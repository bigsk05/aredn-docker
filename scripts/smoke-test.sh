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
    _old="${1:-$(docker inspect -f '{{.State.StartedAt}}' "$NAME" 2>/dev/null || echo init)}"
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

# The firmware's config is not usable right after procd starts. Two boot-time
# races make the un-retried one-shot drive fail:
#
#   * preinit's config_generate rewrites /etc/config.mesh section by section; a
#     `uci set` that lands mid-rewrite sees a partial file (the target anonymous
#     section not there yet) and busybox uci replies "Invalid argument".
#   * node-setup needs the nvram defaults that aredn_init writes late in the
#     boot chain (mac2 / lan_mask / ...). Driven too early it aborts, e.g.
#     "Reference error ... in netmaskToCIDR()" because lan_mask is null.
#
# So wait for both before driving anything — a real operator only acts once the
# device has finished booting. mac2 in the local nvram is the aredn_init marker.
echo "  boot      waiting for boot to settle (aredn_init defaults in nvram)"
_i=0
while [ -z "$(docker exec "$NAME" uci -c /etc/local/uci get hsmmmesh.settings.mac2 2>/dev/null)" ]; do
    _i=$((_i + 1))
    if [ "$_i" -ge 40 ]; then
        echo "SMOKE FAIL: boot never settled (no mac2 in hsmmmesh nvram after $((_i * 3))s)" >&2
        exit 1
    fi
    sleep 3
done

echo "  init      firstuse_setup"
docker exec "$NAME" /usr/local/bin/firstuse_setup CI-SMOKE-01 smoke123 >/dev/null

# Enable the supernode. Retried because the config_generate rewrite can still be
# in flight on a slow runner; each attempt either lands cleanly or within a
# second regenerated file.
_i=0
while ! docker exec "$NAME" sh -c \
    'uci -c /etc/config.mesh set aredn.@supernode[0].enable=1 \
     && uci -c /etc/config.mesh commit aredn' >/dev/null 2>&1; do
    _i=$((_i + 1))
    if [ "$_i" -ge 20 ]; then
        echo "SMOKE FAIL: could not enable supernode (config.mesh kept regenerating, $((_i * 3))s)" >&2
        exit 1
    fi
    echo "  init      config.mesh still regenerating; retry $_i/20"
    sleep 3
done
echo "  init      supernode enabled; node-setup"
docker exec "$NAME" /usr/local/bin/node-setup || { echo "SMOKE FAIL: node-setup returned $?"; exit 1; }

# node-setup marks a firmware reboot (/tmp/reboot-required → aredn_init calls
# /sbin/reboot on the next boot). In an unprivileged container /sbin/reboot is
# a silent no-op, so drive the equivalent transition ourselves: docker restart
# is exactly the documented "firmware reboot == container exit; restart:
# unless-stopped brings it back". wait_restarted below confirms the new boot.
_pre="$(docker inspect -f '{{.State.StartedAt}}' "$NAME" 2>/dev/null || echo init)"
docker restart "$NAME" >/dev/null 2>&1 || true
echo "  reboot    restarting container to complete the firmware reboot"
wait_restarted "$_pre" || { echo "SMOKE FAIL: container did not restart after node-setup"; exit 1; }

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