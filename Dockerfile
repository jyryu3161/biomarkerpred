# Both stages and the complete R dependency graph are immutable inputs.
FROM ghcr.io/prefix-dev/pixi:0.71.2@sha256:d4667958b8f65d26a89ba50f29ddd676a5c2d3ccef367720b265573925cbfbdf AS runtime
WORKDIR /opt/biomarkerpred
COPY pixi.toml pixi.lock ./
RUN pixi install --locked

FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
LABEL org.opencontainers.image.title="BioMarkerPred research engine"
LABEL org.opencontainers.image.version="0.5.0"
# Snapshot fixes OS/font dependencies; Cairo embeds searchable Unicode text.
RUN rm /etc/apt/sources.list.d/debian.sources && \
    printf '%s\n' 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261005T000000Z bookworm main' \
      > /etc/apt/sources.list && \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates fontconfig fonts-noto-cjk && \
    rm -rf /var/lib/apt/lists/* && fc-cache -f
COPY --from=runtime /opt/biomarkerpred/.pixi/envs/default /opt/biomarkerpred/.pixi/envs/default
ENV PATH="/opt/biomarkerpred/.pixi/envs/default/bin:${PATH}" \
    BMP_ENGINE_ROOT=/app LANG=C.UTF-8 LC_ALL=C.UTF-8
WORKDIR /app
COPY *.R ./
COPY R/ ./R/
COPY config/schema.json ./config/schema.json
COPY pixi.toml pixi.lock ./runtime/
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN Rscript BiomarkerCLI.R doctor --json
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["--help"]
