# Optional: network overrides (`/etc/aredn_include/*.network.user`)

`node-setup` (the AREDN firmware's configuration generator) supports **verbatim
config-file overrides**. If `/etc/aredn_include/<name>.network.user` exists, the
generated network section for that name is replaced with the file contents.
Exact filenames: `bridge.network.user`, `lan.network.user`, `wan.network.user`,
`dtdlink.network.user`.

These four files turn the container into a **headless** node: no `br-lan`, no
LAN VLAN, no DHCP server — `eth0` stays a plain interface. `br0` is left as an
empty bridge; `wan`/`dtdlink` reference `eth0` directly.

They are **not baked into the image** — the image stays as close to official
AREDN as possible. Deploy by bind-mounting a host directory *as a directory*:

```yaml
services:
  aredn:
    volumes:
      - ./aredn_include:/etc/aredn_include:ro
```

```bash
mkdir ./aredn_include && cp compose/aredn_include.example/*.network.user ./aredn_include
docker compose up -d    # then firstuse/node-setup as usual
```

## Two addressing variants for `wan.network.user`

- **`wan.network.user` (proto `none`)** — pure headless. Nothing addresses eth0;
  any docker-assigned address there is flushed by netifd mid-boot (see below).
  Use when you don't need host→container connectivity on eth0.
- **`wan.static.example.txt` (proto `static`)** — the durable-control-plane
  variant. Copy it over `wan.network.user` and set `ipaddr` to the container's
  address on the compose/docker subnet. netifd then *owns* the address, re-adds
  it on every boot, and docker's port-forwarding / published-port target stays
  alive across firmware reboots. This is what a public reachable supernode uses.

## What is verified (containerized AREDN, empirical)

- Stock firmware bridges `eth0` into VLANs on every boot, so a docker-assigned
  address on **eth0** is always flushed (**eth0 cannot carry a durable IP**).
- On a **second docker NIC (`eth1`)** the docker-assigned address survives the
  whole cycle and the firewall accepts inbound there (it is not in any zone;
  global input policy is ACCEPT) — the WebUI answers. Caveat: in this runtime
  the eth0/eth1 mapping was observed to flip across container restarts, so which
  network ends up on the claimed `eth0` is not guaranteed per start. Prefer the
  single-NIC `proto static` recipe above.
- With `proto none` on eth0, netifd flushes the docker address mid-boot (~20s).
  With `proto static`, the address persists across repeated firmware reboots.
- In the headless/override config, nftables' wan-zone input rules are keyed to
  the stock bridge (`br-wan`) and are never generated for eth0 — so inbound on
  the docker NIC falls through to the global input policy (ACCEPT). It is open
  to the compose bridge by default; keep the bridge private.
- No IP/location/hostname appears in the base files — fully generic.