# Plan du fork NotProton

Note : les phases numérotées plus bas (Phase 0 à 6) sont le premier brouillon. Le plan à suivre est `docs/ROADMAP.md` (P0 à P18) et `openspec/changes/`.

Date : 2026-10-18. Statut : brouillon, rien n'est codé.

## Choix validés

- **Produit** : intégration Steam conservée + lanceur pour les .exe hors Steam.
- **Runners** : Wine CrossOver libre, **compilé par notre CI** à partir des sources que CodeWeavers publie (LGPL), Wine officiel WineHQ, et Game Porting Toolkit. Correction du 2026-10-19 : Gcenx ne publie pas de build CrossOver prêt à l'emploi.
- **Suivi** : fork indépendant. On ne suit plus l'upstream automatiquement.
- **Jeux installés depuis un .exe** : raccourci Steam + bibliothèque interne.

- **Nom** : **Cartouche** (cartouche de jeu, et l'ovale qui encadre un nom en hiéroglyphes). Libre sur le Mac App Store, Homebrew et GitHub.
- **Icône** : concept « Label », une cartouche de face dont l'étiquette est un bouton play en pixels. Sources dans `mockup/brand/` (fond + premier plan séparés pour Icon Composer, versions Default et Dark, glyphe de barre des menus). Variantes Clear et Tinted à produire dans Icon Composer.
- **Langue de l'app** : anglais.
- **Stack** : SwiftUI natif, en réutilisant l'app existante (`app/`).
- **Maquette** : `mockup/launcher.html`. Style macOS 26 avec Liquid Glass, vraies données MacGamingDB et AppleGamingWiki.

## À décider avant de coder



## Données de compatibilité

- **MacGamingDB** remplace ProtonDB. API REST publique `macgamingdb.app/api/rest/games/<steam appid>` (code MIT, aucune licence publiée pour les données : lues en direct par l’app, jamais redistribuées, ADR 0013).
- Chaque rapport contient la puce (M1 à M5, Base/Pro/Max/Ultra), la méthode (natif, CrossOver), la couche (D3DMetal, DXMT, DXVK), la note, les FPS et les réglages.
- **Estimation pour la machine de l'utilisateur** : détecter la puce (`sysctl machdep.cpu.brand_string`), garder les rapports de Macs proches (GPU entre 0,7x et 1,4x), puis afficher la note médiane, les FPS moyens et les réglages les plus courants.
- Si moins de 3 rapports proches : prendre les 5 Macs les plus proches.
- **AppleGamingWiki** en complément : modèle `{{Compatibility/macOS}}` (native, rosetta 2, crossover, wine, parallels). Pas de requêtes Cargo : lecture du wikitext page par page, avec un cache. Licence CC BY-NC-SA 3.0, source à citer.
- Bouton « Use » : appliquer la couche la plus signalée comme fonctionnelle.

## Périmètre (2026-10-19)

- **Un seul périmètre** : les phases P0 à P16 sont toutes construites avant la première version publique, **v0.1.0**. Voir `docs/ROADMAP.md`.
- **Les consoles sont une fonction principale** : RetroArch intégré et piloté par MCP (P12), bibliothèque console (P13), extras (P14), contrôles (P15), émulateurs autonomes (P16).

## Décisions de livraison (2026-10-18)

- **Signature** : toujours gratuite (ad-hoc). Pas de notarisation. Premier lancement via Réglages Système > « Ouvrir quand même ». Distribution par un **tap Homebrew perso** (les casks officiels refusent les apps non notarisées depuis le 1er septembre 2026).
- **Mises à jour** : Sparkle + `appcast.xml` dans les GitHub Releases, signé par une clé EdDSA gardée dans les secrets de la CI (comme NotProton).
- **macOS minimum** : 15 Sequoia. Liquid Glass sur macOS 26, rendu de repli (matériaux classiques) sur 15. FEX seulement sur 26.
- **Specs** : OpenSpec (`openspec/specs`, `openspec/changes`), une change par phase, critères d'acceptation stricts.
- **Données de compatibilité** : un workflow GitHub Actions de nuit agrège AppleGamingWiki, ProtonDB (export ODbL) et AreWeAntiCheatYet, puis publie un JSON. MacGamingDB est lu en direct par l’app. Pas de serveur.
- **Veille amont en CI** : nouvelles versions de NotProton, sources CrossOver de CodeWeavers, Wine WineHQ, DXMT, GPTK, client Steam → issue ou PR automatique.
- **Orchestration** : Claude (Opus) chef, orchestrateur et relecteur. Sous-agents Sonnet effort moyen pour la recherche web et pour la documentation. Sous-agents de code par phase.

## Sortir une mise à jour de l'app

### Côté développeur
1. PR fusionnée sur `main` : la CI compile et lance les tests.
2. Version et changelog générés à partir des messages de commit (release-please).
3. Tag `vX.Y.Z` → workflow de release :
   - compile l'app ;
   - la signe avec **notre certificat auto-signé** (gratuit, voir plus bas) ;
   - crée le zip, puis `appcast.xml` signé avec la clé EdDSA de Sparkle (secret CI), avec mises à jour delta ;
   - publie le tout dans une GitHub Release ;
   - met à jour le cask du tap Homebrew (version + sha256).

### Côté utilisateur
- Sparkle vérifie `https://github.com/<org>/<repo>/releases/latest/download/appcast.xml` une fois par jour.
- Fenêtre « Une mise à jour est disponible » avec les notes de version, téléchargement, vérification EdDSA, installation, relance.
- Canal **Beta** optionnel dans Réglages (canaux Sparkle).
- Mise à jour **critique** possible (flag dans l'appcast), pour les cassures après une mise à jour de Steam.

### Ce qui ne demande pas de mise à jour de l'app
- Runners, backends (DXMT, DXVK), données de compatibilité : téléchargés à part via un manifeste JSON publié par la CI. La plupart des correctifs passent par là.

### Piège de la signature gratuite
- Avec une signature ad-hoc, **chaque build a une identité différente**. Après une mise à jour, macOS oublie les autorisations (accès aux manettes, dossiers) et le Trousseau redemande l'accès aux jetons des boutiques.
- Parade gratuite : créer **une fois** un certificat de signature auto-signé, le garder dans les secrets de la CI, et signer toutes les versions avec. L'identité reste stable, donc les autorisations et le Trousseau aussi.
- Gatekeeper avertit toujours au **premier** lancement (pas de notarisation), mais plus aux mises à jour : Sparkle installe sans quarantaine.

### Phase 0 obligatoire
- Nouvelle clé EdDSA et nouveau `SUFeedURL`. Sinon l'app se mettrait à jour vers NotProton.

## Règles d'interface (anti AI slop)

- La fiche d'un jeu répond à trois questions : **puis-je jouer, à quelle vitesse, avec quel setup**. Le reste va dans « Details ».
- **Un seul chiffre de performance** visible : tes FPS si tu as joué, sinon l'estimation pour ton Mac.
- Pas de bloc d'information répété (une source = un endroit). Les sources sont citées une fois, en bas de « Details ».
- Les suggestions n'apparaissent que si elles changent quelque chose (« Most players use D3DMetal » seulement si ce n'est pas déjà le cas).
- Pas d'en-tête de section pour un seul élément. Les réglages rares (Rosetta/FEX, HUD) sont dans « Details », les runners dans Réglages.
- Pas de décor sans rôle : pas de dégradés, de badges, d'étoiles de notation ni de couleurs qui ne portent pas d'état.

## Phase 0 — Séparer le fork de NotProton

But : les deux apps peuvent coexister sans se casser.

- Choisir un **nom** et un **bundle ID** propres.
- Changer le dossier `~/Library/Application Support/notproton`.
- **Couper l'auto-update** vers l'appcast upstream (`AppUpdater.swift`). Sinon l'app se remplace par NotProton.
- Retirer la cask brew upstream du README.
- Signature : un certificat auto-signé unique et stable (gratuit), voir « Décisions de livraison ». Pas de notarisation.

## Phase 1 — Abstraction des runners

But : CrossOver n'est plus un cas spécial.

- Un modèle de runner avec trois types : CrossOver, Wine (notre build CrossOver ou WineHQ), GPTK.
- Généraliser `CrossOverSource`, `RunnerStore`, `RunnerInstaller`, `SupportedRunner`.
- **Wine CrossOver compilé par nous** : construit en CI depuis les sources CodeWeavers, publié en release, téléchargé par l'app avec hash épinglé (`PinnedDownload` existe déjà).
- **GPTK** : jamais embarqué (licence). L'utilisateur l'installe, l'app le **détecte** et le copie dans `runners/`.
- Patch `ntdll` : épingler les RVA de chaque build avec `ntdll-patch/resolve.py`.
- Les tests existants doivent rester verts.

## Phase 2 — Backends graphiques

- Un champ `backend` dans `CompatTool` : D3DMetal, DXMT, DXVK, wined3d.
- `compat_run.sh` pose les DLL overrides et variables d'env selon le backend.
- DXMT et DXVK : téléchargés par l'app, hash épinglé.
- D3DMetal : pris dans le GPTK ou le CrossOver installé.

## Phase 3 — Sélecteur dans Steam

- Un compat tool Steam par combinaison runner + backend + CPU.
- Exemple : `GPTK 3 · D3DMetal · Rosetta`, `Wine-CX 26 · DXMT · FEX`.
- Masquer les combinaisons impossibles (FEX avant macOS 26, D3DMetal sans GPTK ni CrossOver).

## Phase 4 — Installeur .exe (setup.exe + .bin)

Détails déjà écrits dans `fork-notproton-brainstorm.md`, section 4 bis.

- Import d'un **dossier**, vérification des `.bin` et du `.md5`.
- Prefix dédié, installeur Inno lancé avec `/DIR` connu d'avance.
- Contrôle d'espace disque, suivi de progression.
- Redistribuables via winetricks, pas les `vcredist` fournis.
- Choix du .exe final, pré-sélectionné.

## Phase 5 — Bibliothèque et raccourci Steam

- **Bibliothèque interne** : liste des jeux, jaquette, bouton Jouer, réglages par jeu (runner, backend, CPU, env).
- **Raccourci Steam** : écrire dans `shortcuts.vdf`, en réutilisant `usershortcuts.c`.
- Une seule source de vérité : la bibliothèque. Le raccourci Steam la lance.

## Phase 6 — Autres boutiques (Epic, GOG, Amazon…)

### Ce qui existe déjà en open source sur Mac (vérifié le 2026-10-18)

| Projet | Rôle | Licence | État |
|---|---|---|---|
| Heroic Games Launcher | Launcher Epic, GOG, Amazon. Tourne sur Mac avec Wine, GPTK ou CrossOver | GPL-3.0 | Très actif, 12k étoiles |
| legendary | Client Epic en ligne de commande, utilisé par Heroic et Mythic | GPL-3.0 | Actif |
| heroic-gogdl | Téléchargement GOG en ligne de commande | GPL-3.0 | Actif |
| nile | Client Amazon Games en ligne de commande | GPL-3.0 | Mis à jour en février 2026 |
| comet | Fonctions en ligne de GOG Galaxy (succès, amis) sans Galaxy | Apache-2.0 | Actif |
| itch (butler) | Client itch.io, natif Mac | MIT | Actif |
| Mythic | Launcher Mac en Swift, Epic + import manuel, Steam pas encore | GPL-3.0 | Actif |
| Whisky | Wrapper Wine en SwiftUI | GPL-3.0 | Archivé |
| Playnite, Lutris | Bibliothèques multi-boutiques | MIT, GPL-3.0 | Windows ou Linux seulement |

### Comment les intégrer

- **Epic, GOG, Amazon** : embarquer les CLI `legendary`, `gogdl` et `nile`, comme Heroic. Même licence GPL-3.0 que le fork.
- **GOG hors ligne** : déjà couvert par l'installeur (setup.exe + .bin).
- **EA app, Ubisoft Connect, Battle.net, Rockstar** : pas de client libre. On installe leur launcher Windows dans un prefix, avec un préréglage par launcher.
- **itch.io** : via `butler`, beaucoup de jeux ont une version Mac native.

### Ce qui nous distingue de Heroic et Mythic

- L'intégration **Steam Play** directement dans Steam, héritée de NotProton.
- L'**estimation par Mac** (FPS, réglages) avec MacGamingDB.
- Une interface **native SwiftUI** en Liquid Glass.

## Récupérer la bibliothèque Steam

Recommandé : **lire la bibliothèque depuis Steam lui-même**, via le code que NotProton injecte déjà dans l'interface de Steam (`dylib/feats/webpatch.c`).

- Ce code utilise déjà `window.appStore.m_mapApps` (toutes les apps du compte) et `SteamClient.Apps.SpecifyCompatTool`.
- On y ajoute un export : jeux possédés, collections (`collectionStore`), temps de jeu, dernière session, jeux installés.
- L'export est écrit dans le dossier de l'app, puis relu par la bibliothèque. Le canal exact (fichier, route locale) reste à choisir.
- Avantages : pas de clé API, marche hors ligne, inclut les jeux privés, les collections et les jeux non installés.

Repli quand Steam est fermé :
- Dernier export gardé en cache.
- Jeux installés : `steamapps/libraryfolders.vdf` et les fichiers `appmanifest_<appid>.acf`.
- Compte : `config/loginusers.vdf`.

Écarté :
- **Steam Web API** (`IPlayerService/GetOwnedGames`) : demande une clé API à l'utilisateur et un profil public.
- **Connexion Steam directe** (protocole Steam) : complexe, et l'utilisateur taperait son mot de passe dans notre app.

## Mesurer les FPS de l'utilisateur

But : afficher la moyenne de FPS de l'utilisateur sur un jeu, et comparer les setups (runner + backend + Rosetta/FEX) qu'il a essayés.

### Mesure
- D3DMetal, DXMT et DXVK (via MoltenVK) finissent tous par afficher des images avec **Metal**. Un seul point de mesure suffit pour les trois.
- Une petite bibliothèque injectée dans le processus Wine compte les images présentées (`CAMetalLayer nextDrawable` ou `presentDrawable`). NotProton injecte déjà du code avec Dobby, la technique est connue du projet.
- Elle doit exister en x86_64 (Rosetta) et en arm64 (FEX).
- Échantillon chaque seconde. On ignore les 30 premières secondes, les écrans de chargement et les moments où la fenêtre n'est pas au premier plan.
- Par session : durée, FPS moyen, 1 % low, résolution, setup utilisé.

### Stockage et affichage
- Base locale (SQLite) dans le dossier de l'app. Rien n'est envoyé par défaut.
- Moyenne **pondérée par le temps de jeu**, pour qu'un test de 5 minutes ne fausse pas tout.
- Fiche du jeu : « Your average », « 1% low », temps joué, meilleur setup.
- Bouton « Compare N Setups » : tableau par setup, avec un bouton pour appliquer le meilleur.
- Option « Share results with MacGamingDB », désactivée par défaut : envoie le modèle de Mac, le setup, les réglages et les FPS, jamais le compte.

### À vérifier
- Que l'injection marche avec chaque runner (les binaires signés avec le hardened runtime peuvent la bloquer).
- Que le compte d'images reste juste quand le jeu limite ses FPS ou utilise la synchro verticale.

## Anti-cheat

Remplacé le 2026-10-19 : l'app ne donne **aucun verdict pour Mac**. Elle reprend ce que disent ProtonDB (export mensuel, ODbL) et AreWeAntiCheatYet (MIT) **pour Linux**, avec les chiffres (« Online works on Linux, 26 of 26 reports »). Voir la spec P4 et l'ADR 0009.

## Lancer un jeu Windows

Un seul moteur pour tout : **runner (Wine) + backend graphique + Rosetta ou FEX + un prefix par jeu**. Seule la façon de démarrer change selon la source.

| Source | Qui télécharge | Qui lance |
|---|---|---|
| Steam | Steam Mac, qui prend la version Windows quand un outil de compatibilité est forcé | `steam://rungameid/<appid>`. Steam appelle l'outil de compatibilité de NotProton (`compat_run.sh`), qui démarre le runner |
| Epic | `legendary` | `legendary launch`, avec le Wine et le prefix choisis |
| GOG | `gogdl` | L'app lit le fichier `goggame-<id>.info` (exe + arguments) et démarre le runner. `comet` pour les fonctions en ligne |
| Amazon | `nile` | Même principe : nile donne l'exe, l'app démarre le runner |
| Installeur .exe | L'installeur lui-même | L'app démarre l'exe choisi dans son prefix |

- Le réglage « runner + backend » d'un jeu Steam s'écrit dans la config de Steam (`CompatToolMapping`), pour que Steam utilise le même choix.
- Les CLI `legendary`, `gogdl`, `nile` et `comet` sont embarquées dans l'app : rien à installer pour Epic, GOG et Amazon. Il suffit de se connecter.
- **Steam doit être installé** sur le Mac. Sinon : bouton « Download Steam » (installeur officiel de Valve), ou `brew install --cask steam` si Homebrew est présent, ou « Locate Steam… ».
- Le compte connecté s'affiche pour chaque boutique (Steam : lu dans `loginusers.vdf`).

## Risques

- **Mises à jour Steam** : les hooks du dylib peuvent casser. En fork indépendant, il faut reporter les correctifs upstream à la main.
- **Chaque nouvelle build Wine** demande de recalculer les RVA ntdll.
- **Licence D3DMetal** : ne jamais le mettre dans le dépôt ni dans une release.
- **Disques NTFS / exFAT** : non supportés par NotProton aujourd'hui.

## Ordre conseillé

Phase 0 → 1 → 2 → 3 côté Steam. La phase 4 peut démarrer après la phase 1, en parallèle des phases 2 et 3.
