`timescale 1ns/1ps
// flit_fifo.sv
//
// A small circular-buffer FIFO holding flit_t entries. In M5 every input
// port has one of these PER VIRTUAL CHANNEL, each with its own credit loop.
//
// Unchanged from M4 except for one new invariant: pushing into a full FIFO
// is now flagged, not silently ignored. Under credit-based flow control a
// sender only transmits with a credit in hand, so a push into a full
// buffer means some sender's credit count is wrong -- and the flit would
// be lost. M4 caught that indirectly (its credit-bound check at the
// sender); this catches it at the buffer, whoever the sender is.

import noc_pkg::*;

module flit_fifo #(
  parameter int DEPTH = 4,
  parameter int TAG_W = 1   // M7: side-band bits stored with each flit (the router keeps the
                            // flit's precomputed route here); tie off when unused
) (
  input  logic  clk,
  input  logic  rst_n,

  input  logic  push_en,
  input  flit_t push_data,
  input  logic  [TAG_W-1:0] push_tag,
  output logic  full,

  input  logic  pop_en,
  output flit_t pop_data,
  output logic  [TAG_W-1:0] pop_tag,
  output logic  empty
);

  localparam int PTR_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int LAST_I = DEPTH - 1;
  localparam logic [PTR_W-1:0] LAST = LAST_I[PTR_W-1:0]; // index of the last slot

  flit_t [DEPTH-1:0]   mem;
  logic  [TAG_W-1:0]   tag_mem [DEPTH];
  logic  [PTR_W-1:0]   head, tail;
  logic  [PTR_W:0]     count; // one extra bit: needs to represent DEPTH itself

  assign empty    = (count == '0);
  assign full     = (count == DEPTH[PTR_W:0]);
  assign pop_data = mem[head];
  assign pop_tag  = tag_mem[head];

  // M7: storage has no reset. The pointers and count already make the
  // contents of an empty FIFO irrelevant, and a flop without reset is a
  // smaller cell -- in M6, mem shared the pointers' async-reset block, so
  // synthesis saw an async reset with no reset value (Yosys warned).
  always_ff @(posedge clk) begin
    if (push_en && !full) begin
      mem[tail]     <= push_data;
      tag_mem[tail] <= push_tag;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      head  <= '0;
      tail  <= '0;
      count <= '0;
    end else begin
      if (push_en && !full) begin
        tail <= (tail == LAST) ? '0 : tail + 1'b1;
      end
      if (pop_en && !empty) begin
        head <= (head == LAST) ? '0 : head + 1'b1;
      end

      case ({(push_en && !full), (pop_en && !empty)})
        2'b10:   count <= count + 1'b1;
        2'b01:   count <= count - 1'b1;
        default: count <= count; // both or neither: net occupancy unchanged
      endcase
    end
  end

  // Verification-only invariants (see noc_pkg::assertion_violations).
`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (rst_n) begin
      assert (int'(count) <= DEPTH) else begin
        $display("ASSERT-FAIL: flit_fifo count=%0d exceeds DEPTH=%0d", count, DEPTH);
        assertion_violations = assertion_violations + 1;
      end
      assert (!(push_en && full)) else begin
        $display("ASSERT-FAIL: flit_fifo push while full -- a sender transmitted without credit; flit lost");
        assertion_violations = assertion_violations + 1;
      end
    end
  end
`endif

endmodule : flit_fifo
