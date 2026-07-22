#!/bin/bash
# scenario.sh - runs one or all lab consensus scenarios
# (docs/lab/DESIGN.md §7/§8).
#
# Usage:
#   ./scenario.sh <id>      run one scenario (e.g. 01, 02, ...)
#   ./scenario.sh --all     run every scenario found in scenarios/*.sh
#   ./scenario.sh --list    list discovered scenario ids + descriptions
#   ./scenario.sh --matrix <id> --clients a,b,c
#                           run scenario <id> once per client in the list
#                           (LAB_CLIENTS=<that one client> for each run --
#                           only meaningful for a scenario that reads
#                           lab_clients()/$LAB_CLIENTS, e.g. 01), writing
#                           results/matrix.md (ItWorksinMyLocal#46 T2.5)
#
# Scenario file contract (scenarios/NN-name.sh), see docs/lab/DESIGN.md §7:
#   - the file stem's leading token before the first '-' is its id (e.g.
#     "01" for "01-diff-oracle-baseline.sh")
#   - defines scen_<id>() implementing up -> drive -> observe -> verdict,
#     using the lib-lab.sh / masternode.sh / oracle.sh API
#   - sets SCEN_DESC, SCEN_PRIORITY, SCEN_PROFILE (fast|real), SCEN_MODE
#     (OBSERVE|INJECT) as plain variables before/at the top of the file
#   - scen_<id>() exit code: 0 = PASS, 1 = FAIL, 2 = SKIP (the function
#     should echo a line starting "SKIP:<reason>" before returning 2 --
#     INJECT scenarios with no patched binary available must SKIP, never
#     silently PASS)
#
# This runner sources scenario files one at a time (so each file's SCEN_*
# metadata is captured before the next file can overwrite it), calls
# lab_teardown AND topo_down (ItWorksinMyLocal#46 T2.1 -- idempotent,
# no-op if no netlab topology is up) before and after each run for
# isolation, and -- when run with --all -- writes results/summary.md (id,
# priority, verdict, reason, duration). An empty scenarios/ directory is
# not an error: it just means there's nothing to run yet.

_SELF_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
_SELF="$_SELF_DIR/$(basename "$0")"
cd "$_SELF_DIR" || exit 1
# shellcheck source=lib-lab.sh
source ./lib-lab.sh
# ItWorksinMyLocal#46 T2.1: topo_up/topo_down/topo_rpc/topo_nodes/topo_stop,
# so any scenario -- and this file's own generic teardown below -- can
# drive a netlab topology.
# shellcheck source=lib-topo.sh
source ./lib-topo.sh
# T2.3: assert_genesis_parity/assert_lockstep/assert_hash_agreement/
# assert_survives_epoch, so any scenario can use named assertions instead
# of open-coding its own PASS/FAIL wait-and-compare logic.
# shellcheck source=lib-assert.sh
source ./lib-assert.sh

SCEN_DIR="$LAB_DIR/scenarios"

_usage() { sed -n '2,23p' "$_SELF" | sed 's/^# \{0,1\}//'; }

# Every scenarios/*.sh file, in sorted order ("" if the dir is empty/missing).
_all_scenario_files() {
  [ -d "$SCEN_DIR" ] || return 0
  local f any=0
  for f in "$SCEN_DIR"/*.sh; do
    [ -e "$f" ] || continue
    any=1
    printf '%s\n' "$f"
  done
  [ "$any" = 1 ]
}

# The scenario file whose id (leading token before the first '-' in the
# stem) matches $1.
_scenario_file_for_id() {
  local id="$1" f base fid
  [ -d "$SCEN_DIR" ] || return 1
  for f in "$SCEN_DIR"/*.sh; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .sh)
    fid="${base%%-*}"
    if [ "$fid" = "$id" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# Runs one scenario file end to end; prints a single
# "id|priority|verdict|reason|duration" summary line on stdout (the
# scenario's own output goes to stderr so it doesn't get mixed into that
# line).
_run_one() {
  local file="$1" base id fn start end dur out rc verdict reason
  base=$(basename "$file" .sh)
  id="${base%%-*}"
  SCEN_DESC=""; SCEN_PRIORITY=""; SCEN_PROFILE=""; SCEN_MODE=""
  # shellcheck disable=SC1090
  source "$file"
  fn="scen_${id}"

  lab_teardown >/dev/null 2>&1
  topo_down >/dev/null 2>&1  # idempotent (T2.1): no-op if no topology is up

  if ! declare -F "$fn" >/dev/null 2>&1; then
    printf '%s|%s|FAIL|no function %s() defined in %s|0s\n' "$id" "${SCEN_PRIORITY:-?}" "$fn" "$file"
    return 1
  fi

  start=$(date +%s)
  out=$("$fn" 2>&1)
  rc=$?
  end=$(date +%s)
  dur=$((end - start))

  reason="-"
  case "$rc" in
    0) verdict=PASS ;;
    2) verdict=SKIP; reason=$(printf '%s\n' "$out" | grep -m1 '^SKIP:' || true)
       [ -n "$reason" ] || reason="SKIP (no reason given)" ;;
    *) verdict=FAIL; reason=$(printf '%s\n' "$out" | tail -1) ;;
  esac

  [ -n "$out" ] && printf '%s\n' "$out" >&2
  printf '%s|%s|%s|%s|%ss\n' "$id" "${SCEN_PRIORITY:-?}" "$verdict" "$reason" "$dur"

  lab_teardown >/dev/null 2>&1
  topo_down >/dev/null 2>&1  # idempotent (T2.1): no-op if no topology is up
}

_run_all() {
  mkdir -p "$LAB_RESULTS_DIR" || exit 1
  local files=() f line id pri verdict reason dur fail_count=0

  while IFS= read -r f; do files+=("$f"); done < <(_all_scenario_files 2>/dev/null)

  {
    echo "# Lab scenario summary"
    echo
    echo "Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo
  } > "$LAB_RESULTS_DIR/summary.md"

  if [ "${#files[@]}" -eq 0 ]; then
    echo "No scenarios found in $SCEN_DIR (none built yet)."
    echo "_(no scenario files found in scenarios/)_" >> "$LAB_RESULTS_DIR/summary.md"
    echo "Wrote $LAB_RESULTS_DIR/summary.md"
    exit 0
  fi

  {
    echo "| id | priority | verdict | reason | duration |"
    echo "|----|----------|---------|--------|----------|"
  } >> "$LAB_RESULTS_DIR/summary.md"

  for f in "${files[@]}"; do
    line=$(_run_one "$f")
    IFS='|' read -r id pri verdict reason dur <<<"$line"
    echo "| $id | $pri | $verdict | ${reason:--} | $dur |" >> "$LAB_RESULTS_DIR/summary.md"
    echo "[$id] $verdict ($dur) ${reason:-}"
    [ "$verdict" = "FAIL" ] && fail_count=$((fail_count + 1))
  done

  echo "Wrote $LAB_RESULTS_DIR/summary.md"
  [ "$fail_count" -eq 0 ]
}

# _run_matrix <id> <clients-csv>: runs scenario <id> once per client in
# clients-csv (ItWorksinMyLocal#46 T2.5), exporting LAB_CLIENTS=<that one
# client> for each run (bash applies a leading VAR=val assignment to a
# function call's environment for that call only, exactly as it would for
# an external command) so a scenario that reads lab_clients()/$LAB_CLIENTS
# (e.g. 01) brings up only that one follower client per row. A scenario
# that ignores LAB_CLIENTS entirely (e.g. 11, 12) just runs identically
# every row -- --matrix is generic client-varying infrastructure, not tied
# to any one scenario. Writes results/matrix.md (id x client -> verdict),
# same one-line-per-row shape as _run_all's summary.md; exits nonzero if
# any row FAILed.
_run_matrix() {
  local id="$1" clients_csv="$2" file c line pri verdict reason dur fail_count=0
  file=$(_scenario_file_for_id "$id") || { echo "no scenario with id '$id' in $SCEN_DIR" >&2; exit 1; }
  [ -n "$clients_csv" ] || { echo "scenario.sh --matrix: --clients a,b,c is required" >&2; exit 1; }
  mkdir -p "$LAB_RESULTS_DIR" || exit 1

  {
    echo "# Lab scenario matrix: id=$id"
    echo
    echo "Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "| client | priority | verdict | reason | duration |"
    echo "|--------|----------|---------|--------|----------|"
  } > "$LAB_RESULTS_DIR/matrix.md"

  for c in $(printf '%s' "$clients_csv" | tr ',' ' '); do
    echo "scenario.sh --matrix: id=$id client=$c ..." >&2
    line=$(LAB_CLIENTS="$c" _run_one "$file")
    IFS='|' read -r _ pri verdict reason dur <<<"$line"
    echo "| $c | $pri | $verdict | ${reason:--} | $dur |" >> "$LAB_RESULTS_DIR/matrix.md"
    echo "[$id/$c] $verdict ($dur) ${reason:-}"
    [ "$verdict" = "FAIL" ] && fail_count=$((fail_count + 1))
  done

  echo "Wrote $LAB_RESULTS_DIR/matrix.md"
  [ "$fail_count" -eq 0 ]
}

_list() {
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(_all_scenario_files 2>/dev/null)
  if [ "${#files[@]}" -eq 0 ]; then
    echo "No scenarios found in $SCEN_DIR (none built yet)."
    return 0
  fi
  local base id
  for f in "${files[@]}"; do
    base=$(basename "$f" .sh)
    id="${base%%-*}"
    SCEN_DESC=""; SCEN_PRIORITY=""; SCEN_PROFILE=""; SCEN_MODE=""
    # shellcheck disable=SC1090
    source "$f"
    printf '%-4s %-8s %-8s %-8s %s\n' "$id" "${SCEN_PRIORITY:-?}" "${SCEN_PROFILE:-?}" "${SCEN_MODE:-?}" "${SCEN_DESC:-$base}"
  done
}

case "${1:-}" in
  ""|-h|--help)
    _usage
    exit 0
    ;;
  --list)
    _list
    ;;
  --all)
    _run_all
    exit $?
    ;;
  --matrix)
    id="$2"
    [ -n "$id" ] || { echo "usage: $(basename "$0") --matrix <id> --clients a,b,c" >&2; exit 1; }
    [ "${3:-}" = "--clients" ] || { echo "usage: $(basename "$0") --matrix <id> --clients a,b,c" >&2; exit 1; }
    _run_matrix "$id" "${4:-}"
    exit $?
    ;;
  *)
    id="$1"
    file=$(_scenario_file_for_id "$id") || { echo "no scenario with id '$id' in $SCEN_DIR" >&2; exit 1; }
    line=$(_run_one "$file")
    echo "$line"
    verdict=$(printf '%s' "$line" | cut -d'|' -f3)
    [ "$verdict" = "PASS" ] || [ "$verdict" = "SKIP" ]
    ;;
esac
