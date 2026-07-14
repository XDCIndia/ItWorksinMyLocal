#!/bin/bash
# Shared helpers, sourced by the other scripts. Keeps everything OS-agnostic
# (macOS / Linux) by resolving platform-specific binaries and network info.

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Platform key, e.g. Darwin-arm64, Linux-x86_64, Linux-aarch64
PLATFORM="$(uname -s)-$(uname -m)"
BIN_DIR="$_LIB_DIR/bin/$PLATFORM"
XDC_BIN="$BIN_DIR/XDC"
BOOTNODE_BIN="$BIN_DIR/bootnode"
PUPPETH_BIN="$BIN_DIR/puppeth"

# XDPoSChain source used to build binaries when none are bundled for this
# platform. Defaults to a sibling checkout; override with XDPOS_DIR=/path.
XDPOS_DIR="${XDPOS_DIR:-$_LIB_DIR/../XDPoSChain}"

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

# Ensure XDC/bootnode/puppeth exist for this platform; build from source if not.
ensure_bins() {
  if [ -x "$XDC_BIN" ] && [ -x "$BOOTNODE_BIN" ] && [ -x "$PUPPETH_BIN" ] && [ "$REBUILD" != "1" ]; then
    return 0
  fi
  if [ ! -d "$XDPOS_DIR" ]; then
    echo "No prebuilt binaries for $PLATFORM and XDPoSChain source not found." >&2
    echo "Clone it next to this repo, or set XDPOS_DIR, e.g.:" >&2
    echo "    git clone https://github.com/XinFinOrg/XDPoSChain ../XDPoSChain" >&2
    echo "    XDPOS_DIR=/path/to/XDPoSChain ./setup.sh" >&2
    exit 1
  fi
  patch_puppeth   # fix the genesis-storage bug before building puppeth
  echo "Building XDC/bootnode/puppeth for $PLATFORM from $XDPOS_DIR ..."
  ( cd "$XDPOS_DIR" && make XDC && make bootnode && make puppeth ) || {
    echo "Build failed. Ensure Go and a C compiler (build-essential) are installed." >&2
    exit 1
  }
  mkdir -p "$BIN_DIR"
  cp "$XDPOS_DIR/build/bin/XDC" "$XDPOS_DIR/build/bin/bootnode" "$XDPOS_DIR/build/bin/puppeth" "$BIN_DIR/"
  echo "Binaries ready in $BIN_DIR"
}
