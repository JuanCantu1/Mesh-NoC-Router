// noc_pkg.sv
//
// Shared type/parameter definitions for the mesh NoC project. Every router
// instance in the design imports this package so that packet formats and
// port numbering stay consistent across the whole mesh (this matters once
// M2 wires many routers together -- they all need to agree on what a flit
// looks like and which port number means "north").

package noc_pkg;

  // Width of one coordinate axis. 4 bits supports mesh sizes up to 16x16,
  // which is far beyond anything this project will instantiate, but costs
  // nothing to leave generous.
  parameter int COORD_WIDTH = 4;

  // Width of the payload carried by a packet. M1 packets are a single flit
  // (header + payload in one cycle), so this is the only "data" a packet
  // carries besides its destination.
  parameter int DATA_WIDTH  = 8;

  // A "flit" (flow-control digit) is the unit transferred across one port
  // in one cycle. In M1, one flit == one whole packet: a destination
  // address plus a payload. Later milestones may split larger packets into
  // multiple flits (head/body/tail); M1 deliberately keeps it to one.
  typedef struct packed {
    logic [COORD_WIDTH-1:0] dest_x;
    logic [COORD_WIDTH-1:0] dest_y;
    logic [DATA_WIDTH-1:0]  payload;
  } flit_t;

  // Every router has exactly 5 ports: the four compass directions to
  // neighboring routers, plus "Local", which connects to the compute node
  // sitting at that mesh position (the thing actually sending/receiving
  // traffic, as opposed to just relaying it).
  parameter int NUM_PORTS = 5;

  typedef enum logic [2:0] {
    PORT_N = 3'd0,
    PORT_S = 3'd1,
    PORT_E = 3'd2,
    PORT_W = 3'd3,
    PORT_L = 3'd4
  } port_e;

  // -------------------------------------------------------------------
  // M4 verification-only: a single shared violation counter that every
  // instance of flit_fifo/router increments if one of its internal
  // invariant checks ever fails. This Icarus build (12.0-devel) does not
  // support SystemVerilog concurrent assertions (`property`/`assert
  // property` fail to even parse -- confirmed directly, not assumed);
  // only plain unlabeled immediate `assert (expr) else ...;` inside a
  // procedural block works. A package-level counter is how those
  // immediate assertions get turned into one check a testbench can gate
  // pass/fail on, given there's no per-instance handle a testbench could
  // otherwise poll across many router/FIFO instances in a mesh.
  // Not synthesizable, and not meant to be -- verification-only state.
  // -------------------------------------------------------------------
  int assertion_violations = 0;

endpackage : noc_pkg
