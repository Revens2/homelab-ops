# Unités systemd — chaîne ConvIA

Déployées sur `vps-etude`. Copie versionnée : ces fichiers vivent dans
`/etc/systemd/system/`, ils sont ici pour la traçabilité et la reconstruction.

| Fichier | Rôle |
|---|---|
| `convia-queue.{service,timer}` | réconcilie `pending_analysis` avec le miroir, toutes les 5 min |
| `convia-sanitize.service.d/20-publication-rag.conf` | publie vers le Vault après la sanitization **A**, plus après l'analyse Gemini |
| `vault-mcp.service.d/20-convia.conf` | ouvre `/var/lib/vault-mcp` dans un service en `ProtectSystem=strict` |
| `sudoers.d/vault-mcp-llm-wiki` | privilège minimal : une seule commande, une seule unité |

## Pourquoi le drop-in de publication

Jusqu'au 2026-09-06, la seule chose qui versait les conversations dans
`Obsidian Vault/raw/assets/ConvIA` était un `ExecStartPost` de
`convia-analyse.service`. Conséquences mesurées :

- une conversation n'atteignait le RAG qu'**après** la méta-analyse Gemini —
  25,8 h de retard médian ;
- neutraliser Gemini aurait coupé l'alimentation du RAG sans que rien ne le signale.

La publication appartient au transport, pas à l'analyse. Elle est donc rattachée à
`convia-sanitize`, où une conversation est publiable dès qu'elle est assainie.
L'`ExecStartPost` de `convia-analyse` est laissé en place : `rclone copy` est
idempotent, et le retirer serait un second changement à valider séparément.

`copy` et non `sync` : le Drive « Conv IA » est une file de travail dont l'analyse
**déplace** les fichiers vers `Traité/`. Un `sync` effacerait du Vault tout ce qui
a été déplacé entre deux passages.

## Installation

```bash
sudo install -m 0644 systemd/convia-queue.service systemd/convia-queue.timer /etc/systemd/system/
sudo install -D -m 0644 systemd/convia-sanitize.service.d/20-publication-rag.conf \
  /etc/systemd/system/convia-sanitize.service.d/20-publication-rag.conf
sudo install -D -m 0644 systemd/vault-mcp.service.d/20-convia.conf \
  /etc/systemd/system/vault-mcp.service.d/20-convia.conf
sudo install -m 0440 systemd/sudoers.d/vault-mcp-llm-wiki /etc/sudoers.d/vault-mcp-llm-wiki
sudo visudo -c -f /etc/sudoers.d/vault-mcp-llm-wiki
sudo systemctl daemon-reload
sudo systemctl enable --now convia-queue.timer
```

## Retour arrière

Supprimer le fichier concerné puis `systemctl daemon-reload`. Aucun de ces ajouts
ne supprime quoi que ce soit d'existant.
