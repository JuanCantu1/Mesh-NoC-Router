#!/usr/bin/env bash
# Attack matrix: every attack, against the unprotected router (SECURE=0)
# and the hardened one (SECURE=1).
#
# Protocol traffic (tb/protocol_tb.sv, 3 VNs x 1 VC x 4 flits, 8
# outstanding transactions per honest requester, attacker = tile (2,2)),
# 8 seeds each:
#   1 spoof   forged trusted source to pass a home's access-control list
#   2 vnhop   requests flooded into the response VN
#   3 flood   the same flood in the correct VN (control: load, no violation)
# Black hole (tb/latency_sweep_tb.sv, 1 VN x 4 VCs x 2, 2-pass, uniform
# traffic): the attacking tile never consumes what it's sent. Center and
# corner attacker, two loads.
#
# Pass criteria -- the demo has to prove both directions:
#   SECURE=0: spoof, vnhop and black hole must SUCCEED (+EXPECT_COMPROMISE);
#   SECURE=1: every attack must be CONTAINED;
#   flood (control) must leave honest traffic intact under both;
#   and no run may report a testbench/RTL error or a false alarm.
#
# Usage: tools/attack_matrix.sh   (JOBS=N, default 16; ~6 min)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p sim results
JOBS=${JOBS:-16}
PIPE=${PIPE:-0}   # M8: PIPE=1 runs every attack against two-stage routers
SUF=""; [ "$PIPE" = 1 ] && SUF=_pipe
RTL="rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/flit_fifo.sv rtl/vc_router.sv rtl/vc_mesh.sv"
LOGDIR=sim/attack_logs
rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"

for sec in 0 1; do
  iverilog -g2012 -DPROTO_NUM_VNS=3 -DPROTO_SECURE=$sec -DPROTO_PIPE=$PIPE -o sim/atk_proto_s$sec.vvp $RTL tb/protocol_tb.sv
  iverilog -g2012 -DSWEEP_VCS_PER_VN=4 -DSWEEP_BUFFER_DEPTH=2 -DSWEEP_SA_ITERS=2 -DSWEEP_SECURE=$sec -DSWEEP_PIPE=$PIPE \
    -o sim/atk_sweep_s$sec.vvp $RTL tb/latency_sweep_tb.sv
done

echo "Running protocol attacks (3 attacks x 2 routers x 8 seeds) and black holes (2 tiles x 2 loads x 2 routers)..."
{
  for a in 1 2 3; do for sec in 0 1; do for s in 1 2 3 4 5 6 7 8; do echo "proto $a $sec $s"; done; done; done
  for t in 4 8; do for r in 200 400; do for sec in 0 1; do echo "bh $t $sec $r"; done; done; done
} | xargs -P "$JOBS" -n 4 bash -c '
  kind=$0; a=$1; sec=$2; x=$3
  expect=""
  if [ "$sec" = 0 ] && [ "$kind$a" != proto3 ]; then expect=+EXPECT_COMPROMISE; fi
  if [ "$kind" = proto ]; then
    vvp sim/atk_proto_s$sec.vvp +NODUMP +CYCLES=5000 +OUTSTANDING=8 +SEED=$x +ATTACK=$a $expect \
      > '"$LOGDIR"'/proto_a${a}_s${sec}_seed$x.log 2>&1
  else
    vvp sim/atk_sweep_s$sec.vvp +NODUMP +PATTERN=0 +RATE=$x +BLACKHOLE=$a $expect \
      > '"$LOGDIR"'/bh_t${a}_s${sec}_r$x.log 2>&1
  fi'

echo "attack,secure,seed,outstanding,deadlocked,started,completed,breaches,denials,unsolicited,atk_started,atk_completed,atk_refused,wd_max_starve,compromised,errors,verdict" > results/attack_protocol$SUF.csv
echo "blackhole_tile,secure,wd_limit,rate_permille,victim_offered,victim_accepted,victim_avg_latency,victim_lost,bh_delivered,bh_discarded,stuck_after_flush,quarantine_cycle,compromised,errors,verdict" > results/attack_blackhole$SUF.csv
bad=0
for f in "$LOGDIR"/proto_*.log "$LOGDIR"/bh_*.log; do
  line=$(grep '^ATTACK,' "$f" | sed 's/^ATTACK,//; s/^blackhole,//' || true)
  verdict=$(grep -oE '^ATTACK-(PASS|FAIL)' "$f" || echo MISSING)
  if [ -z "$line" ] || [ "$verdict" != ATTACK-PASS ]; then
    echo "  $verdict: $f"; grep -E "ATTACK-FAIL|FAIL\]|ASSERT" "$f" | head -3 | sed 's/^/      /'
    bad=$((bad + 1))
  fi
  case "$f" in
    *proto_*) echo "$line,$verdict" >> results/attack_protocol$SUF.csv ;;
    *)        echo "$line,$verdict" >> results/attack_blackhole$SUF.csv ;;
  esac
done

echo
echo "Protocol attacks (8 seeds each; 'compromised' = breach, or honest transactions stuck):"
awk -F, 'NR > 1 {
    k = $1 "," $2; n[k]++; comp[k] += $15; br[k] += $8; den[k] += $9; uns[k] += $10; ref[k] += $13
    dl[k] += $5; done_[k] += $7; st[k] += $6
  }
  END {
    split("spoof vn-hop flood(ctrl)", nm, " ")
    printf "  %-12s %-9s %-12s %9s %9s %12s %9s %10s %16s\n", "attack", "router", "compromised", "breaches", "denials", "unsolicited", "refused", "deadlocks", "honest completed"
    for (a = 1; a <= 3; a++) for (s = 0; s <= 1; s++) {
      k = a "," s
      printf "  %-12s %-9s %8d/%-3d %9d %9d %12d %9d %8d/%-1d %8.1f%%\n", nm[a], (s ? "SECURE=1" : "SECURE=0"),
             comp[k], n[k], br[k], den[k], uns[k], ref[k], dl[k], n[k], 100.0 * done_[k] / st[k]
    }
  }' results/attack_protocol$SUF.csv
echo
echo "Black hole (victim = traffic for every other tile):"
awk -F, 'NR > 1 {
    printf "  tile %-2s %-9s load %4.2f: victims offered %5.3f accepted %5.3f, %5d victim packets lost, %4d stuck; %5d discarded, quarantine @%s -> %s\n",
           $1, ($2 ? "SECURE=1" : "SECURE=0"), $4/1000, $5, $6, $8, $11, $10, $12, ($13 ? "COMPROMISED" : "contained")
  }' results/attack_blackhole$SUF.csv
echo
if [ "$bad" -ne 0 ]; then
  echo "ATTACK MATRIX FAILED: $bad run(s) didn't show the expected outcome"
  exit 1
fi
echo "ATTACK MATRIX PASSED: every attack succeeds against the unprotected router and is contained by the hardened one; the control flood harms neither"
