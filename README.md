# Axis + ForgeFX — sandboxed Podman stack

Runs the [ForgeFX](https://github.com/sKuhLight/ForgeFX) engine serving the
[Axis](https://github.com/sKuhLight/Axis) web UI as a single, locked-down container you use from
your browser. Built entirely from pinned source; **offline by default**.

This have been tested on Debian 13 (Trixie) host, with a Axe-FX III device.

## Prerequisites

- **rootless** podman (`podman info` should show `rootless: true`)
- `podman compose` **or** `podman-compose`

## Quick start

The `Makefile` wraps the common commands:

```bash
cd axis
make            # list all targets
make start      # build + run detached (background)
make open       # opens browser at http://127.0.0.1:5056
```

| Target | Does |
|---|---|
| `make up` | Build (if needed) + run in the foreground |
| `make start` | Same, but detached (background) |
| `make verify` | Check the server sees your Axe-Fx III (`/ports` + `/diag`) |
| `make open` | Open the UI in your browser |
| `make logs` | Follow container logs |
| `make down` | Stop + remove the container |
| `make update` | Pin the **latest** upstream tags (MIDI/ForgeFX/Axis) into the `Dockerfile` |
| `make reset` | Stop + wipe the data volume **and** the image (destructive) |

Data (presets/backups/config) persists in the `axis-data` volume across restarts.

## Isolated execution

| Control | Setting | Effect |
|---|---|---|
| Rootless | Podman default | Container "root" maps to an unprivileged subuid on the host |
| Non-root in image | `USER node` | App runs as uid 1000, not root, even inside |
| No capabilities | `cap_drop: ALL` | Drops every Linux capability |
| No escalation | `no-new-privileges` | setuid binaries can't raise privileges |
| Read-only rootfs | `read_only: true` | App can't modify its own image; only `/data` + `/tmp` are writable |
| Ephemeral tmp | `tmpfs /tmp` | `nosuid,nodev,noexec`, wiped on stop |
| Loopback only | `127.0.0.1:5056:5056` | UI is not reachable from your LAN |
| No egress | `internal: true` network | No route to the internet — can't phone home |
| Offline app | no `SUPABASE_*`/`AXIS_CLOUD`/`AXIS_TELEMETRY` | Cloud sync + telemetry stay code-gated off |
| Resource caps | `mem/cpus/pids` limits | Contains runaway/DoS behavior |

The cloud and telemetry features are disabled.

### One-time host setup

```bash
# 1) Your user must be in the 'audio' group (most desktops already are). If `groups` doesn't list 'audio':
sudo usermod -aG audio "$USER"      # then log out + back in

# 2) The ALSA sequencer module must be loaded (usually automatic):
lsmod | grep -q snd_seq || sudo modprobe snd_seq
```

Plug in the Axe-Fx III and **close Axe-Edit III / FractalBot / any DAW** that might be holding the
MIDI port.

### Run + verify

```bash
make start      # build + run in the background
make verify     # should list an "Axe-Fx III MIDI In/Out" and show MIDI available
```

`make verify` just curls `/ports` and `/diag` on the server for you. Then open
<http://127.0.0.1:5056> (`make open`) and pick the device on the **Connection & Device** page (or let
it auto-detect). Edits now drive the hardware.

### If the device isn't detected

- **`/ports` shows nothing / no MIDI (and `libasound2` is present):** the container can't reach ALSA.
  Confirm `/dev/snd` exists, your host user is in `audio`, and you're launching with **podman**.
- **Port is listed but won't open ("busy"):** another app holds it — quit Axe-Edit III / DAWs.

## Reset / cleanup

```bash
make down       # stop + remove the container
make reset      # also wipe the data volume (presets/backups/config) AND the built image
```

## Notes & caveats

- First build is heavy (three `npm ci` + a Vite build). Subsequent `up` is instant.
- Refs are pinned as `ARG` defaults in the `Dockerfile` — the single source of truth for the stack
  version.
- **Updating the stack:** `make update` (or `./update-refs.sh`) resolves the latest tag for each repo
  via `git ls-remote` and rewrites the `ARG MIDI_REF/FORGEFX_REF/AXIS_REF` lines in the `Dockerfile`;
  then `make build` to pull the new source. It does **not** build on its own — bumping refs pulls
  unreviewed upstream code, so the rebuild stays a deliberate step.
- If the UI is blank/unreachable on your Podman version with `internal: true`, delete that one line;
  the app stays offline regardless (no cloud env is set).
- **`make stop`/`make down` prints `rootless netns: kill network process: permission denied`:** this
  is a **harmless** upstream Podman quirk when tearing down a rootless *bridge* network. The container
  still stops and the command returns success — you can ignore it. 
