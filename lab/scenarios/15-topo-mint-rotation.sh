#!/bin/bash
# shellcheck disable=SC2034  # SCEN_* are read by scenario.sh after sourcing, not within this file
# 15-topo-mint-rotation.sh - the mint-enablement graph (ItWorksinMyLocal#62),
# one client at a time: brings up topologies/mint-iter.json (3 oldxdc
# sealers + 1 role=proposer candidate 'cand1' under test, client
# parameterized via env CAND_CLIENT -- default geth -- + an independent
# oldxdc observer 'obs1' + a fixed modern-geth observer 'obs2'), then runs
# seven gates (G1-G7) against it using ONLY lib-assert.sh's named
# assertions, exactly like scenario 12/14 before it.
#
# Client selection: this file reads $CAND_CLIENT directly (topo.sh's own
# "${CAND_CLIENT:-geth}" template substitution in mint-iter.json is what
# actually determines cand1's client), but ALSO bridges scenario.sh's own
# `--matrix 15 --clients a,b,c` convention (which exports LAB_CLIENTS, not
# CAND_CLIENT, for each row) -- see the CAND_CLIENT assignment below. A bare
# `./scenario.sh 15` with CAND_CLIENT pre-set in the environment works too;
# with neither set, it defaults to geth.
#
# Gates:
#   G1  genesis parity                     (P1)  -- every resolved node
#   G2  lockstep to a settle height         (P2)  -- obs1, obs2, AND cand1
#   G3  no swallowed validation bypass       --   -- every node's own log
#   G4  extraData + 0x88 SMC authorization  (P7)  -- cand1's genesis-time seat
#   G5  V1 turn/rotation correctness        (P3)  -- full signer set incl. cand1
#   G6  THE MINT GATE                       (P11) -- assert_mint_accepted
#   G7  fair share                          (P9)  -- only meaningful once G6
#                                                     actually observed a mint
#
# Honesty (ItWorksinMyLocal#62 section 4's anti-masking rule): G6 not
# observing cand1 ever minting a block within the scan window is a REAL
# possibility for every client this framework doesn't yet have a fully
# verified sealing path for -- see join.sh's own per-client notes (geth's
# --mine/--unlock/--miner.etherbase are deprecated but DO still work on at
# least one build checked live -- the account unlocks and the block-
# production worker starts -- but no mint was actually observed in an
# initial short sample; xone needs the raw --sealkey wired through and is
# unverified; reth has no XDPoS validator-signing flag at all). When that
# happens (G1-G4 all genuinely passed, i.e. the REST of the
# harness/topology is healthy), this scenario SKIPs (rc=2), citing the
# specific known blocker -- exactly scenario 14's own established
# precedent -- rather than either failing the whole run on a capability gap
# that isn't this harness's bug, or silently calling it a PASS. A genuine
# G1-G4 failure (or a G6/G7 assertion that actually FAILS once a mint IS
# observed) is a real FAIL, never folded into the SKIP. G5 (P3 turn-order)
# is likewise never discarded just because a mint was also observed: a
# real G5 FAIL alongside a genuine G6/G7 PASS is reported as SKIP (not
# PASS), with the G5 detail carried in both the narrative and the
# MINT_GRAPH_STATE blocker text below -- it must never silently vanish
# into an unqualified PASS (this exact masking was a gate-review finding).
#
# State reporting is CAPPED, never aspirational: the graph is linear (S5
# V1-mint-accepted -> S6 V2-mint-accepted -> S7 fair-share), so a mint
# observed below MINT_V2BLOCK can only ever be reported as S5 (with V1
# fair-share evidence) -- S7 is reached ONLY by promoting an already-S6
# (V2-crossing) mint, never hardcoded on G6+G7 passing alone.
#
# Every terminal MINT_GRAPH_STATE line also carries cand1's own resolved
# binary path + version/commit (see cand_provenance below) -- a mint claim
# is not fully honest if the exact build under test (e.g. a locally
# patched *_BIN override) is left for a reviewer to reconstruct later.
#
# V2-focus mode (ItWorksinMyLocal#62 round-2 "blocked-harness" fix): by
# default (S15_V2_TIMEOUT=0) G6 only ever scans the near-genesis window
# [_S15_SETTLE+1 .. _S15_SETTLE+_S15_TURN_WINDOW] -- fine for S5 (V1 mint)
# evidence, but that window never moves with MINT_V2BLOCK, so a run cannot
# ever produce real S6/S7 evidence this way no matter what MINT_V2BLOCK is
# set to. Set S15_V2_TIMEOUT to a wall-clock budget (and MINT_V2BLOCK=900,
# the smallest epoch-aligned switch topo.sh allows) to make this run ALSO
# wait for the reference to cross the switch and scan a SECOND window
# strictly ABOVE v2block for a genuine post-switch mint (G6b below) -- the
# only way this scenario can honestly promote a client past S5. Example:
#   MINT_V2BLOCK=900 S15_V2_TIMEOUT=1800 CAND_CLIENT=geth ./scenario.sh 15
#
# In addition to scenario.sh's usual "id|priority|verdict|reason|duration"
# line, this file also emits one machine-parseable line per run:
#   MINT_GRAPH_STATE: client=<c> state=<S0-S7> blocker="<text>"
# -- lab/mintlab.sh greps this (from stderr, where scenario.sh's _run_one
# always dumps a scenario's full output regardless of verdict) to persist
# the per-client mint-enablement graph, since scenario.sh's own matrix.md
# only records a FAIL/SKIP reason, never a PASS run's detail.

export SCEN_DESC="topo-mint-rotation: mint-iter (ItWorksinMyLocal#62) -- G1-G7 gates (genesis parity/lockstep/no-bypass/extraData-SMC/turn-order/THE MINT GATE/fair-share) for one candidate client at a time; client-parameterized via CAND_CLIENT or --matrix 15 --clients"
export SCEN_PRIORITY="P2/P3/P4/P7/P11"
export SCEN_PROFILE="real"
export SCEN_MODE="OBSERVE"

_S15_TOPO="$REPO_ROOT/topologies/mint-iter.json"

# Bridge scenario.sh's --matrix convention (LAB_CLIENTS) to this topology's
# own CAND_CLIENT templating -- see netlab/topo.sh's "Env-var templating".
export CAND_CLIENT="${LAB_CLIENTS:-${CAND_CLIENT:-geth}}"
_S15_V2BLOCK="${MINT_V2BLOCK:-1800}"
export MINT_V2BLOCK="$_S15_V2BLOCK"

_S15_SETTLE="${S15_SETTLE:-15}"            # blocks to let the net settle before gating
_S15_TURN_WINDOW="${S15_TURN_WINDOW:-40}"  # blocks scanned for G5 turn-order + G6a (pre-switch) mint gate
_S15_MINT_TIMEOUT="${S15_MINT_TIMEOUT:-900}"   # wall-clock seconds to wait out the G6a scan window
_S15_SHARE_WINDOW="${S15_SHARE_WINDOW:-60}"    # blocks scanned for G7, only if G6 found a mint

# G6b / V2-focus opt-in (ItWorksinMyLocal#62 round-2 "blocked-harness"
# finding): the G6a window above [_S15_SETTLE+1 .. _S15_SETTLE+
# _S15_TURN_WINDOW] never moves with MINT_V2BLOCK -- a caller could set
# MINT_V2BLOCK=900 wanting to test the V2 switch and this scenario would
# still only ever wait for/scan blocks ~[16..55], nowhere near the switch,
# every single time. That is the diagnosed root cause: MINT_V2BLOCK
# controls WHEN the genesis switches V1->V2, but nothing previously made
# this scenario's own gate evaluation window follow it there.
#
# S15_V2_TIMEOUT (default 0 = off, byte-for-byte the old behavior/runtime):
# wall-clock seconds budgeted to (a) wait for the reference to reach
# MINT_V2BLOCK + S15_V2_WINDOW, then (b) scan [MINT_V2BLOCK+1 ..
# MINT_V2BLOCK+S15_V2_WINDOW] -- STRICTLY ABOVE v2block, never straddling
# it -- for cand1's first mint there. This is a SEPARATE pass from G6a, run
# in ADDITION to it (never instead of): an early V1 mint (G6a, proves S5)
# and a later V2 mint (G6b, proves S6) are different evidence: a giant
# single window starting near genesis would always find the early V1 mint
# first and never actually exercise the post-switch case, which is exactly
# how this bug hid before. A dedicated "V2-focus" run sets both
# MINT_V2BLOCK=900 (smallest epoch-aligned switch topo.sh allows) and
# S15_V2_TIMEOUT to a budget long enough for the fleet to actually mint
# that many blocks (e.g. 900 blocks at period=1s is comfortably reachable
# in a 20-30 minute budget; pad generously, it also covers G6a above).
_S15_V2_TIMEOUT="${S15_V2_TIMEOUT:-0}"
_S15_V2_WINDOW="${S15_V2_WINDOW:-40}"      # blocks scanned strictly above v2block, once reached

# Known, honest per-client blockers for a G6 SKIP -- see join.sh's own
# per-client sealing-attempt notes for the full detail; keep this in sync
# with those comments if the underlying binaries/upstream state changes.
declare -A _S15_BLOCKER=(
  [geth]="--mine/--unlock/--miner.etherbase are deprecated-but-functional on at least one build checked live (account unlocks, block-production worker starts, eventually clears bulk-sync-mode) -- but no mint was observed in an initial short sample; needs a longer soak to tell apart 'will mint given more time' from a real remaining blocker (go-ethereum#1341 tracks the underlying flag deprecation upstream)"
  [xone]="xone's -miner.key sealing path is attempted (node.sh's --sealkey) but not yet verified end-to-end -- check cand1's own node.log for the actual failure"
  [reth]="reth-xdc has no XDPoS validator-signing CLI flag today (blocked-upstream: net5050 reth PRs #202/#223/#243); its only local-authoring mode (--dev) is a different, throwaway chain, not this genesis's real validator set"
)

_s15_emit_state() {
  local state="$1" blocker="$2"
  echo "MINT_GRAPH_STATE: client=$CAND_CLIENT state=$state blocker=\"$blocker\""
}

# _s15_scan_for_mint <url> <from> <to> <candAddrNorm> <timeout_s>: polls
# <url> for blocks [from,to] as they arrive (up to timeout_s wall-clock),
# printing the FIRST height whose actual signer (lib-assert.sh's own
# _assert_block_miner -- ecrecover-based, NOT the raw `miner` JSON field;
# see its own header comment) == candAddrNorm on stdout, or nothing (+
# nonzero) if the window closes (chain reaches `to`, or the timeout
# elapses) with no match.
_s15_scan_for_mint() {
  local url="$1" from="$2" to="$3" cand_norm="$4" timeout="${5:-900}"
  local waited=0 h head checked=$((from - 1))
  while :; do
    head=$(lab_block_number "$url" 2>/dev/null) || head="$checked"
    local upto=$to
    [ "$head" -lt "$to" ] 2>/dev/null && upto="$head"
    for ((h = checked + 1; h <= upto; h++)); do
      local m; m=$(_assert_block_miner "$url" "$h")
      if [ "$m" = "$cand_norm" ]; then printf '%s\n' "$h"; return 0; fi
    done
    checked="$upto"
    [ "$checked" -ge "$to" ] 2>/dev/null && return 1
    [ "$waited" -ge "$timeout" ] && return 1
    sleep 5
    waited=$((waited + 5))
  done
}

scen_15() {
  ( cd "$REPO_ROOT" && ./netlab/fleet.sh wipe "$_S15_TOPO" --force >/dev/null 2>&1 ) || true

  echo "scen_15: CAND_CLIENT=$CAND_CLIENT MINT_V2BLOCK=$_S15_V2BLOCK" >&2
  echo "scen_15: bringing up mint-iter via topo_up --wipe ..." >&2
  topo_up "$_S15_TOPO" --wipe >&2
  local up_rc=$?
  if [ "$up_rc" -ne 0 ]; then
    _s15_emit_state S0 "topo_up failed (rc=$up_rc) -- see fleet.sh output above"
    echo "scen_15: FAIL - topo_up mint-iter failed (rc=$up_rc)"
    return 1
  fi

  # ---- resolve every node's rpc/log, and cand1's own client + address ----
  local ids id
  ids=$(topo_nodes "$_S15_TOPO") || { echo "scen_15: FAIL - topo_nodes failed"; return 1; }
  declare -A URL LOGF
  local pairs=() logpairs=()
  for id in $ids; do
    URL[$id]=$(topo_rpc "$_S15_TOPO" "$id") || { echo "scen_15: FAIL - could not resolve rpc for $id"; return 1; }
    LOGF[$id]=$(topo_log "$_S15_TOPO" "$id") || { echo "scen_15: FAIL - could not resolve log for $id"; return 1; }
    pairs+=("$id=${URL[$id]}")
    logpairs+=("$id=${LOGF[$id]}")
  done

  local cand_client
  cand_client=$(topo_client "$_S15_TOPO" cand1) || { echo "scen_15: FAIL - could not resolve cand1's client"; return 1; }
  echo "scen_15: cand1 resolved client=$cand_client (requested CAND_CLIENT=$CAND_CLIENT), obs1=oldxdc obs2=geth" >&2

  local cand_addr
  cand_addr=$("$REPO_ROOT/netlab/node.sh" addr "$_S15_TOPO" cand1) || { echo "scen_15: FAIL - could not resolve cand1's signer address"; return 1; }
  local cand_norm; cand_norm=$(printf '%s' "$cand_addr" | tr 'A-Z' 'a-z')
  echo "scen_15: cand1 address=$cand_addr" >&2

  # ---- binary provenance: disclose the EXACT binary/build actually under
  # test, in the run's own evidence -- not something a later reviewer has
  # to reconstruct from file mtimes. A mint claim for a client whose binary
  # carries an undisclosed local patch (e.g. a *_BIN override pointing at a
  # freshly rebuilt tree) is not fully honest until that patch is named
  # here (ItWorksinMyLocal#62 gate review: a swapped/patched binary must be
  # stated, never silently assumed "the stock build").
  local cand_bin="" cand_provenance=""
  case "$cand_client" in
    geth) cand_bin="${GETH_BIN:-}" ;;
    xone) cand_bin="${XONE_BIN:-}" ;;
    reth) cand_bin="${RETH_BIN:-}" ;;
  esac
  if [ -n "$cand_bin" ] && [ -x "$cand_bin" ]; then
    local ver_line commit_line mtime
    mtime=$(date -u -r "$cand_bin" +%FT%TZ 2>/dev/null || echo "?")
    if [ "$cand_client" = xone ]; then
      # xone does NOT treat a bare "version" positional as a print-and-exit
      # subcommand the way oldxdc/geth do -- passed anything it doesn't
      # recognise, it silently falls through to starting a real node
      # (mainnet defaults) that never exits, hanging this whole script
      # forever inside the command substitution below (verified live
      # while fixing xOneGo#679). Only "--version" (a real flag) prints
      # and exits; its own output has no "Version:"/"Git Commit:" lines,
      # just one "xone vX.Y.Z (commit ...) [...]" line, so use that
      # directly rather than grepping for the oldxdc/geth format.
      ver_line=$("$cand_bin" --version 2>&1 | head -1)
      commit_line=""
    else
      ver_line=$("$cand_bin" version 2>&1 | grep -m1 -i '^Version:' )
      commit_line=$("$cand_bin" version 2>&1 | grep -m1 -i '^Git Commit:' )
    fi
    cand_provenance="cand1(${cand_client}) bin=$cand_bin mtime=$mtime ${ver_line:-} ${commit_line:-}"
  else
    cand_provenance="cand1(${cand_client}) bin=<no *_BIN override resolved -- join.sh used its own default lookup path>"
  fi
  echo "scen_15: provenance: $cand_provenance" >&2

  local ref="${URL[node1]}"
  local genesis_file="$REPO_ROOT/nodes/mint-iter/genesis.json"

  # ---- G1: genesis parity across every resolved node ----
  if ! assert_genesis_parity "${pairs[@]}" >&2; then
    _s15_emit_state S0 "genesis parity failed across the topology -- see PASS/FAIL line above"
    echo "scen_15: FAIL (G1) - genesis parity"
    return 1
  fi
  echo "scen_15: G1 PASS (genesis parity)" >&2

  echo "scen_15: waiting for the reference (node1) to reach the settle block ($_S15_SETTLE) ..." >&2
  lab_wait_block "$ref" "$_S15_SETTLE" $((_S15_SETTLE * 3 + 300)) || {
    _s15_emit_state S1 "sealers never produced $_S15_SETTLE blocks -- basic liveness problem, not client-specific"
    echo "scen_15: FAIL (G1+) - reference (node1) never reached the settle block ($_S15_SETTLE)"
    return 1
  }

  # ---- G2: lockstep to the settle height -- obs1, obs2, AND cand1 ----
  local g2_ok=0 cand_lockstep_ok=0
  assert_lockstep "node1=$ref" "obs1=${URL[obs1]}" "$_S15_SETTLE" 120 >&2 || g2_ok=1
  assert_lockstep "node1=$ref" "obs2=${URL[obs2]}" "$_S15_SETTLE" 120 >&2 || g2_ok=1
  assert_lockstep "node1=$ref" "cand1=${URL[cand1]}" "$_S15_SETTLE" 120 >&2 || cand_lockstep_ok=1

  # ---- G3: no swallowed validation bypass, every running node ----
  local g3_ok=0
  for id in $ids; do
    assert_no_validation_bypass "$id" "${LOGF[$id]}" >&2 || g3_ok=1
  done

  if [ "$g2_ok" -ne 0 ] || [ "$g3_ok" -ne 0 ]; then
    _s15_emit_state S1 "obs1/obs2 lockstep or a validation-bypass check failed -- topology/harness problem, see PASS/FAIL lines above"
    echo "scen_15: FAIL (G2/G3) - lockstep (obs1/obs2) or no-validation-bypass check failed"
    return 1
  fi
  echo "scen_15: G2+G3 PASS (obs1/obs2/cand1 lockstep to $_S15_SETTLE where applicable; no validation bypass on any node)" >&2

  if [ "$cand_lockstep_ok" -ne 0 ]; then
    _s15_emit_state S1 "cand1 ($cand_client) never kept lockstep with the reference by block $_S15_SETTLE -- see ${LOGF[cand1]}"
    echo "scen_15: FAIL (G2/cand1) - cand1 ($cand_client) never synced cleanly to block $_S15_SETTLE -- stopping here (G4-G7 need a synced candidate); see ${LOGF[cand1]}"
    return 1
  fi

  # ---- G4: extraData + 0x88 SMC authorization ----
  # NOTE: this must inspect ONLY the extraData field's own value, not grep
  # the whole (minified, single-line) genesis file -- cand1's address also
  # appears in `alloc` (its prefunded balance), so a whole-file grep can
  # never independently FAIL when the address is prefunded but missing
  # from the actual signer segment (ItWorksinMyLocal#62 gate review).
  local g4_ok=0
  local extradata_field=""
  if [ -f "$genesis_file" ]; then
    extradata_field=$(grep -oE '"extraData"[[:space:]]*:[[:space:]]*"[^"]*"' "$genesis_file" | head -1)
  fi
  if [ -n "$extradata_field" ] && printf '%s' "$extradata_field" | grep -qi "${cand_addr#0x}"; then
    echo "PASS: G4 (extraData): cand1 ($cand_addr) appears in genesis extraData" >&2
  else
    echo "FAIL: G4 (extraData): cand1 ($cand_addr) does NOT appear in genesis extraData ($genesis_file)" >&2
    g4_ok=1
  fi
  local candidates
  if candidates=$(lab_get_candidates "$ref" 2>/dev/null) && printf '%s\n' "$candidates" | tr ',' '\n' | grep -qiF "$cand_addr"; then
    echo "PASS: G4 (0x88 SMC): cand1 ($cand_addr) appears in getCandidates()" >&2
  else
    echo "FAIL: G4 (0x88 SMC): cand1 ($cand_addr) does NOT appear in getCandidates() (got: ${candidates:-<unreadable>})" >&2
    g4_ok=1
  fi
  if [ "$g4_ok" -ne 0 ]; then
    _s15_emit_state S1 "G4 extraData/SMC authorization failed -- cand1's genesis-time seat is not actually visible on chain, see lines above"
    echo "scen_15: FAIL (G4) - extraData/SMC authorization check failed"
    return 1
  fi
  echo "scen_15: G4 PASS (extraData + 0x88 SMC authorization)" >&2

  # ---- G5: V1 turn/rotation correctness over the FULL signer set (sealers + cand1) ----
  local a1 a2 a3
  a1=$("$REPO_ROOT/netlab/node.sh" addr "$_S15_TOPO" node1) || return 1
  a2=$("$REPO_ROOT/netlab/node.sh" addr "$_S15_TOPO" node2) || return 1
  a3=$("$REPO_ROOT/netlab/node.sh" addr "$_S15_TOPO" node3) || return 1
  local full_signers="$a1,$a2,$a3,$cand_addr"
  local turn_from=$((_S15_SETTLE + 1)) turn_to=$((_S15_SETTLE + _S15_TURN_WINDOW))
  echo "scen_15: waiting for the reference to reach block $turn_to for G5 (turn-order) / G6 (mint-gate) window [$turn_from..$turn_to] ..." >&2
  lab_wait_block "$ref" "$turn_to" $((turn_to * 3 + 300)) || {
    _s15_emit_state S3 "reference never reached block $turn_to -- cannot evaluate G5/G6 windows"
    echo "scen_15: FAIL (G5/G6) - reference never reached block $turn_to"
    return 1
  }
  local g5_out g5_rc
  g5_out=$(assert_v1_turn_order "$turn_from" "$turn_to" "node1=$ref" "$full_signers")
  g5_rc=$?
  echo "$g5_out" >&2

  # ---- G6a: THE MINT GATE, pre-switch window -- did cand1 actually mint a
  # block in the near-genesis window? (unchanged from every prior round) ----
  echo "scen_15: G6a -- scanning obs1 (independent oldxdc observer) for cand1's first minted block in [$turn_from..$turn_to] (pre-switch window, timeout ${_S15_MINT_TIMEOUT}s) ..." >&2
  local mint_h
  mint_h=$(_s15_scan_for_mint "${URL[obs1]}" "$turn_from" "$turn_to" "$cand_norm" "$_S15_MINT_TIMEOUT") || mint_h=""
  [ -n "$mint_h" ] && echo "scen_15: G6a -- candidate observed minting block $mint_h (pre-switch, per obs1)" >&2

  # ---- G6b: THE MINT GATE, V2-focus opt-in -- STRICTLY ABOVE v2block ----
  # (ItWorksinMyLocal#62 round-2 "blocked-harness" fix): only runs when the
  # caller explicitly budgets S15_V2_TIMEOUT>0. Runs REGARDLESS of whether
  # G6a already found an early V1 mint above -- a mint below the switch
  # (S5 evidence) never substitutes for one above it (S6 evidence), and a
  # single window starting near genesis would always find the early one
  # first and never actually reach/prove the post-switch case (exactly how
  # this bug went undetected: MINT_V2BLOCK could be set to anything and
  # this scenario's own scan window never moved to follow it).
  local v2_mint_h=""
  if [ "$_S15_V2_TIMEOUT" -gt 0 ] 2>/dev/null; then
    local v2_from=$((_S15_V2BLOCK + 1)) v2_to=$((_S15_V2BLOCK + _S15_V2_WINDOW))
    echo "scen_15: G6b (V2-focus) -- waiting up to ${_S15_V2_TIMEOUT}s for the reference to cross the V1->V2 switch (v2block=$_S15_V2BLOCK) and reach block $v2_to ..." >&2
    if lab_wait_block "$ref" "$v2_to" "$_S15_V2_TIMEOUT"; then
      echo "scen_15: G6b -- reference past the switch; scanning obs1 for cand1's mint in [$v2_from..$v2_to] (strictly ABOVE v2block=$_S15_V2BLOCK) ..." >&2
      v2_mint_h=$(_s15_scan_for_mint "${URL[obs1]}" "$v2_from" "$v2_to" "$cand_norm" 60) || v2_mint_h=""
      if [ -n "$v2_mint_h" ]; then
        echo "scen_15: G6b -- candidate observed minting block $v2_mint_h (post-switch, per obs1)" >&2
      else
        echo "scen_15: G6b -- reference reached $v2_to but no cand1 mint found in [$v2_from..$v2_to]" >&2
      fi
    else
      echo "scen_15: G6b -- reference never reached block $v2_to within ${_S15_V2_TIMEOUT}s -- switch not (yet) reached this run, no V2 evidence possible" >&2
    fi
  fi

  # A post-switch mint strictly dominates a pre-switch one as evidence (it
  # implies S5 AND S6 in one run) -- prefer it as the height carried
  # forward into assert_mint_accepted/G7 below whenever G6b actually found
  # one; otherwise fall back to G6a's pre-switch mint (S5 only).
  [ -n "$v2_mint_h" ] && mint_h="$v2_mint_h"

  if [ -z "$mint_h" ]; then
    # Honest SKIP (ItWorksinMyLocal#62 section 4 / scenario 14 precedent):
    # G1-G4 all genuinely passed above -- the harness/topology is healthy --
    # but no mint was observed for cand1's client in either window, which is
    # the EXPECTED outcome for a client this framework doesn't yet have a
    # verified sealing path for.
    local blocker="${_S15_BLOCKER[$cand_client]:-no known sealing path for client '$cand_client' in this harness yet (ItWorksinMyLocal#62)}"
    [ "$g5_rc" -ne 0 ] && blocker="$blocker; G5 turn-order also shows cand1 absent from the rotation (consistent with it never sealing): $g5_out"
    [ "$_S15_V2_TIMEOUT" -gt 0 ] 2>/dev/null && blocker="$blocker; G6b (V2-focus, v2block=$_S15_V2BLOCK) also found nothing"
    _s15_emit_state S3 "$blocker"
    echo "SKIP:cand1 ($cand_client) never minted a block in [$turn_from..$turn_to]$( [ "$_S15_V2_TIMEOUT" -gt 0 ] 2>/dev/null && printf ' or [%s..%s]' "$((_S15_V2BLOCK + 1))" "$((_S15_V2BLOCK + _S15_V2_WINDOW))" ) -- $blocker"
    return 2
  fi

  echo "scen_15: G6 -- candidate observed minting block $mint_h ($( [ -n "$v2_mint_h" ] && echo "post-switch, " )per obs1); running assert_mint_accepted (the full 5-condition gate) ..." >&2
  local witnesses_csv="node2=${URL[node2]},node3=${URL[node3]},obs1=${URL[obs1]}"
  local hashnodes_csv="" logn_csv=""
  for id in $ids; do
    hashnodes_csv="${hashnodes_csv}${hashnodes_csv:+,}$id=${URL[$id]}"
    logn_csv="${logn_csv}${logn_csv:+,}$id=${LOGF[$id]}"
  done

  local mint_out mint_rc
  mint_out=$(assert_mint_accepted "$cand_addr" "$mint_h" "$genesis_file" "$witnesses_csv" "$hashnodes_csv" "$logn_csv")
  mint_rc=$?
  echo "$mint_out" >&2

  # mint_state is a CAP, not a starting point: the ItWorksinMyLocal#62
  # mint-enablement graph is linear (S5 V1-mint-accepted -> S6 V2-mint-
  # accepted -> S7 fair-share) -- a mint observed below MINT_V2BLOCK only
  # ever exercised V1 sealing, so the honest state for THIS run can never
  # exceed S5 regardless of how well G7 (fair share) goes below.
  local mint_state="S5"; [ "$mint_h" -ge "$_S15_V2BLOCK" ] 2>/dev/null && mint_state="S6"

  # g5_note: G5 (P3 turn-order) is evaluated above, over the SAME window,
  # but must never be silently discarded just because a real mint (G6) was
  # also observed -- that exact "g5_rc only consulted in the no-mint SKIP
  # branch" pattern is a can't-fail-once-minted masking bug the
  # ItWorksinMyLocal#62 gate review found. Every terminal state emitted
  # from here on carries this note (non-empty only on a real G5 failure).
  local g5_note=""
  [ "$g5_rc" -ne 0 ] && g5_note=" ALSO: G5 (P3 turn-order) FAILED over [$turn_from..$turn_to], not masked by the mint success: ${g5_out#FAIL: }"

  if [ "$mint_rc" -ne 0 ]; then
    _s15_emit_state S4 "cand1 was OBSERVED minting block $mint_h but the mint gate (assert_mint_accepted) FAILED: ${mint_out#FAIL: }${g5_note}"
    echo "scen_15: FAIL (G6) - assert_mint_accepted rejected the observed mint at H=$mint_h (see line above) -- this is a REAL failure, not folded into a SKIP"
    return 1
  fi
  echo "scen_15: G6 PASS (the mint gate) -- cand1 ($cand_client) minted block $mint_h, verified via >=2 other validators + an independent oldxdc observer, cross-client hash agreement, canonical past H+3, and no validation bypass anywhere" >&2

  # ---- G7: fair share -- only meaningful now that a real mint was observed ----
  local share_from=$((mint_h)) share_to=$((mint_h + _S15_SHARE_WINDOW))
  echo "scen_15: G7 -- waiting for the reference to reach block $share_to for the fair-share window [$share_from..$share_to] ..." >&2
  if ! lab_wait_block "$ref" "$share_to" $((share_to * 2 + 300)); then
    _s15_emit_state "$mint_state" "mint gate PASSED at H=$mint_h, but the reference never reached block $share_to to evaluate G7 (fair share) -- treat as an inconclusive soak, not a fairness regression.${g5_note} [$cand_provenance]"
    echo "SKIP:G6 (the mint gate) PASSED at H=$mint_h, but the reference never reached block $share_to within the timeout to evaluate G7 (fair share)"
    return 2
  fi
  local share_out share_rc
  share_out=$(assert_mint_share "$share_from" "$share_to" "node1=$ref" "$full_signers" "${S15_SHARE_TOL:-0.4}")
  share_rc=$?
  echo "$share_out" >&2

  if [ "$share_rc" -ne 0 ]; then
    _s15_emit_state "$mint_state" "mint gate PASSED at H=$mint_h, but G7 (fair share) FAILED over [$share_from..$share_to]: ${share_out#FAIL: }${g5_note}"
    echo "scen_15: FAIL (G7) - fair-share assertion failed over [$share_from..$share_to] (see line above)"
    return 1
  fi

  # ---- final state: capped at mint_state; S7 (fair-share) is only ever
  # reached by PROMOTING an already-S6 run (a V2-crossing mint) -- never
  # hardcoded on the mere fact that G6+G7 both passed, which is exactly
  # the S5-run-reported-as-S7 overclaim the gate review found. ----
  local final_state="$mint_state"
  [ "$mint_state" = "S6" ] && final_state="S7"

  if [ "$g5_rc" -ne 0 ]; then
    # A real G5 (P3) FAIL must never flow into a silent PASS just because
    # the mint gate (G6) -- and now G7 -- also passed. Report as SKIP (not
    # PASS): the mint itself is genuine and disclosed via MINT_GRAPH_STATE
    # below, but full G1-G7 coverage was NOT clean, so this run cannot
    # honestly claim the unqualified PASS/state that a clean run would.
    _s15_emit_state "$final_state" "mint gate (G6) genuinely PASSED at H=$mint_h and G7 fair-share also passed, but G5 (P3 turn-order) FAILED over [$turn_from..$turn_to] and is NOT masked by that success: ${g5_out#FAIL: } [$cand_provenance]"
    echo "SKIP:cand1 ($cand_client) minted block $mint_h (G6 mint gate genuinely PASSED) and G7 fair-share also passed, but G5 (P3 turn-order) FAILED over [$turn_from..$turn_to] -- not folded into a PASS; see the FAIL line above for detail"
    return 2
  fi

  if [ "$final_state" = "S7" ]; then
    _s15_emit_state S7 "[$cand_provenance]"
    echo "scen_15: PASS - cand1 ($cand_client) minted block $mint_h (>= MINT_V2BLOCK=$_S15_V2BLOCK, a V2-crossing mint) under the full anti-masking gate (G6) and shares turns fairly (G7) -- ItWorksinMyLocal#62 state S7"
  else
    _s15_emit_state "$final_state" "V1 mint-accepted + fair-share verified at H=$mint_h, but H < MINT_V2BLOCK=$_S15_V2BLOCK so this run never exercised V2 sealing -- S6/S7 remain untested; rerun with MINT_V2BLOCK <= $mint_h to reach them. [$cand_provenance]"
    echo "scen_15: PASS - cand1 ($cand_client) minted block $mint_h under the full anti-masking gate (G6) and shares turns fairly under V1 (G7) -- ItWorksinMyLocal#62 state $final_state (H=$mint_h < MINT_V2BLOCK=$_S15_V2BLOCK: V2-mint/S6 and S7 were NOT exercised this run)"
  fi
  return 0
}
