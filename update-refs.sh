#!/usr/bin/env bash
#
# Resolve the latest upstream tag for each pinned repo and write them straight into the
# Dockerfile's ARG defaults (MIDI_REF / FORGEFX_REF / AXIS_REF) — the single source of truth
# for which source gets cloned and built. No .env, no compose overrides.
#
# Nothing is built here: bumping refs pulls new upstream source you haven't reviewed, so the
# rebuild is a deliberate, separate step. After running this, rebuild with:
#
#     make build      # or: podman compose build  /  podman-compose build
#
# Usage:
#   ./update-refs.sh            # write the latest tags (incl. -beta/pre-releases) to the Dockerfile
#   ./update-refs.sh --stable   # ignore pre-release tags (anything with a '-' suffix)
#   ./update-refs.sh --dry-run  # show what would change, write nothing
#   ./update-refs.sh --build    # also rebuild the image afterwards
#
# Flags combine, e.g.  ./update-refs.sh --stable --build
set -euo pipefail

owner="sKuhLight"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dockerfile="$here/Dockerfile"

# Ordered so the summary reads codec -> server -> UI (their build dependency order).
keys=(MIDI_REF FORGEFX_REF AXIS_REF)
declare -A repo=(
  [MIDI_REF]="forgefx-midi"
  [FORGEFX_REF]="ForgeFX"
  [AXIS_REF]="Axis"
)

stable_only=0
dry_run=0
do_build=0
for arg in "$@"; do
  case "$arg" in
    --stable)  stable_only=1 ;;
    --dry-run) dry_run=1 ;;
    --build)   do_build=1 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

[ -f "$dockerfile" ] || { echo "Dockerfile not found at $dockerfile" >&2; exit 1; }

# All version tags on a remote. --refs drops the ^{} peel lines. Prints one tag per line.
remote_tags() {
  local name="$1"
  git ls-remote --tags --refs "https://github.com/$owner/$name.git" 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^v[0-9]' || true
}

# Current ARG default for a key, read straight from the Dockerfile.
current_val() {
  local key="$1"
  grep -E "^ARG ${key}=" "$dockerfile" | tail -n1 | sed -E "s/^ARG ${key}=//"
}

# Rewrite the `ARG KEY=...` default line in place.
set_ref() {
  local key="$1" val="$2"
  if ! grep -qE "^ARG ${key}=" "$dockerfile"; then
    echo "  ! no 'ARG ${key}=' line in the Dockerfile to update" >&2
    exit 1
  fi
  sed -i -E "s|^ARG ${key}=.*|ARG ${key}=${val}|" "$dockerfile"
}

echo "Resolving latest tags from github.com/$owner ..."
[ "$stable_only" -eq 1 ] && echo "(stable only: ignoring pre-release '-' tags)"
echo

changed=0
declare -A resolved=()
for key in "${keys[@]}"; do
  name="${repo[$key]}"
  raw="$(remote_tags "$name")"
  if [ -z "$raw" ]; then
    echo "  ! $name: could not reach the repo or it has no version tags (network? repo moved?)" >&2
    exit 1
  fi
  sel="$raw"
  if [ "$stable_only" -eq 1 ]; then
    sel="$(printf '%s\n' "$raw" | grep -vE '-' || true)"
  fi
  if [ -z "$sel" ]; then
    echo "  ! $name: only pre-release tags exist (e.g. $(printf '%s\n' "$raw" | sort -V | tail -n1)); re-run without --stable" >&2
    exit 1
  fi
  new="$(printf '%s\n' "$sel" | sort -V | tail -n1)"
  resolved[$key]="$new"
  cur="$(current_val "$key")"
  if [ "$cur" = "$new" ]; then
    printf "  = %-12s %-28s (already latest)\n" "$key" "$new"
  else
    printf "  ^ %-12s %-28s <- %s\n" "$key" "$new" "${cur:-unset}"
    changed=1
  fi
done
echo

if [ "$dry_run" -eq 1 ]; then
  echo "Dry run: Dockerfile not modified."
  exit 0
fi

if [ "$changed" -eq 0 ]; then
  echo "Everything is already on the latest tag; Dockerfile left unchanged."
else
  for key in "${keys[@]}"; do
    set_ref "$key" "${resolved[$key]}"
  done
  echo "Updated ARG defaults in $dockerfile"
fi
echo

if [ "$do_build" -eq 1 ]; then
  compose="$(command -v podman-compose >/dev/null 2>&1 && echo "podman-compose" || echo "podman compose")"
  echo "Rebuilding with: $compose build"
  ( cd "$here" && $compose build )
else
  echo "Next: rebuild to pull the new source ->  make build   (then: make start)"
fi
