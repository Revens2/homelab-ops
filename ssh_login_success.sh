#!/bin/bash
[ "$PAM_SERVICE" = "sshd" ] || exit 0
[ "$PAM_TYPE" = "open_session" ] || exit 0

logger -t ssh_login_success "SSH login: user=$PAM_USER from=$PAM_RHOST tty=$PAM_TTY"

STATE_DIR="/var/lib/ssh_notify"
mkdir -p "$STATE_DIR" 2>/dev/null
KNOWN_FILE="$STATE_DIR/known_ips"
IP="$PAM_RHOST"
USER="$PAM_USER"
LAST_NOTIF_FILE="$STATE_DIR/last_notif_${USER}"

NOW=$(date +%s)
COOLDOWN=900

if [ -f "$LAST_NOTIF_FILE" ]; then
    LAST_TIME=$(cat "$LAST_NOTIF_FILE" 2>/dev/null || echo 0)
    DIFF=$((NOW - LAST_TIME))
    if [ $DIFF -lt $COOLDOWN ]; then
        logger -t ssh_login_success "User $USER notification suppressed (cooldown $DIFF/$COOLDOWN sec)"
        exit 0
    fi
fi

FAILS=$(journalctl -u ssh -u sshd --since "-10 minutes" --no-pager 2>/dev/null \
    | grep -Ec "(Failed [a-z]+ for|Invalid user|authentication failure).*(from )?${IP}\b")

DATE_PARIS=$(TZ="Europe/Paris" date "+%d/%m/%Y à %H:%M:%S")
# Nom du pair NetBird correspondant a l IP source.
# "netbird status -d" liste chaque pair sous la forme :
#   <fqdn>:
#     NetBird IP: <ip>
# Il faut donc memoriser le nom puis le rendre quand la ligne "NetBird IP:"
# correspond -- format different de l ancien "Tailscale status" (ip et nom sur
# la meme ligne).
NB_NAME=$(netbird status -d 2>/dev/null | awk -v ip="$IP" '
    /^ [^ ].*:$/          { name=$1; sub(/:$/,"",name); sub(/\.netbird\.selfhosted$/,"",name); next }
    /^  NetBird IPv?6?: / { if ($3 == ip) { print name; exit } }
')
[ -z "$NB_NAME" ] && NB_NAME="hors-netbird"
if [[ "$PAM_TTY" =~ ^pts/ ]]; then TYPE="Humain (terminal)"; else TYPE="Agent/script (non-interactif)"; fi

if [ "${FAILS:-0}" -gt 0 ]; then
    MSG="🚨 Connexion SSH réussie après ${FAILS} tentative(s) échouée(s)
Utilisateur : ${USER}
Date (Paris) : ${DATE_PARIS}
Appareil : ${NB_NAME} (${IP})
Session : ${TYPE} — TTY ${PAM_TTY}"
else
    if grep -qxF "$IP" "$KNOWN_FILE" 2>/dev/null; then
        MSG="🟢 Connexion SSH réussie
Utilisateur : ${USER}
Date (Paris) : ${DATE_PARIS}
Appareil : ${NB_NAME} (${IP})
Session : ${TYPE}"
    else
        echo "$IP" >> "$KNOWN_FILE"
        MSG="🟢 Nouvelle IP SSH enregistrée
Utilisateur : ${USER}
Date (Paris) : ${DATE_PARIS}
Appareil : ${NB_NAME} (${IP})
Session : ${TYPE}"
    fi
fi

/usr/local/bin/send_telegram.sh "$MSG"
echo "$NOW" > "$LAST_NOTIF_FILE"
exit 0
