#!/usr/bin/env python3
"""Scan bloquant de secrets en clair, avant publication du wiki vers Google Drive.

Pourquoi il existe : le 2026-09-06, /srv/obsidian-vault/wiki/sources/VPS_IA.md
portait `Mot de passe : 2674` en clair alors que la version deja presente sur
Drive portait `[SECRET-EXPURGE]`. Une passe d expurgation avait eu lieu cote
Drive et pas cote moteur. Publier sans scanner aurait RE-INTRODUIT le secret.

Pourquoi ce n est pas un simple grep : un `grep -i "mot de passe"` remonte 25
fiches de prose ("changement de mot de passe : route backend securisee...").
Un scanner qui crie a chaque page parlant de mots de passe est un scanner qu on
finit par desactiver. On exige donc une AFFECTATION (separateur) suivie d une
valeur qui RESSEMBLE a un identifiant, pas a un mot de la langue.

Sortie : 0 = rien trouve. 1 = au moins un secret. Les lignes fautives vont sur
stderr, tronquees -- on ne recopie jamais le secret entier dans un journal.
"""
import argparse
import os
import re
import sys

# 1. Motifs a haute confiance : jamais un faux positif, toujours bloquants.
HAUTE_CONFIANCE = [
    ("cle privee", re.compile(r"-----BEGIN (?:RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY")),
    ("cle OpenAI", re.compile(r"\bsk-[A-Za-z0-9]{20,}")),
    ("token GitHub", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}")),
    ("cle AWS", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("token Slack", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}")),
    ("cle Tailscale", re.compile(r"\btskey-(?:api|auth)-[A-Za-z0-9]{10,}")),
    ("cle Google", re.compile(r"\bAIza[0-9A-Za-z_-]{30,}")),
]

# 2. Affectation explicite d un identifiant. Le separateur est OBLIGATOIRE :
#    c est lui qui distingue une valeur d une phrase.
AFFECTATION = re.compile(
    r"(?i)\b(mot de passe|mdp|password|passwd|passphrase|secret|api[_ -]?key|token)\b"
    r"\s*[:=]\s*"
    r"[`\"']?([A-Za-z0-9][A-Za-z0-9!@#$%^&*_+.\-]{3,})"
)

# Valeurs deja neutralisees, ou mots de la langue qui suivent parfois un ":".
PLACEHOLDERS = re.compile(
    r"(?i)^(secret|expurge|redacted|tronquee|xxx+|placeholder|null|none|vide|"
    r"votre|ton|le|la|les|un|une|des|ce|cet|cette|route|reset|change|forgot|"
    r"oui|non|true|false|todo|example|exemple|test|dummy|masque|masquee)$"
)


def valeur_suspecte(v):
    """Une valeur ressemble a un identifiant si elle n est pas un mot francais.

    Deux formes acceptees, volontairement etroites :
      - purement numerique d au moins 4 chiffres (le cas `Mot de passe : 2674`) ;
      - au moins 8 caracteres melangeant lettres ET chiffres.
    Tout le reste est traite comme de la prose. Un secret purement alphabetique
    et court passe donc a travers : c est un compromis assume contre le bruit,
    compense par la denylist litterale.
    """
    if PLACEHOLDERS.match(v):
        return False
    # Valeur deja elidee a la source ("cXCHi5...qf2w") : le secret n est pas
    # reconstituable, et bloquer dessus n empeche aucune fuite.
    if "..." in v or "…" in v:
        return False
    if v.isdigit():
        return len(v) >= 4
    if len(v) >= 8 and any(c.isdigit() for c in v) and any(c.isalpha() for c in v):
        return True
    return False


def charger_denylist(chemin):
    """Secrets connus, un par ligne. Le fichier n est pas dans le depot :
    il vit en 0600 sur la machine (invariant #4, aucun secret versionne)."""
    if not chemin or not os.path.isfile(chemin):
        return []
    out = []
    with open(chemin, encoding="utf-8", errors="replace") as fh:
        for ligne in fh:
            ligne = ligne.strip()
            if ligne and not ligne.startswith("#"):
                out.append(ligne)
    return out


def scanner_fichier(chemin, denylist):
    trouve = []
    try:
        with open(chemin, encoding="utf-8", errors="replace") as fh:
            for no, ligne in enumerate(fh, 1):
                for nom, rx in HAUTE_CONFIANCE:
                    if rx.search(ligne):
                        trouve.append((no, nom))
                m = AFFECTATION.search(ligne)
                if m and valeur_suspecte(m.group(2)):
                    trouve.append((no, "affectation %s" % m.group(1).lower()))
                for lit in denylist:
                    if lit in ligne:
                        trouve.append((no, "denylist"))
    except OSError as exc:
        trouve.append((0, "illisible : %s" % type(exc).__name__))
    return trouve


def main():
    ap = argparse.ArgumentParser(description="Scan de secrets avant publication.")
    ap.add_argument("racine")
    ap.add_argument("--denylist", default="/etc/llm-wiki/secret-denylist.txt")
    ap.add_argument("--ext", default=".md")
    a = ap.parse_args()

    denylist = charger_denylist(a.denylist)
    total = 0
    for base, dirs, fichiers in os.walk(a.racine):
        dirs[:] = [d for d in dirs if d not in ("_index", "_review", ".staging")]
        for f in fichiers:
            if not f.endswith(a.ext):
                continue
            p = os.path.join(base, f)
            for no, motif in scanner_fichier(p, denylist):
                total += 1
                sys.stderr.write("  %s:%d  %s\n" % (p, no, motif))
    if total:
        sys.stderr.write("%d occurrence(s) de secret en clair\n" % total)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
