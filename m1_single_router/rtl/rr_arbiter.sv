// rr_arbiter.sv
//
// A round-robin arbiter: given a vector of "requesters" that all want the
// same resource this cycle, pick exactly one winner (one-hot grant), and
// remember who won so that next time a *different* requester gets first
// priority. Without this, a naive fixed-priority scheme (e.g. "port 0
// always wins ties") would let one input port starve the others forever
// whenever they collide on the same output -- a real fairness/liveness bug
// in an arbiter, not just a style nit.
//
// This module is deliberately generic (not NoC-specific) so it can be
// reused for every output port's arbiter inside router.sv.

module rr_arbiter #(
  parameter int NUM_REQ = 5
) (
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic [NUM_REQ-1:0]    req,     // one bit per requester, level-driven
  input  logic                  advance, // pulse: the current grant was actually used
  output logic [NUM_REQ-1:0]    grant    // one-hot (or all-zero if no requesters)
);

  localparam int PTR_W = (NUM_REQ <= 1) ? 1 : $clog2(NUM_REQ);

  // ptr = index of the requester with the *highest* priority this cycle.
  // After a granted requester is actually served (advance=1), priority
  // rotates to the requester just after it, so everyone gets a turn.
  logic [PTR_W-1:0] ptr, ptr_n;

  logic [PTR_W-1:0] win_idx;
  logic             found;

  // NOTE: Icarus Verilog does not support indexed bit-select (req[idx] /
  // grant[idx]) with a runtime-variable idx inside an always_comb/always_ff
  // process, so the requester bit is read and the one-hot grant is built
  // using shifts instead of indexed selects.
  always_comb begin
    found   = 1'b0;
    win_idx = '0;
    // Walk the requesters starting at ptr and wrapping around, taking the
    // first one that's actually asking. This is the classic "rotating
    // priority" scan that makes round-robin arbitration fair over time.
    for (int i = 0; i < NUM_REQ; i++) begin
      int   idx;
      logic bit_req;
      idx     = (int'(ptr) + i) % NUM_REQ;
      bit_req = (req >> idx) & 1'b1;
      if (!found && bit_req) begin
        found   = 1'b1;
        win_idx = idx; // implicit truncation to PTR_W bits, idx is always < NUM_REQ
      end
    end
    grant = found ? ({{(NUM_REQ-1){1'b0}}, 1'b1} << win_idx) : '0;
  end

  always_comb begin
    ptr_n = ptr;
    if (advance && found) begin
      ptr_n = (win_idx == NUM_REQ-1) ? '0 : win_idx + 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ptr <= '0;
    else        ptr <= ptr_n;
  end

endmodule : rr_arbiter
