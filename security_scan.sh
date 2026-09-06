#!/bin/bash

TARGET_LOG="/var/log/security_scan.log"
echo "=== Security Scan Start: $(date) ===" > "$TARGET_LOG"

# Update RKHunter definitions
echo "--- Updating RKHunter Definitions ---" >> "$TARGET_LOG"
rkhunter --update >> "$TARGET_LOG" 2>&1
RK_UPDATE_STATUS=$?
# 2026-08-13 : ce code retour n'etait PAS capture. Un update casse (c'etait le cas depuis
# des mois : MIRRORS_MODE=1 sans miroir local eligible) restait totalement silencieux.
# rkhunter etant le seul controle d'integrite depuis la purge de ClamAV, c'etait un point
# de defaillance unique invisible.

mkdir -p /home /tmp

echo "--- Running RKHunter Scan ---" >> "$TARGET_LOG"
rkhunter --check --sk >> "$TARGET_LOG" 2>&1
RK_STATUS=$?

# --- Volet antivirus RETIRE le 2026-08-13 (decision utilisateur) ---
# La stack ClamAV (daemon, freshclam, scanner) a ete purgee : le daemon consommait
# 1 007 Mo de RSS en permanence et freshclam etait inactif, donc les signatures etaient
# de toute facon perimees. RKHunter reste le SEUL controle d'integrite de cette machine.
# Perte de couverture assumee : plus aucune detection antivirale sur /home et /tmp.
# Voir journal/2026-08.md et reference/services.md.

echo "=== Security Scan End: $(date) ===" >> "$TARGET_LOG"

THREAT_DETECTED=0
ALERT_MSG="⚠️ *Alerte de Sécurité VPS (audit)* ⚠️

"

# 0. Pannes d'infrastructure du scan lui-meme.
# Distinction volontaire : une DETECTION (warnings rkhunter) part par le canal Telegram
# applicatif ci-dessous ; une PANNE du scan fait sortir le script en code non nul, ce qui
# declenche OnFailure=notify-failure@security-scan.service. Un scan casse doit alerter
# aussi fort qu'une menace : il ne detecte plus rien.
INFRA_FAILURE=0
INFRA_MSG=""
if [ "${RK_UPDATE_STATUS:-0}" -ne 0 ]; then
    INFRA_FAILURE=1
    INFRA_MSG="${INFRA_MSG}rkhunter --update a echoue (code ${RK_UPDATE_STATUS}). "
fi
# rkhunter : 0 = RAS, 1 = warnings (= detection, traitee plus bas), >=2 = ERREUR.
# L'ancienne condition excluait explicitement le code 2 : une vraie erreur rkhunter
# passait pour une absence de menace. Corrige le 2026-08-13.
if [ "$RK_STATUS" -ge 2 ]; then
    INFRA_FAILURE=1
    INFRA_MSG="${INFRA_MSG}rkhunter --check a renvoye une erreur (code ${RK_STATUS}). "
fi

# 1. RKHunter Details
if [ $RK_STATUS -ne 0 ] && [ $RK_STATUS -ne 2 ]; then
    THREAT_DETECTED=1
    ALERT_MSG="${ALERT_MSG}❌ *Rootkits / Anomalies (RKHunter) :*
- Code retour: $RK_STATUS
"
    RK_WARNINGS=$(grep 'Warning:' /var/log/rkhunter.log 2>/dev/null | tail -n 5)
    if [ -n "$RK_WARNINGS" ]; then
        ALERT_MSG="${ALERT_MSG}Dernières alertes RKHunter:
\`\`\`
$RK_WARNINGS
\`\`\`
"
    fi
fi

# 2. (ancien volet antivirus) — retire le 2026-08-13, voir plus haut.
#    Les variables de statut et de sortie du scanner n'existent plus : ne pas les
#    reintroduire sans reinstaller la stack, sinon un test sur variable vide casserait
#    le scan chaque nuit.

# 3. J-7 update check
UPDATE_STATUS=$(cat /var/log/unattended_upgrades_status.log 2>/dev/null || echo 0)
if [ "$UPDATE_STATUS" -ne 0 ]; then
    THREAT_DETECTED=1
    ALERT_MSG="${ALERT_MSG}❌ *Mises à jour système*
- Échec de la mise à jour automatique J-7 (Code retour: $UPDATE_STATUS)
"
fi

# Send alert or positive confirmation report
echo "--- Sending Telegram Report ---" >> "$TARGET_LOG"
STATE_FILE="/var/lib/security_scan.state"
if [ $THREAT_DETECTED -eq 1 ]; then
    SIG="$(printf '%s' "$ALERT_MSG" | sed -E 's/[0-9a-f]{16,}//g; s/[0-9]+/N/g' | sha256sum | cut -d' ' -f1)"
else
    SIG="CLEAN"
fi
PREV=""; [ -r "$STATE_FILE" ] && PREV="$(cut -d' ' -f1 "$STATE_FILE" 2>/dev/null)"
mkdir -p "$(dirname "$STATE_FILE")"
printf '%s %s\n' "$SIG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_FILE"
if [ "$SIG" = "$PREV" ]; then
    echo "Etat securite INCHANGE (sig=${SIG:0:12}); pas d'alerte Telegram." >> "$TARGET_LOG"
elif [ $THREAT_DETECTED -eq 1 ]; then
    /usr/local/bin/send_telegram.sh "$ALERT_MSG" >> "$TARGET_LOG" 2>&1
    echo "Telegram Send (Threats Alert) exit code: $?" >> "$TARGET_LOG"
elif [ -n "$PREV" ] && [ "$PREV" != "CLEAN" ]; then
    /usr/local/bin/send_telegram.sh "✅ VPS audit ($(hostname)): retour à la normale, plus aucune menace détectée." >> "$TARGET_LOG" 2>&1
    echo "Telegram Send (Recovery) exit code: $?" >> "$TARGET_LOG"
else
    echo "No threats detected. Skipping Telegram alert." >> "$TARGET_LOG"
fi

# Sortie non nulle en cas de panne du scan -> systemd declenche
# OnFailure=notify-failure@security-scan.service -> Telegram.
# Placee AVANT le heartbeat pour que celui-ci ne masque pas la panne... non :
# le heartbeat doit partir quand meme, l'exit est donc en toute fin de fichier.

# Push Heartbeat Uptime Kuma
if [ $THREAT_DETECTED -eq 0 ]; then
    curl -fsS "http://198.51.100.10:3001/api/push/security-scan-push-token?status=up&msg=OK" >/dev/null 2>&1 || true
else
    curl -fsS "http://198.51.100.10:3001/api/push/security-scan-push-token?status=down&msg=ThreatDetected" >/dev/null 2>&1 || true
fi

if [ "$INFRA_FAILURE" -eq 1 ]; then
    echo "PANNE DU SCAN : $INFRA_MSG" >> "$TARGET_LOG"
    logger -t security-scan "PANNE: $INFRA_MSG"
    exit 1
fi
exit 0
