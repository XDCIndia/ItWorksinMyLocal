#!/bin/bash
# mintlab.sh - the mint loop's thin outer shell (ItWorksinMyLocal#62 section
# 4): runs lab/scenarios/15-topo-mint-rotation.sh once per client, in order,
# and persists an honest per-client mint-enablement-graph (S0-S7) state to
# lab/results/mint-graph.md.
#
# Usage:
#   ./mintlab.sh                    # every client, in the default order
#   ./mintlab.sh geth xone reth     # just these, in this order
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
  [besu]="no known Java block-production path yet; also binary-broken@block1 in some builds (#51) -- client-side work, heavy"
  [erigon]="staged-sync has no XDPoS production path yet -- client-side work, heavy"
  [nethermind]="only loads its own bundled net5151 Parity chainspec (topo.sh rejects any other chainId for it); needs a genesis->chainspec converter before sealing is even reachable -- harness->client"
)

CLIENTS=("$@")
if [ "${#CLIENTS[@]}" -eq 0 ]; then
  # shellcheck disable=SC2206  # word-splitting the default order is intentional here
  CLIENTS=($_DEFAULT_ORDER)
fi

RESULTS_MD="$RESULTS_DIR/mint-graph.md"
SCRATCH="$RESULTS_DIR/.mint-graph.md.building.$$"
rm -f "$SCRATCH"

{
  echo "# Mint-enablement graph (ItWorksinMyLocal#62)"
  echo
  echo "Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ') by mintlab.sh"
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
