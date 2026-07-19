#!/bin/bash
# Shared helpers, sourced by the other scripts. Keeps everything OS-agnostic
# (macOS / Linux) by resolving platform-specific binaries and network info.

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Platform key, e.g. Darwin-arm64, Linux-x86_64, Linux-aarch64
PLATFORM="$(uname -s)-$(uname -m)"

# Which client to build/run:
#   oldxdc  (default) -> XDPoSChain fork (binary: XDC + bootnode + puppeth)
#   geth              -> modern go-ethereum fork (binary: geth)
#   erigon            -> erigon fork (binary: erigon) -- joins built-in XDC
#                        chains via --chain, not a custom genesis file
CLIENT="${CLIENT:-oldxdc}"
case "$CLIENT" in
  oldxdc|xdc|XDC)
    CLIENT=oldxdc
    XDPOS_REPO="${XDPOS_REPO:-https://github.com/XDCIndia/OLDXDC}"
    XDPOS_DIR="${XDPOS_DIR:-$_LIB_DIR/../XDPoSChain}"
    CLIENT_TARGETS="XDC bootnode puppeth"
    NODE_NAME_BIN="XDC"
    ;;
  geth|modern|gp5)
    CLIENT=geth
    XDPOS_REPO="${XDPOS_REPO:-https://github.com/XDCIndia/go-ethereum}"
    XDPOS_DIR="${XDPOS_DIR:-$_LIB_DIR/../go-ethereum}"
    CLIENT_TARGETS="geth"
    NODE_NAME_BIN="geth"
    ;;
  erigon)
    CLIENT=erigon
    XDPOS_REPO="${XDPOS_REPO:-https://github.com/XDCIndia/erigon-xdc}"
    XDPOS_DIR="${XDPOS_DIR:-$_LIB_DIR/../erigon-xdc}"
    CLIENT_TARGETS="erigon"
    NODE_NAME_BIN="erigon"
    ;;
  besu)
    # Prebuilt (Java): located by join.sh via BESU_BIN / PATH, not built here.
    CLIENT=besu
    XDPOS_REPO="${XDPOS_REPO:-https://github.com/XDCIndia/besu-xdc}"
    XDPOS_DIR="${XDPOS_DIR:-$_LIB_DIR/../besu-xdc}"
    CLIENT_TARGETS=""
    NODE_NAME_BIN="besu"
    ;;
  nethermind)
    # Prebuilt (.NET): located by join.sh via NETHERMIND_DIST / PATH, not built here.
    CLIENT=nethermind
    XDPOS_REPO="${XDPOS_REPO:-https://github.com/XDCIndia/nethermind}"
    XDPOS_DIR="${XDPOS_DIR:-$_LIB_DIR/../nethermind}"
    CLIENT_TARGETS=""
    NODE_NAME_BIN="nethermind"
    ;;
  reth)
    # Prebuilt (Rust): located by join.sh via RETH_BIN / PATH, not built here.
    CLIENT=reth
    XDPOS_REPO="${XDPOS_REPO:-https://github.com/XDCIndia/reth-xdc}"
    XDPOS_DIR="${XDPOS_DIR:-$_LIB_DIR/../reth-xdc}"
    CLIENT_TARGETS=""
    NODE_NAME_BIN="xdc-reth"
    ;;
  *)
    echo "unknown CLIENT '$CLIENT' (use: oldxdc | geth | erigon | besu | nethermind | reth)" >&2; exit 1;;
esac

# Binaries live under a per-client, per-platform dir so the clients coexist.
BIN_DIR="$_LIB_DIR/bin/$CLIENT/$PLATFORM"
NODE_BIN="$BIN_DIR/$NODE_NAME_BIN"   # the node binary (XDC / geth / erigon)
# shellcheck disable=SC2034  # XDC_BIN/BOOTNODE_BIN/PUPPETH_BIN are used by scripts that `source ./lib.sh`
XDC_BIN="$NODE_BIN"                  # back-compat alias used by the scripts
# shellcheck disable=SC2034  # used by scripts that `source ./lib.sh` (e.g. join.sh)
BOOTNODE_BIN="$BIN_DIR/bootnode"     # only exists for the oldxdc client
# shellcheck disable=SC2034  # used by scripts that `source ./lib.sh` (e.g. gen-genesis.sh)
PUPPETH_BIN="$BIN_DIR/puppeth"       # only exists for the oldxdc client

# Best-effort LAN IP on macOS or Linux (falls back to 127.0.0.1).
detect_ip() {
  local ip=""
  if command -v ipconfig >/dev/null 2>&1; then
    ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
  fi
  [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -z "$ip" ] && command -v ip >/dev/null 2>&1 && \
    ip=$(ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [ -z "$ip" ] && ip=127.0.0.1
  echo "$ip"
}

# Apply the puppeth genesis-storage fix to the XDPoSChain source (idempotent).
# Upstream's cmd/puppeth/wizard_genesis.go re-RLP-decodes each storage word,
# truncating masternode addresses in the 0x88 validator contract and stalling
# the chain at the first epoch. We store the word verbatim instead.
patch_puppeth() {
  local f="$XDPOS_DIR/cmd/puppeth/wizard_genesis.go"
  [ -f "$f" ] || return 0
  python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
if 'rlp.DecodeBytes' not in s:
    sys.exit(0)  # already patched (or upstream changed shape)
s2 = re.sub(
    r'\n[ \t]*decode := \[\]byte\{\}\n.*?log\.Info\("DecodeBytes".*?\)\n',
    '\n\t\t\tstorage[key] = val\n',
    s, count=1, flags=re.DOTALL)
s2 = re.sub(r'\n[ \t]*"github\.com/XinFinOrg/XDPoSChain/rlp"', '', s2, count=1)
if 'rlp.DecodeBytes' in s2:
    sys.stderr.write(
      "WARNING: could not apply the puppeth genesis fix automatically.\n"
      "         Your XDPoSChain source differs from the expected version.\n"
      "         Pin it first:  (cd \"$XDPOS_DIR\" && git checkout 68b00c7e5)\n")
    sys.exit(1)
open(p, 'w').write(s2)
sys.stderr.write("Applied puppeth genesis-storage fix to wizard_genesis.go\n")
PY
}

# Verify the build toolchain is present before attempting a source build.
check_toolchain() {
  local missing=""
  command -v git >/dev/null 2>&1 || missing="$missing git"
  command -v make >/dev/null 2>&1 || missing="$missing make"
  command -v go >/dev/null 2>&1 || missing="$missing go(golang)"
  { command -v gcc >/dev/null 2>&1 || command -v cc >/dev/null 2>&1; } || missing="$missing gcc"
  if [ -z "$missing" ]; then
    # Go must be >= 1.23 (go.mod). Distro packages are often older.
    local gv maj min
    gv=$(go version 2>/dev/null | grep -oE 'go[0-9]+\.[0-9]+' | head -1 | sed 's/go//')
    maj=${gv%%.*}; min=${gv#*.}
    if [ -n "$gv" ] && { [ "${maj:-0}" -lt 1 ] || { [ "$maj" -eq 1 ] && [ "${min:-0}" -lt 23 ]; }; }; then
      echo "Go $gv is too old to build (need >= 1.23)." >&2
      echo "Ubuntu's 'golang' package is often too old -- install a current Go:" >&2
      echo "  wget https://go.dev/dl/go1.23.4.linux-amd64.tar.gz" >&2
      echo "  sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.23.4.linux-amd64.tar.gz" >&2
      echo "  export PATH=\$PATH:/usr/local/go/bin   # add to ~/.profile" >&2
      exit 1
    fi
    return 0
  fi
  echo "Missing build tools:$missing" >&2
  echo "Install them once, then re-run:" >&2
  echo "  Ubuntu/Debian: sudo apt update && sudo apt install -y build-essential git   (+ Go >=1.23, see below)" >&2
  echo "  Fedora/RHEL:   sudo dnf install -y @development-tools git" >&2
  echo "  macOS:         xcode-select --install && brew install go" >&2
  echo "  Go >= 1.23:    https://go.dev/dl  (distro 'golang' packages are often too old)" >&2
  exit 1
}

# Ensure this client's binaries exist for this platform; build from source if not.
ensure_bins() {
  local t ready=1
  for t in $CLIENT_TARGETS; do [ -x "$BIN_DIR/$t" ] || ready=0; done
  [ "$ready" = 1 ] && [ "$REBUILD" != "1" ] && return 0

  check_toolchain   # need git + make + go + gcc to build from source

  if [ ! -d "$XDPOS_DIR" ]; then
    echo "No $CLIENT binaries for $PLATFORM yet; cloning source from $XDPOS_REPO ..."
    if ! git clone --depth 1 "$XDPOS_REPO" "$XDPOS_DIR"; then
      echo "Could not clone $XDPOS_REPO (private repo needs access?)." >&2
      echo "Clone the source manually, then re-run:" >&2
      echo "    git clone $XDPOS_REPO $XDPOS_DIR" >&2
      [ "$CLIENT" = oldxdc ] && echo "  or upstream pinned:  git clone https://github.com/XinFinOrg/XDPoSChain $XDPOS_DIR && (cd $XDPOS_DIR && git checkout 68b00c7e5)" >&2
      exit 1
    fi
  fi

  [ "$CLIENT" = oldxdc ] && patch_puppeth   # fix the genesis-storage bug first

  # build/ci.go reads the GOPATH env var directly and fails if it's unset,
  # even though modern Go defaults it. Set it for the build.
  if [ -z "$GOPATH" ]; then GOPATH="$(go env GOPATH 2>/dev/null)"; export GOPATH; fi
  [ -z "$GOPATH" ] && export GOPATH="$HOME/go"
  mkdir -p "$GOPATH"

  echo "Building [$CLIENT_TARGETS] for $CLIENT/$PLATFORM from $XDPOS_DIR (GOPATH=$GOPATH) ..."
  ( cd "$XDPOS_DIR" && for t in $CLIENT_TARGETS; do make "$t" || exit 1; done ) || {
    echo "Build failed. Ensure Go and a C compiler (build-essential) are installed." >&2
    exit 1
  }
  mkdir -p "$BIN_DIR"
  for t in $CLIENT_TARGETS; do
    cp "$XDPOS_DIR/build/bin/$t" "$BIN_DIR/"
    # macOS: cp invalidates the binary's ad-hoc code signature, so Gatekeeper
    # SIGKILLs the copy on exec. Re-sign it ad-hoc so it runs.
    if [ "$(uname -s)" = Darwin ] && command -v codesign >/dev/null 2>&1; then
      codesign -f -s - "$BIN_DIR/$t" >/dev/null 2>&1 || true
    fi
  done
  echo "$CLIENT binaries ready in $BIN_DIR"
}

# Harvest live peer enodes from a network by running a short-lived DISCOVERING
# client (oldxdc/geth) against a bootnode, then reading its admin_peers. This is
# how erigon gets its --staticpeers automatically from just an --ip: erigon's
# discv4 doesn't discover through an XDPoSChain bootnode, but oldxdc/geth do
# (exactly what geth does when it joins), so we borrow their discovery.
#   $1 genesis file   $2 bootnode enode   $3 networkid
# Prints a comma-separated enode list on stdout ("" if none). Logs to stderr.
harvest_peers() {
  local genesis="$1" bootnode="$2" nid="$3"
  local xdc="$_LIB_DIR/bin/oldxdc/$PLATFORM/XDC"
  [ -x "$xdc" ] || xdc="$_LIB_DIR/bin/geth/$PLATFORM/geth"
  [ -x "$xdc" ] || { echo "harvest: no oldxdc/geth binary to discover peers" >&2; return 1; }
  local dd rp=8799; dd=$(mktemp -d)
  "$xdc" --datadir "$dd" init "$genesis" >/dev/null 2>&1
  echo "Harvesting peers from bootnode via $(basename "$xdc") discovery ..." >&2
  "$xdc" --datadir "$dd" --networkid "$nid" --syncmode full --bootnodes "$bootnode" \
    --port 30399 --nat "extip:$(detect_ip)" --maxpeers 25 \
    --http --http.addr 127.0.0.1 --http.port "$rp" --http.api admin,net >/dev/null 2>&1 &
  local hpid=$! enodes=""
  for _ in $(seq 1 30); do
    enodes=$(curl -s -m3 "http://127.0.0.1:$rp" -X POST -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}' 2>/dev/null \
      | python3 -c "import sys,json
try: ps=json.load(sys.stdin).get('result',[]) or []
except Exception: ps=[]
out=['enode://%s@%s'%(p.get('id',''),(p.get('network') or {}).get('remoteAddress','')) for p in ps if p.get('id') and (p.get('network') or {}).get('remoteAddress')]
print(','.join(out))" 2>/dev/null)
    [ -n "$enodes" ] && break
    sleep 2
  done
  kill -9 "$hpid" 2>/dev/null
  rm -rf "$dd"
  echo "$enodes"
}

# The run/genesis/join scripts are wired for the oldxdc (XDPoSChain) client:
# separate bootnode binary, puppeth genesis, XDPoS-v1 flags. The modern geth
# fork uses a different run model (no bootnode binary, --http.* flags, its own
# genesis flow), so those scripts refuse to run against it for now.
require_oldxdc() {
  [ "$CLIENT" = oldxdc ] && return 0
  echo "'$CLIENT' client: this script isn't wired for it yet." >&2
  echo "The modern geth run/genesis profile is still TODO -- CLIENT=geth can" >&2
  echo "build the binary, but launching a local net needs its own flags." >&2
  echo "Use the default (oldxdc) to run a network: unset CLIENT" >&2
  exit 1
}
