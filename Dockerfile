# State server image. The GUI client (timeline_app.py) is NOT containerized —
# it runs on the developer's desktop and connects over the published port.
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

COPY timeline_model.py timeline_server.py ./

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
