// protocol_tb.sv
//
// Coherence-style protocol traffic over vc_mesh.sv: the testbench that
// shows *protocol deadlock* -- and that virtual networks prevent it.
//
// Every tile plays three roles at once. One transaction is a chain of
// three single-flit messages, each one triggered by the one before:
//
//      requester ---REQ---> home ---SNP---> owner ---RSP---> requester
//      ("I want line X")    ("you hold X;    ("here it is")
//                            send it to R")
//
// The rules each endpoint follows are the ones real coherence agents have
// to follow, because they have finite storage:
//   * A home can only accept a REQ if it has room to queue the SNP it now
//     owes. Otherwise the REQ stays at the head of its receive buffer.
//   * An owner can only accept a SNP if it has room to queue the RSP.
//   * A requester ALWAYS accepts an RSP (it reserved room when it asked).
//   * Each requester has at most OUTSTANDING transactions in flight.
//
// So a REQ's progress depends on SNPs moving, and a SNP's on RSPs moving.
// If all three classes share the same buffers (NUM_VNS=1), the network
// can fill with REQs that can't be accepted. The SNPs and RSPs that would
// free them can't get through, because the buffers they need are full of
// those same REQs: a cycle of waiting with no way out. With one VN per
// class (NUM_VNS=3), RSPs always have buffers of their own, so they always
// drain, so SNPs always drain, so REQs always drain. The cycle can't form.
//
// The testbench detects deadlock directly. If transactions are
// outstanding but nothing has moved anywhere -- no injection, no
// delivery, no message processed -- for STALL_LIMIT cycles, the system is
// stuck for good. It then prints where every stuck message is.
//
// Checks on every delivered message: right destination, right VN for its
// class, true source, and that it's the message its transaction is
// actually waiting for (REQ at the home, SNP at the owner, RSP back at
// the requester). Plus all RTL invariants.
//
// Compile-time (defaults): -DPROTO_NUM_VNS=<1|3> (3)  -DPROTO_VCS_PER_VN=<n> (1)
//                          -DPROTO_BUFFER_DEPTH=<n> (4)  -DPROTO_SA_ITERS=<1|2> (1)
// Runtime: +OUTSTANDING=<n> per-requester limit (8)   +RATE=<permille> (1000)
//          +SEED=<n> (1)   +CYCLES=<n> traffic phase (20000)   +NODUMP
//          +EXPECT_DEADLOCK  the run passes only if deadlock IS detected
//                            (used to show the shared configuration's hazard)
//
// M6 -- the same traffic with a malicious tile, and the router's defenses:
//   -DPROTO_SECURE=<0|1> (1)  harden every router's tile-facing port
//   -DPROTO_WD_LIMIT=<n> (256)
//   -DPROTO_PIPE=<0|1> (0)     M8: two-stage routers
//   +ATTACK=<n>  +ATTACKER=<tile> (8)  +EXPECT_COMPROMISE
//
//   Homes enforce an access-control list (in every mode): a PROTECTED
//   transaction may only be requested by a TRUSTED tile (the top row,
//   y == 0). Trusted tiles' odd-numbered transactions are protected -- a
//   deterministic rule, so honest traffic is identical to M5's.
//
//   ATTACK=1  SOURCE SPOOFING. The attacker issues protected requests with
//             a trusted tile's coordinates written into the flit's source
//             field. A home that serves one has served a protected request
//             to an untrusted initiator: a BREACH. (Its response is
//             delivered to the impersonated tile as an UNSOLICITED response
//             -- the NoC version of a reflection attack.) Defense: the
//             router stamps the true source at ingress; the home sees the
//             attacker and denies.
//   ATTACK=2  VN HOPPING. The attacker floods requests into the RESPONSE
//             network (it's less congested -- a greedy tile's shortcut).
//             Requests in the RSP VN break the "RSPs always drain" argument
//             that made VNs deadlock-free. Defense: the router refuses
//             flits outside their class's VN at ingress.
//   ATTACK=3  FLOOD (control). The same flood, in the correct VN. Shows it's
//             the VN violation, not the extra load, that does the damage.
//
//   Under attack, honest tiles never choose the attacker as home or owner:
//   a tile that simply refuses to serve stalls transactions at the
//   protocol level, which no network defense can fix (timeouts can) --
//   out of scope here. With no attack, any security alarm is a false
//   positive and fails the run.

`timescale 1ns/1ps

import noc_pkg::*;

module protocol_tb;

`ifndef PROTO_MESH_W
  `define PROTO_MESH_W 3
`endif
`ifndef PROTO_MESH_H
  `define PROTO_MESH_H 3
`endif
`ifndef PROTO_NUM_VNS
  `define PROTO_NUM_VNS 3
`endif
`ifndef PROTO_VCS_PER_VN
  `define PROTO_VCS_PER_VN 1
`endif
`ifndef PROTO_BUFFER_DEPTH
  `define PROTO_BUFFER_DEPTH 4
`endif
`ifndef PROTO_SA_ITERS
  `define PROTO_SA_ITERS 1
`endif
`ifndef PROTO_SECURE
  `define PROTO_SECURE 1
`endif
`ifndef PROTO_WD_LIMIT
  `define PROTO_WD_LIMIT 256
`endif
`ifndef PROTO_PIPE
  `define PROTO_PIPE 0
`endif

  localparam int MESH_W       = `PROTO_MESH_W;
  localparam int MESH_H       = `PROTO_MESH_H;
  localparam int NUM_TILES    = MESH_W*MESH_H;
  localparam int NUM_VNS      = `PROTO_NUM_VNS;
  localparam int VCS_PER_VN   = `PROTO_VCS_PER_VN;
  localparam int NUM_VCS      = NUM_VNS*VCS_PER_VN;
  localparam int BUFFER_DEPTH = `PROTO_BUFFER_DEPTH;
  localparam int SA_ITERS     = `PROTO_SA_ITERS;
  localparam int SECURE       = `PROTO_SECURE;
  localparam int WD_LIMIT     = `PROTO_WD_LIMIT;
  localparam int PIPE         = `PROTO_PIPE;
  localparam int FORGED_TILE  = 0;     // the trusted tile the spoofing attacker impersonates
  localparam int RSP_VN       = 2;     // where the VN-hopping attacker puts its requests

  localparam int OUTQ_DEPTH   = 2;     // per-tile, per-class queue of messages waiting to be injected
  localparam int NUM_TXN_IDS  = 4096;  // 12-bit transaction IDs
  localparam int DRAIN_LIMIT  = 20000; // cycles allowed to finish outstanding work after traffic stops
  localparam int STALL_LIMIT  = 500;   // cycles of zero movement anywhere = deadlock
  localparam int FLIT_W       = $bits(flit_t);

  int  max_outstanding;
  int  rate_permille;
  int  seed;        // RNG state ($random advances it)
  int  seed_arg;    // the +SEED value, for reporting
  int  run_cycles;
  bit  expect_deadlock;
  int  attack_mode;        // 0 none, 1 spoof, 2 VN hop, 3 flood (control)
  int  attacker;
  bit  expect_compromise;

  logic clk = 0;
  logic rst_n;

  logic  [NUM_TILES-1:0]         local_in_valid;
  logic  [NUM_TILES*VC_W-1:0]    local_in_vc;
  flit_t [NUM_TILES-1:0]         local_in_data;
  logic  [NUM_TILES*NUM_VCS-1:0] local_in_credit_return;

  logic  [NUM_TILES-1:0]         local_out_valid;
  logic  [NUM_TILES*VC_W-1:0]    local_out_vc;
  flit_t [NUM_TILES-1:0]         local_out_data;
  logic  [NUM_TILES*NUM_VCS-1:0] local_out_credit_return;
  logic  [NUM_TILES*3-1:0]       tile_alarm;

  vc_mesh #(
    .MESH_W(MESH_W), .MESH_H(MESH_H),
    .NUM_VNS(NUM_VNS), .VCS_PER_VN(VCS_PER_VN), .BUFFER_DEPTH(BUFFER_DEPTH),
    .SA_ITERS(SA_ITERS), .SECURE(SECURE), .WD_LIMIT(WD_LIMIT), .PIPE(PIPE)
  ) dut (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .local_in_valid          (local_in_valid),
    .local_in_vc             (local_in_vc),
    .local_in_data           (local_in_data),
    .local_in_credit_return  (local_in_credit_return),
    .local_out_valid         (local_out_valid),
    .local_out_vc            (local_out_vc),
    .local_out_data          (local_out_data),
    .local_out_credit_return (local_out_credit_return),
    .tile_alarm              (tile_alarm)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------------
  // Per-tile views of the flattened vectors, and the receive side: one
  // buffer per (tile, VC), popped only when the endpoint can actually
  // process its head message (that's the whole point -- see above).
  // Index i = tile*NUM_VCS + vc.
  // ---------------------------------------------------------------------
  logic  [VC_W-1:0]              inj_vc   [NUM_TILES];
  logic  [VC_W-1:0]              arr_vc   [NUM_TILES];
  logic  [NUM_VCS-1:0]           in_cr_of [NUM_TILES];
  flit_t [NUM_TILES*NUM_VCS-1:0] rx_head;
  logic  [NUM_TILES*NUM_VCS-1:0] rx_empty;
  logic  [NUM_TILES*NUM_VCS-1:0] rx_pop;   // driven at negedge by the endpoint models

  genvar gt, gv;
  generate
    for (gt = 0; gt < NUM_TILES; gt++) begin : g_tile
      assign local_in_vc[gt*VC_W +: VC_W] = inj_vc[gt];
      assign arr_vc[gt]                   = local_out_vc[gt*VC_W +: VC_W];
      assign in_cr_of[gt]                 = local_in_credit_return[gt*NUM_VCS +: NUM_VCS];

      for (gv = 0; gv < NUM_VCS; gv++) begin : g_rx_vc
        localparam int I = gt*NUM_VCS + gv;
        logic rx_full;
        flit_fifo #(.DEPTH(BUFFER_DEPTH)) u_rx (
          .clk(clk), .rst_n(rst_n),
          .push_en(local_out_valid[gt] && (local_out_vc[gt*VC_W +: VC_W] == gv)),
          .push_data(local_out_data[gt]), .push_tag(1'b0), .pop_tag(), .full(rx_full),
          .pop_en(rx_pop[I]), .pop_data(rx_head[I]), .empty(rx_empty[I])
        );
        assign local_out_credit_return[I] = rx_pop[I] && !rx_empty[I];
      end
    end
  endgenerate

  // Sender-side credit per (tile, VC): one synchronous update (see M4).
  int send_credit     [NUM_TILES][NUM_VCS];
  bit sent_this_cycle [NUM_TILES];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int t = 0; t < NUM_TILES; t++)
        for (int v = 0; v < NUM_VCS; v++) send_credit[t][v] <= BUFFER_DEPTH;
    end else begin
      for (int t = 0; t < NUM_TILES; t++) begin
        for (int v = 0; v < NUM_VCS; v++) begin
          bit sent, returned;
          sent     = sent_this_cycle[t] && (inj_vc[t] == v);
          returned = in_cr_of[t][v];
          case ({sent, returned})
            2'b10:   send_credit[t][v] <= send_credit[t][v] - 1;
            2'b01:   send_credit[t][v] <= send_credit[t][v] + 1;
            default: send_credit[t][v] <= send_credit[t][v];
          endcase
        end
      end
    end
  end

  // ---------------------------------------------------------------------
  // Endpoint state
  // ---------------------------------------------------------------------
  // Out-queues: per (tile, class), messages waiting for a credit to enter
  // the network. Flits stored as plain vectors (this Icarus build is
  // fragile with arrays of structs).
  logic [FLIT_W-1:0] outq      [NUM_TILES][NUM_MCLASSES][OUTQ_DEPTH];
  int                outq_head [NUM_TILES][NUM_MCLASSES];
  int                outq_cnt  [NUM_TILES][NUM_MCLASSES];
  int                inj_cls_rr[NUM_TILES]; // round-robin over classes for the one injection port
  int                inj_vc_rr [NUM_TILES][NUM_MCLASSES]; // round-robin over each class's VCs

  // Transactions. state: 0 free, 1 REQ pending, 2 SNP pending, 3 RSP pending.
  int txn_req   [NUM_TXN_IDS];
  int txn_home  [NUM_TXN_IDS];
  int txn_owner [NUM_TXN_IDS];
  int txn_state [NUM_TXN_IDS];
  int txn_start [NUM_TXN_IDS];
  bit txn_attack[NUM_TXN_IDS]; // issued by the attacker
  bit txn_prot  [NUM_TXN_IDS]; // protected: only a trusted initiator may be served
  int free_txn  [$];
  int outstanding [NUM_TILES];

  // Accounting, for the deadlock report: where is every message?
  int injected  [NUM_MCLASSES];   // entered the network
  int delivered [NUM_MCLASSES];   // left the network (into a receive buffer)
  int rx_cls    [NUM_TILES][NUM_MCLASSES]; // waiting in receive buffers, by class

  // Statistics / status
  bit     generating;
  int     cycle_num;
  int     last_progress;
  bit     progress;
  int     started, completed, errors;
  longint sum_txn_lat;
  int     max_txn_lat;
  bit     deadlocked;
  // M6 attack accounting
  int     breaches;     // protected requests a home served for an untrusted initiator
  int     denials;      // protected requests a home refused
  int     unsolicited;  // responses delivered to a tile that never asked
  int     atk_started, atk_completed;
  int     atk_refused;  // attacker flits refused at ingress (alarm[0] at its router)

  function automatic bit trusted(input int t); trusted = (t < MESH_W); endfunction // top row
  function automatic int tile_x(input int t); tile_x = t % MESH_W; endfunction
  function automatic int tile_y(input int t); tile_y = t / MESH_W; endfunction
  function automatic string tname(input int t); tname = $sformatf("(%0d,%0d)", tile_x(t), tile_y(t)); endfunction
  function automatic string cname(input int c);
    case (c)
      0:       cname = "REQ";
      1:       cname = "SNP";
      2:       cname = "RSP";
      default: cname = "???";
    endcase
  endfunction

  // Seeded RNG (Verilog-2005 $random with an explicit seed variable).
  function automatic int rnd(input int n); // uniform in [0, n)
    int r;
    r = $random(seed);
    if (r < 0) r = -r;
    rnd = r % n;
  endfunction

  function automatic logic [FLIT_W-1:0] mk_msg(input logic [MCLASS_W-1:0] mc, input int src, input int dest,
                                               input int req_tile, input int txn);
    flit_t f;
    f.mclass  = mc;
    f.src_x   = tile_x(src);
    f.src_y   = tile_y(src);
    f.dest_x  = tile_x(dest);
    f.dest_y  = tile_y(dest);
    f.payload = {req_tile[3:0], txn[11:0]};
    mk_msg = f;
  endfunction

  task automatic outq_push(input int t, input int c, input logic [FLIT_W-1:0] m);
    int slot;
    slot = (outq_head[t][c] + outq_cnt[t][c]) % OUTQ_DEPTH;
    outq[t][c][slot] = m;
    outq_cnt[t][c]   = outq_cnt[t][c] + 1;
  endtask

  // ---------------------------------------------------------------------
  // One cycle of endpoint behavior, driven at negedge:
  //   1. process the head of each receive buffer, if the rules allow
  //   2. requesters start new transactions
  //   3. each tile injects at most one queued message (one link)
  // ---------------------------------------------------------------------
  task automatic drive_cycle();
    rx_pop = '0;
    for (int t = 0; t < NUM_TILES; t++) begin
      local_in_valid[t]  = 1'b0;
      local_in_data[t]   = '0;
      sent_this_cycle[t] = 1'b0;
    end

    // 1. Processing: at most one message per receive buffer per cycle.
    for (int i = 0; i < NUM_TILES*NUM_VCS; i++) begin
      if (!rx_empty[i]) begin
        flit_t h;
        int t, c, id, src, req_tile;
        bit ok;
        h        = rx_head[i];
        t        = i / NUM_VCS;
        c        = h.mclass;
        id       = h.payload[11:0];
        req_tile = h.payload[15:12];
        src      = h.src_y*MESH_W + h.src_x;
        ok       = 1'b0;
        case (c)
          0: begin                                  // REQ at home: owes a SNP to the owner
               if (txn_prot[id] && !trusted(src)) begin       // ACL: refuse, drop the request
                 denials = denials + 1;
                 if (!txn_attack[id]) begin
                   errors = errors + 1;
                   $display("[FAIL] cyc=%0d: home %s denied an honest protected request from %s", cycle_num, tname(t), tname(src));
                 end
                 txn_state[id] = 0;
                 free_txn.push_back(id);
                 ok = 1'b1;
               end else if (outq_cnt[t][1] < OUTQ_DEPTH) begin
                 if (txn_prot[id] && txn_attack[id]) breaches = breaches + 1; // served an untrusted initiator
                 outq_push(t, 1, mk_msg(MC_SNP, t, txn_owner[id], src, id));
                 txn_state[id] = 2;
                 ok = 1'b1;
               end
             end
          1: if (outq_cnt[t][2] < OUTQ_DEPTH) begin // SNP at owner: owes an RSP to the requester
               outq_push(t, 2, mk_msg(MC_RSP, t, req_tile, req_tile, id));
               txn_state[id] = 3;
               ok = 1'b1;
             end
          2: begin                                  // RSP at requester: always accepted
               if (!txn_attack[id]) begin
                 int lat;
                 lat = cycle_num - txn_start[id];
                 sum_txn_lat = sum_txn_lat + lat;
                 if (lat > max_txn_lat) max_txn_lat = lat;
                 outstanding[t] = outstanding[t] - 1;
                 completed      = completed + 1;
               end else if (t == attacker) begin
                 atk_completed = atk_completed + 1;     // the attacker's own flood traffic
               end else begin
                 unsolicited = unsolicited + 1;         // a response this tile never asked for
               end
               txn_state[id]  = 0;
               free_txn.push_back(id);
               ok = 1'b1;
             end
          default: ;
        endcase
        if (ok) begin
          rx_pop[i]    = 1'b1;
          rx_cls[t][c] = rx_cls[t][c] - 1;
          progress     = 1'b1;
        end
      end
    end

    // 2. New transactions.
    if (generating) begin
      for (int t = 0; t < NUM_TILES; t++) begin
        if (attack_mode != 0 && t == attacker) begin
          // The attacker: a request every cycle it has queue space, no
          // outstanding limit.
          if (outq_cnt[t][0] < OUTQ_DEPTH) begin
            int id, home, owner, claim;
            claim = (attack_mode == 1) ? FORGED_TILE : t;  // who the request claims to be from
            home  = rnd(NUM_TILES);
            while (home == t || home == claim) home = rnd(NUM_TILES);
            owner = rnd(NUM_TILES);
            while (owner == t || owner == home || owner == claim) owner = rnd(NUM_TILES);
            id = free_txn[0];
            free_txn.delete(0);
            txn_req[id]    = claim;
            txn_home[id]   = home;
            txn_owner[id]  = owner;
            txn_state[id]  = 1;
            txn_start[id]  = cycle_num;
            txn_attack[id] = 1'b1;
            txn_prot[id]   = (attack_mode == 1);
            atk_started    = atk_started + 1;
            outq_push(t, 0, mk_msg(MC_REQ, claim, home, claim, id)); // claim written into src
          end
        end else if (outstanding[t] < max_outstanding && outq_cnt[t][0] < OUTQ_DEPTH && rnd(1000) < rate_permille) begin
          int id, home, owner;
          home  = rnd(NUM_TILES - 1); if (home >= t) home = home + 1;              // any tile but t
          if (attack_mode != 0)
            while (home == t || home == attacker) home = rnd(NUM_TILES);           // nobody depends on the attacker
          owner = rnd(NUM_TILES);
          while (owner == t || owner == home || (attack_mode != 0 && owner == attacker)) owner = rnd(NUM_TILES);
          id = free_txn[0];
          free_txn.delete(0);
          txn_req[id]    = t;
          txn_home[id]   = home;
          txn_owner[id]  = owner;
          txn_state[id]  = 1;
          txn_start[id]  = cycle_num;
          txn_attack[id] = 1'b0;
          txn_prot[id]   = trusted(t) && (id % 2 == 1);
          outstanding[t] = outstanding[t] + 1;
          started = started + 1;
          outq_push(t, 0, mk_msg(MC_REQ, t, home, t, id));
        end
      end
    end

    // 3. Injection: round-robin over classes that have a message queued
    //    and a credit in a VC of their VN.
    for (int t = 0; t < NUM_TILES; t++) begin
      int pick_c, pick_v;
      pick_c = -1;
      pick_v = -1;
      for (int k = 0; k < NUM_MCLASSES; k++) begin
        int c, vn;
        c  = (inj_cls_rr[t] + k) % NUM_MCLASSES;
        vn = noc_pkg::vn_of(c, NUM_VNS);
        if (attack_mode == 2 && t == attacker && c == 0 && NUM_VNS > 1) vn = RSP_VN; // VN hopping
        if (pick_c == -1 && outq_cnt[t][c] > 0) begin
          for (int j = 0; j < VCS_PER_VN; j++) begin
            int v;
            v = vn*VCS_PER_VN + (inj_vc_rr[t][c] + j) % VCS_PER_VN;
            if (pick_v == -1 && send_credit[t][v] > 0) pick_v = v;
          end
          if (pick_v != -1) pick_c = c;
        end
      end
      if (pick_c != -1) begin
        int hd;
        hd = outq_head[t][pick_c];
        local_in_valid[t]  = 1'b1;
        local_in_data[t]   = outq[t][pick_c][hd];
        inj_vc[t]          = pick_v;
        sent_this_cycle[t] = 1'b1;
        outq_head[t][pick_c] = (hd + 1) % OUTQ_DEPTH;
        outq_cnt[t][pick_c]  = outq_cnt[t][pick_c] - 1;
        inj_cls_rr[t]        = (pick_c + 1) % NUM_MCLASSES;
        inj_vc_rr[t][pick_c] = (pick_v % VCS_PER_VN + 1) % VCS_PER_VN;
        injected[pick_c]     = injected[pick_c] + 1;
        progress = 1'b1;
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Delivery checks, sampled at posedge+1.
  // ---------------------------------------------------------------------
  task automatic check_arrivals();
    // M6: alarms. The watchdog must never fire here (every tile keeps
    // consuming); an ingress refusal is only legitimate at the attacker.
    for (int d = 0; d < NUM_TILES; d++) begin
      logic [2:0] al;
      al = tile_alarm[d*3 +: 3];
      if (al[1] || al[2]) begin
        errors = errors + 1;
        $display("[FAIL] cyc=%0d: watchdog quarantined tile %s, which never stopped consuming (false positive)", cycle_num, tname(d));
      end
      if (al[0]) begin
        if (attack_mode != 0 && d == attacker) atk_refused = atk_refused + 1;
        else begin
          errors = errors + 1;
          $display("[FAIL] cyc=%0d: ingress alarm at honest tile %s (false positive)", cycle_num, tname(d));
        end
      end
    end

    for (int d = 0; d < NUM_TILES; d++) begin
      if (local_out_valid[d]) begin
        flit_t got;
        int c, id, src, req_tile, vc, want_state, want_dest, want_src;
        got      = local_out_data[d];
        c        = got.mclass;
        id       = got.payload[11:0];
        req_tile = got.payload[15:12];
        src      = got.src_y*MESH_W + got.src_x;
        vc       = arr_vc[d];
        progress = 1'b1;

        if (c >= NUM_MCLASSES) begin
          errors = errors + 1;
          $display("[FAIL] cyc=%0d: tile %s received a flit with invalid class %0d", cycle_num, tname(d), c);
        end else begin
          delivered[c] = delivered[c] + 1;
          rx_cls[d][c] = rx_cls[d][c] + 1;
          if (txn_attack[id]) begin
            // Attack traffic: only routing is checked (it went where its
            // header said); everything else about it is the attack.
            case (c)
              0:       want_dest = txn_home[id];
              1:       want_dest = txn_owner[id];
              default: want_dest = txn_req[id];
            endcase
            if (d != want_dest) begin
              errors = errors + 1;
              $display("[FAIL] cyc=%0d: attack-traffic %s misrouted to tile %s", cycle_num, cname(c), tname(d));
            end
          end else if (vc / VCS_PER_VN != noc_pkg::vn_of(c, NUM_VNS)) begin
            errors = errors + 1;
            $display("[FAIL] cyc=%0d: %s for tile %s arrived on VC %0d, outside its VN", cycle_num, cname(c), tname(d), vc);
          end
          if (!txn_attack[id]) begin
          want_state = c + 1;
          case (c)
            0:       begin want_dest = txn_home[id];  want_src = txn_req[id];  end
            1:       begin want_dest = txn_owner[id]; want_src = txn_home[id]; end
            default: begin want_dest = txn_req[id];   want_src = txn_owner[id]; end
          endcase
          if (txn_state[id] != want_state || d != want_dest || src != want_src || req_tile != txn_req[id]) begin
            errors = errors + 1;
            $display("[FAIL] cyc=%0d: tile %s received %s for txn %0d from %s (txn state %0d; expected a %s from %s to %s)",
                      cycle_num, tname(d), cname(c), id, tname(src), txn_state[id], cname(c), tname(want_src), tname(want_dest));
          end
          end
        end
      end
    end
  endtask

  task automatic one_cycle();
    @(negedge clk);
    progress = 1'b0;
    drive_cycle();
    @(posedge clk); #1;
    cycle_num = cycle_num + 1;
    check_arrivals();
    if (progress) last_progress = cycle_num;
  endtask

  function automatic int total_outstanding();
    total_outstanding = 0;
    for (int t = 0; t < NUM_TILES; t++) total_outstanding = total_outstanding + outstanding[t];
  endfunction

  // ---------------------------------------------------------------------
  // Deadlock report: where every stuck message is, and why each tile
  // can't make progress.
  // ---------------------------------------------------------------------
  int in_net [NUM_MCLASSES]; // report_deadlock scratch (module-level: this Icarus
  int in_oq  [NUM_MCLASSES]; // build is fragile with arrays local to tasks)
  int in_rx  [NUM_MCLASSES];

  task automatic report_deadlock();
    for (int c = 0; c < NUM_MCLASSES; c++) begin
      in_net[c] = injected[c] - delivered[c];
      in_oq[c]  = 0;
      in_rx[c]  = 0;
      for (int t = 0; t < NUM_TILES; t++) begin
        in_oq[c] = in_oq[c] + outq_cnt[t][c];
        in_rx[c] = in_rx[c] + rx_cls[t][c];
      end
    end
    $display("");
    $display("DEADLOCK at cycle %0d: nothing has moved anywhere for %0d cycles; %0d transactions can never finish.",
              cycle_num, STALL_LIMIT, total_outstanding());
    $display("");
    $display("  Where the stuck messages are              REQ    SNP    RSP");
    $display("    inside the network (router buffers)   %5d  %5d  %5d", in_net[0], in_net[1], in_net[2]);
    $display("    queued at a tile, waiting to inject   %5d  %5d  %5d", in_oq[0], in_oq[1], in_oq[2]);
    $display("    delivered, waiting to be processed    %5d  %5d  %5d", in_rx[0], in_rx[1], in_rx[2]);
    $display("");
    $display("  Why each tile is stuck (first receive buffer shown; out-queues are REQ/SNP/RSP, %0d slots each):", OUTQ_DEPTH);
    for (int t = 0; t < NUM_TILES; t++) begin
      string why;
      int i;
      i = t*NUM_VCS;
      why = "receive buffer empty";
      for (int v = NUM_VCS-1; v >= 0; v--) begin
        if (!rx_empty[t*NUM_VCS + v]) i = t*NUM_VCS + v;
      end
      if (!rx_empty[i]) begin
        flit_t h;
        h = rx_head[i];
        case (h.mclass)
          0:       why = $sformatf("head is a REQ: must queue a SNP, SNP out-queue full (%0d/%0d)", outq_cnt[t][1], OUTQ_DEPTH);
          1:       why = $sformatf("head is a SNP: must queue an RSP, RSP out-queue full (%0d/%0d)", outq_cnt[t][2], OUTQ_DEPTH);
          default: why = "head is an RSP (always accepted -- should not be stuck)";
        endcase
      end
      $display("    tile %s  out-queues %0d/%0d/%0d, injection credits %0d  |  %s",
                tname(t), outq_cnt[t][0], outq_cnt[t][1], outq_cnt[t][2], send_credit[t][0], why);
    end
    $display("");
  endtask

  initial begin
    int drain_cycles;
    real avg_lat, tput;

    if (!$value$plusargs("OUTSTANDING=%d", max_outstanding)) max_outstanding = 8;
    if (!$value$plusargs("RATE=%d", rate_permille))          rate_permille = 1000;
    if (!$value$plusargs("SEED=%d", seed))                   seed = 1;
    seed_arg = seed;
    if (!$value$plusargs("CYCLES=%d", run_cycles))           run_cycles = 20000;
    expect_deadlock = $test$plusargs("EXPECT_DEADLOCK");
    if (!$value$plusargs("ATTACK=%d", attack_mode))   attack_mode = 0;
    if (!$value$plusargs("ATTACKER=%d", attacker))    attacker = 8;
    expect_compromise = $test$plusargs("EXPECT_COMPROMISE");

    if (!$test$plusargs("NODUMP")) begin
      $dumpfile("sim/protocol_tb.vcd");
      $dumpvars(0, protocol_tb);
    end

    local_in_valid = '0;
    local_in_data  = '0;
    rx_pop         = '0;
    generating     = 1'b0;
    cycle_num      = 0;
    last_progress  = 0;
    started        = 0;
    completed      = 0;
    errors         = 0;
    sum_txn_lat    = 0;
    max_txn_lat    = 0;
    deadlocked     = 1'b0;
    breaches       = 0;
    denials        = 0;
    unsolicited    = 0;
    atk_started    = 0;
    atk_completed  = 0;
    atk_refused    = 0;
    for (int t = 0; t < NUM_TILES; t++) begin
      inj_vc[t]          = '0;
      inj_cls_rr[t]      = 0;
      outstanding[t]     = 0;
      sent_this_cycle[t] = 1'b0;
      for (int c = 0; c < NUM_MCLASSES; c++) begin
        outq_head[t][c] = 0;
        outq_cnt[t][c]  = 0;
        inj_vc_rr[t][c] = 0;
        rx_cls[t][c]    = 0;
      end
    end
    for (int c = 0; c < NUM_MCLASSES; c++) begin
      injected[c]  = 0;
      delivered[c] = 0;
    end
    for (int i = 0; i < NUM_TXN_IDS; i++) begin
      txn_state[i]  = 0;
      txn_attack[i] = 1'b0;
      txn_prot[i]   = 1'b0;
      free_txn.push_back(i);
    end

    $display("protocol_tb: %0d VN x %0d VC x %0d-flit buffers, %0d-pass SA | %0d outstanding/requester, rate %0d/1000, seed %0d",
              NUM_VNS, VCS_PER_VN, BUFFER_DEPTH, SA_ITERS, max_outstanding, rate_permille, seed_arg);

    rst_n = 0;
    repeat (2) @(posedge clk);
    #1;
    rst_n = 1;
    @(posedge clk); #1;

    // Traffic phase.
    generating = 1'b1;
    while (cycle_num < run_cycles && !deadlocked) begin
      one_cycle();
      if (total_outstanding() > 0 && cycle_num - last_progress >= STALL_LIMIT) deadlocked = 1'b1;
    end

    // Drain phase: no new transactions; everything outstanding must finish.
    generating = 1'b0;
    drain_cycles = 0;
    while (total_outstanding() > 0 && !deadlocked && drain_cycles < DRAIN_LIMIT) begin
      one_cycle();
      drain_cycles = drain_cycles + 1;
      if (cycle_num - last_progress >= STALL_LIMIT) deadlocked = 1'b1;
    end

    if (deadlocked) report_deadlock();

    if (assertion_violations != 0) begin
      errors = errors + 1;
      $display("[FAIL] %0d RTL invariant violation(s) (see ASSERT-FAIL lines above)", assertion_violations);
    end
    if (!deadlocked && total_outstanding() > 0 && attack_mode == 0) begin
      errors = errors + 1;
      $display("[FAIL] %0d transaction(s) still outstanding %0d cycles after traffic stopped, but messages kept moving (livelock?)",
                total_outstanding(), DRAIN_LIMIT);
    end

    avg_lat = (completed > 0) ? (sum_txn_lat / (1.0 * completed)) : 0.0;
    tput    = completed / (1.0 * cycle_num);
    $display("transactions: %0d started, %0d completed in %0d cycles (%0.3f per cycle), latency avg %0.1f max %0d cycles",
              started, completed, cycle_num, tput, avg_lat, max_txn_lat);
    $display("CSV,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0.1f,%0d,%0d",
              NUM_VNS, VCS_PER_VN, BUFFER_DEPTH, SA_ITERS, max_outstanding, rate_permille, seed_arg,
              deadlocked, started, completed, avg_lat, cycle_num, errors);

    $display("watchdog: longest honest ejection stall seen %0d cycles (quarantine limit %0d)", wd_max_starve, WD_LIMIT);

    if (attack_mode != 0) begin
      bit compromised;
      string dl_note;
      if (attack_mode == 1) compromised = (breaches > 0);
      else                  compromised = deadlocked || (total_outstanding() > 0);
      if (deadlocked) dl_note = ", DEADLOCKED";
      else            dl_note = "";
      $display("ATTACK,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                attack_mode, SECURE, seed_arg, max_outstanding, deadlocked, started, completed,
                breaches, denials, unsolicited, atk_started, atk_completed, atk_refused,
                wd_max_starve, compromised, errors);
      $display("attack %0d by tile %s (SECURE=%0d): %0d attack requests; breaches %0d, denials %0d, unsolicited responses %0d, refused at ingress %0d; honest: %0d/%0d completed%s",
                attack_mode, tname(attacker), SECURE, atk_started, breaches, denials, unsolicited, atk_refused,
                completed, started, dl_note);
      if (errors != 0)
        $display("ATTACK-FAIL (%0d testbench/RTL error(s))", errors);
      else if (expect_compromise && compromised)
        $display("ATTACK-PASS -- unprotected router compromised, as expected");
      else if (expect_compromise)
        $display("ATTACK-FAIL -- expected the unprotected router to be compromised, but the attack had no effect");
      else if (!compromised)
        $display("ATTACK-PASS -- attack contained");
      else
        $display("ATTACK-FAIL -- attack NOT contained");
    end
    else if (errors != 0)
      $display("FAIL (%0d error(s))", errors);
    else if (deadlocked && expect_deadlock)
      $display("PASS -- deadlock reproduced, as expected for this configuration (classes share buffers)");
    else if (deadlocked)
      $display("FAIL -- protocol deadlock");
    else if (expect_deadlock)
      $display("FAIL -- expected this configuration to deadlock, but every transaction completed");
    else
      $display("PASS -- all %0d transactions completed; no deadlock, no protocol or routing errors", completed);

    $finish;
  end

  initial begin
    #2000000000;
    $display("[FAIL] watchdog timeout");
    $finish;
  end

endmodule : protocol_tb
