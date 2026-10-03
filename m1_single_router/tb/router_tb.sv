// router_tb.sv
//
// Directed, self-checking testbench for the single M1 router.
//
// The router under test sits at mesh position (X_ID=1, Y_ID=1). Every
// scenario below drives one or two packets into specific input ports and
// checks that the packet reappears on the *correct* output port with its
// data unchanged. There is no visual waveform requirement to pass this
// test -- every check is a PASS/FAIL printed to the console, and the run
// ends with a single summary line, so this can be run headless in CI or
// from a plain terminal.
//
// Run with:  iverilog -g2012 -o sim/router_tb.vvp rtl/*.sv tb/router_tb.sv
//            vvp sim/router_tb.vvp

`timescale 1ns/1ps

import noc_pkg::*;

module router_tb;

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

  int pass_count = 0;
  int fail_count = 0;

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

  // 100 MHz-equivalent test clock (period is arbitrary for a functional test)
  always #5 clk = ~clk;

  function automatic flit_t mk_flit(input int dx, input int dy, input int pay);
    mk_flit.dest_x  = dx[COORD_WIDTH-1:0];
    mk_flit.dest_y  = dy[COORD_WIDTH-1:0];
    mk_flit.payload = pay[DATA_WIDTH-1:0];
  endfunction

  function automatic string port_name(input int p);
    case (p)
      PORT_N: port_name = "N";
      PORT_S: port_name = "S";
      PORT_E: port_name = "E";
      PORT_W: port_name = "W";
      PORT_L: port_name = "L";
      default: port_name = "?";
    endcase
  endfunction

  function automatic string flit_str(input flit_t f);
    flit_str = $sformatf("(dest_x=%0d dest_y=%0d payload=%0d)", f.dest_x, f.dest_y, f.payload);
  endfunction

  // Drives one packet into `port`, waits until the router accepts it
  // (in_ready pulses), then checks it appeared on `exp_out` with the same
  // data. Returns the 1-based cycle number on which it was accepted, so
  // callers can reason about arbitration ordering.
  task automatic send_and_check(
    input string  name,
    input int     port,
    input flit_t  f,
    input port_e  exp_out,
    output int    accepted_on_cycle
  );
    int    cyc;
    bit    timed_out;
    flit_t got; // local copy of out_data[exp_out] -- this Icarus build
                // mishandles a struct-field access (inside flit_str, or an
                // implicit one in a function call) chained directly off a
                // runtime-variable array index, so the array element is
                // always copied out to a plain local first.
    in_data[port]  = f;
    in_valid[port] = 1'b1;
    cyc = 0;
    timed_out = 1'b0;
    do begin
      @(posedge clk);
      #1; // let combinational logic settle before sampling
      cyc++;
      if (cyc > 10) begin
        timed_out = 1'b1;
      end
    end while (!in_ready[port] && !timed_out);

    if (timed_out) begin
      $display("[FAIL] %-28s port %s never accepted (timeout)", name, port_name(port));
      fail_count++;
      accepted_on_cycle = -1;
    end else begin
      accepted_on_cycle = cyc;
      got = out_data[exp_out];
      if (!out_valid[exp_out] || got !== f) begin
        $display("[FAIL] %-28s expected %s on port %s, got out_valid=%0b out_data=%s",
                  name, flit_str(f), port_name(exp_out), out_valid[exp_out], flit_str(got));
        fail_count++;
      end else begin
        $display("[PASS] %-28s port %s -> port %s, %s (accepted cycle %0d)",
                  name, port_name(port), port_name(exp_out), flit_str(f), cyc);
        pass_count++;
      end
    end

    in_valid[port] = 1'b0;
    in_data[port]  = '0;
  endtask

  task automatic check(input string name, input bit cond, input string detail);
    if (cond) begin
      $display("[PASS] %-28s %s", name, detail);
      pass_count++;
    end else begin
      $display("[FAIL] %-28s %s", name, detail);
      fail_count++;
    end
  endtask

  initial begin
    $dumpfile("sim/router_tb.vcd");
    $dumpvars(0, router_tb);

    in_valid  = '0;
    out_ready = '1;
    for (int p = 0; p < NUM_PORTS; p++) in_data[p] = '0;

    rst_n = 0;
    repeat (2) @(posedge clk);
    #1;
    rst_n = 1;
    @(posedge clk);
    #1;

    $display("================================================================");
    $display(" M1 single-router directed test -- router at (X=%0d, Y=%0d)", ROUTER_X, ROUTER_Y);
    $display("================================================================");

    // ---------------------------------------------------------------
    // (a) Straight-through in X: enters West, still needs to go further
    //     East (dest_x=2 > 1), so it passes straight through to East.
    // ---------------------------------------------------------------
    begin
      int cyc;
      send_and_check("straight-through W->E", PORT_W, mk_flit(2, 1, 8'hA1), PORT_E, cyc);
    end

    // ---------------------------------------------------------------
    // (b) Straight-through in Y: enters North, X already correct,
    //     dest_y=2 > 1, continues straight through to South.
    // ---------------------------------------------------------------
    begin
      int cyc;
      send_and_check("straight-through N->S", PORT_N, mk_flit(1, 2, 8'hA2), PORT_S, cyc);
    end

    // ---------------------------------------------------------------
    // (c) Turn: enters East, X already correct (dest_x=1), dest_y=2 > 1,
    //     so it turns south -- this is the X-then-Y "dogleg" that makes
    //     XY routing deadlock-free.
    // ---------------------------------------------------------------
    begin
      int cyc;
      send_and_check("turn E->S", PORT_E, mk_flit(1, 2, 8'hB1), PORT_S, cyc);
    end

    // ---------------------------------------------------------------
    // (d) Turn: enters West, X already correct, dest_y=0 < 1, turns north.
    // ---------------------------------------------------------------
    begin
      int cyc;
      send_and_check("turn W->N", PORT_W, mk_flit(1, 0, 8'hB2), PORT_N, cyc);
    end

    // ---------------------------------------------------------------
    // (e) Arrival: destination coordinates exactly match this router's
    //     own position, so the packet is handed to the Local port --
    //     this is where a packet's journey through the mesh ends.
    // ---------------------------------------------------------------
    begin
      int cyc;
      send_and_check("arrival ->Local", PORT_S, mk_flit(1, 1, 8'hC0), PORT_L, cyc);
    end

    // ---------------------------------------------------------------
    // (f) Injection: the Local node (this router's own compute tile)
    //     hands the router a new packet to send into the mesh.
    // ---------------------------------------------------------------
    begin
      int cyc;
      send_and_check("inject Local->E", PORT_L, mk_flit(3, 1, 8'hD0), PORT_E, cyc);
    end

    // ---------------------------------------------------------------
    // (g) Contention: North and West both have a packet that routes to
    //     East in the SAME cycle. Only one can leave on East per cycle,
    //     so the round-robin arbiter must serialize them -- both must
    //     still get through correctly, just one cycle apart.
    // ---------------------------------------------------------------
    begin
      int cyc_n, cyc_w;
      flit_t f_n, f_w;
      f_n = mk_flit(3, 1, 8'hE1);
      f_w = mk_flit(3, 1, 8'hE2);
      fork
        send_and_check("contention N->E", PORT_N, f_n, PORT_E, cyc_n);
        send_and_check("contention W->E", PORT_W, f_w, PORT_E, cyc_w);
      join
      check("contention arbitrated fairly",
            (cyc_n != -1) && (cyc_w != -1) && (cyc_n != cyc_w),
            $sformatf("N accepted cycle %0d, W accepted cycle %0d (must differ, neither -1)", cyc_n, cyc_w));
    end

    // ---------------------------------------------------------------
    // (h) Backpressure: a packet destined for Local arrives, but the
    //     Local consumer isn't ready yet. The router must hold -- NOT
    //     drop or corrupt -- the packet, and only accept it once the
    //     consumer raises out_ready. This is the valid/ready contract
    //     this whole milestone relies on (no buffering exists yet, so
    //     the sender is expected to keep holding valid+data stable).
    // ---------------------------------------------------------------
    begin
      flit_t f_bp;
      f_bp = mk_flit(1, 1, 8'hF0);
      out_ready[PORT_L] = 1'b0;
      in_data[PORT_N]   = f_bp;
      in_valid[PORT_N]  = 1'b1;

      repeat (3) begin
        @(posedge clk); #1;
        check("backpressure holds packet",
              !in_ready[PORT_N],
              "in_ready must stay low while out_ready[Local] is low");
      end

      out_ready[PORT_L] = 1'b1;
      @(posedge clk); #1;
      check("backpressure releases correctly",
            in_ready[PORT_N] && out_valid[PORT_L] && (out_data[PORT_L] === f_bp),
            "packet delivered intact once out_ready[Local] goes high");

      in_valid[PORT_N] = 1'b0;
      in_data[PORT_N]  = '0;
    end

    @(posedge clk);
    $display("================================================================");
    if (fail_count == 0)
      $display(" ALL TESTS PASSED  (%0d/%0d)", pass_count, pass_count + fail_count);
    else
      $display(" %0d TEST(S) FAILED  (%0d passed, %0d failed)", fail_count, pass_count, fail_count);
    $display("================================================================");

    $finish;
  end

  initial begin
    #2000;
    $display("[FAIL] watchdog timeout -- simulation did not finish in time");
    $finish;
  end

endmodule : router_tb
