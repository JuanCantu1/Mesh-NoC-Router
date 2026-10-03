// vc_router_tb.sv
//
// Directed, self-checking tests of a single vc_router -- each test builds
// one specific situation and checks the one behavior M5 claims for it.
// The randomized testbenches (latency_sweep_tb, protocol_tb) prove these
// hold statistically under load; these prove each one deliberately, in a
// scenario small enough to draw (see the README).
//
// Several routers, each in its own router_harness at mesh position (1,1),
// with different configurations. Some tests replay the same stimulus on
// two configurations side by side to show the difference.
//
//   T1  routing + credits     every output port, every credit back on the right VC wire
//   T2  HOL blocking          1-VC router: a flit stuck behind a blocked one
//                             2-VC router, same stimulus: it goes around
//   T3  VN isolation          a REQ-class jam on one output doesn't stop an
//                             RSP to the same output; VN preserved hop to hop
//   T4  output-VC choice      round-robin across the VCs of a VN; a stalled
//                             VC is skipped, never a VC of another VN
//   T5  2-pass allocation     an input that loses pass 1 sends on another VC
//                             in pass 2, the same cycle (1-pass: later)
//   T6  fairness              4 inputs contending for 1 output get equal shares
//   T7  checker check         the VN-isolation invariant actually fires on a
//                             flit injected into the wrong VN
//
// Run with: iverilog -g2012 -o sim/vc_router_tb.vvp rtl/*.sv tb/router_harness.sv tb/vc_router_tb.sv

`timescale 1ns/1ps

import noc_pkg::*;

module vc_router_tb;

  logic clk = 0;
  logic rst_n;
  always #5 clk = ~clk;

  // Port numbers (noc_pkg::port_e values, as ints).
  localparam int N = 0, S = 1, E = 2, W = 3, L = 4;
  // Destinations as seen from the router at (1,1).
  localparam int TO_E_X = 2, TO_E_Y = 1;
  localparam int TO_W_X = 0, TO_W_Y = 1;
  localparam int TO_N_X = 1, TO_N_Y = 0;
  localparam int TO_S_X = 1, TO_S_Y = 2;
  localparam int TO_L_X = 1, TO_L_Y = 1;

  //                           NUM_VNS VCS_PER_VN DEPTH SA_ITERS
  router_harness #(1, 1, 2, 1) h_1vc   (.clk(clk), .rst_n(rst_n)); // T2 (M4-like), T6
  router_harness #(1, 2, 2, 1) h_2vc   (.clk(clk), .rst_n(rst_n)); // T2
  router_harness #(3, 1, 2, 1) h_vn    (.clk(clk), .rst_n(rst_n)); // T1, T3, T7
  router_harness #(3, 2, 2, 2) h_vn2   (.clk(clk), .rst_n(rst_n)); // T4
  router_harness #(1, 2, 1, 1) h_sa1   (.clk(clk), .rst_n(rst_n)); // T5, 1-pass
  router_harness #(1, 2, 1, 2) h_sa2   (.clk(clk), .rst_n(rst_n)); // T5, 2-pass

  int pass_count = 0;
  int fail_count = 0;
  int expected_violations = 0;

  task automatic check(input string name, input bit cond, input string detail);
    if (cond) begin
      $display("[PASS] %-34s %s", name, detail);
      pass_count++;
    end else begin
      $display("[FAIL] %-34s %s", name, detail);
      fail_count++;
    end
  endtask

  initial begin
    $dumpfile("sim/vc_router_tb.vcd");
    $dumpvars(0, vc_router_tb);

    rst_n = 0;
    repeat (2) @(posedge clk);
    #1;
    rst_n = 1;
    @(posedge clk); #1;

    $display("================================================================");
    $display(" M5 vc_router directed tests");
    $display("================================================================");

    // -----------------------------------------------------------------
    // T1: routing + per-VC credits (3 VNs x 1 VC). One flit of each
    // class to each output; each must leave on the right port, in its own
    // VN's VC, and every input credit must come back.
    // -----------------------------------------------------------------
    begin
      int dx [5], dy [5];
      bit ok_port, ok_vc;
      dx[N] = TO_N_X; dy[N] = TO_N_Y;  dx[S] = TO_S_X; dy[S] = TO_S_Y;
      dx[E] = TO_E_X; dy[E] = TO_E_Y;  dx[W] = TO_W_X; dy[W] = TO_W_Y;
      dx[L] = TO_L_X; dy[L] = TO_L_Y;
      ok_port = 1; ok_vc = 1;
      for (int o = 0; o < 5; o++) begin
        for (int c = 0; c < 3; c++) begin
          h_vn.send1(L, c, h_vn.mk(c, dx[o], dy[o], 100 + o*10 + c));
        end
      end
      h_vn.idle(4);
      for (int o = 0; o < 5; o++) begin
        for (int c = 0; c < 3; c++) begin
          int k;
          k = h_vn.find(100 + o*10 + c);
          if (k < 0 || h_vn.ev_port[k] != o) ok_port = 0;
          if (k < 0 || h_vn.ev_vc[k] != c)   ok_vc = 0;
        end
      end
      check("T1 routing to all 5 ports", ok_port, "15 flits (3 classes x 5 destinations), each left on its XY port");
      check("T1 class stays in its VN", ok_vc, "every REQ/SNP/RSP left on VC 0/1/2 respectively");
      check("T1 credits returned per VC", h_vn.send_credit[L][0] == 2 && h_vn.send_credit[L][1] == 2 && h_vn.send_credit[L][2] == 2,
            $sformatf("local input credits back to %0d/%0d/%0d of 2", h_vn.send_credit[L][0], h_vn.send_credit[L][1], h_vn.send_credit[L][2]));
    end

    // -----------------------------------------------------------------
    // T2: head-of-line blocking, same stimulus on 1 VC vs 2 VCs.
    // East's downstream is stalled and its credits used up, so a flit
    // for East is stuck. Then from the West input: A (for East), then B
    // (for North, which is idle). 1 VC: B is behind A in the same FIFO.
    // 2 VCs: B goes in the other VC and leaves right away.
    // -----------------------------------------------------------------
    begin
      int kb1, kb2, ka1, cyc_b1;
      // fill East: 1-VC router has 2 credits there, 2-VC router has 4
      h_1vc.stall(E, 0, 1);
      h_2vc.stall(E, 0, 1);
      h_2vc.stall(E, 1, 1);
      for (int i = 0; i < 2; i++) h_1vc.send1(S, 0, h_1vc.mk(0, TO_E_X, TO_E_Y, 200 + i));
      for (int i = 0; i < 4; i++) h_2vc.send1(S, i % 2, h_2vc.mk(0, TO_E_X, TO_E_Y, 200 + i));
      h_1vc.idle(2);
      h_2vc.idle(0);
      // A then B into the West input
      fork
        begin
          h_1vc.send1(W, 0, h_1vc.mk(0, TO_E_X, TO_E_Y, 210)); // A
          h_1vc.send1(W, 0, h_1vc.mk(0, TO_N_X, TO_N_Y, 211)); // B, same FIFO
        end
        begin
          h_2vc.send1(W, 0, h_2vc.mk(0, TO_E_X, TO_E_Y, 210)); // A
          h_2vc.send1(W, 1, h_2vc.mk(0, TO_N_X, TO_N_Y, 211)); // B, other VC
        end
      join
      h_1vc.idle(6);
      kb1 = h_1vc.find(211);
      kb2 = h_2vc.find(211);
      check("T2 1 VC: B stuck behind A (HOL)", kb1 < 0, "North is idle, yet B hasn't left after 6 cycles: A blocks the only FIFO");
      check("T2 2 VCs: B bypasses A", kb2 >= 0 && h_2vc.ev_port[kb2] == N,
            "same stimulus; B was in its own VC and left on North");
      // release East: everything drains, A before B on the 1-VC router
      h_1vc.stall(E, 0, 0);
      h_2vc.stall(E, 0, 0);
      h_2vc.stall(E, 1, 0);
      h_1vc.idle(8);
      ka1 = h_1vc.find(210);
      kb1 = h_1vc.find(211);
      check("T2 1 VC: drains once East frees", ka1 >= 0 && kb1 >= 0 && h_1vc.ev_cycle[ka1] < h_1vc.ev_cycle[kb1],
            "A leaves first, then B -- FIFO order");
    end

    // -----------------------------------------------------------------
    // T3: VN isolation (3 VNs x 1 VC, depth 2). East's REQ VC is stalled
    // and full. A REQ for East waits -- but an RSP for East, in its own
    // VN with its own credits, goes straight through.
    // -----------------------------------------------------------------
    begin
      int k_req, k_rsp;
      h_vn.stall(E, 0, 1);
      for (int i = 0; i < 2; i++) h_vn.send1(S, 0, h_vn.mk(MC_REQ, TO_E_X, TO_E_Y, 300 + i));
      h_vn.send1(W, 0, h_vn.mk(MC_REQ, TO_E_X, TO_E_Y, 310)); // blocked REQ
      h_vn.send1(W, 2, h_vn.mk(MC_RSP, TO_E_X, TO_E_Y, 311)); // RSP, same input port, same output
      h_vn.idle(4);
      k_req = h_vn.find(310);
      k_rsp = h_vn.find(311);
      check("T3 REQ blocked (its VN is full)", k_req < 0, "East's REQ VC has no credit");
      check("T3 RSP passes the REQ jam", k_rsp >= 0 && h_vn.ev_port[k_rsp] == E && h_vn.ev_vc[k_rsp] == 2,
            "same input, same output, different VN: left on East, VC 2 (RSP)");
      h_vn.stall(E, 0, 0);
      h_vn.idle(6);
      k_req = h_vn.find(310);
      check("T3 REQ drains on its own VC", k_req >= 0 && h_vn.ev_vc[k_req] == 0, "once East's REQ VC frees, the REQ leaves on VC 0");
    end

    // -----------------------------------------------------------------
    // T4: output-VC choice (3 VNs x 2 VCs). Consecutive REQs to East use
    // VC 0 and VC 1 in turn. With VC 0 stalled, once its 2 credits are
    // spent every REQ uses VC 1 -- never a VC of another VN.
    // -----------------------------------------------------------------
    begin
      bit alternate, in_vn, fallback;
      int vc_prev, used0, used1;
      alternate = 1; in_vn = 1;
      vc_prev = -1;
      for (int i = 0; i < 4; i++) h_vn2.send1(L, i % 2, h_vn2.mk(MC_REQ, TO_E_X, TO_E_Y, 400 + i));
      h_vn2.idle(3);
      for (int i = 0; i < 4; i++) begin
        int k;
        k = h_vn2.find(400 + i);
        if (k < 0 || h_vn2.ev_vc[k] > 1) in_vn = 0;
        else begin
          if (vc_prev != -1 && h_vn2.ev_vc[k] == vc_prev) alternate = 0;
          vc_prev = h_vn2.ev_vc[k];
        end
      end
      check("T4 round-robin within the VN", alternate && in_vn, "4 REQs to East used VC 0,1,0,1 (in some rotation), never VCs 2-5");
      h_vn2.stall(E, 0, 1);
      used0 = 0; used1 = 0; fallback = 1;
      for (int i = 0; i < 8; i++) h_vn2.send1(L, i % 2, h_vn2.mk(MC_REQ, TO_E_X, TO_E_Y, 410 + i));
      h_vn2.idle(4);
      for (int i = 0; i < 8; i++) begin
        int k;
        k = h_vn2.find(410 + i);
        if (k < 0) fallback = 0;
        else if (h_vn2.ev_vc[k] == 0) used0++;
        else if (h_vn2.ev_vc[k] == 1) used1++;
        else fallback = 0;
      end
      check("T4 stalled VC skipped, not waited on", fallback && used0 <= 2 && used1 >= 6,
            $sformatf("8 REQs with VC 0 stalled: %0d on VC 0 (its 2 credits), %0d on VC 1, none blocked", used0, used1));
      h_vn2.stall(E, 0, 0);
      h_vn2.idle(4);
    end

    // -----------------------------------------------------------------
    // T5: 2-pass switch allocation (1 VN x 2 VCs, depth 1), same stimulus
    // on a 1-pass and a 2-pass router. East and North start full. Then:
    // West VC0 -> East, Local VC0 -> East, Local VC1 -> North. When both
    // outputs free up in the same cycle, West wins East in pass 1. With 2
    // passes, Local (which lost) sends its North flit in pass 2, the same
    // cycle. With 1 pass, North sits idle that cycle.
    // -----------------------------------------------------------------
    begin
      int kw_a, kl_a, kw_b, kl_b;
      h_sa1.stall(E, 0, 1); h_sa1.stall(E, 1, 1); h_sa1.stall(N, 0, 1); h_sa1.stall(N, 1, 1);
      h_sa2.stall(E, 0, 1); h_sa2.stall(E, 1, 1); h_sa2.stall(N, 0, 1); h_sa2.stall(N, 1, 1);
      fork
        begin
          h_sa1.send1(S, 0, h_sa1.mk(0, TO_E_X, TO_E_Y, 500));
          h_sa1.send1(S, 1, h_sa1.mk(0, TO_E_X, TO_E_Y, 501));
          h_sa1.send1(S, 0, h_sa1.mk(0, TO_N_X, TO_N_Y, 502));
          h_sa1.send1(S, 1, h_sa1.mk(0, TO_N_X, TO_N_Y, 503));
        end
        begin
          h_sa2.send1(S, 0, h_sa2.mk(0, TO_E_X, TO_E_Y, 500));
          h_sa2.send1(S, 1, h_sa2.mk(0, TO_E_X, TO_E_Y, 501));
          h_sa2.send1(S, 0, h_sa2.mk(0, TO_N_X, TO_N_Y, 502));
          h_sa2.send1(S, 1, h_sa2.mk(0, TO_N_X, TO_N_Y, 503));
        end
      join
      // stage the three contenders (East and North are full, so they wait)
      @(negedge clk);
      h_sa1.stage(W, 0, h_sa1.mk(0, TO_E_X, TO_E_Y, 510));
      h_sa1.stage(L, 0, h_sa1.mk(0, TO_E_X, TO_E_Y, 511));
      h_sa2.stage(W, 0, h_sa2.mk(0, TO_E_X, TO_E_Y, 510));
      h_sa2.stage(L, 0, h_sa2.mk(0, TO_E_X, TO_E_Y, 511));
      @(posedge clk); #1;
      h_sa1.unstage(); h_sa2.unstage();
      @(negedge clk);
      h_sa1.stage(L, 1, h_sa1.mk(0, TO_N_X, TO_N_Y, 512));
      h_sa2.stage(L, 1, h_sa2.mk(0, TO_N_X, TO_N_Y, 512));
      @(posedge clk); #1;
      h_sa1.unstage(); h_sa2.unstage();
      // free East and North at the same moment
      @(negedge clk);
      h_sa1.stall(E, 0, 0); h_sa1.stall(E, 1, 0); h_sa1.stall(N, 0, 0); h_sa1.stall(N, 1, 0);
      h_sa2.stall(E, 0, 0); h_sa2.stall(E, 1, 0); h_sa2.stall(N, 0, 0); h_sa2.stall(N, 1, 0);
      h_sa1.idle(8);
      kw_a = h_sa1.find(510); kl_a = h_sa1.find(512);
      kw_b = h_sa2.find(510); kl_b = h_sa2.find(512);
      check("T5 2-pass: loser uses another VC", kw_b >= 0 && kl_b >= 0 && h_sa2.ev_cycle[kl_b] == h_sa2.ev_cycle[kw_b],
            $sformatf("Local's North flit left in the same cycle West won East (cycle %0d)", (kw_b >= 0) ? h_sa2.ev_cycle[kw_b] : -1));
      check("T5 1-pass: North idles that cycle", kw_a >= 0 && kl_a >= 0 && h_sa1.ev_cycle[kl_a] > h_sa1.ev_cycle[kw_a],
            $sformatf("same stimulus, 1 pass: North flit left %0d cycle(s) after West won East",
                      (kw_a >= 0 && kl_a >= 0) ? h_sa1.ev_cycle[kl_a] - h_sa1.ev_cycle[kw_a] : -1));
    end

    // -----------------------------------------------------------------
    // T6: fairness. N, S, W and Local all stream flits to East for 40
    // cycles; round-robin must give each a quarter of East's grants.
    // -----------------------------------------------------------------
    begin
      int got [5];
      int lo, hi;
      int base;
      base = h_1vc.ev_count;
      for (int i = 0; i < 40; i++) begin
        @(negedge clk);
        if (h_1vc.send_credit[N][0] > 0) h_1vc.stage(N, 0, h_1vc.mk(0, TO_E_X, TO_E_Y, 600));
        if (h_1vc.send_credit[S][0] > 0) h_1vc.stage(S, 0, h_1vc.mk(0, TO_E_X, TO_E_Y, 601));
        if (h_1vc.send_credit[W][0] > 0) h_1vc.stage(W, 0, h_1vc.mk(0, TO_E_X, TO_E_Y, 603));
        if (h_1vc.send_credit[L][0] > 0) h_1vc.stage(L, 0, h_1vc.mk(0, TO_E_X, TO_E_Y, 604));
        @(posedge clk); #1;
        h_1vc.unstage();
      end
      h_1vc.idle(12);
      for (int p = 0; p < 5; p++) got[p] = 0;
      for (int i = base; i < h_1vc.ev_count; i++) begin
        if (h_1vc.ev_payload[i] >= 600 && h_1vc.ev_payload[i] <= 604) got[h_1vc.ev_payload[i] - 600]++;
      end
      lo = got[N]; hi = got[N];
      for (int p = 0; p < 5; p++) begin
        if (p != E) begin
          if (got[p] < lo) lo = got[p];
          if (got[p] > hi) hi = got[p];
        end
      end
      check("T6 round-robin fairness", hi - lo <= 1 && lo >= 9,
            $sformatf("East granted N/S/W/Local %0d/%0d/%0d/%0d flits", got[N], got[S], got[W], got[L]));
    end

    // -----------------------------------------------------------------
    // T7: does the VN-isolation checker actually fire? Inject a REQ-class
    // flit into the RSP VC (VC 2) on purpose. (M5 only *detects* this --
    // stopping a tile from doing it is a later milestone's security work.)
    // -----------------------------------------------------------------
    begin
      int viol_before;
      viol_before = assertion_violations;
      h_vn.send1(L, 2, h_vn.mk(MC_REQ, TO_E_X, TO_E_Y, 700));
      h_vn.idle(3);
      check("T7 VN-isolation checker fires", assertion_violations == viol_before + 1,
            $sformatf("a REQ placed in the RSP VC raised exactly %0d violation(s) (expected 1)", assertion_violations - viol_before));
      expected_violations = expected_violations + (assertion_violations - viol_before);
    end

    h_1vc.idle(2);
    check("Harness credit discipline", h_1vc.errors + h_2vc.errors + h_vn.errors + h_vn2.errors + h_sa1.errors + h_sa2.errors == 0,
          "no test ever sent without a credit");
    check("RTL invariants held", assertion_violations == expected_violations,
          $sformatf("%0d violation(s) beyond the one T7 provoked deliberately", assertion_violations - expected_violations));

    $display("================================================================");
    if (fail_count == 0)
      $display(" ALL TESTS PASSED  (%0d/%0d)", pass_count, pass_count + fail_count);
    else
      $display(" %0d TEST(S) FAILED  (%0d passed, %0d failed)", fail_count, pass_count, fail_count);
    $display("================================================================");
    $finish;
  end

  initial begin
    #200000;
    $display("[FAIL] watchdog timeout -- simulation did not finish in time");
    $finish;
  end

endmodule : vc_router_tb
