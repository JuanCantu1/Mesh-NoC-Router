// trace_gen_tb.sv
//
// NOT a verification testbench (that's tb/router_tb.sv, which already
// passes 13/13 checks). This one drives the exact same set of scenarios
// through the exact same DUT, and instead of checking pass/fail, it dumps
// a plain-text, line-oriented trace of every port's state on every clock
// cycle. That trace is what the visual simulator artifact is built from --
// so the animation you see there is a replay of this real RTL simulation,
// not a separate hand-drawn reimplementation of the router's behavior.
//
// Two line formats are printed (grep-able by the tag in column 1):
//   MARK|<cycle>|<label>|<description>
//     -- marks the cycle a named scenario begins, for chapter navigation.
//   TRACE|<cycle>|<10 fields per port, N,S,E,W,L in that order>
//     -- per port: in_valid|in_ready|dest_x|dest_y|payload|
//                  out_valid|out_ready|dest_x|dest_y|payload
//
// Run with:
//   iverilog -g2012 -o sim/trace_gen_tb.vvp rtl/*.sv tb/trace_gen_tb.sv
//   vvp sim/trace_gen_tb.vvp | grep -E "^(MARK|TRACE)" > sim/trace.log

`timescale 1ns/1ps

import noc_pkg::*;

module trace_gen_tb;

  localparam int ROUTER_X = 1;
  localparam int ROUTER_Y = 1;

  logic clk = 0;
  logic rst_n;

  logic  [NUM_PORTS-1:0] in_valid;
  flit_t [NUM_PORTS-1:0] in_data;
  logic  [NUM_PORTS-1:0] in_ready;

  logic  [NUM_PORTS-1:0] out_valid;
  flit_t [NUM_PORTS-1:0] out_data;
  logic  [NUM_PORTS-1:0] out_ready;

  router #(.X_ID(ROUTER_X), .Y_ID(ROUTER_Y)) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (in_valid),
    .in_data   (in_data),
    .in_ready  (in_ready),
    .out_valid (out_valid),
    .out_data  (out_data),
    .out_ready (out_ready)
  );

  always #5 clk = ~clk;

  function automatic flit_t mk_flit(input int dx, input int dy, input int pay);
    mk_flit.dest_x  = dx[COORD_WIDTH-1:0];
    mk_flit.dest_y  = dy[COORD_WIDTH-1:0];
    mk_flit.payload = pay[DATA_WIDTH-1:0];
  endfunction

  // ---------------------------------------------------------------------
  // Cycle counter + free-running trace monitor. Samples shortly after
  // every posedge (once combinational logic has settled) and prints one
  // TRACE line per cycle. Every port's struct field is read through a
  // *constant*-indexed local copy (tmp_in/tmp_out) rather than a variable
  // index -- see router.sv's top-of-file note on this Icarus build's
  // struct/array-indexing bugs. Never refactor this into a `for` loop
  // over port number without re-testing; that shape is exactly what was
  // found to corrupt simulation on this toolchain.
  // ---------------------------------------------------------------------
  int cyc_num = 0;
  flit_t tmp_in, tmp_out;

  task automatic dump_port(input int iv, input int ir, input flit_t din,
                            input int ov, input int ord, input flit_t dout);
    // NOTE: `din`/`dout` are passed in already-copied-out (by the caller,
    // using a constant index) so this task never itself indexes an array
    // with a variable -- see the caution above.
    $write("%0d|%0d|%0d|%0d|%0d|%0d|%0d|%0d|%0d|%0d|",
           iv, ir, din.dest_x, din.dest_y, din.payload,
           ov, ord, dout.dest_x, dout.dest_y, dout.payload);
  endtask

  always @(posedge clk) begin
    #1;
    if (rst_n) begin
      $write("TRACE|%0d|", cyc_num);

      tmp_in = in_data[0]; tmp_out = out_data[0];
      dump_port(in_valid[0], in_ready[0], tmp_in, out_valid[0], out_ready[0], tmp_out);
      tmp_in = in_data[1]; tmp_out = out_data[1];
      dump_port(in_valid[1], in_ready[1], tmp_in, out_valid[1], out_ready[1], tmp_out);
      tmp_in = in_data[2]; tmp_out = out_data[2];
      dump_port(in_valid[2], in_ready[2], tmp_in, out_valid[2], out_ready[2], tmp_out);
      tmp_in = in_data[3]; tmp_out = out_data[3];
      dump_port(in_valid[3], in_ready[3], tmp_in, out_valid[3], out_ready[3], tmp_out);
      tmp_in = in_data[4]; tmp_out = out_data[4];
      dump_port(in_valid[4], in_ready[4], tmp_in, out_valid[4], out_ready[4], tmp_out);

      $write("\n");
      cyc_num = cyc_num + 1;
    end
  end

  task automatic mark(input string label, input string desc);
    $display("MARK|%0d|%s|%s", cyc_num, label, desc);
  endtask

  // Drives one packet into `port` at the next negedge, holds valid+data
  // until the router accepts it (in_ready pulses), then clears at the
  // following negedge. Stimulus changes only at negedges, sampling only
  // at posedge+1 -- this keeps every write safely clear of the monitor's
  // read of the exact same cycle, so both always see a consistent snapshot.
  task automatic send(input int port, input flit_t f);
    bit accepted;
    @(negedge clk);
    in_data[port]  = f;
    in_valid[port] = 1'b1;
    accepted = 1'b0;
    while (!accepted) begin
      @(posedge clk); #1;
      if (in_ready[port]) accepted = 1'b1;
    end
    @(negedge clk);
    in_valid[port] = 1'b0;
    in_data[port]  = '0;
  endtask

  initial begin
    in_valid  = '0;
    out_ready = '1;
    in_data   = '0;

    rst_n = 0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    mark("straight-through", "A packet entering West still needs to go further East, so it passes straight through.");
    send(PORT_W, mk_flit(2, 1, 8'hA1));
    repeat (2) @(posedge clk);

    mark("straight-through-2", "Same idea, other axis: enters North, still needs to go further South.");
    send(PORT_N, mk_flit(1, 2, 8'hA2));
    repeat (2) @(posedge clk);

    mark("turn", "X already matches. The packet turns to fix Y instead -- the XY \"dogleg\".");
    send(PORT_E, mk_flit(1, 2, 8'hB1));
    repeat (2) @(posedge clk);

    mark("turn-2", "Same turn, the other way: West in, X already correct, turns North.");
    send(PORT_W, mk_flit(1, 0, 8'hB2));
    repeat (2) @(posedge clk);

    mark("arrival", "Destination exactly matches this router's own position -- delivered to Local.");
    send(PORT_S, mk_flit(1, 1, 8'hC0));
    repeat (2) @(posedge clk);

    mark("injection", "The Local compute tile hands the router a brand-new packet to send out.");
    send(PORT_L, mk_flit(3, 1, 8'hD0));
    repeat (2) @(posedge clk);

    mark("contention", "North AND West both need East in the same cycle. Only one can leave -- the round-robin arbiter must pick.");
    fork
      send(PORT_N, mk_flit(3, 1, 8'hE1));
      send(PORT_W, mk_flit(3, 1, 8'hE2));
    join
    repeat (2) @(posedge clk);

    mark("backpressure", "A packet for Local arrives, but Local isn't ready yet. The router holds it -- nothing is dropped.");
    @(negedge clk);
    out_ready[PORT_L] = 1'b0;
    in_data[PORT_N]   = mk_flit(1, 1, 8'hF0);
    in_valid[PORT_N]  = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk);
    out_ready[PORT_L] = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk);
    in_valid[PORT_N] = 1'b0;
    in_data[PORT_N]  = '0;

    repeat (2) @(posedge clk);
    mark("end", "End of trace.");

    $finish;
  end

  initial begin
    #5000;
    $display("MARK|%0d|end|watchdog timeout", cyc_num);
    $finish;
  end

endmodule : trace_gen_tb
