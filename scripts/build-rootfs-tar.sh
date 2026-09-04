#!/bin/sh
# Extract the root filesystem from an AREDN ext4 rootfs image (.img.gz) into a
# .tar.gz, for the Dockerfile's `ADD rootfs-<arch>.tar.gz /` (docker auto-extracts).
#
# Equivalent to the hand-verified local procedure:
#   (as root) debugfs -R "rdump / /d" <img>  →  (as root) tar
# Here we use debugfs directly on the runner (no container). ext4 is
# little-endian, so an amd64 host can read images built for arm64/armv7.
#
# Why everything runs as root: debugfs rdump rewrites file owners/modes to the
# values stored in the rootfs (as a non-root user each chown fails and the dump
# aborts), so after `sudo debugfs` the extracted tree is owned by root — and
# /root, /etc/shadow and co. are unreadable/unlistable by a plain user. Reading
# and repacking must therefore run as root too, so the tar faithfully preserves
# uid/gid 0 and the restrictive modes (a rootfs owned by uid 1000 would be wrong
# inside the container). sudo is passwordless on CI ubuntu runners. The final
# tar is chowned back to the runner so later steps (validate/sha256sum) can read
# it.
#
# Usage: build-rootfs-tar.sh <rootfs.img.gz URL> <output .tar.gz path>
set -eu

URL="${1:?usage: build-rootfs-tar.sh <img.gz url> <out.tar.gz>}"
OUT_TAR="${2:?usage: build-rootfs-tar.sh <img.gz url> <out.tar.gz>}"

TMP="$(mktemp -d)"
# The tree is root-owned after the sudo dump; plain rm can't remove it.
trap 'sudo rm -rf "$TMP"' EXIT

echo "  download  $URL"
curl -fsSL --retry 3 --max-time 600 "$URL" | gzip -dc > "$TMP/rootfs.img"

echo "  extract   debugfs rdump /"
mkdir -p "$TMP/root"
ERR="$TMP/debugfs.err"
if ! (cd "$TMP/root" && sudo debugfs -R "rdump / ." "$TMP/rootfs.img" >/dev/null 2>"$ERR"); then
    echo "debugfs rdump failed; stderr tail:" >&2
    tail -8 "$ERR" >&2
    exit 1
fi
echo "  pack      $(sudo du -sh "$TMP/root" | cut -f1)"
mkdir -p "$(dirname "$OUT_TAR")"
sudo tar -czf "$OUT_TAR" -C "$TMP/root" .
# The tar was written as root; give it back to the runner so validate/sha256sum
# (plain user) can read and later overwrite it on a re-run.
sudo chown "$(id -u):$(id -g)" "$OUT_TAR"
echo "  wrote     $OUT_TAR ($(du -h "$OUT_TAR" | cut -f1))"