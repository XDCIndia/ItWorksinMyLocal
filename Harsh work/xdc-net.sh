#!/usr/bin/env bash
# =============================================================================
# xdc-net.sh — one command for a private XDC network:
#   4 XDC (oldxdc) sealers  +  geth, erigon, nethermind, besu, xone followers
#   (reth is deliberately NOT included: it needs ~3 GB RAM on its own)
#
# Usage:
#   ./xdc-net.sh start     set everything up and start the network (fresh chain)
#   ./xdc-net.sh status    show every node: block, peers, same-chain check, RAM
#   ./xdc-net.sh stop      stop every node cleanly (data is kept)
#   ./xdc-net.sh check     only check the machine + prepare files, start nothing
#
# Connecting a reth node on ANOTHER laptop on a different network (via Tailscale):
#   both laptops:     ./xdc-net.sh tailscale          install Tailscale + log in (same account on both)
#   network laptop:   ./xdc-net.sh connect-info       writes connect-<CHAIN_ID>.json (genesis + sealer addresses)
#                     -> send that file to the reth laptop (Tailscale "Send file", WhatsApp, email...)
#   reth laptop:      ./xdc-net.sh join-reth connect-20120.json   start reth and connect it
#                     ./xdc-net.sh reth-status  |  ./xdc-net.sh reth-stop
#
# Optional settings (put them in front of the command):
#   CHAIN_ID=20120          chain id of the network            (default 20120)
#   CLIENTS="geth besu"     which follower clients to add      (default: all 5)
#   PORT_BASE=35000         first port used (each node uses a block of 20)
#   ETHSTATS=off            don't report to SkyNet (stats.xdcindia.com)
#   WORKDIR=~/somewhere     where the repo + chain data live   (default ~/xdc-net-<CHAIN_ID>)
#   FORCE=1                 start even if less than 2 GB RAM is free
#   example:  CHAIN_ID=20121 ./xdc-net.sh start
#
# Needs: Linux x86_64 (Ubuntu / WSL Ubuntu), ~4 GB free RAM, ~10 GB free disk,
#        internet (downloads ~1.6 GB of client programs once). It installs
#        git/curl/python3/openssl/Java 21 with apt if they are missing (asks
#        for your sudo password once).
# =============================================================================
set -uo pipefail

CHAIN_ID_SET="${CHAIN_ID:-}"
CHAIN_ID="${CHAIN_ID:-20120}"
CLIENTS="${CLIENTS:-geth erigon nethermind besu xone}"
PORT_BASE="${PORT_BASE:-35000}"
ETHSTATS="${ETHSTATS:-on}"
WORKDIR="${WORKDIR:-$HOME/xdc-net-$CHAIN_ID}"
REPO_URL="https://github.com/XDCIndia/ItWorksinMyLocal"
REPO_COMMIT="6ce87f8"            # the commit this script was tested against
NAME="net$CHAIN_ID"
TOPO="topologies/$NAME.json"
RUN="nodes/$NAME"
SYNC_WAIT_MIN=30                 # max minutes to wait for one client (download + sync)

# ---------- output helpers ----------------------------------------------------
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=; G=; Y=; R=; N=; fi
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "  ${G}OK${N}    $*"; }
warn() { echo "  ${Y}WARN${N}  $*"; }
die()  { echo; echo "  ${R}ERROR${N} $*" >&2; echo; exit 1; }

# JSON-RPC call -> prints the "result" (or nothing on any failure)
rpc() { # rpc <port> <method> [params-json]
  curl -s -m 5 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":${3:-[]}}" \
    "http://127.0.0.1:$1" 2>/dev/null |
  python3 -c 'import sys,json
try:
    r=json.load(sys.stdin).get("result")
    print(json.dumps(r) if isinstance(r,(dict,list)) else ("" if r is None else r))
except Exception: pass' 2>/dev/null
}
head_of() { local h; h=$(rpc "$1" eth_blockNumber); [ -n "$h" ] && echo $((h)) || echo -1; }
mem_avail_mb() { awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo; }

# rows of the resolved topology: "id client role rpc"
nodes_tsv() {
  python3 - "$WORKDIR/$RUN/topo.resolved.tsv" <<'PY'
import sys
rows=[l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if not l.startswith("#")]
h=rows[0]
for r in rows[1:]:
    d=dict(zip(h,r)); print(d["id"], d["client"], d["role"], d["rpc"])
PY
}

load_env() {
  cd "$WORKDIR" || die "cannot cd to $WORKDIR (run './xdc-net.sh start' first)"
  set -a; . ./.env; set +a
  export IWML_KEYPASS="iwml-$CHAIN_ID"
  [ "$ETHSTATS" = off ] && export NETLAB_ETHSTATS=off || unset NETLAB_ETHSTATS
}

# ---------- 1. machine checks -------------------------------------------------
check_machine() {
  step "Checking this machine"
  [ "$(uname -s)" = Linux ] || die "this script needs Linux (Ubuntu, or Ubuntu inside WSL on Windows). Found: $(uname -s)"
  [ "$(uname -m)" = x86_64 ] || die "this script needs an x86_64 (Intel/AMD) machine. Found: $(uname -m)"
  ok "Linux x86_64"

  local need=() t
  for t in git curl python3 openssl; do command -v "$t" >/dev/null 2>&1 || need+=("$t"); done
  command -v ss >/dev/null 2>&1 || need+=(iproute2)
  if [[ " $CLIENTS " == *" besu "* ]] && ! java -version 2>&1 | grep -qE 'version "(2[1-9]|[3-9][0-9])'; then
    need+=(openjdk-21-jre-headless)
  fi
  if [ ${#need[@]} -gt 0 ]; then
    echo "  installing missing packages: ${need[*]}  (may ask for your sudo password)"
    command -v apt-get >/dev/null 2>&1 || die "missing: ${need[*]} -- install them yourself (no apt-get here)"
    sudo apt-get update -qq && sudo apt-get install -y -qq "${need[@]}" >/dev/null ||
      die "apt-get install failed for: ${need[*]}"
  fi
  for t in git curl python3 openssl; do command -v "$t" >/dev/null 2>&1 || die "$t still missing"; done
  ok "tools: git curl python3 openssl"
  if [[ " $CLIENTS " == *" besu "* ]]; then
    if java -version 2>&1 | grep -qE 'version "(2[1-9]|[3-9][0-9])'; then ok "Java 21+ (for besu)"
    else warn "Java 21 not available -> besu will be skipped"; CLIENTS="${CLIENTS//besu/}"; fi
  fi

  local mem; mem=$(mem_avail_mb)
  if [ "$mem" -lt 2000 ]; then
    [ "${FORCE:-0}" = 1 ] || die "only ${mem} MB RAM free; need at least 2000 MB (4000 MB for all clients). Close other programs. (FORCE=1 to try anyway)"
    warn "only ${mem} MB RAM free -- continuing because FORCE=1"
  fi
  [ "$mem" -lt 3500 ] && warn "only ${mem} MB RAM free; all clients together use ~2.5 GB. Consider CLIENTS=\"geth erigon xone\"." || ok "RAM free: ${mem} MB"

  local disk; disk=$(df -Pm "$HOME" | awk 'NR==2{print int($4/1024)}')
  [ "$disk" -lt 5 ] && die "only ${disk} GB disk free in $HOME; need 10 GB"
  [ "$disk" -lt 10 ] && warn "only ${disk} GB disk free; 10 GB recommended" || ok "disk free: ${disk} GB"

  if grep -qi microsoft /proc/version 2>/dev/null; then
    local swap; swap=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
    if [ "$swap" -lt 4000 ]; then
      warn "WSL swap is only ${swap} MB. To avoid out-of-memory, on Windows create C:\\Users\\<you>\\.wslconfig with:"
      echo "          [wsl2]"
      echo "          swap=8GB"
      echo "        then run 'wsl --shutdown' in PowerShell and open Ubuntu again. (Continuing anyway.)"
    else ok "WSL swap: ${swap} MB"; fi
  fi
}

# ---------- 2. repo + config --------------------------------------------------
prepare_repo() {
  step "Preparing $WORKDIR"
  if [ ! -d "$WORKDIR/.git" ]; then
    git clone -q "$REPO_URL" "$WORKDIR" || die "git clone $REPO_URL failed (check internet)"
    git -C "$WORKDIR" checkout -q "$REPO_COMMIT" 2>/dev/null || warn "commit $REPO_COMMIT not found, using latest"
    ok "cloned repo ($(git -C "$WORKDIR" log --oneline -1 | cut -c1-60))"
  else
    ok "repo already there ($(git -C "$WORKDIR" log --oneline -1 | cut -c1-60))"
  fi
  cd "$WORKDIR" || die "cannot cd to $WORKDIR"

  # SkyNet reporting: upstream netlab hard-codes --no-ethstats; make it switchable.
  if grep -q 'NETLAB_ETHSTATS' netlab/node.sh; then ok "SkyNet reporting switch already present"
  else
    python3 - <<'PY' && ok "patched netlab/node.sh so nodes can report to SkyNet" || warn "could not patch netlab/node.sh: nodes will NOT show on SkyNet (network still works)"
p="netlab/node.sh"; s=open(p).read()
old='--name "${TOPO_NAME}-${NODE_ID}" --no-ethstats)\n'
new=('--name "${TOPO_NAME}-${NODE_ID}")\n'
     '  # xdc-net.sh patch: NETLAB_ETHSTATS=off disables, SECRET@HOST:PORT overrides, unset = join.sh default (SkyNet)\n'
     '  case "${NETLAB_ETHSTATS:-}" in off) args+=(--no-ethstats);; "") ;; *) args+=(--ethstats "$NETLAB_ETHSTATS");; esac\n')
assert s.count(old)==1
open(p,"w").write(s.replace(old,new))
PY
  fi

  # 4 fresh sealer keys, kept private (file mode 600, never printed)
  if [ ! -f .env ] || [ "$(grep -c '^PRIVATE_KEY_[1-4]=' .env)" -lt 4 ]; then
    ( umask 077; for i in 1 2 3 4; do echo "PRIVATE_KEY_$i=$(openssl rand -hex 32)"; done > .env )
    ok "generated 4 new sealer keys in $WORKDIR/.env"
  else ok "sealer keys already in .env"; fi
  [ "$(cut -d= -f2 .env | sort -u | wc -l)" -ge 4 ] || die ".env keys are not 4 distinct keys; delete $WORKDIR/.env and re-run"

  # topology: 4 sealers start with the network; followers are added one by one later
  python3 - "$TOPO" "$NAME" "$CHAIN_ID" "$PORT_BASE" "$CLIENTS" <<'PY' || die "could not write topology"
import json, sys
path, name, chain, base, clients = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5].split()
nodes = [{"id": "xdc%d" % i, "client": "oldxdc", "role": "sealer", "keyRef": "PRIVATE_KEY_%d" % i} for i in range(1, 5)]
nodes += [{"id": c + "1", "client": c, "role": "follower", "startAt": 1} for c in clients]
json.dump({"name": name, "description": "xdc-net.sh: 4 XDC sealers + followers " + " ".join(clients),
           "chainId": chain, "epoch": 900, "v2block": 900, "period": 2, "reward": 5000, "gap": 450,
           "gasLimit": 420000000, "portBase": base, "staggerSeconds": 10, "nodes": nodes},
          open(path, "w"), indent=1)
PY
  load_env
  mkdir -p "$RUN"
  netlab/topo.sh print "$TOPO" > "$RUN/topo.resolved.tsv" 2> "$RUN/topo.err" ||
    { cat "$RUN/topo.err"; die "topology check failed"; }
  ok "topology $TOPO (chain $CHAIN_ID, ports $PORT_BASE-$((PORT_BASE + 20 * (4 + $(wc -w <<<"$CLIENTS")) )))"
}

# ---------- 3. download client programs up front (so nothing times out) -------
prefetch() {
  step "Downloading client programs (one time, ~1.6 GB; skipped if already there)"
  local c
  mkdir -p "$WORKDIR/logs"
  for c in oldxdc $CLIENTS; do
    echo "  - $c ..."
    # set +u: the repo's lib.sh is not written for 'set -u' (unset vars would abort it)
    if ( set +u; cd "$WORKDIR" && CLIENT=$c && . ./lib.sh && download_bins ) > "$WORKDIR/logs/download-$c.log" 2>&1; then
      ok "$c ready"
    else
      warn "$c pre-download failed (it will be retried when the node starts). Log: $WORKDIR/logs/download-$c.log"
    fi
  done
}

# ---------- 4. start ----------------------------------------------------------
running_sealers() { local n=0 id cl role port; while read -r id cl role port; do [ "$role" = sealer ] && [ "$(head_of "$port")" -ge 0 ] && n=$((n+1)); done < <(nodes_tsv); echo $n; }

start_net() {
  check_machine
  prepare_repo
  if [ "$(running_sealers)" -gt 0 ]; then
    warn "network $NAME is already running -- showing status instead (use './xdc-net.sh stop' first for a fresh start)"
    show_status; return 0
  fi
  prefetch

  step "Starting 4 XDC sealers (fresh chain $CHAIN_ID)"
  local force=(); [ "${FORCE:-0}" = 1 ] && force=(--force)
  nice -n 5 netlab/fleet.sh up "$TOPO" --wipe "${force[@]}" > "$WORKDIR/logs/start-sealers.log" 2>&1 ||
    { tail -25 "$WORKDIR/logs/start-sealers.log"; die "sealers failed to start (full log: $WORKDIR/logs/start-sealers.log)"; }
  local tip=-1 i
  local p1; p1=$(nodes_tsv | awk '$1=="xdc1"{print $4}')
  for i in $(seq 1 60); do tip=$(head_of "$p1"); [ "$tip" -ge 3 ] && break; sleep 5; done
  [ "$tip" -ge 3 ] || die "sealers started but no blocks after 5 min. Logs: $WORKDIR/$RUN/xdc1/node.log"
  ok "chain is producing blocks (block $tip)"

  # enodes of the 4 sealers = where followers connect
  local enodes="" id cl role port e
  while read -r id cl role port; do
    [ "$role" = sealer ] || continue
    e=$(rpc "$port" admin_nodeInfo | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["enode"].split("?")[0])
except Exception: pass')
    [ -n "$e" ] && enodes="${enodes:+$enodes,}$e"
  done < <(nodes_tsv)
  [ -n "$enodes" ] || die "could not read sealer enodes"

  step "Adding follower clients one at a time: $CLIENTS"
  local results=()
  while read -r id cl role port; do
    [ "$role" = follower ] || continue
    echo "  - $id ($cl) starting ..."
    if ! nice -n 10 netlab/node.sh start "$TOPO" "$id" --bootnodes "$enodes" > "$WORKDIR/$RUN/start-$id.log" 2>&1; then
      warn "$id did not start (log: $WORKDIR/$RUN/start-$id.log)"; results+=("$id:FAILED-TO-START"); continue
    fi
    local t0=$SECONDS st="TIMEOUT" h
    while [ $((SECONDS - t0)) -lt $((SYNC_WAIT_MIN * 60)) ]; do
      sleep 10
      tip=$(head_of "$p1"); h=$(head_of "$port")
      if ! pgrep -f "$RUN/$id" >/dev/null; then st="CRASHED"; break; fi
      if [ "$h" -gt 0 ] && [ $((tip - h)) -le 3 ]; then st="SYNCED"; break; fi
      if [ "$(mem_avail_mb)" -lt 250 ]; then st="LOW-MEMORY"; break; fi
    done
    case $st in
      SYNCED) ok "$id in sync at block $h ($(( (SECONDS - t0) ))s)";;
      LOW-MEMORY) warn "$id: RAM almost full -> stopping $id to protect the sealers"
                  netlab/node.sh stop "$TOPO" "$id" >/dev/null 2>&1;;
      *) warn "$id: $st (last lines of its log:)"; tail -5 "$WORKDIR/$RUN/$id/node.log" 2>/dev/null | cut -c1-160 | sed 's/^/          /';;
    esac
    results+=("$id:$st")
  done < <(nodes_tsv)

  show_status
  step "Done"
  echo "  followers: ${results[*]}"
  [ "$ETHSTATS" = off ] || echo "  SkyNet:    https://skynet.xdcindia.com/stats?net=$CHAIN_ID   (nodes appear after ~5-10 min)"
  echo "  status:    $0 status"
  echo "  stop:      $0 stop"
}

# ---------- status / stop -----------------------------------------------------
show_status() {
  load_env
  step "Network $NAME status"
  local p1 tip ref; p1=$(nodes_tsv | awk '$1=="xdc1"{print $4}'); tip=$(head_of "$p1")
  if [ "$tip" -lt 0 ]; then warn "xdc1 is not answering -- network is stopped?"; tip=0; fi
  ref=$(( tip > 10 ? tip - 10 : 0 ))
  printf '  %-13s %-11s %-9s %8s %6s  %s\n' NODE CLIENT ROLE BLOCK PEERS "HASH@$ref"
  local id cl role port h pc hash first="" bad=0
  while read -r id cl role port; do
    h=$(head_of "$port")
    if [ "$h" -lt 0 ]; then printf '  %-13s %-11s %-9s %8s\n' "$id" "$cl" "$role" "DOWN"; continue; fi
    pc=$(rpc "$port" net_peerCount); pc=$(( ${pc:-0} ))
    hash=$(rpc "$port" eth_getBlockByNumber "[\"$(printf '0x%x' $ref)\",false]" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["hash"][:14])
except Exception: print("-")')
    [ -z "$first" ] && [ "$hash" != - ] && first=$hash
    [ "$hash" != - ] && [ "$hash" != "$first" ] && bad=1
    printf '  %-13s %-11s %-9s %8d %6d  %s\n' "$id" "$cl" "$role" "$h" "$pc" "$hash"
  done < <(nodes_tsv)
  [ "$bad" = 0 ] && ok "all running nodes agree on block $ref (no fork)" || warn "nodes DISAGREE on block $ref (fork!)"
  echo "  RAM free: $(mem_avail_mb) MB"
}

stop_net() {
  load_env
  step "Stopping network $NAME (data is kept)"
  netlab/fleet.sh down "$TOPO" 2>&1 | tail -3
}

# ---------- Tailscale (private link between laptops on different networks) ----
setup_tailscale() {
  step "Tailscale"
  [ "$(uname -s)" = Linux ] || die "run this inside Linux / WSL Ubuntu"
  command -v curl >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq curl >/dev/null; }
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "  installing Tailscale (may ask for your sudo password) ..."
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null || die "Tailscale install failed (check internet)"
  fi
  ok "Tailscale installed ($(tailscale version 2>/dev/null | head -1))"
  if ! pgrep -x tailscaled >/dev/null; then
    if [ "$(ps -p 1 -o comm= 2>/dev/null)" = systemd ]; then
      sudo systemctl enable --now tailscaled >/dev/null 2>&1
    else   # WSL without systemd: run the daemon by hand
      sudo mkdir -p /var/lib/tailscale
      sudo sh -c 'nohup tailscaled --state=/var/lib/tailscale/tailscaled.state > /var/log/tailscaled.log 2>&1 &'
    fi
    sleep 3
  fi
  pgrep -x tailscaled >/dev/null || die "tailscaled (the Tailscale service) is not running"
  if [ -z "$(tailscale ip -4 2>/dev/null)" ]; then
    echo
    echo "  ${B}A login link will appear below. Open it in your browser and log in.${N}"
    echo "  ${B}Use the SAME Tailscale account on both laptops.${N}"
    echo
    sudo tailscale up || die "tailscale login did not finish"
  fi
  local ip; ip=$(tailscale ip -4 2>/dev/null | head -1)
  [ -n "$ip" ] || die "Tailscale has no IP yet -- run '$0 tailscale' again"
  ok "this laptop's Tailscale address: ${B}$ip${N}  (name: $(hostname))"
}

# address other laptops should use to reach this one
public_ip() {
  local ip; ip=$(tailscale ip -4 2>/dev/null | head -1)
  [ -n "$ip" ] && { echo "$ip"; return; }
  ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

connect_info() {
  load_env
  step "Writing connection info for chain $CHAIN_ID"
  local ip; ip=$(tailscale ip -4 2>/dev/null | head -1)
  if [ -z "$ip" ]; then
    warn "Tailscale is not set up on this laptop -- run '$0 tailscale' first if the reth laptop is on a different network"
    ip=$(public_ip)
  fi
  local out="$WORKDIR/connect-$CHAIN_ID.json" enodes="" id cl role port e
  while read -r id cl role port; do
    [ "$role" = sealer ] || continue
    e=$(rpc "$port" admin_nodeInfo | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["enode"].split("?")[0])
except Exception: pass')
    [ -n "$e" ] && enodes="$enodes $e"
  done < <(nodes_tsv)
  [ -n "$enodes" ] || die "no sealer is answering -- is the network running? ('$0 status')"
  python3 - "$out" "$CHAIN_ID" "$ip" "$RUN/genesis.json" $enodes <<'PY' || die "could not write $out"
import json, re, sys
out, chain, ip, gen, enodes = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5:]
# replace each enode's host with the address the OTHER laptop can reach (keep key + port)
enodes = [re.sub(r"@[^:]+:", "@%s:" % ip, e) for e in enodes]
json.dump({"chainId": chain, "enodes": enodes, "genesis": json.load(open(gen))}, open(out, "w"))
print("\n".join("  " + e[:40] + "..." + e[-22:] for e in enodes))
PY
  ok "wrote ${B}$out${N}"
  if grep -qi microsoft /proc/version 2>/dev/null; then
    local win; win=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')
    if [ -n "$win" ]; then
      local wdesk; wdesk="$(wslpath "$win" 2>/dev/null)/Desktop"
      [ -d "$wdesk" ] && cp "$out" "$wdesk/" && ok "also copied to your Windows Desktop: connect-$CHAIN_ID.json"
    fi
  fi
  echo
  echo "  Next: send connect-$CHAIN_ID.json to the reth laptop (Tailscale 'Send file', WhatsApp, email, Drive...)"
  echo "        then on that laptop run:   ./xdc-net.sh join-reth connect-$CHAIN_ID.json"
}

# ---------- reth on a second laptop --------------------------------------------
RETH_PORT="${RETH_PORT:-36500}"          # p2p; rpc = +1, ws = +2, authrpc = +3

reth_dir() {
  [ -n "${RETH_DIR:-}" ] && { echo "$RETH_DIR"; return; }
  # no CHAIN_ID given and exactly one reth setup on this laptop -> use that one
  if [ -z "${CHAIN_ID_SET:-}" ] && [ ! -d "$HOME/xdc-reth-$CHAIN_ID" ]; then
    local found=("$HOME"/xdc-reth-*/)
    [ ${#found[@]} -eq 1 ] && [ -d "${found[0]}" ] && { CHAIN_ID=$(basename "${found[0]}"); CHAIN_ID=${CHAIN_ID#xdc-reth-}; }
  fi
  echo "$HOME/xdc-reth-$CHAIN_ID"
}

join_reth() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || die "usage: $0 join-reth <connect-XXXXX.json>  (file from '$0 connect-info' on the network laptop)"
  file=$(readlink -f "$file")
  CHAIN_ID=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["chainId"])' "$file") || die "$file is not a valid connect file"
  CHAIN_ID_SET=1
  local dir; dir=$(reth_dir)
  local enodes; enodes=$(python3 -c 'import json,sys;print(",".join(json.load(open(sys.argv[1]))["enodes"]))' "$file")

  step "reth joining chain $CHAIN_ID"
  [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || die "needs Linux x86_64 (Ubuntu / WSL Ubuntu)"
  local need=() t
  for t in git curl python3; do command -v "$t" >/dev/null 2>&1 || need+=("$t"); done
  [ ${#need[@]} -gt 0 ] && { sudo apt-get update -qq && sudo apt-get install -y -qq "${need[@]}" >/dev/null || die "apt-get install ${need[*]} failed"; }
  local mem; mem=$(mem_avail_mb)
  if [ "$mem" -lt 3500 ]; then
    [ "${FORCE:-0}" = 1 ] || die "reth needs ~3 GB RAM; only ${mem} MB free. Stop other networks first. (FORCE=1 to try anyway)"
    warn "only ${mem} MB RAM free -- continuing because FORCE=1"
  else ok "RAM free: ${mem} MB"; fi

  if [ -f "$dir/reth.pid" ] && kill -0 "$(cat "$dir/reth.pid")" 2>/dev/null; then
    warn "reth is already running for chain $CHAIN_ID"; reth_status; return 0
  fi

  # can we reach the sealers? (needs Tailscale up on both laptops)
  local reach=0 e hp
  for e in ${enodes//,/ }; do
    hp=${e##*@}
    if timeout 5 bash -c "</dev/tcp/${hp%:*}/${hp##*:}" 2>/dev/null; then reach=$((reach+1)); fi
  done
  [ "$reach" -gt 0 ] || die "cannot reach any sealer at ${hp%:*}. Check: Tailscale is up on BOTH laptops ('$0 tailscale', same account) and the network is running there ('$0 status')."
  ok "can reach $reach of $(tr ',' '\n' <<<"$enodes" | wc -l) sealers"

  if [ ! -d "$dir/.git" ]; then
    git clone -q "$REPO_URL" "$dir" || die "git clone failed"
    git -C "$dir" checkout -q "$REPO_COMMIT" 2>/dev/null || warn "commit $REPO_COMMIT not found, using latest"
  fi
  ok "repo in $dir"
  python3 -c 'import json,sys;json.dump(json.load(open(sys.argv[1]))["genesis"],open(sys.argv[2],"w"),indent=1)' "$file" "$dir/genesis-$CHAIN_ID.json"
  mkdir -p "$dir/logs"

  echo "  - downloading reth (one time, ~80 MB) ..."
  if ( set +u; cd "$dir" && CLIENT=reth && . ./lib.sh && download_bins ) > "$dir/logs/download-reth.log" 2>&1; then ok "reth ready"
  else warn "reth pre-download failed (will retry on start). Log: $dir/logs/download-reth.log"; fi

  local es=(); [ "$ETHSTATS" = off ] && es=(--no-ethstats)
  nohup "$dir/join.sh" --genesis "$dir/genesis-$CHAIN_ID.json" --client reth --datadir "$dir/data" \
    --chainid "$CHAIN_ID" --port "$RETH_PORT" --rpcport $((RETH_PORT+1)) --wsport $((RETH_PORT+2)) \
    --authrpc-port $((RETH_PORT+3)) --bootnodes "$enodes" --name "net$CHAIN_ID-reth-remote" "${es[@]}" \
    > "$dir/logs/reth.log" 2>&1 < /dev/null &
  echo $! > "$dir/reth.pid"
  ok "reth started (log: $dir/logs/reth.log)"

  echo "  - waiting for reth to connect and sync (up to $SYNC_WAIT_MIN min) ..."
  local t0=$SECONDS h=-1 prev=-1 pc=0 grow=0
  while [ $((SECONDS - t0)) -lt $((SYNC_WAIT_MIN * 60)) ]; do
    sleep 15
    kill -0 "$(cat "$dir/reth.pid")" 2>/dev/null || { tail -15 "$dir/logs/reth.log" | cut -c1-160; die "reth exited (log: $dir/logs/reth.log)"; }
    [ "$(mem_avail_mb)" -lt 250 ] && { reth_stop; die "RAM almost full -- reth stopped to protect this laptop"; }
    h=$(head_of $((RETH_PORT+1))); pc=$(rpc $((RETH_PORT+1)) net_peerCount); pc=$(( ${pc:-0} ))
    printf '    %4ds  block=%s peers=%s\n' $((SECONDS - t0)) "$h" "$pc"
    if [ "$h" -gt 0 ] && [ "$h" -gt "$prev" ] && [ "$pc" -gt 0 ]; then grow=$((grow+1)); else grow=0; fi
    prev=$h
    [ "$grow" -ge 4 ] && break        # head kept rising for ~1 minute with peers -> following the chain
  done
  if [ "$grow" -ge 4 ]; then
    ok "reth is connected ($pc peers) and following the chain at block $h"
    echo "  Compare with the network laptop: '$0 status' there should show about the same block."
  else
    warn "reth did not start following the chain within $SYNC_WAIT_MIN min (block=$h peers=$pc). Last log lines:"
    tail -10 "$dir/logs/reth.log" | cut -c1-160 | sed 's/^/          /'
  fi
}

reth_status() {
  local dir; dir=$(reth_dir)
  [ -f "$dir/reth.pid" ] || die "no reth set up in $dir (run '$0 join-reth <file>' first)"
  step "reth ($dir)"
  if kill -0 "$(cat "$dir/reth.pid")" 2>/dev/null; then
    local pc; pc=$(rpc $((RETH_PORT+1)) net_peerCount)
    ok "running: block $(head_of $((RETH_PORT+1))), peers $(( ${pc:-0} ))"
  else warn "reth is not running"; fi
  echo "  RAM free: $(mem_avail_mb) MB    log: $dir/logs/reth.log"
}

reth_stop() {
  local dir i; dir=$(reth_dir)
  step "Stopping reth ($dir)"
  for i in $(seq 1 10); do          # polite stop only (SIGTERM), never kill -9
    pgrep -f "$dir/data" >/dev/null || { ok "reth stopped"; return 0; }
    pkill -TERM -f "$dir/data" 2>/dev/null; sleep 3
  done
  warn "reth still running after 10 stop signals -- check: pgrep -af '$dir/data'"
}

case "${1:-}" in
  start)        start_net ;;
  status)       show_status ;;
  stop)         stop_net ;;
  check)        check_machine; prepare_repo; step "Check finished -- nothing was started. Run: $0 start" ;;
  tailscale)    setup_tailscale ;;
  connect-info) connect_info ;;
  join-reth)    join_reth "${2:-}" ;;
  reth-status)  reth_status ;;
  reth-stop)    reth_stop ;;
  *) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
