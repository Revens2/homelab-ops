#!/usr/bin/env python3
"""Alimente convia-reco depuis les analyses ChatGPT, sans passer par Gemini.

CONTEXTE
convia_reco.py agrege `/var/lib/convia/reports/<run>/rapport.json`, produit par
convia-analyse (Gemini). C est le DERNIER couplage fort a Gemini : couper
convia-analyse.timer sans rien mettre a la place viderait la fenetre glissante
de 7 jours et laisserait convia-reco, convia-decide (Telegram) et
convia-staleness sans entree. Ce script produit le meme rapport.json a partir
des analyses ChatGPT deposees dans `raw/assets/ConvIA-Analysis/**`.

DEUX SOURCES, DANS CET ORDRE
  1. bloc ```json convia-axes``` en fin d analyse -- structure exacte, c est ce
     que le runbook ChatGPT demande desormais de produire ;
  2. a defaut, derivation des sections Markdown. Degrade mais pas vide : les
     analyses ecrites avant l ajout du bloc restent exploitables.

POURQUOI LA RECURRENCE COMPTE
convia_reco.py priorise par NOMBRE D OCCURRENCES d une meme cle. Un item en
texte libre produit une cle unique a chaque fois, donc une recurrence de 1 et
aucune priorisation. C est precisement ce que le bloc structure corrige : il
impose des libelles courts et reutilisables. La derivation Markdown, elle,
tronque a 160 caracteres pour rapprocher ce qui peut l etre -- sans jamais
inventer d occurrence.
"""
import argparse
import datetime as dt
import json
import os
import re
import sys

AXES_VIDES = {
    "axe1_hygiene": [],
    "axe2_stack": [],
    "axe3_skills": [],
    "axe4_invariants": [],
    "difficultes": [],
}

BLOC_RX = re.compile(r"```(?:json\s+)?convia-axes\s*\n(.*?)```", re.S | re.I)
SECTION_RX = re.compile(r"^##\s+(.+?)\s*$", re.M)
FM_RX = re.compile(r"\A---\s*\n(.*?)\n---\s*\n", re.S)


def frontmatter(txt):
    m = FM_RX.match(txt)
    if not m:
        return {}
    out = {}
    for ligne in m.group(1).splitlines():
        if ":" in ligne and not ligne.startswith(" "):
            k, _, v = ligne.partition(":")
            out[k.strip()] = v.strip().strip('"')
    return out


def sections(txt):
    """Corps de chaque `## Titre`, dans l ordre du document."""
    out = {}
    bornes = [(m.start(), m.end(), m.group(1)) for m in SECTION_RX.finditer(txt)]
    for i, (_s, e, titre) in enumerate(bornes):
        fin = bornes[i + 1][0] if i + 1 < len(bornes) else len(txt)
        out[titre.strip().lower()] = txt[e:fin].strip()
    return out


def puces(bloc):
    """Puces d une section. Un paragraphe sans puce compte pour une entree."""
    items = [re.sub(r"^\s*[-*]\s+", "", l).strip()
             for l in bloc.splitlines() if re.match(r"^\s*[-*]\s+", l)]
    if items:
        return items
    bloc = bloc.strip()
    if not bloc or re.match(r"(?i)^aucun", bloc):
        return []
    return [bloc]


def vide(v):
    return not v or re.match(r"(?i)^aucun", str(v).strip())


def _sec(sec, *titres):
    for t in titres:
        if t in sec:
            return sec[t]
    return ""


def derive_markdown(sec):
    """Repli : reconstruit les axes depuis les sections de l analyse."""
    ax = {k: [] for k in AXES_VIDES}
    for titre in ("mauvais cadrages / repetitions",
                  "mauvais cadrages / répétitions",
                  "frictions utilisateur ↔ agent"):
        for p in puces(_sec(sec, titre)):
            if not vide(p):
                ax["axe1_hygiene"].append(
                    {"anti_pattern": p[:160], "gravite": "moyenne",
                     "recommandation": p})
    for p in puces(_sec(sec, "candidats skill / rule / mcp / automatisation")):
        if vide(p):
            continue
        bas = p.lower()
        if "skill" in bas[:24]:
            ax["axe3_skills"].append({"nom_suggere": p[:160], "motif": p})
        else:
            ax["axe2_stack"].append(
                {"composant": "mcp" if "mcp" in bas else "automatisation",
                 "besoin": p[:160], "justification": p})
    for p in puces(_sec(sec,
                        "difficultes rencontrees par l’agent",
                        "difficultés rencontrées par l’agent",
                        "difficultés rencontrées par l'agent")):
        if vide(p):
            continue
        ax["difficultes"].append(
            {"probleme": p[:160], "resolution": "", "resolue": False})
    return ax


def lire_analyse(chemin):
    txt = open(chemin, encoding="utf-8", errors="replace").read()
    fm = frontmatter(txt)
    m = BLOC_RX.search(txt)
    if m:
        try:
            bloc = json.loads(m.group(1))
            if isinstance(bloc, dict):
                return fm, {k: (bloc.get(k) or []) for k in AXES_VIDES}, "bloc"
        except ValueError as exc:
            sys.stderr.write("[axes] %s : bloc convia-axes illisible (%s)\n"
                             % (chemin, exc))
    return fm, derive_markdown(sections(txt)), "markdown"


def horodatage(fm, chemin):
    v = fm.get("analyzed_at")
    if v:
        try:
            return dt.datetime.strptime(v, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=dt.timezone.utc)
        except ValueError:
            pass
    return dt.datetime.fromtimestamp(os.path.getmtime(chemin), dt.timezone.utc)


def main():
    ap = argparse.ArgumentParser(
        description="rapport.json pour convia-reco, depuis ConvIA-Analysis.")
    ap.add_argument("--source",
                    default="/srv/vault-mirror/raw/assets/ConvIA-Analysis")
    ap.add_argument("--reports", default="/var/lib/convia/reports")
    ap.add_argument("--jours", type=int, default=1,
                    help="fenetre des analyses reprises dans CE run")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    limite = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=a.jours)
    agg = {k: [] for k in AXES_VIDES}
    n, n_bloc = 0, 0
    for base, _d, fichiers in os.walk(a.source):
        for f in sorted(fichiers):
            if not f.endswith("__analyse.md"):
                continue
            p = os.path.join(base, f)
            fm, ax, origine = lire_analyse(p)
            if horodatage(fm, p) < limite:
                continue
            n += 1
            n_bloc += origine == "bloc"
            for k in AXES_VIDES:
                agg[k].extend(x for x in ax[k] if isinstance(x, dict))

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    rapport = dict(agg)
    rapport["resume_executif"] = (
        "Agregation de %d analyse(s) ConvIA-Analysis (%d avec bloc structure) "
        "sur %d jour(s). Source : ChatGPT, pas Gemini." % (n, n_bloc, a.jours))
    rapport["recommandations_prioritaires"] = []
    doc = {
        "meta": {
            "date": stamp,
            "n_ok": n,
            "n_ko": 0,
            "n_skipped": 0,
            "n_requeued": 0,
            "n_restant": 0,
            "partiel": False,
            "motif_arret": "",
            "synthese": "convia-axes-from-analysis",
            "quota": False,
            "quota_reset_s": 0,
            "requests": 0,
            "tokens_in": 0,
            "tokens_out": 0,
            "producteur": "convia_axes_from_analysis.py",
        },
        "rapport": rapport,
    }

    if a.dry_run:
        json.dump(doc, sys.stdout, ensure_ascii=False, indent=1)
        sys.stdout.write("\n")
        return 0
    if n == 0:
        # Pas de rapport vide : convia-staleness le lirait comme un run reussi
        # sans contenu, et convia-reco agregerait du neant.
        sys.stderr.write("[axes] aucune analyse dans la fenetre, rien ecrit\n")
        return 0
    d = os.path.join(a.reports, stamp)
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".rapport.json.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, os.path.join(d, "rapport.json"))
    with open(os.path.join(d, "rapport.md"), "w", encoding="utf-8") as fh:
        fh.write("# Rapport ConvIA (source ChatGPT)\n\n%s\n"
                 % rapport["resume_executif"])
    latest = os.path.join(a.reports, "latest")
    tmp_l = latest + ".tmp"
    if os.path.islink(tmp_l) or os.path.exists(tmp_l):
        os.remove(tmp_l)
    os.symlink(d, tmp_l)
    os.replace(tmp_l, latest)
    print("rapport ecrit : %s (%d analyses, %d avec bloc)" % (d, n, n_bloc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
