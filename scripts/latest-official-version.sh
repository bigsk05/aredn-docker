#!/bin/sh
# Detect the latest official AREDN release version (releases only — NOT nightlies).
#
# Source: the official GitHub releases atom feed — unauthenticated and structured,
# the tag IS the version number.
#   https://github.com/aredn/aredn/releases.atom
# Convention: take the <title> of the first <entry> (the feed-level <title> comes
# first; entry titles start from the second one).
# Output: bare version, e.g. 4.26.7.0.
#
# Accepted edge cases:
#   * If the project ever publishes a pre-release, it may be the first atom entry —
#     the real build gate is check-arch-source.sh (the downloads/fork asset must
#     exist), so a misdetection only causes one skipped run (self-healed by the next
#     cron), never a wrong build.
#   * grep -o is a GNU extension; GitHub runners use GNU grep, so it's fine.
set -eu

ATOM_URL="${ATOM_URL:-https://github.com/aredn/aredn/releases.atom}"

latest="$(curl -fsSL --retry 2 --max-time 30 "$ATOM_URL" \
    | grep -o '<title>[^<]*</title>' \
    | sed -n '2p' \
    | sed -e 's/<[^>]*>//g')"

if [ -z "${latest:-}" ]; then
    echo "latest-official-version: no version found in $ATOM_URL" >&2
    exit 1
fi
echo "$latest"