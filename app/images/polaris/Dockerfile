# Polaris — source-built image (stack-conventions §19 / source-image skill).
# Self-contained: EMPTY build context — the server is cloned at a pinned tag,
# the web client is fetched from polaris-web releases, and the Stage A gate
# seed audio is generated inline. NEVER vendor upstream source into the repo.

ARG RUST_IMAGE=rust:1-bookworm
ARG RUNTIME_IMAGE=debian:stable-slim
ARG POLARIS_VERSION=0.16.1

# --- server binary -----------------------------------------------------------
FROM ${RUST_IMAGE} AS server-builder
ARG POLARIS_VERSION
RUN git clone https://github.com/agersant/polaris.git /src \
 && git -C /src checkout "${POLARIS_VERSION}"
WORKDIR /src
RUN cargo build --release && cp target/release/polaris /polaris

# --- web client assets (upstream CI strategy: latest polaris-web release) ----
FROM ${RUST_IMAGE} AS web-fetcher
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL -o /tmp/web.zip \
      https://github.com/agersant/polaris-web/releases/latest/download/web.zip \
 && mkdir /tmp/webx && unzip -q /tmp/web.zip -d /tmp/webx \
 && srcdir=$(find /tmp/webx -maxdepth 2 -name index.html -printf '%h' | head -1) \
 && test -n "$srcdir" \
 && mkdir /web && cp -a "$srcdir"/. /web/ \
 && test -f /web/index.html

# --- gate seed audio (DEPLOYMENT.md §4; H5: one track with embedded art) -----
FROM alpine:3.20 AS seed-builder
RUN apk add --no-cache ffmpeg \
 && mkdir /seed \
 && ffmpeg -loglevel error -f lavfi -i color=c=0x1f6f8b:s=512x512 -frames:v 1 -q:v 2 /tmp/cover.jpg \
 && ffmpeg -loglevel error -f lavfi -i sine=frequency=440:duration=30 \
      -metadata title="Seed Track One" -metadata artist="Polaris Seed" \
      -metadata album="Seed Collection" -metadata track=1 \
      -c:a libmp3lame -b:a 128k /seed/01-seed-track-one.mp3 \
 && ffmpeg -loglevel error -f lavfi -i sine=frequency=550:duration=30 \
      -metadata title="Seed Track Two" -metadata artist="Polaris Seed" \
      -metadata album="Seed Collection" -metadata track=2 \
      -c:a libmp3lame -b:a 128k /seed/02-seed-track-two.mp3 \
 && ffmpeg -loglevel error -f lavfi -i sine=frequency=660:duration=30 -i /tmp/cover.jpg \
      -map 0:a -map 1:v -c:a libmp3lame -b:a 128k -c:v copy -id3v2_version 3 \
      -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
      -metadata title="Seed Track Three" -metadata artist="Polaris Seed" \
      -metadata album="Seed Collection" -metadata track=3 \
      /seed/03-seed-track-three.mp3 \
 && ls -la /seed

# --- runtime -----------------------------------------------------------------
FROM ${RUNTIME_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 1000 --home-dir /app --create-home polaris
COPY --from=server-builder /polaris /app/polaris
COPY --from=web-fetcher /web/ /app/web/
COPY --from=seed-builder /seed/ /seed/
RUN chmod 0755 /app/polaris \
 && mkdir -p /data /cache /music /config \
 && chown polaris:polaris /data /cache /music
WORKDIR /app
USER polaris
EXPOSE 5050
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=30s \
  CMD curl -f http://127.0.0.1:5050/ || exit 1
ENTRYPOINT ["/app/polaris"]
