#!/usr/bin/env bash
# Sauvegarde chiffree des volumes Docker sensibles du coffre.
#
# Chaine : arret a froid -> tar -> gpg --encrypt (cle PUBLIQUE seule) -> rclone vers un remote
# Drive borne par root_folder_id -> retention -> redemarrage.
#
# Propriete centrale : le VPS ne detient QUE la cle publique. Il produit des archives qu il est
# lui-meme incapable de relire. Un attaquant qui obtient root ici repart avec du chiffre.
# La cle privee vit hors ligne, voir runbooks/recovery-kit-gpg.md.
#
# Ce script ECHOUE VOLONTAIREMENT si la cle de chiffrement est absente : produire une archive
# en clair serait pire que ne pas sauvegarder, parce que personne ne s en apercevrait.
set -euo pipefail

RECIPIENT="${RECIPIENT:-backups@example.org}"
REMOTE="${REMOTE:-gdrive-backups:}"
STAGING="${STAGING:-/var/backups/vault}"
RETENTION_JOURS="${RETENTION_JOURS:-30}"
# Volumes a sauvegarder, sous la forme "projet_compose:repertoire_compose:volume[,volume...]"
CIBLES="${CIBLES:-}"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
mourir() { log "ECHEC: $*" >&2; exit 1; }

# --- Controles prealables, tous bloquants ------------------------------------

command -v gpg >/dev/null      || mourir "gpg absent"
command -v rclone >/dev/null   || mourir "rclone absent"
command -v docker >/dev/null   || mourir "docker absent"

gpg --list-keys "$RECIPIENT" >/dev/null 2>&1 \
  || mourir "cle publique '$RECIPIENT' absente du trousseau. Voir runbooks/recovery-kit-gpg.md."

# Controle negatif : si le VPS possede la cle PRIVEE, le modele de securite est casse.
if gpg --list-secret-keys "$RECIPIENT" >/dev/null 2>&1; then
  mourir "la cle PRIVEE '$RECIPIENT' est presente sur le VPS. Elle ne doit jamais y etre."
fi

rclone lsd "$REMOTE" >/dev/null 2>&1 \
  || mourir "remote rclone '$REMOTE' injoignable ou non configure"

[ -n "$CIBLES" ] || mourir "CIBLES vide : rien a sauvegarder"

mkdir -p "$STAGING"
chmod 700 "$STAGING"

HORO="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="$STAGING/coffre-$HORO.tar.gz"
CHIFFRE="$ARCHIVE.gpg"

# --- Arret a froid, archivage, redemarrage ------------------------------------

declare -a ARRETES=()
redemarrer() {
  for rep in "${ARRETES[@]}"; do
    log "redemarrage de $rep"
    (cd "$rep" && docker compose start) || log "ATTENTION: redemarrage KO pour $rep"
  done
}
trap 'redemarrer; rm -f "$ARCHIVE"' EXIT

declare -a CHEMINS=()
for cible in $CIBLES; do
  IFS=: read -r _projet repertoire volumes <<< "$cible"
  [ -d "$repertoire" ] || mourir "repertoire compose introuvable : $repertoire"
  log "arret a froid de $repertoire"
  (cd "$repertoire" && docker compose stop) || mourir "arret KO pour $repertoire"
  ARRETES+=("$repertoire")
  IFS=, read -ra vols <<< "$volumes"
  for v in "${vols[@]}"; do
    point="$(docker volume inspect "$v" --format '{{ .Mountpoint }}' 2>/dev/null)" \
      || mourir "volume introuvable : $v"
    CHEMINS+=("$point")
  done
done

log "archivage de ${#CHEMINS[@]} volume(s)"
tar -czf "$ARCHIVE" "${CHEMINS[@]}" 2>/dev/null || mourir "tar KO"

log "chiffrement pour $RECIPIENT"
gpg --batch --yes --trust-model always --encrypt --recipient "$RECIPIENT" \
    --output "$CHIFFRE" "$ARCHIVE" || mourir "chiffrement KO"
rm -f "$ARCHIVE"
chmod 600 "$CHIFFRE"

# Preuve, a chaque execution, que l archive n est pas lisible ici.
if gpg --batch --list-packets "$CHIFFRE" 2>/dev/null | grep -q "^:literal data packet"; then
  mourir "l archive semble en clair. Arret."
fi

redemarrer
ARRETES=()
trap - EXIT

# --- Envoi et retention -------------------------------------------------------

log "envoi vers $REMOTE"
rclone copy "$CHIFFRE" "$REMOTE" --tpslimit 8 --retries 3 --stats 0 || mourir "envoi KO"

TAILLE="$(stat -c %s "$CHIFFRE")"
log "archive envoyee : $(basename "$CHIFFRE") ($TAILLE octets)"

log "retention : suppression au-dela de $RETENTION_JOURS jours"
find "$STAGING" -name 'coffre-*.tar.gz.gpg' -mtime "+$RETENTION_JOURS" -print -delete || true
rclone delete "$REMOTE" --min-age "${RETENTION_JOURS}d" --include 'coffre-*.tar.gz.gpg' || true

log "termine"
