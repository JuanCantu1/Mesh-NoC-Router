// latency_sweep_tb.sv
//
// Latency / throughput characterization of vc_mesh.sv -- one run per
// (router configuration, traffic pattern, offered load) point.
// tools/sweep.sh runs whole grids of them.
//
// This is M4's latency_sweep_tb.sv carried forward to the VC interface,
// with the measurement method unchanged (open-loop Bernoulli injection into
// unbounded source queues; warmup -> measure -> drain -> flush; latency
// from generation; see M4's README for the method). Every point is still
// a full correctness run.
//
// What's new for VCs:
//   * The sender tracks one credit counter per VC of its local link and
//     injects into the VCs of the packet's VN round-robin, skipping VCs
//     with no credit. The receiver has one always-draining buffer per VC.
//   * Every arrival is also checked for: arriving on a VC of its own VN,
//     and carrying its true source coordinates.
//   * Per-(source, destination) ORDER is only guaranteed when each VN has
//     a single VC: with several, two packets of the same pair can take
//     different VCs and overtake each other. So with VCS_PER_VN == 1 a
//     reorder is an error (as in M4); with VCS_PER_VN > 1 reorders are
//     counted and reported as a statistic -- the price of the VCs, measured.
//   * The random-number call sequence is identical to M4's (VC choice uses
//     no randomness), so with one VN of one VC this testbench drives
//     exactly M4's stimulus -- which is what lets
//     tools/equivalence_check.sh compare against M4's sweep line for line.
//
// M6 additions:
//   * The mesh is built with SECURE (default 1). With no attack running,
//     every security alarm must stay silent -- any alarm is a false
//     positive and fails the run -- and the output is identical to M5's.
//   * +BLACKHOLE=<tile>: the BLACK-HOLE ATTACK. That tile never consumes
//     anything delivered to it, so it never returns ejection credits.
//     Everything else is measured as VICTIM traffic (packets for other
//     tiles): offered/accepted throughput and latency count victims only.
//     Packets for the black hole are accounted separately: delivered into
//     its (never-drained) buffers, discarded by the router's watchdog (the
//     discarded flit is still visible on local_out_data with out_valid low
//     and alarm[2] high, so the testbench identifies each one), or stuck.
//     "Compromised" = victim packets that never arrive, or a network that
//     can't drain once traffic stops. With SECURE=1 the attack must be
//     contained; with SECURE=0 and +EXPECT_COMPROMISE it must succeed.
//
// Compile-time configuration (defaults in parentheses):
//   -DSWEEP_NUM_VNS=<n>       virtual networks (1); all traffic here is REQ class
//   -DSWEEP_VCS_PER_VN=<n>    VCs per VN (1)
//   -DSWEEP_BUFFER_DEPTH=<n>  flits per VC buffer (4)
//   -DSWEEP_SA_ITERS=<n>      switch-allocation passes, 1 or 2 (1)
//   -DSWEEP_SECURE=<0|1>      M6 hardening (1)
//   -DSWEEP_WD_LIMIT=<n>      watchdog starvation limit, cycles (256)
// Runtime: +RATE=<permille> +PATTERN=<0..3> +NODUMP  (as in M4)
//          +BLACKHOLE=<tile> +EXPECT_COMPROMISE        (M6 attack mode)
//          +BH_START=<cycle>  the tile behaves until this cycle, then turns black hole (0)

`timescale 1ns/1ps

import noc_pkg::*;

module latency_sweep_tb;

`ifndef SWEEP_NUM_VNS
  `define SWEEP_NUM_VNS 1
`endif
`ifndef SWEEP_VCS_PER_VN
  `define SWEEP_VCS_PER_VN 1
`endif
`ifndef SWEEP_BUFFER_DEPTH
  `define SWEEP_BUFFER_DEPTH 4
`endif
`ifndef SWEEP_SA_ITERS
  `define SWEEP_SA_ITERS 1
`endif
`ifndef SWEEP_SECURE
  `define SWEEP_SECURE 1
`endif
`ifndef SWEEP_WD_LIMIT
  `define SWEEP_WD_LIMIT 256
`endif

  localparam int MESH_W       = 3;
  localparam int MESH_H       = 3;
  localparam int NUM_TILES    = MESH_W*MESH_H;
  localparam int NUM_VNS      = `SWEEP_NUM_VNS;
  localparam int VCS_PER_VN   = `SWEEP_VCS_PER_VN;
  localparam int NUM_VCS      = NUM_VNS*VCS_PER_VN;
  localparam int BUFFER_DEPTH = `SWEEP_BUFFER_DEPTH;
  localparam int SA_ITERS     = `SWEEP_SA_ITERS;
  localparam int SECURE       = `SWEEP_SECURE;
  localparam int WD_LIMIT     = `SWEEP_WD_LIMIT;

  localparam int WARMUP_CYCLES  = 1000;
  localparam int MEASURE_CYCLES = 2000;
  localparam int DRAIN_LIMIT    = 4000;
  localparam int FLUSH_LIMIT    = 1000;

  localparam int SRCQ_DEPTH = 8192; // per-tile source queue capacity ("unbounded" in practice)
  localparam int NUM_IDS    = 4096; // > 33 input ports x NUM_VCS x depth for every config swept
  localparam int HIST_BINS  = 8192; // latency histogram, 1-cycle bins, last bin = overflow

  // All sweep traffic is one class, so it all travels in one VN.
  localparam logic [MCLASS_W-1:0] SWEEP_CLASS = MC_REQ;
  localparam int SWEEP_VN = (NUM_VNS == 1) ? 0 : int'(SWEEP_CLASS);

  int rate_permille;
  int pattern;
  int blackhole;         // attacking tile, or -1
  int bh_start;          // cycle it stops consuming
  bit expect_compromise;

  logic clk = 0;
  logic rst_n;

  logic  [NUM_TILES-1:0]         local_in_valid;
  logic  [NUM_TILES*VC_W-1:0]    local_in_vc;
  flit_t [NUM_TILES-1:0]         local_in_data;
  logic  [NUM_TILES*NUM_VCS-1:0] local_in_credit_return;

  logic  [NUM_TILES-1:0]         local_out_valid;
  logic  [NUM_TILES*VC_W-1:0]    local_out_vc;
  flit_t [NUM_TILES-1:0]         local_out_data;
  logic  [NUM_TILES*NUM_VCS-1:0] local_out_credit_return;
  logic  [NUM_TILES*3-1:0]       tile_alarm;
  logic  [NUM_TILES-1:0]         rx_drain;  // tile consumes its deliveries (all but a black hole)

  vc_mesh #(
    .MESH_W(MESH_W), .MESH_H(MESH_H),
    .NUM_VNS(NUM_VNS), .VCS_PER_VN(VCS_PER_VN), .BUFFER_DEPTH(BUFFER_DEPTH),
    .SA_ITERS(SA_ITERS), .SECURE(SECURE), .WD_LIMIT(WD_LIMIT)
  ) dut (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .local_in_valid          (local_in_valid),
    .local_in_vc             (local_in_vc),
    .local_in_data           (local_in_data),
    .local_in_credit_return  (local_in_credit_return),
    .local_out_valid         (local_out_valid),
    .local_out_vc            (local_out_vc),
    .local_out_data          (local_out_data),
    .local_out_credit_return (local_out_credit_return),
    .tile_alarm              (tile_alarm)
  );

  always #5 clk = ~clk;

  // Per-tile views of the flattened VC/credit vectors (generate-time
  // slicing; procedural code then indexes plain arrays).
  logic [VC_W-1:0]    inj_vc      [NUM_TILES]; // VC this tile drives on local_in_vc
  logic [VC_W-1:0]    arr_vc      [NUM_TILES]; // VC of the flit on local_out
  logic [NUM_VCS-1:0] in_cr_of    [NUM_TILES]; // credits coming back to each sender

  // ---------------------------------------------------------------------
  // Receive model: one always-draining buffer per (tile, VC).
  // ---------------------------------------------------------------------
  genvar gt, gv;
  generate
    for (gt = 0; gt < NUM_TILES; gt++) begin : g_tile
      assign local_in_vc[gt*VC_W +: VC_W] = inj_vc[gt];
      assign arr_vc[gt]                   = local_out_vc[gt*VC_W +: VC_W];
      assign in_cr_of[gt]                 = local_in_credit_return[gt*NUM_VCS +: NUM_VCS];

      for (gv = 0; gv < NUM_VCS; gv++) begin : g_rx_vc
        logic  rx_empty, rx_full;
        flit_t rx_head;
        flit_fifo #(.DEPTH(BUFFER_DEPTH)) u_rx_model (
          .clk(clk), .rst_n(rst_n),
          .push_en(local_out_valid[gt] && (local_out_vc[gt*VC_W +: VC_W] == gv)),
          .push_data(local_out_data[gt]), .push_tag(1'b0), .pop_tag(), .full(rx_full),
          .pop_en(rx_drain[gt]), .pop_data(rx_head), .empty(rx_empty)
        );
        assign local_out_credit_return[gt*NUM_VCS + gv] = rx_drain[gt] && !rx_empty;
      end
    end
  endgenerate

  // ---------------------------------------------------------------------
  // Sender-side credit, one counter per (tile, VC): one synchronous update
  // covering send, return, both, or neither (see M4's README for the
  // two-process race this shape exists to avoid).
  // ---------------------------------------------------------------------
  int send_credit     [NUM_TILES][NUM_VCS];
  bit sent_this_cycle [NUM_TILES];
  int inj_rr          [NUM_TILES]; // round-robin pointer over the VN's VCs

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int t = 0; t < NUM_TILES; t++)
        for (int v = 0; v < NUM_VCS; v++) send_credit[t][v] <= BUFFER_DEPTH;
    end else begin
      for (int t = 0; t < NUM_TILES; t++) begin
        for (int v = 0; v < NUM_VCS; v++) begin
          bit sent, returned;
          sent     = sent_this_cycle[t] && (inj_vc[t] == v);
          returned = in_cr_of[t][v];
          case ({sent, returned})
            2'b10:   send_credit[t][v] <= send_credit[t][v] - 1;
            2'b01:   send_credit[t][v] <= send_credit[t][v] + 1;
            default: send_credit[t][v] <= send_credit[t][v];
          endcase
        end
      end
    end
  end

  // ---------------------------------------------------------------------
  // Per-tile source queues (fixed 2D arrays; see M4 for why not queues).
  // ---------------------------------------------------------------------
  int srcq_dest [NUM_TILES][SRCQ_DEPTH];
  int srcq_gen  [NUM_TILES][SRCQ_DEPTH];
  bit srcq_meas [NUM_TILES][SRCQ_DEPTH];
  int srcq_head [NUM_TILES];
  int srcq_tail [NUM_TILES];
  int srcq_cnt  [NUM_TILES];
  bit srcq_overflow;

  // Per-packet table, indexed by the packet's ID (its payload).
  int pkt_src  [NUM_IDS];
  int pkt_dest [NUM_IDS];
  int pkt_gen  [NUM_IDS];
  int pkt_inj  [NUM_IDS];
  int pkt_seq  [NUM_IDS];
  bit pkt_meas [NUM_IDS];
  bit pkt_live [NUM_IDS];

  int free_ids [$];
  int live_count;
  int inj_seq_ctr;
  int last_seq [NUM_TILES][NUM_TILES]; // [src][dest] -> highest injection seq delivered so far

  // Phase control and statistics
  bit generating;
  bit injecting_en;
  bit measuring_window;
  int cycle_num;

  int     meas_generated;
  int     meas_delivered;
  int     window_delivered;
  int     total_delivered;
  int     reordered;          // deliveries that arrived after a later packet of the same pair
  // M6 black-hole accounting
  int     bh_delivered;       // packets for the black hole that reached its buffers
  int     bh_discarded;       // ...that its router's watchdog discarded
  int     stuck_after_flush;  // packets still in the network when the run ended
  int     quarantine_cycle;   // first cycle the black hole's port was quarantined (-1: never)
  longint sum_total_lat;
  longint sum_net_lat;
  int     max_total_lat;
  int     lat_hist [HIST_BINS];
  int     errors;

  function automatic int tile_x(input int t); tile_x = t % MESH_W; endfunction
  function automatic int tile_y(input int t); tile_y = t / MESH_W; endfunction
  function automatic int tile_id(input int x, input int y); tile_id = y*MESH_W + x; endfunction

  function automatic int pick_dest_uniform(input int src);
    int d;
    d = src;
    while (d == src) d = $urandom_range(0, NUM_TILES-1);
    pick_dest_uniform = d;
  endfunction

  // Same four patterns as M4.
  function automatic int pick_dest(input int src);
    int sx, sy, dx, dy;
    sx = tile_x(src);
    sy = tile_y(src);
    case (pattern)
      1: begin // transpose: (x,y) -> (y,x); diagonal tiles have no transpose partner
        dx = sy; dy = sx;
        if (dx == sx && dy == sy) pick_dest = pick_dest_uniform(src);
        else pick_dest = tile_id(dx, dy);
      end
      2: begin // bit-complement: mirror through the mesh center; the center tile has no partner
        dx = (MESH_W-1) - sx; dy = (MESH_H-1) - sy;
        if (dx == sx && dy == sy) pick_dest = pick_dest_uniform(src);
        else pick_dest = tile_id(dx, dy);
      end
      3: begin // hotspot: 25% of traffic converges on tile 0
        if (src != 0 && $urandom_range(0,99) < 25) pick_dest = 0;
        else pick_dest = pick_dest_uniform(src);
      end
      default: pick_dest = pick_dest_uniform(src);
    endcase
  endfunction

  // First VC (round-robin from inj_rr[t]) in the sweep VN with credit, or -1.
  function automatic int pick_inj_vc(input int t);
    int k, v;
    pick_inj_vc = -1;
    for (int i = 0; i < VCS_PER_VN; i++) begin
      k = (inj_rr[t] + i) % VCS_PER_VN;
      v = SWEEP_VN*VCS_PER_VN + k;
      if (pick_inj_vc == -1 && send_credit[t][v] > 0) pick_inj_vc = v;
    end
  endfunction

  // ---------------------------------------------------------------------
  // One cycle's worth of generation + injection, driven at negedge.
  // ---------------------------------------------------------------------
  task automatic drive_cycle();
    if (blackhole >= 0 && cycle_num >= bh_start) rx_drain[blackhole] = 1'b0; // the tile turns rogue
    for (int t = 0; t < NUM_TILES; t++) begin
      local_in_valid[t]  = 1'b0;
      local_in_data[t]   = '0;
      sent_this_cycle[t] = 1'b0;
    end

    // Generation (Bernoulli process per tile) into the source queue.
    if (generating) begin
      for (int t = 0; t < NUM_TILES; t++) begin
        if ($urandom_range(0,999) < rate_permille) begin
          if (srcq_cnt[t] >= SRCQ_DEPTH) begin
            srcq_overflow = 1'b1;
          end else begin
            int tl;
            tl = srcq_tail[t];
            srcq_dest[t][tl] = pick_dest(t);
            srcq_gen[t][tl]  = cycle_num;
            srcq_meas[t][tl] = measuring_window && (srcq_dest[t][tl] != blackhole);
            srcq_tail[t]     = (tl + 1) % SRCQ_DEPTH;
            srcq_cnt[t]      = srcq_cnt[t] + 1;
            if (srcq_meas[t][tl]) meas_generated = meas_generated + 1;
          end
        end
      end
    end

    // Injection: head of each source queue, if a VC of its VN has credit.
    if (injecting_en) begin
      for (int t = 0; t < NUM_TILES; t++) begin
        int v;
        v = pick_inj_vc(t);
        if (srcq_cnt[t] > 0 && v >= 0) begin
          if (free_ids.size() == 0) begin
            errors = errors + 1;
            $display("[FAIL] cyc=%0d: packet ID pool exhausted (more in flight than the mesh can hold?)", cycle_num);
          end else begin
            int hd, id, dest;
            flit_t f;
            hd   = srcq_head[t];
            dest = srcq_dest[t][hd];
            id   = free_ids[0];
            free_ids.delete(0);

            pkt_src[id]  = t;
            pkt_dest[id] = dest;
            pkt_gen[id]  = srcq_gen[t][hd];
            pkt_inj[id]  = cycle_num;
            pkt_seq[id]  = inj_seq_ctr;
            pkt_meas[id] = srcq_meas[t][hd];
            pkt_live[id] = 1'b1;
            inj_seq_ctr  = inj_seq_ctr + 1;
            live_count   = live_count + 1;

            srcq_head[t] = (hd + 1) % SRCQ_DEPTH;
            srcq_cnt[t]  = srcq_cnt[t] - 1;

            f.mclass  = SWEEP_CLASS;
            f.src_x   = tile_x(t);
            f.src_y   = tile_y(t);
            f.dest_x  = tile_x(dest);
            f.dest_y  = tile_y(dest);
            f.payload = id;
            local_in_valid[t]  = 1'b1;
            local_in_data[t]   = f;
            inj_vc[t]          = v;
            inj_rr[t]          = (v - SWEEP_VN*VCS_PER_VN + 1) % VCS_PER_VN;
            sent_this_cycle[t] = 1'b1;
          end
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Arrival checking + statistics, sampled at posedge+1.
  // ---------------------------------------------------------------------
  task automatic check_arrivals();
    // M6: security alarms. With no attack, any alarm is a false positive.
    // Under attack, only the black hole's own router may raise one.
    for (int d = 0; d < NUM_TILES; d++) begin
      logic [2:0] al;
      al = tile_alarm[d*3 +: 3];
      if (al != 3'b000 && d != blackhole) begin
        errors = errors + 1;
        $display("[FAIL] cyc=%0d: false security alarm at tile %0d (alarm=%b) -- an honest tile was flagged", cycle_num, d, al);
      end
      if (al[1] && d == blackhole && quarantine_cycle < 0) quarantine_cycle = cycle_num;
      if (al[2]) begin // the watchdog discarded the flit on local_out_data[d]
        flit_t gone;
        int gid;
        gone = local_out_data[d];
        gid  = gone.payload;
        if (gid >= NUM_IDS || !pkt_live[gid] || pkt_dest[gid] != d) begin
          errors = errors + 1;
          $display("[FAIL] cyc=%0d: tile %0d's router discarded a flit that isn't a live packet for it (ID %0d)", cycle_num, d, gid);
        end else begin
          bh_discarded  = bh_discarded + 1;
          pkt_live[gid] = 1'b0;
          free_ids.push_back(gid);
          live_count    = live_count - 1;
        end
      end
    end

    for (int d = 0; d < NUM_TILES; d++) begin
      if (local_out_valid[d]) begin
        flit_t got;
        int id, s, lat_total, lat_net, vc;
        got = local_out_data[d];
        id  = got.payload;
        vc  = arr_vc[d];

        if (got.dest_x !== tile_x(d) || got.dest_y !== tile_y(d)) begin
          errors = errors + 1;
          $display("[FAIL] cyc=%0d: MISROUTED -- tile %0d received a flit addressed to (%0d,%0d)",
                    cycle_num, d, got.dest_x, got.dest_y);
        end
        if (vc / VCS_PER_VN != noc_pkg::vn_of(got.mclass, NUM_VNS)) begin
          errors = errors + 1;
          $display("[FAIL] cyc=%0d: tile %0d received a class-%0d flit on VC %0d -- outside its VN",
                    cycle_num, d, got.mclass, vc);
        end

        if (id >= NUM_IDS || !pkt_live[id]) begin
          errors = errors + 1;
          $display("[FAIL] cyc=%0d: tile %0d received ID %0d, which is not in flight (duplicate or corrupted)",
                    cycle_num, d, id);
        end else begin
          s = pkt_src[id];
          if (pkt_dest[id] != d) begin
            errors = errors + 1;
            $display("[FAIL] cyc=%0d: ID %0d delivered to tile %0d, was sent to tile %0d",
                      cycle_num, id, d, pkt_dest[id]);
          end
          if (got.src_x !== tile_x(s) || got.src_y !== tile_y(s)) begin
            errors = errors + 1;
            $display("[FAIL] cyc=%0d: ID %0d from tile %0d arrived claiming source (%0d,%0d)",
                      cycle_num, id, s, got.src_x, got.src_y);
          end
          if (pkt_seq[id] <= last_seq[s][d]) begin
            if (VCS_PER_VN == 1) begin
              errors = errors + 1;
              $display("[FAIL] cyc=%0d: REORDER on pair %0d->%0d (seq %0d arrived after seq %0d) -- impossible with one VC per VN",
                        cycle_num, s, d, pkt_seq[id], last_seq[s][d]);
            end else begin
              reordered = reordered + 1;
            end
          end else begin
            last_seq[s][d] = pkt_seq[id];
          end

          total_delivered = total_delivered + 1;
          if (d == blackhole) bh_delivered = bh_delivered + 1;
          else if (measuring_window) window_delivered = window_delivered + 1;

          if (pkt_meas[id]) begin
            lat_total = cycle_num - pkt_gen[id];
            lat_net   = cycle_num - pkt_inj[id];
            meas_delivered = meas_delivered + 1;
            sum_total_lat  = sum_total_lat + lat_total;
            sum_net_lat    = sum_net_lat + lat_net;
            if (lat_total > max_total_lat) max_total_lat = lat_total;
            if (lat_total >= HIST_BINS) lat_hist[HIST_BINS-1] = lat_hist[HIST_BINS-1] + 1;
            else                        lat_hist[lat_total]   = lat_hist[lat_total] + 1;
          end

          pkt_live[id] = 1'b0;
          free_ids.push_back(id);
          live_count = live_count - 1;
        end
      end
    end
  endtask

  task automatic one_cycle();
    @(negedge clk);
    drive_cycle();
    @(posedge clk); #1;
    cycle_num = cycle_num + 1;
    check_arrivals();
  endtask

  function automatic int percentile(input int pct);
    int target, acc;
    bit found;
    target = (meas_delivered * pct + 99) / 100;
    if (target < 1) target = 1;
    acc = 0;
    found = 1'b0;
    percentile = HIST_BINS - 1;
    for (int b = 0; b < HIST_BINS; b++) begin
      acc = acc + lat_hist[b];
      if (!found && acc >= target) begin
        found = 1'b1;
        percentile = b;
      end
    end
  endfunction

  initial begin
    int     drain_cycles, flush_cycles, p50, p99;
    bit     saturated;
    real    offered_r, accepted_r, avg_total_r, avg_net_r, reorder_pct;

    if (!$value$plusargs("RATE=%d", rate_permille)) rate_permille = 200;
    if (!$value$plusargs("PATTERN=%d", pattern))    pattern = 0;
    if (!$value$plusargs("BLACKHOLE=%d", blackhole)) blackhole = -1;
    expect_compromise = $test$plusargs("EXPECT_COMPROMISE");
    if (!$value$plusargs("BH_START=%d", bh_start)) bh_start = 0;
    for (int t = 0; t < NUM_TILES; t++) rx_drain[t] = (t != blackhole) || (bh_start > 0);

    if (!$test$plusargs("NODUMP")) begin
      $dumpfile("sim/latency_sweep_tb.vcd");
      $dumpvars(0, latency_sweep_tb);
    end

    local_in_valid = '0;
    local_in_data  = '0;
    generating = 1'b0;
    injecting_en = 1'b0;
    measuring_window = 1'b0;
    srcq_overflow = 1'b0;
    cycle_num = 0;
    live_count = 0;
    inj_seq_ctr = 0;
    meas_generated = 0;
    meas_delivered = 0;
    window_delivered = 0;
    total_delivered = 0;
    reordered = 0;
    bh_delivered = 0;
    bh_discarded = 0;
    stuck_after_flush = 0;
    quarantine_cycle = -1;
    sum_total_lat = 0;
    sum_net_lat = 0;
    max_total_lat = 0;
    errors = 0;

    for (int t = 0; t < NUM_TILES; t++) begin
      srcq_head[t] = 0;
      srcq_tail[t] = 0;
      srcq_cnt[t]  = 0;
      sent_this_cycle[t] = 1'b0;
      inj_vc[t] = 0;
      inj_rr[t] = 0;
      for (int u = 0; u < NUM_TILES; u++) last_seq[t][u] = -1;
    end
    for (int i = 0; i < NUM_IDS; i++) begin
      pkt_live[i] = 1'b0;
      free_ids.push_back(i);
    end
    for (int b = 0; b < HIST_BINS; b++) lat_hist[b] = 0;

    rst_n = 0;
    repeat (2) @(posedge clk);
    #1;
    rst_n = 1;
    @(posedge clk); #1;

    // WARMUP
    generating = 1'b1;
    injecting_en = 1'b1;
    repeat (WARMUP_CYCLES) one_cycle();

    // MEASURE
    measuring_window = 1'b1;
    repeat (MEASURE_CYCLES) one_cycle();
    measuring_window = 1'b0;

    // DRAIN (background load continues; wait for every measured packet)
    drain_cycles = 0;
    while (meas_delivered < meas_generated && drain_cycles < DRAIN_LIMIT) begin
      one_cycle();
      drain_cycles = drain_cycles + 1;
    end
    saturated = (meas_delivered < meas_generated) || srcq_overflow;

    // FLUSH (no new traffic at all; the network must empty -> deadlock check)
    generating = 1'b0;
    injecting_en = 1'b0;
    flush_cycles = 0;
    while (live_count > 0 && flush_cycles < FLUSH_LIMIT) begin
      one_cycle();
      flush_cycles = flush_cycles + 1;
    end
    stuck_after_flush = live_count;
    if (live_count > 0 && blackhole < 0) begin
      errors = errors + 1;
      $display("[FAIL] network did not drain: %0d packet(s) still in flight %0d cycles after injection stopped (lost or deadlocked)",
                live_count, FLUSH_LIMIT);
    end
    if (assertion_violations != 0) begin
      errors = errors + 1;
      $display("[FAIL] %0d RTL invariant violation(s) (see ASSERT-FAIL lines above)", assertion_violations);
    end

    offered_r   = meas_generated / (1.0 * NUM_TILES * MEASURE_CYCLES);
    accepted_r  = window_delivered / (1.0 * NUM_TILES * MEASURE_CYCLES);
    if (accepted_r < 0.95 * offered_r) saturated = 1'b1;
    avg_total_r = (meas_delivered > 0) ? (sum_total_lat / (1.0 * meas_delivered)) : 0.0;
    avg_net_r   = (meas_delivered > 0) ? (sum_net_lat   / (1.0 * meas_delivered)) : 0.0;
    reorder_pct = (total_delivered > 0) ? (100.0 * reordered / total_delivered) : 0.0;
    p50 = percentile(50);
    p99 = percentile(99);

    $display("CSV,%0d,%0d,%0d,%0d,%0d,%0d,%0.4f,%0.4f,%0.3f,%0.3f,%0d,%0d,%0d,%0d,%0d,%0d,%0.3f",
              NUM_VNS, VCS_PER_VN, BUFFER_DEPTH, SA_ITERS,
              pattern, rate_permille, offered_r, accepted_r, avg_total_r, avg_net_r,
              p50, p99, max_total_lat, meas_delivered, saturated, errors, reorder_pct);

    $write("vns=%0d vcs/vn=%0d depth=%0d sa_iters=%0d pattern=%0d rate=%0d/1000: offered=%0.3f accepted=%0.3f, avg latency total=%0.2f net=%0.2f, p50=%0d p99=%0d max=%0d, reordered=%0.2f%%, ",
            NUM_VNS, VCS_PER_VN, BUFFER_DEPTH, SA_ITERS, pattern, rate_permille, offered_r, accepted_r,
            avg_total_r, avg_net_r, p50, p99, max_total_lat, reorder_pct);
    if (saturated) $display("SATURATED");
    else           $display("stable");
    if (blackhole >= 0)
      ; // attack mode: the ATTACK-PASS/ATTACK-FAIL verdict below is the result
    else if (errors != 0)
      $display("FAIL (%0d error(s))", errors);
    else if (VCS_PER_VN == 1)
      $display("PASS (no misroutes, loss, duplication, reordering, VN escapes, source corruption, false alarms, invariant violations; network drained in %0d cycles)", flush_cycles);
    else
      $display("PASS (no misroutes, loss, duplication, VN escapes, source corruption, false alarms, invariant violations; network drained in %0d cycles)", flush_cycles);

    if (blackhole >= 0) begin
      bit compromised;
      compromised = (stuck_after_flush > 0) || (meas_delivered < meas_generated);
      $display("ATTACK,blackhole,%0d,%0d,%0d,%0d,%0.4f,%0.4f,%0.3f,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                blackhole, SECURE, WD_LIMIT, rate_permille, offered_r, accepted_r, avg_total_r,
                meas_generated - meas_delivered, bh_delivered, bh_discarded, stuck_after_flush,
                quarantine_cycle, compromised, errors, bh_start);
      $display("black hole at tile %0d (SECURE=%0d): victims offered %0.3f, accepted %0.3f, %0d of %0d measured victim packets never arrived;",
                blackhole, SECURE, offered_r, accepted_r, meas_generated - meas_delivered, meas_generated);
      $display("  packets for the black hole: %0d delivered into its buffers, %0d discarded by the watchdog, %0d stuck at the end; quarantine at cycle %0d",
                bh_delivered, bh_discarded, stuck_after_flush, quarantine_cycle);
      if (errors != 0)
        $display("ATTACK-FAIL (%0d testbench/RTL error(s))", errors);
      else if (expect_compromise && compromised)
        $display("ATTACK-PASS -- unprotected network compromised, as expected: victim traffic stalled behind the black hole");
      else if (expect_compromise)
        $display("ATTACK-FAIL -- expected the unprotected network to be compromised, but victims were unaffected");
      else if (!compromised)
        $display("ATTACK-PASS -- attack contained: every victim packet delivered, network drained");
      else
        $display("ATTACK-FAIL -- attack NOT contained: victim packets lost or network stuck");
    end

    $finish;
  end

  initial begin
    #100000000;
    $display("[FAIL] watchdog timeout");
    $finish;
  end

endmodule : latency_sweep_tb
