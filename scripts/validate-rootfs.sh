#!/bin/sh
# Static validation for a rootfs tar (no full boot): confirm the tar extracted
# from the rootfs image is a sane AREDN root filesystem with the critical
# files/directories present. Runs for every architecture in CI; the runtime
# smoke test is x86_64-only.
#
# Checks match what the project's 4-node experiment actually depends on:
#   - first-boot entrypoint /sbin/init (procd's init)
#   - firstuse_setup (first-boot initialization entry)
#   - node-setup (supernode setup)
#   - babeld and babeld_wrapper (babel convergence core)
#   - /etc/aredn_include mount point (babel-user.conf hook lives here)
#   - a core binary passes `file` for the expected architecture
#     (the x86 host's `file` recognizes arm64/armv7 ELF)
#
# Usage: validate-rootfs.sh <rootfs .tar.gz path> <expected file type, e.g. "ARM aarch64">
set -eu

TAR="${1:?usage: validate-rootfs.sh <rootfs.tar.gz> <elf-type>}"
WANT_TYPE="${2:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

tar -xzf "$TAR" -C "$TMP"

missing=""
for f in \
    sbin/init usr/local/bin/firstuse_setup usr/local/bin/node-setup \
    usr/sbin/babeld etc/aredn_include etc/config ; do
    [ -e "$TMP/$f" ] || { echo "MISSING $f" >&2; missing="1"; }
done

if [ -n "$missing" ]; then
    echo "VALIDATE FAIL: missing files" >&2
    exit 1
fi

# Architecture check: look at one core binary and confirm the ELF machine type
# matches expectation. file(1) output looks like
# "ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV)" or
# "ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV)";
# the machine type is the 2nd comma-separated field. On non-ELF output we fall
# back to the whole string (grep then fails to match → gate blocks).
#
# -L is required: /sbin/init is a symlink to ../sbin/procd, and file(1) without
# -L reports "symbolic link to ..." — no ELF header → the check never matches.
for probe in sbin/init usr/sbin/babeld; do
    [ -f "$TMP/$probe" ] || continue
    out="$(file -bL "$TMP/$probe")"
    machine="$(printf '%s' "$out" | awk -F, 'NR==1 && $1 ~ /ELF/ { gsub(/^ +| +$/, "", $2); print $2 }')"
    [ -n "$machine" ] || machine="$out"
    echo "  elf       $probe -> $machine"
    if [ -n "$WANT_TYPE" ] && ! printf '%s' "$machine" | grep -qi "$WANT_TYPE"; then
        echo "VALIDATE FAIL: $probe is '$machine' (full: $out), want ~$WANT_TYPE" >&2
        exit 1
    fi
    break
done

# Version anchor: the rootfs should carry /etc/mesh-release, or at least the
# config dir exists (node-setup depends on it)
[ -e "$TMP/etc/mesh-release" ] && echo "  version   $(tr -d '\r\n' < "$TMP/etc/mesh-release" 2>/dev/null | head -c 80)"
echo "VALIDATE OK: $(du -sh "$TMP" | cut -f1)"