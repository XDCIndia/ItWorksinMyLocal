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
  echo "Building XDC/bootnode/puppeth for $PLATFORM from $XDPOS_DIR ..."
  ( cd "$XDPOS_DIR" && make XDC && make bootnode && make puppeth ) || {
    echo "Build failed. Ensure Go and a C compiler (build-essential) are installed." >&2
    exit 1
  }
  mkdir -p "$BIN_DIR"
  cp "$XDPOS_DIR/build/bin/XDC" "$XDPOS_DIR/build/bin/bootnode" "$XDPOS_DIR/build/bin/puppeth" "$BIN_DIR/"
  echo "Binaries ready in $BIN_DIR"
}
