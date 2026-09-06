# convia-sanitize

Copie versionnee de `/opt/convia-sanitize/` sur `vps-etude`, qui n etait dans
aucun depot. Le sanitizer est le composant qui decide ce qui sort du corpus de
conversations vers Google Drive : c est le dernier point ou un secret peut etre
arrete avant publication. Le laisser exister uniquement sur la machine etait un
risque -- constate le 2026-09-06, quand une regle de redaction trop stricte a
laisse passer un mot de passe SSH sans qu aucun historique ne permette de dater
la regression.

`/opt/convia-sanitize/` reste le chemin d execution ; ce dossier est la reference.
Toute modification se fait ici puis est deployee, pas l inverse.

- `redact.py`    -- etage 2 : redaction des secrets, motifs et validateurs
- `sanitizer.py` -- transformation des conversations
- `runner.py`    -- point d entree appele par `convia-sanitize.service`
- `tests/`       -- suite pytest ; `test_redact_mdp_court.py` couvre la
                    regression du 2026-09-06

`tests/test_analyse_budget.py` echoue hors machine et sans profil AGY
authentifie : il touche le moteur d analyse, pas le sanitizer.
