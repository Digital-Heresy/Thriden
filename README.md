# Thriden — deploy recipe

**Thriden** is a self-hostable memory system for AI agents. This repository is
the **deployment recipe**: the container compose files, operator scripts, and
the configuration you need to stand one up on your own host. It is a read-only
mirror, published automatically on each tagged release. Don't open PRs here.

> If you're running a Thriden host you were given an access **token**
> separately. Use it to `docker login ghcr.io` and pull the container images.
> All of your data stays on your own host, under your own encryption keys.

## Requirements

- A Linux host with Docker + the Docker Compose plugin.
- [SOPS](https://github.com/getsops/sops) + an [age](https://github.com/FiloSottile/age)
  key for your secrets (the recipe never contains secrets — you supply your own).
- Your GHCR access token (provided to you).

## Configuration & ports

The stack is brought up from two compose files layered together:

```
sops exec-env secrets/prod/stack.enc.env \
  "docker compose -f docker-compose.yml -f compose.prod.yml up -d"
```

Thriden ships **no built-in TLS/DNS ingress**. Services bind direct host ports
and you front whatever you want to expose with your own tunnel or reverse-proxy.

Host ports (all loopback-bindable; the prod overlay exposes the two web
surfaces on `0.0.0.0` so your proxy can reach them):

| Port    | Purpose                                  |
|---------|------------------------------------------|
| `8200`  | Management / admin web UI                |
| `8080`  | Activity / telemetry viewer              |
| `27017` | Database (loopback-only, never exposed)  |
| `30xx`  | Per-agent runtime (allocated on demand)  |
| `81xx`  | Per-agent runtime (allocated on demand)  |

Configurable values (image versions, the secure-cookie toggle, your proxy
URL, etc.) are set through your SOPS-encrypted env file. See the operator
documentation provided with your access for the full list and walkthrough.

## Releases

Each release here pins a tested combination of component versions
(`thriden-vX.Y.Z`). Your admin UI reads these to tell you when a new version is
available and what it contains.
