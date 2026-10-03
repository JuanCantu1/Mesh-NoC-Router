// arb_equiv.sv -- formal equivalence miter: M7's rewritten rr_arbiter vs.
// the M1-M6 original (rr_arbiter_ref.sv), N requesters.
//
// Both arbiters start from reset and see the same, completely
// unconstrained inputs every cycle (req, req_b, advance: any values, any
// sequence). The proof obligation: their grants are identical on every
// cycle after reset.
//
// Why bounded model checking is a COMPLETE proof here: each arbiter's only
// state is its priority pointer, and every reachable pointer value 0..N-1
// is reached one cycle after reset (granting requester v-1 with advance
// set moves the pointer to v). So a few cycles of BMC from reset visit
// every reachable state with every possible input -- there is nothing
// deeper to find. (Plain register-cut equivalence, e.g. eqy's default
// partitioning, would also consider pointer values N..2^PTR_W-1, which
// can never occur and on which the two implementations legitimately
// differ.)

module arb_equiv #(
  parameter int N = 5
) (
  input logic         clk,
  input logic [N-1:0] req,
  input logic [N-1:0] req_b,
  input logic         advance
);

  logic started = 1'b0;           // reset during the first cycle only
  always @(posedge clk) started <= 1'b1;
  wire rst_n = started;

  logic [N-1:0] g_new, gb_new, g_ref, gb_ref;

  rr_arbiter #(.NUM_REQ(N)) u_new (
    .clk(clk), .rst_n(rst_n), .req(req), .advance(advance), .grant(g_new),
    .req_b(req_b), .grant_b(gb_new)
  );
  rr_arbiter_ref #(.NUM_REQ(N)) u_ref (
    .clk(clk), .rst_n(rst_n), .req(req), .advance(advance), .grant(g_ref),
    .req_b(req_b), .grant_b(gb_ref)
  );

  always @(posedge clk) begin
    if (started) begin
      assert (g_new  == g_ref);
      assert (gb_new == gb_ref);
    end
  end

endmodule
