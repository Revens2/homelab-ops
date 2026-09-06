#!/bin/bash
# Miroir fidele du vault Obsidian depuis Google Drive.
# Source de verite unique du RAG : "G:\Mon Drive\Obsidian Vault" -> gdrive: -> ici.
#
# Pourquoi "sync" et pas "copy" : copy ne supprime jamais. Une note effacee sur Drive
# resterait indexee et remonterait dans les resultats de recherche -- un RAG qui repond
# du faux avec assurance. --backup-dir garantit qu aucune suppression n est definitive.
set -uo pipefail

SRC="gdrive:Obsidian Vault"
DEST="/srv/vault-mirror"
TRASH_ROOT="/srv/vault-mirror-trash"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RETENTION_DAYS=14

command -v rclone >/dev/null || { echo "rclone absent"; exit 1; }
mkdir -p "$DEST" "$TRASH_ROOT"

# Verrou PARTAGE avec /usr/local/bin/vault_spool_push.sh (adr/0020). Les deux
# ecrivent dans $DEST. Sans le meme flock DES DEUX COTES, celui du pousseur ne
# protege de rien : un `sync` demarrant pendant qu une intention est en vol vers
# Drive supprimerait du miroir la note fraichement creee. L attente est alignee
# sur TimeoutStartSec=1h de l unite.
# TICKET DE PRIORITE. Pose AVANT de se mettre en attente du verrou.
#
# `flock` n est pas equitable : un candidat en attente n a aucune garantie de
# passer avant un nouvel arrivant. vault_spool_push.sh est declenche par un
# .path a chaque intention deposee et par un timer toutes les ~13 s ; quand la
# tache ChatGPT produit des analyses en rafale, ses passages courts se
# re-servent en boucle et cette synchro attend.
#
# Mesure du 2026-09-06 : run demarre a 19:00:56, verrou obtenu a 19:57:33 --
# 56 min 37 s d attente pour un `-w 3600`. Il est passe a 3 min 23 s de
# l expiration, apres quoi le miroir aurait echoue et alerte sur Telegram, et le
# RAG serait reste en retard jusqu au passage suivant.
#
# Le ticket ne prend aucun verrou et n autorise aucune ecriture concurrente : il
# dit seulement au pousseur « rends la main a la fin de l intention en cours ».
TICKET="${VAULT_LOCK_WANTED:-/run/lock/vault-mirror.wanted}"
: > "$TICKET" 2>/dev/null || true
# Retire meme en cas d interruption : un ticket oublie ferait ceder le pousseur
# apres chaque intention, indefiniment.
trap 'rm -f "$TICKET"' EXIT

exec 9>/run/lock/vault-mirror.lock
if ! flock -w 3600 9; then
  echo "verrou vault-mirror non obtenu"
  exit 1
fi
rm -f "$TICKET"

# Exclusions :
#   .obsidian/.trash/.temp/.git -- etat local d Obsidian, aucune valeur semantique
#   livesync_log_*.md           -- journaux de sync, jusqu a 1,3 Mo piece, zero valeur
EXCLUDES=(
  --exclude "/.obsidian/**"
  --exclude "/.trash/**"
  --exclude "/.temp/**"
  --exclude "/.git/**"
  --exclude "livesync_log_*.md"
  --exclude "**/.DS_Store"
)

# Le vault est fait de milliers de petits fichiers : c est la latence par requete
# Drive qui domine, pas la bande passante. Mais un pacer trop court (10ms, burst 200)
# declenche le rate-limit Drive et son backoff exponentiel : constate le 2026-08-14,
# la synchro est tombee a 6 Ko/s pendant plus de dix minutes. On reste donc sur le
# pacer par defaut, avec un plafond explicite de requetes par seconde.
TUNING=(
  --fast-list
  --transfers 8
  --checkers 16
  --tpslimit 8
  --retries 5
  --low-level-retries 20
  --stats-one-line
  --stats 1m
)

if ! rclone sync "$SRC" "$DEST" --backup-dir "$TRASH_ROOT/$STAMP" "${EXCLUDES[@]}" "${TUNING[@]}"; then
  echo "ECHEC rclone sync"
  exit 1
fi

# Un backup-dir vide est cree a chaque passage sans suppression : le retirer.
rmdir "$TRASH_ROOT/$STAMP" 2>/dev/null

find "$TRASH_ROOT" -maxdepth 1 -mindepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null

echo "miroir a jour : $(find "$DEST" -type f -name '*.md' | wc -l) notes, $(du -sh "$DEST" | cut -f1)"
