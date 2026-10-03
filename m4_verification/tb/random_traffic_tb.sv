// random_traffic_tb.sv
//
// Randomized-traffic regression for mesh_credit.sv: every tile injects
// packets to random destinations at a fixed rate for many cycles, and a
// scoreboard checks that every single packet arrives -- exactly once,
// with unchanged data, in the order it was sent relative to every other
// packet between that same (source, destination) pair.
//
// Why per-(source,destination) ordering, not global ordering: XY routing
// is deterministic -- every packet between a given pair takes the exact
// same path -- so packets *from the same pair* can never legitimately
// reorder. Packets between *different* pairs interleave freely (that's
// normal, correct concurrent traffic), so checking global arrival order
// would be checking something that was never promised.
//
// Scoreboard implementation note (this took a real bug to get right):
// the first version of this file tagged each packet with a 4-bit
// sequence number embedded in its payload and checked it against a
// per-pair expected-next-sequence counter. That works fine for uniform
// random and permutation traffic, but genuinely broke under the hotspot
// pattern below: heavy convergent traffic toward one tile can leave more
// than 16 packets from the same source simultaneously in flight, which
// wraps a 4-bit tag and produces false failures that look exactly like
// real ordering bugs. (Confirmed by lowering the injection rate: same
// RTL, same pattern, passes clean once congestion drops -- so the RTL
// was never wrong, the *tag width* was.) Icarus does not support arrays
// of queues (confirmed directly -- `type q[N][$]` fails to elaborate for
// any element type, not just structs), so the fix here is three *bare*
// parallel queues (src/dest/payload) holding every packet still
// in-flight, searched linearly for the oldest still-pending entry from
// the same (src,dest) pair on every arrival. That's O(outstanding
// packets) per arrival rather than O(1), but it has no wraparound limit
// at all, which is what actually matters for verifying a design under
// adversarial-by-design traffic like hotspot.
//
// Run with: iverilog -g2012 -o sim/random_traffic_tb.vvp rtl/*.sv tb/random_traffic_tb.sv
//           vvp sim/random_traffic_tb.vvp

`timescale 1ns/1ps

import noc_pkg::*;

module random_traffic_tb;

  localparam int MESH_W = 3;
  localparam int MESH_H = 3;
  localparam int NUM_TILES = MESH_W*MESH_H;
  localparam int BUFFER_DEPTH = 4;

  // PATTERN is set via a `-D` macro at compile time (this Icarus build has
  // no command-line Verilog-parameter-override flag, only `-D`), e.g.
  //   iverilog ... -DPATTERN=1 tb/random_traffic_tb.sv
  // PATTERN: 0=uniform random, 1=transpose, 2=bit-complement, 3=hotspot
  `ifndef PATTERN
    `define PATTERN 0
  `endif
  `ifndef INJECT_PCT
    `define INJECT_PCT 30
  `endif
  parameter int RUN_CYCLES      = 3000; // cycles traffic is actively injected
  parameter int DRAIN_CYCLES    = 500;  // extra cycles to let in-flight traffic finish
  parameter int INJECT_PCT      = `INJECT_PCT; // percent chance per tile per cycle of a new packet
  parameter int PATTERN         = `PATTERN;

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

  // Receive model: every tile is an ideal (always-draining) consumer for
  // this test -- the point here is traffic-pattern correctness, not
  // backpressure (M3's router_tb.sv already covers backpressure in
  // depth).
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

  // send_credit[t]: this tile's local mirror of how much room its own
  // router's Local-input FIFO has. Deliberately a SINGLE synchronous
  // always_ff, not two separate processes (one decrementing at negedge
  // inside maybe_inject_all, another incrementing at posedge here) --
  // that split-process version was tried first and had a real bug: under
  // the dense, every-tile-every-cycle injection pattern this test uses
  // (much denser than M3's router_tb.sv, which only ever drove one port
  // at a time), a send and a same-cycle credit-return could both need to
  // touch send_credit[t], and the two-process version occasionally lost
  // one of the two updates, permanently under-counting by exactly 1 --
  // which is indistinguishable from a real credit leak until traced back
  // to its actual source. This mirrors router.sv's own credit_count
  // update (a single case statement covering "sent", "returned", "both",
  // "neither" together) for exactly the reason that pattern is correct
  // there: both events have to be accounted for in the same atomic
  // update, not two updates that can race.
  int  send_credit [NUM_TILES];
  bit  sent_this_cycle [NUM_TILES]; // set by maybe_inject_all at negedge, consumed here

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
  // Scoreboard: three bare (non-array-indexed -- see header note above)
  // parallel queues describing every packet currently in flight, in the
  // order each was injected.
  // ---------------------------------------------------------------------
  int q_src     [$];
  int q_dest    [$];
  int q_payload [$];

  // tag_ctr/tag_in_use embed a per-source 4-bit tag in each flit's payload
  // (see maybe_inject_all) so an arrival can be traced back to a source at
  // all -- flit_t has no dedicated source field. This tag DOES matter for
  // correctness, not just readability, and getting it right took two
  // tries:
  //   1st try: a blind round-robin counter (0..15 wrapping). Broke under
  //     heavy hotspot congestion -- not because 16+ packets were ever
  //     truly outstanding at once, but because *one* packet could sit
  //     stuck for a long time while 16 *other* packets from the same
  //     source were sent and resolved quickly around it, so the counter
  //     wrapped back onto that one still-outstanding packet's tag even
  //     though total outstanding count never got large.
  //   2nd try: capping total outstanding count (pending_count < 15)
  //     without changing the allocation scheme. Didn't help, for exactly
  //     the reason above -- count staying low doesn't stop one specific
  //     tag value from being reused while its packet is still in flight.
  // The actual fix: tag_in_use tracks which specific tag *values* are
  // currently assigned to an outstanding packet, and allocation skips
  // forward past any that are still in use rather than blindly taking
  // the next counter value. pending_count < 15 (kept as a real invariant,
  // not just a mitigation now) guarantees a free tag always exists among
  // the 16 possible values when one is needed.
  int  tag_ctr [NUM_TILES];
  bit  tag_in_use [NUM_TILES][16];
  int pending_count [NUM_TILES]; // how many of this source's packets are currently outstanding
  longint total_injected;
  longint total_delivered;
  int     mismatch_count;
  bit     injecting;

  // DEBUG: full history logs (never pruned) so a mismatch can be traced
  // back to exactly what was sent and what arrived, in order.
  longint cycle_num = 0;
  int     hist_src[$];  int     hist_dest[$];  int     hist_payload[$];  longint hist_cyc[$];
  int     ahist_dest[$]; int    ahist_payload[$]; longint ahist_cyc[$];
  bit     debug_dumped;

  function automatic int tile_x(input int t); tile_x = t % MESH_W; endfunction
  function automatic int tile_y(input int t); tile_y = t / MESH_W; endfunction
  function automatic int tile_id(input int x, input int y); tile_id = y*MESH_W + x; endfunction

  function automatic int pick_dest_uniform(input int src);
    int d;
    d = src;
    while (d == src) begin
      d = $urandom_range(0, NUM_TILES-1);
    end
    pick_dest_uniform = d;
  endfunction

  // Four classic synthetic traffic patterns used to characterize NoC
  // designs (see e.g. Dally & Towles, "Principles and Practices of
  // Interconnection Networks"): uniform random stresses average-case
  // behavior; transpose and bit-complement are permutations that
  // concentrate load on specific diagonal/long-distance paths and are
  // known to be adversarial for some routing algorithms; hotspot models
  // many-to-one traffic like a shared memory controller or cache.
  function automatic int pick_dest(input int src);
    int sx, sy, dx, dy;
    sx = tile_x(src);
    sy = tile_y(src);
    case (PATTERN)
      1: begin // transpose: (x,y) -> (y,x)
        dx = sy;
        dy = sx;
        if (dx == sx && dy == sy) pick_dest = pick_dest_uniform(src); // on the diagonal: no real transpose exists
        else pick_dest = tile_id(dx, dy);
      end
      2: begin // bit-complement: mirror through the center of the mesh
        dx = (MESH_W-1) - sx;
        dy = (MESH_H-1) - sy;
        if (dx == sx && dy == sy) pick_dest = pick_dest_uniform(src); // exact center tile on an odd-sized mesh
        else pick_dest = tile_id(dx, dy);
      end
      3: begin // hotspot: 25% of traffic converges on tile 0, else uniform
        if (src != 0 && $urandom_range(0,99) < 25) pick_dest = 0;
        else pick_dest = pick_dest_uniform(src);
      end
      default: pick_dest = pick_dest_uniform(src); // 0: uniform random
    endcase
  endfunction

  // Drives all NUM_TILES potential injections for one cycle. A single
  // procedural loop over plain int/logic arrays (no struct-field access
  // chained off the loop variable) -- the shape already proven safe
  // elsewhere in this project, as opposed to the shapes documented as
  // unsafe at the top of router.sv.
  task automatic maybe_inject_all();
    for (int t = 0; t < NUM_TILES; t++) begin
      local_in_valid[t]   = 1'b0;
      local_in_data[t]    = '0;
      sent_this_cycle[t]  = 1'b0;
    end
    if (injecting) begin
      for (int t = 0; t < NUM_TILES; t++) begin
        // pending_count[t] < 15 guarantees at least one of the 16 tag
        // values is free below (see the tag_ctr/tag_in_use declaration).
        if (send_credit[t] > 0 && pending_count[t] < 15 && ($urandom_range(0,99) < INJECT_PCT)) begin
          int dest;
          int tag;
          flit_t f;
          dest = pick_dest(t);
          f.dest_x  = tile_x(dest);
          f.dest_y  = tile_y(dest);

          tag = tag_ctr[t];
          while (tag_in_use[t][tag]) tag = (tag + 1) % 16;
          tag_in_use[t][tag] = 1'b1;
          tag_ctr[t] = (tag + 1) % 16;

          // top 4 bits identify the source; low 4 bits are the tag just
          // allocated above (guaranteed free among currently-outstanding
          // packets from this source).
          f.payload = {t[3:0], tag[3:0]};

          local_in_valid[t]  = 1'b1;
          local_in_data[t]   = f;
          sent_this_cycle[t] = 1'b1;

          q_src.push_back(t);
          q_dest.push_back(dest);
          q_payload.push_back(f.payload);
          total_injected = total_injected + 1;
          pending_count[t] = pending_count[t] + 1;

          hist_src.push_back(t);
          hist_dest.push_back(dest);
          hist_payload.push_back(f.payload);
          hist_cyc.push_back(cycle_num);
        end
      end
    end
  endtask

  // Checks all NUM_TILES outputs for an arrival this cycle. For each one,
  // finds the *oldest* still-outstanding entry from the same (src,dest)
  // pair (a linear scan from the front of the shared queues -- the front
  // is the oldest injection overall, so the first pair-match found is
  // necessarily that pair's oldest still-pending entry) and checks the
  // arriving payload against it exactly, then removes it. A pair whose
  // packets never reorder will always find its own next expected entry
  // at that same relative position, so this is exactly as strict an
  // ordering check as the old per-pair counter was -- just without a tag
  // width to overflow.
  // Pulled out to its own top-level task (rather than nested several
  // levels deep inside check_all_arrivals) because this Icarus build's
  // vvp runtime crashes (an internal thread-context assertion, not a
  // compile error) when a queue is declared as a local variable inside a
  // deeply nested begin/end block. A shallow, task-scoped declaration is
  // the workaround.
  // sent_pay/sent_cyc/arr_pay/arr_cyc/dump_n are module-level, not
  // task-local, even though only dump_pair_history() ever touches them:
  // this Icarus build's vvp runtime crashes (an internal thread-context
  // assertion, not a compile error -- confirmed with a minimal direct-call
  // repro, not merely a nesting-depth issue) whenever an `automatic` task
  // declares a queue as a *local* variable, unconditionally. Module-level
  // queues accessed from within a task are fine; the bug is specifically
  // about where the queue is declared.
  int sent_pay[$];  int sent_cyc[$];
  int arr_pay[$];   int arr_cyc[$];
  int dump_n;

  task automatic dump_pair_history(input int src, input int d, input longint trig_cyc);
    sent_pay.delete(); sent_cyc.delete();
    arr_pay.delete();  arr_cyc.delete();

    for (int k = 0; k < hist_src.size(); k++) begin
      if (hist_src[k] == src && hist_dest[k] == d) begin
        sent_pay.push_back(hist_payload[k]);
        sent_cyc.push_back(int'(hist_cyc[k]));
      end
    end
    for (int k = 0; k < ahist_dest.size(); k++) begin
      int pay, psrc;
      pay = ahist_payload[k];
      psrc = (pay >> 4) & 4'hF;
      if (ahist_dest[k] == d && psrc == src) begin
        arr_pay.push_back(pay);
        arr_cyc.push_back(int'(ahist_cyc[k]));
      end
    end

    $display("---- DEBUG: src=%0d dest=%0d (triggering cycle=%0d) ----", src, d, trig_cyc);
    $display("  sent %0d, arrived %0d, so far (includes this cycle's own arrival above)",
              sent_pay.size(), arr_pay.size());
    dump_n = (sent_pay.size() > arr_pay.size()) ? sent_pay.size() : arr_pay.size();
    for (int k = 0; k < dump_n; k++) begin
      if (k < sent_pay.size() && k < arr_pay.size())
        $display("  [%0d] sent cyc=%0d pay=%0d  |  arrived cyc=%0d pay=%0d  %s",
                  k, sent_cyc[k], sent_pay[k], arr_cyc[k], arr_pay[k],
                  (sent_pay[k] == arr_pay[k]) ? "" : "<-- MISMATCH HERE");
      else if (k < sent_pay.size())
        $display("  [%0d] sent cyc=%0d pay=%0d  |  (nothing arrived yet at this position)",
                  k, sent_cyc[k], sent_pay[k]);
      else
        $display("  [%0d] (nothing sent at this position!)  |  arrived cyc=%0d pay=%0d",
                  k, arr_cyc[k], arr_pay[k]);
    end
    $display("---- END DEBUG ----");
  endtask

  task automatic check_all_arrivals();
    for (int d = 0; d < NUM_TILES; d++) begin
      if (local_out_valid[d]) begin
        flit_t got;
        int src;
        int found_idx;
        bit found;
        got = local_out_data[d];
        src = got.payload[7:4];
        total_delivered = total_delivered + 1;

        if (got.dest_x !== tile_x(d) || got.dest_y !== tile_y(d)) begin
          $display("[FAIL] MISROUTED: flit arrived at tile %0d (x=%0d,y=%0d) but carries dest_x=%0d dest_y=%0d -- src=%0d payload=%0d cyc=%0d",
                    d, tile_x(d), tile_y(d), got.dest_x, got.dest_y, src, got.payload, cycle_num);
        end

        ahist_dest.push_back(d);
        ahist_payload.push_back(got.payload);
        ahist_cyc.push_back(cycle_num);

        found = 1'b0;
        found_idx = -1;
        for (int i = 0; i < q_src.size(); i++) begin
          if (!found && q_src[i] == src && q_dest[i] == d) begin
            found = 1'b1;
            found_idx = i;
          end
        end

        if (!found) begin
          mismatch_count = mismatch_count + 1;
          $display("[FAIL] tile %0d: unexpected arrival from src %0d (payload %0d) -- nothing was waiting for this pair",
                    d, src, got.payload);
        end else begin
          if (q_payload[found_idx] !== got.payload) begin
            mismatch_count = mismatch_count + 1;
            $display("[FAIL] tile %0d: payload mismatch from src %0d -- expected %0d, got %0d (loss/reorder/dup)",
                      d, src, q_payload[found_idx], got.payload);
            if (!debug_dumped) begin
              debug_dumped = 1'b1;
              dump_pair_history(src, d, cycle_num);
            end
          end
          q_src.delete(found_idx);
          q_dest.delete(found_idx);
          q_payload.delete(found_idx);
          pending_count[src] = pending_count[src] - 1;
          tag_in_use[src][got.payload[3:0]] = 1'b0;
        end
      end
    end
  endtask

  initial begin
    $dumpfile("sim/random_traffic_tb.vcd");
    $dumpvars(0, random_traffic_tb);

    local_in_valid = '0;
    local_in_data  = '0;
    total_injected = 0;
    total_delivered = 0;
    mismatch_count = 0;
    debug_dumped = 1'b0;
    injecting = 1'b0;

    for (int s = 0; s < NUM_TILES; s++) begin
      // send_credit[s] is not initialized here -- it's driven entirely by
      // its own always_ff (async reset to BUFFER_DEPTH), not this
      // procedural block; assigning it here too would be a second driver.
      tag_ctr[s]     = 0;
      pending_count[s] = 0;
      for (int tg = 0; tg < 16; tg++) tag_in_use[s][tg] = 1'b0;
    end

    rst_n = 0;
    repeat (2) @(posedge clk);
    #1;
    rst_n = 1;
    @(posedge clk); #1;

    $display("================================================================");
    $display(" M4 randomized-traffic scoreboard -- %0dx%0d mesh, pattern=%0d (%s),",
              MESH_W, MESH_H, PATTERN,
              (PATTERN==1) ? "transpose" : (PATTERN==2) ? "bit-complement" : (PATTERN==3) ? "hotspot" : "uniform random");
    $display(" %0d cycles @ %0d%% injection, then %0d cycles to drain", RUN_CYCLES, INJECT_PCT, DRAIN_CYCLES);
    $display("================================================================");

    injecting = 1'b1;
    for (int c = 0; c < RUN_CYCLES; c++) begin
      @(negedge clk);
      maybe_inject_all();
      @(posedge clk); #1;
      cycle_num = cycle_num + 1;
      check_all_arrivals();
    end

    injecting = 1'b0;
    @(negedge clk);
    maybe_inject_all(); // clears any lingering valid from the last injecting cycle
    for (int c = 0; c < DRAIN_CYCLES; c++) begin
      @(posedge clk); #1;
      cycle_num = cycle_num + 1;
      check_all_arrivals();
    end

    $display("================================================================");
    $display(" total injected:   %0d", total_injected);
    $display(" total delivered:  %0d", total_delivered);
    $display(" still outstanding after drain: %0d (should be 0)", q_src.size());
    $display(" mismatches (loss/reorder/dup/unexpected): %0d", mismatch_count);
    $display(" RTL invariant violations (FIFO/credit/fairness): %0d", assertion_violations);

    if (mismatch_count == 0 && total_injected == total_delivered && q_src.size() == 0
        && assertion_violations == 0) begin
      $display(" ALL TRAFFIC ACCOUNTED FOR -- PASS");
    end else begin
      $display(" FAIL -- %0d packet(s) unaccounted for, %0d mismatch(es), %0d stuck outstanding, %0d invariant violation(s)",
                total_injected - total_delivered, mismatch_count, q_src.size(), assertion_violations);
    end
    $display("================================================================");

    $finish;
  end

  initial begin
    #500000;
    $display("[FAIL] watchdog timeout -- simulation did not finish in time");
    $finish;
  end

endmodule : random_traffic_tb
