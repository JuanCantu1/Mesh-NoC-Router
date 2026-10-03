// flit_fifo.sv
//
// A small circular-buffer FIFO holding flit_t entries -- the per-input-port
// buffer that makes credit-based flow control possible. Without this, a
// router has nowhere to put a flit that's arrived but hasn't won
// arbitration yet (that's the M1/M2 situation: no buffer, so the *sender*
// has to keep holding the flit and re-offering it every cycle). With a
// buffer here, the sender can fire-and-forget as soon as it has credit,
// and this FIFO holds the flit until the router can actually forward it.
//
// Deliberately specific to flit_t (not a generic parameterized-width FIFO)
// -- this project has exactly one data type in flight, and a generic
// `parameter type` FIFO isn't worth the added risk on an Icarus build that
// has already shown real bugs around less exotic array/struct handling.

import noc_pkg::*;

module flit_fifo #(
  parameter int DEPTH = 4
) (
  input  logic  clk,
  input  logic  rst_n,

  input  logic  push_en,
  input  flit_t push_data,
  output logic  full,

  input  logic  pop_en,
  output flit_t pop_data,
  output logic  empty
);

  localparam int PTR_W = $clog2(DEPTH);

  flit_t [DEPTH-1:0]   mem;
  logic  [PTR_W-1:0]   head, tail;
  logic  [PTR_W:0]     count; // one extra bit: needs to represent DEPTH itself

  assign empty    = (count == '0);
  assign full     = (count == DEPTH[PTR_W:0]);
  assign pop_data = mem[head];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      head  <= '0;
      tail  <= '0;
      count <= '0;
    end else begin
      if (push_en && !full) begin
        mem[tail] <= push_data;
        tail      <= (tail == DEPTH-1) ? '0 : tail + 1'b1;
      end
      if (pop_en && !empty) begin
        head <= (head == DEPTH-1) ? '0 : head + 1'b1;
      end

      case ({(push_en && !full), (pop_en && !empty)})
        2'b10:   count <= count + 1'b1;
        2'b01:   count <= count - 1'b1;
        default: count <= count; // both or neither: net occupancy unchanged
      endcase
    end
  end

  // Verification-only invariant: occupancy can never exceed physical
  // capacity or go negative (count is unsigned, so "negative" would show
  // up as a wraparound to a huge value instead -- this catches that too).
  // See noc_pkg::assertion_violations for why this is a counter and not
  // a concurrent `assert property`.
  always_ff @(posedge clk) begin
    if (rst_n) begin
      assert (count <= DEPTH) else begin
        $display("ASSERT-FAIL: flit_fifo count=%0d exceeds DEPTH=%0d", count, DEPTH);
        assertion_violations = assertion_violations + 1;
      end
    end
  end

endmodule : flit_fifo
