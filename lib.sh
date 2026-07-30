#!/bin/bash
# Shared helpers, sourced by the other scripts. Keeps everything OS-agnostic
# (macOS / Linux) by resolving platform-specific binaries and network info.

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Platform key, e.g. Darwin-arm64, Linux-x86_64, Linux-aarch64
PLATFORM="$(uname -s)-$(uname -m)"

# Prebuilt-binary manifest (repo root); see download_bins() below.
BINARIES_JSON="$_LIB_DIR/binaries.json"

# Where each client's binary comes from, default "download" (fetch a prebuilt
# binary from binaries.json for this platform; falls back to a source build
# if unavailable). Set BIN_SOURCE=build to always build from source, or
# override a single client with BIN_SOURCE_<client>= (e.g. BIN_SOURCE_erigon=build).
BIN_SOURCE="${BIN_SOURCE:-download}"

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
  geth1175)
    # geth 1.17.5-xdc.8, opt-in alongside the default `geth` (1.17.4-xdc.7) so
    # existing users are not silently upgraded. Same repo and make target -- it is
    # geth, just a newer tag -- but a separate binaries.json key (`geth1175`) and its
    # own BIN_DIR, so the two coexist. See binaries.json's geth1175 entry for the
    # validation behind it (9-client parity, then gate-proven minting at 11.12%
    # against an 11.11% ideal on netv12).
    CLIENT=geth1175
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
  xone)
    # xone-native (XDCIndia/xOneGo): the go-ethereum-derived XDPoS client, the
    # reference mainnet-parity node. Prebuilt is downloaded (binaries.json xone);
    # a source build is the fallback when present. Uses single-dash flags.
    CLIENT=xone
    XDPOS_REPO="${XDPOS_REPO:-https://github.com/XDCIndia/xOneGo}"
    XDPOS_DIR="${XDPOS_DIR:-$_LIB_DIR/../xOneGo}"
    CLIENT_TARGETS="xone"
    NODE_NAME_BIN="xone"
    ;;
  all)
    # Meta-client: join.sh fans "all" out to one child process per real client
    # (each re-sources lib.sh with its own concrete client). The dispatcher itself
    # needs no per-client repo / binary setup, so accept it and set no targets.
    CLIENT=all
    CLIENT_TARGETS=""
    NODE_NAME_BIN=""
    ;;
  *)
    echo "unknown CLIENT '$CLIENT' (use: oldxdc | geth | geth1175 | erigon | besu | nethermind | reth | xone | all)" >&2; exit 1;;
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

# This platform's {os}-{arch} key as used in binaries.json -- distinct from
# $PLATFORM (which is "uname -s-uname -m" / used for BIN_DIR): lowercase os,
# and machine arch normalised to amd64/arm64.
platform_slug() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *)      os=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *)             arch=$(uname -m) ;;
  esac
  echo "${os}-${arch}"
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

# sha256 of a file, using whichever tool this host has (sha256sum is typical
# on Linux, shasum -a 256 on macOS; some hosts have both, either works).
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "no sha256sum/shasum found -- cannot verify downloads" >&2
    return 1
  fi
}

# Read binaries.json for $1=client/$2=platform-slug and print bash assignments
# to eval: _BJ_OK=1 (only when there's a manifest entry supporting this
# platform), _BJ_URL/_BJ_FILE/_BJ_ARCHIVE/_BJ_SHA256, plus one
# `_bj_produce NAME RELPATH` call per entry in that client's "produces" map.
_binjson_query() {
  local client="$1" slug="$2"
  python3 - "$BINARIES_JSON" "$client" "$slug" <<'PY'
import json, sys
path, client, slug = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    m = json.load(open(path))
except Exception:
    sys.exit(0)  # caller checks _BJ_OK; no valid manifest
c = (m.get("clients") or {}).get(client)
if not c:
    sys.exit(0)
platforms = c.get("platforms") or []
if slug not in platforms and "*" not in platforms:
    sys.exit(0)
os_, arch = slug.split("-", 1)
file = (c.get("file") or "").replace("{os}", os_).replace("{arch}", arch)
archive = c.get("archive", "none")
sha = (c.get("sha256") or {}).get(slug) or (c.get("sha256") or {}).get("*") or ""
# Per-client baseUrl override: almost every client is mirrored under the
# single global xdc.network baseUrl; a client entry may set its own "baseUrl"
# to pull from a different (public) mirror instead. Absent that, fall back to
# the global one.
base = (c.get("baseUrl") or m.get("baseUrl") or "").rstrip("/")
# ghRelease (ItWorksinMyLocal#114): an urgent fix can land as a release asset
# on a client's own (often PRIVATE) GitHub repo before it's mirrored to
# xdc.network -- e.g. xone's genesis-hash-parity build. {"repo":"owner/name",
# "tag":"vX"} tells download_bins() to fetch $file via `gh release download`
# (which carries the caller's own gh auth, unlike a plain curl URL) when the
# ordinary curl fetch fails. Both may be present; curl (against the possibly-
# stale xdc.network mirror) is always tried first, gh is the fallback.
gh = c.get("ghRelease") or {}

def q(s):
    return "'" + str(s).replace("'", "'\\''") + "'"

print("_BJ_OK=1")
print("_BJ_URL=" + q(base + "/" + file if base else ""))
print("_BJ_FILE=" + q(file))
print("_BJ_GH_REPO=" + q(gh.get("repo", "")))
print("_BJ_GH_TAG=" + q(gh.get("tag", "")))
print("_BJ_ARCHIVE=" + q(archive))
print("_BJ_SHA256=" + q(sha))
for k, v in (c.get("produces") or {}).items():
    print("_bj_produce " + q(k) + " " + q(v))
PY
}

# Download this $CLIENT's prebuilt binary for the current platform from
# binaries.json, verify its sha256 (mandatory -- refuses to proceed without a
# recorded hash, and deletes the file on mismatch), extract it if it's an
# archive, and place the resulting binary(ies) at $BIN_DIR/<name> (chmod +x,
# plus an ad-hoc macOS codesign so Gatekeeper doesn't SIGKILL it).
#
# Idempotent: a cached download that still matches its recorded sha256 is
# reused as-is; REBUILD=1 forces a fresh fetch. Returns 1 (after a clear
# message) if this client has no manifest entry, no prebuilt binary for this
# platform, or the download/verification fails -- callers should fall back to
# a source build.
#
# On success, sets DOWNLOADED_DIST to the extraction directory for archive
# clients whose "produces" path is "." (a whole-directory product, e.g.
# nethermind's dist, as opposed to a single extracted binary).
download_bins() {
  # shellcheck disable=SC2034  # DOWNLOADED_DIST is used by scripts that `source ./lib.sh` (e.g. join.sh)
  DOWNLOADED_DIST=""
  [ -f "$BINARIES_JSON" ] || { echo "binaries.json not found at $BINARIES_JSON" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 is required to read binaries.json" >&2; return 1; }
  command -v curl >/dev/null 2>&1 || { echo "curl is required to download prebuilt binaries" >&2; return 1; }

  local slug; slug=$(platform_slug)
  local _BJ_OK="" _BJ_URL="" _BJ_FILE="" _BJ_ARCHIVE="" _BJ_SHA256="" _BJ_GH_REPO="" _BJ_GH_TAG=""
  local _BJ_PRODUCE_NAMES=() _BJ_PRODUCE_PATHS=()
  _bj_produce() { _BJ_PRODUCE_NAMES+=("$1"); _BJ_PRODUCE_PATHS+=("$2"); }
  eval "$(_binjson_query "$CLIENT" "$slug")"

  if [ "$_BJ_OK" != 1 ]; then
    echo "binaries.json: no prebuilt $CLIENT binary for platform $slug" >&2
    return 1
  fi
  if [ -z "$_BJ_SHA256" ]; then
    echo "binaries.json: no sha256 recorded for $CLIENT/$slug -- refusing to trust an unverifiable download" >&2
    return 1
  fi

  mkdir -p "$BIN_DIR"
  local dl="$BIN_DIR/.download-$_BJ_FILE"

  if [ "$REBUILD" != "1" ] && [ -f "$dl" ] && [ "$(sha256_file "$dl" 2>/dev/null)" = "$_BJ_SHA256" ]; then
    echo "$CLIENT: cached download for $slug already verified ($_BJ_FILE)"
  else
    rm -f "$dl"
    local verified=""
    # --retry rides out transient failures; --speed-time/-limit aborts a truly
    # stalled connection (no bytes for 60s) instead of hanging forever; -C -
    # resumes a partial temp from a prior interrupted attempt.
    #
    # "verified" only becomes true once a fetched file's sha256 actually
    # matches -- a curl fetch can succeed (HTTP-wise) against a mirror that's
    # simply serving a STALE build (e.g. xdc.network hasn't caught up with an
    # urgent fix yet), which must NOT short-circuit the gh-release fallback
    # below (ItWorksinMyLocal#114 caught this: an earlier version of this
    # function treated "curl exited 0" as success and never tried gh at all).
    if [ -n "$_BJ_URL" ]; then
      echo "Downloading $CLIENT for $slug: $_BJ_URL"
      if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 \
              --speed-time 60 --speed-limit 1024 -C - -o "$dl" "$_BJ_URL"; then
        if [ "$(sha256_file "$dl" 2>/dev/null)" = "$_BJ_SHA256" ]; then
          verified=1
        else
          echo "  sha256 mismatch from $_BJ_URL (mirror may be stale)" >&2
          rm -f "$dl"
        fi
      fi
    fi
    # gh-release fallback (ItWorksinMyLocal#114): a client entry's "ghRelease"
    # names an asset on that client's own (possibly PRIVATE) GitHub repo --
    # curl against a plain URL 404s on a private repo even with a bearer
    # token (GitHub serves release assets via a signed redirect that needs
    # the gh CLI's own handling), so this shells out to `gh release download`
    # instead, which carries the caller's own `gh auth` session. Only
    # attempted if curl above didn't already produce a verified file, and
    # only if `gh` is on PATH -- silently unavailable (not a hard error) for
    # anyone without gh or without access to that private repo, since the
    # normal xdc.network mirror is still the primary, documented path.
    if [ -z "$verified" ] && [ -n "$_BJ_GH_REPO" ] && [ -n "$_BJ_GH_TAG" ] && command -v gh >/dev/null 2>&1; then
      echo "$CLIENT: no verified curl fetch; trying gh release download $_BJ_GH_TAG -R $_BJ_GH_REPO -p $_BJ_FILE" >&2
      rm -f "$dl"
      if gh release download "$_BJ_GH_TAG" -R "$_BJ_GH_REPO" -p "$_BJ_FILE" -O "$dl" --clobber 2>&1 \
         && [ "$(sha256_file "$dl" 2>/dev/null)" = "$_BJ_SHA256" ]; then
        verified=1
      else
        echo "  gh release download did not produce a file matching the recorded sha256" >&2
        rm -f "$dl"
      fi
    fi
    if [ -z "$verified" ]; then
      echo "download failed: no source produced a $_BJ_FILE matching the recorded sha256 for $CLIENT/$slug (tried${_BJ_URL:+ curl $_BJ_URL}${_BJ_GH_REPO:+, gh release $_BJ_GH_REPO@$_BJ_GH_TAG})" >&2
      rm -f "$dl"
      return 1
    fi
    local got; got=$(sha256_file "$dl")
    echo "  sha256 OK ($got)"
  fi

  local distdir="$BIN_DIR/.dist-$CLIENT"
  if [ "$_BJ_ARCHIVE" = tar.gz ]; then
    rm -rf "$distdir"; mkdir -p "$distdir"
    tar xzf "$dl" -C "$distdir" || { echo "extract failed: $dl" >&2; return 1; }
  fi

  local i name relpath src_path dest
  for (( i=0; i<${#_BJ_PRODUCE_NAMES[@]}; i++ )); do
    name="${_BJ_PRODUCE_NAMES[$i]}"; relpath="${_BJ_PRODUCE_PATHS[$i]}"
    if [ "$_BJ_ARCHIVE" = none ]; then
      src_path="$dl"
    elif [ -z "$relpath" ] || [ "$relpath" = "." ]; then
      # shellcheck disable=SC2034  # DOWNLOADED_DIST is used by scripts that `source ./lib.sh` (e.g. join.sh)
      DOWNLOADED_DIST="$distdir"   # whole-directory product; nothing to copy
      continue
    else
      src_path="$distdir/$relpath"
      # A launcher nested inside the extracted dist (e.g. besu's bin/besu) resolves
      # its own APP_HOME from its location and needs sibling dirs (lib/) alongside
      # it. Copying just the launcher out to $BIN_DIR orphans it from lib/, so it
      # dies with "Could not find or load main class". Install a thin wrapper at
      # $BIN_DIR/$name that execs the launcher in place instead, keeping join.sh's
      # "$BIN_DIR/<name>" entry point working while preserving lib/ resolution.
      case "$relpath" in
        */*)
          dest="$BIN_DIR/$name"
          abs_src="$(cd "$(dirname "$src_path")" && pwd)/$(basename "$src_path")"
          printf '#!/bin/sh\nexec "%s" "$@"\n' "$abs_src" > "$dest"
          chmod +x "$dest"
          continue ;;
      esac
    fi
    dest="$BIN_DIR/$name"
    cp -f "$src_path" "$dest" || { echo "could not place $name from $src_path" >&2; return 1; }
    chmod +x "$dest"
    # macOS: cp invalidates the binary's ad-hoc code signature, so Gatekeeper
    # SIGKILLs it on exec. Re-sign it ad-hoc so it runs (same as the build path).
    if [ "$(uname -s)" = Darwin ] && command -v codesign >/dev/null 2>&1; then
      codesign -f -s - "$dest" >/dev/null 2>&1 || true
    fi
  done

  echo "$CLIENT: prebuilt binary ready in $BIN_DIR (downloaded for $slug)"
  return 0
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

# Ensure this client's binaries exist for this platform: prefer downloading a
# prebuilt binary from binaries.json (BIN_SOURCE=download, the default);
# build from source if unavailable, unsupported on this platform, or
# BIN_SOURCE(_<client>)=build. REBUILD=1 always forces a source build.
ensure_bins() {
  local t ready=1
  for t in $CLIENT_TARGETS; do [ -x "$BIN_DIR/$t" ] || ready=0; done
  [ "$ready" = 1 ] && [ "$REBUILD" != "1" ] && return 0

  local src="$BIN_SOURCE"
  case "$CLIENT" in
    geth)   src="${BIN_SOURCE_geth:-$src}" ;;
    geth1175) src="${BIN_SOURCE_geth1175:-$src}" ;;
    erigon) src="${BIN_SOURCE_erigon:-$src}" ;;
    oldxdc) src="${BIN_SOURCE_oldxdc:-$src}" ;;
  esac
  [ "$REBUILD" = "1" ] && src=build

  if [ "$src" != build ]; then
    if download_bins; then
      echo "$CLIENT binaries ready in $BIN_DIR (downloaded)"
      return 0
    fi
    echo "$CLIENT: no usable prebuilt binary for $PLATFORM; falling back to a source build." >&2
  fi

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

# ---------------------------------------------------------------------------
# Safe process discovery for teardown (ItWorksinMyLocal#97).
#
# Shared by netlab/node.sh (`stop`/`wipe`/`status`) and netlab/fleet.sh
# (`down`/`wipe`'s post-teardown assertion). Both need the SAME answer to
# "is a real client process still holding this datadir, right now, no
# matter what a pidfile or a listening-port check believes?" -- so it lives
# here once rather than being reimplemented per caller.
#
# Two live incidents drove this:
#   - A node whose RPC never bound (mid-shutdown, wedged, or a bind
#     failure) is INVISIBLE to any resolution that only checks a listening
#     RPC port. On netv12, exactly this let a stale node3 survive a full
#     net wipe for ~40 minutes, still holding its XDCx LOCK -- so the real
#     node3's restart failed outright ("Can't create new DB error=...
#     resource temporarily unavailable"), and the net silently ran on 4 of
#     5 seated validators. Every fair-share number measured in that window
#     was meaningless.
#   - The obvious "just pgrep for the datadir path" fix is worse:
#     `pgrep -f <datadir path>` matches ANY process whose command line
#     contains that path as a plain string -- including the shell running
#     the teardown script itself, and any agent/tool/tmux shell whose own
#     command line happens to mention the same path. That footgun killed a
#     live session (exit 144) during this investigation. NEVER use it.
#
# The safe replacement requires BOTH a cmdline match AND that
# /proc/<pid>/exe actually resolves to a known client binary -- and always
# excludes our own pid and every ancestor pid (the calling shell, its
# parent script, an agent shell, tmux/ssh, ...), so it can never signal or
# report its own caller.
# ---------------------------------------------------------------------------

# client_exe_names <client>: prints (space-separated, possibly more than
# one) the realistic /proc/<pid>/exe basename(s) for a running instance of
# <client> -- what proc_pids_for_datadir below must match against. Most
# clients are one self-contained binary (exe basename == the client name);
# besu and nethermind are launched by their own JVM/.NET runtime, so the
# OS-level exe is actually java/dotnet, not "besu"/"nethermind" -- for
# those two, the cmdline-contains-this-datadir check (always a highly
# specific, per-node absolute path) is what actually disambiguates; the exe
# check there only rules out "some unrelated process whose args happen to
# mention the same path", which is already the point of requiring it.
client_exe_names() {
  case "$1" in
    oldxdc|xdc|XDC) echo "XDC" ;;
    geth)           echo "geth" ;;
    geth1175)       echo "geth" ;;
    erigon)         echo "erigon" ;;
    besu)           echo "besu java" ;;
    nethermind)     echo "nethermind dotnet" ;;
    reth)           echo "xdc-reth" ;;
    xone)           echo "xone" ;;
    bootnode)       echo "bootnode" ;;
    *)              echo "" ;;
  esac
}

# proc_pids_for_datadir <datadir_abspath> [exe_basename ...]: one live pid
# per line -- any process whose /proc/<pid>/cmdline contains
# datadir_abspath as a plain substring AND whose /proc/<pid>/exe resolves
# to one of the given exe basenames (if none given, the exe check is
# skipped -- not used by any caller today, kept only because it's the
# natural degenerate case). Always excludes our own pid and every ancestor
# pid, computed by walking /proc/<pid>/stat's ppid field up to 16 hops
# (far deeper than any realistic shell/script/agent nesting).
proc_pids_for_datadir() {
  local datadir="$1"; shift
  python3 - "$datadir" "$@" <<'PY'
import os
import sys

datadir = sys.argv[1]
exe_names = set(sys.argv[2:])

anc, p = set(), os.getpid()
for _ in range(16):
    anc.add(p)
    try:
        p = int(open('/proc/%d/stat' % p).read().rsplit(')', 1)[1].split()[1])
    except Exception:
        break
    if p <= 1:
        anc.add(p)
        break

for d in os.listdir('/proc'):
    if not d.isdigit() or int(d) in anc:
        continue
    try:
        cmd = open('/proc/%s/cmdline' % d, 'rb').read().replace(b'\0', b' ').decode(errors='replace')
        exe = os.path.realpath('/proc/%s/exe' % d)
    except Exception:
        continue
    if datadir in cmd and (not exe_names or os.path.basename(exe) in exe_names):
        print(d)
PY
}

# proc_pids_holding_lockfiles <datadir_abspath>: one "<pid> <lockfile>"
# pair per line -- a live process that currently has an open file
# descriptor on one of this datadir's embedded-DB LOCK files (found by
# walking the datadir, up to 4 levels deep, for files literally named
# `LOCK` -- covers XDCx/LOCK, chaindata/LOCK, geth/chaindata/LOCK,
# erigon/LOCK, rocksdb/LOCK, besu's database/LOCK, ...). This is the
# PROXIMATE cause of ItWorksinMyLocal#97's "Can't create new DB ...
# resource temporarily unavailable": a stale holder's flock on this exact
# file is what blocks a fresh node from starting, even if that holder's
# own /proc/<pid>/exe didn't happen to match a name proc_pids_for_datadir
# knows about (a renamed/newer client binary, say). Always excludes our
# own pid and every ancestor pid, same rule as proc_pids_for_datadir.
proc_pids_holding_lockfiles() {
  local datadir="$1"
  [ -d "$datadir" ] || return 0
  python3 - "$datadir" <<'PY'
import os
import sys

datadir = os.path.realpath(sys.argv[1])

locks = []
for root, dirs, files in os.walk(datadir):
    depth = root[len(datadir):].count(os.sep)
    if depth >= 4:
        dirs[:] = []
    if 'LOCK' in files:
        locks.append(os.path.join(root, 'LOCK'))
if not locks:
    sys.exit(0)
locks = set(os.path.realpath(p) for p in locks)

anc, p = set(), os.getpid()
for _ in range(16):
    anc.add(p)
    try:
        p = int(open('/proc/%d/stat' % p).read().rsplit(')', 1)[1].split()[1])
    except Exception:
        break
    if p <= 1:
        anc.add(p)
        break

for d in os.listdir('/proc'):
    if not d.isdigit() or int(d) in anc:
        continue
    fddir = '/proc/%s/fd' % d
    try:
        fds = os.listdir(fddir)
    except Exception:
        continue
    for fd in fds:
        try:
            target = os.path.realpath(os.path.join(fddir, fd))
        except Exception:
            continue
        if target in locks:
            print('%s %s' % (d, target))
            break
PY
}
