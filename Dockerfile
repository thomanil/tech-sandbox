# State server image. The Qt GUI client (app/client-python-qt/timeline_client.py)
# is NOT containerized — it runs on the developer's desktop and connects over
# the published port. The WEB client (app/client-web), by contrast, IS baked in:
# the first stage below builds it to static assets that the server stage serves
# at / alongside /ws (same process, port, and origin).
#
# --- web client build stage -------------------------------------------------
#
# Build the Vite/React/TS web client to plain static files. A pinned Node image
# runs `npm ci` + `vite build`, emitting /web/dist (index.html + favicon/icons +
# hashed files under assets/). Only that dist/ is copied into the final image —
# Node and node_modules never ship. Pinned to a digest for reproducible builds
# (the tag is kept as documentation); this is the multi-arch index digest, so
# arm64/amd64 both resolve. Resolved 2026-06-06 from tag 22-bookworm-slim.
FROM node:22-bookworm-slim@sha256:7af03b14a13c8cdd38e45058fd957bf00a72bbe17feac43b1c15a689c029c732 AS web-build
WORKDIR /web
# Copy only the manifests first so `npm ci` is cached and re-runs only when the
# lockfile changes, not on every source edit.
COPY app/client-web/package.json app/client-web/package-lock.json ./
RUN npm ci
COPY app/client-web/ ./
RUN npm run build

# --- server stage -----------------------------------------------------------
#
# Base: Astral's official uv image (Python 3.11 on Debian 12 "bookworm" slim).
# Pinned to a digest for reproducible builds — the readable tag is kept as
# documentation, but Docker enforces the @sha256. This is the multi-arch OCI
# index digest, so arm64/amd64 still resolve automatically.
# Resolved 2026-06-06 from tag python3.11-bookworm-slim. To refresh:
#   curl -s "https://ghcr.io/token?scope=repository:astral-sh/uv:pull" | ...
#   curl -sI -H "Authorization: Bearer <token>" \
#     -H "Accept: application/vnd.oci.image.index.v1+json" \
#     https://ghcr.io/v2/astral-sh/uv/manifests/python3.11-bookworm-slim
FROM ghcr.io/astral-sh/uv:python3.11-bookworm-slim@sha256:4f5d923c9dcea037f57bda425dd209f3ec643da2f0b74227f68d09dab0b3bb36

WORKDIR /app

# curl is used by the compose healthcheck to probe /healthz.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# The server package is flattened into /app (timeline_server.py imports
# timeline_model as a sibling module, so they must stay side by side).
COPY app/server-python/timeline_model.py app/server-python/timeline_server.py ./

# DB migrations, applied on startup by timeline_server.run_migrations() (and
# reusable by a future one-shot migration Job from this same image). Lands at
# /app/db/migrations. See app/server-python/db/migrations/README.md.
COPY app/server-python/db ./db

# Web client assets: the Vite build output from the web-build stage above,
# dropped where timeline_server.py mounts it (static/). Content-hashed filenames,
# so it's safe to cache hard.
COPY --from=web-build /web/dist ./static

# Keep the PEP 723 inline metadata in timeline_server.py as the single source of
# truth for dependencies: resolve them with uv and install system-wide at build
# time, so container startup needs no network and no runtime resolution.
RUN uv export --script timeline_server.py --no-hashes -o /tmp/requirements.txt \
    && uv pip install --system -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

# Run as a non-root user (k8s-friendly).
RUN useradd --create-home --uid 10001 app
USER app

# 0.0.0.0 so the port is reachable outside the container; see timeline_server.py.
ENV HOST=0.0.0.0 \
    PORT=8000
EXPOSE 8000

# Plain python: deps are already installed, so the PEP 723 metadata is ignored
# and there's no uv resolution at start.
CMD ["python", "timeline_server.py"]
