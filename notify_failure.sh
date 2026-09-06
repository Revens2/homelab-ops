#!/bin/bash
# Notification Telegram d'echec d'une unite systemd.
# Usage : notify_failure.sh <unite> [--dry-run]
# Sort TOUJOURS en 0 : une notification qui echoue ne doit pas faire echouer autre chose.
set -uo pipefail

UNIT="${1:-inconnue}"
DRY="${2:-}"
MAXLEN=3800

redact() {
    sed -E -e 's#(bot)?[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}#<REDACTED_TG_TOKEN>#g' \
           -e 's#(Bearer|Authorization:)[[:space:]]*[A-Za-z0-9._~+/=-]{16,}#\1 <REDACTED>#gI' \
           -e 's#(ya29\.|AIza|sk-|ghp_|gho_|xox[baprs]-)[A-Za-z0-9._~+/=-]{10,}#<REDACTED_KEY>#g' \
           -e 's#(password|passwd|secret|token|api[_-]?key)([[:space:]]*[:=][[:space:]]*)[^[:space:],;]+#\1\2<REDACTED>#gI'
}
esc_html() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

RESULT=$(systemctl show "$UNIT" -p Result --value 2>/dev/null)
CODE=$(systemctl show "$UNIT" -p ExecMainStatus --value 2>/dev/null)
WHEN=$(systemctl show "$UNIT" -p ExecMainExitTimestamp --value 2>/dev/null)
LOG=$(journalctl -u "$UNIT" -n 20 --no-pager -o cat 2>/dev/null | redact | esc_html)

# L'en-tete est compose en premier et n'est JAMAIS tronque.
HEADER="❌ <b>Echec d'unite</b>
<b>Unite</b>  : $(printf '%s' "$UNIT" | esc_html)
<b>Resultat</b>: ${RESULT:-?}  (code ${CODE:-?})
<b>Quand</b>  : ${WHEN:-?}
<b>Hote</b>   : $(hostname)"

AVAIL=$(( MAXLEN - ${#HEADER} - 40 ))
[ "$AVAIL" -lt 200 ] && AVAIL=200
if [ "${#LOG}" -gt "$AVAIL" ]; then
    # troncature sur une frontiere de ligne
    LOG=$(printf '%s' "${LOG:0:$AVAIL}" | sed '$d')
    LOG="${LOG}
… (journal tronque — journalctl -u ${UNIT} -n 100)"
fi

BODY="${HEADER}

<pre>${LOG}</pre>"

if [ "$DRY" = "--dry-run" ]; then
    printf '%s\n' "$BODY"
    exit 0
fi

TG_PARSE_MODE=HTML TG_PERSIST=1 /usr/local/bin/send_telegram.sh "$BODY" || true
exit 0
