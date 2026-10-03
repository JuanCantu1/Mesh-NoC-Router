// latency_sweep_tb.sv
//
// Latency / throughput characterization of mesh_credit.sv -- one run per
// (traffic pattern, offered load) point; tools/sweep.sh runs the whole
// grid and collects results/latency_sweep.csv.
//
// Methodology (standard open-loop measurement, as in Dally & Towles,
// "Principles and Practices of Interconnection Networks", ch. 23):
//
//   * Every tile has an unbounded *source queue*. Each cycle, each tile
//     generates a new packet with probability RATE/1000 -- regardless of
//     whether the network can currently accept it. Packets leave the
//     source queue (are injected) only when the tile has credit into its
//     own router. Latency is measured from *generation*, so time spent
//     waiting in the source queue counts. That's what makes saturation
//     visible: past the saturation point, source queues grow without
//     bound and latency blows up, instead of the load simply being
//     silently turned away (which is what random_traffic_tb.sv does --
//     fine for correctness, useless for finding the knee of the curve).
//   * Phases: WARMUP (reach steady state, nothing measured) -> MEASURE
//     (packets generated here are tagged; deliveries here count toward
//     accepted throughput) -> DRAIN (keep generating untagged background
//     load so tagged packets see steady-state conditions, until every
//     tagged packet is delivered or DRAIN_LIMIT is hit -> "saturated")
//     -> FLUSH (stop generating AND injecting; the network must empty
//     completely within FLUSH_LIMIT cycles).
//   * FLUSH doubles as a deadlock check under load: whatever state the
//     network was driven into, once no new traffic is offered, every
//     packet already inside it must reach its destination. A router
//     design that could deadlock would leave packets stuck here.
//
// Scoreboard: every injected packet gets a unique 8-bit ID from a free
// pool, carried in the payload, indexing a per-packet table (source,
// destination, generation/injection cycle, injection sequence number).
// Unlike random_traffic_tb.sv's source+tag encoding, lookup is O(1) and
// needs no tag-reuse bookkeeping -- at the default depth, 256 IDs
// comfortably exceed the most packets this 3x3 mesh can physically hold
// in flight at once (33 used input FIFOs x BUFFER_DEPTH 4 = 132).
// Every arrival is checked for: correct destination (misrouting), a live
// ID (loss/duplication), and injection order within its (src,dest) pair
// (reordering). Any failure is counted in `errors`; a clean run needs
// errors == 0 AND noc_pkg::assertion_violations == 0.
//
// Runtime arguments (plusargs, so one compile serves every sweep point):
//   +RATE=<n>     offered load in packets per tile per 1000 cycles (e.g. 250 = 0.25)
//   +PATTERN=<n>  0=uniform random, 1=transpose, 2=bit-complement, 3=hotspot
//   +NODUMP       skip the VCD. The sweep script passes this: a full-mesh
//                 VCD is ~19 MB per 3500 cycles, and 80 sweep points
//                 running in parallel would otherwise write gigabytes and
//                 collide on one filename. Run a single point by hand
//                 (without +NODUMP) to get its waveform.
//
// Compile-time option:
//   -DSWEEP_BUFFER_DEPTH=<n>  input FIFO depth (default 4). Used to test
//                 whether saturation is buffer-limited (README: "Is it
//                 just the buffers?"). Depths above 7 can, in deep
//                 saturation, hold more packets than the 256-entry ID
//                 pool (33 input FIFOs x depth); that shows up loudly as
//                 an "ID pool exhausted" error, never as skewed numbers.
//
// Output: one line prefixed "CSV," (machine-readable, collected by the
// sweep script) plus a human-readable summary and PASS/FAIL line.

`timescale 1ns/1ps

import noc_pkg::*;

module latency_sweep_tb;

`ifndef SWEEP_BUFFER_DEPTH
  `define SWEEP_BUFFER_DEPTH 4
`endif

  localparam int MESH_W       = 3;
  localparam int MESH_H       = 3;
  localparam int NUM_TILES    = MESH_W*MESH_H;
  localparam int BUFFER_DEPTH = `SWEEP_BUFFER_DEPTH;

  localparam int WARMUP_CYCLES  = 1000;
  localparam int MEASURE_CYCLES = 2000;
  localparam int DRAIN_LIMIT    = 4000;
  localparam int FLUSH_LIMIT    = 1000;

  localparam int SRCQ_DEPTH = 8192; // per-tile source queue capacity ("unbounded" in practice)
  localparam int NUM_IDS    = 256;  // 8-bit payload
  localparam int HIST_BINS  = 8192; // latency histogram, 1-cycle bins, last bin = overflow
                                    // (deep-saturation latencies reach ~6000 cycles; smaller
                                    // bins would clip p99 into the overflow bin)

  int rate_permille;
  int pattern;

  logic clk = 0;
  logic rst_n;

  logic  [NUM_TILES-1:0] local_in_valid;
  flit_t [NUM_TILES-1:0] local_in_data;
  logic  [NUM_TILES-1:0] local_in_credit_return;

  logic  [NUM_TILES-1:0] local_out_valid;
  flit_t [NUM_TILES-1:0] local_out_data;
  logic  [NUM_TILES-1:0] local_out_credit_return;

  mesh_credit #(.MESH_W(MESH_W), .MESH_H(MESH_H), .BUFFER_DEPTH(BUFFER_DEPTH)) dut (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .local_in_valid          (local_in_valid),
    .local_in_data           (local_in_data),
    .local_in_credit_return  (local_in_credit_return),
    .local_out_valid         (local_out_valid),
    .local_out_data          (local_out_data),
    .local_out_credit_return (local_out_credit_return)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------------
  // Receive model: each tile is an always-draining consumer with a real
  // bounded buffer (same as random_traffic_tb.sv), so ejection credit
  // timing is realistic rather than same-cycle.
  // ---------------------------------------------------------------------
  logic  [NUM_TILES-1:0] rx_pop_en = '1;
  logic  [NUM_TILES-1:0] rx_full;
  logic  [NUM_TILES-1:0] rx_empty;
  flit_t [NUM_TILES-1:0] rx_head;

  genvar rt;
  generate
    for (rt = 0; rt < NUM_TILES; rt++) begin : g_rx_model
      flit_fifo #(.DEPTH(BUFFER_DEPTH)) u_rx_model (
        .clk(clk), .rst_n(rst_n),
        .push_en(local_out_valid[rt]), .push_data(local_out_data[rt]), .full(rx_full[rt]),
        .pop_en(rx_pop_en[rt]), .pop_data(rx_head[rt]), .empty(rx_empty[rt])
      );
      assign local_out_credit_return[rt] = rx_pop_en[rt] && !rx_empty[rt];
    end
  endgenerate

  // ---------------------------------------------------------------------
  // Sender-side credit: one synchronous update covering send, return,
  // both, or neither -- see random_traffic_tb.sv for the two-process
  // race this shape exists to avoid.
  // ---------------------------------------------------------------------
  int send_credit     [NUM_TILES];
  bit sent_this_cycle [NUM_TILES];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int t = 0; t < NUM_TILES; t++) send_credit[t] <= BUFFER_DEPTH;
    end else begin
      for (int t = 0; t < NUM_TILES; t++) begin
        case ({sent_this_cycle[t], local_in_credit_return[t]})
          2'b10:   send_credit[t] <= send_credit[t] - 1;
          2'b01:   send_credit[t] <= send_credit[t] + 1;
          default: send_credit[t] <= send_credit[t];
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------
  // Per-tile source queues: fixed-size circular buffers built from plain
  // 2D int arrays (this Icarus build supports neither arrays of queues
  // nor task-local queues -- see random_traffic_tb.sv).
  // ---------------------------------------------------------------------
  int srcq_dest [NUM_TILES][SRCQ_DEPTH];
  int srcq_gen  [NUM_TILES][SRCQ_DEPTH];
  bit srcq_meas [NUM_TILES][SRCQ_DEPTH];
  int srcq_head [NUM_TILES];
  int srcq_tail [NUM_TILES];
  int srcq_cnt  [NUM_TILES];
  bit srcq_overflow;

  // ---------------------------------------------------------------------
  // Per-packet table, indexed by the packet's 8-bit ID (its payload).
  // ---------------------------------------------------------------------
  int pkt_src  [NUM_IDS];
  int pkt_dest [NUM_IDS];
  int pkt_gen  [NUM_IDS];
  int pkt_inj  [NUM_IDS];
  int pkt_seq  [NUM_IDS];
  bit pkt_meas [NUM_IDS];
  bit pkt_live [NUM_IDS];

  int free_ids [$]; // module-level bare queue: the only queue shape this Icarus build handles
  int live_count;
  int inj_seq_ctr;
  int last_seq [NUM_TILES][NUM_TILES]; // [src][dest] -> injection seq of last delivery

  // ---------------------------------------------------------------------
  // Phase control and statistics
  // ---------------------------------------------------------------------
  bit generating;
  bit injecting_en;
  bit measuring_window;
  int cycle_num;

  int     meas_generated;
  int     meas_delivered;
  int     window_delivered;
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

  // Same four patterns as random_traffic_tb.sv.
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

  // ---------------------------------------------------------------------
  // One cycle's worth of generation + injection, driven at negedge.
  // ---------------------------------------------------------------------
  task automatic drive_cycle();
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
            srcq_overflow = 1'b1; // queue model exceeded: treat point as saturated
          end else begin
            int tl;
            tl = srcq_tail[t];
            srcq_dest[t][tl] = pick_dest(t);
            srcq_gen[t][tl]  = cycle_num;
            srcq_meas[t][tl] = measuring_window;
            srcq_tail[t]     = (tl + 1) % SRCQ_DEPTH;
            srcq_cnt[t]      = srcq_cnt[t] + 1;
            if (measuring_window) meas_generated = meas_generated + 1;
          end
        end
      end
    end

    // Injection: head of each source queue, if the tile has credit.
    if (injecting_en) begin
      for (int t = 0; t < NUM_TILES; t++) begin
        if (srcq_cnt[t] > 0 && send_credit[t] > 0) begin
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

            f.dest_x  = tile_x(dest);
            f.dest_y  = tile_y(dest);
            f.payload = id[7:0];
            local_in_valid[t]  = 1'b1;
            local_in_data[t]   = f;
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
    for (int d = 0; d < NUM_TILES; d++) begin
      if (local_out_valid[d]) begin
        flit_t got;
        int id, s, lat_total, lat_net;
        got = local_out_data[d];
        id  = got.payload;

        if (got.dest_x !== tile_x(d) || got.dest_y !== tile_y(d)) begin
          errors = errors + 1;
          $display("[FAIL] cyc=%0d: MISROUTED -- tile %0d received a flit addressed to (%0d,%0d)",
                    cycle_num, d, got.dest_x, got.dest_y);
        end

        if (!pkt_live[id]) begin
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
          if (pkt_seq[id] <= last_seq[s][d]) begin
            errors = errors + 1;
            $display("[FAIL] cyc=%0d: REORDER on pair %0d->%0d (seq %0d arrived after seq %0d)",
                      cycle_num, s, d, pkt_seq[id], last_seq[s][d]);
          end
          last_seq[s][d] = pkt_seq[id];

          if (measuring_window) window_delivered = window_delivered + 1;

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

  // Smallest latency L such that at least pct% of measured packets had
  // latency <= L (read off the 1-cycle-resolution histogram).
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
    real    offered_r, accepted_r, avg_total_r, avg_net_r;

    if (!$value$plusargs("RATE=%d", rate_permille)) rate_permille = 200;
    if (!$value$plusargs("PATTERN=%d", pattern))    pattern = 0;

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
    sum_total_lat = 0;
    sum_net_lat = 0;
    max_total_lat = 0;
    errors = 0;

    for (int t = 0; t < NUM_TILES; t++) begin
      srcq_head[t] = 0;
      srcq_tail[t] = 0;
      srcq_cnt[t]  = 0;
      sent_this_cycle[t] = 1'b0;
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
    if (live_count > 0) begin
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
    // Past saturation the network can't keep up: accepted throughput falls
    // below offered load and source queues grow for as long as the run
    // lasts. Measured packets may still manage to drain within DRAIN_LIMIT
    // if the overload is mild, so "undrained" alone under-reports it --
    // accepted falling >5% short of offered is the standard signal.
    if (accepted_r < 0.95 * offered_r) saturated = 1'b1;
    avg_total_r = (meas_delivered > 0) ? (sum_total_lat / (1.0 * meas_delivered)) : 0.0;
    avg_net_r   = (meas_delivered > 0) ? (sum_net_lat   / (1.0 * meas_delivered)) : 0.0;
    p50 = percentile(50);
    p99 = percentile(99);

    $display("CSV,%0d,%0d,%0.4f,%0.4f,%0.3f,%0.3f,%0d,%0d,%0d,%0d,%0d,%0d",
              pattern, rate_permille, offered_r, accepted_r, avg_total_r, avg_net_r,
              p50, p99, max_total_lat, meas_delivered, saturated, errors);

    $write("pattern=%0d rate=%0d/1000: offered=%0.3f accepted=%0.3f pkt/node/cyc, avg latency total=%0.2f net=%0.2f, p50=%0d p99=%0d max=%0d, ",
            pattern, rate_permille, offered_r, accepted_r, avg_total_r, avg_net_r, p50, p99, max_total_lat);
    if (saturated) $display("SATURATED");
    else           $display("stable");
    if (errors == 0) $display("PASS (no misroutes, loss, duplication, reordering, invariant violations; network drained in %0d cycles)", flush_cycles);
    else             $display("FAIL (%0d error(s))", errors);

    $finish;
  end

  initial begin
    #100000000; // generous: DRAIN/FLUSH limits already bound the run
    $display("[FAIL] watchdog timeout");
    $finish;
  end

endmodule : latency_sweep_tb
