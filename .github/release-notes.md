# AREDN @VERSION@ container image · @ARCH@

- **Platform**: `@PLATFORM@`
- **Image digest**: `@DIGEST@`
- **Rootfs checksum**: see release asset `rootfs-@ARCH@.sha256`

## Pull

```bash
docker pull ghcr.io/bigsk05/aredn-docker:@VERSION@-@ARCH@
# Once all three architectures are present you can also use the suffix-less multi-arch tag:
# docker pull ghcr.io/bigsk05/aredn-docker:@VERSION@
# docker pull ghcr.io/bigsk05/aredn-docker:latest
```

## Run (supernode)

```bash
# Local test run:
docker run -d --name aredn-supernode \
  --cap-add NET_ADMIN --cap-add SYS_NICE \
  --sysctl net.ipv4.conf.all.forwarding=1 \
  --sysctl net.ipv6.conf.all.forwarding=1 \
  --sysctl net.ipv6.conf.all.accept_redirects=0 \
  --sysctl net.ipv4.conf.all.rp_filter=0 \
  --restart unless-stopped \
  ghcr.io/bigsk05/aredn-docker:@VERSION@-@ARCH@

docker exec aredn-supernode /usr/local/bin/firstuse_setup <node-name> <password>
docker exec aredn-supernode sh -c 'uci -c /etc/config.mesh set aredn.@supernode[0].enable=1 \
  && uci -c /etc/config.mesh commit aredn && /usr/local/bin/node-setup'
```

No host-side files are needed: the image bakes the babel hook
(`skip-kernel-setup true`) into the firmware's own include file. For a public
supernode, see the repo README's **Network shapes** section (headless + static
eth0 addressing, published ports) and `compose/aredn_include.example/`.

## Notes

- This image is the official/community AREDN firmware rootfs moved into `scratch`
  unchanged, plus one build-time hook injected through the firmware's own
  extension file (`/etc/aredn_include/babel-user.conf`); no firmware code changes.
- Only `NET_ADMIN` + `SYS_NICE` capabilities are required — no privileged mode.
- Built automatically by GitHub Actions: a daily cron checks for a new official release and only builds when one appears.