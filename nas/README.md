# NAS — stockage unifié SSD + HDD

Debian 12, portable reconverti. Configuration non secrète ; identifiants disques, mots de passe et remotes réels restent sur la machine (`/etc/nas/`).

## Architecture (depuis 2026-09-15)

```
/srv/storage            mergerfs  (partage Samba [Stockage], Nextcloud /Stockage)
├── branche /srv/tier/ssd   ext4 sur SSD entier   (label nas-ssd)
└── branche /srv/tier/hdd   ext4 sur bcache0 sans cache (HDD 2 To, données durables)

/srv/nas-fast/rag-cache  image ext4 loop à taille fixe sur l'eMMC système (cache RAG reconstructible, jamais sauvegardé)
```

- Écriture : `category.create=ff` + `minfreespace=40G` → nouveaux fichiers sur le SSD tant qu'il reste 40 G, sinon HDD.
- `Rapide/` n'existe que sur la branche SSD et n'est jamais déplacé : il peut occuper presque tout le SSD.
- `nas-ssd-mover` (timer horaire) : au-delà de 75 % d'occupation SSD, déplace les fichiers hors `Rapide/` les moins accédés vers le HDD jusqu'à 55 %. Chemin logique inchangé.
- `posix_acl=true` est obligatoire sur le montage mergerfs, sinon les ACL (www-data de Nextcloud) sont ignorées.
- Ce n'est pas un cache : un fichier récent hors `Rapide/` n'existe que sur le SSD jusqu'au passage du mover. La copie hors site (rclone → Drive) lit `/srv/storage` et exclut `Rapide/`.
- `Non-sauvegarde/` : dossier du HDD monté en bind sur `/srv/storage/Non-sauvegarde` (jamais sur le SSD, jamais déplacé), exclu de rclone et de restic.
- Pourquoi pas bcachefs : absent du noyau Debian 12, retiré du mainline (6.17), exigeait de reformater aussi le HDD.

## Opérations lourdes

Toute opération I/O lourde passe par `nas-heavy <nom> <commande>` : verrou `flock` global (une seule à la fois) et pause globale si `/etc/nas/heavy-io.paused` existe (`NAS_HEAVY_FORCE=1` pour forcer). Concerne rclone, génération d'aperçus, scan Nextcloud, backup restic local, mover SSD.

`nas-data-backup` refuse de tourner sans `/etc/nas/data-backup.gate-ok`, posé à la main uniquement quand la capacité du disque de backup est prouvée suffisante.

## Contenu

- `sbin/` : scripts installés dans `/usr/local/sbin`.
- `systemd/` : unités et drop-ins (`smbd`/`docker`/`rclone` exigent le montage `/srv/storage`).
- `fstab.example` : lignes de montage, UUID à remplacer.

## Rollback vers bcache

Arrêter smbd, copyparty, docker ; démonter `/srv/storage` ; déplacer le contenu non-Rapide de la branche SSD vers le HDD ; remonter `bcache0` sur `/srv/storage` ; recréer éventuellement un cache (`make-bcache -C` + `attach`).
