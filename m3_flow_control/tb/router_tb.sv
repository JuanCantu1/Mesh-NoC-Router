// router_tb.sv
//
// Directed, self-checking testbench for the M3 credit-based router.
// Unlike M1's testbench (which drove valid/data directly and waited on a
// live `ready`), this one plays the role of a real credit-aware neighbor:
// it keeps its own send_credit[] counter per input port -- mirroring
// exactly what a real upstream router would track -- and only ever sends
// when that counter is nonzero, exactly like the DUT itself does for its
// own outputs. It also plays the role of the downstream neighbor on the
// output side, modeled as a real bounded buffer that can deliberately
// stop draining (`downstream_pop_en`) to force a genuine buffer-full
// backpressure scenario instead of just asserting it works.
//
// The router under test sits at mesh position (X_ID=1, Y_ID=1), same as
// M1, so results are directly comparable.

`timescale 1ns/1ps

import noc_pkg::*;

module router_tb;

  localparam int ROUTER_X = 1;
  localparam int ROUTER_Y = 1;
  localparam int BUFFER_DEPTH = 4;

  logic clk = 0;
  logic rst_n;

  logic  [NUM_PORTS-1:0] in_valid;
  flit_t [NUM_PORTS-1:0] in_data;
  logic  [NUM_PORTS-1:0] in_credit_return;

  logic  [NUM_PORTS-1:0] out_valid;
  flit_t [NUM_PORTS-1:0] out_data;
  logic  [NUM_PORTS-1:0] out_credit_return;

  int pass_count = 0;
  int fail_count = 0;

  router #(.X_ID(ROUTER_X), .Y_ID(ROUTER_Y), .BUFFER_DEPTH(BUFFER_DEPTH)) dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .in_valid          (in_valid),
    .in_data           (in_data),
    .in_credit_return  (in_credit_return),
    .out_valid         (out_valid),
    .out_data          (out_data),
    .out_credit_return (out_credit_return)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------------
  // Downstream model: a real (modeled) neighbor buffer per output port,
  // not just a same-cycle "return everything instantly" stand-in. That
  // distinction matters: crediting back the instant a flit is *sent*
  // (rather than when a real downstream buffer actually *frees a slot*,
  // on its own schedule) would let credit_count[o] recover before this
  // router has any right to believe it. Each of these is a real
  // flit_fifo of the same depth the router's own credit_count assumes,
  // so it can only ever accept what credit_count actually authorized --
  // any mismatch would show up as this model's `full` going high, which
  // should never happen if the router's credit accounting is correct.
  //
  // downstream_pop_en[o] (default all-1: an always-draining, fast
  // neighbor) is how a test models a temporarily busy/slow neighbor on
  // port o: holding it low stops this model from draining, so
  // credit_count[o] will genuinely run out and grants to port o will
  // genuinely stop -- real backpressure, not simulated.
  // ---------------------------------------------------------------------
  logic  [NUM_PORTS-1:0] downstream_pop_en = '1;
  logic  [NUM_PORTS-1:0] downstream_full;
  logic  [NUM_PORTS-1:0] downstream_empty;
  flit_t [NUM_PORTS-1:0] downstream_head;

  genvar dp;
  generate
    for (dp = 0; dp < NUM_PORTS; dp++) begin : g_downstream_model
      flit_fifo #(.DEPTH(BUFFER_DEPTH)) u_downstream_model (
        .clk       (clk),
        .rst_n     (rst_n),
        .push_en   (out_valid[dp]),
        .push_data (out_data[dp]),
        .full      (downstream_full[dp]),
        .pop_en    (downstream_pop_en[dp]),
        .pop_data  (downstream_head[dp]),
        .empty     (downstream_empty[dp])
      );
      assign out_credit_return[dp] = downstream_pop_en[dp] && !downstream_empty[dp];
    end
  endgenerate

  // ---------------------------------------------------------------------
  // Sender model: one credit counter per input port, exactly mirroring
  // what a real upstream neighbor would track. Incremented here whenever
  // the DUT pulses in_credit_return; decremented by try_send() whenever
  // it actually sends. If this counter and the DUT's real FIFO occupancy
  // ever disagree, that disagreement is exactly what a "credit leak"
  // would look like -- which is why fill/drain tests below check this
  // counter returns to exactly BUFFER_DEPTH after a full round trip.
  // ---------------------------------------------------------------------
  int send_credit [NUM_PORTS];

  always @(posedge clk) begin
    #1;
    for (int p = 0; p < NUM_PORTS; p++) begin
      if (in_credit_return[p]) send_credit[p] = send_credit[p] + 1;
    end
  end

  function automatic flit_t mk_flit(input int dx, input int dy, input int pay);
    mk_flit.dest_x  = dx[COORD_WIDTH-1:0];
    mk_flit.dest_y  = dy[COORD_WIDTH-1:0];
    mk_flit.payload = pay[DATA_WIDTH-1:0];
  endfunction

  function automatic string flit_str(input flit_t f);
    flit_str = $sformatf("(dest_x=%0d dest_y=%0d payload=%0d)", f.dest_x, f.dest_y, f.payload);
  endfunction

  // Fire-and-forget single-cycle send, gated by our own tracked credit --
  // never checks or waits on anything from the DUT, exactly like a real
  // credit-based sender wouldn't. `sent` reports whether we actually had
  // credit to send with.
  task automatic try_send(input int port, input flit_t f, output bit sent);
    @(negedge clk);
    if (send_credit[port] > 0) begin
      in_data[port]      = f;
      in_valid[port]     = 1'b1;
      send_credit[port]  = send_credit[port] - 1;
      sent = 1'b1;
    end else begin
      sent = 1'b0;
    end
    @(posedge clk); #1;
    if (sent && dut.fifo_full[port] && send_credit[port] > 0) begin
      // Defensive cross-check: if we still believed we had credit left
      // yet the real buffer reports full, our tracking has drifted from
      // reality -- exactly the shape of bug "credit leak" testing is for.
      $display("[FAIL] protocol check: port %0d full but sender still thinks it has credit", port);
      fail_count++;
    end
    @(negedge clk);
    in_valid[port] = 1'b0;
    in_data[port]  = '0;
  endtask

  task automatic send_and_check(
    input string  name,
    input int     port,
    input flit_t  f,
    input int     exp_out,
    output int    delivered_on_cycle
  );
    bit    sent;
    int    cyc;
    bit    timed_out;
    bit    delivered;
    flit_t got;

    try_send(port, f, sent);

    if (!sent) begin
      $display("[FAIL] %-28s no credit available on port %0d", name, port);
      fail_count++;
      delivered_on_cycle = -1;
    end else begin
      cyc = 0;
      timed_out = 1'b0;
      delivered = 1'b0;
      // Check the *current* state before waiting for a new edge: this
      // router cuts through combinationally, so a flit pushed into an
      // empty, credit-available FIFO can already be sitting on the
      // output the instant try_send() returns -- try_send() itself
      // already advanced through that cycle's sample point (to safely
      // clear in_valid afterward), so polling must not skip past it by
      // unconditionally waiting for another posedge first.
      got = out_data[exp_out];
      if (out_valid[exp_out] && got === f) delivered = 1'b1;
      while (!delivered && !timed_out) begin
        @(posedge clk); #1;
        cyc++;
        got = out_data[exp_out];
        if (out_valid[exp_out] && got === f) delivered = 1'b1;
        else if (cyc > 15) timed_out = 1'b1;
      end

      if (!delivered) begin
        $display("[FAIL] %-28s never observed at output %0d (timeout)", name, exp_out);
        fail_count++;
        delivered_on_cycle = -1;
      end else begin
        $display("[PASS] %-28s port %0d -> port %0d, %s (delivered cycle %0d)",
                  name, port, exp_out, flit_str(f), cyc);
        pass_count++;
        delivered_on_cycle = cyc;
      end
    end
  endtask

  task automatic check(input string name, input bit cond, input string detail);
    if (cond) begin
      $display("[PASS] %-28s %s", name, detail);
      pass_count++;
    end else begin
      $display("[FAIL] %-28s %s", name, detail);
      fail_count++;
    end
  endtask

  // Waits for the next flit to appear on `port`'s output (up to a bounded
  // number of cycles) and copies it out. Used by the drain-order checks,
  // one call per expected flit -- deliberately not a loop over an array
  // of expected values, to stay clear of the loop-variable-plus-struct
  // shapes noted at the top of this file as unsafe on this toolchain.
  task automatic wait_for_output(input int port, output flit_t got);
    bit done;
    int cyc;
    done = 1'b0;
    cyc = 0;
    while (!done) begin
      @(posedge clk); #1;
      cyc++;
      if (out_valid[port]) begin
        got = out_data[port];
        done = 1'b1;
      end else if (cyc > 20) begin
        done = 1'b1; // safety net -- caller's check will fail on stale `got`
      end
    end
  endtask

  initial begin
    $dumpfile("sim/router_tb.vcd");
    $dumpvars(0, router_tb);

    in_valid  = '0;
    in_data   = '0;
    for (int p = 0; p < NUM_PORTS; p++) send_credit[p] = BUFFER_DEPTH;

    rst_n = 0;
    repeat (2) @(posedge clk);
    #1;
    rst_n = 1;
    @(posedge clk);
    #1;

    $display("================================================================");
    $display(" M3 credit-based router directed test -- router at (X=%0d, Y=%0d)", ROUTER_X, ROUTER_Y);
    $display("================================================================");

    // -----------------------------------------------------------------
    // (a) Basic pass-through, now through a buffer + credit round trip.
    // -----------------------------------------------------------------
    begin
      int cyc;
      send_and_check("pass-through W->E", PORT_W, mk_flit(2,1,8'hA1), PORT_E, cyc);
    end

    // -----------------------------------------------------------------
    // (b) Turn: same XY routing as M1, now sourced from a FIFO instead
    // of a direct wire.
    // -----------------------------------------------------------------
    begin
      int cyc;
      send_and_check("turn E->S", PORT_E, mk_flit(1,2,8'hB1), PORT_S, cyc);
    end

    // -----------------------------------------------------------------
    // (c) Arrival and (d) injection, same as M1.
    // -----------------------------------------------------------------
    begin
      int cyc;
      send_and_check("arrival ->Local", PORT_N, mk_flit(1,1,8'hC0), PORT_L, cyc);
    end
    begin
      int cyc;
      send_and_check("inject Local->E", PORT_L, mk_flit(3,1,8'hD0), PORT_E, cyc);
    end

    // -----------------------------------------------------------------
    // (e) Contention: the round-robin arbiter still has to resolve two
    // simultaneous requesters, now competing for credit-gated grants
    // instead of plain valid/ready ones.
    // -----------------------------------------------------------------
    begin
      int cyc_n, cyc_w;
      fork
        send_and_check("contention N->E", PORT_N, mk_flit(3,1,8'hE1), PORT_E, cyc_n);
        send_and_check("contention W->E", PORT_W, mk_flit(3,1,8'hE2), PORT_E, cyc_w);
      join
      check("contention arbitrated fairly",
            (cyc_n != -1) && (cyc_w != -1) && (cyc_n != cyc_w),
            $sformatf("N delivered cycle %0d, W delivered cycle %0d (must differ, neither -1)", cyc_n, cyc_w));
    end

    // -----------------------------------------------------------------
    // (f) Fill to genuinely full, verify backpressure, drain in strict
    // order, and verify credit fully recovers -- the core "no credit
    // leak" check this milestone is about.
    //
    // East's modeled downstream neighbor stops draining first, but
    // East's credit_count doesn't necessarily start at a full
    // BUFFER_DEPTH here -- it reflects whatever traffic already passed
    // through East in earlier scenarios above, which may not have fully
    // settled back to BUFFER_DEPTH yet. So the first few flits sent
    // toward East would cut through immediately no matter which input
    // port they arrive from, simply spending whatever credit East
    // happens to still have. To observe West's *own* input buffer
    // genuinely fill up (rather than its flits cutting straight through
    // and piling up in East's modeled neighbor instead), East's credit
    // is first drained on purpose with unrelated "priming" traffic from
    // North -- sent one at a time, checking real (settled) credit after
    // each, for as many as it actually takes -- only once East is
    // *actually* out of credit does anything sent from West have to sit
    // and queue.
    // -----------------------------------------------------------------
    begin
      flit_t pdummy;                       // priming traffic (via North)
      flit_t g0, g1, g2, g3, fq_extra;     // the real traffic under test (via West)
      flit_t got0, got1, got2, got3;
      bit sent;
      bit primed_done;
      int prime_guard;

      g0 = mk_flit(3,1,8'h10);
      g1 = mk_flit(3,1,8'h11);
      g2 = mk_flit(3,1,8'h12);
      g3 = mk_flit(3,1,8'h13);
      fq_extra = mk_flit(3,1,8'hFF);

      downstream_pop_en[PORT_E] = 1'b0;

      // Prime: drain East's credit with throwaway traffic that cuts
      // straight through (East still has credit for each of these,
      // until it doesn't). A settle wait follows every send before the
      // stopping condition is checked -- try_send() itself returns
      // before the credit_count update it triggered has actually
      // clocked in, so checking immediately would see a stale value.
      primed_done = 1'b0;
      prime_guard = 0;
      while (!primed_done) begin
        repeat (2) begin @(posedge clk); #1; end
        if (dut.credit_count[PORT_E] == 0) begin
          primed_done = 1'b1;
        end else begin
          pdummy = mk_flit(3, 1, 8'h90 + prime_guard);
          try_send(PORT_N, pdummy, sent);
          prime_guard = prime_guard + 1;
          if (prime_guard > 2*BUFFER_DEPTH) primed_done = 1'b1; // safety net
        end
      end
      check("priming drained East's credit",
            dut.credit_count[PORT_E] == 0,
            $sformatf("credit_count[E]=%0d after %0d priming sends (started from whatever East's credit already was)",
                      dut.credit_count[PORT_E], prime_guard));
      check("no priming traffic left stuck behind",
            dut.fifo_empty[PORT_N],
            "every priming flit that was sent was also fully granted -- none left queued to interfere with the real test");

      // Now East genuinely has nothing to give: these four have to queue.
      try_send(PORT_W, g0, sent);
      check("queue fill 1/4 accepted", sent, "W had credit for flit 1");
      try_send(PORT_W, g1, sent);
      check("queue fill 2/4 accepted", sent, "W had credit for flit 2");
      try_send(PORT_W, g2, sent);
      check("queue fill 3/4 accepted", sent, "W had credit for flit 3");
      try_send(PORT_W, g3, sent);
      check("queue fill 4/4 accepted", sent, "W had credit for flit 4 (buffer now genuinely full)");

      check("sender correctly out of credit",
            send_credit[PORT_W] == 0,
            $sformatf("send_credit[W]=%0d, expected 0 after exactly BUFFER_DEPTH=%0d sends", send_credit[PORT_W], BUFFER_DEPTH));
      check("DUT's own buffer agrees it's full",
            dut.fifo_full[PORT_W] === 1'b1,
            "dut.fifo_full[W] is genuinely asserted, not just inferred from our own counter");

      try_send(PORT_W, fq_extra, sent);
      check("5th send correctly refused (real backpressure)",
            !sent,
            "a well-behaved sender with 0 credit does not attempt to send, and none was lost by trying");

      check("nothing leaked out to East while blocked",
            !out_valid[PORT_E],
            "East has no credit, so nothing queued behind it should have escaped yet");

      // Let East's modeled neighbor resume draining. Its 4 primed
      // (throwaway) entries drain first, handing credit back one at a
      // time; West's 4 queued flits are granted the instant each credit
      // arrives, so what we observe next -- in order -- is g0..g3.
      downstream_pop_en[PORT_E] = 1'b1;

      wait_for_output(PORT_E, got0);
      check("drain order: 1st out matches 1st in", got0 === g0, "FIFO order preserved under backpressure");
      wait_for_output(PORT_E, got1);
      check("drain order: 2nd out matches 2nd in", got1 === g1, "still in order");
      wait_for_output(PORT_E, got2);
      check("drain order: 3rd out matches 3rd in", got2 === g2, "still in order");
      wait_for_output(PORT_E, got3);
      check("drain order: 4th out matches 4th in (last)", got3 === g3, "still in order, nothing duplicated");

      // Give the final in_credit_return pulse (from the last pop) one
      // more cycle to be sampled by our monitor before checking it.
      @(posedge clk); #1;

      check("no credit leak: sender fully recovered",
            send_credit[PORT_W] == BUFFER_DEPTH,
            $sformatf("send_credit[W]=%0d, expected exactly BUFFER_DEPTH=%0d after full fill+drain round trip",
                      send_credit[PORT_W], BUFFER_DEPTH));
      check("DUT agrees its own buffer is empty again",
            dut.fifo_empty[PORT_W] === 1'b1,
            "dut.fifo_empty[W] confirms zero net occupancy after the round trip");
    end

    @(posedge clk);
    $display("================================================================");
    if (fail_count == 0)
      $display(" ALL TESTS PASSED  (%0d/%0d)", pass_count, pass_count + fail_count);
    else
      $display(" %0d TEST(S) FAILED  (%0d passed, %0d failed)", fail_count, pass_count, fail_count);
    $display("================================================================");

    $finish;
  end

  initial begin
    #5000;
    $display("[FAIL] watchdog timeout -- simulation did not finish in time");
    $finish;
  end

endmodule : router_tb
