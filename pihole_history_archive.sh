#!/usr/bin/env bash
# Exporte les requetes DNS de Pi-hole vers une archive chiffree GPG (cle publique).
# La cle privee n'existe QUE sur le poste Windows de juliann -> ni root ni ludo
# ne peuvent dechiffrer les archives produites ici.
set -euo pipefail

DB=/etc/pihole/pihole-FTL.db          # chemin *dans* le conteneur
RECIPIENT=368BD390CF6A9C563B4C775AF17457FC3741BEDB
KEYRING=/etc/pihole-archive/pubring.gpg
OUTDIR=/home/juliann/dns-archive
STATE=/var/lib/pihole-archive
CURSOR="$STATE/cursor"
RETENTION_DAYS=91

mkdir -p "$OUTDIR" "$STATE"
chown juliann:juliann "$OUTDIR"
chmod 700 "$OUTDIR"
[ -f "$CURSOR" ] || echo 0 > "$CURSOR"
last=$(cat "$CURSOR")

max=$(docker exec pihole pihole-FTL sqlite3 "$DB" \
        "SELECT COALESCE(MAX(id),0) FROM query_storage;")

if [ "$max" -le "$last" ]; then
  logger -t pihole-archive "rien a archiver (cursor=$last)"
  curl -fsS "http://198.51.100.10:3001/api/push/pihole-archive-push-token?status=up&msg=OK+nothing+to+archive" >/dev/null 2>&1 || true
  exit 0
fi

stamp=$(date +%Y%m%dT%H%M%S)
out="$OUTDIR/queries-$stamp.csv.gz.gpg"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# En-tete + lignes. La vue "queries" resout domaine/client/forward.
{
  echo "id,datetime,type,status,domain,client,forward,reply_type,reply_time,dnssec"
  docker exec pihole pihole-FTL sqlite3 -csv "$DB" \
    "SELECT id, datetime(timestamp,'unixepoch','localtime'), type, status,
            domain, client, forward, reply_type, reply_time, dnssec
     FROM queries WHERE id > $last AND id <= $max ORDER BY id;"
} > "$tmp"

rows=$(( $(wc -l < "$tmp") - 1 ))

gzip -9 -c "$tmp" \
  | gpg --batch --yes --trust-model always \
        --no-default-keyring --keyring "$KEYRING" \
        --encrypt --recipient "$RECIPIENT" --output "$out"

chown juliann:juliann "$out"
chmod 600 "$out"
echo "$max" > "$CURSOR"
chmod 600 "$CURSOR"

# Purge au-dela de la retention
find "$OUTDIR" -maxdepth 1 -name 'queries-*.csv.gz.gpg' -mtime +"$RETENTION_DAYS" -delete

logger -t pihole-archive "archive $out : $rows lignes (id $((last+1))..$max)"

# Push Heartbeat Uptime Kuma
curl -fsS "http://198.51.100.10:3001/api/push/pihole-archive-push-token?status=up&msg=OK" >/dev/null 2>&1 || true 
