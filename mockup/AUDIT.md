# Audit UX de la maquette

Date : 2026-10-19. Fichier : `mockup/launcher.html`. Chaque état s'ouvre depuis « Mockup state », en bas à gauche de la page.

## Ce que le premier audit a raté

Le premier passage vérifiait seulement que rien ne plantait. Il n'a pas cliqué les parcours comme un utilisateur. Résultat : il a laissé passer une impasse (impossible de revenir de « Console Games » à « Windows Game ») et une fiche console surchargée. Ce second passage clique chaque parcours et regarde chaque écran.

## Deuxième passage (2026-10-19) : trouvé et corrigé

| Problème | Correction |
|---|---|
| Impossible de revenir de « Console Games » à « Windows Game » dans la feuille + | Un seul sélecteur, qui marche dans les deux sens ; même largeur de feuille dans les deux modes |
| Pas de retour depuis l'identification des jeux console | Bouton Back |
| Fiche console surchargée (8 sections, textes d'explication partout) | Fiche équilibrée : reprendre une sauvegarde, temps joué et succès, Setup (core, rendu, latence, Hardcore), Controls, Play Together. Traduction, Coach mode et BIOS derrière « More… ». Plus aucun texte d'explication dans la fiche |
| Le bouton de la barre d'outils disait « Install Game… » alors qu'il ajoute aussi des jeux console | « Add Games… » |
| Le titre de section répétait le titre de la barre d'outils (« Super Nintendo » puis « Super Nintendo 3 ») | Les titres de section n'apparaissent que dans All Games |
| Les boîtes SNES et N64, en paysage, laissaient un grand vide dans des cartes verticales | Cartes carrées pour les consoles |
| Après « Stop » d'une installation, la barre latérale affichait encore « Installing » | Corrigé |
| Impossible de retirer une console ajoutée | Clic droit sur la console : « Remove » (les jeux restent sur le disque) ou « Add Games… » |
| Customize ouvert depuis Details ne permettait pas d'y revenir | Bouton Back |
| Réglages : avec 8 onglets, « General » et « Controllers » étaient coupés | Fenêtre plus large, onglets resserrés |
| Texte de 4 lignes sous la version de RetroArch | Une phrase |

## Boutons visibles mais pas branchés dans la maquette

Ils ouvriront un vrai parcours dans l'app. Dans la maquette, cliquer dessus ne fait rien : Change…, Remove (dossiers), Add Folder…, Download (runners), View All, Update, Test, Sign Out, Show…, Show Log, Show Installer Window, Show Folder, Set Up…, Run (Homebrew), Results, Open in Steam, Locate Steam…, Learn More, Join…, How to Get It, Free Up Space…, Add to Claude, Undo, Change (touches).

## Méthode du premier passage

- **Balayage automatique** : les 12 entrées de la barre latérale, les 18 fiches de jeu, chaque feuille Details, les 13 états, les 6 onglets de Réglages, les 8 menus, chaque menu contextuel, et les feuilles Add Consoles, Console Games et accueil. Résultat : 0 erreur JavaScript.
- **Scan du texte** : aucun point médian, tiret long, point d'exclamation, mot creux (« seamless », « powerful », « magic »…) ou bouton générique (« OK », « Submit »).
- **Vérification des faits** : chaque version, source et capacité affichée vérifiée le 2026-10-19 (releases GitHub, code source, Homebrew).
- **Passe visuelle** : clair et sombre, chaque écran.

## Écrans et états

| Écran | États |
|---|---|
| Bibliothèque | Données, chargement (squelettes), vide (accueil), recherche, aucun résultat, favoris vides, hors ligne |
| Sources PC | Steam connecté, Steam absent (installeur Valve, Homebrew, Locate), Epic/GOG/Amazon non connectés, attente, connectés, session expirée |
| Consoles | Une entrée par console ajoutée, console vide, feuille Add Consoles (seuls les cores choisis se téléchargent, BIOS requis signalé, jeux déjà trouvés affichés) |
| Jaquette | Installé, non installé (noir et blanc), sélectionné, téléchargement (révélation WebGL), pause, échec, en jeu (halo vert), favori |
| Fiche jeu PC | Play, lancement, en jeu, plantage (Try DXMT, Show Log), téléchargement (progression, pause, échec avec Try Again), Install, version Mac ou Windows, Your Play, estimation, anti-cheat Linux, rapports graphiques, setup, feuille Details |
| Fiche jeu console | Resume ou Play, Time Machine, succès, rendu (Original, CRT, LCD), jeu à deux, setup (core, latence, BIOS, disques, traduction), Coach mode, allumage CRT au lancement |
| Ajouter (+) | Jeu Windows : 6 étapes (dépôt, analyse, revue, install avec révélation de la jaquette, choix de l'exe, prêt), partie manquante, arrière-plan. Jeux console : dépôt, reconnaissance par empreinte, fichier inconnu, console ajoutée |
| Bas de barre latérale | En jeu, installation, téléchargement (anneau App Store, pause, échec), mise à jour, masqué |
| Réglages | General, Library (dossiers de jeux), Accounts, Compatibility (runners), Privacy, Agents (MCP), Consoles (version de RetroArch, cores, BIOS, RetroAchievements, défauts) |
| Menus | Barre des menus (7 menus + icône d'état), menu contextuel, notifications |

## Corrigé pendant cet audit

| Problème | Correction |
|---|---|
| **Le runner gratuit « Wine CrossOver par Gcenx » n'existe pas.** Gcenx ne publie aucun build CrossOver aujourd'hui. | CodeWeavers publie le code source de CrossOver 26.3.0 (LGPL) : notre CI le compile. Corrigé dans la maquette, la spec P2, le plan et la roadmap. « Wine Staging 11 » devient le vrai build WineHQ « Wine 11.18 ». |
| Le « code de salle » du jeu en ligne n'existe pas dans RetroArch | « Tes amis te trouvent dans le lobby netplay de RetroArch » |
| La traduction d'écran semblait gratuite et immédiate | Elle demande un service de traduction ; une ligne de Réglages a été ajoutée |
| Coach mode semblait fini | Marqué Experimental ; exemples qui ne parlent plus de Zelda |
| « Overlay » Epic non vérifié | « Depends on the game » |
| Mise à jour DXMT 0.71 | La dernière version est 0.80 (2026-04-23) |
| L'état « aucun résultat » trouvait les Zelda rétro | Recherche sans résultat possible |
| Une taille de téléchargement inventée dans l'accueil | Retirée |
| L'état « Normal » laissait Epic connecté | Réinitialisé |

## Faisabilité de chaque fonction

| Fonction | Réalisable ? | Sur quoi elle repose |
|---|---|---|
| Steam Play avec runners gratuits | Oui, à construire | Hooks NotProton, sources CrossOver, offsets ntdll par build |
| Version Mac ou Windows | Oui | Outil de compatibilité forcé dans Steam (README NotProton) |
| Estimation par Mac | Oui | API publique MacGamingDB, puce et FPS par rapport |
| Anti-cheat Linux | Oui | `games.json` d'AreWeAntiCheatYet, export mensuel ProtonDB |
| Analyse d'un installeur Windows | Oui, codé | InstallerKit + innoextract, testé sur un vrai installeur |
| Exécution de l'installeur | Oui, à construire | Options Inno `/DIR /LOG /LANG`, prefix Wine |
| Jeux des boutiques | Oui | legendary, gogdl, comet, nile |
| Mesure des FPS | Probable | Compteur d'images Metal injecté dans Wine, à prouver en P8 |
| Pause des téléchargements Steam | Probable | API du client Steam via le code injecté par NotProton, à prouver en P7 |
| Serveur MCP | Oui | SDK MCP Swift officiel |
| Wrapper RetroArch | Oui | GPL-3.0, projet Xcode dans le dépôt, serveur MCP sur master (`--mcp-stdio`) |
| Time Machine, succès, rendus, netplay, run-ahead, disques | Oui | Fonctions et commandes de RetroArch |
| Coach mode | Expérimental | Outils mémoire du MCP de RetroArch, adresses par jeu issues de RetroAchievements |
| Traduction d'écran | Oui, avec configuration | Service IA de RetroArch + un service de traduction |

## Encore ouvert

- Vue liste et tri réel.
- Page plein écran d'un jeu (captures, notes de version).
- Plusieurs comptes Steam sur un même Mac.
- Navigation au clavier dans la grille.
- Contrôles (manette, clavier et souris) : voir `docs/research/controls.md`.
