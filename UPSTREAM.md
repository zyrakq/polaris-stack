# Upstream provenance log

Append-only. One row per upstream sync. Never edit or delete previous rows.

| Date (UTC) | Upstream commit | Tag/Ref | Note |
|---|---|---|---|
| 2026-11-05 | 218e6a4 | 0.16.1 | Initial dockerization (upstream `agersant/polaris`; no published image exists — source-built via `app/images/polaris/Dockerfile`; web client from polaris-web latest `web.zip`, same strategy as upstream CI) |
