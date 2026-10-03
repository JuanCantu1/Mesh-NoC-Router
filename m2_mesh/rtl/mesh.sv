// mesh.sv
//
// An MESH_W x MESH_H grid of M1 routers, wired together into a real mesh:
// every router's N/S/E/W ports connect to its actual neighbor's opposite
// port (East feeds a neighbor's West, South feeds a neighbor's North),
// and every router's Local port is exposed at this module's boundary so
// a testbench (or, eventually, real compute tiles) can inject and receive
// packets at any grid position.
//
// Coordinate convention (matches router.sv / noc_pkg.sv):
//   X increases going East (columns 0 .. MESH_W-1)
//   Y increases going South (rows    0 .. MESH_H-1)
// Tile numbering for the flattened local_* ports: TILE = Y*MESH_W + X
// (row-major -- row 0's tiles first, left to right, then row 1, ...).
//
// A note on how this is wired: every connection below is a plain
// continuous `assign` between two *constant* (genvar-indexed) port
// slices. That's deliberate, not incidental style -- see router.sv's
// top-of-file note on this Icarus Verilog build's runtime bugs with
// procedural loops that mix struct-field access or array-vs-array
// comparisons with *variable* indices. Nothing here does that: every
// index into every array is a genvar or a genvar-derived localparam,
// resolved at elaboration time, matching the patterns already proven
// safe in router.sv.
//
// IMPORTANT CAVEAT (read before assuming this models real hardware
// timing): M1's routers have no buffering and are purely combinational
// end to end (see router.sv). Wiring many of them directly together, as
// this module does, means a packet can combinationally ripple across
// the *entire* mesh in a single clock cycle if nothing blocks it --
// there is currently no register anywhere between one router's output
// and the next router's input. That's fine for proving XY routing is
// *correct* hop over hop (what M2 verifies), but it is not something
// that would meet timing in real silicon -- the combinational path
// length grows with mesh size. M3's credit-based buffering fixes this
// by putting a real register at every hop.

import noc_pkg::*;

module mesh #(
  parameter int MESH_W = 3,
  parameter int MESH_H = 3
) (
  input  logic clk,
  input  logic rst_n,

  input  logic  [MESH_W*MESH_H-1:0] local_in_valid,
  input  flit_t [MESH_W*MESH_H-1:0] local_in_data,
  output logic  [MESH_W*MESH_H-1:0] local_in_ready,

  output logic  [MESH_W*MESH_H-1:0] local_out_valid,
  output flit_t [MESH_W*MESH_H-1:0] local_out_data,
  input  logic  [MESH_W*MESH_H-1:0] local_out_ready
);

  // Per-router port bundles, one entry per grid position. Each element is
  // exactly the shape of one router's port (a NUM_PORTS-wide packed
  // vector, or a NUM_PORTS-wide packed array of flit_t).
  logic  [NUM_PORTS-1:0] r_in_valid  [MESH_W][MESH_H];
  flit_t [NUM_PORTS-1:0] r_in_data   [MESH_W][MESH_H];
  logic  [NUM_PORTS-1:0] r_in_ready  [MESH_W][MESH_H];
  logic  [NUM_PORTS-1:0] r_out_valid [MESH_W][MESH_H];
  flit_t [NUM_PORTS-1:0] r_out_data  [MESH_W][MESH_H];
  logic  [NUM_PORTS-1:0] r_out_ready [MESH_W][MESH_H];

  // -------------------------------------------------------------------
  // One router per grid position.
  // -------------------------------------------------------------------
  genvar gx, gy;
  generate
    for (gx = 0; gx < MESH_W; gx++) begin : g_col
      for (gy = 0; gy < MESH_H; gy++) begin : g_row
        router #(.X_ID(gx), .Y_ID(gy)) u_router (
          .clk       (clk),
          .rst_n     (rst_n),
          .in_valid  (r_in_valid[gx][gy]),
          .in_data   (r_in_data[gx][gy]),
          .in_ready  (r_in_ready[gx][gy]),
          .out_valid (r_out_valid[gx][gy]),
          .out_data  (r_out_data[gx][gy]),
          .out_ready (r_out_ready[gx][gy])
        );
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Horizontal links: router (hx,hy)'s East <-> router (hx+1,hy)'s West.
  // -------------------------------------------------------------------
  genvar hx, hy;
  generate
    for (hx = 0; hx < MESH_W-1; hx++) begin : g_hlink_x
      for (hy = 0; hy < MESH_H; hy++) begin : g_hlink_y
        assign r_in_data [hx+1][hy][PORT_W] = r_out_data [hx][hy][PORT_E];
        assign r_in_valid[hx+1][hy][PORT_W] = r_out_valid[hx][hy][PORT_E];
        assign r_out_ready[hx][hy][PORT_E]  = r_in_ready [hx+1][hy][PORT_W];

        assign r_in_data [hx][hy][PORT_E]   = r_out_data [hx+1][hy][PORT_W];
        assign r_in_valid[hx][hy][PORT_E]   = r_out_valid[hx+1][hy][PORT_W];
        assign r_out_ready[hx+1][hy][PORT_W] = r_in_ready[hx][hy][PORT_E];
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Vertical links: router (vx,vy)'s South <-> router (vx,vy+1)'s North.
  // (vy+1 is further South, per this project's Y-increases-South convention.)
  // -------------------------------------------------------------------
  genvar vx, vy;
  generate
    for (vx = 0; vx < MESH_W; vx++) begin : g_vlink_x
      for (vy = 0; vy < MESH_H-1; vy++) begin : g_vlink_y
        assign r_in_data [vx][vy+1][PORT_N] = r_out_data [vx][vy][PORT_S];
        assign r_in_valid[vx][vy+1][PORT_N] = r_out_valid[vx][vy][PORT_S];
        assign r_out_ready[vx][vy][PORT_S]  = r_in_ready [vx][vy+1][PORT_N];

        assign r_in_data [vx][vy][PORT_S]   = r_out_data [vx][vy+1][PORT_N];
        assign r_in_valid[vx][vy][PORT_S]   = r_out_valid[vx][vy+1][PORT_N];
        assign r_out_ready[vx][vy+1][PORT_N] = r_in_ready[vx][vy][PORT_S];
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Edge tie-offs: a port facing off the edge of the grid has no
  // neighbor. Nothing is ever sending it a packet (in_valid held low),
  // and it's always free to accept whatever it's (never) sent
  // (out_ready held high) -- XY routing never legitimately tries to
  // leave the grid as long as every injected packet's destination is a
  // real, in-range tile, so out_valid on these ports should stay low in
  // every test in this milestone.
  // -------------------------------------------------------------------
  genvar ex, ey;
  generate
    for (ey = 0; ey < MESH_H; ey++) begin : g_tie_ew
      assign r_in_valid[0][ey][PORT_W]        = 1'b0;
      assign r_in_data [0][ey][PORT_W]        = '0;
      assign r_out_ready[0][ey][PORT_W]       = 1'b1;

      assign r_in_valid[MESH_W-1][ey][PORT_E] = 1'b0;
      assign r_in_data [MESH_W-1][ey][PORT_E] = '0;
      assign r_out_ready[MESH_W-1][ey][PORT_E] = 1'b1;
    end
    for (ex = 0; ex < MESH_W; ex++) begin : g_tie_ns
      assign r_in_valid[ex][0][PORT_N]        = 1'b0;
      assign r_in_data [ex][0][PORT_N]        = '0;
      assign r_out_ready[ex][0][PORT_N]       = 1'b1;

      assign r_in_valid[ex][MESH_H-1][PORT_S] = 1'b0;
      assign r_in_data [ex][MESH_H-1][PORT_S] = '0;
      assign r_out_ready[ex][MESH_H-1][PORT_S] = 1'b1;
    end
  endgenerate

  // -------------------------------------------------------------------
  // Local ports: expose every router's Local port at this module's
  // boundary, flattened to one bit / one flit per tile. TILE = Y*MESH_W+X.
  // -------------------------------------------------------------------
  genvar lx, ly;
  generate
    for (lx = 0; lx < MESH_W; lx++) begin : g_local_x
      for (ly = 0; ly < MESH_H; ly++) begin : g_local_y
        localparam int TILE = ly*MESH_W + lx;

        assign r_in_valid[lx][ly][PORT_L] = local_in_valid[TILE];
        assign r_in_data [lx][ly][PORT_L] = local_in_data[TILE];
        assign local_in_ready[TILE]       = r_in_ready[lx][ly][PORT_L];

        assign local_out_valid[TILE]      = r_out_valid[lx][ly][PORT_L];
        assign local_out_data[TILE]       = r_out_data[lx][ly][PORT_L];
        assign r_out_ready[lx][ly][PORT_L] = local_out_ready[TILE];
      end
    end
  endgenerate

endmodule : mesh
