# syntax=docker/dockerfile:1
#
# Reproducible, offline-by-default build of the Axis + ForgeFX stack.
#
# Three sibling repos are cloned at pinned, immutable tags and built from source in the
# exact layout their `file:` links expect:
#
#   /app/forgefx-midi        (codec)   -- built first; its exports point at dist/
#   /app/ForgeFX/server      (server)  -- file:../../forgefx-midi -> /app/forgefx-midi
#   /app/Axis                (web UI)  -- file:../ForgeFX/server   -> /app/ForgeFX/server
#
# The result is ONE Node service: the ForgeFX HTTP API (Fastify) serving the Axis SPA.
# No cloud/telemetry env is baked in, so the app runs completely dark (no outbound calls).

ARG NODE_IMAGE=node:20-bookworm-slim

# ----------------------------------------------------------------------------- fetch
FROM ${NODE_IMAGE} AS src
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Pinned to the reviewed release tags -- the single source of truth for the stack version.
# Bump to the latest upstream tags with `make update` (runs ./update-refs.sh), then rebuild.
ARG MIDI_REF=v0.4.4
ARG FORGEFX_REF=v0.6.31-beta
ARG AXIS_REF=v0.9.24-beta

RUN git clone --depth 1 --branch "${MIDI_REF}"    https://github.com/sKuhLight/forgefx-midi.git forgefx-midi \
 && git clone --depth 1 --branch "${FORGEFX_REF}" https://github.com/sKuhLight/ForgeFX.git      ForgeFX \
 && git clone --depth 1 --branch "${AXIS_REF}"    https://github.com/sKuhLight/Axis.git         Axis \
 && rm -rf forgefx-midi/.git ForgeFX/.git Axis/.git

# ----------------------------------------------------------------------------- build
FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY --from=src /app /app

# 1) codec (zero runtime deps; exports resolve to dist/)
WORKDIR /app/forgefx-midi
RUN npm ci && npm run build

# 2) server (file:../../forgefx-midi resolves to /app/forgefx-midi)
WORKDIR /app/ForgeFX/server
RUN npm ci && npm run build

# 3) Axis web UI, served same-origin by ForgeFX (VITE_FORGEFX_BASE empty).
#    Skip the Electron binary download -- we build the WEB bundle, not the desktop app.
WORKDIR /app/Axis
ENV ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    NODE_OPTIONS=--max-old-space-size=4096
RUN npm ci \
 && npx svelte-kit sync \
 && VITE_FORGEFX_BASE= npm run build

# Slim the server down to production deps for the runtime image.
WORKDIR /app/ForgeFX/server
RUN npm prune --omit=dev && npm cache clean --force

# --------------------------------------------------------------------------- runtime
FROM ${NODE_IMAGE} AS runtime

# ALSA runtime library: the MIDI transport loads @julusian/midi (RtMidi), whose native
# binding dynamically links libasound.so.2. The -slim base omits it, so without this the
# addon fails to load, MIDI enumeration returns nothing, and NO Fractal device is ever
# detected even though /dev/snd is passed in and the host sees the unit fine.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libasound2 \
 && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production \
    PORT=5056 \
    FORGEFX_STATIC=/app/axis-ui \
    FORGEFX_DATA_DIR=/data
# NOTE: intentionally NO SUPABASE_URL / SUPABASE_ANON_KEY / AXIS_CLOUD / AXIS_TELEMETRY.
# Their absence keeps cloud sync + telemetry disabled (the code gates on them), so the
# server never reaches out to the network.

# codec at the exact path the server's file: link resolves to (dist + catalog + manifest only)
COPY --from=build /app/forgefx-midi/package.json /forgefx-midi/package.json
COPY --from=build /app/forgefx-midi/dist         /forgefx-midi/dist
COPY --from=build /app/forgefx-midi/catalog      /forgefx-midi/catalog

# server (dist + pruned prod node_modules + manifest)
WORKDIR /app/server
COPY --from=build /app/ForgeFX/server/package.json ./package.json
COPY --from=build /app/ForgeFX/server/dist         ./dist
COPY --from=build /app/ForgeFX/server/node_modules ./node_modules

# the built Axis SPA that ForgeFX serves at /
COPY --from=build /app/Axis/build /app/axis-ui

# writable data dir (presets/backups/config), owned by the unprivileged runtime user
RUN mkdir -p /data && chown -R node:node /data /app /forgefx-midi
USER node
EXPOSE 5056
CMD ["node", "dist/index.js"]
