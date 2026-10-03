`timescale 1ns/1ps
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
// Generic (not NoC-specific); vc_router uses it for every arbiter.
//
// req_b/grant_b (M5): a second request set scanned with the SAME priority
// pointer, which never moves it -- vc_router's second switch-allocation
// pass. Tie req_b to '0 when unused.
//
// M7: rewritten for timing, same function. M1-M6 found the winner with a
// loop that rotated the request vector by a variable amount, one requester
// at a time ((ptr + i) % NUM_REQ, then a variable shift) -- in hardware a
// chain of barrel shifters, and synthesis put it on the router's critical
// path. This is the standard masked form instead:
//
//     high  = req & {bits at positions >= ptr}      ("thermometer" mask)
//     grant = lowest set bit of high, if any;        -- first requester at or after ptr
//             else lowest set bit of req              -- wrap around to the start
//     lowest set bit of x  =  x & (~x + 1)           (two's complement trick)
//
// The grant function is identical to M6's for every req and ptr: proved
// formally, not just simulated -- see formal/README and tools/formal.sh.

module rr_arbiter #(
  parameter int NUM_REQ = 5
) (
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic [NUM_REQ-1:0]    req,     // one bit per requester, level-driven
  input  logic                  advance, // pulse: the current grant was actually used
  output logic [NUM_REQ-1:0]    grant,   // one-hot (or all-zero if no requesters)

  input  logic [NUM_REQ-1:0]    req_b,   // second request set, same priority order
  output logic [NUM_REQ-1:0]    grant_b  // one-hot winner of req_b; never moves the pointer
);

  localparam int PTR_W  = (NUM_REQ <= 1) ? 1 : $clog2(NUM_REQ);
  localparam int LAST_I = NUM_REQ - 1;
  localparam logic [PTR_W-1:0] LAST = LAST_I[PTR_W-1:0]; // index of the last requester

  // ptr = index of the requester with the *highest* priority this cycle.
  // After a granted requester is actually served (advance=1), priority
  // rotates to the requester just after it, so everyone gets a turn.
  logic [PTR_W-1:0]   ptr, ptr_n;
  logic [NUM_REQ-1:0] mask;      // 1 at every position >= ptr
  logic [NUM_REQ-1:0] high, high_b;
  logic [PTR_W-1:0]   win_idx;
  logic               found;

  assign mask = ~(({{(NUM_REQ-1){1'b0}}, 1'b1} << ptr) - 1'b1);

  assign high   = req   & mask;
  assign grant  = (|high)   ? (high   & (~high   + 1'b1)) : (req   & (~req   + 1'b1));

  // Pass 2 uses the same pointer. A separate set of wires, not shared logic
  // with `grant`: in vc_router req_b depends on grant through the rest of
  // the allocator, so they must not share a process (a false loop).
  assign high_b  = req_b & mask;
  assign grant_b = (|high_b) ? (high_b & (~high_b + 1'b1)) : (req_b & (~req_b + 1'b1));

  // Index of the (one-hot) winner, for the pointer update. One-hot to
  // binary: index bit b is the OR of the grant bits whose position has bit
  // b set (flat logic, no chain).
  assign found = |grant;
  genvar b, g;
  generate
    for (b = 0; b < PTR_W; b++) begin : g_enc
      logic [NUM_REQ-1:0] pick;
      for (g = 0; g < NUM_REQ; g++) begin : g_pos
        assign pick[g] = (((g >> b) & 1) != 0) && grant[g];
      end
      assign win_idx[b] = |pick;
    end
  endgenerate

  always_comb begin
    ptr_n = ptr;
    if (advance && found) begin
      ptr_n = (win_idx == LAST) ? '0 : win_idx + 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ptr <= '0;
    else        ptr <= ptr_n;
  end

endmodule : rr_arbiter
