# -*- coding: utf-8 -*-
"""Tests de la logique de budget de /usr/local/bin/convia_analyse.py.

Ce que ces tests verrouillent, apres l'echec du run du 2026-08-14 :
  - la phase map ne peut PAS consommer le budget reserve a la synthese ;
  - budget epuise pendant la map => synthese produite quand meme, sortie 0 ;
  - une conversation non traitee (budget ou 429) reste EN FILE : ni manifeste,
    ni deplacement vers Traite/ ;
  - un manifeste corrompu est une anomalie (sortie 3), jamais un reset silencieux.
Aucun appel reseau ni sous-processus reel : `subprocess.run` est
remplace par un double qui rejoue l'enveloppe JSON d'AGY.
"""
import importlib.util
import io
import json
import os
import sys

import pytest

SCRIPT = os.environ.get("CONVIA_ANALYSE_PY", "/usr/local/bin/convia_analyse.py")


def load_module(tmp_path, **env):
    """Charge le script avec un etat isole dans tmp_path."""
    os.environ.update({
        "CONVIA_STATE": str(tmp_path / "state"),
        "CONVIA_SPOOL": str(tmp_path / "spool"),
        "GEMINI_API_KEY": "cle-de-test-jamais-utilisee",
        "CONVIA_MIN_INTERVAL": "0",
        "CONVIA_MAX_ATTEMPTS": "1",
        "CONVIA_MAX_ATTEMPTS_429": "1",
        # Explicite, en plus de la derivation depuis CONVIA_STATE : aucun test ne
        # doit pouvoir toucher l etat de production (incident du 2026-08-15).
        "CONVIA_QUOTA_GATE": str(tmp_path / "state" / "quota-reset"),
        "CONVIA_AGY_STAGE": str(tmp_path / "state" / "agy-stage"),
    })
    os.environ.update({k: str(v) for k, v in env.items()})
    (tmp_path / "state").mkdir(exist_ok=True)
    (tmp_path / "spool").mkdir(exist_ok=True)
    spec = importlib.util.spec_from_file_location("convia_analyse_%d" % id(tmp_path),
                                                  SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ------------------------------------------------------- arithmetique du budget
def test_reserve_jamais_nulle(tmp_path):
    m = load_module(tmp_path)
    assert m.reduce_requests_for(0) == 0
    assert m.reduce_requests_for(1) == 1
    assert m.reduce_requests_for(10) >= 1


def test_reduce_hierarchique_compte_tous_les_niveaux(tmp_path):
    m = load_module(tmp_path, CONVIA_FICHE_CHARS=100000,
                    CONVIA_REDUCE_CHUNK_CHARS=250000)
    # 10 fiches x 100 ko : niveaux successifs 4 puis 2 puis 1 groupe = 7 requetes
    assert m.reduce_requests_for(10) == 7


def test_plan_budget_reserve_la_synthese(tmp_path):
    m = load_module(tmp_path)
    for total in range(2, 80):
        map_budget, reserve = m.plan_budget(total)
        assert map_budget >= 1
        assert reserve >= 1
        assert map_budget + reserve <= total, total
        assert reserve >= m.reduce_requests_for(map_budget)


def test_map_ne_peut_pas_depasser_son_cap(tmp_path):
    m = load_module(tmp_path, CONVIA_MAX_REQUESTS=5)
    m._requests_used = 3
    with pytest.raises(m.BudgetExhausted):
        m.call_agy("sys", "user", m.MAP_SCHEMA, cap=3)


# ------------------------------------------------------------ double de reseau
MAP_OUT = {"resume": "r", "axe1_hygiene": [], "axe2_stack": [], "axe3_skills": [],
           "axe4_invariants": [], "difficultes": [], "injection_detectee": False}
REDUCE_OUT = {"resume_executif": "synthese", "axe1_hygiene": [], "axe2_stack": [],
              "axe3_skills": [], "axe4_invariants": [], "difficultes": [],
              "recommandations_prioritaires": ["a"]}


class FakeCompleted:
    """Ce que `subprocess.run` rend : AGY ecrit son enveloppe JSON sur stdout."""

    def __init__(self, stdout, returncode=0, stderr=""):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode


# Message reel d'AGY quand l'abonnement est epuise, releve le 2026-08-14.
QUOTA_MSG = ("Individual quota reached. Please upgrade your subscription to "
             "increase your limits. Resets in 42h00m00s.")


def envelope(payload):
    return json.dumps({
        "status": "OK",
        "response": json.dumps(payload),
        "usage": {"input_tokens": 10, "output_tokens": 20, "thinking_tokens": 0},
    })


def install_fakes(m, tmp_path, n_conv, monkeypatch, quota=False):
    """Remplace le sous-processus AGY et rclone. Renvoie les appels observes."""
    calls = []

    def fake_run(cmd, **kwargs):
        prompt = cmd[cmd.index("-p") + 1] if "-p" in cmd else ""
        kind = "reduce" if "resume_executif" in prompt else "map"
        calls.append(kind)
        # Le quota ne frappe qu'apres deux reussites : on verifie ainsi que ce qui
        # a ete analyse est conserve, et que le reste repart en file.
        if quota and kind == "map" and len(calls) > 2:
            return FakeCompleted(
                json.dumps({"status": "ERROR", "error": QUOTA_MSG}), returncode=1)
        out = REDUCE_OUT if kind == "reduce" else MAP_OUT
        return FakeCompleted(envelope(out))

    monkeypatch.setattr(m.subprocess, "run", fake_run)
    # Le binaire et le jeton sont verifies par presence : on satisfait la garde.
    monkeypatch.setattr(m.Path, "is_file", lambda self: True)

    entries = [{"Path": "conv/%03d.md" % i, "Size": 100} for i in range(n_conv)]
    monkeypatch.setattr(m, "list_remote", lambda: list(entries))
    moved = []

    def fake_rclone(*args, capture=False):
        if args[0] == "copyto":
            dst = m.Path(args[2])
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text("---\nconvia_sanitized: 3\n---\nbla\n", encoding="utf-8")
            return ""
        if args[0] == "moveto":
            moved.append(args[1])
            return ""
        return ""

    monkeypatch.setattr(m, "rclone", fake_rclone)
    return calls, entries, moved


# ------------------------------------------- le cas qui a fait echouer le run
def test_budget_epuise_pendant_la_map_produit_quand_meme_la_synthese(
        tmp_path, monkeypatch):
    m = load_module(tmp_path, CONVIA_MAX_REQUESTS=6)
    calls, entries, moved = install_fakes(m, tmp_path, 20, monkeypatch)
    monkeypatch.setattr(sys, "argv", ["convia_analyse.py"])

    rc = m.main()

    assert rc == 0, "un run partiel n'est pas une panne"
    map_budget, reserve = m.plan_budget(6)
    assert calls.count("map") == map_budget
    assert calls.count("reduce") == 1, "la synthese a bien eu lieu"
    # rapport final produit
    latest = m.REPORTS / "latest"
    assert (latest / "rapport.md").is_file()
    assert (latest / "rapport.json").is_file()
    txt = (latest / "rapport.md").read_text(encoding="utf-8")
    assert "RUN PARTIEL" in txt
    assert "restent en file" in txt
    # ce qui n'a pas ete traite reste EN FILE
    man = json.loads((m.MANIFEST).read_text(encoding="utf-8"))
    assert len(man) == map_budget
    assert len(moved) == map_budget
    reste = [e for e in entries if m.needs_work(e, man)]
    assert len(reste) == 20 - map_budget
    # telegram : le caractere partiel est annonce
    spool = sorted((m.SPOOL).glob("*.json"))
    assert spool
    tg = "".join(json.loads(p.read_text(encoding="utf-8"))["text"] for p in spool)
    assert "RUN PARTIEL" in tg
    assert "restantes" in tg


def test_429_persistant_remet_la_conversation_en_file_et_arrete_la_map(
        tmp_path, monkeypatch):
    m = load_module(tmp_path, CONVIA_MAX_REQUESTS=30, CONVIA_MAX_CONSECUTIVE_429=2)
    calls, entries, moved = install_fakes(m, tmp_path, 20, monkeypatch, quota=True)
    monkeypatch.setattr(sys, "argv", ["convia_analyse.py"])

    rc = m.main()

    # Contrat AGY (adr/0007) : un arret sur quota sort en 75, que systemd traite
    # comme un succes via SuccessExitStatus=75. Ce n est pas une panne.
    assert rc == 75, "arret sur quota = 75, pas un echec"
    man = json.loads((m.MANIFEST).read_text(encoding="utf-8"))
    assert len(man) == 2, "seules les 2 reussites sont au manifeste"
    assert len(moved) == 2
    assert len([e for e in entries if m.needs_work(e, man)]) == 18
    assert calls.count("reduce") == 1
    txt = (m.REPORTS / "latest" / "rapport.md").read_text(encoding="utf-8")
    assert "RUN PARTIEL" in txt


def test_429_ne_marque_jamais_la_conversation_en_echec(tmp_path, monkeypatch):
    m = load_module(tmp_path, CONVIA_MAX_REQUESTS=30, CONVIA_MAX_CONSECUTIVE_429=2)
    calls, entries, moved = install_fakes(m, tmp_path, 20, monkeypatch, quota=True)
    monkeypatch.setattr(sys, "argv", ["convia_analyse.py"])
    assert m.main() == 75
    # Le jalon de reprise est ecrit, et dans l'etat ISOLE du test : jamais dans
    # /var/lib/convia (incident du 2026-08-15, un test avait bloque la production
    # pendant 42 heures).
    assert m.QUOTA_GATE.is_file(), "le delai annonce par AGY doit etre memorise"
    assert str(tmp_path) in str(m.QUOTA_GATE), "l'etat de production est intouchable"
    rep = json.loads((m.REPORTS / "latest" / "rapport.json").read_text(
        encoding="utf-8"))
    assert rep["meta"]["n_ko"] == 0, "un refus de quota n'est JAMAIS un echec"
    # La map s'arrete des le premier refus : chaque appel refuse coute une requete
    # pour rien. Une conversation repart en file, les autres n'ont pas ete tentees.
    assert rep["meta"]["n_requeued"] >= 1
    assert rep["meta"]["partiel"] is True


def test_delai_de_reprise_lu_dans_le_message_agy(tmp_path):
    """AGY annonce son delai en clair : c'est lui qui alimente le jalon de reprise."""
    m = load_module(tmp_path)
    assert m.quota_reset_seconds(QUOTA_MSG) == 42 * 3600
    assert m.quota_reset_seconds("Resets in 1h30m10s") == 5410
    assert m.quota_reset_seconds("aucun delai annonce") == 0


def test_journalisation_masque_toute_chaine_opaque(tmp_path):
    """Le jeton OAuth ne doit apparaitre ni dans un journal ni dans une notification."""
    m = load_module(tmp_path)
    secret = "A" * 60
    sortie = m.redact("erreur avec " + secret + " en clair")
    assert secret not in sortie
    assert "[REDACTED]" in sortie
    # une chaine courte et legitime n'est pas masquee
    assert "quota" in m.redact("quota reached")


def test_manifeste_corrompu_est_une_anomalie(tmp_path, monkeypatch):
    m = load_module(tmp_path)
    m.MANIFEST.write_text("{ceci n'est pas du json", encoding="utf-8")
    monkeypatch.setattr(sys, "argv", ["convia_analyse.py"])
    assert m.main() == 3
    # le manifeste n'a pas ete ecrase
    assert m.MANIFEST.read_text(encoding="utf-8").startswith("{ceci")


def test_corpus_illisible_est_une_anomalie(tmp_path, monkeypatch):
    m = load_module(tmp_path)

    def boom():
        raise m.subprocess.CalledProcessError(1, ["rclone"])

    monkeypatch.setattr(m, "list_remote", boom)
    monkeypatch.setattr(sys, "argv", ["convia_analyse.py"])
    assert m.main() == 3


def test_jeton_agy_absent_est_une_anomalie(tmp_path, monkeypatch):
    """Il n'y a plus de cle d'API : l'anomalie, c'est le profil non authentifie."""
    m = load_module(tmp_path)
    reel = m.Path.is_file

    def pas_de_jeton(self):
        return False if "antigravity-oauth-token" in str(self) else reel(self)

    monkeypatch.setattr(m.Path, "is_file", pas_de_jeton)
    monkeypatch.setattr(sys, "argv", ["convia_analyse.py"])
    assert m.main() == 2


def test_synthese_de_repli_sans_modele_est_conforme_au_schema(tmp_path):
    m = load_module(tmp_path)
    fiche = dict(MAP_OUT)
    fiche["axe3_skills"] = [{"motif": "mo", "occurrences": 3, "nom_suggere": "s",
                             "ebauche_markdown": "# s"}]
    fiche["axe1_hygiene"] = [{"anti_pattern": "ap", "gravite": "haute",
                              "preuve": "p", "recommandation": "r"}]
    fiche["axe4_invariants"] = [{"invariant": "I1", "statut": "respecte",
                                 "preuve": "p", "correction": "-"}]
    out = m.local_reduce([fiche, dict(fiche)])
    m.validate(out, m.REDUCE_SCHEMA)          # leve si non conforme
    assert out["axe3_skills"][0]["occurrences"] == 6
    assert "LOCALEMENT" in out["resume_executif"]
