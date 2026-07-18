# Axis + ForgeFX — sandboxed Podman stack

Runs the [ForgeFX](https://github.com/sKuhLight/ForgeFX) engine serving the
[Axis](https://github.com/sKuhLight/Axis) web UI as a single, locked-down container you use from
your browser. Built entirely from pinned source; **offline by default**.

This have been tested on Debian 13 (Trixie) host, wioth a Axe-FX III device.

## Prerequisites

- **rootless** Podman (`podman info` should show `rootless: true`)
- `podman compose` **or** `podman-compose`
- Network access **at build time only** (git clone + `npm ci`). Runtime is offline.

## Quick start

The `Makefile` wraps the common commands (it auto-picks `podman-compose`, falling back to
`podman compose`):

```bash
cd axis
make            # list all targets
make up         # build + run in the foreground   (Ctrl-C to stop)
# ...or...
make start      # build + run detached (background)
```

Then open <http://127.0.0.1:5056> (or `make open`).

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

The cloud and telemetry features are **doubly** disabled: the app gates them on env vars we never
set, *and* the `internal` network removes any path out even if something tried.

### Enabling cloud sync later 

If you ever want account sync, you'd remove `internal: true` and add your own
`SUPABASE_URL` / `SUPABASE_ANON_KEY` (+ `AXIS_CLOUD=1`) as `environment:` entries. Doing so
re-introduces outbound network — only do it deliberately.

## Controlling a real Axe-Fx III

**How it works:** ForgeFX runs *inside* the container and does all USB I/O itself. Your browser only
talks HTTP to it, so nothing MIDI-related needs to happen in the browser. The Axe-Fx III connects as a
**USB-MIDI** device, so the container needs the host's ALSA sound devices (`/dev/snd`). This is already
enabled in `compose.yaml`.

USB device access needs no network, so the offline/isolated setup stays fully intact.

### One-time host setup

```bash
# 1) Your user must be in the 'audio' group (most desktops already are). If `groups`
#    doesn't list 'audio':
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

- **`/diag` shows `"midiAvailable": false` with empty `midiIn`/`midiOut`, even though the host sees
  the unit:** the MIDI transport's native addon (`@julusian/midi`, RtMidi) couldn't load its ALSA
  dependency `libasound.so.2`. The runtime image installs `libasound2` in the
  `Dockerfile` runtime stage for exactly this reason; if you removed it or swapped the base image, put
  it back. Confirm from inside the container:

```bash
podman exec axis-stack node -e 'require("@julusian/midi"); console.log("ok")'
# "libasound.so.2: cannot open shared object file" => the library is missing
```

  Note the package name tracks the **base image**, not your host: the base here is Debian 12
  (bookworm), where it's `libasound2`. This host is **Debian 13 (trixie)**, where the same library is
  packaged as `libasound2t64` — so if you rebase the image onto trixie, install `libasound2t64`
  instead.
- **`/ports` shows nothing / no MIDI (and `libasound2` is present):** the container can't reach ALSA.
  Confirm `/dev/snd` exists, your host user is in `audio`, and you're launching with **podman** (so
  `keep-groups` applies). As a quick test you can add `privileged: true` temporarily — if it works
  then, it's a group/permission issue, not detection.
- **Port is listed but won't open ("busy"):** another app holds it — quit Axe-Edit III / DAWs.
- **Your unit exposes a USB-serial node instead** (FM3-style): run `ls -l /dev/serial/by-id/`, then
  uncomment the `/dev/ttyACM0` line under `devices:` and add `dialout` to your host groups
  (`sudo usermod -aG dialout "$USER"`).
- Passing `/dev/snd` (or one specific tty) is still far tighter than `--privileged`; only fall back to
  `privileged` for a one-off diagnosis.

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
  unreviewed upstream code, so the rebuild stays a deliberate step. Useful flags:
  `./update-refs.sh --dry-run` (preview only), `--stable` (ignore `-beta`/pre-release tags),
  `--build` (update **and** rebuild in one go). `make update-stable` maps to `--stable`.
- If the UI is blank/unreachable on your Podman version with `internal: true`, delete that one line;
  the app stays offline regardless (no cloud env is set).
- **Clean shutdown:** the server runs as PID 1, and the kernel ignores `SIGTERM` sent to PID 1 unless
  the app handles it (it doesn't) — so `compose.yaml` sets `init: true`, which runs `catatonit` as
  PID 1 to forward the signal. Without it, `make stop`/`make down` would hang ~10s and then `SIGKILL`
  the server (exit 137).
- **`make stop`/`make down` prints `rootless netns: kill network process: permission denied`:** this
  is a **harmless** upstream Podman quirk when tearing down a rootless *bridge* network (it deletes
  the netns, the `pasta` helper exits, then Podman tries to kill the already-gone pid). The container
  still stops and the command returns success — you can ignore it. If the noise bothers you, switch
  the rootless-network helper from `pasta` to `slirp4netns` (both do the same job here) by adding this
  to `~/.config/containers/containers.conf` — note it affects *all* your rootless bridge containers,
  not just this stack:

```toml
[network]
default_rootless_network_cmd = "slirp4netns"
```
