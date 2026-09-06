#!/bin/bash
# Regression : une panne Drive ne doit RIEN faire perdre.
#
# Le pont llm_wiki_publish.sh est le dernier saut de la chaine : sans lui, une
# fiche produite par le moteur n arrive jamais dans le RAG. Il pousse vers un
# service distant, donc il echouera un jour. Ce qu on exige alors :
#   1. la fiche locale est intacte -- on ne DEPLACE jamais, on COPIE ;
#   2. un marqueur `publish.pending` est pose ;
#   3. le marqueur de demande `publish.request` n est PAS consomme, donc le
#      .path unit reste arme et la publication est retentee ;
#   4. quand Drive revient, la publication reussit et les deux marqueurs
#      disparaissent.
#
# Le test n appelle pas Google : un faux `rclone` en tete de PATH simule la
# panne puis le retour a la normale.
set -uo pipefail

SCRIPT="${SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/llm_wiki_publish.sh}"
SCANNER="${SCANNER:-$(cd "$(dirname "$0")/.." && pwd)/llm_wiki_secret_scan.py}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ECHECS=0
ok()  { printf '  ok   %s\n' "$*"; }
ko()  { printf '  KO   %s\n' "$*"; ECHECS=$((ECHECS+1)); }

# --- arborescence de test
SRC="$TMP/wiki"; STATE="$TMP/state"
mkdir -p "$SRC/sources" "$STATE" "$TMP/bin"
printf -- '---\ntitle: canary\n---\n# canary\ncontenu unique de test\n' \
    > "$SRC/sources/canary-panne-drive.md"
EMPREINTE="$(sha256sum "$SRC/sources/canary-panne-drive.md" | cut -d' ' -f1)"

# --- faux rclone : echoue tant que $TMP/drive-up n existe pas
cat > "$TMP/bin/rclone" <<'FAUX'
#!/bin/bash
if [ ! -f "$FAUX_DRIVE_UP" ]; then
    echo "Failed to copy: googleapi: Error 503: Service Unavailable" >&2
    exit 1
fi
echo "faux rclone : transfert accepte"
exit 0
FAUX
chmod +x "$TMP/bin/rclone"

# Le scanner de secrets est reel : on veut aussi verifier qu il laisse passer
# une fiche propre.
mkdir -p "$TMP/run"
export PATH="$TMP/bin:$PATH"
export FAUX_DRIVE_UP="$TMP/drive-up"

lancer() {
    LLM_WIKI_SRC="$SRC" \
    LLM_WIKI_DEST="faux:cible" \
    LLM_WIKI_STATE="$STATE" \
    LLM_WIKI_SCANNER="$SCANNER" \
    LLM_WIKI_LOCK="$TMP/run/test.lock" \
    PUBLISH_REQUEST="$STATE/publish.request" \
    PUBLISH_PENDING="$STATE/publish.pending" \
    PUBLISH_LAST_OK="$STATE/publish.last-ok" \
    bash "$SCRIPT" 2>&1
}

echo "== 1. Drive indisponible =="
: > "$STATE/publish.request"
SORTIE="$(lancer)"; RC=$?

[ "$RC" -ne 0 ] && ok "sortie non nulle ($RC)" || ko "le script a rendu 0 malgre l echec Drive"
[ -f "$SRC/sources/canary-panne-drive.md" ] \
    && ok "fiche locale toujours presente" || ko "fiche locale disparue"
[ "$(sha256sum "$SRC/sources/canary-panne-drive.md" | cut -d' ' -f1)" = "$EMPREINTE" ] \
    && ok "fiche locale inchangee" || ko "fiche locale modifiee"
[ -f "$STATE/publish.pending" ] \
    && ok "marqueur pending pose" || ko "marqueur pending absent"
[ -f "$STATE/publish.request" ] \
    && ok "demande NON consommee : la publication sera retentee" \
    || ko "demande consommee malgre l echec -- le .path ne se rearmera pas"
printf '%s\n' "$SORTIE" | grep -q "reportee" \
    && ok "message d echec explicite" || ko "echec silencieux"

echo "== 2. Drive revenu =="
: > "$FAUX_DRIVE_UP"
SORTIE="$(lancer)"; RC=$?

[ "$RC" -eq 0 ] && ok "sortie 0" || ko "echec alors que Drive repond ($RC)"
[ ! -f "$STATE/publish.pending" ] \
    && ok "marqueur pending leve" || ko "pending encore la apres succes"
[ ! -f "$STATE/publish.request" ] \
    && ok "demande consommee" || ko "demande non consommee apres succes"
[ -s "$STATE/publish.last-ok" ] \
    && ok "horodatage de derniere publication ecrit" || ko "last-ok absent"

echo "== 3. Secret en clair : publication bloquee AVANT tout transfert =="
printf 'Mot de passe : 2674\n' >> "$SRC/sources/canary-panne-drive.md"
SORTIE="$(lancer)"; RC=$?
[ "$RC" -eq 3 ] && ok "sortie 3 (secret detecte)" || ko "secret non bloquant (rc=$RC)"
printf '%s\n' "$SORTIE" | grep -q "BLOQUEE" \
    && ok "message de blocage explicite" || ko "blocage silencieux"

echo
if [ "$ECHECS" -eq 0 ]; then
    echo "test_publish_panne_drive : OK"
    exit 0
fi
echo "test_publish_panne_drive : $ECHECS echec(s)"
exit 1
