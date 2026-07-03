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

# Official SHA-256 checksums from https://ziglang.org/download/index.json. The download is
# verified against these before anything is extracted or executed — bumping ZIG_VERSION
# requires adding its checksums here, and an unknown version fails closed.
case "${ZIG_VERSION}-${za}" in
  0.16.0-x86_64) expected_sha256="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" ;;
  0.16.0-aarch64) expected_sha256="ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17" ;;
  *)
    echo "no pinned SHA-256 for Zig ${ZIG_VERSION} on ${za}; add it from ziglang.org/download/index.json" >&2
    exit 1
    ;;
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
    echo "${expected_sha256}  zig.tar.xz" | sha256sum -c -
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
