#!/bin/bash
# Regression : une intention admin/reindex ne doit plus immobiliser la FIFO.
#
# Le 2026-09-06, `admin/reindex` appelait `systemctl start vault-reindex.service`
# SANS --no-block. Le pousseur etant le consumer UNIQUE de la file, il attendait
# la fin de la reindexation : 37 min 11 s mesures en production, et toutes les
# ecritures ordinaires deposees derriere attendaient avec lui.
#
# Ce test rejoue exactement ce scenario : une intention admin/reindex suivie
# d une ecriture normale, avec un faux `sudo` qui DORT si --no-block est absent.
# Si la regression revient, le test depasse le budget de temps et echoue.
set -uo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POUSSEUR="$RACINE/vault_spool_push.sh"
BAC="$(mktemp -d)"
trap 'rm -rf "$BAC"' EXIT

SPOOL="$BAC/spool"; MIROIR="$BAC/miroir"; STUBS="$BAC/stubs"
mkdir -p "$SPOOL"/{queue,done,failed,tmp} "$MIROIR" "$STUBS"

# --- doublures. `sudo` sans --no-block dort 30 s : c est la regression.
cat > "$STUBS/sudo" <<'STUB'
#!/bin/bash
for arg in "$@"; do [ "$arg" = "--no-block" ] && exec /bin/true; done
case "$*" in
  *systemd-run*) exit 0 ;;
  *vault-reindex*) sleep 30; exit 0 ;;
esac
exit 0
STUB
# `rclone` : toute la surface utilisee par les branches create/confirmation.
cat > "$STUBS/rclone" <<'STUB'
#!/bin/bash
case "${1:-}" in
  lsjson) [ "${2:-}" = "--hash" ] && echo '[{"Name":"x","Hashes":{"md5":"d41d8"}}]' || echo '[{"Name":"x"}]' ;;
  lsf)    : ;;
  copyto|moveto|mkdir|purge|delete) : ;;
esac
exit 0
STUB
chmod +x "$STUBS/sudo" "$STUBS/rclone"

intention() { # <id> <op> <path> [contenu_b64]
  local ts; ts=$(date +%s%N)
  cat > "$SPOOL/queue/${ts}-$1.json" <<JSON
{"id":"$1","version":1,"op":"$2","path":"$3","client_id":"test",
 "horodatage":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","contenu_b64":"${4:-}"}
JSON
  sleep 0.01
}

intention reindex01 "admin/reindex" "-"
intention write01   "create"        "notes/derriere-le-reindex.md" "$(printf 'contenu\n' | base64 -w0)"

debut=$(date +%s)
PATH="$STUBS:$PATH" VAULT_SPOOL="$SPOOL" VAULT_MIRROR="$MIROIR" \
  VAULT_LOCK="$BAC/verrou" VAULT_TRASH="$BAC/corbeille" \
  bash "$POUSSEUR" >"$BAC/sortie.log" 2>&1
duree=$(( $(date +%s) - debut ))

echec=0
verifier() { # <libelle> <condition-vraie>
  if eval "$2"; then echo "  ok   $1"; else echo "  ECHEC $1"; echec=1; fi
}

echo "resultat du rejeu (duree ${duree}s) :"
verifier "l admin/reindex ne bloque pas la file (< 10 s)" "[ $duree -lt 10 ]"
verifier "recu de l admin/reindex ecrit"      "[ -f '$SPOOL/done/reindex01.json' ]"
verifier "l ecriture derriere est appliquee"  "[ -f '$SPOOL/done/write01.json' ]"
verifier "la file est vidange"                "[ -z \"\$(ls -A '$SPOOL/queue')\" ]"
verifier "aucun echec"                        "[ -z \"\$(ls -A '$SPOOL/failed')\" ]"

# Idempotence : rejouer la meme file ne doit rien casser ni dupliquer.
intention reindex01 "admin/reindex" "-"
PATH="$STUBS:$PATH" VAULT_SPOOL="$SPOOL" VAULT_MIRROR="$MIROIR" \
  VAULT_LOCK="$BAC/verrou" VAULT_TRASH="$BAC/corbeille" \
  bash "$POUSSEUR" >>"$BAC/sortie.log" 2>&1
verifier "rejeu d une intention deja appliquee : sans effet" \
         "[ -z \"\$(ls -A '$SPOOL/queue')\" ] && [ -z \"\$(ls -A '$SPOOL/failed')\" ]"

if [ "$echec" -ne 0 ]; then sed 's/^/    | /' "$BAC/sortie.log"; fi
exit "$echec"
