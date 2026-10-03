// router.sv
//
// A 5-port mesh router with REAL credit-based flow control -- the M3
// milestone. This replaces M1/M2's valid/ready handshake (where a
// rejected packet just sits on the sender's output, re-offered every
// cycle, with no storage anywhere in the router) with the mechanism real
// interconnects actually use: every input port now has a small buffer
// (flit_fifo.sv), and every output port tracks, via a credit counter, how
// much room is left in whatever is downstream of it. A sender only ever
// transmits when it knows -- from its own local credit count, not by
// asking -- that there's a free slot waiting for it.
//
// Port protocol, per direction:
//   Forward  (sender -> receiver): valid, data           -- unchanged in
//     spirit from M1/M2, except the sender no longer needs to hold valid
//     and keep re-driving data if it's not immediately accepted -- it's
//     buffered here now.
//   Backward (receiver -> sender): credit_return          -- a single-cycle
//     pulse meaning "I just freed a buffer slot you were using; you may
//     send me one more flit than you thought you could."
// There is no `ready` signal anymore. That's the point: the sender never
// has to ask, because it always already knows via its own credit counter.
//
// Port numbering (see noc_pkg::port_e): 0=N, 1=S, 2=E, 3=W, 4=Local.
//
// Same Icarus-workaround discipline as M1/M2's router.sv: every array
// index that can vary at runtime is either (a) a genvar/localparam,
// resolved at elaboration time, or (b) used in exactly the shapes already
// proven safe there (a single procedural loop copying one array element
// to a local variable before using it, never a nested loop comparing two
// loop-variable-indexed reads, never a struct field chained directly off
// a variable index without an intermediate copy).

import noc_pkg::*;

module router #(
  parameter int X_ID = 0,          // this router's column in the mesh
  parameter int Y_ID = 0,          // this router's row in the mesh
  parameter int BUFFER_DEPTH = 4   // flits held per input port before backpressure
) (
  input  logic clk,
  input  logic rst_n,

  // Input side of each port: a neighbor (or the local node) sends a flit
  // whenever it wants -- it's trusted to only do so when it believes it
  // has credit. This router buffers it and, exactly when the buffer
  // slot it used is freed again (the flit is forwarded onward), pulses
  // in_credit_return back so the sender's own counter stays in sync.
  input  logic  [NUM_PORTS-1:0] in_valid,
  input  flit_t [NUM_PORTS-1:0] in_data,
  output logic  [NUM_PORTS-1:0] in_credit_return,

  // Output side of each port: this router sends only when its own
  // credit counter for that port is nonzero, and relies on
  // out_credit_return pulses from whatever is downstream to know when
  // it's earned the right to send another.
  output logic  [NUM_PORTS-1:0] out_valid,
  output flit_t [NUM_PORTS-1:0] out_data,
  input  logic  [NUM_PORTS-1:0] out_credit_return
);

  localparam int CREDIT_W = $clog2(BUFFER_DEPTH+1);

  // -------------------------------------------------------------------
  // Step 1: one small FIFO per input port. A flit that arrives is pushed
  // immediately; it leaves only once it's actually granted an output
  // this cycle (Step 4's pop_grant). fifo_head_data[p] is always the
  // oldest flit still waiting at port p (garbage/don't-care when empty).
  // -------------------------------------------------------------------
  logic  [NUM_PORTS-1:0] fifo_empty;
  logic  [NUM_PORTS-1:0] fifo_full;
  flit_t [NUM_PORTS-1:0] fifo_head_data;
  logic  [NUM_PORTS-1:0] pop_grant; // driven by Step 4 below

  genvar gp;
  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_fifo
      flit_fifo #(.DEPTH(BUFFER_DEPTH)) u_fifo (
        .clk       (clk),
        .rst_n     (rst_n),
        .push_en   (in_valid[gp]),
        .push_data (in_data[gp]),
        .full      (fifo_full[gp]),
        .pop_en    (pop_grant[gp]),
        .pop_data  (fifo_head_data[gp]),
        .empty     (fifo_empty[gp])
      );

      // Exactly one freed slot per pop -- exactly one credit back.
      assign in_credit_return[gp] = pop_grant[gp];
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 2: routing decision for whatever is currently at the head of
  // each input's FIFO. Same XY dimension-order routing as M1/M2.
  // -------------------------------------------------------------------
  logic [2:0] route_sel [NUM_PORTS];

  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_route
      flit_t f;
      assign f = fifo_head_data[gp];

      always_comb begin
        if (f.dest_x > X_ID)      route_sel[gp] = 3'(PORT_E);
        else if (f.dest_x < X_ID) route_sel[gp] = 3'(PORT_W);
        else if (f.dest_y > Y_ID) route_sel[gp] = 3'(PORT_S);
        else if (f.dest_y < Y_ID) route_sel[gp] = 3'(PORT_N);
        else                      route_sel[gp] = 3'(PORT_L); // arrived
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 3: per-output credit counters. Reset to BUFFER_DEPTH (matching
  // a downstream buffer that starts empty). Decrements exactly when this
  // router sends on that port; increments exactly when downstream tells
  // us it freed a slot. Both in the same cycle nets to no change.
  // Only a request backed by credit_count > 0 is ever allowed to become
  // a grant (Step 5), so this can never be sent below zero -- there is
  // no separate "leak" path for it to drift out of [0, BUFFER_DEPTH].
  // -------------------------------------------------------------------
  logic [CREDIT_W-1:0] credit_count [NUM_PORTS];

  genvar gc;
  generate
    for (gc = 0; gc < NUM_PORTS; gc++) begin : g_credit
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          credit_count[gc] <= BUFFER_DEPTH;
        end else begin
          case ({out_valid[gc], out_credit_return[gc]})
            2'b10:   credit_count[gc] <= credit_count[gc] - 1'b1;
            2'b01:   credit_count[gc] <= credit_count[gc] + 1'b1;
            default: credit_count[gc] <= credit_count[gc];
          endcase
        end
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 4: for each output port, which input ports are asking for it?
  // A request is only formed when there's actually a flit waiting
  // (fifo not empty) AND that output currently has credit to send it.
  // Same genvar-only-indexed double generate as M1/M2's req_mat, for the
  // same reason: comparing two loop-variable-indexed values inside a
  // *procedural* nested loop was found to corrupt simulation on this
  // Icarus build.
  // -------------------------------------------------------------------
  logic [NUM_PORTS-1:0] req_mat  [NUM_PORTS];
  logic [NUM_PORTS-1:0] grant_mat[NUM_PORTS];

  genvar go, gq;
  generate
    for (go = 0; go < NUM_PORTS; go++) begin : g_req_o
      for (gq = 0; gq < NUM_PORTS; gq++) begin : g_req_p
        assign req_mat[go][gq] = !fifo_empty[gq]
                                  && (route_sel[gq] == go[2:0])
                                  && (credit_count[go] > 0);
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 5: one round-robin arbiter per output port, and the winning
  // input's data muxed onto that output. Because a request already
  // required credit to exist, every grant here unconditionally sends --
  // there's no separate downstream-not-ready case left to handle, so the
  // arbiter's pointer advances on every grant (`advance` = `out_valid`).
  // -------------------------------------------------------------------
  genvar o;
  generate
    for (o = 0; o < NUM_PORTS; o++) begin : g_out
      rr_arbiter #(.NUM_REQ(NUM_PORTS)) u_arb (
        .clk     (clk),
        .rst_n   (rst_n),
        .req     (req_mat[o]),
        .advance (out_valid[o]),
        .grant   (grant_mat[o])
      );

      assign out_valid[o] = |req_mat[o];

      always_comb begin
        out_data[o] = '0;
        for (int p = 0; p < NUM_PORTS; p++) begin
          if (grant_mat[o][p]) out_data[o] = fifo_head_data[p];
        end
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 6: tell each input's FIFO whether it was popped (granted some
  // output) this cycle. Same shape as M1's in_ready computation (single
  // procedural loop, one local copy per iteration, no loop-variable
  // struct chaining) -- proven safe on this toolchain.
  // -------------------------------------------------------------------
  always_comb begin
    for (int p = 0; p < NUM_PORTS; p++) begin
      int tgt;
      tgt = route_sel[p];
      pop_grant[p] = grant_mat[tgt][p];
    end
  end

endmodule : router
