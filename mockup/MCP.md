# Serveur MCP de Cartouche

Mis à jour le 2026-10-19 : ajout des consoles (RetroArch) et des contrôles. Les outils PC sont livrés en P11, les outils consoles en P12, les outils de contrôle en P13.

Date : 2026-10-18. But : qu'un agent (Claude, ou tout client MCP) pilote Cartouche : installer, régler, lancer, diagnostiquer.

## Architecture

- **SDK** : `modelcontextprotocol/swift-sdk` (0.12.1), version du protocole `2026-07-28`. Même langage que l'app.
- **Transport local stdio** : un petit binaire `cartouche-mcp` dans l'app (`Contents/Helpers/`). Le client MCP le lance, il parle à l'app par XPC. C'est le mode par défaut pour Claude Desktop et Claude Code.
- **Transport HTTP** (optionnel) : `http://127.0.0.1:<port>/mcp`, désactivé par défaut, avec un jeton affiché dans Réglages. Jamais exposé hors de la machine.
- **L'app reste la seule source de vérité** : le serveur MCP appelle les mêmes fonctions que l'interface. Tout ce que fait l'agent apparaît dans l'app en direct (activité, notifications).

## Permissions

Trois niveaux, réglés dans Réglages > Agents :

| Niveau | Ce que l'agent peut faire |
|---|---|
| **Read only** | Lire la bibliothèque, les réglages, les FPS, les logs |
| **Standard** (défaut) | + lancer, installer, changer runner/backend/réglages d'un jeu |
| **Full** | + commandes dans un prefix (winetricks, registre, exe arbitraire) |

- **Confirmation dans l'app** pour tout ce qui supprime, dépense de l'espace ou exécute un exe : une notification « Claude wants to install CarX Street (28 GB). Allow? ». L'agent attend la réponse.
- Un **journal des actions** de l'agent dans Réglages > Agents, avec annulation quand c'est possible (réglages d'un jeu).
- Jamais : mots de passe des boutiques, jetons, fichiers hors du dossier de l'app et des dossiers que l'utilisateur a donnés.

## Outils (tools)

### Bibliothèque
Les outils de bibliothèque couvrent **tous les jeux** : PC (Steam, boutiques, installeurs) et consoles. `list_games(source?)` accepte `steam`, `epic`, `gog`, `amazon`, `installer` ou une console (`snes`, `ps1`…).

| Outil | Rôle |
|---|---|
| `list_games(filter?, source?, installed?)` | Jeux avec état, source, setup, dernière session |
| `get_game(game)` | Fiche complète : setup, FPS perso, estimation pour ce Mac, anti-cheat Linux, versions Mac/Windows |
| `search_store(store, query)` | Chercher dans une boutique connectée |
| `set_favorite(game, on)` / `hide_game(game)` | Organisation |

### Installation
| Outil | Rôle |
|---|---|
| `install_from_store(store, game)` | Télécharge et installe depuis Steam, Epic, GOG, Amazon |
| `analyze_installer(path)` | L'analyse d'InstallerKit : parties, manquantes, MD5, Inno, décompression, espace, nom reconnu |
| `install_from_installer(path, options)` | Lance l'install. Options : `mode` (guided/automatic), `runner`, `backend`, `install_dir`, `language`, `components` |
| `get_install_status(job)` | Progression, phase, vitesse, CPU, dernières lignes du log Inno |
| `retry_install(job, fixes)` | **Plan B quand ça plante** : `fixes` parmi `verify_files`, `single_thread` (limite les threads des décompresseurs), `lower_memory` (réduit `Memory=` dans CLS.ini), `short_path`, `other_runner`, `rosetta_only`, `copy_to_internal_disk` |
| `cancel_install(job)` / `pause_download(game)` | Contrôle |
| `choose_executable(game, exe)` | Après install, ou pour corriger un mauvais choix |
| `cleanup_installer(path)` | Met les fichiers d'install à la corbeille (confirmation) |

### Réglages d'un jeu et FPS
| Outil | Rôle |
|---|---|
| `get_game_config(game)` | Runner, backend, Rosetta/FEX, variables d'env, DLL overrides, résolution, HUD |
| `set_game_config(game, changes)` | Modifie un ou plusieurs réglages, renvoie l'ancien état (annulable) |
| `set_version(game, mac or windows)` | Lancer la version Mac native ou la version Windows via Steam Play |
| `suggest_fps_boost(game)` | Liste d'actions classées par gain attendu, avec sources : backend plus rapide selon MacGamingDB, MetalFX, résolution, `DXMT` vs `D3DMetal`, MSync, désactiver la VSync, FEX vs Rosetta |
| `benchmark(game, setups[], seconds)` | Lance le jeu avec chaque setup, mesure FPS moyen et 1 % low, quitte, compare. L'utilisateur doit être d'accord (le jeu s'ouvre) |
| `compare_setups(game)` | Tes sessions passées, par setup |
| `apply_recommended_setup(game)` | Le setup le plus signalé comme fonctionnel |

### Runners et moteur
| Outil | Rôle |
|---|---|
| `list_runners()` / `install_runner(name)` / `set_default_runner(name)` | Gestion des runners et backends |
| `run_winetricks(game, verbs[])` | Niveau Full. Ex : `vcrun2022`, `d3dx9` |
| `registry_get(game, key)` / `registry_set(...)` | Niveau Full |
| `run_in_prefix(game, exe, args)` | Niveau Full, confirmation à chaque fois |

### Consoles (via RetroArch), livré en P12
Cartouche lance son RetroArch avec `--mcp-stdio` et garde le canal. Ses outils restent **ceux de Cartouche** : l'agent ne parle jamais directement à RetroArch, Cartouche filtre et applique les niveaux d'accès.

| Outil | Rôle | Commande RetroArch derrière |
|---|---|---|
| `list_consoles()` / `add_console(system)` / `remove_console(system)` | Consoles affichées, cores téléchargés ou supprimés (fichiers de jeux jamais touchés) | Buildbot libretro |
| `scan_game_folders()` / `add_console_games(paths[])` | Reconnaissance par empreinte (No-Intro, Redump), console déduite | Base libretro |
| `identify_file(path)` | Nom, console, empreinte, jaquette, core conseillé | Base libretro + fichiers `.info` |
| `get_bios_status(system?)` | BIOS présents, manquants, MD5 attendu. Jamais de lien de téléchargement | Fichiers `.info` des cores |
| `launch_console_game(game, core?, state?)` | Lance le jeu, éventuellement depuis une sauvegarde | `LOAD_CONTENT`, `--entryslot` |
| `list_states(game)` / `save_state(slot)` / `load_state(slot)` | La Time Machine : sauvegardes avec leur image | `STATE`, images des sauvegardes |
| `screenshot()` | Capture du jeu en cours | `SCREENSHOT` |
| `set_look(game, original|crt|lcd)` | Shader | `SET_SHADER` |
| `set_core(game, core)` / `set_core_option(...)` | Changer de core, régler une option | `LOAD_CORE`, `SET_CORE_OPTION` |
| `set_input_lag(game, on)` | Run-ahead | `RUNAHEAD_TOGGLE`, config |
| `host_netplay()` / `join_netplay(host)` | Jouer à deux | `--host`, `--connect` |
| `get_achievements(game)` | Succès débloqués et restants | RetroAchievements |
| `swap_disc(n)` | Disques des jeux PlayStation | `DISK_NEXT`, `.m3u` |
| `translate_screen()` | Traduction de l'écran (service configuré) | `AI_SERVICE` |

**Coach mode** (niveau Full, expérimental) : `read_game_state(game)` et `watch(game, value)` lisent la mémoire du jeu (`READ_CORE_MEMORY`, `WATCH`, `RUN_UNTIL`) avec des adresses nommées issues des définitions RetroAchievements (« lives », « health »). **Jamais d'entrée envoyée en mode Hardcore** : RetroArch la refuse déjà (`SET_INPUT`), et Cartouche refuse avant lui.

### Contrôles, livré en P13
| Outil | Rôle |
|---|---|
| `list_controllers()` | Manettes connectées, type, batterie |
| `get_controls(game)` | Qui gère la disposition (Steam Input, Cartouche, RetroArch) et le mapping actuel |
| `set_controls(game, mapping)` | Jeux PC hors Steam : écrit `SDL_GAMECONTROLLERCONFIG` pour le lancement. Consoles : fichier de remap RetroArch. Jeux Steam : refusé, renvoie vers Steam Input |
| `set_keyboard_mouse(game, options)` | Cmd comme Ctrl, Option comme Alt, souris gardée dans la fenêtre, défilement précis (pilote Mac de Wine) |
| `set_controller_for_keyboard_game(game, layout)` | Manette vers clavier et souris pour un jeu qui n'accepte que le clavier (autorisation Accessibilité requise, demandée par l'app, jamais par l'agent) |

### Lancement et diagnostic
| Outil | Rôle |
|---|---|
| `launch_game(game, setup?)` / `quit_game(game)` / `force_quit(game)` | Contrôle du jeu |
| `get_running()` | Jeu en cours, FPS en direct, CPU, GPU, mémoire |
| `get_logs(game, source, tail?, grep?)` | `source` : wine, game, installer, steam, launcher |
| `get_crash_report(game)` | Dernier plantage : code de sortie, dernières lignes utiles, DLL en cause |
| `diagnose(game)` | Analyse automatique du dernier échec : DLL manquante, backend incompatible, anti-cheat, mémoire. Renvoie des correctifs à appliquer avec `set_game_config` |
| `get_compatibility(game)` | MacGamingDB, AppleGamingWiki, ProtonDB (Linux), anti-cheat |
| `report_result(game)` | Partage le résultat sur MacGamingDB, seulement si l'utilisateur l'a activé |

### Système
| Outil | Rôle |
|---|---|
| `get_mac_info()` | Puce, GPU, RAM, macOS, espace disque |
| `get_storage()` | Place prise par jeu, prefix, installeurs à nettoyer |
| `get_activity()` | Téléchargements, installs, mises à jour en cours |

## Ressources (resources)

- `cartouche://consoles/{system}` : console, core, BIOS, nombre de jeux.
- `cartouche://games/{id}/states` : sauvegardes d'un jeu console avec leurs images.

- `cartouche://games/{id}` : fiche JSON d'un jeu.
- `cartouche://logs/{id}/{source}` : log, mis à jour en direct (abonnement).
- `cartouche://installs/{job}` : état d'une install.

## Prompts prêts à l'emploi

- **« Add my ROM folder »** : `scan_game_folders` → `add_console` pour les consoles trouvées → `get_bios_status` → liste de ce qui manque.
- **« Help me past this part »** (Coach mode) : `read_game_state` → conseil, `save_state` avant l'essai si le joueur le demande.
- **« My controller does the wrong thing »** : `get_controls` → `set_controls` → relance.

- **« Why won't this game start? »** : `get_crash_report` → `diagnose` → propose les correctifs.
- **« Make it run faster »** : `suggest_fps_boost` → `benchmark` sur 2 ou 3 setups → applique le meilleur.
- **« Install the game in my Downloads »** : `analyze_installer` → `install_from_installer` → `retry_install` si erreur → `choose_executable`.

## Idées en plus

- **Notifications vers l'agent** : l'install a fini, le jeu a planté. L'agent peut réagir sans qu'on lui demande.
- **Profils partagés** : exporter/importer le setup d'un jeu en JSON, pour qu'un agent applique un setup trouvé ailleurs.
- **Mode « nuit »** : l'agent installe et benchmarke la file d'attente pendant que le Mac est branché.
