# homelab-ops

Scripts d'exploitation d'un serveur self-hosted (sauvegardes, synchronisation,
supervision DNS, durcissement, notifications) — les briques « cron / systemd timers »
d'un homelab. Exécutables installés dans `/usr/local/bin`, pilotés par des unités
systemd dédiées.

## Scripts

| Script | Rôle | Déclencheur type |
|---|---|---|
| `vault_backup.sh` | Sauvegarde **chiffrée** (GPG clé publique seule) de volumes Docker sensibles, arrêt à froid, envoi rclone + rétention | timer quotidien |
| `vault_mirror_sync.sh` | Synchronisation rclone (Drive → miroir local) du vault de connaissances | timer (toutes les 30 min) |
| `vault_spool_push.sh` | Consommateur FIFO du spool d'écriture : applique les intentions du MCP sur Drive (CAS, confinement anti-symlink, corbeille) puis rafraîchit le miroir | path/timer (20 s) |
| `dns_hub_watch.sh` | Surveillance de la chaîne DNS (Pi-hole → Unbound → dnsproxy DoH) : probes par maillon, réparation ciblée, alerte seulement sur changement d'état | timer (5 min) |
| `security_scan.sh` | Scan de sécurité (signatures, état) avec notification | timer quotidien |
| `pihole_history_archive.sh` | Archivage de l'historique Pi-hole | timer (6 h) |
| `ssh_login_success.sh` | Notification des connexions SSH réussies (PAM `open_session`), cooldown, nom du pair VPN, alertes après échecs | PAM |
| `notify_failure.sh` | Notification d'échec d'une unité systemd (`journalctl` redacté, HTML Telegram) | `OnFailure=` |
| `google-bypass.sh` | Sort le trafic Google de WARP par la route directe (iptables mark + ip rule), préfixes rafraîchis depuis `goog.json` | timer (5 min) |
| `netbird-staged-update.sh` | Mise à jour par étapes du serveur NetBird auto-hébergé | timer dédié |
| `nic-tuning.sh` | Tuning NIC (txqueuelen, RPS/XPS) au boot | service one-shot |

## Dépendances d'environnement

Les scripts lisent leurs secrets/paramètres dans l'environnement (fichiers 0600 hors
Git) ou via des helpers locaux (`send_telegram.sh`, remote `rclone`) : **aucune valeur
réelle n'est embarquée**. Variables principales :

- `vault_backup.sh` : `CIBLES` (`projet:répertoire:volume[,volume…]`), `RECIPIENT` (clé GPG
  publique), `REMOTE` (remote rclone borné), `STAGING`, `RETENTION_JOURS`.
- `vault_spool_push.sh` : `VAULT_SPOOL`, `VAULT_MIRROR`, `VAULT_REMOTE` (`gdrive:…`),
  `VAULT_TRASH`, `VAULT_LOCK`, `MIRROR_SYNC`.
- `notify_failure.sh` : appelle `send_telegram.sh` (jeton Telegram injecté par l'appelant).
- `ssh_login_success.sh` : appelé par PAM avec `PAM_SERVICE/PAM_TYPE/PAM_USER/PAM_RHOST` ;
  notifie via `send_telegram.sh`.

## Notes

- Tous les scripts sont **idempotents** et sûrs à relancer.
- `vault_spool_push.sh` est sourçable par des tests bash (`BASH_SOURCE[0] == $0`).
- Les adresses IP privées / identifiants machine des originaux ont été remplacés par
  des exemples (plage `198.51.100.0/24`, TEST-NET) : paramétrez selon votre déploiement.
