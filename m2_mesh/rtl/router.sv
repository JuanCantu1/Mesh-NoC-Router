// router.sv
//
// A single 5-port mesh router: North, South, East, West, and Local.
// This is the M1 milestone -- one router in isolation, no neighbors wired
// up yet (that's M2), and no input buffering or credits yet (that's M3).
//
// What it does, in plain terms:
//   1. Every input port that has a packet waiting looks at that packet's
//      destination (dest_x, dest_y) and this router's own position
//      (X_ID, Y_ID), and decides which output port the packet needs to
//      leave on. This is "XY dimension-order routing" -- see g_route below.
//   2. It's possible for two (or more) input ports to decide they both
//      need the *same* output port in the same cycle. Only one packet can
//      leave a given output port per cycle, so a round-robin arbiter
//      (rr_arbiter.sv) picks a fair winner among the requesters.
//   3. The winning packet is muxed onto that output port combinationally
//      -- there's no storage in this router yet, so a packet that isn't
//      granted must simply be held by whoever is driving it (that's what
//      the valid/ready handshake contract requires of the sender).
//
// Port numbering (see noc_pkg::port_e): 0=N, 1=S, 2=E, 3=W, 4=Local.
//
// A note on coding style below: Steps 1 and 2 use generate/genvar loops
// where a plain procedural `for` loop would be more natural SystemVerilog.
// That's a workaround, not a preference -- this Icarus Verilog build
// (12.0-devel) has runtime (not just compile-time) bugs when a procedural
// for-loop reads a packed-struct field, or compares two loop-variable-
// indexed array reads against each other, inside always_comb. Both were
// confirmed to actually corrupt simulation (vvp crashes with an internal
// assertion a few clock edges in) rather than just misbehave, so they're
// avoided rather than papered over. Steps 3 and 4 use plain procedural
// loops, since those specific shapes tested clean. If a future Icarus
// release fixes this, Steps 1 and 2 can revert to plain for loops too.

import noc_pkg::*;

module router #(
  parameter int X_ID = 0,   // this router's column in the mesh
  parameter int Y_ID = 0    // this router's row in the mesh
) (
  input  logic clk,
  input  logic rst_n,

  // Input side of each port: a neighbor (or the local node) is trying to
  // send this router a packet.
  //
  // NOTE: in_data/out_data are declared as PACKED arrays of flit_t
  // (`flit_t [NUM_PORTS-1:0]`), not unpacked (`flit_t x [NUM_PORTS]`).
  // This Icarus build has a bug where an *unpacked* array-of-struct output
  // port, written from inside a generate block, silently fails to
  // propagate its value to the parent module (reads as 'x from outside,
  // even though the value is correct when inspected hierarchically inside
  // the submodule). Packed-array ports do not have this problem.
  input  logic  [NUM_PORTS-1:0] in_valid,
  input  flit_t [NUM_PORTS-1:0] in_data,
  output logic  [NUM_PORTS-1:0] in_ready,

  // Output side of each port: this router is trying to send a packet to
  // a neighbor (or the local node).
  output logic  [NUM_PORTS-1:0] out_valid,
  output flit_t [NUM_PORTS-1:0] out_data,
  input  logic  [NUM_PORTS-1:0] out_ready
);

  // -------------------------------------------------------------------
  // Step 1: routing decision, one per input port.
  //
  // XY dimension-order routing: first fix up the X (column) position by
  // always going East or West, and only once X is correct do we ever move
  // in Y (North/South). This fixed order is what makes XY routing
  // deadlock-free in a mesh -- packets never build a cyclic dependency
  // waiting on each other, because everything resolves X before Y.
  //
  // route_sel[p] holds the target output port index (0..4) for whatever
  // packet is currently sitting on input port p.
  // -------------------------------------------------------------------
  logic [2:0] route_sel [NUM_PORTS];

  genvar gp;
  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_route
      // Bind this port's flit to a plain (non-array) local signal first --
      // this Icarus build has a runtime bug when a struct-field select is
      // chained directly off a runtime-indexed array read inside a
      // procedural loop; a genvar-indexed (compile-time constant) local
      // signal sidesteps it.
      flit_t f;
      assign f = in_data[gp];

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
  // Step 2: for each output port, which input ports are asking for it?
  // req_mat[o] is a bit-vector over input ports, one bit per requester.
  //
  // Built with a fully genvar-indexed (compile-time constant) double
  // generate loop instead of a procedural nested `for` loop -- comparing
  // two runtime loop-variable-indexed values against each other inside a
  // nested procedural loop crashed vvp at simulation time on this build.
  // -------------------------------------------------------------------
  logic [NUM_PORTS-1:0] req_mat  [NUM_PORTS];
  logic [NUM_PORTS-1:0] grant_mat[NUM_PORTS];

  genvar go, gq;
  generate
    for (go = 0; go < NUM_PORTS; go++) begin : g_req_o
      for (gq = 0; gq < NUM_PORTS; gq++) begin : g_req_p
        assign req_mat[go][gq] = in_valid[gq] && (route_sel[gq] == go[2:0]);
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 3: one round-robin arbiter per output port picks the winner
  // among that output's requesters, and the winning input's data is
  // muxed onto that output.
  // -------------------------------------------------------------------
  genvar o;
  generate
    for (o = 0; o < NUM_PORTS; o++) begin : g_out
      rr_arbiter #(.NUM_REQ(NUM_PORTS)) u_arb (
        .clk     (clk),
        .rst_n   (rst_n),
        .req     (req_mat[o]),
        .advance (out_valid[o] && out_ready[o]),
        .grant   (grant_mat[o])
      );

      assign out_valid[o] = |req_mat[o];

      always_comb begin
        out_data[o] = '0;
        for (int p = 0; p < NUM_PORTS; p++) begin
          if (grant_mat[o][p]) out_data[o] = in_data[p];
        end
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 4: tell each input port whether its packet was accepted this
  // cycle. An input is "ready" (accepted) only if it won arbitration for
  // its requested output AND the far side of that output is ready too --
  // both halves of the handshake have to be true in the same cycle.
  // -------------------------------------------------------------------
  always_comb begin
    for (int p = 0; p < NUM_PORTS; p++) begin
      int tgt;
      tgt = route_sel[p];
      in_ready[p] = in_valid[p] && grant_mat[tgt][p] && out_ready[tgt];
    end
  end

endmodule : router
