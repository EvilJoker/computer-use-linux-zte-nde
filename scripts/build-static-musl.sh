#!/usr/bin/env bash
# Build computer-use-linux static-musl variant inside the dsh-builder:cargo-ready
# (or any Ubuntu 24.04+ with rustup + musl target + musl-tools + libssl-dev) container.
#
# Usage:
#   scripts/build-static-musl.sh [--variant=NAME] [--out-dir=DIR] [--target-dir=DIR] [--jobs=N]
#
# Defaults (mirrors upstream's release-binary job in .github/workflows/ci.yml):
#   --variant=computer-use-linux   →  asset: computer-use-linux-x86_64-unknown-linux-musl
#   --out-dir=./release/_staging   →  staging dir for the variant binary + sha256
#   --target-dir=./release/_target →  cargo --target-dir (isolated, ~1.7 GB)
#   --jobs=$(nproc)
#
# Does NOT push, NOT tag, NOT modify git state.  Pure build + stage.

set -euo pipefail

ASSET_BASE="computer-use-linux"   # full leading name component (caller controls; e.g. computer-use-linux-static-claude-nde)
OUT_DIR="./release/_staging"
TARGET_DIR="./release/_target"
JOBS="$(nproc)"

for arg in "$@"; do
  case "$arg" in
    --asset-base=*) ASSET_BASE="${arg#*=}" ;;
    --out-dir=*)   OUT_DIR="${arg#*=}"  ;;
    --target-dir=*) TARGET_DIR="${arg#*=}";;
    --jobs=*)      JOBS="${arg#*=}"     ;;
    -h|--help)
      sed -n '2,21p' "$0"
      exit 0
      ;;
    *)
      echo "build-static-musl: unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

ASSET="${ASSET_BASE}-x86_64-unknown-linux-musl"

echo "=========================================="
echo "[build-static-musl] asset-base=$ASSET_BASE"
echo "[build-static-musl] asset=$ASSET"
echo "[build-static-musl] out-dir=$OUT_DIR"
echo "[build-static-musl] target-dir=$TARGET_DIR"
echo "[build-static-musl] jobs=$JOBS"
echo "=========================================="

# Toolchain sanity (this script must run inside an environment that already
# provides rustup + x86_64-unknown-linux-musl + musl-tools + libssl-dev).
command -v rustc >/dev/null   || { echo "rustc not found; install rustup + stable toolchain" >&2; exit 3; }
command -v musl-gcc >/dev/null || { echo "musl-gcc not found; install musl-tools"   >&2; exit 3; }
command -v pkg-config >/dev/null || true
rustup target list --installed | grep -qx "x86_64-unknown-linux-musl" \
  || { echo "x86_64-unknown-linux-musl target missing; run: rustup target add x86_64-unknown-linux-musl" >&2; exit 3; }

export CC_x86_64_unknown_linux_musl=musl-gcc
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc

mkdir -p "$OUT_DIR" "$TARGET_DIR"

echo "[1/4] cargo build --release --target x86_64-unknown-linux-musl"
cargo build --release --target x86_64-unknown-linux-musl \
  --target-dir "$TARGET_DIR" \
  --jobs "$JOBS"

SRC_BIN="$TARGET_DIR/x86_64-unknown-linux-musl/release/computer-use-linux"
DST_BIN="$OUT_DIR/$ASSET"
echo "[2/4] stage $SRC_BIN -> $DST_BIN"
cp -v "$SRC_BIN" "$DST_BIN"

echo "[3/4] sha256sum"
( cd "$OUT_DIR" && sha256sum "$ASSET" > "$ASSET.sha256" )
cat "$OUT_DIR/$ASSET.sha256"

echo "[4/4] verify with ldd + file"
file "$DST_BIN"
ldd "$DST_BIN" 2>&1 | sed 's/^/  /'
"$DST_BIN" --help >/dev/null && echo "  --help: OK"

echo
echo "=========================================="
echo "STAGED: $DST_BIN"
echo "=========================================="