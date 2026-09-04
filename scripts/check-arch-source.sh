#!/bin/sh
# Check whether a given architecture's rootfs is ready. The three pipelines each
# call this independently, minding their own business:
#   * x86_64      <- official downloads.arednmesh.org (every release ships x86/64)
#   * arm64/v7l   <- the matching release asset on fork bigsk05/aredn
#
# Ready -> build; not ready -> skip (the next cron checks again). This is exactly
# the "if arm is stale but x86 updated, only x86 builds" mechanism.
#
# Usage: check-arch-source.sh <version> <arch> [GITHUB_TOKEN]
# Output (stdout, key=value so the workflow can pump it into GITHUB_OUTPUT):
#   ready=<yes|no>
#   url=<download URL of the rootfs .img.gz>
#   reason=<why not ready; empty when ready=yes>
set -eu

VERSION="${1:?usage: check-arch-source.sh <version> <arch> [token]}"
ARCH="${2:?usage: check-arch-source.sh <version> <arch> [token]}"
TOKEN="${3:-}"

# Validate the version format up-front so we never build a bogus URL that just
# looks like a false "not ready".
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
    *)
        printf 'ready=no\nurl=\nreason=invalid version format: %s\n' "$VERSION"
        exit 0
        ;;
esac

maj="$(printf '%s' "$VERSION" | cut -d. -f1)"
min="$(printf '%s' "$VERSION" | cut -d. -f2)"

case "$ARCH" in
    x86_64)
        URL="https://downloads.arednmesh.org/releases/${maj}/${min}/${VERSION}/targets/x86/64/aredn-${VERSION}-x86-64-generic-ext4-rootfs.img.gz"
        if curl -fsSI --retry 2 --max-time 30 "$URL" >/dev/null 2>&1; then
            printf 'ready=yes\nurl=%s\nreason=\n' "$URL"
        else
            printf 'ready=no\nurl=\nreason=x86_64 rootfs not found: %s\n' "$URL"
        fi
        ;;
    arm64|armv7l)
        ASSET="aredn-${VERSION}-${ARCH}-generic-ext4-rootfs.img.gz"
        OWNER_REPO="bigsk05/aredn"
        LOG="$(mktemp)"
        if [ -n "$TOKEN" ]; then
            assets="$(GH_TOKEN="$TOKEN" gh release view "$VERSION" --repo "$OWNER_REPO" \
                --json assets -q '.assets[].name' 2>"$LOG" || true)"
        else
            assets="$(gh release view "$VERSION" --repo "$OWNER_REPO" \
                --json assets -q '.assets[].name' 2>"$LOG" || true)"
        fi
        # Distinguish "gh itself failed" (network/token) from "release not published yet"
        # — the latter is the normal case (waiting for the fork build) and must not be
        # reported as a query failure.
        if [ -s "$LOG" ]; then
            if grep -qi 'not found' "$LOG"; then
                reason="${OWNER_REPO} has no release for ${VERSION} yet (waiting for fork build)"
            else
                reason="gh query failed for ${OWNER_REPO} release ${VERSION}: $(head -c 240 "$LOG" | tr '\n' ' ')"
            fi
            printf 'ready=no\nurl=\nreason=%s\n' "$reason"
            rm -f "$LOG"
            exit 0
        fi
        rm -f "$LOG"
        if printf '%s\n' "$assets" | grep -qx "$ASSET"; then
            printf 'ready=yes\nurl=https://github.com/%s/releases/download/%s/%s\nreason=\n' \
                "$OWNER_REPO" "$VERSION" "$ASSET"
        else
            printf 'ready=no\nurl=\nreason=asset %s missing from %s release %s\n' \
                "$ASSET" "$OWNER_REPO" "$VERSION"
        fi
        ;;
    *)
        printf 'ready=no\nurl=\nreason=unknown arch: %s\n' "$ARCH" >&2
        exit 2
        ;;
esac