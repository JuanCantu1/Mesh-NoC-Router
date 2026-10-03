// router_credit.sv -- formal check of the credit protocol on every port of
// one vc_router, for ALL input sequences up to the proof depth.
//
// The router's neighbors are modeled by ASSUMPTIONS (what a correct
// neighbor does), and the router's own obligations are ASSERTIONS:
//
//   assume  upstream: a sender only sends on a VC it holds a credit for
//           (shadow counter per input port & VC: -1 on send, +1 on each
//           credit the router returns), and names a VC that exists
//   assume  downstream: a receiver only returns a credit for a flit it is
//           holding (shadow occupancy per output port & VC)
//   assert  C1  the router never sends into a full downstream buffer
//   assert  C2  the router never returns a credit it doesn't owe
//               (a sender's credits never exceed BUFFER_DEPTH)
//   assert  C3  every flit leaves on a VC that exists
//   assert  C4  every flit leaves in its own class's VN (with VNs)
//
// Flit contents, arrival times, VC choices and credit returns are all
// free: the solver picks the worst case. Simulation in M4-M6 checked these
// properties for the traffic that ran; this checks them for every trace
// of the given depth.

module router_credit #(
  parameter int NUM_VNS      = 1,
  parameter int VCS_PER_VN   = 2,
  parameter int BUFFER_DEPTH = 2,
  parameter int SA_ITERS     = 2,
  parameter int SECURE       = 1,
  parameter int PIPE         = 0
) (
  input  logic                                   clk,
  input  noc_pkg::flit_t [noc_pkg::NUM_PORTS-1:0] in_data,
  input  logic [noc_pkg::NUM_PORTS-1:0]           in_valid,
  input  logic [noc_pkg::NUM_PORTS*noc_pkg::VC_W-1:0] in_vc,
  input  logic [noc_pkg::NUM_PORTS*NUM_VNS*VCS_PER_VN-1:0] out_credit_return
);
  import noc_pkg::*;

  localparam int NUM_VCS = NUM_VNS * VCS_PER_VN;
  localparam int P       = NUM_PORTS;

  logic started = 1'b0;
  always @(posedge clk) started <= 1'b1;
  wire rst_n = started;

  logic  [P*NUM_VCS-1:0] in_credit_return;
  logic  [P-1:0]         out_valid;
  logic  [P*VC_W-1:0]    out_vc;
  flit_t [P-1:0]         out_data;
  logic  [2:0]           alarm;

  vc_router #(
    .X_ID(1), .Y_ID(1), .NUM_VNS(NUM_VNS), .VCS_PER_VN(VCS_PER_VN),
    .BUFFER_DEPTH(BUFFER_DEPTH), .SA_ITERS(SA_ITERS), .SECURE(SECURE), .PIPE(PIPE)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_vc(in_vc), .in_data(in_data), .in_credit_return(in_credit_return),
    .out_valid(out_valid), .out_vc(out_vc), .out_data(out_data), .out_credit_return(out_credit_return),
    .alarm(alarm)
  );

  genvar gp, gv;
  generate
    for (gp = 0; gp < P; gp++) begin : g_port
      wire [VC_W-1:0] ivc = in_vc[gp*VC_W +: VC_W];
      wire [VC_W-1:0] ovc = out_vc[gp*VC_W +: VC_W];
      flit_t of;
      assign of = out_data[gp];

      // upstream sender: never sends on a nonexistent VC (C3's mirror)
      always @(*) if (started) assume (!in_valid[gp] || ivc < NUM_VCS);

      // The trust boundary (M6), stated explicitly: a neighboring ROUTER
      // keeps VN discipline (it's this same verified hardware), so on the
      // four link ports a flit arrives in its own class's VN. The LOCAL
      // port gets no such assumption -- the tile may send anything, and C4
      // must still hold. (The first version of this harness left this out;
      // the solver promptly delivered a REQ-class flit on the RSP VC over
      // the West link, and the router -- correctly -- forwarded it.)
      flit_t inf;
      assign inf = in_data[gp];
      if (gp != PORT_L && NUM_VNS > 1) begin : g_trusted_link
        always @(*) if (started) assume (!in_valid[gp] || (ivc / VCS_PER_VN) == inf.mclass);
      end

      for (gv = 0; gv < NUM_VCS; gv++) begin : g_vc
        localparam int I = gp*NUM_VCS + gv;

        // ---- upstream sender's credit counter for (port, VC) ----
        logic [3:0] up_cred = BUFFER_DEPTH;
        wire sent = in_valid[gp] && (ivc == gv);
        always @(posedge clk) begin
          if (!started) up_cred <= BUFFER_DEPTH;
          else          up_cred <= up_cred - sent + in_credit_return[I];
        end
        always @(*) if (started) assume (!sent || up_cred != 0);
        // C2: the router never hands back a credit it didn't take
        always @(*) if (started) assert (up_cred <= BUFFER_DEPTH);

        // ---- downstream receiver's occupancy for (port, VC) ----
        logic [3:0] dn_held = '0;
        wire arrives = out_valid[gp] && (ovc == gv);
        always @(posedge clk) begin
          if (!started) dn_held <= '0;
          else          dn_held <= dn_held + arrives - out_credit_return[I];
        end
        always @(*) if (started) assume (!out_credit_return[I] || dn_held != 0);
        // C1: never send into a full downstream buffer
        always @(*) if (started && arrives) assert (dn_held < BUFFER_DEPTH);
      end

      // C3 / C4: every departing flit is on a real VC, in its class's VN
      always @(*) begin
        if (started && out_valid[gp]) begin
          assert (ovc < NUM_VCS);
          if (NUM_VNS > 1) assert ((ovc / VCS_PER_VN) == of.mclass);
        end
      end
    end
  endgenerate

endmodule
