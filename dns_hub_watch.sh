#!/bin/bash
# Surveillance de la chaine DNS du hub : Pi-hole -> Unbound -> dnsproxy (DoH).
# - teste chaque maillon separement pour pointer le fautif
# - tente une reparation automatique ciblee du maillon defaillant
# - n'alerte que sur CHANGEMENT d'etat (pas de spam toutes les 5 min)
set -u

STATE_DIR="/var/lib/dns_hub_watch"
STATE_FILE="$STATE_DIR/state"
LOG="/var/log/dns_hub_watch.log"
TG="/usr/local/bin/send_telegram.sh"
PROBE="cloudflare.com"
BLOCKED="doubleclick.net"

mkdir -p "$STATE_DIR"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Renvoie 0 si le resolveur repond une adresse pour $PROBE
probe() { # $1=ip  $2=port
    local out
    out=$(dig @"$1" -p "$2" "$PROBE" +short +time=2 +tries=2 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    [ -n "$out" ]
}

FAILED=""

probe 127.0.0.1 5353 || FAILED="$FAILED dnsproxy(DoH:5353)"
probe 127.0.0.1 5335 || FAILED="$FAILED unbound(5335)"
probe 127.0.0.1 53   || FAILED="$FAILED pihole(53)"

REPAIR=""

# 1. Reparation ciblee dnsproxy si defaillant
if echo "$FAILED" | grep -q "dnsproxy"; then
    log "dnsproxy KO, tentative de redemarrage du service"
    systemctl restart dnsproxy 2>/dev/null
    sleep 2
    if probe 127.0.0.1 5353; then
        REPAIR="$REPAIR (dnsproxy redemarre)"
        FAILED=$(echo "$FAILED" | sed 's/ dnsproxy(DoH:5353)//')
        log "dnsproxy repare"
    fi
fi

# 2. Reparation ciblee unbound si defaillant alors que dnsproxy est OK
if echo "$FAILED" | grep -q "unbound" && ! echo "$FAILED" | grep -q "dnsproxy"; then
    log "unbound KO, tentative de redemarrage du service"
    systemctl restart unbound 2>/dev/null
    sleep 2
    if probe 127.0.0.1 5335; then
        REPAIR="$REPAIR (unbound redemarre)"
        FAILED=$(echo "$FAILED" | sed 's/ unbound(5335)//')
        log "unbound repare"
    fi
fi

# 3. Reparation ciblee Pi-hole uniquement si amont (dnsproxy + unbound) OK mais pihole KO
if echo "$FAILED" | grep -q "pihole" && ! echo "$FAILED" | grep -qE "dnsproxy|unbound"; then
    log "Pi-hole seul KO, tentative de redemarrage du conteneur"
    docker restart pihole >/dev/null 2>&1
    sleep 10
    if probe 127.0.0.1 53; then
        REPAIR="$REPAIR (pihole redemarre)"
        FAILED=$(echo "$FAILED" | sed 's/ pihole(53)//')
        log "Pi-hole repare"
    else
        log "Pi-hole toujours KO apres redemarrage"
    fi
fi

# Le filtrage repond-il encore ? (doit renvoyer 0.0.0.0)
if [ -z "$FAILED" ]; then
    BLK=$(dig @127.0.0.1 -p 53 "$BLOCKED" +short +time=2 +tries=2 2>/dev/null | head -1)
    [ "$BLK" = "0.0.0.0" ] || FAILED="$FAILED filtrage(gravity)"
fi

if [ -z "$FAILED" ]; then NEW="OK"; else NEW="KO:$FAILED"; fi
OLD=$(cat "$STATE_FILE" 2>/dev/null || echo "OK")
echo "$NEW" > "$STATE_FILE"

if [ "$NEW" = "$OLD" ]; then
    log "etat inchange ($NEW)"
    exit 0
fi

if [ "$NEW" = "OK" ]; then
    log "RETABLI"
    "$TG" "✅ *DNS hub retabli* — le serveur
La resolution DNS du reseau NetBird refonctionne.$REPAIR"
else
    log "PANNE: $FAILED"
    "$TG" "🚨 *DNS hub en panne* — le serveur
Maillons KO :$FAILED

Les appareils du reseau NetBird peuvent perdre la resolution DNS.
Echappatoire sur le client :
\`netbird up --disable-dns\`"
fi
