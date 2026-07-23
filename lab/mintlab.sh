#!/bin/bash
# mintlab.sh - the mint loop's thin outer shell (ItWorksinMyLocal#62 section
# 4): runs lab/scenarios/15-topo-mint-rotation.sh once per client, in order,
# and persists an honest per-client mint-enablement-graph (S0-S7) state to
# lab/results/mint-graph.md.
#
# Usage:
#   ./mintlab.sh                    # every client, in the default order
#   ./mintlab.sh geth xone reth     # just these, in this order
#   ./mintlab.sh --v2 geth          # V2-focus mint-iter variant (below), just geth
#
# --v2 (ItWorksinMyLocal#62 round-2 "blocked-harness" fix / mint-iter V2
# variant): dispatches scenario 15 with MINT_V2BLOCK=900 (the smallest
# epoch-aligned V1->V2 switch topo.sh allows) and S15_V2_TIMEOUT=${S15_V2_TIMEOUT:-1800}
# (a 30-minute default budget -- override by exporting S15_V2_TIMEOUT
# yourself before calling --v2) so scenario 15's own G6b pass actually
# waits for the fleet to cross the switch and scans STRICTLY ABOVE it for
# a real post-switch mint -- the only way this harness can honestly
# promote a client past S5 (V1-mint) to S6/S7. Without --v2 (the default),
# scenario 15's G6 never moves past its near-genesis window regardless of
# MINT_V2BLOCK, so S6/S7 are unreachable no matter how long you wait --
# this was the exact gap ItWorksinMyLocal#62 round 2 hit and reported as
# "blocked-harness" for geth. Results go to a SEPARATE file,
# lab/results/mint-graph-v2.md, so a --v2 run never clobbers the default
# (fast, V1-focus) mint-graph.md a plain ./mintlab.sh run produced.
#
# This is deliberately NOT the full autonomous loop the umbrella issue
# describes ("fleet-up -> gates G1-G7 -> on fail: diagnose, classify
# harness-vs-client, fix+PR (harness) or issue+PR upstream (client), retry")
# -- that needs a human or agent driving actual fixes BETWEEN iterations,
# which is out of scope for a mechanical script. What this script IS: the
# always-safe, deterministic shell that loop calls each iteration -- run
# scenario 15 once per client, capture its real verdict + gate-level detail
# (never fabricated), and write it to mint-graph.md. Re-running it after a
# fix lands simply overwrites the affected client's row with whatever
# actually happened this time.
#
# Per-client dispatch:
#   - a client scenario 15 can actually attempt (geth, xone, reth -- the
#     only role=proposer-capable clients topo.sh accepts today, see
#     netlab/topo.sh) is run via `CAND_CLIENT=<c> ./scenario.sh 15`, one at
#     a time (NOT scenario.sh's own --matrix, which only records a FAIL/SKIP
#     reason in matrix.md and drops all detail on a PASS -- this script
#     needs the MINT_GRAPH_STATE line scenario 15 always emits, on stdout,
#     regardless of verdict).
#   - a client with no sealing-flag path in this harness yet (besu, erigon,
#     nethermind) is recorded directly from a static, documented blocker
#     table below -- NOT run through scenario 15 at all: topo.sh's own
#     role=proposer client restriction would hard-reject it before a single
#     node started, and attempting it anyway would just be noise, not a
#     genuine attempt. Update the table (and, ideally, topo.sh's own
#     restriction) if/when one of these gains real sealing wiring.

_MINTLAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
LAB_DIR="$_MINTLAB_DIR"
RESULTS_DIR="$LAB_DIR/results"
mkdir -p "$RESULTS_DIR" || exit 1

# ItWorksinMyLocal#62 section 4's own dispatch order.
_DEFAULT_ORDER="geth xone reth besu erigon nethermind"
_PROPOSER_CAPABLE="geth xone reth"

_is_capable() {
  local c="$1"
  case " $_PROPOSER_CAPABLE " in *" $c "*) return 0 ;; *) return 1 ;; esac
}

# Static, honest fallback for a client this script does not attempt at all
# (see the header) -- mirrors ItWorksinMyLocal#62's own graph table; update
# the text here (and cite a fresher issue/PR) as that table's own entries move.
declare -A _STATIC_STATE=(
  [besu]="S1"
  [erigon]="S1->S2"
  [nethermind]="S0"
)
declare -A _STATIC_BLOCKER=(
  [besu]="confirmed S1 live this session on a mint-iter-shaped 3-sealer+besu-follower probe (topologies/mint-iter-besu-probe.json): the currently-staged binary (bin/besu, sha256 7ade4f2f..., NOT the separately-tracked broken-at-block-1 246e5030 build in ItWorksinMyLocal#51) boots, peers, and hash-agrees with all 3 independent oldxdc sealers through block 15, then permanently stalls at block 16 (stateRoot mismatch on the first XDPoS 0x89 signing-tx block) and never recovers -- root-caused to XdposConfigOptions' TIPSigning/TIPXDCX default (=0, \"active from genesis\") being wrong whenever a genesis omits tipsigning/tipxdcx/tiptrc21fee (as gen-genesis.sh always does) while still deploying real BlockSigners bytecode at 0x89 (as gen-genesis.sh also always does) -- filed XDCIndia/besu#47 with full repro; besu never reaches S2 (clean follow-at-tip) on this class of genesis, so no sealing/mint question is even reachable yet, independent of and in addition to topo.sh's own role=proposer restriction -- client-side work, blocked-upstream(https://github.com/XDCIndia/besu/issues/47)"
  [erigon]="staged-sync has no XDPoS production path yet -- client-side work, heavy"
  [nethermind]="confirmed S0 live this session (topo.sh validate rejects a mint-iter-shaped topology for ANY nethermind node, proposer or plain follower, at any chainId != 5151 -- no genesis->chainspec converter exists); even where a converter existed, S3+ is separately blocked by xdc-nethermind-private#224 (InitBlockProducer() => NotSupportedException) -- see xdc-nethermind-private#250, blocked-upstream"
)

# --v2 (mint-iter V2 variant, ItWorksinMyLocal#62 round-2 fix -- see header):
# must be the first arg if present. Sets MINT_V2BLOCK/S15_V2_TIMEOUT for
# every scenario-15 invocation below (unless the caller already exported
# either one, in which case that value wins) and redirects output to a
# separate mint-graph-v2.md.
_V2_MODE=0
if [ "${1:-}" = "--v2" ]; then
  _V2_MODE=1
  shift
  export MINT_V2BLOCK="${MINT_V2BLOCK:-900}"
  export S15_V2_TIMEOUT="${S15_V2_TIMEOUT:-1800}"
  echo "mintlab.sh: --v2 mode -- MINT_V2BLOCK=$MINT_V2BLOCK S15_V2_TIMEOUT=${S15_V2_TIMEOUT}s (scenario 15 will wait for + scan strictly above the switch, see lab/scenarios/15-topo-mint-rotation.sh)" >&2
fi

CLIENTS=("$@")
if [ "${#CLIENTS[@]}" -eq 0 ]; then
  # shellcheck disable=SC2206  # word-splitting the default order is intentional here
  CLIENTS=($_DEFAULT_ORDER)
fi

RESULTS_MD="$RESULTS_DIR/mint-graph.md"
[ "$_V2_MODE" -eq 1 ] && RESULTS_MD="$RESULTS_DIR/mint-graph-v2.md"
SCRATCH="$RESULTS_DIR/.$(basename "$RESULTS_MD").building.$$"
rm -f "$SCRATCH"

{
  echo "# Mint-enablement graph (ItWorksinMyLocal#62)$( [ "$_V2_MODE" -eq 1 ] && printf ' -- V2-focus variant (MINT_V2BLOCK=%s, S15_V2_TIMEOUT=%ss)' "$MINT_V2BLOCK" "$S15_V2_TIMEOUT" )"
  echo
  echo "Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ') by mintlab.sh$( [ "$_V2_MODE" -eq 1 ] && echo " --v2" )"
  echo
  echo "\`S0 boots -> S1 syncs -> S2 follows-at-tip(clean) -> S3 authorized-as-signer -> S4 scheduled-for-turn -> S5 V1-mint-accepted -> S6 V2-mint-accepted -> S7 fair-share\`"
  echo
  echo "| client | state | verdict | blocker / next step |"
  echo "|--------|-------|---------|----------------------|"
} > "$SCRATCH"

_overall_fail=0

for c in "${CLIENTS[@]}"; do
  if ! _is_capable "$c"; then
    state="${_STATIC_STATE[$c]:-?}"
    blocker="${_STATIC_BLOCKER[$c]:-not attempted by mintlab.sh (unknown client)}"
    echo "mintlab.sh: $c -- not proposer-capable in this harness yet (topo.sh restricts role=proposer to geth|xone|reth); recording static state, not attempting" >&2
    printf '| %s | %s | (not attempted) | %s |\n' "$c" "$state" "$blocker" >> "$SCRATCH"
    continue
  fi

  echo "mintlab.sh: running scenario 15 for CAND_CLIENT=$c ..." >&2
  out=$(cd "$LAB_DIR" && CAND_CLIENT="$c" ./scenario.sh 15 2>&1)
  # scenario.sh's own single-scenario invocation prints one final
  # "id|priority|verdict|reason|duration" line on stdout, mixed here with
  # everything _run_one dumped from stderr (the full scenario narrative,
  # ALWAYS emitted regardless of verdict -- see scenario.sh's _run_one) --
  # exactly what lets this script recover full PASS detail a --matrix run's
  # own matrix.md would have discarded.
  summary=$(printf '%s\n' "$out" | grep -E '^15\|' | tail -1)
  verdict=$(printf '%s' "$summary" | cut -d'|' -f3)
  reason=$(printf '%s' "$summary" | cut -d'|' -f4)
  [ -n "$verdict" ] || verdict="FAIL"
  [ "$verdict" = "FAIL" ] && _overall_fail=1

  state_line=$(printf '%s\n' "$out" | grep -m1 '^MINT_GRAPH_STATE:')
  state=$(printf '%s' "$state_line" | grep -oE 'state=[^ ]+' | cut -d= -f2)
  blocker=$(printf '%s' "$state_line" | sed -n 's/.*blocker="\(.*\)"$/\1/p')
  [ -n "$state" ] || state="?"
  [ -n "$blocker" ] || blocker="${reason:-no MINT_GRAPH_STATE line found in scenario 15 output -- see lab/results/ for its own log detail}"

  echo "mintlab.sh: $c -> verdict=$verdict state=$state" >&2
  printf '| %s | %s | %s | %s |\n' "$c" "$state" "$verdict" "$blocker" >> "$SCRATCH"
done

mv "$SCRATCH" "$RESULTS_MD"
echo "mintlab.sh: wrote $RESULTS_MD"
[ "$_overall_fail" -eq 0 ]
