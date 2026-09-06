#!/bin/bash
# Regression : le pousseur du spool doit ceder le verrou a vault-mirror-sync.
#
# `flock` n est pas equitable. vault_spool_push.sh est declenche par un .path a
# chaque intention deposee et par un timer toutes les ~13 s ; quand la tache
# ChatGPT produit des analyses en rafale, ces passages courts se re-servent en
# boucle et la synchro du miroir attend derriere.
#
# Mesure du 2026-09-06 : run de vault-mirror-sync demarre a 19:00:56, verrou
# obtenu a 19:57:33 -- 56 min 37 s pour un `-w 3600`. A 3 min 23 s de
# l expiration. Au-dela, le miroir echoue, alerte sur Telegram, et le RAG reste
# en retard jusqu au passage suivant.
#
# Le correctif : la synchro pose un TICKET avant de se mettre en attente ; le
# pousseur le regarde entre deux intentions et rend la main. Aucune ecriture
# concurrente n est introduite -- le verrou continue de serialiser tout le monde.
#
# Ce que le test exige :
#   1. ticket frais  -> le pousseur s arrete apres UNE intention, le reste de la
#      file est intact (rien n est perdu : le declenchement suivant le reprend) ;
#   2. ticket perime -> ignore, la file est vidangee normalement. Sans cette
#      regle, un ticket oublie par une synchro tuee ferait ceder le pousseur
#      apres chaque intention, indefiniment ;
#   3. pas de ticket -> comportement d origine, file vidangee.
set -uo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POUSSEUR="$RACINE/vault_spool_push.sh"
BAC="$(mktemp -d)"
trap 'rm -rf "$BAC"' EXIT

SPOOL="$BAC/spool"; MIROIR="$BAC/miroir"; STUBS="$BAC/stubs"
TICKET="$BAC/vault-mirror.wanted"
mkdir -p "$SPOOL"/{queue,done,failed,tmp} "$MIROIR" "$STUBS"

cat > "$STUBS/sudo" <<'STUB'
#!/bin/bash
exit 0
STUB
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

intention() { # <id> <chemin>
  local ts; ts=$(date +%s%N)
  cat > "$SPOOL/queue/${ts}-$1.json" <<JSON
{"id":"$1","version":1,"op":"create","path":"$2","client_id":"test",
 "horodatage":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","contenu_b64":"$(printf 'x\n' | base64 -w0)"}
JSON
  sleep 0.01
}

lancer() {
  PATH="$STUBS:$PATH" VAULT_SPOOL="$SPOOL" VAULT_MIRROR="$MIROIR" \
    VAULT_LOCK="$BAC/verrou" VAULT_TRASH="$BAC/corbeille" \
    VAULT_LOCK_WANTED="$TICKET" \
    bash "$POUSSEUR" >>"$BAC/sortie.log" 2>&1
}

echec=0
verifier() { if eval "$2"; then echo "  ok   $1"; else echo "  ECHEC $1"; echec=1; fi; }
en_file() { ls -1 "$SPOOL/queue" 2>/dev/null | wc -l; }

echo "== 1. ticket frais : le pousseur cede apres une intention =="
intention a01 "notes/a01.md"; intention a02 "notes/a02.md"; intention a03 "notes/a03.md"
: > "$TICKET"
lancer
verifier "une seule intention traitee"        "[ -f '$SPOOL/done/a01.json' ]"
verifier "deux intentions restent en file"    "[ \$(en_file) -eq 2 ]"
verifier "aucun echec"                        "[ -z \"\$(ls -A '$SPOOL/failed')\" ]"
verifier "cession tracee dans le journal"     "grep -q 'cession du verrou' '$BAC/sortie.log'"

echo "== 2. le declenchement suivant reprend le reste =="
rm -f "$TICKET"
lancer
verifier "file vidangee"                      "[ \$(en_file) -eq 0 ]"
verifier "les trois intentions appliquees"    "[ -f '$SPOOL/done/a02.json' ] && [ -f '$SPOOL/done/a03.json' ]"
verifier "toujours aucun echec"               "[ -z \"\$(ls -A '$SPOOL/failed')\" ]"

echo "== 3. ticket perime : ignore, pas de cession perpetuelle =="
intention b01 "notes/b01.md"; intention b02 "notes/b02.md"
: > "$TICKET"
touch -d "-40 minutes" "$TICKET"
lancer
verifier "file vidangee malgre le ticket"     "[ \$(en_file) -eq 0 ]"
verifier "les deux intentions appliquees"     "[ -f '$SPOOL/done/b01.json' ] && [ -f '$SPOOL/done/b02.json' ]"

echo "== 4. sans ticket : comportement d origine =="
intention c01 "notes/c01.md"; intention c02 "notes/c02.md"
rm -f "$TICKET"
lancer
verifier "file vidangee"                      "[ \$(en_file) -eq 0 ]"
verifier "aucun echec"                        "[ -z \"\$(ls -A '$SPOOL/failed')\" ]"

echo
if [ "$echec" -eq 0 ]; then echo "test_flock_cession_sync : OK"; exit 0; fi
echo "test_flock_cession_sync : ECHEC"; exit 1
