#!/usr/bin/env bash
# Container-side build script for a musl-static computer-use-linux binary.
# Run inside dsh-builder:ubuntu24 with /src mounted from host.
set -euo pipefail
cd /src

# rustup + stable toolchain（如果还没装）
if ! command -v rustc >/dev/null 2>&1; then
  echo "[1/5] installing rustup ..."
  curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
  source "$HOME/.cargo/env"
fi

# musl target（rust 标准库 musl 后端）
rustc --version
echo "[2/5] ensuring target x86_64-unknown-linux-musl ..."
rustup target add x86_64-unknown-linux-musl

# 系统包：musl C 库头（让任何链接到 C 的 crate 也能编译）+ pkg-config + 一些 zbus 间接依赖
echo "[3/5] installing system deps ..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  musl-tools pkg-config libssl-dev 2>&1 | tail -5 || true

# 在 build 期间告诉 Rust 用 musl-gcc 来链
export CC_x86_64_unknown_linux_musl=musl-gcc
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc

echo "[4/5] cargo build --release --target x86_64-unknown-linux-musl ..."
cargo build --release --target x86_64-unknown-linux-musl \
  --target-dir /out/target \
  --jobs "$(nproc)" 2>&1 | tail -40

# 复制产物到固定位置（docker run --volume 之后会被外面 cp 走）
echo "[5/5] artifacts:"
ls -la /out/target/x86_64-unknown-linux-musl/release/computer-use-linux /out/target/x86_64-unknown-linux-musl/release/computer-use-linux-cosmic 2>&1
# 也放到 /out/bin/ 方便卷复制
mkdir -p /out/bin
cp -v /out/target/x86_64-unknown-linux-musl/release/computer-use-linux /out/bin/
cp -v /out/target/x86_64-unknown-linux-musl/release/computer-use-linux-cosmic /out/bin/ 2>/dev/null || true
echo "DONE"