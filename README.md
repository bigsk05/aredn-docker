# aredn-docker

Strip the **Supernode / TunnelServer** mode out of the AREDN firmware and run it as an
**unprivileged user-space container**. The image is the official/community AREDN
rootfs moved **unchanged** into a `scratch` base image — **zero firmware
modification**; every container-environment adaptation (capabilities / sysctl /
network shapes / restart semantics) is applied in the compose and orchestration
layer. The one firmware-side hook a supernode needs is baked into the firmware's
own include file at build time (`/etc/aredn_include/babel-user.conf` →
`skip-kernel-setup true`; see "Babel hook") — so a deployment is a single
compose file and needs **no host-side files**.

- Image: `ghcr.io/bigsk05/aredn-docker`
- Mechanism details: see `docker-test/DEPLOYMENT-GUIDE.md` in this project's
  workspace (full record of the locally-verified 4-node hybrid mesh; not checked
  into the repo).

> After the first CI push, check your package page (`ghcr.io/bigsk05/aredn-docker`)
> to confirm visibility is **public** (GHCR package visibility is independent of
> the repo; a public repo usually auto-publishes its packages on first push, but
> it's worth confirming once). Otherwise other people need credentials to
> `docker pull`.

## Three pipelines, each minding its own business

A daily GitHub Actions cron (`23 2 * * *` UTC) probes the latest official
**release** (4.x.y.z — nightlies are not tracked). Each of the three pipelines
checks **its own rootfs source** independently: whoever is ready builds, whoever
is missing skips (the next cron tries again) — pipelines **never wait for each
other**:

| pipeline | rootfs source | builds when |
|---|---|---|
| `x86_64` | official [downloads.arednmesh.org](https://downloads.arednmesh.org/releases/) | a new official release appears |
| `arm64` | matching-version release asset on fork [bigsk05/aredn](https://github.com/bigsk05/aredn) | official has a new version **and** the fork has built it |
| `armv7l` | same | same |

Manual trigger: `workflow_dispatch`, with `arch` (all/x86_64/arm64/armv7l) and
`force` (ignore the "already published" check and rebuild).

Each build:

1. Detect version → gate (source ready? already published?)

2. `debugfs` extracts the ext4 rootfs image to `rootfs-<arch>.tar.gz`
   (`FROM scratch` + `ADD`, no RUN, so cross-arch needs no compilation)

3. `docker buildx` builds for the right platform and pushes to GHCR
   (tags: `<version>-<arch>` + `latest-<arch>`)

4. **x86_64** additionally gets a full runtime smoke test: run the container →
   `firstuse_setup` → enable supernode → `node-setup` → verify `babeld` is
   running, `smoothing-half-life 0`, and the `table 21 blackhole`. Arm gets
   static validation (critical files + ELF arch type)

5. Publish a GitHub release (same tag as the image; carries the rootfs checksum)

When all three architectures exist, a suffix-less multi-arch manifest is merged
on top:

```bash
docker pull ghcr.io/bigsk05/aredn-docker:4.26.7.0     # multi-arch
docker pull ghcr.io/bigsk05/aredn-docker:latest
```

## Usage

```bash
docker pull ghcr.io/bigsk05/aredn-docker:latest
docker compose up -d            # the repo ships a production compose (caps/sysctl/babel hook)
docker exec aredn-supernode /usr/local/bin/firstuse_setup <node-name> <password>
```

Enable supernode:

```bash
docker exec aredn-supernode sh -c 'uci -c /etc/config.mesh set aredn.@supernode[0].enable=1 \
  && uci -c /etc/config.mesh commit aredn && /usr/local/bin/node-setup'
```

### Capabilities (no privileged mode)

```yaml
cap_add:
  - NET_ADMIN    # create wg interfaces, ip rule/route, netlink routes (required by babeld)
  - SYS_NICE     # babeld_wrapper runs `nice --20 babeld`; without it the container crash-loops
# CAP_NET_RAW is already in Docker's default set — no need to add it
```

### sysctl (pre-set on the host; the container's /proc/sys stays read-only)

```yaml
sysctls:
  net.ipv4.conf.all.forwarding: "1"
  net.ipv6.conf.all.forwarding: "1"
  net.ipv6.conf.all.accept_redirects: "0"
  net.ipv4.conf.all.rp_filter: "0"
```

### Babel hook (baked into the image, no host file)

AREDN already ships an empty include file at `/etc/aredn_include/babel-user.conf`
(comment-only; `babeld_wrapper` officially appends it). The Dockerfile `COPY`s
`compose/babel-user.conf` over it at build time, so the image contains
`skip-kernel-setup true` — making babeld skip writing `/proc/sys` for wg
interfaces created at runtime (those can't be pre-set via `--sysctl`, and the
container's `/proc/sys` is read-only). This is the firmware's official extension
mechanism, applied as a build-time container adaptation.

Deploying therefore needs no host-side volume at all. To add extra per-line
babel options for a specific deployment, mount your own file over it (`:ro`):

```yaml
volumes:
  - ./compose/babel-user.conf:/etc/aredn_include/babel-user.conf:ro
```

### Network shapes

- **Local test run**: default bridge (current `compose.yaml`).
- **Real deployment** (the container is an independent LAN device the docker host
  can't even ping): macvlan — see the notes in `compose.yaml`.

### Ports (when exposing tunnel service)

| purpose | UDP port |
|---|---|
| supernode tunnels | 6525–6653 |
| regular-node tunnels | 5525–5653 |
| WebUI | 80/8080 |

## Version policy

- **Releases only**, no nightlies (official supernode docs lean toward nightlies,
  but release builds have a stable `node-setup` schema and a low cadence — about
  one version every six months — which fits the "only ship when there's a new
  version" goal).
- Release-vs-nightly differences and trade-offs: `docker-test/DEPLOYMENT-GUIDE.md`
  §7 "Versions" in the same workspace.
- Before joining a real Cloud Mesh, read the official supernode deployment
  requirements and naming conventions.

## Layout

```
.github/workflows/build.yml   main assembly pipeline (detect/gate/build/smoke/publish)
.github/release-notes.md      release template
Dockerfile                    scratch + ADD rootfs + baked babel hook (no RUN)
compose.yaml                  production deployment example (caps/sysctl/babel hook/restart)
compose/babel-user.conf       skip-kernel-setup hook
scripts/latest-official-version.sh   detect the latest official version
scripts/check-arch-source.sh  check whether one arch's rootfs source is ready (gate)
scripts/build-rootfs-tar.sh   ext4 rootfs image → tar.gz
scripts/validate-rootfs.sh    arm static validation (critical files + ELF type)
scripts/smoke-test.sh         x86_64 full runtime smoke test
```

All scripts are plain `sh` with no external dependencies. Actions the workflow
uses: `checkout@v4`, `docker/login-action@v3`,
`docker/setup-buildx-action@v3`, `docker/setup-qemu-action@v3`,
`docker/build-push-action@v6`.