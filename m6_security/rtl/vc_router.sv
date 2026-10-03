`timescale 1ns/1ps
// vc_router.sv
//
// M5: M4's credit-based router rebuilt around VIRTUAL CHANNELS (VCs),
// grouped into VIRTUAL NETWORKS (VNs).
//
// Why: M4 measured that uniform random traffic saturates at ~0.72
// flits/node/cycle when the topology allows 1.0, and that doubling buffer
// depth barely helps. The cause is head-of-line (HOL) blocking -- one FIFO
// per input port means a flit waiting for a busy output blocks every flit
// behind it, even ones headed for idle outputs. VCs fix that by splitting
// each input's buffer into several independent FIFOs that share the one
// physical link:
//
//        M4: one FIFO per input                M5: NUM_VCS FIFOs per input
//
//   link --> [ E  N  S  L ] --> crossbar   link --+--> VC0 [ E  L ] --+
//             ^                                   +--> VC1 [ N    ] --+--> crossbar
//             E busy: N, S, L all wait            +--> VC2 [ S    ] --+
//                                                 (the link's `vc` signal
//                                                  picks the FIFO)
//
// VNs are a second, separate use of the same mechanism. A VN is a group of
// VCs reserved for one message class (REQ, SNP, RSP). A flit never leaves
// its VN, so one class's traffic can never fill the buffers another class
// needs. That's what prevents *protocol* (message-dependent) deadlock --
// see tb/protocol_tb.sv and the README for the deadlock this prevents.
//
//   VC numbering on every port: vc = vn * VCS_PER_VN + k,  k in [0, VCS_PER_VN)
//   e.g. NUM_VNS=3, VCS_PER_VN=2:   VN0 (REQ) = VC0,VC1   VN1 (SNP) = VC2,VC3   VN2 (RSP) = VC4,VC5
//
// Everything still happens in ONE cycle per hop, as in M4: a flit at the
// head of a VC FIFO is routed, allocated an output VC, wins the switch,
// and is written into the next router's FIFO at the next clock edge.
//
// Per cycle, in order (all combinational):
//   1. RC  route compute    XY routing on every VC FIFO's head flit.
//   2.     eligibility      a head flit is eligible if its output port has
//                           a free buffer (credit) in at least one VC of the
//                           flit's own VN.
//   3. SA  switch alloc.    separable, input-first: each input port picks
//                           ONE eligible VC (round-robin), then each output
//                           port picks ONE requesting input (round-robin).
//                           With SA_ITERS=2, a second pass repeats this for
//                           the inputs and outputs the first pass left
//                           unmatched (iSLIP-style: only first-pass wins
//                           rotate the round-robin pointers).
//   4. VA  VC allocation    the winner gets an output VC: round-robin among
//                           the VCs of its VN that have credit.
//   5. ST  switch traversal each input port's VC mux puts its winning VC's
//                           flit on that port's one crossbar input; the 5x5
//                           crossbar delivers it; the VC pops and returns
//                           one credit upstream, on that VC's wire.
// With single-flit packets, VC allocation is per flit, so it can come
// after switch allocation: step 2 already guaranteed a free VC exists.
//
// Port protocol, per port, per direction:
//   Forward  (sender -> receiver): valid, vc, data
//   Backward (receiver -> sender): credit_return[NUM_VCS] -- one pulse on
//     VC v's wire each time VC v's buffer frees a slot. One credit counter
//     per output VC here, exactly M4's scheme, just NUM_VCS times over.
//
// Configured as NUM_VNS=1, VCS_PER_VN=1 this is behaviorally identical to
// M4's router.sv -- tools/equivalence_check.sh verifies that by
// reproducing M4's whole latency/throughput sweep.
//
// Icarus discipline (as in M1-M4): every array index that varies at runtime
// is either a genvar/localparam or used in the single-loop copy shapes
// already proven safe; runtime values appear only inside comparisons.

import noc_pkg::*;

module vc_router #(
  parameter int X_ID         = 0,  // this router's column in the mesh
  parameter int Y_ID         = 0,  // this router's row in the mesh
  parameter int NUM_VNS      = 1,  // virtual networks: 1 (all classes share) or NUM_MCLASSES
  parameter int VCS_PER_VN   = 1,  // virtual channels inside each VN
  parameter int BUFFER_DEPTH = 4,  // flits per VC buffer
  parameter int SA_ITERS     = 1,  // switch-allocation passes per cycle: 1 or 2
  parameter int SECURE       = 1,  // M6: harden the local (tile-facing) port -- see below
  parameter int WD_LIMIT     = 256  // M6: cycles of ejection starvation before quarantine (see README)
) (
  input  logic clk,
  input  logic rst_n,

  // Input side of each port. in_vc[p*VC_W +: VC_W] names the VC buffer
  // the incoming flit goes into; the sender picked it and holds a credit
  // for it.
  input  logic  [NUM_PORTS-1:0]                    in_valid,
  input  logic  [NUM_PORTS*VC_W-1:0]               in_vc,
  input  flit_t [NUM_PORTS-1:0]                    in_data,
  output logic  [NUM_PORTS*NUM_VNS*VCS_PER_VN-1:0] in_credit_return, // [p*NUM_VCS + v]

  // Output side of each port.
  output logic  [NUM_PORTS-1:0]                    out_valid,
  output logic  [NUM_PORTS*VC_W-1:0]               out_vc,
  output flit_t [NUM_PORTS-1:0]                    out_data,
  input  logic  [NUM_PORTS*NUM_VNS*VCS_PER_VN-1:0] out_credit_return, // [o*NUM_VCS + w]

  // M6 security alarms (all 0 when SECURE=0):
  //   [0] pulse: a flit from the local tile was refused at ingress (wrong VN / no such VC)
  //   [1] level: the local ejection port is quarantined (tile stopped consuming)
  //   [2] pulse: a flit for the quarantined tile was discarded
  output logic  [2:0]                              alarm
);

  localparam int NUM_VCS  = NUM_VNS * VCS_PER_VN; // VCs per port
  localparam int NUM_IVC  = NUM_PORTS * NUM_VCS;  // input VCs in the router (= output VCs)
  localparam int CREDIT_W = $clog2(BUFFER_DEPTH+1);

  initial begin
    if (NUM_VCS > MAX_VCS) begin
      $display("CONFIG ERROR: vc_router NUM_VNS*VCS_PER_VN=%0d exceeds MAX_VCS=%0d (VC_W=%0d bits)",
                NUM_VCS, MAX_VCS, VC_W);
      $finish;
    end
    if (NUM_VNS != 1 && NUM_VNS != NUM_MCLASSES) begin
      $display("CONFIG ERROR: vc_router NUM_VNS=%0d; must be 1 (shared) or %0d (one per message class)",
                NUM_VNS, NUM_MCLASSES);
      $finish;
    end
    if (SA_ITERS != 1 && SA_ITERS != 2) begin
      $display("CONFIG ERROR: vc_router SA_ITERS=%0d; must be 1 or 2", SA_ITERS);
      $finish;
    end
  end

  // -------------------------------------------------------------------
  // Step 0: one FIFO per (input port, VC). Input VC index I = p*NUM_VCS + v.
  // A flit is pushed into the FIFO its link-level vc names; it leaves
  // when granted (fifo_pop), returning one credit on that same VC's wire.
  //
  // M6 -- the trust boundary. Router-to-router links are trusted hardware:
  // a flit there in the wrong VN is an RTL bug, so it's an assertion. The
  // LOCAL port faces a tile, which may be buggy or malicious, so with
  // SECURE=1 the router itself enforces two rules there:
  //   * Source stamping: the flit's src_x/src_y are overwritten with this
  //     router's own coordinates, so a tile can't claim to be another tile
  //     (the NoC version of BCP38 ingress filtering).
  //   * VN enforcement: a flit is accepted only into a VC of its own
  //     class's VN. Anything else -- wrong VN, or a VC that doesn't exist --
  //     is refused and raises alarm[0]. Its credit is NOT returned: a tile
  //     that breaks the rules can only starve itself.
  // With SECURE=0 the local port is simply unchecked (the M5 behavior an
  // attacker exploits; see tb/attack_*).
  // -------------------------------------------------------------------
  localparam int LOCAL = PORT_L;
  localparam logic [COORD_WIDTH-1:0] MY_X = X_ID;
  localparam logic [COORD_WIDTH-1:0] MY_Y = Y_ID;

  logic  [NUM_IVC-1:0] fifo_push;
  logic  [NUM_IVC-1:0] fifo_pop;
  logic  [NUM_IVC-1:0] fifo_empty;
  logic  [NUM_IVC-1:0] fifo_full;
  flit_t [NUM_IVC-1:0] fifo_head;
  logic                ingress_drop; // a local-port flit was refused this cycle

  genvar gp, gv;
  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_in_port
      flit_t raw, fin;
      assign raw = in_data[gp];

      if (SECURE != 0 && gp == LOCAL) begin : g_stamp
        assign fin = {raw.mclass, MY_X, MY_Y, raw.dest_x, raw.dest_y, raw.payload};
      end else begin : g_no_stamp
        assign fin = raw;
      end

      for (gv = 0; gv < NUM_VCS; gv++) begin : g_in_vc
        localparam int I  = gp*NUM_VCS + gv;
        localparam int VN = gv / VCS_PER_VN;
        logic arrives;
        assign arrives = in_valid[gp] && (in_vc[gp*VC_W +: VC_W] == gv);

        if (SECURE != 0 && gp == LOCAL && NUM_VNS > 1) begin : g_vn_guard
          assign fifo_push[I] = arrives && (fin.mclass == VN);
        end else begin : g_no_guard
          assign fifo_push[I] = arrives;
        end

        flit_fifo #(.DEPTH(BUFFER_DEPTH)) u_fifo (
          .clk       (clk),
          .rst_n     (rst_n),
          .push_en   (fifo_push[I]),
          .push_data (fin),
          .full      (fifo_full[I]),
          .pop_en    (fifo_pop[I]),
          .pop_data  (fifo_head[I]),
          .empty     (fifo_empty[I])
        );

        assign in_credit_return[I] = fifo_pop[I];

        // Verification-only, trusted links only: VN isolation. A flit may
        // only enter a VC of its own message class's VN; on a link between
        // two routers, a violation means a router upstream is broken.
        // That's only a guarantee when the ingress guard exists (SECURE):
        // without it, a tile can put any flit in any VN and these checks
        // would flag the TILE's misbehavior, not an RTL bug -- which is
        // exactly the vulnerability the SECURE=0 baseline demonstrates.
        if (gp != LOCAL && SECURE != 0) begin : g_link_vn_check
          always @(posedge clk) begin
            if (rst_n && fifo_push[I]) begin
              assert (noc_pkg::vn_of(fin.mclass, NUM_VNS) == VN) else begin
                $display("ASSERT-FAIL: router(%0d,%0d) port %0d: class-%0d flit arrived on VC %0d (VN %0d), but its class belongs to VN %0d",
                          X_ID, Y_ID, gp, fin.mclass, gv, VN, noc_pkg::vn_of(fin.mclass, NUM_VNS));
                assertion_violations = assertion_violations + 1;
              end
            end
          end
        end
      end

      if (gp != LOCAL) begin : g_link_vc_check
        // Verification-only: the upstream router named a VC that doesn't exist.
        always @(posedge clk) begin
          if (rst_n && in_valid[gp]) begin
            assert (in_vc[gp*VC_W +: VC_W] < NUM_VCS) else begin
              $display("ASSERT-FAIL: router(%0d,%0d) port %0d: flit arrived on VC %0d, router has only %0d VCs -- flit lost",
                        X_ID, Y_ID, gp, in_vc[gp*VC_W +: VC_W], NUM_VCS);
              assertion_violations = assertion_violations + 1;
            end
          end
        end
      end else if (SECURE != 0) begin : g_ingress_alarm
        assign ingress_drop = in_valid[gp] && !(|fifo_push[gp*NUM_VCS +: NUM_VCS]);
      end else begin : g_no_ingress_alarm
        assign ingress_drop = 1'b0;
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 1 (RC): XY routing for the head flit of every input VC.
  // -------------------------------------------------------------------
  logic [2:0] route_sel [NUM_IVC];

  genvar gi;
  generate
    for (gi = 0; gi < NUM_IVC; gi++) begin : g_route
      flit_t f;
      assign f = fifo_head[gi];

      // X first, then Y, then eject. (A continuous assign rather than an
      // always_comb: this Icarus build warns on every constant-indexed
      // array element written inside always_* blocks.)
      assign route_sel[gi] = (f.dest_x > X_ID) ? 3'(PORT_E)
                           : (f.dest_x < X_ID) ? 3'(PORT_W)
                           : (f.dest_y > Y_ID) ? 3'(PORT_S)
                           : (f.dest_y < Y_ID) ? 3'(PORT_N)
                           :                     3'(PORT_L); // arrived
    end
  endgenerate

  // -------------------------------------------------------------------
  // Output-VC credit counters, one per (output port, VC): index
  // O = o*NUM_VCS + w. Same update rule as M4, per VC.
  // -------------------------------------------------------------------
  logic [CREDIT_W-1:0] credit_count [NUM_IVC];
  logic [NUM_IVC-1:0]  ovc_has_credit;
  logic [NUM_IVC-1:0]  ovc_send; // this output VC carries a flit this cycle (set in Step 5)

  generate
    for (gi = 0; gi < NUM_IVC; gi++) begin : g_credit
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          credit_count[gi] <= BUFFER_DEPTH;
        end else begin
          case ({ovc_send[gi], out_credit_return[gi]})
            2'b10:   credit_count[gi] <= credit_count[gi] - 1'b1;
            2'b01:   credit_count[gi] <= credit_count[gi] + 1'b1;
            default: credit_count[gi] <= credit_count[gi];
          endcase
        end
      end

      assign ovc_has_credit[gi] = (credit_count[gi] != '0);

      // Verification-only: credit conservation, per output VC.
      always @(posedge clk) begin
        if (rst_n) begin
          assert (credit_count[gi] <= BUFFER_DEPTH) else begin
            $display("ASSERT-FAIL: router(%0d,%0d) output %0d VC %0d credit_count=%0d exceeds BUFFER_DEPTH=%0d",
                      X_ID, Y_ID, gi / NUM_VCS, gi % NUM_VCS, credit_count[gi], BUFFER_DEPTH);
            assertion_violations = assertion_violations + 1;
          end
        end
      end
    end
  endgenerate

  // Does output o have a free buffer in at least one VC of VN n?
  // vn_has_credit additionally counts a quarantined local ejection VN as
  // "open" (see the watchdog below): its flits get to leave -- into the bin.
  logic [NUM_PORTS*NUM_VNS-1:0] vn_has_credit_raw; // [o*NUM_VNS + n]
  logic [NUM_PORTS*NUM_VNS-1:0] vn_has_credit;
  logic [NUM_VNS-1:0]           quarantine;        // per VN, local ejection port only

  genvar go, gn;
  generate
    for (go = 0; go < NUM_PORTS; go++) begin : g_vn_credit_o
      for (gn = 0; gn < NUM_VNS; gn++) begin : g_vn_credit_n
        assign vn_has_credit_raw[go*NUM_VNS + gn] = |ovc_has_credit[go*NUM_VCS + gn*VCS_PER_VN +: VCS_PER_VN];
        if (go == LOCAL) begin : g_local
          assign vn_has_credit[go*NUM_VNS + gn] = vn_has_credit_raw[go*NUM_VNS + gn] || quarantine[gn];
        end else begin : g_link
          assign vn_has_credit[go*NUM_VNS + gn] = vn_has_credit_raw[go*NUM_VNS + gn];
        end
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // M6: credit-starvation watchdog on the local ejection port.
  //
  // A tile that stops consuming what's delivered to it (a "black hole")
  // stops returning ejection credits. Flits addressed to it then wait in
  // this router's input buffers -- and in the buffers behind those, and so
  // on: the backpressure spreads until traffic between tiles that have
  // nothing to do with it is stuck behind its flits (tree saturation).
  //
  // Per VN: if a flit is waiting for the local port and that VN has had no
  // ejection credit for WD_LIMIT consecutive cycles, the VN is QUARANTINED.
  // Its flits are then still switched to the local port, but discarded
  // instead of sent (alarm[2] pulses per flit), so the network drains. The
  // quarantine lifts the moment the tile returns a credit. A slow but
  // live consumer never trips it: any credit returned resets the count.
  //
  // WD_LIMIT trades detection delay against false alarms on legitimately
  // stalled tiles; the README measures how long honest tiles ever stall.
  // -------------------------------------------------------------------
  localparam int WD_W = $clog2(WD_LIMIT + 1);

  generate
    if (SECURE != 0) begin : g_watchdog
      for (gn = 0; gn < NUM_VNS; gn++) begin : g_vn
        logic [NUM_PORTS*VCS_PER_VN-1:0] waiting; // input VCs of this VN with a flit for the local port
        for (gp = 0; gp < NUM_PORTS; gp++) begin : g_p
          for (gv = 0; gv < VCS_PER_VN; gv++) begin : g_k
            localparam int I = gp*NUM_VCS + gn*VCS_PER_VN + gv;
            assign waiting[gp*VCS_PER_VN + gv] = !fifo_empty[I] && (route_sel[I] == LOCAL);
          end
        end

        logic            has_credit, starved, q;
        logic [WD_W-1:0] starve_cnt;
        assign has_credit     = vn_has_credit_raw[LOCAL*NUM_VNS + gn];
        assign starved        = |waiting && !has_credit;
        assign quarantine[gn] = q;

        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            starve_cnt <= '0;
            q          <= 1'b0;
          end else if (has_credit) begin          // the tile is consuming again
            starve_cnt <= '0;
            q          <= 1'b0;
          end else if (q) begin                   // stay quarantined until it does
            starve_cnt <= starve_cnt;
          end else if (starved) begin
            if (int'(starve_cnt) == WD_LIMIT - 1) q <= 1'b1;
            starve_cnt <= starve_cnt + 1'b1;
          end else begin
            starve_cnt <= '0;
          end
        end

        // Verification-only: longest starvation that did NOT trip the
        // watchdog, mesh-wide -- how close honest traffic comes to it.
        // (No reset gating: starve_cnt is 0 in reset. Blocking on purpose:
        // every router updates one shared maximum in the same timestep.)
        always @(posedge clk) begin
          /* verilator lint_off BLKSEQ */
          if (!q && int'(starve_cnt) > wd_max_starve) wd_max_starve = int'(starve_cnt);
          /* verilator lint_on BLKSEQ */
        end
      end
    end else begin : g_no_watchdog
      assign quarantine = '0;
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 2: eligibility. req_mat[o][I]: input VC I has a flit for output o,
  // and o has a free VC in I's VN. (I's VN is a constant: a flit's VN is
  // simply which VC it's sitting in -- the isolation check above is what
  // keeps that true.)
  // -------------------------------------------------------------------
  logic [NUM_IVC-1:0]   req_mat    [NUM_PORTS]; // [o][I]
  logic [NUM_PORTS-1:0] req_by_ivc [NUM_IVC];   // same bits, [I][o]
  logic [NUM_IVC-1:0]   elig;                   // I is eligible for *some* output

  generate
    for (go = 0; go < NUM_PORTS; go++) begin : g_req_o
      for (gi = 0; gi < NUM_IVC; gi++) begin : g_req_i
        localparam int VN_I = (gi % NUM_VCS) / VCS_PER_VN;
        assign req_mat[go][gi] = !fifo_empty[gi]
                                 && (route_sel[gi] == go)
                                 && vn_has_credit[go*NUM_VNS + VN_I];
        assign req_by_ivc[gi][go] = req_mat[go][gi];
      end
    end
    for (gi = 0; gi < NUM_IVC; gi++) begin : g_elig
      assign elig[gi] = |req_by_ivc[gi];
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 3 (SA): separable, input-first switch allocation.
  //
  //   Pass 1, input stage:  each input port nominates ONE eligible VC
  //                         (round-robin over its VCs).
  //   Pass 1, output stage: each output port grants ONE of the input
  //                         ports whose nominee wants it (round-robin --
  //                         M4's arbiter).
  //
  // A single pass wastes matches: an input whose nominee loses at the
  // output sends nothing, even if another of its VCs wants an output that
  // nobody won. With SA_ITERS=2, pass 2 repeats both stages over only what
  // pass 1 left unmatched (inputs that won nothing nominate among VCs that
  // want an output nobody won). Pass 2 scans in the same round-robin order
  // but never rotates the pointers -- only pass-1 wins do (iSLIP's rule),
  // which keeps pass 1's fairness bounds exact (checked below).
  // -------------------------------------------------------------------
  logic [NUM_VCS-1:0]   in_gnt   [NUM_PORTS]; // pass-1 nominee per input port, one-hot
  logic [NUM_VCS-1:0]   in_gnt2  [NUM_PORTS]; // pass-2 nominee
  logic [NUM_PORTS-1:0] out_req  [NUM_PORTS]; // pass-1 requests, [o][p]
  logic [NUM_PORTS-1:0] out_gnt  [NUM_PORTS]; // pass-1 grants, [o][p], one-hot per o
  logic [NUM_PORTS-1:0] out_req2 [NUM_PORTS]; // pass-2 requests
  logic [NUM_PORTS-1:0] out_gnt2 [NUM_PORTS]; // pass-2 grants
  logic [NUM_PORTS-1:0] in_won1;              // input p won an output in pass 1
  logic [NUM_PORTS-1:0] out_won1;             // output o granted someone in pass 1
  logic [NUM_IVC-1:0]   elig2;                // pass-2 eligibility
  logic [NUM_PORTS-1:0] xfer;                 // output o carries a granted flit this cycle (either pass)
  logic [NUM_PORTS-1:0] discard;              // ...which the M6 watchdog throws away instead of sending

  genvar gq;
  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_in_arb
      rr_arbiter #(.NUM_REQ(NUM_VCS)) u_in_arb (
        .clk     (clk),
        .rst_n   (rst_n),
        .req     (elig[gp*NUM_VCS +: NUM_VCS]),
        .advance (in_won1[gp]),
        .grant   (in_gnt[gp]),
        .req_b   (elig2[gp*NUM_VCS +: NUM_VCS]),
        .grant_b (in_gnt2[gp])
      );

      logic [NUM_PORTS-1:0] won_from;
      for (go = 0; go < NUM_PORTS; go++) begin : g_won_o
        assign won_from[go] = out_gnt[go][gp];
      end
      assign in_won1[gp] = |won_from;
    end

    for (go = 0; go < NUM_PORTS; go++) begin : g_out_arb
      for (gq = 0; gq < NUM_PORTS; gq++) begin : g_out_req
        assign out_req [go][gq] = |(in_gnt [gq] & req_mat[go][gq*NUM_VCS +: NUM_VCS]);
        assign out_req2[go][gq] = !out_won1[go] && |(in_gnt2[gq] & req_mat[go][gq*NUM_VCS +: NUM_VCS]);
      end

      rr_arbiter #(.NUM_REQ(NUM_PORTS)) u_out_arb (
        .clk     (clk),
        .rst_n   (rst_n),
        .req     (out_req[go]),
        .advance (out_won1[go]),
        .grant   (out_gnt[go]),
        .req_b   (out_req2[go]),
        .grant_b (out_gnt2[go])
      );

      assign out_won1[go]  = |out_req[go];
      assign xfer[go]      = out_won1[go] || |out_req2[go];
      // A transfer is a real send unless it's a quarantined flit being
      // discarded (M6 watchdog; discard is always 0 off the local port).
      assign out_valid[go] = xfer[go] && !discard[go];
    end

    for (gi = 0; gi < NUM_IVC; gi++) begin : g_elig2
      if (SA_ITERS == 2) begin : g_pass2
        logic [NUM_PORTS-1:0] wants_free_out;
        for (go = 0; go < NUM_PORTS; go++) begin : g_o
          assign wants_free_out[go] = req_mat[go][gi] && !out_won1[go];
        end
        assign elig2[gi] = !in_won1[gi / NUM_VCS] && |wants_free_out;
      end else begin : g_no_pass2
        assign elig2[gi] = 1'b0;
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 4 (ST): the datapath, in the canonical two levels:
  //
  //   input VC FIFOs --> one VC mux per input port --> 5x5 crossbar --> outputs
  //
  // Each input port has exactly ONE crossbar input. Its VC mux selects the
  // VC that won (in pass 1 or pass 2), and that VC pops. Each output then
  // takes the flit of the input port it granted. One flit per input port
  // per cycle is thus a property of the wiring, not just of the allocator.
  // It's also the cheaper structure: a flat (NUM_PORTS*NUM_VCS)-to-1 mux
  // per output would need ~2x the mux inputs at 4 VCs.
  // -------------------------------------------------------------------
  logic  [NUM_PORTS-1:0] in_won2;              // input p won an output in pass 2
  logic  [NUM_VCS-1:0]   win_vc   [NUM_PORTS]; // one-hot VC input p sends from this cycle (or 0)
  flit_t [NUM_PORTS-1:0] port_flit;            // input p's crossbar input
  logic  [NUM_PORTS-1:0] xbar_sel [NUM_PORTS]; // [o][p]: output o takes input p's flit

  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_vc_mux
      logic [NUM_PORTS-1:0] won2_from;
      for (go = 0; go < NUM_PORTS; go++) begin : g_o
        assign won2_from[go] = out_gnt2[go][gp];
      end
      assign in_won2[gp] = |won2_from;
      assign win_vc[gp]  = in_won1[gp] ? in_gnt[gp]
                         : in_won2[gp] ? in_gnt2[gp]
                         : {NUM_VCS{1'b0}};
      assign fifo_pop[gp*NUM_VCS +: NUM_VCS] = win_vc[gp];

      always_comb begin
        port_flit[gp] = '0;
        for (int v = 0; v < NUM_VCS; v++) begin
          if (win_vc[gp][v]) port_flit[gp] = fifo_head[gp*NUM_VCS + v];
        end
      end
    end

    for (go = 0; go < NUM_PORTS; go++) begin : g_xbar
      for (gp = 0; gp < NUM_PORTS; gp++) begin : g_p
        assign xbar_sel[go][gp] = out_gnt[go][gp] || out_gnt2[go][gp];
      end

      always_comb begin
        out_data[go] = '0;
        for (int p = 0; p < NUM_PORTS; p++) begin
          if (xbar_sel[go][p]) out_data[go] = port_flit[p];
        end
      end

      // Verification-only: an output takes at most one input.
      always @(posedge clk) begin
        if (rst_n) begin
          assert ($onehot0(xbar_sel[go])) else begin
            $display("ASSERT-FAIL: router(%0d,%0d) output %0d granted to several inputs at once (sel=%b) -- flits collide",
                      X_ID, Y_ID, go, xbar_sel[go]);
            assertion_violations = assertion_violations + 1;
          end
        end
      end
    end

    // Verification-only: an input feeds at most one output. Its crossbar
    // input carries one flit, so two grants would duplicate that flit and
    // silently drop the other VC's.
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_xbar_in_check
      logic [NUM_PORTS-1:0] taken_by;
      for (go = 0; go < NUM_PORTS; go++) begin : g_o
        assign taken_by[go] = xbar_sel[go][gp];
      end
      always @(posedge clk) begin
        if (rst_n) begin
          assert ($onehot0(taken_by)) else begin
            $display("ASSERT-FAIL: router(%0d,%0d) input %0d granted by several outputs at once (outputs=%b) -- one crossbar input can't feed them all",
                      X_ID, Y_ID, gp, taken_by);
            assertion_violations = assertion_violations + 1;
          end
        end
      end
    end
  endgenerate

  // -------------------------------------------------------------------
  // Step 5 (VA): give each sending output an output VC -- round-robin
  // among the VCs of the winning flit's VN that have credit. Step 2
  // guaranteed at least one exists.
  // -------------------------------------------------------------------
  logic [NUM_VNS-1:0] port_vn  [NUM_PORTS]; // one-hot VN of the flit input p sends
  logic [NUM_VNS-1:0] win_vn   [NUM_PORTS]; // one-hot VN of the flit output o sends
  logic [NUM_VCS-1:0] ovc_cand [NUM_PORTS];
  logic [NUM_VCS-1:0] ovc_gnt  [NUM_PORTS];

  genvar gw;
  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_port_vn
      for (gn = 0; gn < NUM_VNS; gn++) begin : g_n
        assign port_vn[gp][gn] = |win_vc[gp][gn*VCS_PER_VN +: VCS_PER_VN];
      end
    end

    for (go = 0; go < NUM_PORTS; go++) begin : g_va
      for (gn = 0; gn < NUM_VNS; gn++) begin : g_win_vn
        logic [NUM_PORTS-1:0] from_port;
        for (gp = 0; gp < NUM_PORTS; gp++) begin : g_p
          assign from_port[gp] = xbar_sel[go][gp] && port_vn[gp][gn];
        end
        assign win_vn[go][gn] = |from_port;
      end

      // M6: the flit switched to the local port belongs to a quarantined VN.
      if (go == LOCAL) begin : g_discard
        assign discard[go] = xfer[go] && |(win_vn[go] & quarantine);
      end else begin : g_no_discard
        assign discard[go] = 1'b0;
      end

      for (gw = 0; gw < NUM_VCS; gw++) begin : g_cand
        assign ovc_cand[go][gw] = win_vn[go][gw / VCS_PER_VN] && ovc_has_credit[go*NUM_VCS + gw];
        assign ovc_send[go*NUM_VCS + gw] = out_valid[go] && ovc_gnt[go][gw];
      end

      rr_arbiter #(.NUM_REQ(NUM_VCS)) u_ovc_arb (
        .clk     (clk),
        .rst_n   (rst_n),
        .req     (ovc_cand[go]),
        .advance (out_valid[go]),
        .grant   (ovc_gnt[go]),
        .req_b   ({NUM_VCS{1'b0}}),
        .grant_b ()
      );

      logic [VC_W-1:0] vc_enc;
      always_comb begin
        vc_enc = '0;
        for (int w = 0; w < NUM_VCS; w++) begin
          if (ovc_gnt[go][w]) vc_enc = w;
        end
      end
      assign out_vc[go*VC_W +: VC_W] = vc_enc;

      // Verification-only: every flit that leaves got an output VC.
      always @(posedge clk) begin
        if (rst_n && out_valid[go]) begin
          assert (|ovc_gnt[go]) else begin
            $display("ASSERT-FAIL: router(%0d,%0d) output %0d sent a flit with no output VC allocated",
                      X_ID, Y_ID, go);
            assertion_violations = assertion_violations + 1;
          end
        end
      end
    end
  endgenerate

  assign alarm = {discard[LOCAL], |quarantine, ingress_drop};

  // -------------------------------------------------------------------
  // Verification-only: fairness (no starvation), checked at both
  // allocator stages. Both bounds follow from round-robin with the pointer
  // update rules above, and hold exactly -- so each is a tight check,
  // not a timeout.
  //
  //   Output stage: an input port that keeps requesting output o in pass 1
  //   is granted within NUM_PORTS-1 grants to others (M4's check, tightened).
  //
  //   Input stage: a VC that stays eligible sees at most NUM_VCS-1 pass-1
  //   wins by the other VCs of its port before it sends itself. (Each such
  //   win moves the port's pointer strictly closer to it. Pass-2 sends by
  //   other VCs don't count against it: they never move the pointer, and
  //   they only use outputs this VC wasn't competing for in that cycle.)
  //
  // See noc_pkg::assertion_violations for why these are counters feeding
  // immediate assertions rather than `assert property`.
  // -------------------------------------------------------------------
  generate
    for (go = 0; go < NUM_PORTS; go++) begin : g_fair_out_o
      for (gq = 0; gq < NUM_PORTS; gq++) begin : g_fair_out_p
        int waited;
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            waited <= 0;
          end else begin
            if (out_req[go][gq] && !out_gnt[go][gq]) waited <= waited + 1;
            else                                     waited <= 0;
            assert (waited <= NUM_PORTS-1) else begin
              $display("ASSERT-FAIL: router(%0d,%0d) input %0d requested output %0d for %0d cycles without a grant (output arbiter starvation)",
                        X_ID, Y_ID, gq, go, waited);
              assertion_violations = assertion_violations + 1;
            end
          end
        end
      end
    end

    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_fair_in_p
      for (gv = 0; gv < NUM_VCS; gv++) begin : g_fair_in_v
        localparam int I = gp*NUM_VCS + gv;
        int bypassed;
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            bypassed <= 0;
          end else begin
            if (!elig[I] || fifo_pop[I]) bypassed <= 0;
            else if (in_won1[gp])        bypassed <= bypassed + 1;
            assert (bypassed <= NUM_VCS-1) else begin
              $display("ASSERT-FAIL: router(%0d,%0d) input %0d VC %0d stayed eligible while other VCs of its port won %0d first-pass grants (input arbiter starvation)",
                        X_ID, Y_ID, gp, gv, bypassed);
              assertion_violations = assertion_violations + 1;
            end
          end
        end
      end
    end
  endgenerate

endmodule : vc_router
