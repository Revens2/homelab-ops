#!/usr/bin/env bash
# netbird-staged-update.sh — mise a jour echelonnee du client NetBird sur un parc HA.
#
# Deux roles :
#   primary   : met a jour immediatement, puis publie son etat de sante.
#   secondary : ne met a jour QUE si le primaire est sain, vu depuis ce noeud.
#
# Le secondaire ne se connecte jamais au primaire par SSH : il juge sa sante
# depuis sa propre vue du reseau (joignabilite par wt0 + DNS + peer connecte).
# Aucun credential a distribuer.
#
# Config : /etc/default/netbird-staged-update
# Journal : journalctl -u netbird-staged-update

set -uo pipefail

CONF=/etc/default/netbird-staged-update
[ -r "$CONF" ] && . "$CONF"

ROLE="${ROLE:-secondary}"            # primary | secondary
PEER_IP="${PEER_IP:-}"               # IP NetBird du primaire (requis si secondary)
DNS_PROBE="${DNS_PROBE:-example.com}"
DNS_SERVER="${DNS_SERVER:-}"         # IP NetBird du Pi-hole ; vide = pas de test DNS
STATE_DIR="${STATE_DIR:-/var/lib/netbird-staged-update}"
DRY_RUN="${DRY_RUN:-0}"              # 1 = tout verifier, ne rien installer

STATE_FILE="$STATE_DIR/last-run"
mkdir -p "$STATE_DIR"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
fail() { log "ECHEC: $*"; printf 'FAILED %s %s\n' "$(date -Is)" "$*" > "$STATE_FILE"; exit 1; }

# --- Sante locale -----------------------------------------------------------
# Les deux controles (unite systemd ET interface) sont obligatoires : ils
# divergent, et cette divergence a deja cause deux coupures totales.
check_local() {
    local ctx="$1"

    systemctl is-active --quiet netbird \
        || { log "[$ctx] netbird.service inactif"; return 1; }

    ip link show wt0 >/dev/null 2>&1 \
        || { log "[$ctx] interface wt0 absente"; return 1; }

    ip link show wt0 | grep -q 'state UNKNOWN\|state UP' \
        || { log "[$ctx] wt0 presente mais pas UP"; return 1; }

    netbird status 2>/dev/null | grep -qi 'Management: Connected' \
        || { log "[$ctx] NetBird non connecte au management"; return 1; }

    # Controle Tailscale retire le 2026-08-29 : Tailscale purge du parc, NetBird seul en place.

    log "[$ctx] sante locale OK"
    return 0
}

# --- Sante du pair ----------------------------------------------------------
check_peer() {
    [ -n "$PEER_IP" ] || fail "PEER_IP non defini alors que ROLE=secondary"

    ping -c 3 -W 2 -I wt0 "$PEER_IP" >/dev/null 2>&1 \
        || { log "pair $PEER_IP injoignable par wt0"; return 1; }

    netbird status --detail 2>/dev/null | grep -q "$PEER_IP" \
        || { log "pair $PEER_IP absent de netbird status"; return 1; }

    if [ -n "$DNS_SERVER" ]; then
        dig "@$DNS_SERVER" +short +time=3 +tries=2 "$DNS_PROBE" >/dev/null 2>&1 \
            || { log "resolution DNS via $DNS_SERVER en echec"; return 1; }
    fi

    log "pair $PEER_IP sain"
    return 0
}

# --- Mise a jour ------------------------------------------------------------
do_update() {
    local before after
    before="$(netbird version 2>/dev/null || echo inconnue)"

    if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN=1 — mise a jour non executee (version courante: $before)"
        return 0
    fi

    log "mise a jour depuis la version $before"
    apt-get update -qq || fail "apt-get update"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade netbird \
        || fail "apt-get install --only-upgrade netbird"

    systemctl restart netbird || fail "systemctl restart netbird"

    # Laisser le tunnel se retablir avant de juger.
    sleep 20

    after="$(netbird version 2>/dev/null || echo inconnue)"
    log "version apres mise a jour: $after"
}

# --- Deroulement ------------------------------------------------------------
log "demarrage, role=$ROLE"

case "$ROLE" in
    primary)
        check_local "avant" || fail "sante locale degradee avant mise a jour"
        do_update
        check_local "apres" || fail "sante locale degradee APRES mise a jour — rollback manuel requis"
        ;;

    secondary)
        check_local "avant" || fail "sante locale degradee avant mise a jour"
        check_peer        || fail "primaire non sain — mise a jour du secondaire annulee"
        do_update
        check_local "apres" || fail "sante locale degradee APRES mise a jour — rollback manuel requis"
        check_peer        || log "AVERTISSEMENT: pair injoignable apres mise a jour locale"
        ;;

    *)
        fail "ROLE inconnu: $ROLE (attendu: primary | secondary)"
        ;;
esac

printf 'OK %s role=%s version=%s\n' \
    "$(date -Is)" "$ROLE" "$(netbird version 2>/dev/null || echo inconnue)" > "$STATE_FILE"
log "termine sans erreur"
