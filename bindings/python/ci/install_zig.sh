#!/usr/bin/env bash
# Install a pinned Zig 0.16 into /opt/zig inside a manylinux build container (used by
# cibuildwheel's `before-all` on Linux). macOS/Windows builds use the host Zig from setup-zig.
set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
DEST="/opt/zig"

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) za="x86_64" ;;
  aarch64|arm64) za="aarch64" ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac

mkdir -p "$DEST"
cd /tmp

# The release filename layout changed across Zig versions; try both known forms.
candidates=(
  "zig-${za}-linux-${ZIG_VERSION}"
  "zig-linux-${za}-${ZIG_VERSION}"
)

ok=0
for base in "${candidates[@]}"; do
  url="https://ziglang.org/download/${ZIG_VERSION}/${base}.tar.xz"
  echo "trying $url"
  if curl -fsSL "$url" -o zig.tar.xz; then
    tar -xJf zig.tar.xz
    cp -r "${base}/." "$DEST/"
    ok=1
    break
  fi
done

if [ "$ok" -ne 1 ]; then
  echo "failed to download Zig ${ZIG_VERSION}" >&2
  exit 1
fi

"$DEST/zig" version
