// flit_fifo_tb.sv
//
// Unit test for flit_fifo.sv in isolation, before it's ever wired into
// the credit-based router: push/pop ordering, full/empty flags,
// wraparound past the physical end of the circular buffer, and
// simultaneous push+pop on a non-empty FIFO. router_tb.sv exercises the
// FIFO again as part of the whole router, but bugs here are much cheaper
// to find at this level.

`timescale 1ns/1ps
import noc_pkg::*;

module flit_fifo_tb;
  logic clk = 0;
  logic rst_n;
  logic push_en, pop_en, full, empty;
  flit_t push_data, pop_data;

  flit_fifo #(.DEPTH(4)) dut (
    .clk(clk), .rst_n(rst_n),
    .push_en(push_en), .push_data(push_data), .full(full),
    .pop_en(pop_en), .pop_data(pop_data), .empty(empty)
  );

  always #5 clk = ~clk;

  int errors = 0;
  flit_t got;

  task automatic mk(output flit_t f, input int dx, input int dy, input int pay);
    f.dest_x = dx[3:0]; f.dest_y = dy[3:0]; f.payload = pay[7:0];
  endtask

  task automatic tick(); @(posedge clk); #1; endtask

  task automatic expect_eq(input string name, input bit cond);
    if (cond) $display("[PASS] %s", name);
    else begin $display("[FAIL] %s", name); errors++; end
  endtask

  initial begin
    flit_t f0, f1, f2, f3, f4;

    $dumpfile("sim/flit_fifo_tb.vcd");
    $dumpvars(0, flit_fifo_tb);

    mk(f0, 0,0,10); mk(f1, 1,1,11); mk(f2, 2,2,12); mk(f3, 3,3,13); mk(f4, 4,4,14);

    push_en = 0; pop_en = 0; push_data = '0;
    rst_n = 0;
    repeat (2) @(posedge clk);
    #1;
    rst_n = 1;
    tick();

    expect_eq("starts empty", empty === 1'b1);
    expect_eq("starts not full", full === 1'b0);

    // push 4 (fills DEPTH=4), then confirm full
    push_en = 1;
    push_data = f0; tick();
    push_data = f1; tick();
    push_data = f2; tick();
    push_data = f3; tick();
    push_en = 0;
    expect_eq("full after 4 pushes into depth-4 fifo", full === 1'b1);
    expect_eq("not empty after pushes", empty === 1'b0);

    // try to push a 5th while full -- should be dropped (push_en gated by !full internally)
    push_en = 1; push_data = f4; tick(); push_en = 0;
    expect_eq("still full, 5th push had no effect", full === 1'b1);

    // pop all 4, checking FIFO order and data integrity
    pop_en = 1;
    got = pop_data; expect_eq("pop order 1: f0", got === f0); tick();
    got = pop_data; expect_eq("pop order 2: f1", got === f1); tick();
    got = pop_data; expect_eq("pop order 3: f2", got === f2); tick();
    got = pop_data; expect_eq("pop order 4: f3", got === f3); tick();
    pop_en = 0;

    expect_eq("empty again after draining", empty === 1'b1);
    expect_eq("not full after draining", full === 1'b0);

    // wraparound: push+pop interleaved past the physical end of mem[]
    push_en = 1; push_data = f4; tick(); push_en = 0;
    pop_en = 1; got = pop_data; expect_eq("wraparound pop: f4", got === f4); tick(); pop_en = 0;
    expect_eq("empty after wraparound push+pop", empty === 1'b1);

    // simultaneous push+pop on a non-empty fifo: occupancy unchanged, order preserved
    push_en = 1; push_data = f0; tick(); push_en = 0; // occupancy=1 (f0)
    push_en = 1; pop_en = 1; push_data = f1; // push f1 while popping f0, same cycle
    got = pop_data; expect_eq("simul push+pop pops existing head f0", got === f0);
    tick();
    push_en = 0; pop_en = 0;
    expect_eq("occupancy still 1 after simultaneous push+pop", !empty && !full);
    got = pop_data; expect_eq("remaining entry is f1", got === f1);

    if (errors == 0) $display("ALL FIFO SMOKE CHECKS PASSED");
    else $display("%0d FIFO SMOKE CHECK(S) FAILED", errors);
    $finish;
  end
endmodule
