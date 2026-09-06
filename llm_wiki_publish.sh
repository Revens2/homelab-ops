#!/bin/bash
# Publication du wiki genere vers Google Drive -- le saut manquant de la chaine.
#
# POURQUOI CE SCRIPT EXISTE
# Le moteur llm-wiki ecrit ses fiches dans /srv/obsidian-vault/wiki (WIKI_DIR).
# Le RAG, lui, lit /srv/vault-mirror, qui est un miroir de Google Drive reconstruit
# par vault-mirror-sync.timer. Entre les deux : rien. `llm_wiki_sync.sh` a ete
# neutralise le 2026-08-22 et ne poussait de toute facon QUE raw/assets, jamais
# wiki/. Consequence mesuree le 2026-09-06 : 4167 fiches cote moteur, 2554 cote
# miroir. Une fiche produite par le moteur n a JAMAIS ete retrouvable dans le RAG
# sans publication manuelle.
#
# SENS DE SYNCHRONISATION -- moteur -> Drive, jamais l inverse.
# Drive reste la source de verite du vault humain ; le moteur est autoritaire sur
# les seuls namespaces qu il genere (wiki/sources, wiki/entities, wiki/concepts).
#
# TROIS GARDE-FOUS, dans cet ordre :
#   1. `copy`, JAMAIS `sync`. Une fiche presente sur Drive et absente du moteur
#      (7 mesurees le 2026-09-06 : osauto, hermes-capture-mcp, Vault MCP...) est
#      ecrite par un agent via vault-mcp. `sync` les supprimerait.
#   2. `--update`. Si la version Drive est PLUS RECENTE que celle du moteur, elle
#      gagne : c est une edition humaine ou un agent, on ne l ecrase pas.
#      20 fichiers etaient dans ce cas le 2026-09-06.
#   3. scan de secrets AVANT tout transfert, bloquant. Mesure le 2026-09-06 :
#      /srv/obsidian-vault/wiki/sources/VPS_IA.md portait un mot de passe SSH en
#      clair que la version Drive avait deja expurge. Publier sans scanner aurait
#      RE-INTRODUIT le secret dans le Drive.
#
# _index/ et _review/ sont exclus : artefacts internes du moteur (pagination,
# files de relecture), sans valeur dans le vault humain et tres bavards.
#
# IDEMPOTENCE : rclone ne transfere que ce qui differe. Un second passage sans
# nouvelle fiche ne transfere rien.
# REPRISE : rien n est jamais supprime en local. Drive indisponible => exit != 0,
# le marqueur de demande est repose, la publication est retentee au prochain
# declenchement. Aucune perte possible.
set -uo pipefail

SRC="${LLM_WIKI_SRC:-/srv/obsidian-vault/wiki}"
DEST="${LLM_WIKI_DEST:-gdrive:Obsidian Vault/wiki}"
STATE_DIR="${LLM_WIKI_STATE:-/var/lib/llm-wiki}"
REQUEST="${PUBLISH_REQUEST:-${STATE_DIR}/publish.request}"
PENDING="${PUBLISH_PENDING:-${STATE_DIR}/publish.pending}"
LAST_OK="${PUBLISH_LAST_OK:-${STATE_DIR}/publish.last-ok}"
DRY_RUN="${DRY_RUN:-0}"
# Parametrables pour les tests : le banc n a ni /run/lock accessible ni
# /usr/local/bin en ecriture.
SCANNER="${LLM_WIKI_SCANNER:-/usr/local/bin/llm_wiki_secret_scan.py}"
LOCK_FILE="${LLM_WIKI_LOCK:-/run/lock/vault-mirror.lock}"

log() { printf '[llm-wiki-publish] %s\n' "$*"; }
err() { printf '[llm-wiki-publish] %s\n' "$*" >&2; }

command -v rclone >/dev/null || { err "rclone absent"; exit 1; }
[ -d "$SRC" ] || { err "source absente : $SRC"; exit 1; }

# --------------------------------------------------------------- scan secrets
# Bloquant par conception. Un faux positif coute une publication reportee ;
# un faux negatif publie un secret sur Google Drive. L heuristique vit dans
# llm_wiki_secret_scan.py -- un grep suffisamment large pour attraper
# `Mot de passe : 2674` remonte 25 fiches de prose, donc plus personne ne le lit.
if ! python3 "$SCANNER" "$SRC"; then
    err "PUBLICATION BLOQUEE : secret en clair dans le tree moteur (voir ci-dessus)"
    : > "$PENDING"
    exit 3
fi

EXCLUDES=(
  --exclude "/_index/**"
  --exclude "/_review/**"
  --exclude "/.staging/**"
  --exclude "**/.DS_Store"
)
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
[ "$DRY_RUN" = "1" ] && TUNING+=(--dry-run)

# Verrou PARTAGE avec vault_mirror_sync.sh et vault_spool_push.sh : les trois
# touchent la meme arborescence Drive/miroir (adr/0020).
exec 9>"$LOCK_FILE"
if ! flock -w 1800 9; then
    err "verrou vault-mirror non obtenu"
    : > "$PENDING"
    exit 1
fi

# PAS de --backup-dir, et c est un choix mesure.
#
# Premiere tentative, 2026-09-06 17:05 : `--backup-dir` fait, pour chaque fiche
# a remplacer, un DEPLACEMENT server-side (instantane) puis un UPLOAD (lent).
# Sur 3319 fiches, les deplacements ont pris ~400 fiches d avance sur les
# uploads en huit minutes. Autrement dit : plusieurs centaines de notes
# ABSENTES de Drive pendant des heures, et vault-mirror-sync (toutes les 30 min)
# aurait propage ces absences dans le miroir, donc dans le RAG.
#
# La reversibilite ne se paie donc pas ici. Elle vient d ailleurs :
#   - /srv/vault-mirror/wiki EST deja une copie locale fidele de ce que Drive
#     contient ; c est la sauvegarde, et elle est gratuite ;
#   - `--update` protege ce qui est plus recent cote Drive ;
#   - `copy` ne supprime jamais rien.
# Sans --backup-dir, rclone ecrase en place : la fiche n est jamais absente.
#
# LLM_WIKI_BACKUP reste disponible pour une passe exceptionnelle ou l on
# accepte le trou en echange d une corbeille datee.
BACKUP=()
if [ -n "${LLM_WIKI_BACKUP:-}" ]; then
    BACKUP=(--backup-dir "${LLM_WIKI_BACKUP}/$(date -u +%Y%m%dT%H%M%SZ)")
    log "corbeille demandee : ${LLM_WIKI_BACKUP} (des notes seront absentes le temps du transfert)"
fi

log "publication ${SRC} -> ${DEST} (copy --update, dry-run=${DRY_RUN})"
if ! rclone copy "$SRC" "$DEST" --update "${BACKUP[@]+"${BACKUP[@]}"}" \
        "${EXCLUDES[@]}" "${TUNING[@]}"; then
    err "ECHEC rclone copy -- publication reportee, rien n est perdu en local"
    : > "$PENDING"
    exit 1
fi

rm -f "$PENDING" "$REQUEST"
date -u +%Y-%m-%dT%H:%M:%SZ > "$LAST_OK"
log "publication terminee : $(find "$SRC" -name '*.md' -not -path '*/_index/*' -not -path '*/_review/*' | wc -l) fiches candidates"
