#!/bin/bash
# google-bypass.sh — sort le trafic Google (AS15169/AS36040) des clients exit node
# par la sortie directe Oracle au lieu de WARP (contourne le blocage Gemini).
#
# Mécanisme :
#   - mangle PREROUTING : -i wt0 -d <plage google> -j MARK --set-xmark 0x90000/0xff0000
#   - ip rule 5285 : fwmark 0x90000/0xff0000 -> lookup main (évaluée AVANT la 5300 -> WARP)
# Le mark 0x90000 est posé avant la décision de routage ; NetBird pose ses marques 0x0001bd1x
# APRES (chaines netbird-mangle-*), donc le NAT direct (netbird-rt-postrouting) fonctionne normalement.
# Idempotent : peut tourner à chaque boot et à chaque appel.
set -u

PREFIXES=/usr/local/etc/google-bypass-prefixes.txt
SRC_URL=https://www.gstatic.com/ipranges/goog.json
MARK=0x90000/0xff0000
RULE_PRIO=5285
CHAIN=GOOGLE_BYPASS
LOG=/var/log/google-bypass.log

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

refresh_prefixes() {
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL --max-time 30 "$SRC_URL" -o "$tmp"; then
        log "refresh: curl KO"
        rm -f "$tmp"
        return 1
    fi
    if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join(sorted(p["ipv4Prefix"] for p in d["prefixes"] if "ipv4Prefix" in p)))' "$tmp" > "$tmp.txt"; then
        log "refresh: python KO"
        rm -f "$tmp" "$tmp.txt"
        return 1
    fi
    mkdir -p "$(dirname "$PREFIXES")"
    install -m 0644 "$tmp.txt" "$PREFIXES"
    rm -f "$tmp" "$tmp.txt"
    log "refresh: $(wc -l < "$PREFIXES") préfixes écrits dans $PREFIXES"
}

apply() {
    local n
    # 1. chaîne mangle + jump idempotent
    iptables -t mangle -N "$CHAIN" 2>/dev/null
    iptables -t mangle -F "$CHAIN"
    n=0
    while read -r cidr; do
        [ -n "$cidr" ] || continue
        iptables -t mangle -A "$CHAIN" -d "$cidr" -j MARK --set-xmark "$MARK"
        n=$((n+1))
    done < "$PREFIXES"
    iptables -t mangle -C PREROUTING -i wt0 -j "$CHAIN" 2>/dev/null || \
        iptables -t mangle -A PREROUTING -i wt0 -j "$CHAIN"
    # 2. règle ip rule fwmark -> main (priorité 5285, avant la 5300)
    ip rule show | grep -q "fwmark 0x90000/0xff0000 lookup main" || \
        ip rule add priority "$RULE_PRIO" fwmark 0x90000/0xff0000 lookup main
    log "apply: $n règles dans la chaîne, jump présent=$([ -n "$(iptables -t mangle -S PREROUTING | grep -c -- '-j '"$CHAIN")" ] && echo oui || echo non), ip rule=$([ -n "$(ip rule show | grep -c 'fwmark 0x90000')" ] && echo oui || echo non)"
}

remove() {
    iptables -t mangle -D PREROUTING -i wt0 -j "$CHAIN" 2>/dev/null
    iptables -t mangle -F "$CHAIN" 2>/dev/null
    iptables -t mangle -X "$CHAIN" 2>/dev/null
    ip rule del priority "$RULE_PRIO" fwmark 0x90000/0xff0000 lookup main 2>/dev/null
    log "remove: chaîne et ip rule 5285 retirées"
}

status() {
    echo "== chaîne mangle =="
    iptables -t mangle -S "$CHAIN" 2>/dev/null | sed -n '1,3p;/^$/d'
    echo "  total règles : $(iptables -t mangle -S "$CHAIN" 2>/dev/null | grep -c -- '-d ')"
    echo "== jump PREROUTING =="
    iptables -t mangle -S PREROUTING 2>/dev/null | grep -- "$CHAIN" || echo "  (absent)"
    echo "== ip rule 5285 =="
    ip rule show | grep "fwmark 0x90000" || echo "  (absent)"
}

case "${1:-apply}" in
    refresh) refresh_prefixes ;;
    apply)
        [ -s "$PREFIXES" ] || refresh_prefixes || { echo "pas de préfixes et refresh KO — abandon"; exit 1; }
        apply ;;
    remove) remove ;;
    status) status ;;
    *) echo "usage: $0 [apply|refresh|remove|status]"; exit 1 ;;
esac
