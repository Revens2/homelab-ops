#!/bin/bash
# Pousseur du spool d ecriture du vault (adr/0020).
#
# Consomme /srv/vault-spool/queue en FIFO et applique chaque intention sur
# Google Drive -- la source de verite -- puis rafraichit le miroir local.
#
# POURQUOI CE SCRIPT EXISTE
# -------------------------
# `vault-mcp.service` est le seul composant du VPS joignable depuis internet.
# Son unite lui interdit toute sortie reseau et toute ecriture hors de deux
# repertoires. Il ne peut donc pas ecrire sur Drive. Il depose une intention ;
# ce script, sous l uid `juliann` qui detient les credentials rclone, l applique.
# La compromission totale du MCP donne au mieux le droit de deposer des
# intentions valides -- c est toute la propriete que cette separation preserve.
#
# LE CONTROLE LE PLUS IMPORTANT DE CE FICHIER
# -------------------------------------------
# `confiner` (plus bas). En lecture, `mirror_store._resoudre` protege le vault
# par `realpath` + verification de confinement, ce qui attrape un lien
# symbolique pointant hors du miroir. En ecriture ce rempart est ABSENT, puisque
# le MCP n ecrit pas dans le miroir. Un lien plante dans le vault et synchronise
# depuis Drive suffirait sinon a faire ecrire ce script hors du miroir, sous un
# uid membre du groupe `sudo`. Ce controle n est pas optionnel.
set -uo pipefail

SPOOL="${VAULT_SPOOL:-/srv/vault-spool}"
MIROIR="${VAULT_MIRROR:-/srv/vault-mirror}"
DISTANT="${VAULT_REMOTE:-gdrive:Obsidian Vault}"
CORBEILLE_LOCALE="${VAULT_TRASH:-/srv/vault-mirror-trash}"
CORBEILLE_DISTANTE=".trash-mcp"
VERROU="${VAULT_LOCK:-/run/lock/vault-mirror.lock}"
# Chemin du script de sync (admin/sync) : surchargeable pour les tests
# locaux ; defaut = vault_mirror_sync.sh de production, execute en
# SYNCHRONE par le worker v4.1 (adr/0023).
MIRROR_SYNC="${MIRROR_SYNC:-/usr/local/bin/vault_mirror_sync.sh}"
RETENTION_JOURS=14
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# Meme calibrage que vault_mirror_sync.sh : le pacer par defaut et un plafond
# explicite de requetes/s. Regle apres le rate-limit Drive du 2026-08-14, ne pas
# durcir sans mesure.
RCLONE_OPTS=(--tpslimit 8 --retries 3 --low-level-retries 10 --stats 0)

journal() { echo "pousseur $*"; }

# ---------------------------------------------------------------- confinement
# Rend le chemin absolu prouve a l interieur du miroir, ou echoue.
# Resout les liens du PARENT (le fichier lui-meme peut ne pas exister encore).
confiner() {
  local relatif="$1" parent reel_parent
  case "$relatif" in
    /*|*..*|"") return 1 ;;
  esac
  parent="$(dirname "$MIROIR/$relatif")"
  mkdir -p "$parent" 2>/dev/null || return 1
  reel_parent="$(realpath -e "$parent" 2>/dev/null)" || return 1
  local reel_miroir
  reel_miroir="$(realpath -e "$MIROIR")" || return 1
  # Le parent resolu doit etre le miroir lui-meme ou strictement dessous.
  [ "$reel_parent" = "$reel_miroir" ] || case "$reel_parent" in
    "$reel_miroir"/*) ;;
    *) return 1 ;;
  esac
  # La cible ne doit pas etre un lien sortant. `-L` en plus de `-e` : un lien
  # symbolique CASSE echoue `-e` et passait donc ce controle. `realpath -m` (et
  # non `-e`) resout un chemin dont la derniere composante n existe pas encore,
  # ce qui est le cas normal d une creation -- et le cas d un lien casse.
  if [ -e "$MIROIR/$relatif" ] || [ -L "$MIROIR/$relatif" ]; then
    local reel_cible
    reel_cible="$(realpath -m "$MIROIR/$relatif" 2>/dev/null)" || return 1
    case "$reel_cible" in
      "$reel_miroir"/*) ;;
      *) return 1 ;;
    esac
  fi
  printf '%s\n' "$MIROIR/$relatif"
}

# ------------------------------------------------------------------- verdicts
terminer_ok() {
  local fichier="$1" id="$2"
  jq --arg fini "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     'del(.contenu_b64) + {resultat:"ok", fini_a:$fini}' \
     "$fichier" > "$SPOOL/done/$id.json" 2>/dev/null
  # Le recu est ecrit AVANT le retrait de la file : un crash entre les deux
  # rejoue une operation deja appliquee, ce qui est sans effet (toutes les
  # operations sont formulees comme un etat final). L inverse perdrait le recu.
  rm -f "$fichier"
  journal "id=$id resultat=ok"
  BESOIN_REINDEX=1
}

# `mkdir` (create_folder) ne touche aucune note : inutile d armer la
# reindexation debouncee. Meme recu que terminer_ok, sans le drapeau.
terminer_ok_sans_reindex() {
  local fichier="$1" id="$2"
  jq --arg fini "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     'del(.contenu_b64) + {resultat:"ok", fini_a:$fini}' \
     "$fichier" > "$SPOOL/done/$id.json" 2>/dev/null
  rm -f "$fichier"
  journal "id=$id resultat=ok"
}

terminer_echec() {
  local fichier="$1" id="$2" motif="$3"
  jq --arg fini "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg motif "$motif" \
     'del(.contenu_b64) + {resultat:"echec", motif:$motif, fini_a:$fini}' \
     "$fichier" > "$SPOOL/failed/$id.json" 2>/dev/null
  rm -f "$fichier"
  journal "id=$id resultat=echec motif=$motif"
}

# ------------------------------------------------- confirmation cote Drive
# Drive ne garantit pas la coherence immediate d un listing, et le sync utilise
# --fast-list. Sans cette confirmation, un `rclone sync` demarrant juste apres
# pourrait ne pas voir la note fraichement ecrite et la SUPPRIMER du miroir.
# On ne relache le verrou qu une fois la note visible.
confirmer_sur_drive() {
  local chemin="$1" attente=1
  for _ in 1 2 3 4 5; do
    if rclone lsjson "$DISTANT/$chemin" "${RCLONE_OPTS[@]}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$attente"
    attente=$((attente * 2))
  done
  return 1
}

confirmer_absence_sur_drive() {
  local chemin="$1" attente=1
  for _ in 1 2 3 4 5; do
    if ! rclone lsjson "$DISTANT/$chemin" "${RCLONE_OPTS[@]}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$attente"
    attente=$((attente * 2))
  done
  return 1
}

# --------------------------------------------------------- application d une op
# ------------------------------------------------------ controle concurrence
# CAS v4.1 (adr/0023) : compare Drive, PAS le miroir.
# Codes de retour :
#   0 = CAS ok            (Drive == version attendue)
#   1 = conflit           (Drive != version attendue : edition concurrente)
#   2 = absent sur Drive  (lsjson rc 3/4 : l etat final est peut-etre atteint)
#   3 = etat indetermine  (erreur reseau/API : on ne decide PAS)
# Entrees (variables du contexte) : $chemin $md5_attendu $sha $local_cible.
verifier_cas() {
  if [ -n "${md5_attendu:-}" ]; then
    # Chemin v4.1 : UNE SEULE operation distante (lsjson --hash), aucun
    # download (37 s pour 42 Ko mesure sous throttling Drive), aucun lsjson de
    # presence supplementaire. Drive expose le md5 de ses octets stockes en
    # metadonnee ; on le compare au md5_attendu calcule a T0 par le serveur sur
    # les MEMES octets que le sha256_attendu. Le miroir n est JAMAIS consulte.
    local json md5_drive rc
    json="$(rclone lsjson --hash "$DISTANT/$chemin" "${RCLONE_OPTS[@]}" 2>/dev/null)"
    rc=$?
    if [ "$rc" = "3" ] || [ "$rc" = "4" ]; then return 2; fi
    [ "$rc" = "0" ] || return 3
    # `rclone lsjson --hash` sur un chemin FICHIER renvoie un TABLEAU
    # [{...}] avec le hash sous "Hashes":{"md5":...} (verifie le 2026-09-05
    # sur le vrai remote : un jq '.md5' top-level echoue et rendait chaque CAS
    # "etat Drive indetermine"). Le mock des tests bash reproduit CE format.
    md5_drive="$(printf '%s' "$json" | jq -r '.[0].Hashes.md5 // empty' 2>/dev/null)"
    [ -n "$md5_drive" ] || return 3
    if [ "$md5_drive" != "$md5_attendu" ]; then
      journal "CONFLIT id=${id:-?} op=${op:-?} path=$chemin attendu_md5=$md5_attendu drive_md5=$md5_drive"
      return 1
    fi
    return 0
  fi
  # Repli intents ANCIENS (schema v1, sans md5_attendu) : CAS historique sur le
  # miroir. A disparaitre quand la file aura purge les intentions v1.
  if [ -n "${sha:-}" ]; then
    local actuel=""
    [ -f "$local_cible" ] && actuel="$(sha256sum "$local_cible" | cut -d' ' -f1)"
    if [ "$actuel" != "$sha" ]; then return 1; fi
  fi
  return 0
}

traiter() {
  local fichier="$1"
  local id op chemin cible sha contenu_b64 version
  id="$(jq -r '.id // empty' "$fichier" 2>/dev/null)"
  if [ -z "$id" ]; then
    # Illisible ou malformee. NE PAS supprimer : une intention d ecriture
    # effacee en silence est une perte de donnee sans trace. On la range dans
    # failed/ sous un nom derive du fichier, pour qu elle reste inspectable.
    journal "intention illisible : $fichier"
    mv -f "$fichier" "$SPOOL/failed/$(basename "$fichier" .json)-illisible.json" 2>/dev/null       || journal "intention illisible ET non deplacable : $fichier"
    return
  fi

  version="$(jq -r '.version // 0' "$fichier")"
  if [ "$version" != "1" ]; then
    terminer_echec "$fichier" "$id" "version de schema non geree : $version"
    return
  fi

  # Idempotence : une intention deja appliquee ne se rejoue pas.
  if [ -f "$SPOOL/done/$id.json" ]; then
    journal "id=$id deja applique, retrait de la file"
    rm -f "$fichier"
    return
  fi

  op="$(jq -r '.op' "$fichier")"
  chemin="$(jq -r '.path' "$fichier")"
  cible="$(jq -r '.path_cible // empty' "$fichier")"
  sha="$(jq -r '.sha256_attendu // empty' "$fichier")"
  # Version-token interne Drive (adr/0023) : compare au md5 natif expose par
  # `lsjson --hash`. Champ optionnel (schema v1) : absent sur les intentions
  # anciennes, qui retombent sur le repli legacy plus bas.
  md5_attendu="$(jq -r '.md5_attendu // empty' "$fichier")"
  contenu_b64="$(jq -r '.contenu_b64 // empty' "$fichier")"

  case "$op" in
    admin/reindex)
      # `--no-block` N EST PAS COSMETIQUE. Sans lui, `systemctl start` attend la
      # fin de l unite -- et si une reindexation tourne deja, il attend la fin de
      # CELLE-LA. Le pousseur est un consumer UNIQUE : cette attente immobilise
      # toute la FIFO. Mesure du 2026-09-06 : l intention e9f18115727a
      # (admin/reindex, deposee a 13:53:48) a bloque le pousseur 37 min 11 s, et
      # l ecriture ordinaire d35504f3218d, deposee a 14:09:08, n a ete appliquee
      # qu a 14:32:45 -- derriere elle, pas a cause d elle.
      #
      # Persistance et indexation semantique sont deux operations distinctes :
      # une demande de reindexation est une DEMANDE, le recu `ok` signifie
      # « reindexation demandee/demarree », pas « index reconstruit ». Le
      # rendez-vous de coalescence est le job systemd : un second start pendant
      # qu un job est deja en file est un no-op.
      sudo -n systemctl start --no-block vault-reindex.service \
        && terminer_ok "$fichier" "$id" \
        || terminer_echec "$fichier" "$id" "reindexation refusee"
      BESOIN_REINDEX=0
      return ;;
    admin/sync)
      # Sync SYNCHRONE (adr/0023) : l intention ne rend `ok` qu une fois le
      # miroir ALIGNE sur Drive. `sync_now()` (serveur) poll ce recu ; sans
      # cela il rendrait un faux ok des minutes avant le vrai sync.
      flock -u 9
      # Le script de sync prend le MEME verrou (/run/lock/vault-mirror.lock) et
      # le tient pendant TOUT le rclone sync : impossible de l appeler en
      # gardant le notre (flock traite chaque descripteur independamment : un
      # enfant qui herite de notre fd 9 puis rouvre le fichier se bloquerait
      # sur notre propre verrou). On le relache donc d abord, on execute le
      # script -- meme uid que l unite, aucune sudo requis -- puis on le
      # REPREND AVANT d ecrire le recu : aucun autre pousseur ne peut traiter
      # le lot ni re-synchroniser entre la fin du sync et le recu.
      if "$MIRROR_SYNC"; then
        if flock -w 3600 9; then
          terminer_ok "$fichier" "$id"
          BESOIN_REINDEX=0
          return
        fi
        # ARCHITECTURE A (conservateur) : AUCUN recu hors verrou. Sync
        # reussi mais verrou non repris dans le delai : PAS de ok. L intention
        # RESTE EN FILE (rejouable, idempotente) -- un passage suivant
        # re-synchronisera puis ecrira le recu sous verrou. Aucune suite de
        # traitement sans verrou.
        journal "id=$id sync reussi mais verrou non repris : intention laissee en file"
        exit 1
      fi
      # Echec du sync : recu d echec UNIQUEMENT verrou detenu (coherent avec
      # la suite du lot). Verrou introuvable : l intention RESTE EN FILE, un
      # passage suivant reessaiera -- jamais de recu contradictoire.
      if flock -w 3600 9; then
        terminer_echec "$fichier" "$id" "synchronisation echouee"
        return
      fi
      journal "id=$id sync en echec et verrou non retrouve : intention laissee en file"
      exit 1
      ;;
  esac

  local local_cible
  if ! local_cible="$(confiner "$chemin")"; then
    terminer_echec "$fichier" "$id" "chemin non confine dans le miroir"
    return
  fi

  # Controle optimiste de concurrence : la note a-t-elle change depuis que le
  # MCP l a lue (T0) ? v4.1 : la verification porte sur DRIVE a l execution
  # (md5 natif vs md5_attendu), jamais sur un snapshot miroir vieux de minutes.
  if [ -n "$md5_attendu" ] || [ -n "$sha" ]; then
    verifier_cas
    local verdict=$?
    case "$verdict" in
      1)
        terminer_echec "$fichier" "$id" "conflit"
        return ;;
      3)
        # Indetermine (reseau/API) : ne RIEN toucher, l intention reste
        # rejouable. Refuser d agir vaut mieux que supprimer a l aveugle.
        terminer_echec "$fichier" "$id" "etat Drive indetermine"
        return ;;
      2)
        if [ "$op" != "delete" ]; then
          # Divergence reelle pour update/move : Drive n a plus la note.
          terminer_echec "$fichier" "$id" "note absente sur Drive"
          return
        fi
        # delete + deja absent sur Drive : l etat final vise est atteint cote
        # autorite. On n enterre que le miroir s il existe encore, et ok --
        # idempotent, donc rejouable apres crash.
        if [ -e "$local_cible" ]; then
          mkdir -p "$(dirname "$CORBEILLE_LOCALE/$STAMP/$chemin")"
          mv -f "$local_cible" "$CORBEILLE_LOCALE/$STAMP/$chemin"
        fi
        terminer_ok "$fichier" "$id"
        return ;;
    esac
  fi

  case "$op" in
    create|update)
      if [ "$op" = "create" ] && [ -e "$local_cible" ]; then
        terminer_echec "$fichier" "$id" "la note existe deja"
        return
      fi
      local tampon
      tampon="$(mktemp)" || { terminer_echec "$fichier" "$id" "mktemp"; return; }
      if ! printf '%s' "$contenu_b64" | base64 -d > "$tampon" 2>/dev/null; then
        rm -f "$tampon"
        terminer_echec "$fichier" "$id" "contenu illisible"
        return
      fi
      if ! rclone copyto "$tampon" "$DISTANT/$chemin" "${RCLONE_OPTS[@]}"; then
        rm -f "$tampon"
        terminer_echec "$fichier" "$id" "envoi vers Drive refuse"
        return
      fi
      if ! confirmer_sur_drive "$chemin"; then
        rm -f "$tampon"
        terminer_echec "$fichier" "$id" "non confirme sur Drive"
        return
      fi
      # Rafraichissement cible du miroir, verrou toujours detenu.
      # Le 0644 n est pas cosmetique : `mktemp` cree en 0600, et le MCP tourne
      # sous `juliann-app`. Sans ce chmod, la note fraichement ecrite est
      # introuvable en lecture -- exactement le \"trouvable mais illisible\" que
      # l adr/0012 a corrige. Aligne sur les 0644 poses par rclone.
      if ! cp -f "$tampon" "$local_cible" || ! chmod 0644 "$local_cible"; then
        # Drive a bien la note, mais le miroir non : le prochain rclone sync
        # reparera. Ne PAS rapporter ok -- un succes mensonger est pire qu un
        # echec, il fait croire que la note est lisible alors qu elle ne l est pas.
        rm -f "$tampon"
        terminer_echec "$fichier" "$id" "ecrit sur Drive mais miroir non rafraichi"
        return
      fi
      rm -f "$tampon"
      terminer_ok "$fichier" "$id"
      ;;

    delete)
      if [ -z "$md5_attendu" ] && [ ! -e "$local_cible" ]; then
        # Rejeu v1 (sans md5 on ne sait rien de l etat Drive) : deja absent
        # localement, l etat final vise est atteint. Succes, pas echec -- sinon
        # un rejeu apres crash echouerait toujours.
        terminer_ok "$fichier" "$id"
        return
      fi
      # v4.1 : on n arrive ici que si Drive contient encore la note (le verdict
      # 2 du CAS a deja couvert le cas Drive absent). Miroir vide ou non, la
      # corbeille Drive est l etat final a atteindre.
      # `rclone moveto` vers un dossier date, et non `rclone delete` : le
      # comportement de ce dernier vis-a-vis de la corbeille Drive depend de
      # --drive-use-trash et n est pas garanti stable.
      if ! rclone moveto "$DISTANT/$chemin" "$DISTANT/$CORBEILLE_DISTANTE/$STAMP/$chemin" \
           "${RCLONE_OPTS[@]}"; then
        terminer_echec "$fichier" "$id" "mise a la corbeille Drive refusee"
        return
      fi
      if ! confirmer_absence_sur_drive "$chemin"; then
        terminer_echec "$fichier" "$id" "suppression non confirmee sur Drive"
        return
      fi
      if [ -e "$local_cible" ]; then
        mkdir -p "$(dirname "$CORBEILLE_LOCALE/$STAMP/$chemin")"
        mv -f "$local_cible" "$CORBEILLE_LOCALE/$STAMP/$chemin"
      fi
      terminer_ok "$fichier" "$id"
      ;;

    move)
      local local_nouveau
      if [ -z "$cible" ] || ! local_nouveau="$(confiner "$cible")"; then
        terminer_echec "$fichier" "$id" "chemin cible non confine dans le miroir"
        return
      fi
      if [ -e "$local_nouveau" ]; then
        terminer_echec "$fichier" "$id" "la note cible existe deja"
        return
      fi
      if ! rclone moveto "$DISTANT/$chemin" "$DISTANT/$cible" "${RCLONE_OPTS[@]}"; then
        terminer_echec "$fichier" "$id" "deplacement sur Drive refuse"
        return
      fi
      if ! confirmer_sur_drive "$cible"; then
        terminer_echec "$fichier" "$id" "deplacement non confirme sur Drive"
        return
      fi
      mv -f "$local_cible" "$local_nouveau" 2>/dev/null
      terminer_ok "$fichier" "$id"
      ;;

    mkdir)
      # create_folder : dossier VIDE. Le miroir ne garde que des notes ; on
      # cree donc cote Drive (source de verite) puis localement, pour que
      # l etat final soit atteint des deux cotes. mkdir est idempotent : un
      # rejeu apres crash est sans effet, et un dossier deja present reussit.
      if [ -e "$local_cible" ] && [ ! -d "$local_cible" ]; then
        terminer_echec "$fichier" "$id" "un fichier occupe deja ce chemin"
        return
      fi
      if ! rclone mkdir "$DISTANT/$chemin" "${RCLONE_OPTS[@]}"; then
        terminer_echec "$fichier" "$id" "creation du dossier sur Drive refusee"
        return
      fi
      if ! confirmer_sur_drive "$chemin"; then
        terminer_echec "$fichier" "$id" "dossier non confirme sur Drive"
        return
      fi
      if ! mkdir -p "$local_cible"; then
        terminer_echec "$fichier" "$id" "dossier local non cree"
        return
      fi
      terminer_ok_sans_reindex "$fichier" "$id"
      ;;

    *)
      terminer_echec "$fichier" "$id" "operation inconnue : $op"
      ;;
  esac
}

# ---------------------------------------------------------------------- main
main() {
[ -d "$SPOOL/queue" ] || { journal "spool absent, rien a faire"; exit 0; }

# Sortie immediate si la file est vide : le .path unit peut se declencher sur
# un fichier deja traite par le passage precedent.
shopt -s nullglob
en_file=("$SPOOL"/queue/*.json)
[ ${#en_file[@]} -gt 0 ] || exit 0

# Verrou PARTAGE avec vault_mirror_sync.sh. Sans le meme flock des deux cotes,
# ce verrou ne protege de rien. Attente alignee sur TimeoutStartSec du sync.
exec 9>"$VERROU"
if ! flock -w 3600 9; then
  journal "verrou vault-mirror non obtenu"
  exit 1
fi

BESOIN_REINDEX=0

# Tri lexicographique = tri chronologique : le nom porte time_ns sur 19 chiffres.
for fichier in $(printf '%s\n' "${en_file[@]}" | sort); do
  [ -f "$fichier" ] || continue
  traiter "$fichier"
done

# Purges alignees sur la retention de vault_mirror_sync.sh.
find "$SPOOL/done" "$SPOOL/failed" -maxdepth 1 -type f -name '*.json' \
     -mtime +$RETENTION_JOURS -delete 2>/dev/null
find "$SPOOL/tmp" -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null

flock -u 9

# Reindexation DEBOUNCEE. `scripts/reindex.py` n est pas incremental : il
# revectorise les 5 600 notes, plusieurs minutes de CPU. `systemd-run --unit=`
# avec un nom fixe REMPLACE le timer transitoire s il existe deja : dix
# ecritures en dix minutes ne produisent qu une seule reindexation, dix minutes
# apres la derniere. Debounce vrai, sans etat applicatif a gerer.
#
# `--no-block` ici aussi, pour une raison differente et tout aussi concrete : sans
# lui, l unite transitoire reste ACTIVE pendant toute la reindexation (constate le
# 2026-09-06 : vault-reindex-debounce.service bloque sur `systemctl start` de
# 14:42:45 a la fin de la passe). Or le nom `--unit=vault-reindex-debounce` est
# fixe : tant qu il est occupe, tout re-armement echoue et le journal se contente
# d un « debounce de reindexation non arme » (constate a 13:53:47). Les ecritures
# faites pendant une reindexation perdaient donc silencieusement leur indexation.
if [ "$BESOIN_REINDEX" = "1" ]; then
  sudo -n systemd-run --unit=vault-reindex-debounce --on-active=10min \
              --timer-property=AccuracySec=30s \
              systemctl start --no-block vault-reindex.service >/dev/null 2>&1 \
    || journal "debounce de reindexation non arme"
fi

# Purge de la corbeille Drive, meme retention que la corbeille locale.
# Les horodatages sont au format YYYYMMDDTHHMMSSZ, donc triables et comparables
# comme des CHAINES. La version precedente calculait un age en jours par
# arithmetique bash sur des sous-chaines de date : elle plantait le script en
# status=2 (erreur de syntaxe a l execution, invisible pour `bash -n`).
limite="$(date -u -d "-$RETENTION_JOURS days" +%Y%m%dT%H%M%SZ)"
while read -r dossier; do
  horodatage="${dossier%/}"
  case "$horodatage" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T*) ;;
    *) continue ;;
  esac
  if [[ "$horodatage" < "$limite" ]]; then
    rclone purge "$DISTANT/$CORBEILLE_DISTANTE/$horodatage" "${RCLONE_OPTS[@]}" 2>/dev/null       && journal "corbeille Drive purgee : $horodatage"
  fi
done < <(rclone lsf "$DISTANT/$CORBEILLE_DISTANTE/" --dirs-only "${RCLONE_OPTS[@]}" 2>/dev/null)

exit 0
}

# Garde d execution : executable directement, mais SOURCABLE par les tests
# unitaires bash (qui n appellent que les fonctions, sans jamais lancer main).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
