// mesh_credit.sv
//
// An MESH_W x MESH_H grid of M3's credit-based routers, wired together --
// the credit-flow-control counterpart of M2's mesh.sv. Every router's
// N/S/E/W ports connect to its real neighbor's opposite port, same as M2,
// except the backward signal carried on each link is now a credit_return
// pulse instead of a ready level, matching router.sv's M3 port protocol.
//
// Coordinate convention (unchanged from M1/M2): X increases East, Y
// increases South. Tile numbering for the flattened local_* ports:
// TILE = Y*MESH_W + X.
//
// Every connection below is a continuous `assign` between constant
// (genvar-indexed) port slices, for the same reason documented at the top
// of router.sv and mesh.sv: this Icarus build has runtime bugs when an
// array is indexed by something other than a genvar/localparam in certain
// shapes. Nothing here does that.
//
// Unlike M2's mesh, this one gives a multi-hop packet *real* per-hop
// latency: each router's input FIFO is a register, so a flit spends at
// least one clock edge at every hop rather than rippling combinationally
// across the whole grid in a single cycle. That's the whole point of
// bringing M3's router into the mesh -- M4's latency/throughput
// measurements are only meaningful against a network that actually has
// latency to measure.

import noc_pkg::*;

module mesh_credit #(
  parameter int MESH_W = 3,
  parameter int MESH_H = 3,
  parameter int BUFFER_DEPTH = 4
) (
  input  logic clk,
  input  logic rst_n,

  input  logic  [MESH_W*MESH_H-1:0] local_in_valid,
  input  flit_t [MESH_W*MESH_H-1:0] local_in_data,
  output logic  [MESH_W*MESH_H-1:0] local_in_credit_return,

  output logic  [MESH_W*MESH_H-1:0] local_out_valid,
  output flit_t [MESH_W*MESH_H-1:0] local_out_data,
  input  logic  [MESH_W*MESH_H-1:0] local_out_credit_return
);

  // Per-router port bundles, one entry per grid position.
  logic  [NUM_PORTS-1:0] r_in_valid         [MESH_W][MESH_H];
  flit_t [NUM_PORTS-1:0] r_in_data          [MESH_W][MESH_H];
  logic  [NUM_PORTS-1:0] r_in_credit_return [MESH_W][MESH_H];
  logic  [NUM_PORTS-1:0] r_out_valid        [MESH_W][MESH_H];
  flit_t [NUM_PORTS-1:0] r_out_data         [MESH_W][MESH_H];
  logic  [NUM_PORTS-1:0] r_out_credit_return[MESH_W][MESH_H];

  // -------------------------------------------------------------------
  // One credit-based router per grid position.
  // -------------------------------------------------------------------
  genvar gx, gy;
  generate
    for (gx = 0; gx < MESH_W; gx++) begin : g_col
      for (gy = 0; gy < MESH_H; gy++) begin : g_row
        router #(.X_ID(gx), .Y_ID(gy), .BUFFER_DEPTH(BUFFER_DEPTH)) u_router (
          .clk               (clk),
          .rst_n             (rst_n),
          .in_valid          (r_in_valid[gx][gy]),
          .in_data           (r_in_data[gx][gy]),
          .in_credit_return  (r_in_credit_return[gx][gy]),
          .out_valid         (r_out_valid[gx][gy]),
          .out_data          (r_out_data[gx][gy]),
          .out_credit_return (r_out_credit_return[gx][gy])
        );
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Horizontal links: router (hx,hy)'s East <-> router (hx+1,hy)'s West.
  // Forward: valid/data. Backward: credit_return (replaces M2's ready).
  // -------------------------------------------------------------------
  genvar hx, hy;
  generate
    for (hx = 0; hx < MESH_W-1; hx++) begin : g_hlink_x
      for (hy = 0; hy < MESH_H; hy++) begin : g_hlink_y
        assign r_in_data [hx+1][hy][PORT_W] = r_out_data [hx][hy][PORT_E];
        assign r_in_valid[hx+1][hy][PORT_W] = r_out_valid[hx][hy][PORT_E];
        assign r_out_credit_return[hx][hy][PORT_E] = r_in_credit_return[hx+1][hy][PORT_W];

        assign r_in_data [hx][hy][PORT_E]   = r_out_data [hx+1][hy][PORT_W];
        assign r_in_valid[hx][hy][PORT_E]   = r_out_valid[hx+1][hy][PORT_W];
        assign r_out_credit_return[hx+1][hy][PORT_W] = r_in_credit_return[hx][hy][PORT_E];
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Vertical links: router (vx,vy)'s South <-> router (vx,vy+1)'s North.
  // -------------------------------------------------------------------
  genvar vx, vy;
  generate
    for (vx = 0; vx < MESH_W; vx++) begin : g_vlink_x
      for (vy = 0; vy < MESH_H-1; vy++) begin : g_vlink_y
        assign r_in_data [vx][vy+1][PORT_N] = r_out_data [vx][vy][PORT_S];
        assign r_in_valid[vx][vy+1][PORT_N] = r_out_valid[vx][vy][PORT_S];
        assign r_out_credit_return[vx][vy][PORT_S] = r_in_credit_return[vx][vy+1][PORT_N];

        assign r_in_data [vx][vy][PORT_S]   = r_out_data [vx][vy+1][PORT_N];
        assign r_in_valid[vx][vy][PORT_S]   = r_out_valid[vx][vy+1][PORT_N];
        assign r_out_credit_return[vx][vy+1][PORT_N] = r_in_credit_return[vx][vy][PORT_S];
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Edge tie-offs: a port facing off the edge of the grid has no
  // neighbor. Nothing ever sends it anything (in_valid held low), and
  // since XY routing never legitimately tries to leave the grid for an
  // in-range destination, its out_valid should never assert either --
  // so its credit_return input is simply tied off (that credit_count
  // will just sit at its reset value forever, unused).
  // -------------------------------------------------------------------
  genvar ex, ey;
  generate
    for (ey = 0; ey < MESH_H; ey++) begin : g_tie_ew
      assign r_in_valid[0][ey][PORT_W]          = 1'b0;
      assign r_in_data [0][ey][PORT_W]          = '0;
      assign r_out_credit_return[0][ey][PORT_W] = 1'b0;

      assign r_in_valid[MESH_W-1][ey][PORT_E]          = 1'b0;
      assign r_in_data [MESH_W-1][ey][PORT_E]          = '0;
      assign r_out_credit_return[MESH_W-1][ey][PORT_E] = 1'b0;
    end
    for (ex = 0; ex < MESH_W; ex++) begin : g_tie_ns
      assign r_in_valid[ex][0][PORT_N]          = 1'b0;
      assign r_in_data [ex][0][PORT_N]          = '0;
      assign r_out_credit_return[ex][0][PORT_N] = 1'b0;

      assign r_in_valid[ex][MESH_H-1][PORT_S]          = 1'b0;
      assign r_in_data [ex][MESH_H-1][PORT_S]          = '0;
      assign r_out_credit_return[ex][MESH_H-1][PORT_S] = 1'b0;
    end
  endgenerate

  // -------------------------------------------------------------------
  // Local ports: expose every router's Local port at this module's
  // boundary. TILE = Y*MESH_W+X. Whatever is outside this module (a
  // testbench, or eventually a real compute tile) is responsible for
  // being a well-behaved credit-aware party on both halves, exactly as
  // established in M3: track local_in_credit_return to know when it may
  // send more, and pulse local_out_credit_return once it's actually
  // consumed a delivered flit.
  // -------------------------------------------------------------------
  genvar lx, ly;
  generate
    for (lx = 0; lx < MESH_W; lx++) begin : g_local_x
      for (ly = 0; ly < MESH_H; ly++) begin : g_local_y
        localparam int TILE = ly*MESH_W + lx;

        assign r_in_valid[lx][ly][PORT_L] = local_in_valid[TILE];
        assign r_in_data [lx][ly][PORT_L] = local_in_data[TILE];
        assign local_in_credit_return[TILE] = r_in_credit_return[lx][ly][PORT_L];

        assign local_out_valid[TILE] = r_out_valid[lx][ly][PORT_L];
        assign local_out_data[TILE]  = r_out_data[lx][ly][PORT_L];
        assign r_out_credit_return[lx][ly][PORT_L] = local_out_credit_return[TILE];
      end
    end
  endgenerate

endmodule : mesh_credit
