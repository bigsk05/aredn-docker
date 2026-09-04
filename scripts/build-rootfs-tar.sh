#!/bin/sh
# Extract the root filesystem from an AREDN ext4 rootfs image (.img.gz) into a
# .tar.gz, for the Dockerfile's `ADD rootfs-<arch>.tar.gz /` (docker auto-extracts).
#
# Equivalent to the hand-verified local procedure:
#   alpine + e2fsprogs' debugfs -R "rdump / /d" <img>  →  tar
# Here we use debugfs directly on the runner (no container). ext4 is
# little-endian, so an amd64 host can read images built for arm64/armv7.
#
# Usage: build-rootfs-tar.sh <rootfs.img.gz URL> <output .tar.gz path>
set -eu

URL="${1:?usage: build-rootfs-tar.sh <img.gz url> <out.tar.gz>}"
OUT_TAR="${2:?usage: build-rootfs-tar.sh <img.gz url> <out.tar.gz>}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "  download  $URL"
curl -fsSL --retry 3 --max-time 600 "$URL" | gzip -dc > "$TMP/rootfs.img"

echo "  extract   debugfs rdump /"
# Needs root: debugfs rdump rewrites file owners to the uid/gid stored in the
# rootfs (as non-root each chown fails and the dump aborts). sudo is passwordless
# on CI ubuntu runners.
mkdir -p "$TMP/root"
ERR="$TMP/debugfs.err"
if ! (cd "$TMP/root" && sudo debugfs -R "rdump / ." "$TMP/rootfs.img" >/dev/null 2>"$ERR"); then
    echo "debugfs rdump failed; stderr tail:" >&2
    tail -8 "$ERR" >&2
    exit 1
fi
echo "  pack      $(du -sh "$TMP/root" | cut -f1)"
mkdir -p "$(dirname "$OUT_TAR")"
tar -czf "$OUT_TAR" -C "$TMP/root" .
echo "  wrote     $OUT_TAR ($(du -h "$OUT_TAR" | cut -f1))"