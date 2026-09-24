#!/usr/bin/env bash
# etcd-backup.sh: snapshot etcd + the PKI on cka-m, verify the snapshot, prune old ones.
# Installed as /usr/local/sbin/etcd-backup.sh, run as root by etcd-backup.service (see etcd-backup.timer).
# Runbook: docs/phases/phase-00-rebuild.md, Step R10c.
set -euo pipefail          # stop on any error, unset variable, or failure inside a pipe
umask 077                  # every file we create is root-only: snapshots contain all Secrets

BACKUP_DIR=/var/backups/etcd
KEEP_SNAPSHOTS=28          # timer runs every 6 h -> 28 snapshots = 7 days
KEEP_PKI=7                 # one PKI tarball per day -> 7 days
PKI=/etc/kubernetes/pki/etcd
# Same flags as the manual snapshot in R10a (taken from /etc/kubernetes/manifests/etcd.yaml)
ETCDCTL=(etcdctl --endpoints=https://127.0.0.1:2379
         --cacert="$PKI/ca.crt" --cert="$PKI/server.crt" --key="$PKI/server.key")

# 1. Wait for etcd. After a boot, Persistent=true can start us before the etcd static pod is up.
for i in $(seq 1 30); do                                   # 30 x 10 s = 5 min max
  "${ETCDCTL[@]}" endpoint health >/dev/null 2>&1 && break
  if [ "$i" -eq 30 ]; then echo "etcd not healthy after 5 min, no backup taken" >&2; exit 1; fi
  sleep 10
done

install -d -m 700 "$BACKUP_DIR"
SNAP="$BACKUP_DIR/etcd-$(date +%F-%H%M).db"
TMP="$SNAP.tmp"
trap 'rm -f "$TMP"' EXIT                                   # never leave a half-written file behind

# 2. Snapshot to a temp name, verify it, and only then give it the real name.
#    A file called etcd-*.db is therefore always a snapshot that passed the check.
"${ETCDCTL[@]}" snapshot save "$TMP"
etcdutl snapshot status "$TMP" -w table                    # fails on a corrupt file (hash check)
mv "$TMP" "$SNAP"

# 3. PKI (CA + keys). A snapshot is useless for a rebuild without the CA that signed everything.
tar czf "$BACKUP_DIR/pki-$(date +%F).tgz" -C /etc/kubernetes pki

# 4. Prune: newest first, delete everything after the first N
ls -1t "$BACKUP_DIR"/etcd-*.db   | tail -n +$((KEEP_SNAPSHOTS + 1)) | xargs -r rm -f --
ls -1t "$BACKUP_DIR"/pki-*.tgz   | tail -n +$((KEEP_PKI + 1))       | xargs -r rm -f --

echo "OK: $SNAP ($(du -h "$SNAP" | cut -f1)), $(ls "$BACKUP_DIR"/etcd-*.db | wc -l) snapshots kept"
