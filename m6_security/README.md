# M6 -- Fabric Security

M5 made the mesh fast and deadlock-free. Both guarantees quietly assumed
that **every tile follows the rules**:
- it writes its own coordinates into the flits it sends;
- it puts each message in its own class's virtual network;
- it keeps consuming what's delivered to it.

M6 drops that assumption. One tile is now compromised.

Three attacks follow. Each is a classic network-security attack
translated to an on-chip network, and each is shown **working against
M5's router** and then **stopped by a small piece of hardware** at the
router's tile-facing port. A fourth run is a control (a plain flood),
included to show what the defenses don't cover.

See [M5's README](../m5_virtual_networks/README.md) for virtual channels,
virtual networks, and the coherence-style protocol these attacks abuse.

## Results at a glance

| Attack | Internet analogy | Against M5's router | Against M6's router | Defense |
|---|---|---|---|---|
| **Source spoofing**: forge a trusted tile's identity to pass a home's access-control list | IP spoofing | 8/8 runs breached; every forged request served | 0 breaches; every forged request denied | Router **stamps the true source** into every flit at ingress (BCP38-style ingress filtering) |
| **VN hopping**: put requests into the response network | Abusing a priority traffic class | 8/8 runs **deadlock the whole fabric** | 0/8; honest traffic 100% complete | Router **refuses flits outside their class's VN** at ingress |
| **Black hole**: stop consuming deliveries | Black-hole / DoS router | Victims' throughput collapses ~8x; network can't drain | 0 victim packets lost | **Credit-starvation watchdog** quarantines the dead port |
| Flood (control): heavy but well-formed traffic | Volumetric DoS | Slows honest traffic, no deadlock | Same (not mitigated) | Rate limiting: future work |

Two further properties hold:
- **Invisible to honest traffic.** With no attacker present, M6
  reproduces M4's and M5's results digit for digit: 288 runs, zero
  security alarms.
- **Verified both ways.** Every attack is shown to *succeed* without the
  defense, so a passing secure run means something. A mutation test then
  removes each defense, and also makes the watchdog over-eager, and checks
  that the verification catches all four.

## Threat model

- **The attacker** controls one tile: a compromised accelerator,
  malicious firmware, or a buggy agent. It can:
  - inject any flit, with any header fields, on any VC, as fast as its
    credits allow;
  - refuse to consume what it's sent.
- **Trusted:** the routers, the links between them, and the other tiles.
- **Goals:**
  - **Authenticity:** a tile cannot claim to be another tile.
  - **Isolation:** a tile cannot break the guarantees the network gives
    everyone else (M5's deadlock freedom).
  - **Availability:** one tile cannot freeze traffic between other tiles.
- **Out of scope:**
  - physical attacks, or a malicious router;
  - a tile simply refusing to *serve* requests sent to it, which is a
    protocol-level problem that needs timeouts, not network hardware;
  - volumetric flooding (rate limiting);
  - confidentiality, including timing side channels through shared links.

## The trust boundary

Every defense sits in one place: each router's **local port**, where a
tile meets the network. Router-to-router links stay trusted.

```
                 trusted (routers, links)                    UNTRUSTED
     +---------------------------------------------------+
     |  router (x,y)                                     |      tile (x,y)
     |                                     +-----------+ |   +------------+
 N/S/E/W links <--> VC buffers, allocator  | ingress:  |<----| may forge  |
     |               crossbar              |  stamp src| |   | src, use   |
     |                                     |  check VN | |   | any VC ... |
     |                                     +-----------+ |   |            |
     |                                     +-----------+ |   |            |
     |                                     | ejection: |---->| ...or stop |
     |                                     |  watchdog | |   | consuming  |
     |                                     +-----------+ |   +------------+
     +---------------------------------------------------+
```

That split also changes what an assertion means:
- **On a link,** a flit in the wrong VN can only come from a broken
  router upstream. It's an RTL bug, so it's an assertion, as in M5.
- **At the local port,** the same flit is an attack. The router refuses
  it and raises an alarm instead.

All of it is behind one parameter, `SECURE` (default 1). `SECURE=0`
builds M5's behavior, the vulnerable baseline that every attack is
demonstrated against.

## Attack 1: source spoofing

**The setup.** Homes enforce an access-control list:
- a **protected** transaction may only be served for a **trusted** tile
  (the top row);
- the home decides by reading the requester's identity from the flit's
  `src` field.

**The attack.** The attacker, tile (2,2), sends protected requests with
`src` set to (0,0), a trusted tile:

```
  attacker (2,2) --REQ, src=(0,0)--> home: "(0,0) is trusted"  --> serves it: BREACH
                                      |
                                      +--SNP--> owner --RSP--> (0,0): a response it never asked for
```

Against M5's router, every forged request is served, and the impersonated
tile is hit with unsolicited responses. That's the on-chip version of a
reflection attack: the attacker can't read the data, but it can make the
system act on its behalf, and dump the results on someone else.

**The defense.** The router overwrites `src` with its own coordinates on
every flit entering from the tile. A tile can claim anything; the network
reports where the flit really came from. This is BCP38 ingress filtering,
done in hardware at the only place it can be done, the network's edge.
It's also the principle behind hardware-assigned initiator identities in
real SoC fabrics: the identity comes from *where* a request entered, not
from what it says about itself.

Results, 8 seeds per row, 5,000 cycles each, 8 outstanding transactions
per honest requester
([`results/attack_protocol.csv`](results/attack_protocol.csv)):

| Router | Runs breached | Forged requests served | Denied | Unsolicited responses at (0,0) | Honest transactions completed |
|---|---|---|---|---|---|
| M5 behavior (`SECURE=0`) | 8/8 | 22,685 | 0 | 22,664 | 100% |
| M6 (`SECURE=1`) | **0/8** | **0** | 26,391 | 0 | 100% |

Honest traffic is unaffected either way, which is exactly what makes
spoofing dangerous: nothing looks wrong until someone audits the access
log.

## Attack 2: VN hopping

M5's deadlock-freedom argument ran backward from the end of the
transaction chain:
1. RSPs always drain, because the RSP network holds only RSPs and every
   requester always accepts them.
2. Therefore SNPs always drain.
3. Therefore REQs always drain.

**The attack.** A greedy tile notices the response network is less
congested and puts its *requests* there. Now a REQ can sit at the head of
a home's RSP buffer, waiting for the home to have room for a SNP. Every
RSP behind it waits too. Step 1 of the argument is gone, and the cyclic
wait from M5's shared-buffer configuration returns.

Against M5's router, it deadlocks the whole fabric in every run. That's
at 8 outstanding transactions per requester, a load at which M5's VNs
never deadlocked. One misbehaving tile takes the guarantee away from
everyone.

**The defense.** At the local port, a flit is accepted only into a VC of
its own class's VN. Otherwise it's refused and `alarm[0]` pulses. The
credit the tile spent on it is **not** returned, so a rule-breaking tile
quickly runs out of credits on the VC it abused. It starves only itself.

| Router | Runs deadlocked | Attacker flits refused | Honest transactions completed |
|---|---|---|---|
| M5 behavior (`SECURE=0`) | **8/8** | 0 | 91.4%, then nothing moves |
| M6 (`SECURE=1`) | 0/8 | 32 (4 per run: its credits ran out) | 100% |

## Attack 3: black hole

**The attack.** The attacking tile simply stops consuming what's
delivered to it. Its ejection credits never come back, so:
- flits addressed to it wait in its router's input buffers;
- the flits behind *them*, addressed to anyone, wait too, because of
  head-of-line blocking;
- the routers feeding those buffers back up the same way.

The backpressure spreads until traffic between tiles that have nothing to
do with the attacker is frozen (tree saturation). A corner tile does it
as thoroughly as the center one.

**The defense.** Per VN, the local ejection port runs a watchdog:

```
  starved = a flit is waiting for this tile  AND  the tile has returned no credit
  starved for WD_LIMIT consecutive cycles  ->  QUARANTINE that VN:
      its flits still win the switch, but are discarded instead of sent  (alarm[2])
      -> the router's buffers drain, the backpressure unwinds
  the tile returns any credit  ->  quarantine lifts immediately
```

A slow but live tile never trips it, because any credit returned resets
the count. The discarded flits were addressed to the tile that refused
them.

Results with uniform traffic on M5's best configuration (4 VCs x 2
flits, 2-pass), the attacker active from the start
([`results/attack_blackhole.csv`](results/attack_blackhole.csv)).
"Victims" are all packets for other tiles:

| Attacker | Load | Router | Victims accepted / offered | Victim packets lost | Stuck after traffic stops | Quarantined at cycle |
|---|---|---|---|---|---|---|
| center (1,1) | 0.20 | M5 behavior | 0.022 / 0.178 | 2,802 | 128 | never |
| center (1,1) | 0.40 | M5 behavior | 0.045 / 0.361 | 5,684 | 128 | never |
| corner (2,2) | 0.20 | M5 behavior | 0.022 / 0.177 | 2,776 | 128 | never |
| corner (2,2) | 0.40 | M5 behavior | 0.044 / 0.360 | 5,687 | 128 | never |
| center (1,1) | 0.20 | M6 | 0.178 / 0.178 | **0** | 0 | 311 |
| center (1,1) | 0.40 | M6 | 0.361 / 0.361 | **0** | 0 | 278 |
| corner (2,2) | 0.20 | M6 | 0.177 / 0.177 | **0** | 0 | 325 |
| corner (2,2) | 0.40 | M6 | 0.360 / 0.360 | **0** | 0 | 286 |

"Stuck" is the same 128 flits in every unprotected run: once enough
buffers fill with traffic waiting on the black hole, the network reaches
a frozen state that doesn't depend on which tile or load started it.

### Choosing WD_LIMIT

The limit trades **false alarms** (quarantining an honest tile that's
legitimately stalled) against the **damage window** (how long a black
hole gets to back traffic up). Both sides were measured
(`tools/watchdog_study.sh`,
[`results/watchdog_study.csv`](results/watchdog_study.csv)).

**Honest tiles do stall.** A coherence home can't accept a request until
it has room for the snoop it owes. Longest honest ejection stall, across
48 protocol runs at every load from M5's study:

| Outstanding transactions per requester | 2 | 4 | 8 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|
| Longest honest stall (cycles) | 0 | 0 | 21 | 59 | 74 | 75 |

**Damage grows faster than the limit.** In this run, the center tile
turns black hole at cycle 1000, mid-operation, under uniform traffic at
0.30 load:

| Watchdog | Detected after | Victim latency avg / p99 (cycles) | Victim packets lost |
|---|---|---|---|
| none (M5's router) | never | -- | 3,986 |
| WD_LIMIT 32 | 53 cycles | 3.3 / 7 | 0 |
| WD_LIMIT 64 | 85 | 3.4 / 7 | 0 |
| WD_LIMIT 128 | 149 | 4.6 / 50 | 0 |
| **WD_LIMIT 256 (default)** | 277 | 14.9 / 179 | 0 |
| WD_LIMIT 512 | 533 | 66.1 / 436 | 0 |
| WD_LIMIT 1024 | 1,045 | 295.9 / 946 | 0 |

With no attack, victim latency is 3.3 / 6 cycles.

**The default is 256.** That's 3.4x the worst honest stall measured, at a
load (64 outstanding per requester) far beyond typical miss-handling
resources, and it detects 4x faster than the first choice of 1024, with
5x less tail damage. A design that knows its endpoints better could go
lower: 128 still has 1.7x margin. It's a parameter, and these two tables
are the data to choose it with.

### Known limitation: deadlock looks like a black hole

The watchdog sees one symptom: delivered flits waiting at a tile with no
credit coming back. A protocol-deadlocked tile shows exactly that
symptom, even though it is honest. The tile can't accept the REQ at the
head of its receive queue until its SNP out-queue drains, and that queue
can't drain into a network that is full.

So if the watchdog runs on the shared-buffer configuration (1 VN, which
deadlocks; see [M5](../m5_virtual_networks/README.md)), it quarantines
honest tiles:

```
protocol_tb  -DPROTO_NUM_VNS=1 -DPROTO_SECURE=1  +OUTSTANDING=16 +SEED=1
[FAIL] cyc=328: watchdog quarantined tile (1,0), which never stopped consuming (false positive)
...                                    (106 false-positive errors in all)
transactions: 3879 started, 3804 completed ...     -> deadlocks again at cycle 3535
```

The discards free some buffers, so traffic limps on for a while. The cost
is lost messages, and the network deadlocks again anyway. The watchdog
turns a deadlock into message loss. It does not cure it.

This doesn't happen in the configuration the watchdog is meant for. With
one VN per message class the protocol can't deadlock, and every honest
run in this README, the attack matrix and the equivalence check shows
zero alarms. The rule: **the watchdog assumes a deadlock-free protocol.**
Deadlock freedom has to come from VNs, not from the watchdog. The
[visualizer](../visualizer/README.md)'s deadlock replay runs with
`SECURE=0` for this reason.

## The control: flooding

The same attacker floods requests **in the correct VN**. Honest traffic
slows but completes in every run, against both routers. The control
shows the VN-hopping deadlock comes from the VN violation, not the extra
load. It also marks the edge of what M6 covers: volumetric flooding needs
per-tile rate limiting (a token bucket at the local port), which is
future work.

## Invisible to honest traffic

Security logic that changes how honest packets move is a performance bug.
With no attacker, M6 must behave exactly like M5
(`tools/equivalence_check.sh`):

| Check | Runs | Result |
|---|---|---|
| M4's whole sweep, SECURE=1 and SECURE=0 | 2 x 80 | Identical to M4, digit for digit |
| M5's best VC configuration (4 VCs x 2, 2-pass), 4 patterns | 80 | Identical to M5, every column |
| M5's protocol runs, one VN per class (6 loads x 8 seeds) | 48 | Identical to M5; zero alarms |

Every one of these runs also fails on any security alarm. So "no false
positives" is checked, not assumed.

## Verification

**Directed tests** (`tb/vc_router_tb.sv`, 28/28): M5's suite, plus:

| Test | Checks |
|---|---|
| T7 | (changed) A wrong-VN flit arriving over a router-to-router *link* still fires the RTL assertion: links are trusted, so it's a bug |
| T8 | A local flit claiming (2,2) leaves stamped (1,1); a transit flit keeps its source |
| T9 | A local REQ in the RSP VC is refused (1 alarm, no assertion, credit kept); the same REQ in the REQ VC passes |
| T10 | Watchdog with limit 16: a 12-cycle stall is tolerated; past 16 cycles, quarantine, and exactly the 2 waiting flits are discarded; the other VN is unaffected; recovery when the tile resumes |
| T11 | The same tricks on an unprotected router pass silently: the vulnerability, shown directly |

**Attack matrix** (`tools/attack_matrix.sh`): every attack against both
routers, 8 seeds for the protocol attacks, plus 2 tiles x 2 loads for the
black hole. Passing requires both directions: compromise without the
defense, containment with it.

**Mutation testing** (`tools/mutation_test.sh`): M5's seven mutants plus
four security mutants, each run against six testbenches. All 11 caught.

| Security mutant | Bug | Caught by |
|---|---|---|
| `no_stamp` | Source stamping removed | Spoofing run: breaches > 0; directed T8 |
| `no_vn_guard` | Ingress VN check removed | VN-hopping run: wrong-VN flits reach the links and fire the link assertion; directed T9 |
| `no_watchdog` | Watchdog never quarantines | Black-hole run: victims stuck; directed T10 |
| `hair_trigger` | Watchdog fires after 2 starved cycles instead of WD_LIMIT | **Honest** protocol runs: false-positive alarms on tiles that never stopped consuming; directed T10 ("short stall tolerated") |

The last mutant matters as much as the first three. A security mechanism
with a false-positive bug discards honest traffic, which is a
self-inflicted denial of service. It's caught only because two checks
look for it: every honest run treats any alarm as a failure, and T10
deliberately stalls a tile for less than the limit.

## Hardware cost

All of it sits at one port per router:

- **Source stamping:** the 8 `src` bits become constants (a 2:1 mux).
- **VN guard:** a 2-bit compare per local VC, gating the FIFO push.
- **Watchdog, per VN:** a `log2(WD_LIMIT+1)`-bit counter (9 bits at
  256), a quarantine flop, and an override on that VN's credit check.

Area and timing in gates is M7's job (synthesis). The expectation is a
small fraction of a router dominated by its buffers and allocators, and
M7 will measure it.

## Running it

```sh
./run.sh                       # regression: directed + honest + each attack x both routers (~2 min)
tools/equivalence_check.sh     # invisible to honest traffic: 288 runs vs M4/M5 (~14 min)
tools/attack_matrix.sh         # every attack x both routers x 8 seeds (~6 min)
tools/watchdog_study.sh        # WD_LIMIT trade-off: honest stalls vs. black-hole damage (~5 min)
tools/mutation_test.sh         # 11 injected bugs, 4 in the security layer (~4 min)
SECURE=0 tools/sweep.sh        # latency/throughput sweeps, either router
```

## Not yet covered

- **Rate limiting** against volumetric flooding (a per-tile token bucket
  at the local port).
- **Protocol-level timeouts** for tiles that refuse to *serve* (out of
  the network's reach).
- **Timing channels.** Two colluding tiles can signal through contention
  on shared links and switch ports. Virtual networks isolate *buffers*,
  not *bandwidth*, so VN separation alone wouldn't close such a channel.
- **Area and timing** of every feature: M7.
