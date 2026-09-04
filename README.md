# aredn-docker

Run AREDN in **Supernode / TunnelServer** mode as an **unprivileged user-space
container**. The image is the official/community AREDN rootfs moved **unchanged**
into a `scratch` base image — no firmware code is modified. Everything a
container environment needs (capabilities / sysctl / restart semantics) lives in
the deploy layer. The only build-time change is one hook injected through the
firmware's *own* extension file (`/etc/aredn_include/babel-user.conf` →
`skip-kernel-setup true`, see "Image design" below) — so a basic deployment is a
single compose file with **no host-side files**.

- Image: `ghcr.io/bigsk05/aredn-docker`
- Runs unprivileged: `NET_ADMIN` + `SYS_NICE`, no privileged mode
- Releases only (no nightlies); built by GitHub Actions on a daily cron

> After the first CI push, check the package page (`ghcr.io/bigsk05/aredn-docker`)
> to confirm visibility is **public** (GHCR package visibility is independent of
> the repo; a public repo usually auto-publishes its packages on first push, but
> it's worth confirming once). Otherwise other people need credentials to
> `docker pull`.

## Quick start

```bash
docker pull ghcr.io/bigsk05/aredn-docker:latest
docker compose up -d           # repo ships a production compose (caps/sysctl/restart)
docker exec aredn-supernode /usr/local/bin/firstuse_setup <node-name> <password>
```

Enable supernode mode:

```bash
docker exec aredn-supernode sh -c 'uci -c /etc/config.mesh set aredn.@supernode[0].enable=1 \
  && uci -c /etc/config.mesh commit aredn && /usr/local/bin/node-setup'
```

`node-setup` marks a firmware reboot; in a container that means the process exits
and `restart: unless-stopped` brings it back with the new config active.

## Image design

The Dockerfile is `FROM scratch` + `ADD` of a rootfs tarball — no `RUN`, so
cross-arch builds only unpack the tarball (no QEMU compilation).

The rootfs tarball is a build artifact — gitignored and excluded from the docker
context (`.dockerignore`) — so its default reference can never resolve and a
bare `docker build .` fails loudly at `ADD` instead of silently baking a stale
or wrong-arch rootfs. CI always passes the build-arg
(`ROOTFS_TAR=out/<arch>.tar.gz`); to build locally, produce the tarball first
and pass it the same way:

```bash
./scripts/build-rootfs-tar.sh <rootfs .img.gz URL> out/x86_64.tar.gz
docker build --build-arg ROOTFS_TAR=out/x86_64.tar.gz .
```

The one build-time adaptation is the **babel hook**: AREDN ships an empty include
file at `/etc/aredn_include/babel-user.conf` (comment-only; `babeld_wrapper`
officially appends it). The Dockerfile `COPY`s `compose/babel-user.conf` over it,
so the image contains `skip-kernel-setup true` — making babeld skip writing
`/proc/sys` for wg interfaces created at runtime (those can't be pre-set via
`--sysctl`, and the container's `/proc/sys` is read-only). This is the firmware's
official extension mechanism, applied at build time; mounting your own
`babel-user.conf` over it still overrides for extra per-line options.

## CI: three pipelines, each minding its own business

A daily GitHub Actions cron (`23 2 * * *` UTC, off the top-of-the-hour peak)
probes the latest official **release** (4.x.y.z — nightlies are not tracked).
Each of the three pipelines checks **its own rootfs source** independently:
whoever is ready builds, whoever is missing skips (the next cron tries again) —
pipelines **never wait for each other**:

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
4. Every pipeline runs static validation of the rootfs (critical files + ELF arch
   type); **x86_64 additionally** gets a full runtime smoke test: run the
   container → `firstuse_setup` → enable supernode → `node-setup` → reboot →
   verify `babeld` running, `smoothing-half-life 0`, and the `table 21 blackhole`
5. Publish a GitHub release (same tag as the image; carries the rootfs checksum)

When all three architectures exist, a suffix-less multi-arch manifest is merged
on top:

```bash
docker pull ghcr.io/bigsk05/aredn-docker:<version>     # multi-arch
docker pull ghcr.io/bigsk05/aredn-docker:latest
```

## Running the container

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

### Boundary conditions

- **Firmware reboot == container exit.** `node-setup` (and later config changes)
  mark a reboot that AREDN enacts by calling `/sbin/reboot` — a silent no-op in an
  unprivileged container, where the process simply exits. `restart:
  unless-stopped` is what makes the "reboot" come back. Without it the container
  dies permanently after the first node-setup.
- The firmware claims `eth0` on every boot (it bridges it into the internal
  LAN/WAN VLANs), so a *docker-assigned* address on eth0 is not durable across
  reboots on its own. See **Network shapes** below for the options.

## Network shapes

Three shapes; pick in `compose.yaml` (details in `compose.yaml` comments and
`compose/aredn_include.example/README.md`).

1. **Default bridge** (the shipped `compose.yaml`): container gets a private IP
   on the compose network — fine for a local test run and hand-wired DtD links.
2. **macvlan**: the container is an independent LAN device on your wire. The
   docker host itself cannot ping it (macvlan isolation) — manage it through the
   published ports or a second bridge uplink.
3. **Headless + static eth0** (recommended for a public supernode): an optional
   IP-free override set that turns the node headless (no LAN bridge, no DHCP —
   `eth0` stays a plain interface), plus a static address on the compose subnet so
   published ports / host DNAT keep a stable target across firmware reboots.

The override set ships in `compose/aredn_include.example/`:

```bash
mkdir ./aredn_include && cp compose/aredn_include.example/*.network.user ./aredn_include
```

```yaml
services:
  aredn:
    volumes:
      - ./aredn_include:/etc/aredn_include:ro
```

- `wan.network.user` — headless only (`proto none`; nothing addresses eth0).
- `wan.static.example.txt` — the durable-addressing variant: copy it over
  `wan.network.user` and set `ipaddr` to the container's address on the compose
  subnet. netifd then *owns* the address and re-adds it on every boot, so the
  port-forwarding target survives reboots (verified: netifd flushes a docker
  address from an interface its config merely references with `proto none`).
- No IP/location/hostname appears in the base files — fully generic.

### Ports (when exposing tunnel service)

| purpose | protocol | ports |
|---|---|---|
| supernode tunnels | UDP | 6525–6653 |
| regular-node tunnels | UDP | 5525–5653 |
| WebUI (HTTP) | TCP | 80/8080 |

## Version policy

- **Releases only**, no nightlies: release builds have a stable `node-setup`
  schema and a low cadence (about one version every six months) — "only ship when
  there's a new version".
- Before joining a real Cloud Mesh, read the official supernode deployment
  requirements and naming conventions.

## Layout

```
.github/workflows/build.yml   main assembly pipeline (detect/gate/build/smoke/publish)
.github/release-notes.md      release template (@VERSION@/@ARCH@ placeholders)
Dockerfile                    scratch + ADD rootfs + baked babel hook (no RUN)
.dockerignore                 blocks rootfs artifacts from the build context (see Image design)
compose.yaml                  production deployment example (caps/sysctl/restart)
compose/babel-user.conf       skip-kernel-setup hook (baked into the image)
compose/aredn_include.example/   optional headless + static-eth0 override set (see its README)
scripts/latest-official-version.sh   detect the latest official version
scripts/check-arch-source.sh  check whether one arch's rootfs source is ready (gate)
scripts/build-rootfs-tar.sh   ext4 rootfs image → tar.gz
scripts/validate-rootfs.sh    static rootfs validation (critical files + ELF type; all archs)
scripts/smoke-test.sh         x86_64 full runtime smoke test
```

The scripts are plain `sh`. CI itself also uses the `gh` CLI and `debugfs`
(e2fsprogs, preinstalled on ubuntu runner images). GitHub Actions:
`checkout@v4`, `docker/login-action@v3`, `docker/setup-buildx-action@v3`,
`docker/setup-qemu-action@v3`, `docker/build-push-action@v6`.