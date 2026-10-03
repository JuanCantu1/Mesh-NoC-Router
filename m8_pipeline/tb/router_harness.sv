// router_harness.sv
//
// Test harness around ONE vc_router at mesh position (1,1) -- the center
// of a 3x3 grid, so every output (N/S/E/W/Local) is a legal direction.
// vc_router_tb.sv instantiates several of these with different
// configurations and drives them through hierarchical task calls, so the
// same scenario can be replayed on, say, a 1-VC and a 2-VC router side by
// side.
//
// What it models around the router:
//   * Upstream senders on all 5 input ports, one credit counter per VC,
//     exactly like a neighboring router would keep. stage() refuses to
//     send without a credit (that would be a testbench bug).
//   * Downstream receivers on all 5 output ports, one buffer per VC that
//     drains one flit per cycle -- unless the test STALLS it, which is how
//     tests make an output (or one VC of it) run out of credit on purpose.
//   * An event log of every flit that leaves the router: cycle, output
//     port, output VC, payload. Tests identify flits by unique payloads.
//
// Usage pattern from the testbench, once per cycle:
//   @(negedge clk); h.stage(port, vc, flit); h.stage(...); ...  // up to one per input port
//   @(posedge clk); #1; h.unstage();                              // flits are now inside
// or simply h.idle(n) to let n cycles pass.

`timescale 1ns/1ps

`ifndef TB_PIPE
  `define TB_PIPE 0
`endif

import noc_pkg::*;

module router_harness #(
  parameter int NUM_VNS      = 1,
  parameter int VCS_PER_VN   = 1,
  parameter int BUFFER_DEPTH = 4,
  parameter int SA_ITERS     = 1,
  parameter int SECURE       = 1,
  parameter int WD_LIMIT     = 256,
  parameter int PIPE         = `TB_PIPE   // M8: every harness router two-stage when -DTB_PIPE=1
) (
  input logic clk,
  input logic rst_n
);

  localparam int NUM_VCS = NUM_VNS * VCS_PER_VN;
  localparam int NUM_OVC = NUM_PORTS * NUM_VCS;
  localparam int EV_MAX  = 4096;

  logic  [NUM_PORTS-1:0]      in_valid;
  logic  [NUM_PORTS*VC_W-1:0] in_vc;
  flit_t [NUM_PORTS-1:0]      in_data;
  logic  [NUM_OVC-1:0]        in_credit_return;
  logic  [NUM_PORTS-1:0]      out_valid;
  logic  [NUM_PORTS*VC_W-1:0] out_vc;
  flit_t [NUM_PORTS-1:0]      out_data;
  logic  [NUM_OVC-1:0]        out_credit_return;
  logic  [2:0]                alarm;

  vc_router #(
    .X_ID(1), .Y_ID(1),
    .NUM_VNS(NUM_VNS), .VCS_PER_VN(VCS_PER_VN), .BUFFER_DEPTH(BUFFER_DEPTH), .SA_ITERS(SA_ITERS),
    .SECURE(SECURE), .WD_LIMIT(WD_LIMIT), .PIPE(PIPE)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_vc(in_vc), .in_data(in_data), .in_credit_return(in_credit_return),
    .out_valid(out_valid), .out_vc(out_vc), .out_data(out_data), .out_credit_return(out_credit_return),
    .alarm(alarm)
  );

  // M6: alarm counters (pulses counted per cycle; level = cycles quarantined)
  int n_refused;      // alarm[0]: local-port flits refused at ingress
  int n_quar_cycles;  // alarm[1]: cycles the local port spent quarantined
  int n_discarded;    // alarm[2]: flits discarded for the quarantined tile
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      n_refused <= 0; n_quar_cycles <= 0; n_discarded <= 0;
    end else begin
      n_refused     <= n_refused     + alarm[0];
      n_quar_cycles <= n_quar_cycles + alarm[1];
      n_discarded   <= n_discarded   + alarm[2];
    end
  end

  // ---------------------------------------------------------------------
  // Downstream receivers: one buffer per (output port, VC). Index
  // i = port*NUM_VCS + vc. Releases (= returns a credit) one flit per
  // cycle unless stalled.
  // ---------------------------------------------------------------------
  logic [7:0]         ds_count [NUM_OVC];
  logic [NUM_OVC-1:0] ds_stall;
  logic [NUM_OVC-1:0] ds_release;

  genvar gi;
  generate
    for (gi = 0; gi < NUM_OVC; gi++) begin : g_ds
      localparam int O = gi / NUM_VCS;
      localparam int W = gi % NUM_VCS;
      logic arriving;
      assign arriving       = out_valid[O] && (out_vc[O*VC_W +: VC_W] == W);
      assign ds_release[gi] = !ds_stall[gi] && (ds_count[gi] != 0);

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ds_count[gi] <= '0;
        else        ds_count[gi] <= ds_count[gi] + arriving - ds_release[gi];
      end
    end
  endgenerate
  assign out_credit_return = ds_release;

  // ---------------------------------------------------------------------
  // Upstream senders: credit per (input port, VC).
  // ---------------------------------------------------------------------
  int send_credit [NUM_PORTS][NUM_VCS];
  bit staged      [NUM_PORTS];
  int staged_vc   [NUM_PORTS];
  int errors;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int p = 0; p < NUM_PORTS; p++)
        for (int v = 0; v < NUM_VCS; v++) send_credit[p][v] <= BUFFER_DEPTH;
    end else begin
      for (int p = 0; p < NUM_PORTS; p++) begin
        for (int v = 0; v < NUM_VCS; v++) begin
          bit sent, returned;
          sent     = staged[p] && (staged_vc[p] == v);
          returned = in_credit_return[p*NUM_VCS + v];
          case ({sent, returned})
            2'b10:   send_credit[p][v] <= send_credit[p][v] - 1;
            2'b01:   send_credit[p][v] <= send_credit[p][v] + 1;
            default: send_credit[p][v] <= send_credit[p][v];
          endcase
        end
      end
    end
  end

  // ---------------------------------------------------------------------
  // Output event log.
  // ---------------------------------------------------------------------
  int cyc;
  int ev_count;
  int ev_cycle   [EV_MAX];
  int ev_port    [EV_MAX];
  int ev_vc      [EV_MAX];
  int ev_payload [EV_MAX];
  int ev_src_x   [EV_MAX];
  int ev_src_y   [EV_MAX];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cyc      <= 0;
      ev_count <= 0;
    end else begin
      int n;
      cyc <= cyc + 1;
      n = ev_count;
      for (int o = 0; o < NUM_PORTS; o++) begin
        if (out_valid[o]) begin
          flit_t f;
          f = out_data[o];
          ev_cycle[n]   = cyc;
          ev_port[n]    = o;
          ev_vc[n]      = out_vc[o*VC_W +: VC_W];
          ev_payload[n] = f.payload;
          ev_src_x[n]   = f.src_x;
          ev_src_y[n]   = f.src_y;
          n = n + 1;
        end
      end
      ev_count <= n;
    end
  end

  // ---------------------------------------------------------------------
  // Test-facing tasks and queries.
  // ---------------------------------------------------------------------
  initial begin
    in_valid = '0;
    in_vc    = '0;
    in_data  = '0;
    ds_stall = '0;
    errors   = 0;
    for (int p = 0; p < NUM_PORTS; p++) begin
      staged[p]    = 1'b0;
      staged_vc[p] = 0;
    end
  end

  // Build a flit addressed to (dx,dy), claiming source (0,0).
  function automatic flit_t mk(input int mc, input int dx, input int dy, input int payload);
    flit_t f;
    f.mclass  = mc;
    f.src_x   = 0;
    f.src_y   = 0;
    f.dest_x  = dx;
    f.dest_y  = dy;
    f.payload = payload;
    mk = f;
  endfunction

  // Same, with an explicit (possibly forged) source.
  function automatic flit_t mk_src(input int mc, input int dx, input int dy, input int payload,
                                   input int sx, input int sy);
    flit_t f;
    f = mk(mc, dx, dy, payload);
    f.src_x = sx;
    f.src_y = sy;
    mk_src = f;
  endfunction

  // Call between a negedge and the following posedge.
  task automatic stage(input int port, input int vc, input flit_t f);
    if (send_credit[port][vc] <= 0) begin
      errors = errors + 1;
      $display("[TB-ERROR] harness: stage() on port %0d VC %0d with no credit", port, vc);
    end else begin
      in_valid[port]               = 1'b1;
      in_vc[port*VC_W +: VC_W]     = vc;
      in_data[port]                = f;
      staged[port]                 = 1'b1;
      staged_vc[port]              = vc;
    end
  endtask

  // Call after the posedge that consumed the staged flits.
  task automatic unstage();
    in_valid = '0;
    in_data  = '0;
    for (int p = 0; p < NUM_PORTS; p++) staged[p] = 1'b0;
  endtask

  // One flit in, one cycle.
  task automatic send1(input int port, input int vc, input flit_t f);
    @(negedge clk);
    stage(port, vc, f);
    @(posedge clk); #1;
    unstage();
  endtask

  task automatic idle(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic stall(input int port, input int vc, input bit s);
    ds_stall[port*NUM_VCS + vc] = s;
  endtask

  // Index of the event carrying `payload`, or -1 if it hasn't left yet.
  function automatic int find(input int payload);
    find = -1;
    for (int i = 0; i < ev_count; i++)
      if (find == -1 && ev_payload[i] == payload) find = i;
  endfunction

endmodule : router_harness
