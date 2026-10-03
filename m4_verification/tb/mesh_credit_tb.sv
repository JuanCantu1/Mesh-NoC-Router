// mesh_credit_tb.sv
//
// Directed, self-checking smoke test for mesh_credit.sv: the same
// multi-hop scenarios M2's mesh_tb.sv proved for the valid/ready mesh,
// now through the credit-based mesh built on M3's router. Every tile is
// modeled as a proper credit-aware party on both sides, exactly as
// established in M3's router_tb.sv: a sender that tracks its own credit
// and never sends at zero, and a receiver that's a real bounded buffer
// (not a same-cycle "always yes"), so credit timing is realistic rather
// than degenerate.
//
// Run with: iverilog -g2012 -o sim/mesh_credit_tb.vvp rtl/*.sv tb/mesh_credit_tb.sv
//           vvp sim/mesh_credit_tb.vvp

`timescale 1ns/1ps

import noc_pkg::*;

module mesh_credit_tb;

  localparam int MESH_W = 3;
  localparam int MESH_H = 3;
  localparam int NUM_TILES = MESH_W*MESH_H;
  localparam int BUFFER_DEPTH = 4;

  logic clk = 0;
  logic rst_n;

  logic  [NUM_TILES-1:0] local_in_valid;
  flit_t [NUM_TILES-1:0] local_in_data;
  logic  [NUM_TILES-1:0] local_in_credit_return;

  logic  [NUM_TILES-1:0] local_out_valid;
  flit_t [NUM_TILES-1:0] local_out_data;
  logic  [NUM_TILES-1:0] local_out_credit_return;

  mesh_credit #(.MESH_W(MESH_W), .MESH_H(MESH_H), .BUFFER_DEPTH(BUFFER_DEPTH)) dut (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .local_in_valid          (local_in_valid),
    .local_in_data           (local_in_data),
    .local_in_credit_return  (local_in_credit_return),
    .local_out_valid         (local_out_valid),
    .local_out_data          (local_out_data),
    .local_out_credit_return (local_out_credit_return)
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

  // ---------------------------------------------------------------------
  // Receive-side model: one real bounded buffer per tile, standing in for
  // "the compute tile's own inbox." Defaults to always-draining (an
  // ideal-but-not-instantaneous consumer); tests that want to model a
  // slow/busy tile can hold a specific tile's pop_en low.
  // ---------------------------------------------------------------------
  logic  [NUM_TILES-1:0] rx_pop_en = '1;
  logic  [NUM_TILES-1:0] rx_full;
  logic  [NUM_TILES-1:0] rx_empty;
  flit_t [NUM_TILES-1:0] rx_head;

  genvar rt;
  generate
    for (rt = 0; rt < NUM_TILES; rt++) begin : g_rx_model
      flit_fifo #(.DEPTH(BUFFER_DEPTH)) u_rx_model (
        .clk       (clk),
        .rst_n     (rst_n),
        .push_en   (local_out_valid[rt]),
        .push_data (local_out_data[rt]),
        .full      (rx_full[rt]),
        .pop_en    (rx_pop_en[rt]),
        .pop_data  (rx_head[rt]),
        .empty     (rx_empty[rt])
      );
      assign local_out_credit_return[rt] = rx_pop_en[rt] && !rx_empty[rt];
    end
  endgenerate

  // Sender-side model: one credit counter per tile, mirroring exactly
  // what a real tile would track for its own outbound link.
  int send_credit [NUM_TILES];

  always @(posedge clk) begin
    #1;
    for (int t = 0; t < NUM_TILES; t++)
      if (local_in_credit_return[t]) send_credit[t] = send_credit[t] + 1;
  end

  task automatic try_send(input int tile, input flit_t f, output bit sent);
    @(negedge clk);
    if (send_credit[tile] > 0) begin
      local_in_data[tile]  = f;
      local_in_valid[tile] = 1'b1;
      send_credit[tile]    = send_credit[tile] - 1;
      sent = 1'b1;
    end else begin
      sent = 1'b0;
    end
    @(posedge clk); #1;
    @(negedge clk);
    local_in_valid[tile] = 1'b0;
    local_in_data[tile]  = '0;
  endtask

  task automatic send_and_check(
    input string  name,
    input int     src_tile,
    input flit_t  f,
    input int     dest_tile,
    output int    delivered_on_cycle
  );
    bit    sent;
    int    cyc;
    bit    timed_out;
    bit    delivered;
    flit_t got;

    try_send(src_tile, f, sent);

    if (!sent) begin
      $display("[FAIL] %-28s no credit available on tile %0d", name, src_tile);
      fail_count++;
      delivered_on_cycle = -1;
    end else begin
      cyc = 0;
      timed_out = 1'b0;
      delivered = 1'b0;
      // Check current state before waiting for a new edge -- this mesh
      // inherits M3's cut-through behavior (a flit can reach an idle,
      // credit-available downstream within the same cycle it's pushed at
      // each hop), so the transfer may already be visible the instant
      // try_send() returns.
      got = local_out_data[dest_tile];
      if (local_out_valid[dest_tile] && got === f) delivered = 1'b1;
      while (!delivered && !timed_out) begin
        @(posedge clk); #1;
        cyc++;
        got = local_out_data[dest_tile];
        if (local_out_valid[dest_tile] && got === f) delivered = 1'b1;
        else if (cyc > 30) timed_out = 1'b1;
      end

      if (!delivered) begin
        $display("[FAIL] %-28s never observed at tile %0d (timeout)", name, dest_tile);
        fail_count++;
        delivered_on_cycle = -1;
      end else begin
        $display("[PASS] %-28s tile %0d -> tile %0d, %s (delivered cycle %0d)",
                  name, src_tile, dest_tile, flit_str(f), cyc);
        pass_count++;
        delivered_on_cycle = cyc;
      end
    end
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
    $dumpfile("sim/mesh_credit_tb.vcd");
    $dumpvars(0, mesh_credit_tb);

    local_in_valid = '0;
    local_in_data  = '0;
    for (int t = 0; t < NUM_TILES; t++) send_credit[t] = BUFFER_DEPTH;

    rst_n = 0;
    repeat (2) @(posedge clk);
    #1;
    rst_n = 1;
    @(posedge clk);
    #1;

    $display("================================================================");
    $display(" M4 credit-based mesh smoke test -- %0dx%0d grid", MESH_W, MESH_H);
    $display("================================================================");

    begin
      int cyc;
      send_and_check("adjacent hop (0,0)->(1,0)", tile_id(0,0), mk_flit(1,0,8'h11), tile_id(1,0), cyc);
    end
    begin
      int cyc;
      send_and_check("straight row (0,1)->(2,1)", tile_id(0,1), mk_flit(2,1,8'h22), tile_id(2,1), cyc);
    end
    begin
      int cyc;
      send_and_check("straight col (1,0)->(1,2)", tile_id(1,0), mk_flit(1,2,8'h33), tile_id(1,2), cyc);
    end
    begin
      int cyc;
      send_and_check("corner (0,0)->(2,2)", tile_id(0,0), mk_flit(2,2,8'h44), tile_id(2,2), cyc);
    end
    begin
      int cyc;
      send_and_check("corner (2,0)->(0,2)", tile_id(2,0), mk_flit(0,2,8'h55), tile_id(0,2), cyc);
    end

    begin
      int cyc1, cyc2;
      fork
        send_and_check("concurrent (0,0)->(2,0)", tile_id(0,0), mk_flit(2,0,8'h66), tile_id(2,0), cyc1);
        send_and_check("concurrent (0,2)->(2,2)", tile_id(0,2), mk_flit(2,2,8'h77), tile_id(2,2), cyc2);
      join
      check("concurrent traffic didn't interfere",
            (cyc1 != -1) && (cyc2 != -1),
            $sformatf("tile(0,0)->tile(2,0) delivered cycle %0d, tile(0,2)->tile(2,2) delivered cycle %0d", cyc1, cyc2));
    end

    begin
      int cyc_near, cyc_far;
      fork
        send_and_check("contention near (1,0)->(2,0)", tile_id(1,0), mk_flit(2,0,8'h88), tile_id(2,0), cyc_near);
        send_and_check("contention far  (0,0)->(2,0)", tile_id(0,0), mk_flit(2,0,8'h99), tile_id(2,0), cyc_far);
      join
      check("cross-router contention arbitrated",
            (cyc_near != -1) && (cyc_far != -1) && (cyc_near != cyc_far),
            $sformatf("near-tile delivered cycle %0d, far-tile delivered cycle %0d (must differ, neither -1)", cyc_near, cyc_far));
    end

    @(posedge clk);
    // The RTL's embedded invariant checks (FIFO bounds, credit bounds,
    // bounded-wait fairness) report through noc_pkg::assertion_violations;
    // a run where any fired is a failed run, even if every directed check
    // above passed.
    check("RTL invariants held", assertion_violations == 0,
          $sformatf("%0d violation(s) of the FIFO/credit/fairness checks embedded in the RTL", assertion_violations));
    $display("================================================================");
    if (fail_count == 0)
      $display(" ALL TESTS PASSED  (%0d/%0d)", pass_count, pass_count + fail_count);
    else
      $display(" %0d TEST(S) FAILED  (%0d passed, %0d failed)", fail_count, pass_count, fail_count);
    $display("================================================================");

    $finish;
  end

  initial begin
    #5000;
    $display("[FAIL] watchdog timeout -- simulation did not finish in time");
    $finish;
  end

endmodule : mesh_credit_tb
