#!/bin/sh
# Runtime smoke test: boot the freshly-built image, drive it to supernode state,
# and verify the key processes/config.
#
# Flow (mirrors the 4-node experiment this project verified locally):
#   boot → firstuse_setup → enable supernode → node-setup → "firmware reboot"
#   (container exit) → restart unless-stopped brings it back → check babeld and
#   the supernode-specific config.
#
# Only x86_64 (linux/amd64) runs the full test. The arm architectures only get
# static validation (scripts/validate-rootfs.sh): the runner is amd64, and
# emulating a full OpenWrt init (procd+netifd+babeld) under QEMU is both slow and
# flaky — not worth gating every build on it.
#
# Notes:
#   * Always use `pgrep <name>` (no -f) — `-f` matches pgrep's own command line
#     (which contains the pattern).
#   * "Reboot" is detected by a change in docker inspect's StartedAt, so we never
#     mistake an old boot for a fresh one.
#
# Usage: smoke-test.sh <image[:tag]>
set -eu

IMAGE="${1:?usage: smoke-test.sh <image>}"

NAME="aredn-smoke-$$"
docker rm -f "$NAME" >/dev/null 2>&1 || true
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

# wait_pid <process name> <max tries> <interval sec> — wait for a process to
# appear inside the container
wait_pid() {
    _cmd="$1"; _n="$2"; _s="$3"
    _i=0
    while [ "$_i" -lt "$_n" ]; do
        docker exec "$NAME" pgrep "$_cmd" >/dev/null 2>&1 && return 0
        _i=$((_i + 1))
        sleep "$_s"
    done
    return 1
}

# wait_restarted <sec> — wait for the container to go through the exit/reboot
# transition (after node-setup marks a reboot); returns the new container's
# StartedAt (fails if it hasn't restarted within ~5 minutes)
wait_restarted() {
    _old="$(docker inspect -f '{{.State.StartedAt}}' "$NAME" 2>/dev/null || echo init)"
    _i=0
    while [ "$_i" -lt 150 ]; do
        _now="$(docker inspect -f '{{.State.StartedAt}}' "$NAME" 2>/dev/null || echo gone)"
        case "$_now" in
            gone|"") _now="$_old" ;;
        esac
        if [ "$_now" != "$_old" ]; then
            echo "  reboot    new StartedAt=$_now"
            return 0
        fi
        _i=$((_i + 1))
        sleep 2
    done
    return 1
}

echo "  run       $NAME  <-  $IMAGE"
docker run -d --name "$NAME" \
    --restart unless-stopped \
    --cap-add NET_ADMIN \
    --cap-add SYS_NICE \
    --sysctl net.ipv4.conf.all.forwarding=1 \
    --sysctl net.ipv6.conf.all.forwarding=1 \
    --sysctl net.ipv6.conf.all.accept_redirects=0 \
    --sysctl net.ipv4.conf.all.rp_filter=0 \
    "$IMAGE" >/dev/null

echo "  boot      waiting for procd"
wait_pid procd 30 2 || { echo "SMOKE FAIL: procd never came up"; exit 1; }

echo "  init      firstuse_setup"
docker exec "$NAME" /usr/local/bin/firstuse_setup CI-SMOKE-01 smoke123 >/dev/null

echo "  init      enable supernode + node-setup"
docker exec "$NAME" sh -c \
    'uci -c /etc/config.mesh set aredn.@supernode[0].enable=1 \
     && uci -c /etc/config.mesh commit aredn \
     && /usr/local/bin/node-setup' >/dev/null

echo "  reboot    waiting for container restart (restart: unless-stopped)"
wait_restarted || { echo "SMOKE FAIL: container did not restart after node-setup"; exit 1; }

echo "  check     babeld running"
wait_pid babeld 30 2 || { echo "SMOKE FAIL: babeld not running"; exit 1; }

echo "  check     supernode babel config (smoothing-half-life 0 / import-table 21)"
_i=0
while [ "$_i" -lt 20 ]; do
    if docker exec "$NAME" sh -c 'grep -qs "smoothing-half-life 0" /var/etc/babel-active.conf' 2>/dev/null; then
        break
    fi
    _i=$((_i + 1))
    sleep 3
done
docker exec "$NAME" sh -c 'grep -q "smoothing-half-life 0" /var/etc/babel-active.conf'

echo "  check     policy route table 21 blackhole"
_i=0
while [ "$_i" -lt 20 ]; do
    if docker exec "$NAME" sh -c 'ip route show table 21 | grep -q "blackhole 10.0.0.0/8"' 2>/dev/null; then
        echo "SMOKE OK: $IMAGE"
        exit 0
    fi
    _i=$((_i + 1))
    sleep 3
done
echo "SMOKE FAIL: no blackhole 10.0.0.0/8 in table 21" >&2
exit 1