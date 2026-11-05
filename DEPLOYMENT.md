# DEPLOYMENT.md — Polaris deployment model

Phase 0 contract (stack-conventions §20). Analyzed from upstream
`agersant/polaris` at tag `0.16.1` (commit `218e6a4`). Provenance:
`UPSTREAM.md` (written at stack-init Phase 1).

## 1. Product parts

Single-part product. One deployable artifact:

- **polaris** — a single self-contained Rust binary (axum HTTP server,
  port 5050) that serves the web client, the `/api` REST surface (API
  v8, OpenAPI via utoipa), audio streaming with HTTP Range support,
  wave peaks, thumbnails, playlists (import/export), collection
  scanning, DDNS updates, and the embedded `native_db` (LMDB)
  index/database — all in one process (`src/main.rs` → `src/app.rs`
  → `src/server/axum.rs`; no worker, no scheduler, no split frontend).
- **Web client assets** — the polaris-web UI is NOT in the server
  repo; upstream's own release workflow (`.github/actions/make-linux-release`)
  downloads `https://github.com/agersant/polaris-web/releases/latest/download/web.zip`
  and ships it as a `web/` directory next to the binary, served from
  `web_dir_path` (default `./web`, `-w`/`POLARIS_WEB_DIR`). It is a
  static directory baked into the image, never a separate service.
- **Image source: none published** — upstream ships no Docker image.
  The community image `ogarcia/docker-polaris` is officially RETIRED
  ("no new images will be built"; README master). `apache/polaris` is
  an unrelated project (Iceberg catalog — name collision only).
  Therefore the polaris image is SOURCE-BUILT (stack-conventions §19
  + `source-image` skill): `app/images/polaris/Dockerfile` builds the
  server from a pinned tag (`0.16.1`) AND fetches the polaris-web
  `web.zip` release archive, self-contained, empty build context.

Platform note: the `ui` cargo feature (`native-windows-gui`) is
Windows-only; unix builds are headless and unaffected.

## 2. Interaction map

```
[User browser] ──HTTP 5050──> [polaris]
                                │  web client static files at `/` (baked into image)
                                │  /api v8 (auth, settings, mount dirs, index, browse,
                                │          albums/artists/genres/search, playlists,
                                │          songs, peaks, thumbnails, audio ± Range)
                                │  native_db (LMDB) index in --data dir (local volume)
                                │  thumbnails/album-art cache in --cache dir (local volume)
                                │  polaris.toml config (mount_dirs, users, ddns_url)
                                └─out→ DDNS provider (optional; plain URL request,
                                       e.g. duckdns/freemyip update URL)
[music library] ──filesystem──> [polaris] via `[[mount_dirs]]` paths in the
                                music volume (scanner re-indexes on demand)
```

- All reads/writes are local (embedded LMDB, cache dir, config file) —
  no external database, no message queue, no object storage.
- Exactly one inbound port (5050). All external calls are outbound;
  the only outbound call is the optional DDNS update request.
- Nothing breaks when a non-part is absent: there are no outer rings.

## 3. Functional base

| Group | Verdict | Notes |
|---|---|---|
| Core service `polaris` (single container) | **base** | Named volumes: `polaris-music` (library, user payload), `polaris-data` (`--data`, embedded native_db index), `polaris-cache` (`--cache`, thumbnails). Config `polaris.toml` delivered image-side (dockerfile_inline COPY per §13) — declare `[[users]]` (pbkdf2-hashed at first boot) and `[[mount_dirs]]` pointing into the music volume. Entrypoint MUST run with `-f` (foreground): the unix binary otherwise daemonizes via the `daemonize` crate (src/main.rs:48-59) and the container exits. No pid file needed with `-f`. |
| Database (mandatory infra) | **REFUSED with reason** | Polaris 0.16.x is embedded-native-only: data layer is `native_db` 0.8.2 / LMDB (`src/app/ndb.rs`), no SQL driver in `Cargo.toml`. Upstream explicitly REMOVED the DB-dir surface in 0.16.0 ("the `-d` command line option and the `POLARIS_DB_DIR` compile-time environment variable have been removed", CHANGELOG) and removed pre-0.15 migrations. It is neither SQLite nor PostgreSQL — no `database/{postgresql,pgrust}` extension; state persists via the `polaris-data` volume. |
| OIDC (mandatory infra) | **N/A — refused (no native support)** | No OIDC/OAuth/SAML code anywhere in the tree. Auth is TOML-defined users (`[[users]]`, `initial_password` → auto-hashed `hashed_password` pbkdf2-sha256) + branca tokens (src/app/auth.rs). No hook point to front it; no oidc extension. |
| S3 (mandatory infra) | **N/A — refused (no native support)** | No S3/minio/object-storage references; the library is physical files under `[[mount_dirs]]` paths on the local filesystem. No `s3-storage` extension. (An s3fs-fuse mount of the `polaris-music` volume would be technically possible because that volume holds no database data — offered in the catalog, decided at the extension menu.) |
| Other product-mandated infra | none | DDNS is an optional outbound feature toggled in config/web UI (`ddns_url`), not infra. No transcoding exists in 0.16.1 (no ffmpeg/transcode code) — audio is served as-is. |

The functional base is therefore: **one core service + three named
volumes (music payload, data, cache)**.

## 4. Base stage plan

Single Stage A gate; deliberately no outer stages around it:

- Stage A (functional base): `polaris` service on `polaris-network`,
  named volumes `polaris-music` / `polaris-data` / `polaris-cache`
  (explicit `name:`), image
  `${IMAGE:-localhost/polaris:0.16.1}` built by
  `app/images/polaris/Dockerfile` (server tag `0.16.1` + polaris-web
  release assets), command `-f --config /config/polaris.toml
  --data /data --cache /cache`, port `${POLARIS_PORT:-5050}`. Env
  overridable per §5/§7; no environment-layered TLS vars in base.
- No database stage (refused above), no pgrust, no oidc stage, no s3
  stage; no cross-group links exist, so no group needs
  `step-ca-trust` (§14 applies only if this stack is later placed in
  a TLS environment — vhost/env handling is environment-overlay work,
  not base scope).
- Stage A passes when the functional gate scenario below succeeds.

Gate prerequisite (input data, §20 gate-enabling rule): the
functional base needs real audio files in `polaris-music`. Minimal
implementation: seed a handful of tagged audio files (any common
format accepted by symphonia/lofty — mp3/flac supported) into the
music volume before the gate; no extension is needed for it. Gate
toggles are excluded if the track simply plays.

**Functional gate scenario:** fresh boot (`docker compose up -d`) →
polaris stays foreground/healthy and logs its config path and port →
open the web client at `:5050` → log in with the TOML admin user →
Settings shows the `[[mount_dirs]]` music mount → trigger an index
scan (API `POST /api/trigger_index` or the UI action) → wait for
index completion (`GET /api/index_status`) → browse albums in the
collection view → select the seeded track and play it end-to-end in
the browser player (exercises thumb generation, native_db reads, and
Range-based audio streaming).

## 5. Extension catalog

Built-in product features (NOT separate implementations — they ship
in the single binary and are configured via `polaris.toml` or the web
UI): DDNS (`ddns_url`), playlists + import/export (zip/multipart),
thumbnails + `album_art_pattern`, wave peaks, multi-user admin
rights, `album_art_pattern` art scan. No env fragments needed.

Everything outside the functional base:

| Extension | Type | Status | Dependencies |
|---|---|---|---|
| postgresql / pgrust (`database/{postgresql,pgrust}`) | infra | refused | Upstream uses embedded native_db/LMDB; 0.16.0 removed the DB-dir surface entirely (see §3). Never implement. |
| oidc | infra | refused | No OIDC/OAuth support in 0.16.1; auth is password-file based, no integration hook (§3). Never implement. |
| s3-storage (native) | infra | refused | Library is local `[[mount_dirs]]` paths only; no native S3 support. Never implement. |
| s3fs-fuse media volume | infra | available | Optional: mount `polaris-music` via s3fs-fuse for object-backed library storage. Permitted under §11 because the media volume holds no database data (persisted index lives in `polaris-data`). Only after Stage A passes. |
| DDNS toggle | product (built-in) | implemented-in-product | Nothing to build: enable via `ddns_url` in polaris.toml / web UI settings page. Listed for completeness; outbound internet required only when enabled. |
| Reverse-proxy exposure (letsencrypt / step-ca environments) | infra env | available | Standard environment overlays at scaffold time (§7); polaris needs no app-native TLS config (terminates plain HTTP). |

## 6. Open hypotheses

- H1 (high): the polaris-web `web.zip` from upstream's default
  strategy (latest release, same as their CI) is compatible with the
  `0.16.1` API v8 surface. Gate observations: web client loads,
  login + browse + playback all succeed; a DTO/version mismatch
  would surface immediately as UI/API errors (`get_version`).
- H2 (high): running the unix binary WITHOUT `-f` in a container
  kills the service (daemonize forks to background → PID 1 exits).
  Verify at gate: container stays up only with the `-f` flag.
- H3 (medium): polaris runs as a non-root user in-container given
  writable `polaris-data`/`polaris-cache`/`polaris-music` and a
  readable config/web path; 0.16.1 makes no assumptions about
  root. Verify at gate with `user:` set; fall back to root run + note
  in component README if hit-password/scan errors appear.
- H4 (medium): seeding the music volume by `COPY` in an init
  container vs dockerfile_inline COPY into `polaris-music` — either
  works; prefer the simplest that survives `compose down -v` reseeding
  for repeatable Stage A runs. Verify at first gate run.
- H5 (low): whether gate-seeded music formats exercise the
  thumbnail path (e.g. m4a with embedded art) —
  include one file with embedded artwork in the seed set to settle it.
