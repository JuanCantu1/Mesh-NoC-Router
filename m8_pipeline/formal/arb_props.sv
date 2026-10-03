// arb_props.sv -- formal properties of rr_arbiter (N requesters), proved
// for ALL input sequences by k-induction (SymbiYosys), as real concurrent
// SystemVerilog assertions -- the `assert property` that M4 had to replace
// with counters because Icarus can't parse it.
//
//   P1  grants only go to requesters               (grant is a subset of req)
//   P2  at most one grant                          ($onehot0)
//   P3  work-conserving: anyone asks -> someone wins
//   P4  pass 2 obeys P1-P3 for req_b
//   P5  FAIRNESS: a requester that keeps asking is granted within N cycles,
//       when every grant is used (advance = "there was a winner" -- how the
//       output arbiters in vc_router are driven). M4 checked this bound in
//       simulation, for the traffic that happened to run; this proves it
//       for every possible request pattern.

module arb_props #(
  parameter int N = 5
) (
  input logic         clk,
  input logic [N-1:0] req,
  input logic [N-1:0] req_b
);

  logic started = 1'b0;
  always @(posedge clk) started <= 1'b1;
  wire rst_n = started;

  logic [N-1:0] grant, grant_b;
  wire advance = |grant;  // every grant is used

  rr_arbiter #(.NUM_REQ(N)) dut (
    .clk(clk), .rst_n(rst_n), .req(req), .advance(advance), .grant(grant),
    .req_b(req_b), .grant_b(grant_b)
  );

  // P1-P4: combinational, every cycle after reset.
  p1_subset:    assert property (@(posedge clk) disable iff (!rst_n) (grant & ~req) == '0);
  p2_onehot:    assert property (@(posedge clk) disable iff (!rst_n) $onehot0(grant));
  p3_conserve:  assert property (@(posedge clk) disable iff (!rst_n) !(|req) || (|grant));
  p4_subset_b:  assert property (@(posedge clk) disable iff (!rst_n) (grant_b & ~req_b) == '0);
  p4_onehot_b:  assert property (@(posedge clk) disable iff (!rst_n) $onehot0(grant_b));
  p4_conserve_b:assert property (@(posedge clk) disable iff (!rst_n) !(|req_b) || (|grant_b));

  // P5: per requester, count consecutive cycles asking without winning.
  genvar i;
  generate
    for (i = 0; i < N; i++) begin : g_fair
      logic [7:0] waited = '0;
      always @(posedge clk) begin
        if (!rst_n || !req[i] || grant[i]) waited <= '0;
        else                               waited <= waited + 1'b1;
      end
      // Bound: at most N-1 others can be served ahead of it.
      p5_fair: assert property (@(posedge clk) disable iff (!rst_n) waited < N);
    end
  endgenerate

endmodule
