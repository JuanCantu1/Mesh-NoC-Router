// mesh_tb.sv
//
// Directed, self-checking testbench for the M2 milestone: a 3x3 grid of
// M1 routers wired into a real mesh (mesh.sv). Where router_tb.sv (M1)
// proves one router makes correct *local* routing decisions, this
// testbench proves those decisions compose correctly across multiple
// hops -- packets injected at one tile's Local port are checked for
// arrival, with unchanged data, at the correct destination tile's Local
// port, including straight lines, corner-to-corner paths that require a
// turn, concurrent independent traffic, and cross-router contention.
//
// Tile numbering: TILE = Y*MESH_W + X (matches mesh.sv), so for this 3x3
// grid: (0,0)=0 (1,0)=1 (2,0)=2 / (0,1)=3 (1,1)=4 (2,1)=5 / (0,2)=6 (1,2)=7 (2,2)=8
//
// Run with: iverilog -g2012 -o sim/mesh_tb.vvp rtl/*.sv tb/mesh_tb.sv
//           vvp sim/mesh_tb.vvp

`timescale 1ns/1ps

import noc_pkg::*;

module mesh_tb;

  localparam int MESH_W = 3;
  localparam int MESH_H = 3;
  localparam int NUM_TILES = MESH_W*MESH_H;

  logic clk = 0;
  logic rst_n;

  logic  [NUM_TILES-1:0] local_in_valid;
  flit_t [NUM_TILES-1:0] local_in_data;
  logic  [NUM_TILES-1:0] local_in_ready;

  logic  [NUM_TILES-1:0] local_out_valid;
  flit_t [NUM_TILES-1:0] local_out_data;
  logic  [NUM_TILES-1:0] local_out_ready;

  mesh #(.MESH_W(MESH_W), .MESH_H(MESH_H)) dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .local_in_valid  (local_in_valid),
    .local_in_data   (local_in_data),
    .local_in_ready  (local_in_ready),
    .local_out_valid (local_out_valid),
    .local_out_data  (local_out_data),
    .local_out_ready (local_out_ready)
  );

  always #5 clk = ~clk;

  int pass_count = 0;
  int fail_count = 0;

  function automatic int tile_id(input int x, input int y);
    tile_id = y*MESH_W + x;
  endfunction

  function automatic flit_t mk_flit(input int dx, input int dy, input int pay);
    mk_flit.dest_x  = dx[COORD_WIDTH-1:0];
    mk_flit.dest_y  = dy[COORD_WIDTH-1:0];
    mk_flit.payload = pay[DATA_WIDTH-1:0];
  endfunction

  function automatic string flit_str(input flit_t f);
    flit_str = $sformatf("(dest_x=%0d dest_y=%0d payload=%0d)", f.dest_x, f.dest_y, f.payload);
  endfunction

  // Same shape/timing discipline as tb/router_tb.sv in M1: drive at
  // negedge, sample at posedge+#1, copy any array-of-struct element out
  // to a local variable before comparing or formatting it. See that
  // file's and router.sv's notes on why -- this Icarus build has runtime
  // bugs when a struct field is accessed by chaining it directly off a
  // variable array index instead of copying the element out first.
  task automatic send_and_check(
    input string  name,
    input int     src_tile,
    input flit_t  f,
    input int     dest_tile,
    output int    accepted_on_cycle
  );
    int    cyc;
    bit    timed_out;
    flit_t got;

    in_data_write(src_tile, f);
    cyc = 0;
    timed_out = 1'b0;
    do begin
      @(posedge clk);
      #1;
      cyc++;
      if (cyc > 10) timed_out = 1'b1;
    end while (!local_in_ready[src_tile] && !timed_out);

    if (timed_out) begin
      $display("[FAIL] %-28s tile %0d never accepted (timeout)", name, src_tile);
      fail_count++;
      accepted_on_cycle = -1;
    end else begin
      accepted_on_cycle = cyc;
      got = local_out_data[dest_tile];
      if (!local_out_valid[dest_tile] || got !== f) begin
        $display("[FAIL] %-28s expected %s at tile %0d, got out_valid=%0b out_data=%s",
                  name, flit_str(f), dest_tile, local_out_valid[dest_tile], flit_str(got));
        fail_count++;
      end else begin
        $display("[PASS] %-28s tile %0d -> tile %0d, %s (accepted cycle %0d)",
                  name, src_tile, dest_tile, flit_str(f), cyc);
        pass_count++;
      end
    end

    in_valid_clear(src_tile);
  endtask

  // Small helpers kept as tasks (not inlined into send_and_check as a
  // procedural loop) specifically so no array is ever indexed by a
  // variable inside a loop body -- src_tile here is a plain task
  // argument used once, not a loop induction variable.
  task automatic in_data_write(input int t, input flit_t f);
    local_in_data[t]  = f;
    local_in_valid[t] = 1'b1;
  endtask

  task automatic in_valid_clear(input int t);
    local_in_valid[t] = 1'b0;
    local_in_data[t]  = '0;
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
    $dumpfile("sim/mesh_tb.vcd");
    $dumpvars(0, mesh_tb);

    local_in_valid  = '0;
    local_out_ready = '1;
    local_in_data   = '0;

    rst_n = 0;
    repeat (2) @(posedge clk);
    #1;
    rst_n = 1;
    @(posedge clk);
    #1;

    $display("================================================================");
    $display(" M2 mesh directed test -- %0dx%0d grid of M1 routers", MESH_W, MESH_H);
    $display("================================================================");

    // -----------------------------------------------------------------
    // (a) One hop: adjacent tiles, straight east.
    // -----------------------------------------------------------------
    begin
      int cyc;
      send_and_check("adjacent hop (0,0)->(1,0)", tile_id(0,0),
                      mk_flit(1,0,8'h11), tile_id(1,0), cyc);
    end

    // -----------------------------------------------------------------
    // (b) Straight line across a whole row: two hops east, no turn.
    // -----------------------------------------------------------------
    begin
      int cyc;
      send_and_check("straight row (0,1)->(2,1)", tile_id(0,1),
                      mk_flit(2,1,8'h22), tile_id(2,1), cyc);
    end

    // -----------------------------------------------------------------
    // (c) Straight line down a whole column: two hops south, no turn.
    // -----------------------------------------------------------------
    begin
      int cyc;
      send_and_check("straight col (1,0)->(1,2)", tile_id(1,0),
                      mk_flit(1,2,8'h33), tile_id(1,2), cyc);
    end

    // -----------------------------------------------------------------
    // (d) Corner to corner: 2 hops east, then 2 hops south (one turn).
    // -----------------------------------------------------------------
    begin
      int cyc;
      send_and_check("corner (0,0)->(2,2)", tile_id(0,0),
                      mk_flit(2,2,8'h44), tile_id(2,2), cyc);
    end

    // -----------------------------------------------------------------
    // (e) Corner to corner, the other diagonal: 2 hops west, 2 south.
    // -----------------------------------------------------------------
    begin
      int cyc;
      send_and_check("corner (2,0)->(0,2)", tile_id(2,0),
                      mk_flit(0,2,8'h55), tile_id(0,2), cyc);
    end

    // -----------------------------------------------------------------
    // (f) Concurrent, independent traffic: two packets on different
    // rows share no router along their paths, so both should complete
    // on the very same cycle with no interference.
    // -----------------------------------------------------------------
    begin
      int cyc1, cyc2;
      fork
        send_and_check("concurrent (0,0)->(2,0)", tile_id(0,0), mk_flit(2,0,8'h66), tile_id(2,0), cyc1);
        send_and_check("concurrent (0,2)->(2,2)", tile_id(0,2), mk_flit(2,2,8'h77), tile_id(2,2), cyc2);
      join
      check("concurrent traffic didn't interfere",
            (cyc1 != -1) && (cyc2 != -1) && (cyc1 == cyc2),
            $sformatf("both delivered on cycle %0d (independent paths, no shared router)", cyc1));
    end

    // -----------------------------------------------------------------
    // (g) Cross-router contention: a packet injected directly at
    // router(1,0) needing only one more hop East, and a packet injected
    // at router(0,0) that also needs to continue East *through*
    // router(1,0) -- both end up requesting router(1,0)'s East output
    // in the same cycle. The same round-robin arbiter mechanism M1
    // tested locally must resolve this across tiles too.
    // -----------------------------------------------------------------
    begin
      int cyc_near, cyc_far;
      fork
        send_and_check("contention near (1,0)->(2,0)", tile_id(1,0), mk_flit(2,0,8'h88), tile_id(2,0), cyc_near);
        send_and_check("contention far  (0,0)->(2,0)", tile_id(0,0), mk_flit(2,0,8'h99), tile_id(2,0), cyc_far);
      join
      check("cross-router contention arbitrated",
            (cyc_near != -1) && (cyc_far != -1) && (cyc_near != cyc_far),
            $sformatf("near-tile accepted cycle %0d, far-tile accepted cycle %0d (must differ, neither -1)", cyc_near, cyc_far));
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

endmodule : mesh_tb
