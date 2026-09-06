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
# ROLLBACK AUTOMATIQUE (depuis 2026-09-06) :
#   NetBird porte l'acces reseau du VPS : un echec de sante apres upgrade ne doit
#   pas laisser l'operateur sans acces. AVANT toute modification, le script
#   s'assure qu'un .deb de la version courante est disponible LOCALEMENT
#   (jamais de telechargement apres que NetBird soit casse). Si les controles
#   post-upgrade echouent, il reinstalle automatiquement cette version depuis le
#   cache local, redemarre et revalide.
#
# Config : /etc/default/netbird-staged-update
# Journal : journalctl -u netbird-staged-update

set -uo pipefail

CONF="${CONF:-/etc/default/netbird-staged-update}"
# CONF surchargeable (les tests pointent vers une config isolee).
[ -r "$CONF" ] && . "$CONF"

ROLE="${ROLE:-secondary}"            # primary | secondary
PEER_IP="${PEER_IP:-}"               # IP NetBird du primaire (requis si secondary)
DNS_PROBE="${DNS_PROBE:-example.com}"
DNS_SERVER="${DNS_SERVER:-}"         # IP NetBird du Pi-hole ; vide = pas de test DNS
STATE_DIR="${STATE_DIR:-/var/lib/netbird-staged-update}"
ROLLBACK_DIR="${ROLLBACK_DIR:-$STATE_DIR/rollback}"
DRY_RUN="${DRY_RUN:-0}"              # 1 = tout verifier, ne rien installer
APT_OPTS="${APT_OPTS:-}"              # options supplementaires pour apt-get install

STATE_FILE="$STATE_DIR/last-run"
PAQUET="netbird"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"

mkdir -p "$STATE_DIR" "$ROLLBACK_DIR"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# Chemin du .deb local de rollback, rempli par preparer_rollback (jamais de
# command substitution sur stdout : le log et le resultat ne doivent pas se
# melanger).
ROLLBACK_CHEMIN=""

# Ecrit l'etat final : premier mot = statut machine-lisible.
# Statuts : OK | ROLLED_BACK | FAILED | CRITICAL_ROLLBACK_FAILED
ecrire_statut() {
    local statut="$1" detail="$2"
    printf '%s %s role=%s version=%s detail=%s\n' \
        "$statut" "$(date -Is)" "$ROLE" \
        "$(netbird version 2>/dev/null || echo inconnue)" "$detail" > "$STATE_FILE"
}

fail() { log "ECHEC: $*"; ecrire_statut FAILED "$*"; exit 1; }

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

# --- Rollback : cache local de la version courante ---------------------------
# Le .deb de la version INSTALLEE doit exister sur disque AVANT la mise a jour :
# le rollback ne doit jamais dependre d'Internet une fois NetBird casse.
preparer_rollback() {
    local avant="$1"
    local deb_cherche="netbird_${avant}_${ARCH}.deb"

    # 1. Deja en cache (run precedent ou apt) ? (globe HORS guillemets :
    #    c'est le shell qui l'expand, ls recoit des noms de fichiers reels)
    local candidat
    candidat="$(ls "$ROLLBACK_DIR"/"$deb_cherche" "$STATE_DIR"/"$deb_cherche" \
        /var/cache/apt/archives/"$deb_cherche" 2>/dev/null | head -1)"

    # 2. Sinon, telecharger MAINTENANT (NetBird encore fonctionnel), depuis les
    #    listes apt actuelles. Echec => on refuse d'aller plus loin.
    if [ -z "$candidat" ]; then
        log "rollback : aucun .deb local de $avant — telechargement prealable"
        if [ "$DRY_RUN" = "1" ]; then
            log "DRY_RUN=1 — telechargement non execute"
            return 0
        fi
        if (cd "$ROLLBACK_DIR" && apt-get download "${PAQUET}=${avant}"); then
            candidat="$(ls "$ROLLBACK_DIR"/"$deb_cherche" 2>/dev/null | head -1)"
        fi
    fi

    if [ -z "$candidat" ]; then
        log "rollback : paquet $deb_cherche indisponible localement"
        return 1
    fi

    # Copie de securite dans le repertoire dedie (a l'abri d'apt-get clean).
    if [ "$(dirname "$candidat")" != "$ROLLBACK_DIR" ]; then
        cp -a "$candidat" "$ROLLBACK_DIR/$deb_cherche" 2>/dev/null \
            || { log "rollback : copie vers $ROLLBACK_DIR impossible"; return 1; }
        candidat="$ROLLBACK_DIR/$deb_cherche"
    fi

    ROLLBACK_CHEMIN="$candidat"
    log "rollback pret : $ROLLBACK_CHEMIN"
}

effectuer_rollback() {
    local cible="$1"   # chemin du .deb local de la version d'avant

    log "ROLLBACK automatique vers $cible"
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN=1 — rollback non execute"
        return 1
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
        $APT_OPTS "$cible" || return 1

    systemctl restart netbird || return 1
    sleep 20

    local apres
    apres="$(netbird version 2>/dev/null || echo inconnue)"
    log "version apres rollback: $apres"
    return 0
}

# --- Mise a jour ------------------------------------------------------------
do_update() {
    local avant="$1" apres
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN=1 — mise a jour non executee (version courante: $avant)"
        return 0
    fi

    log "mise a jour depuis la version $avant"
    apt-get update -qq || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
        $APT_OPTS "$PAQUET" || return 1

    systemctl restart netbird || return 1

    # Laisser le tunnel se retablir avant de juger.
    sleep 20

    apres="$(netbird version 2>/dev/null || echo inconnue)"
    log "version apres mise a jour: $apres"
    return 0
}

# --- Deroulement ------------------------------------------------------------
log "demarrage, role=$ROLE, arch=$ARCH"

# Rien de plus recent a installer ? On sort proprement sans toucher au cache.
# (Si les listes apt sont absentes, candidate_apt est vide : on poursuit, le
# `apt-get update` du chemin normal les reconstruira.)
candidate_apt="$(apt-cache policy "$PAQUET" 2>/dev/null | awk '/Candidate:/{print $2}')"
installee="$(netbird version 2>/dev/null || echo inconnue)"
if [ -n "$candidate_apt" ] && [ "$candidate_apt" = "$installee" ]; then
    log "deja a jour ($installee) — rien a faire"
    ecrire_statut OK "deja-a-jour"
    exit 0
fi

case "$ROLE" in
    primary)
        check_local "avant" || fail "sante locale degradee avant mise a jour"
        preparer_rollback "$installee" \
            || fail "rollback impossible (version $installee indisponible localement) — mise a jour annulee"
        ROLLBACK_DEB="$ROLLBACK_CHEMIN"
        if ! do_update "$installee"; then
            fail "apt-get upgrade netbird"
        fi
        if check_local "apres"; then
            ecrire_statut OK "mise-a-jour"
            log "termine sans erreur"
            exit 0
        fi
        log "sante locale degradee APRES mise a jour — rollback automatique"
        if [ "$DRY_RUN" = "1" ]; then
            ecrire_statut FAILED "rollback non teste en DRY_RUN"
            exit 1
        fi
        if effectuer_rollback "$ROLLBACK_DEB" && check_local "rollback"; then
            ecrire_statut ROLLED_BACK "version d'origine restauree"
            log "rollback reussi — NetBird de nouveau sain"
            exit 0
        fi
        ecrire_statut CRITICAL_ROLLBACK_FAILED "rollback automatique en echec — intervention manuelle requise"
        log "ROLLBACK EN ECHEC : intervention manuelle requise"
        exit 1
        ;;

    secondary)
        check_local "avant" || fail "sante locale degradee avant mise a jour"
        check_peer        || fail "primaire non sain — mise a jour du secondaire annulee"
        preparer_rollback "$installee" \
            || fail "rollback impossible (version $installee indisponible localement) — mise a jour annulee"
        ROLLBACK_DEB="$ROLLBACK_CHEMIN"
        if ! do_update "$installee"; then
            fail "apt-get upgrade netbird"
        fi
        if check_local "apres"; then
            check_peer || log "AVERTISSEMENT: pair injoignable apres mise a jour locale"
            ecrire_statut OK "mise-a-jour"
            log "termine sans erreur"
            exit 0
        fi
        log "sante locale degradee APRES mise a jour — rollback automatique"
        if [ "$DRY_RUN" = "1" ]; then
            ecrire_statut FAILED "rollback non teste en DRY_RUN"
            exit 1
        fi
        if effectuer_rollback "$ROLLBACK_DEB" && check_local "rollback"; then
            check_peer || log "AVERTISSEMENT: pair injoignable apres rollback"
            ecrire_statut ROLLED_BACK "version d'origine restauree"
            log "rollback reussi — NetBird de nouveau sain"
            exit 0
        fi
        ecrire_statut CRITICAL_ROLLBACK_FAILED "rollback automatique en echec — intervention manuelle requise"
        log "ROLLBACK EN ECHEC : intervention manuelle requise"
        exit 1
        ;;

    *)
        fail "ROLE inconnu: $ROLE (attendu: primary | secondary)"
        ;;
esac
