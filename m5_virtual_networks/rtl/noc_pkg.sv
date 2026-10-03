`timescale 1ns/1ps
// noc_pkg.sv
//
// Shared type/parameter definitions for the mesh NoC. Every router instance
// imports this package so packet formats and port numbering stay consistent
// across the whole mesh.
//
// What M5 changes relative to M4:
//   * Every flit carries a MESSAGE CLASS (REQ / SNP / RSP) -- the kind of
//     coherence-protocol message it is. The router uses it only to check
//     that a flit is travelling in its own virtual network; the endpoints
//     use it to decide what the message means.
//   * Every flit carries its SENDER's coordinates. A real coherence
//     protocol needs this (a home agent has to know who to answer), and
//     it's the field later milestones' security work is about: nothing in
//     M5 stops a tile from lying about it.
//   * Payload widened to 16 bits, so testbenches can tag far more packets
//     in flight than M4's 8-bit IDs allowed (VC routers hold more flits).
//   * A virtual-channel ID travels ALONGSIDE each flit on every link (a
//     separate `vc` signal, not a flit field): it's link-level state that
//     each router rewrites hop by hop, and it never needs to be stored.

package noc_pkg;

  // Width of one coordinate axis (meshes up to 16x16).
  parameter int COORD_WIDTH = 4;

  // Payload width. Opaque to the routers; testbenches carry packet IDs in it.
  parameter int DATA_WIDTH  = 16;

  // -------------------------------------------------------------------
  // Message classes of the coherence-style protocol M5 models. One
  // transaction is a chain of three messages, each triggered by the last:
  //
  //   requester --REQ--> home --SNP--> owner --RSP--> requester
  //
  // Plain parameters rather than an enum: this Icarus build mishandles
  // enum-typed values used as array indices, and testbenches do exactly
  // that with message classes.
  // -------------------------------------------------------------------
  parameter int MCLASS_W     = 2;
  parameter int NUM_MCLASSES = 3;
  parameter logic [MCLASS_W-1:0] MC_REQ = 2'd0;
  parameter logic [MCLASS_W-1:0] MC_SNP = 2'd1;
  parameter logic [MCLASS_W-1:0] MC_RSP = 2'd2;

  typedef struct packed {
    logic [MCLASS_W-1:0]    mclass;
    logic [COORD_WIDTH-1:0] src_x;
    logic [COORD_WIDTH-1:0] src_y;
    logic [COORD_WIDTH-1:0] dest_x;
    logic [COORD_WIDTH-1:0] dest_y;
    logic [DATA_WIDTH-1:0]  payload;
  } flit_t;

  // Which virtual network a message class travels in. With one VN,
  // everything shares it (the configuration that can protocol-deadlock);
  // with one VN per class, each class gets its own.
  function automatic int vn_of(input logic [MCLASS_W-1:0] mclass, input int num_vns);
    vn_of = (num_vns == 1) ? 0 : int'(mclass);
  endfunction

  // Every router has 5 ports: four compass directions plus Local (the
  // compute tile at that mesh position).
  parameter int NUM_PORTS = 5;

  typedef enum logic [2:0] {
    PORT_N = 3'd0,
    PORT_S = 3'd1,
    PORT_E = 3'd2,
    PORT_W = 3'd3,
    PORT_L = 3'd4
  } port_e;

  // Virtual-channel ID width on every link: up to 8 VCs per port.
  parameter int VC_W    = 3;
  parameter int MAX_VCS = 8;

  // -------------------------------------------------------------------
  // Verification-only: a single shared violation counter that every
  // flit_fifo / vc_router / vc_mesh instance increments if one of its
  // embedded invariant checks fails. This Icarus build (12.0-devel) does
  // not parse concurrent assertions (`property` / `assert property`); a
  // package-level counter is how immediate assertions scattered across
  // dozens of instances become one number a testbench can gate on.
  // Not synthesizable, and not meant to be.
  // -------------------------------------------------------------------
  int assertion_violations = 0;

endpackage : noc_pkg
