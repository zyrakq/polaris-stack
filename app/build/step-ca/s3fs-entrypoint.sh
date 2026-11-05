#!/bin/sh
# s3fs-fuse extension entrypoint (polaris stack).
# Mounts the RustFS bucket at /music via s3fs, then execs the service's
# original command. Credentials are supplied through environment variables
# only and written to a 0600 passwd file at start; they are never logged.
set -euf

: "${S3FS_ENDPOINT:=http://rustfs:9000}"
: "${S3FS_BUCKET:=polaris-music}"
: "${S3FS_MOUNTPOINT:=/music}"
: "${S3FS_ARGS:=-o allow_other,uid=1000,gid=1000}"

: "${RUSTFS_ACCESS_KEY:?RUSTFS_ACCESS_KEY is required}"
: "${RUSTFS_SECRET_KEY:?RUSTFS_SECRET_KEY is required}"

PASSWD_FILE="/tmp/.s3fs-passwd-${S3FS_BUCKET}"
umask 077
printf '%s:%s\n' "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY" > "$PASSWD_FILE"

# The base compose still mounts the local polaris-music volume at /music
# (stackbuilder merges volume lists append-only); drop it so the bucket is
# the only music source, then mount s3fs over the mountpoint.
umount "$S3FS_MOUNTPOINT" 2>/dev/null || true

s3fs "$S3FS_BUCKET" "$S3FS_MOUNTPOINT" \
  -o passwd_file="$PASSWD_FILE" \
  -o url="$S3FS_ENDPOINT" \
  -o use_path_request_style \
  -o connect_timeout=30 \
  -o readwrite_timeout=120 \
  $S3FS_ARGS

# s3fs can return before the mount is fully live; wait for it to appear.
i=0
while ! awk -v m="$S3FS_MOUNTPOINT" '$2 == m && $3 ~ /^fuse/ { f = 1 } END { exit !f }' /proc/mounts; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo "s3fs: mount did not come up within 30s" >&2
    exit 1
  fi
  sleep 1
done

# When running as root on behalf of the app (polaris service), drop
# privileges to the app user before exec; the seed service runs its copy
# as root so seed files stay root-owned world-readable.
if [ "$(id -u)" = "0" ] && [ -n "${S3FS_EXEC_USER:-}" ]; then
  APP_HOME="$(getent passwd "$S3FS_EXEC_USER" | cut -d: -f6)"
  exec setpriv --reuid="$S3FS_EXEC_USER" --regid="$S3FS_EXEC_USER" \
    --init-groups env HOME="$APP_HOME" "$@"
fi

exec "$@"
