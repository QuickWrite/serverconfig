#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

BACKUP_DEST="${1:-/srv/backups}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DEST}/${TIMESTAMP}"
RETENTION_DAYS=7

BACKUP_SOURCES=(
  "/srv/caddy"
  "/srv/caddy/data"
  "/srv/caddy/config"
  "/srv/overleaf/overleaf"
  "/srv/overleaf/redis"
  "/var/www"
)

MONGO_CONTAINER_NAME="mongo"
MONGO_REPLICA_SET="overleaf"
MONGO_DBS=("sharelatex")
MONGO_DUMP_DIR="${BACKUP_DIR}/mongo-dumps"
MONGO_WAIT_TIMEOUT=60
MONGO_IMAGE="mongo:8"
MONGO_PORT=27017

mkdir -p "$BACKUP_DIR"

# MongoDB dumps
# Warning: This code was written to tackle most problems that arose when using it.
# This was mainly the case as I also wanted to support mounted drives like WebDAV drives which are another
# annoying can of worms. This script is not good, but it works.
if docker ps --filter "name=${MONGO_CONTAINER_NAME}" --format '{{.Names}}' | grep -q .; then
  log "Preparing MongoDB dumps..."
  mkdir -p "$MONGO_DUMP_DIR"

  # Test writeability for UID 999
  can_write_as_999=false
  if docker run --rm --user 999 --network "none" -v "${MONGO_DUMP_DIR}:/backups" busybox sh -c 'touch /backups/.wbtest 2>/dev/null && rm -f /backups/.wbtest && echo ok' >/dev/null 2>&1; then
    can_write_as_999=true
  fi

  if [ "$can_write_as_999" = true ]; then
    dump_target_dir="$MONGO_DUMP_DIR"
    cleanup_tmp=false
  else
    # Fallback: create local tmp dir, make it writable by UID 999, write there as UID 999, then copy files into mount as the host user
    TMP_DUMPS_DIR="$(mktemp -d)"
    chown 999:999 "${TMP_DUMPS_DIR}"
    chmod 700 "${TMP_DUMPS_DIR}"
    dump_target_dir="$TMP_DUMPS_DIR"
    cleanup_tmp=true
    log "  Mount not writable by UID 999; will create dumps in local temp dir and copy them afterwards."
  fi

  log "  Waiting for MongoDB to become reachable (timeout ${MONGO_WAIT_TIMEOUT}s)..."
  start_ts=$(date +%s)
  while true; do
    if docker exec "${MONGO_CONTAINER_NAME}" mongosh --eval "db.adminCommand('ping')" --quiet >/dev/null 2>&1; then
      log "  MongoDB responded."
      break
    fi
    now_ts=$(date +%s)
    if (( now_ts - start_ts > MONGO_WAIT_TIMEOUT )); then
      warn "  MongoDB did not respond within ${MONGO_WAIT_TIMEOUT}s; skipping mongo dumps."
      break
    fi
    sleep 2
  done

  if docker exec "${MONGO_CONTAINER_NAME}" mongosh --eval "db.adminCommand('ping')" --quiet >/dev/null 2>&1; then
    mapfile -t discovered_dbs < <(docker exec "${MONGO_CONTAINER_NAME}" mongosh --quiet --eval "db.getMongo().getDBs().databases.map(d=>d.name).join(' ')" | tr ' ' '\n' | grep -Ev '^(admin|local|config)$' || true)
    if [[ ${#discovered_dbs[@]} -gt 0 ]]; then MONGO_DBS=("${discovered_dbs[@]}"); fi

    if [[ -n "${MONGO_REPLICA_SET:-}" ]]; then
      MONGO_URI="mongodb://${MONGO_CONTAINER_NAME}:${MONGO_PORT}/?replicaSet=${MONGO_REPLICA_SET}"
    else
      MONGO_URI="mongodb://${MONGO_CONTAINER_NAME}:${MONGO_PORT}/"
    fi

    for db in "${MONGO_DBS[@]}"; do
      out="${dump_target_dir:?}/${db}_${TIMESTAMP}.archive.gz"
      log "  Dumping MongoDB database: ${db} -> $(basename "$out")"
      docker run --rm --user 999 --network "container:${MONGO_CONTAINER_NAME}" -v "${dump_target_dir}:/backups" ${MONGO_IMAGE} \
        mongodump --archive="/backups/$(basename "$out")" --gzip --db="${db}" --uri="${MONGO_URI}" \
        || { warn "    Failed to dump ${db}"; rm -f "$out" || true; }
    done

    FULL_OUT="${dump_target_dir}/all_${TIMESTAMP}.archive.gz"
    log "  Dumping full MongoDB (all DBs) -> $(basename "$FULL_OUT")"
    docker run --rm --user 999 --network "container:${MONGO_CONTAINER_NAME}" -v "${dump_target_dir}:/backups" ${MONGO_IMAGE} \
      mongodump --archive="/backups/$(basename "$FULL_OUT")" --gzip --uri="${MONGO_URI}" \
      || { warn "    Failed to create full MongoDB dump"; rm -f "$FULL_OUT" || true; }

    # If we used a tmp dir, copy files into the mount as the host user (avoid preserving ownership)
    if [ "$cleanup_tmp" = true ]; then
      host_uid=$(stat -c %u "${MONGO_DUMP_DIR}")
      host_gid=$(stat -c %g "${MONGO_DUMP_DIR}")
      mkdir -p "${MONGO_DUMP_DIR}"
      for f in "${dump_target_dir}"/*_"${TIMESTAMP}".archive.gz "${dump_target_dir}"/all_"${TIMESTAMP}".archive.gz; do
        [ -e "$f" ] || continue
        dest="${MONGO_DUMP_DIR}/$(basename "$f")"
        if cp -- "${f}" "${dest}"; then
          rm -f -- "${f}"
        else
          warn "    Failed to copy $(basename "$f") to ${MONGO_DUMP_DIR}"
          continue
        fi
      done
      # best-effort adjust perms/owner on destination (may be a no-op on WebDAV)
      chown -R "${host_uid}:${host_gid}" "${MONGO_DUMP_DIR}" >/dev/null 2>&1 || true
      chmod -R u+rwX,g+rX,o-rwx "${MONGO_DUMP_DIR}" >/dev/null 2>&1 || true
      rm -rf "${dump_target_dir}"
    fi
  fi
else
  warn "MongoDB container not running, skipping mongo dumps."
fi

# Directory backups
log "Backing up directories..."
for src in "${BACKUP_SOURCES[@]}"; do
  if [[ -d "$src" ]]; then
    dir_name="$(basename "$src")"
    log "  Backing up: ${src}"
    if tar czf "${BACKUP_DIR}/${dir_name}.tar.gz" -C "$(dirname "$src")" "$dir_name" 2>/dev/null; then :; else warn "  Issue backing up ${src}"; rm -f "${BACKUP_DIR}/${dir_name}.tar.gz" || true; fi
  else
    warn "  Source not found or not a directory: ${src}"
  fi
done

log "Backing up configuration repo..."
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if tar czf "${BACKUP_DIR}/config-repo.tar.gz" --exclude='.git' --exclude='secrets' -C "$(dirname "$SCRIPT_DIR")" "$(basename "$SCRIPT_DIR")" 2>/dev/null; then :; else warn "  Failed to tar config repo"; rm -f "${BACKUP_DIR}/config-repo.tar.gz" || true; fi

log "Generating checksums..."
cd "$BACKUP_DIR"
sha256sum *.tar.gz *.sql.gz *.archive.gz 2>/dev/null > checksums.sha256 || sha256sum *.tar.gz 2>/dev/null > checksums.sha256 || warn "  Could not generate checksums (no matching files found)"

if [[ "$BACKUP_DEST" == /srv/backups* ]]; then
  log "Cleaning up backups older than ${RETENTION_DAYS} days..."
  find "$BACKUP_DEST" -maxdepth 1 -type d -name "*" -mtime +${RETENTION_DAYS} -exec rm -rf {} + 2>/dev/null || true
fi

BACKUP_SIZE="$(du -sh "$BACKUP_DIR" | cut -f1)"
echo ""
log "============================================"
log "  Backup complete!"
log "  Location: ${BACKUP_DIR}"
log "  Size:     ${BACKUP_SIZE}"
log "============================================"
