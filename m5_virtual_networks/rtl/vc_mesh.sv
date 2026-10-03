`timescale 1ns/1ps
// vc_mesh.sv
//
// An MESH_W x MESH_H grid of vc_routers -- M4's mesh_credit.sv with each
// link widened to carry a VC ID forward and one credit wire per VC back:
//
//        router A                                   router B
//      out_valid ------------------------------->  in_valid
//      out_vc    ---- which VC buffer at B ----->  in_vc
//      out_data  ------------------------------->  in_data
//      out_credit_return[NUM_VCS] <-- one pulse --  in_credit_return[NUM_VCS]
//                                     per freed slot, per VC
//
// Coordinate convention (unchanged): X increases East, Y increases South.
// Local ports are flattened by TILE = Y*MESH_W + X; per-tile vectors are
// sliced the same way (vc: TILE*VC_W +: VC_W, credits: TILE*NUM_VCS +: NUM_VCS).
//
// Same genvar-only wiring discipline as M2/M4: every connection is a
// continuous assign between constant slices.

import noc_pkg::*;

module vc_mesh #(
  parameter int MESH_W       = 3,
  parameter int MESH_H       = 3,
  parameter int NUM_VNS      = 1,
  parameter int VCS_PER_VN   = 1,
  parameter int BUFFER_DEPTH = 4,
  parameter int SA_ITERS     = 1
) (
  input  logic clk,
  input  logic rst_n,

  input  logic  [MESH_W*MESH_H-1:0]                      local_in_valid,
  input  logic  [MESH_W*MESH_H*VC_W-1:0]                 local_in_vc,
  input  flit_t [MESH_W*MESH_H-1:0]                      local_in_data,
  output logic  [MESH_W*MESH_H*NUM_VNS*VCS_PER_VN-1:0]   local_in_credit_return,

  output logic  [MESH_W*MESH_H-1:0]                      local_out_valid,
  output logic  [MESH_W*MESH_H*VC_W-1:0]                 local_out_vc,
  output flit_t [MESH_W*MESH_H-1:0]                      local_out_data,
  input  logic  [MESH_W*MESH_H*NUM_VNS*VCS_PER_VN-1:0]   local_out_credit_return
);

  localparam int NUM_VCS = NUM_VNS * VCS_PER_VN;
  localparam int CR_W    = NUM_PORTS * NUM_VCS; // credit wires per router, [port*NUM_VCS + vc]

  // Port-slice offsets (the enum's values, as plain ints for arithmetic).
  localparam int PN = PORT_N, PS = PORT_S, PE = PORT_E, PW = PORT_W, PL = PORT_L;

  // Per-router port bundles, one entry per grid position.
  logic  [NUM_PORTS-1:0]      r_in_valid         [MESH_W][MESH_H];
  logic  [NUM_PORTS*VC_W-1:0] r_in_vc            [MESH_W][MESH_H];
  flit_t [NUM_PORTS-1:0]      r_in_data          [MESH_W][MESH_H];
  logic  [CR_W-1:0]           r_in_credit_return [MESH_W][MESH_H];
  logic  [NUM_PORTS-1:0]      r_out_valid        [MESH_W][MESH_H];
  logic  [NUM_PORTS*VC_W-1:0] r_out_vc           [MESH_W][MESH_H];
  flit_t [NUM_PORTS-1:0]      r_out_data         [MESH_W][MESH_H];
  logic  [CR_W-1:0]           r_out_credit_return[MESH_W][MESH_H];

  genvar gx, gy;
  generate
    for (gx = 0; gx < MESH_W; gx++) begin : g_col
      for (gy = 0; gy < MESH_H; gy++) begin : g_row
        vc_router #(
          .X_ID(gx), .Y_ID(gy),
          .NUM_VNS(NUM_VNS), .VCS_PER_VN(VCS_PER_VN), .BUFFER_DEPTH(BUFFER_DEPTH),
          .SA_ITERS(SA_ITERS)
        ) u_router (
          .clk               (clk),
          .rst_n             (rst_n),
          .in_valid          (r_in_valid[gx][gy]),
          .in_vc             (r_in_vc[gx][gy]),
          .in_data           (r_in_data[gx][gy]),
          .in_credit_return  (r_in_credit_return[gx][gy]),
          .out_valid         (r_out_valid[gx][gy]),
          .out_vc            (r_out_vc[gx][gy]),
          .out_data          (r_out_data[gx][gy]),
          .out_credit_return (r_out_credit_return[gx][gy])
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
        // eastbound
        assign r_in_valid[hx+1][hy][PW]                     = r_out_valid[hx][hy][PE];
        assign r_in_vc   [hx+1][hy][PW*VC_W +: VC_W]        = r_out_vc   [hx][hy][PE*VC_W +: VC_W];
        assign r_in_data [hx+1][hy][PW]                     = r_out_data [hx][hy][PE];
        assign r_out_credit_return[hx][hy][PE*NUM_VCS +: NUM_VCS] = r_in_credit_return[hx+1][hy][PW*NUM_VCS +: NUM_VCS];
        // westbound
        assign r_in_valid[hx][hy][PE]                       = r_out_valid[hx+1][hy][PW];
        assign r_in_vc   [hx][hy][PE*VC_W +: VC_W]          = r_out_vc   [hx+1][hy][PW*VC_W +: VC_W];
        assign r_in_data [hx][hy][PE]                       = r_out_data [hx+1][hy][PW];
        assign r_out_credit_return[hx+1][hy][PW*NUM_VCS +: NUM_VCS] = r_in_credit_return[hx][hy][PE*NUM_VCS +: NUM_VCS];
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
        // southbound
        assign r_in_valid[vx][vy+1][PN]                     = r_out_valid[vx][vy][PS];
        assign r_in_vc   [vx][vy+1][PN*VC_W +: VC_W]        = r_out_vc   [vx][vy][PS*VC_W +: VC_W];
        assign r_in_data [vx][vy+1][PN]                     = r_out_data [vx][vy][PS];
        assign r_out_credit_return[vx][vy][PS*NUM_VCS +: NUM_VCS] = r_in_credit_return[vx][vy+1][PN*NUM_VCS +: NUM_VCS];
        // northbound
        assign r_in_valid[vx][vy][PS]                       = r_out_valid[vx][vy+1][PN];
        assign r_in_vc   [vx][vy][PS*VC_W +: VC_W]          = r_out_vc   [vx][vy+1][PN*VC_W +: VC_W];
        assign r_in_data [vx][vy][PS]                       = r_out_data [vx][vy+1][PN];
        assign r_out_credit_return[vx][vy+1][PN*NUM_VCS +: NUM_VCS] = r_in_credit_return[vx][vy][PS*NUM_VCS +: NUM_VCS];
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Edge tie-offs: ports facing off the grid get no traffic and no
  // credits. XY routing never sends toward an edge for an in-range
  // destination -- and now that's checked: a flit leaving through an
  // edge port is gone (nothing is there to receive it), so it's flagged
  // on the cycle it happens instead of surfacing later as a missing packet.
  // -------------------------------------------------------------------
  genvar ex, ey;
  generate
    for (ey = 0; ey < MESH_H; ey++) begin : g_tie_ew
      assign r_in_valid[0][ey][PW]                               = 1'b0;
      assign r_in_vc   [0][ey][PW*VC_W +: VC_W]                  = '0;
      assign r_in_data [0][ey][PW]                               = '0;
      assign r_out_credit_return[0][ey][PW*NUM_VCS +: NUM_VCS]   = '0;

      assign r_in_valid[MESH_W-1][ey][PE]                             = 1'b0;
      assign r_in_vc   [MESH_W-1][ey][PE*VC_W +: VC_W]                = '0;
      assign r_in_data [MESH_W-1][ey][PE]                             = '0;
      assign r_out_credit_return[MESH_W-1][ey][PE*NUM_VCS +: NUM_VCS] = '0;

      always @(posedge clk) begin
        if (rst_n) begin
          assert (!r_out_valid[0][ey][PW] && !r_out_valid[MESH_W-1][ey][PE]) else begin
            $display("ASSERT-FAIL: mesh row %0d: a flit was routed off the West/East edge of the grid (misroute; flit lost)", ey);
            assertion_violations = assertion_violations + 1;
          end
        end
      end
    end
    for (ex = 0; ex < MESH_W; ex++) begin : g_tie_ns
      assign r_in_valid[ex][0][PN]                               = 1'b0;
      assign r_in_vc   [ex][0][PN*VC_W +: VC_W]                  = '0;
      assign r_in_data [ex][0][PN]                               = '0;
      assign r_out_credit_return[ex][0][PN*NUM_VCS +: NUM_VCS]   = '0;

      assign r_in_valid[ex][MESH_H-1][PS]                             = 1'b0;
      assign r_in_vc   [ex][MESH_H-1][PS*VC_W +: VC_W]                = '0;
      assign r_in_data [ex][MESH_H-1][PS]                             = '0;
      assign r_out_credit_return[ex][MESH_H-1][PS*NUM_VCS +: NUM_VCS] = '0;

      always @(posedge clk) begin
        if (rst_n) begin
          assert (!r_out_valid[ex][0][PN] && !r_out_valid[ex][MESH_H-1][PS]) else begin
            $display("ASSERT-FAIL: mesh column %0d: a flit was routed off the North/South edge of the grid (misroute; flit lost)", ex);
            assertion_violations = assertion_violations + 1;
          end
        end
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Local ports, exposed at this module's boundary. TILE = Y*MESH_W + X.
  // -------------------------------------------------------------------
  genvar lx, ly;
  generate
    for (lx = 0; lx < MESH_W; lx++) begin : g_local_x
      for (ly = 0; ly < MESH_H; ly++) begin : g_local_y
        localparam int TILE = ly*MESH_W + lx;

        assign r_in_valid[lx][ly][PL]                     = local_in_valid[TILE];
        assign r_in_vc   [lx][ly][PL*VC_W +: VC_W]        = local_in_vc[TILE*VC_W +: VC_W];
        assign r_in_data [lx][ly][PL]                     = local_in_data[TILE];
        assign local_in_credit_return[TILE*NUM_VCS +: NUM_VCS] = r_in_credit_return[lx][ly][PL*NUM_VCS +: NUM_VCS];

        assign local_out_valid[TILE]                      = r_out_valid[lx][ly][PL];
        assign local_out_vc[TILE*VC_W +: VC_W]            = r_out_vc[lx][ly][PL*VC_W +: VC_W];
        assign local_out_data[TILE]                       = r_out_data[lx][ly][PL];
        assign r_out_credit_return[lx][ly][PL*NUM_VCS +: NUM_VCS] = local_out_credit_return[TILE*NUM_VCS +: NUM_VCS];
      end
    end
  endgenerate

endmodule : vc_mesh
