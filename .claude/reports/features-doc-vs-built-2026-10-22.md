# Fonctionnalités promises par la doc vs code construit — 2026-10-22

Audit en lecture seule de la branche d'intégration `origin/claude/sleepy-cerf-8bbse7` (HEAD `f2ab4a8`). Rien n'est compilé dans ce conteneur Linux : **BUILT** veut dire « code présent et branché dans l'UI ou le flux », pas « prouvé à l'exécution ». Les vérifications réelles (Steam, stores, matériel, machine propre) restent celles listées dans `docs/ROADMAP.md` (« Still required before v0.1.0 »).

Sources lues : `docs/PRD.md`, `docs/TRD.md`, `docs/ROADMAP.md`, `docs/RETROARCH.md`, `docs/FPS-MEASUREMENT.md`, `docs/PRIVACY.md`, `README.md`, `CHANGELOG.md`, `openspec/specs/**`, `openspec/changes/**` (tasks.md), titres des ADR `docs/adr/`, `mockup/MCP.md` (liste d'outils citée par la TRD), et les anciens rapports `.claude/reports/feature-audit.md` et `product-gap-audit-2026-10-22.md` (re-vérifiés).

Abréviations des chemins : `NPA/` = `app/Sources/NotProtonApp/`, `RAK/` = `retroarch/Sources/RetroArchKit/`, `IK/` = `installer/Sources/InstallerKit/`.

Statuts : **BUILT** · **PARTIAL** (ce qui manque est dit) · **MISSING** · **DEFERRED** (la doc le renvoie à une version ultérieure) · **IN PROGRESS (branche)** (travail non fusionné listé par le mainteneur).

## 1. Résumé

| Statut | Nombre |
|---|---|
| BUILT | 136 |
| PARTIAL | 16 |
| MISSING | 4 |
| DEFERRED | 4 |
| IN PROGRESS | 13 |
| **Total** | **173** |

Par zone :

| Zone | BUILT | PARTIAL | MISSING | DEFERRED | IN PROGRESS |
|---|---|---|---|---|---|
| Bibliothèque | 20 | 2 | 1 | 0 | 2 |
| Steam | 8 | 1 | 0 | 0 | 1 |
| Stores | 11 | 1 | 0 | 0 | 2 |
| Installeurs | 18 | 1 | 1 | 1 | 1 |
| Wine / runners | 10 | 2 | 0 | 0 | 2 |
| Graphismes et performances | 9 | 2 | 0 | 1 | 3 |
| Consoles / RetroArch | 17 | 1 | 0 | 0 | 1 |
| Réglages / onboarding / contrôles / permissions | 16 | 2 | 1 | 0 | 1 |
| Mises à jour / release | 9 | 4 | 0 | 0 | 0 |
| Agent / MCP | 9 | 0 | 1 | 0 | 0 |
| Autres (compatibilité, identité) | 9 | 0 | 0 | 2 | 0 |

Note : « Manette visible dans les jeux Windows » (Réglages) et « Cartouche Wine 26.3.0-2 » (Wine) sont le même manque, compté deux fois. Le « Compteur FPS » est BUILT pour les jeux Steam seulement.

Changements notables par rapport à l'ancien `feature-audit.md` (2026-10-20), désormais faux : Favoris (n'est plus désactivé : `NPA/Library/GameActions.swift:58,268`, `NPA/App/AppCommands.swift:65` est seulement désactivé sans sélection), vérification de l'installation (était MISSING, maintenant BUILT), archives et CrossOver/Cartouche Wine par défaut (étaient IN-FLIGHT, maintenant fusionnés), sauvegardes cloud Epic/GOG (maintenant codées).

## 2. Tableaux par zone

### Bibliothèque

| Fonctionnalité | Source doc | Statut | Preuve / manque |
|---|---|---|---|
| Import complet de la bibliothèque Steam (jeux possédés et installés, données de jeu) | PRD Library 1 ; spec game-library ; ADR 0021-0022 | BUILT | `NPA/Library/Steam/SteamLibraryImport.swift:1,83-94`, `NPA/Library/Steam/SteamLocalFiles.swift:163` ; contrôle réel de fraîcheur et de changement de compte en attente (`openspec/changes/steam-export/tasks.md:10-11`) |
| Steam fermé : dernier export, marqué « peut être périmé » | PRD Library 5 ; ADR 0021 | BUILT | `NPA/Library/LibraryModel.swift:324`, `NPA/Activity/Views/ActivityViews.swift:337` |
| Steam absent : Download Steam, Install with Homebrew, Locate Steam… | PRD Library 6 | BUILT | `NPA/Library/Views/LibraryStates.swift:203-256`, `NPA/Library/Steam/SteamSetup.swift:59` |
| Jeux non installés en noir et blanc, couleur à la sélection | PRD Library 2 ; spec game-library | BUILT | `NPA/Library/Views/GameCard.swift:101` |
| Révélation progressive de la jaquette (shader Metal, Reduce Motion) | spec activity ; TRD P7 | BUILT | `NPA/Activity/Reveal/CoverReveal.swift:13-14`, `NPA/Activity/ActivityCenter.swift:76-80` ; mesure Instruments M1 non faite (`archive/…p7…/tasks.md:11`) |
| Recherche (« No games match », Clear Search) | PRD Library 3 ; spec game-library | BUILT | `NPA/Library/LibraryModel.swift:79,232`, `NPA/Library/Views/LibraryWindow.swift:430,455` |
| Favoris (étoile sur la jaquette, ⌘D) | PRD Library 3 ; spec game-library | BUILT | `NPA/Library/Views/GameCard.swift:196`, `NPA/Library/GameActions.swift:58,268` |
| Masquer / réafficher des jeux | PRD Library 3 | BUILT | `NPA/Library/LibraryModel.swift:202,217`, `NPA/Library/Views/SettingsWindow.swift:187-198` |
| Barre latérale PC / Consoles, une seule entrée Add Games | spec game-library « Built for PC and console games » | BUILT | `NPA/Library/Views/LibraryWindow.swift:20,63`, `NPA/App/AppCommands.swift:8` |
| Panneau du jeu : Play, estimation, anti-cheat Linux, graphismes rapportés, setup, Details | PRD Library 4 ; spec game-library | BUILT | `NPA/Library/Views/GamePanel.swift:36-176`, `NPA/Compatibility/CompatibilityPanel.swift:22-24`, `NPA/Library/Views/GameDetailsSheet.swift:43-89` |
| Jaquettes PC (cache/CDN Steam, art du store, image déposée, repli nom + icône exe) | spec game-library « Covers for PC games » | BUILT | `NPA/Library/CoverStore.swift:28,99`, `NPA/Library/Views/GameCard.swift:146-148` |
| Recherche de jaquette Steam soumise au choix de confidentialité | spec game-library ; ADR 0019 | BUILT | `NPA/Library/Views/LibraryWindow.swift:289`, `NPA/Library/SteamLookup.swift:3` |
| Carrousel média du panneau | TRD « Library appearance » | BUILT | `NPA/Library/Views/GamePanel.swift:36` |
| Menus et raccourcis (⌘↩, ⌘I, ⌘D, ⌘F, ⌘,) | spec game-library « Keyboard and menus » | BUILT | `NPA/Library/GameActions.swift:57-59`, `NPA/App/AppCommands.swift:22` |
| États d'écran (chargement, vide, hors ligne, session expirée, Steam absent, aucun résultat) | spec game-library « Screen states » | BUILT | `NPA/Library/Views/LibraryStates.swift` ; tests snapshot macOS 15/26 non faits (`archive/…p5…/tasks.md:23`) |
| Liquid Glass sur macOS 26, matériaux classiques sur 15, Reduce Motion/Transparency | spec game-library ; ADR 0004 | BUILT | `NPA/Library/Views/Glass.swift` ; validation macOS 15 en attente |
| Emplacement d'activité unique + menu de la barre des menus | spec activity ; TRD P7 | BUILT | `NPA/Activity/Views/ActivityViews.swift:17-22`, `NPA/App.swift:138-140` |
| Notifications (fin et échec de téléchargement/installation, avec actions) | spec activity ; PRIVACY | BUILT | `NPA/Activity/ActivityNotifier.swift:74-147`, `NPA/Installer/InstallNotifier.swift` |
| Rapports de crash locaux de l'app : Show Report, Copy Summary, Collect Diagnostics | PRD follow-ups ; ADR 0029 ; spec local-diagnostics | BUILT | `NPA/App/CrashNotice.swift:1-40`, `NPA/Library/Views/LibraryWindow.swift:406`, `NPA/Support/CrashReports.swift:317-334`, `NPA/Library/Views/SettingsWindow.swift:250` |
| Sondes de processus hors main actor (menu sans lsof/pgrep bloquant) | spec game-library ; TRD f9bb3d7 | BUILT | `NPA/Library/GameActions.swift:67` (état occupé en cache) |
| Après un crash, le panneau suggère un autre backend | PRD Steam Play 5 | PARTIAL | Seule une suggestion fondée sur les rapports existe (« Most players use X », `NPA/Library/Views/GamePanel.swift:353-359`). Rien ne réagit à un crash du jeu |
| Collections Steam | spec game-library « Steam library import » | PARTIAL | Lues (`NPA/Library/Steam/SteamLocalFiles.swift:170`, `SteamLibraryImport.swift:30`) mais jamais affichées : `SidebarItem` = all/favorites/source (`NPA/Library/LibraryModel.swift:4-8`) |
| Bandeau d'erreur (Play/Install/Uninstall qui échouent en silence) | PRD « names the likely cause » ; spec mac-permissions « never silent failure » | IN PROGRESS (wip/wp1-errors) | `LibraryModel.problem` (`NPA/Library/LibraryModel.swift:88`) n'est lu par aucune vue |
| Avis « le jeu a quitté de façon inattendue » (crash d'un jeu Windows) | PRD follow-ups (crash reports) | IN PROGRESS (wip/wp1-errors) | `NPA/Installer/InstallCenter.swift:359-377` garde la backtrace sans prévenir l'utilisateur |
| Vue liste, vrai tri, page plein écran, plusieurs comptes Steam, navigation clavier dans la grille | PRD « Release details and open questions » | MISSING | Aucun tri (`LibraryModel.swift:220-227`). La doc les classe en questions ouvertes, sans engagement pour 0.1.0 |

### Steam

| Fonctionnalité | Source doc | Statut | Preuve / manque |
|---|---|---|---|
| Setup par jeu écrit dans Steam (CompatToolMapping via SpecifyCompatTool) | PRD Steam Play 1-2 ; spec game-setup | BUILT | `NPA/Setup/SteamCompatChoice.swift:1-15,67`, `dylib/hooks/hook_compat.c:136-147` |
| Un outil de compatibilité Steam par paire runner · backend | TRD Runners ; spec game-setup | BUILT | `dylib/feats/compat.c:421-465` ; capture du menu Steam non faite (`archive/…p3…/tasks.md:15`) |
| Version Mac ou Windows pour un jeu qui a les deux | PRD Steam Play 4 ; spec game-setup | BUILT | `NPA/Setup/GameSetup.swift:11-12`, `NPA/Setup/LibrarySetup.swift:14` ; contrôle du dépôt réellement installé non fait |
| Export de la liste possédée (route WebUI, jeton par lancement, backoff) | TRD dylib ; ADR 0022 ; spec game-library | BUILT | `dylib/feats/webpatch.c:423-491`, `dylib/feats/libexport.c` ; contrôle réel après Repair en attente |
| Progression des téléchargements Steam, Pause/Reprise/Annuler | TRD P7 ; CHANGELOG | BUILT | `NPA/Activity/SteamDownloadCommands.swift:9-52`, `NPA/Activity/SteamDownloadMonitor.swift` ; test M1 sur vrai Steam en attente |
| Une action Repair (Quit Steam and Repair) + remise à jour automatique du dylib | ROADMAP E,F ; CHANGELOG | BUILT | `NPA/Views/StatusView.swift:538`, `NPA/Model/SteamUpkeep.swift:26-57`, `NPA/Permissions/SteamStep.swift` |
| Builds Cartouche Wine enregistrés comme outils Steam, sans CrossOver.app | TRD Runners (9214df4) ; README | BUILT | `NPA/Model/SupportedRunner.swift:108-109`, `dylib/feats/compat.c:464-465` |
| Show in Steam (raccourci non-Steam) | spec windows-installer | BUILT | `NPA/Installer/SteamShortcuts.swift:1-31` |
| WineHQ et GPTK comme outils Steam | TRD Runners ; spec runner-sources « Steam Play hooks on free builds » | PARTIAL | Il manque les offsets ntdll épinglés pour WineHQ/GPTK (TRD l.67) ; `archive/…p2…/tasks.md:9,19` non cochés |
| Jeu Steam affiché « en cours » + bouton Stop | (attendu par cohérence avec « Play becomes Stop », CHANGELOG) | IN PROGRESS (wip/wp5-game-tools) | `runningAppID` est lu (`NPA/Activity/SteamActivityReader.swift:8-62`) mais `running` ne couvre que store et installeur (`NPA/Library/GameActions.swift:67-74`) |

### Stores (Epic / GOG / Amazon)

| Fonctionnalité | Source doc | Statut | Preuve / manque |
|---|---|---|---|
| Connexion sur la page du store, jeton seul dans le Trousseau | PRD Stores 1 ; TRD P10 | BUILT | `NPA/Stores/StoreSignInWindow.swift:8,88`, `NPA/Stores/StoreVault.swift:1-27` ; vraie connexion non testée (P10 evidence) |
| Jeux du store dans la bibliothèque | PRD Stores 2 | BUILT | `NPA/Stores/StoreCenter.swift:299-322` |
| Installer / mettre à jour / vérifier / désinstaller | PRD Stores 3 ; TRD P10 | BUILT | `NPA/Stores/StoreCenter.swift:348-397`, `NPA/Stores/EpicAdapter.swift:86-106`, `AmazonAdapter.swift:90-100`, `GOGAdapter.swift:115-126` |
| Importer un dossier de jeu déjà installé | TRD P10 | BUILT | `NPA/Stores/StoreViews.swift:153`, `NPA/Stores/StoreCenter.swift:411`, `EpicAdapter.swift:109` |
| Lancement avec le même runner/backend que Steam | PRD Stores 3 ; TRD P10 | BUILT | `NPA/Stores/StoreCenter.swift:465-492` |
| Stop d'un jeu de store | TRD « Play becomes Stop » | BUILT | `NPA/Stores/StoreCenter.swift:624`, `NPA/Library/GameActions.swift:363` |
| Sauvegardes cloud Epic et GOG avant lancement et après sortie | TRD P10 ; tâche p10 3.2 | BUILT | `NPA/Stores/StoreCenter.swift:513-518,574` ; test réel sur deux Mac en attente (`p10-store-integrations/tasks.md:16`) |
| comet pour les fonctions en ligne GOG | TRD P10 | BUILT | `NPA/Stores/GOGAdapter.swift:25,164-166` |
| Page du store qui dit honnêtement ce que le client gère (Amazon : « Not supported yet ») | PRD Stores 4 ; TRD P10 | BUILT | `NPA/Stores/StoreViews.swift:45`, `NPA/Stores/StoreAdapter.swift:17-23`, `AmazonAdapter.swift:15` |
| Clients épinglés (version, taille, SHA-256), téléchargés au premier usage | TRD P10 | BUILT | `NPA/Resources/store-clients.json`, `NPA/Stores/StoreClients.swift:43-63`, `.github/workflows/store-clients.yml` |
| Jeux installés jouables quand la session a expiré | TRD P10 | BUILT | `NPA/Stores/StoreCenter.swift:289` (expire), `EpicAdapter.swift:139` (lancement hors ligne) |
| Mesure FPS pour les jeux de store (« same … FPS features as Steam games ») | PRD Stores 3 ; TRD P10 | PARTIAL | Même setup oui ; mais aucune injection du compteur dans les scripts store/installeur, et les sessions sont indexées par app_id Steam (`NPA/Performance/PerformanceStore.swift:12,62`). Voir Graphismes |
| Jobs de store en échec visibles dans Activity | (spec activity, PRD « never silent ») | IN PROGRESS (wip/wp1-errors) | `NPA/Stores/StoreCenter.swift:338-341` ne renvoie que les jobs en cours |
| Installations de store sous l'emplacement des jeux choisi | (onboarding : dossier des jeux) | IN PROGRESS (wip/wp2-location) | Toujours sous Application Support (`NPA/Stores/StoreCenter.swift:126`) |

### Installeurs (Add Games, installeur Windows, imports)

| Fonctionnalité | Source doc | Statut | Preuve / manque |
|---|---|---|---|
| Une feuille Add Games (+, dépôt sur la fenêtre, Choose…) avec détection automatique | PRD Add Games ; ADR 0024 ; spec windows-installer | BUILT | `NPA/App.swift:91`, `NPA/Library/Drop/DropClassifierAdapter.swift:8`, `IK/DropClassifier.swift:48-53` |
| Archives via libarchive embarqué (zip/zip64, 7z, tar.*, RAR4/5), archives chiffrées refusées | PRD installer 1 ; ADR 0016, 0023 ; spec archive-import | BUILT | `IK/Archive.swift:35-42`, `IK/DropClassifier.swift:256-258`, `installer/libarchive/pins` ; RAR réel de l'utilisateur non vérifié (`archives/tasks.md:10`) |
| Jeu extrait déplacé hors de `~/Library/Caches` (avec migration) | PRD installer 1 ; CHANGELOG | BUILT | `NPA/Installer/StagedGames.swift:1-3` |
| Analyse sans exécution (parties, parties manquantes, checksums, type, nom, espace) | PRD installer 2 ; spec windows-installer | BUILT | `IK/Analysis.swift:57,121`, `IK/PartScanner.swift`, `installer/scripts/no-exec-check.sh` ; preuve eslogger non faite (`archive/…p6…/tasks.md:8`) |
| Partie requise manquante bloque, partie optionnelle avertit | PRD installer 3 | BUILT | `NPA/Installer/InstallSheetModel.swift:295-296` |
| Installation dans un préfixe neuf sous Rosetta, progression réelle, en arrière-plan | PRD installer 4 ; TRD InstallerKit | BUILT | `NPA/Installer/InstallEngine.swift`, `NPA/Installer/InstallCenter.swift` |
| Échec : cause probable + nouvelles tentatives (verify files, fewer threads, less memory, short path, other runner) | PRD installer 5 | BUILT | `IK/RetryFixes.swift:16-31`, `NPA/Installer/InstallSheetView.swift:511` |
| Choix de l'exe de lancement, puis Starts With | PRD installer 6 ; CHANGELOG | BUILT | `NPA/Library/GameStartsWith.swift:52,77`, `NPA/Library/GameActions.swift:31-32,321-323` |
| Runtimes d'après les imports PE, un verbe winetricks à la fois, délai 300 s, Skip, Wine Mono pour .NET | PRD installer 6 ; ADR 0020 | BUILT | `NPA/Installer/InstallEngine.swift:20,578`, `IK/RuntimeScan.swift:3-24`, `IK/PEImports.swift:10` ; Wine Mono n'est livré qu'avec Cartouche Wine 26.3.0-2 (pas encore publié) |
| Fichiers d'installeur supprimés seulement sur demande, vers la Corbeille | PRD installer 7 | BUILT | `NPA/Installer/InstallerCleanup.swift:8`, `NPA/Installer/InstallSheetModel.swift:77` |
| Extraction directe (unarc-driver) + repli Try Again sur le vrai setup | PRD installer 8 ; ADR 0017, 0034 | BUILT | `NPA/Installer/InstallEngine.swift:95-309`, `NPA/Installer/InstallCenter.swift:185-200`, `helpers/unarc-driver.c`, `Makefile:598-602,694` ; 6 tâches ouvertes (`direct-unpack/tasks.md:5-11`), test bout en bout absent |
| Annuler un repack nettoie son dossier et son préfixe | ROADMAP K ; CHANGELOG | BUILT | `NPA/Installer/InstallCenter.swift:359-364`, `NPA/Installer/CancellableToolRunner.swift` |
| Désinstallation gérée vers la Corbeille + Keep save files ; un import en place ne supprime jamais la source | PRD installer 9 ; ADR 0018 | BUILT | `NPA/Installer/GameUninstall.swift:23-120` |
| Import d'un jeu déjà installé, en place (défaut) ou copié | README ; ADR 0018 | BUILT | `NPA/Library/Drop/DropViews.swift:303-313`, `NPA/Installer/GameCopy.swift` |
| Identification classée (ID de store, moteur, version exe, nom exe, dossiers) + repli Steam soumis au choix de confidentialité | PRD installer 10 ; ADR 0019 | BUILT | `NPA/Installer/GameMatcher.swift:5-9`, `NPA/Library/SteamLookup.swift:3`, `IK/EngineMetadata.swift`, `IK/PEVersion.swift` |
| Renommer et ré-identifier un jeu importé | ROADMAP ; CHANGELOG | BUILT | `NPA/Library/GameReidentify.swift:86`, `NPA/Library/Views/GamePanel.swift:61-67` |
| Vérification de la sortie : complète / tailles / non vérifié, Stop, Verify Files…, Retry / Keep Anyway / Cancel | PRD « Installation verification » ; ADR 0025-0026 ; spec windows-installer | BUILT | `NPA/Library/Verification/GameVerification.swift:10,43-78`, `GameVerificationCenter.swift:114,162`, `NPA/Installer/InstallCenter.swift:230`, `NPA/App/AppBootstrap.swift:86` |
| Optimisations qui ne changent que la vitesse (liste d'autorisation des helpers) | spec windows-installer ; ADR 0025 | BUILT | `IK/HelperAllowlist.swift` (liste vide, aucune substitution active, conforme à la doc) |
| Classification statique avec preuves et niveau de confiance (ADR 0028) | spec windows-installer « Static classification » ; TRD | PARTIAL | `DropOutcome` ne porte ni preuves ni confiance (`IK/DropClassifier.swift:38-53`) ; cas « preuves contradictoires montrées à l'utilisateur » absent. Tâche non cochée (`detection-localization-diagnostics-advanced/tasks.md:4`) |
| Suggérer les installeurs qui arrivent dans Téléchargements | PRIVACY (permission Downloads, P6) ; Info.plist | MISSING | Aucun observateur. La TRD dit qu'il a été retiré (l.185). Restes : `NPA/Onboarding/OnboardingState.swift:58`, `NPA/Onboarding/OnboardingModel.swift:553-565`, `app/Info.plist:55-56` |
| Plusieurs racines d'installation, jeux de l'ancien dossier toujours visibles | (onboarding : dossier des jeux, TRD) | IN PROGRESS (wip/wp2-location) | Un seul dossier scanné (`NPA/Installer/InstalledGame.swift:62`), lu une seule fois au lancement (`LibraryModel.swift:98`, `InstallEngine.swift:11`) |
| Mods et patches (lancer un .exe dans le préfixe du jeu, overrides DLL par jeu, ouvrir le C:) | ROADMAP « After v0.1.0 » (M) | DEFERRED (0.1.1) | Run Program… existe déjà au niveau du préfixe (`NPA/Views/PrefixesView.swift:398`) |

### Wine / runners

| Fonctionnalité | Source doc | Statut | Preuve / manque |
|---|---|---|---|
| Registre de runners avec états (available, installing, ready, damaged, unsupported) | TRD Runners ; spec runner-management | BUILT | `NPA/Model/Runner.swift:7-29`, `NPA/Model/RunnerRegistry.swift:38` |
| Détection de dommages par hash épinglé + Repair | spec runner-management | BUILT | `NPA/Model/RunnerStore.swift`, `NPA/Model/RunnerRegistry.swift:38` |
| Parité CrossOver (comportement inchangé) | spec runner-management | BUILT | `NPA/Model/CrossOverSource.swift`, `NPA/Model/SupportedRunner.swift` |
| Cartouche Wine épinglé et recommandé par défaut | PRD Goals ; ADR 0015, 0033 ; spec runner-sources | BUILT | `NPA/Resources/runners.json:5-18`, `NPA/Runners/FreeRunners.swift` ; contrôle matériel en attente (`crossover-default/tasks.md:12-13`) |
| WineHQ stable 11.0 / devel 11.18 épinglés | TRD Runners | BUILT | `NPA/Resources/runners.json:19-40` |
| Détection du Game Porting Toolkit (volumes, apps, kegs Homebrew, dossiers choisis) + import d'image disque | TRD Runners ; ADR 0032 | BUILT | `NPA/Runners/PortingToolkitSource.swift:24-104`, `NPA/Runners/PortingToolkitDMG.swift:12-52` |
| Premier démarrage sérialisé (`wineboot -u` puis `wineserver -w`), Show Log / Try Again / Recreate Prefix | TRD ; spec runner-sources | BUILT | `NPA/Setup/WineBootstrap.swift:5-68`, `NPA/Library/Views/GamePanel.swift:405-413`, `NPA/Stores/StoreCenter.swift:593-599` |
| Manifeste de runners distant, signé EdDSA | TRD Data stores ; P2 | BUILT | `NPA/Runners/RunnerManifest.swift:1,133-209`, `app/Info.plist` (`CartoucheRunnerManifestURL`) |
| Mises à jour de runners proposées | gap-audit (fait) ; TRD Sparkle | BUILT | `NPA/Runners/RunnerUpdate.swift:34-47` |
| Préfixes : liste, sauvegardes, restauration, winecfg, regedit, Run Program, Winetricks, Open Log | ROADMAP (Settings rework) ; TRD Settings | BUILT | `NPA/Views/PrefixesView.swift:83-406`, `NPA/Views/BackupsView.swift` |
| Cartouche Wine 26.3.0-2 (SDL3 pour les manettes, Wine Mono, Wine Gecko) | ROADMAP ; CHANGELOG ; TRD dépendances | PARTIAL | La recette a SDL3 (`packaging/wine-crossover/pins.env:13,28`). Mono et Gecko ne figurent pas dans la recette de ce dépôt. Pas publié : `runners.json` épingle encore `26.3.0-1` |
| Contrôle CI « boot + fenêtre » de Wine | change wine-ci-boot-check | PARTIAL | `.github/workflows/wine-crossover.yml:102`, `packaging/wine-crossover/boot-check.sh` ; résultat du run non enregistré (`wine-ci-boot-check/tasks.md:5`) |
| Sous-menu Wine Tools sur chaque jeu + Show Log | gap-audit item 9 | IN PROGRESS (wip/wp5-game-tools) | Outils seulement dans Réglages > Préfixes Wine (`NPA/Views/PrefixesView.swift:335-406`) |
| Cartouche Wine 26.3.0-3 : GStreamer | ROADMAP « After v0.1.0 » | IN PROGRESS (cartouche-wine 26.3.0-3) | Construit encore `--without-gstreamer` (`packaging/wine-crossover/build.sh:89`). La doc le place après 0.1.0 |

### Graphismes et performances

| Fonctionnalité | Source doc | Statut | Preuve / manque |
|---|---|---|---|
| Backends D3DMetal, DXMT, DXVK, wined3d choisis par jeu | PRD ; TRD P3 ; spec game-setup | BUILT | `NPA/Library/LibraryStore.swift:3-37`, `NPA/Library/Views/GraphicsMenu.swift` |
| DXMT 0.80 et DXVK épinglés (version, taille, SHA-256) | TRD ; spec game-setup « Pinned backends » | BUILT | `NPA/Resources/backends.json`, `NPA/Setup/BackendInstaller.swift:1-59` |
| Traduction CPU Rosetta / FEX | PRD Tinkerer ; TRD | BUILT | `NPA/Library/LibraryStore.swift:12-19`, `NPA/Setup/GameSetup.swift:97,152-164` |
| Backends indisponibles masqués + une entrée Get More Graphics Backends… | ADR 0027 ; TRD | BUILT | `NPA/Library/Views/GraphicsMenu.swift:29`, `NPA/Library/GameActions.swift:110`, `NPA/Setup/SetupDefaultsSection.swift:32` |
| D3DMetal seulement depuis le GPTK de l'utilisateur ; Get D3DMetal… | PRD Legal ; TRD ; CHANGELOG | BUILT | `NPA/Library/Views/GamePanel.swift:363-368`, `NPA/Setup/SetupEnvironment.swift` |
| Options avancées : MetalFX spatial, AVX, MSync, haute résolution, Metal HUD, DLSS DXMT | ADR 0030-0031 ; spec game-setup | BUILT | `NPA/Setup/AdvancedGameOptions.swift:25-66`, `NPA/Setup/GameSetup.swift:249`, `NPA/Setup/AdvancedPrefixSettings.swift:6-42`, `NPA/Library/Views/AdvancedGameRows.swift:43`, `GamePanel.swift:77` ; recherche « upscaling » non close (`detection-…/tasks.md:7`) |
| Compteur FPS injecté (hook CAMetalLayer nextDrawable), runner refusé = « FPS can't be measured » | TRD P8 ; FPS-MEASUREMENT | BUILT (jeux Steam) | `fps-counter/fps_counter.m`, `dylib/feats/compat_run.sh:1667-1770`, `NPA/Performance/YourPlayViews.swift:67` |
| Your Play, Compare Setups, étiquette « meilleur setup » | spec performance-tracking ; FPS-MEASUREMENT | BUILT | `NPA/Performance/YourPlayViews.swift:53-111`, `NPA/Performance/PlayStats.swift:80` |
| Estimation pour ce Mac + MacGamingDB lu en direct | PRD Goals ; spec compatibility-data | BUILT | `NPA/Compatibility/CompatEstimate.swift`, `NPA/Compatibility/MacGamingDB.swift`, `NPA/Library/GamePanelContent.swift:143` |
| FPS et temps de jeu pour jeux d'installeur et de store | PRD Stores 3 ; TRD P10 « same … FPS features » | PARTIAL | Les scripts de lancement installeur/store n'injectent pas le compteur (`NPA/Installer/InstalledGame.swift`, `NPA/Stores/StoreCenter.swift` : aucune référence) ; le stockage est indexé par app_id Steam (`PerformanceStore.swift:62`) |
| Précision ±1 fps et surcoût < 1 % par backend, sur un vrai jeu | PRD Success measures ; FPS-MEASUREMENT | PARTIAL | Banc synthétique présent (`fps-counter/tests`) ; injection réelle par runner et mesures par backend non faites (`archive/…p8…/tasks.md:6-7`) |
| Arguments de lancement et variables d'environnement par jeu | TRD « A game setup is runner, backend, CPU translation and environment variables » | IN PROGRESS (wip/wp4-launch-gfx) | Le modèle a `environment` avec une liste d'autorisation (`NPA/Library/LibraryStore.swift:9`, `NPA/Setup/GameSetup.swift:198-208`), réglable seulement par l'agent ; pas d'UI, pas d'arguments |
| DLSS via MetalFX et DXR pour D3DMetal | (gap-audit item 8) | IN PROGRESS (wip/wp4-launch-gfx) | Aujourd'hui la doc dit « D3DMetal DLSS is hidden » (TRD l.116) : elle devra changer |
| Import complet d'un ensemble GPTK assorti (matched set) | (research 2026-10-22) | IN PROGRESS (wip/wp4-launch-gfx) | Import d'image actuel : `NPA/Runners/PortingToolkitDMG.swift:49-52` |
| Partage opt-in des stats (FPS par setup) | ROADMAP v0.1.1 ; PRIVACY | DEFERRED (0.1.1) | Charge utile codée, UI masquée (`NPA/Performance/PerformanceSharing.swift:1`) |

### Consoles / RetroArch

| Fonctionnalité | Source doc | Statut | Preuve / manque |
|---|---|---|---|
| RetroArch compilé en CI depuis un commit épinglé, `--version` et `--mcp-stdio` vérifiés | RETROARCH.md ; ADR 0008 ; spec retroarch-runtime | BUILT | `.github/workflows/retroarch.yml:104-142`, `retroarch/scripts/check-retroarch.sh` |
| RetroArch **embarqué dans l'app publiée** et signé avec le certificat | TRD « Bundled RetroArch » ; PRD Consoles 5 | PARTIAL | `make retroarch-embed` ne tourne que dans `retroarch.yml:178`. `release.yml:59` appelle `app.yml`, qui fait `make app-payload` / `make app` (`app.yml:169-172`) sans RetroArch : une release n'embarquerait pas RetroArch |
| Pilotage par MCP stdio, repli sur les commandes UDP | RETROARCH.md ; TRD | BUILT | `RAK/MCP/MCPClient.swift`, `RAK/Session/NetworkCommands.swift`, `RAK/Session/RetroArchSession.swift` |
| Choix de version (incluse, release officielle, votre copie) + lien vers le source | TRD ; spec retroarch-runtime « Version choice » | BUILT | `RAK/Settings/ConsolesSettingsView.swift:4-83`, `RAK/Builds/OfficialRelease.swift` |
| Cores téléchargés par console, vérifiés taille + SHA-256 | RETROARCH.md ; spec retroarch-runtime | BUILT | `RAK/Cores/CoreManager.swift`, `RAK/Cores/CoreInfo.swift` |
| BIOS vérifiés par MD5, nommés, « Dump it from your own console » | PRD Legal ; spec retroarch-runtime | BUILT | `RAK/BIOS/BIOSChecker.swift`, `NPA/Consoles/ConsolePanel.swift:119` |
| Add Consoles | PRD Consoles 1 ; spec console-library | BUILT | `NPA/Consoles/AddConsolesSheet.swift` |
| Jeux ajoutés par checksum (Add Games) + dossiers surveillés dans Réglages > Bibliothèque | PRD Consoles 1 ; spec console-library | BUILT | `RAK/Identify/Identifier.swift`, `NPA/Consoles/ConsoleImportFlow.swift`, `NPA/Consoles/GameFolderWatch.swift`, `NPA/Onboarding/GameFolders.swift:73-87` |
| Jaquettes libretro | PRD Consoles 3 | BUILT | `RAK/Library/Thumbnails.swift` |
| Panneau console : Continue From, succès, look, input lag, hardcore, disques, BIOS | PRD Consoles 4 ; spec console-library | BUILT | `NPA/Consoles/ConsolePanel.swift:154-269`, `NPA/Consoles/ConsolePanelContent.swift:13-43` |
| Effet CRT à l'allumage | PRD Consoles 5 | BUILT | `NPA/Consoles/CRTPowerOn.swift` |
| Netplay (lobby, relais MITM, salles Bonjour) | PRD Console extras 1 ; spec console-extras | BUILT | `RAK/Extras/Netplay.swift`, `RAK/Extras/LocalNetplayBrowser.swift`, `NPA/Consoles/ConsoleExtrasViews.swift:19-89` ; vrai lobby non testé |
| RetroAchievements (compte, Hardcore) | PRD Console extras 2 | BUILT | `RAK/Extras/RetroAchievements.swift`, `NPA/Consoles/ConsolePanel.swift:265-269` |
| Traduction d'écran | PRD Console extras 3 | BUILT | `RAK/Extras/Translation.swift`, `NPA/Consoles/ConsoleExtrasViews.swift:106-114` |
| Coach mode (expérimental) dans l'app | PRD Console extras 4 | BUILT | `RAK/Extras/Coach.swift`, `NPA/Consoles/ConsoleExtrasViews.swift:118-122` (outils MCP du Coach : voir Agent) |
| Sauvegardes dans iCloud Drive | PRD Console extras 5 | BUILT | `RAK/Extras/CloudSaves.swift`, `RAK/Extras/ConsoleExtrasSettingsView.swift:44-45` |
| Émulateurs autonomes (Dolphin, PCSX2, PPSSPP, Azahar, xemu, Ryubing) détectés et lancés | PRD ; spec standalone-emulators | BUILT | `RAK/Standalone/EmulatorCatalog.swift:28-38`, `RAK/Standalone/EmulatorDetector.swift`, `NPA/Consoles/StandalonePlay.swift` |
| Suppression d'une console / d'un émulateur avec choix sur les fichiers | ROADMAP ; CHANGELOG | BUILT | `NPA/Consoles/ConsoleUninstall.swift` |
| Message quand un BIOS ou un core manque au lancement | PRD Legal (« reported by name ») | IN PROGRESS (wip/wp1-errors) | `ConsoleCenter.problem` est rempli (`NPA/Consoles/ConsolePlay.swift:126-159`) ; seul Réglages > Consoles le lit pour la suppression (`ConsoleCenter.swift:80`) |

### Réglages / onboarding / contrôles / permissions

| Fonctionnalité | Source doc | Statut | Preuve / manque |
|---|---|---|---|
| Onboarding v2 en sept étapes, Skip Setup, tâches de fond, reprise après relance | ADR 0032 ; TRD Onboarding ; README | BUILT | `NPA/Onboarding/OnboardingState.swift:6-20`, `NPA/Onboarding/OnboardingModel.swift:191-193`, `NPA/Onboarding/SetupTasks.swift` ; captures et preuves en attente (`onboarding-v2/tasks.md:8,13`) |
| App Management demandé juste avant l'écriture Steam (étape Stores) | TRD Onboarding ; PRIVACY | BUILT | `NPA/Permissions/SteamStep.swift` |
| Proposer de se déplacer dans Applications | README ; spec onboarding | BUILT | `NPA/Onboarding/AppLocation.swift:146` |
| install.sh (sans quarantaine), dmg avec les trois étapes, cask | README ; ADR 0012 ; spec onboarding | BUILT | `install.sh`, `packaging/dmg/make-dmg.sh`, `packaging/homebrew/cartouche.rb.in` ; tests sur comptes propres macOS 15/26 non faits (`archive/…p18…/tasks.md:5,7`) |
| Run Setup Again | TRD Onboarding | BUILT | `NPA/Onboarding/OnboardingSettings.swift:11` |
| Réglages : Général, Bibliothèque, Comptes, Steam, Préfixes Wine, Runners, Confidentialité, Consoles, Manettes, Agents, Avancé | README ; TRD Settings | BUILT | `NPA/Library/Views/SettingsWindow.swift:25-141` |
| Vérification quotidienne des mises à jour et des données désactivable | TRD Open questions | BUILT | `NPA/Views/UpdatesSettingsView.swift:6-11` |
| Remove Everything (sans toucher NotProton) | TRD SwiftUI app | BUILT | `NPA/Views/StatusView.swift:207,387` |
| Permissions : catalogue, une phrase avant le prompt, états dans Réglages > Confidentialité, liens vers les panneaux | PRIVACY ; spec mac-permissions | BUILT | `NPA/Permissions/Permission.swift`, `PermissionFlow.swift`, `SettingsLink.swift:18-32`, `PrivacySettingsView.swift` ; matrice 15/26/27 non mesurée (`archive/…p17…/tasks.md:7,16`) |
| Relance gérée par Cartouche pour Input Monitoring (attend les jeux, y compris consoles) | PRIVACY Relaunch | BUILT | `NPA/Permissions/RelaunchService.swift:1,34,170` |
| Manettes : statut, nom, batterie | PRD Controls 1 ; spec controls | BUILT | `NPA/Controls/ControlsViews.swift:34,295`, `NPA/Controls/ControllerMonitor.swift` |
| Remappage par jeu : Steam Input, `SDL_GAMECONTROLLERCONFIG`, fichiers remap RetroArch | PRD Controls 2 ; spec controls | BUILT | `NPA/Controls/GameControls.swift:139-158`, `NPA/Controls/RetroArchRemap.swift`, `ControlsViews.swift:130` ; test réel dans Wine non fait (`archive/…p15…/tasks.md:9`) |
| Clavier et souris Mac (Cmd → Ctrl, Option → Alt, souris gardée, défilement précis) | PRD Controls 3 | BUILT | `NPA/Controls/ControlsViews.swift:194-204`, `NPA/Controls/KeyRemap.swift` |
| Manette pour jeux au clavier seul (Accessibilité) | PRD Controls 4 | BUILT | `NPA/Controls/ControlsViews.swift:215`, `NPA/Controls/KeyboardPlay.swift`, `ControlsCenter.swift:16` |
| Couch mode | PRD Controls 5 | BUILT | `NPA/Controls/CouchMode.swift`, `NPA/App/AppBootstrap.swift:46`, `NPA/Library/Views/LibraryGrid.swift:46` |
| Localisation fr / it / zh-Hans, glossaire FR (vouvoiement) | PRD follow-ups ; spec localization | BUILT | `NPA/Resources/Localization/Localizable.xcstrings` (1519 entrées avec `fr`), `docs/l10n/glossary-fr.md` |
| Manette visible dans les jeux Windows | ROADMAP J ; README Controls | PARTIAL | Correctif SDL3 côté app fusionné (1b05e2d), mais il faut Cartouche Wine 26.3.0-2, non publié (voir Wine) |
| Ouvrir Cartouche à l'ouverture de session (Login Items) | PRIVACY (« When you turn the option on ») | PARTIAL | Logique de permission présente (`NPA/Permissions/PermissionFlow.swift:46-48`, `PermissionRequester.swift:34`) mais aucun interrupteur dans Réglages |
| Valeurs par défaut globales de stockage et de glyphes, appliquer une disposition aux futurs jeux | TRD Onboarding (« remain unimplemented ») | MISSING | La doc reconnaît que ce n'est pas implémenté |
| Réglage « Emplacement des jeux » dans Réglages > Bibliothèque | (onboarding : dossier des jeux) | IN PROGRESS (wip/wp2-location) | Changeable seulement par Run Setup Again (`NPA/Onboarding/OnboardingModel.swift:591-602`) |

### Mises à jour / release

| Fonctionnalité | Source doc | Statut | Preuve / manque |
|---|---|---|---|
| Sparkle 2.10 : flux signé exigé, vérification avant extraction | TRD Sparkle ; spec release-pipeline | BUILT | `app/Info.plist` (`SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`, `SUPublicEDKey`), `NPA/Support/AppUpdater.swift`, `NPA/App/AppCommands.swift:17` |
| Canal bêta (désactivé par défaut) | TRD Sparkle | BUILT | `NPA/Views/UpdatesSettingsView.swift:14-16`, `NPA/Support/UpdateChannel.swift` |
| Mise à jour critique | TRD Sparkle ; CHANGELOG | BUILT | `packaging/make-appcast.sh:4-16` |
| Workflow de release : build, signature, dmg, appcast EdDSA, GitHub Release | spec release-pipeline ; RELEASE.md | BUILT | `.github/workflows/release.yml:64-167` ; jamais exécuté (pas de v0.0.1-test, `archive/…p9…/tasks.md:10`) |
| Contrôles de PR (build, tests, openspec, scan de redistribution) | spec release-pipeline | BUILT | `.github/workflows/ci.yml`, `lint.yml`, `packaging/redist-scan.sh` ; protection de branche non vérifiée |
| Veille des projets amont | spec release-pipeline | BUILT | `.github/workflows/upstream-watch.yml`, `packaging/upstream-watch` |
| Données de compatibilité nocturnes publiées par CI | TRD ; spec compatibility-data | BUILT | `.github/workflows/compat-data.yml`, `tools/compat` |
| Lien vers le site et mention de non-affiliation dans À propos | PRD Release ; spec app-identity | BUILT | `NPA/Support/Attribution.swift:6-24` |
| Icône de l'app | spec app-identity | BUILT | `NPA/Resources/Brand.xcassets`, `helpers/iconmaker.swift` |
| Signature auto-signée stable (même designated requirement) | ADR 0003 ; spec release-pipeline | PARTIAL | Scripts prêts (`packaging/signing/*.sh`, `release.yml:118-146`). Il manque le certificat et les secrets (mainteneur) ainsi que le test sur deux releases |
| Clé privée EdDSA de Sparkle en secret CI | P0 tâche 3.1 ; RELEASE.md | PARTIAL | La clé publique est dans `Info.plist` ; secret à confirmer (`docs/HANDOFF-codex.md`) ; test d'un flux signé par un tiers non fait (P0 3.3) |
| Tap Homebrew + mise à jour automatique du cask | spec release-pipeline ; README | PARTIAL | `release.yml:241-251`, `packaging/homebrew/cartouche.rb.in` ; dépôt `homebrew-cartouche` à créer |
| Runners, backends et données de compat mis à jour sans nouvelle app | TRD Sparkle (dernière puce) | PARTIAL | Runners (`RunnerManifest.swift:202`) et compat oui ; `backends.json` et `store-clients.json` ne sont lus que dans l'app (`NPA/Setup/BackendInstaller.swift:5-59`, `NPA/Stores/StoreClients.swift`) |

### Agent / MCP

| Fonctionnalité | Source doc | Statut | Preuve / manque |
|---|---|---|---|
| Helper `cartouche-mcp` (stdio ↔ socket Unix, seul helper embarqué admis) | TRD MCP ; spec agent-control | BUILT | `app/Sources/CartoucheMCPHelper/main.swift`, `app/Sources/CartoucheMCP/MCPSocket.swift`, `Makefile:774-776` |
| Commande `claude mcp add cartouche -- …` affichée | PRD Agents 1 | BUILT | `NPA/Agent/AgentViews.swift:11` |
| Transport HTTP optionnel sur 127.0.0.1 avec jeton | TRD MCP | BUILT | `app/Sources/CartoucheMCP/MCPHTTP.swift`, `NPA/Agent/AgentViews.swift:52-100` |
| Trois niveaux d'accès (Read Only, Standard, Full) | PRD Agents 3 ; spec agent-control | BUILT | `NPA/Agent/AgentLevel.swift:4-13` |
| Approbation dans l'app pour installer, supprimer, lancer un exe | PRD Agents 4 | BUILT | `NPA/Agent/AgentViews.swift:28-38` |
| Journal des actions dans Réglages > Agents avec Undo | PRD Agents 5 | BUILT | `NPA/Agent/AgentViews.swift:83-84` |
| Outils PC (bibliothèque, installation, setup, runners, préfixes, FPS) | PRD Agents 3 ; `mockup/MCP.md` | BUILT | `NPA/Agent/AgentReadTools.swift`, `NPA/Agent/AgentActionTools.swift` (environ 55 outils) |
| Outils console et contrôles, via le relais de Cartouche | spec agent-control « One server for every kind of game » | BUILT | `NPA/Agent/AgentActionTools.swift:631`, `NPA/Agent/AgentTool.swift:61`, `NPA/Agent/AgentControls.swift` |
| Diagnostic (logs, rapports de crash, diagnose) | PRD Agents 2 ; spec agent-control | BUILT | outils `get_logs`, `get_crash_report`, `diagnose` (`NPA/Agent/AgentDiagnose.swift`) |
| Outils Coach `read_game_state` / `watch` | `mockup/MCP.md:91,132` (liste citée par la TRD) | MISSING | Aucun outil de ce nom. Les 9 autres noms du mockup sont des valeurs de paramètres, pas des outils |

### Autres (compatibilité, identité, confidentialité)

| Fonctionnalité | Source doc | Statut | Preuve / manque |
|---|---|---|---|
| Identité Cartouche (bundle ID, dossiers séparés, NotProton intact) | spec app-identity ; ADR 0014 | BUILT | `app/Sources/CartoucheIdentity/include/cartouche_identity.h`, `NPA/Support/SupportPaths.swift`, `NPA/Model/NotProtonTakeover.swift` |
| Fichier de compat nocturne (AppleGamingWiki, ProtonDB, AreWeAntiCheatYet) sans MacGamingDB | TRD ; ADR 0005, 0013 | BUILT | `.github/workflows/compat-data.yml`, `tools/compat` |
| Client hors ligne d'abord (une fois par jour, dernière copie valide) | spec compatibility-data | BUILT | `NPA/Compatibility/CompatibilityClient.swift:1-73` |
| MacGamingDB lu en direct, en cache, interrupteur dans Confidentialité | TRD ; PRIVACY | BUILT | `NPA/Compatibility/MacGamingDB.swift`, `NPA/Permissions/PrivacyChoices.swift` |
| Estimation par Mac (force GPU 1/1,4 à 1,4) | TRD | BUILT | `NPA/Compatibility/CompatEstimate.swift` |
| Anti-cheat présenté comme donnée Linux | PRD Legal ; ADR 0009 | BUILT | `NPA/Compatibility/AntiCheatSummary.swift` |
| Crédits des sources de données | PRD Legal | BUILT | `NPA/Compatibility/CompatibilityCredits.swift`, `NPA/Library/Views/GameDetailsSheet.swift:89` |
| Boîte de dialogue de crash de Wine supprimée (backtrace dans le log) | CHANGELOG ; gap-audit | BUILT | `NPA/Installer/CrashHandling.swift:1-86`, `NPA/Installer/InstalledGame.swift:95` |
| Rapports locaux, rien envoyé par défaut | PRIVACY ; PRD Success measures | BUILT | `NPA/Support/CrashReports.swift:1`, `NPA/Performance/PerformanceSharing.swift:1` |
| Liste publique de jeux avec étoiles sur cartouche.bryann2k.dev | ROADMAP v0.1.1 ; PRD Non-goals | DEFERRED (0.1.1) | Pas de backend en 0.1.0, par décision |
| Soumission de statistiques et hébergement du site | PRIVACY « Not decided » ; TRD | DEFERRED (0.1.1) | Conception non décidée |

## Textes de doc en retard sur le code

1. **PRD « Add Games »** : « The backend classifier is pending; without it the sheet says “Game detection is unavailable” ». C'est faux, le classifieur est branché (`NPA/App.swift:91`, `DropClassifierAdapter.swift:8`).
2. **README** (texte hérité de NotProton) : « intended to be used with … CrossOver 26.3 or CrossOver Preview », le conseil de régler l'outil par défaut dans Steam > Compatibility, et « ntdll-patch patches the copy of CrossOver ». Cela contredit Cartouche Wine par défaut sans CrossOver.app et le choix de setup fait par l'app.
3. **PRIVACY, tableau des permissions** : Downloads folder « Suggest installers that appear in Downloads (P6) ». Aucun observateur n'existe ; la TRD (l.185) dit qu'il a été retiré. `app/Info.plist:55-56` garde `NSDownloadsFolderUsageDescription`, et `OnboardingState.watchDownloads` reste dans le code sans UI.
4. **PRIVACY, Onboarding** : « asks only for App Management, in the PC games step » et « Folders and privacy step ». La v2 a les étapes Stores et Permissions (`OnboardingState.swift:6-12`).
5. **PRIVACY, Login Items** : « When you turn the option on ». Aucun interrupteur n'existe.
6. **PRIVACY, Relaunch** : « Console games (P12) need their own check, which is not written yet ». Il existe (`RelaunchService.swift:34`, `ConsoleGameActivity`).
7. **FPS-MEASUREMENT.md** : « Install the counter through Steam Play Setup ». Cette fenêtre a été supprimée par le rework des Réglages (a9ceae3).
8. **spec windows-installer** : « innoextract 1.9: Inno 1.2.10–6.2.2 ». Le code embarque 1.10, qui va jusqu'à 6.4.0 (TRD InstallerKit).
9. **TRD Sparkle** : « Runners, backends and compatibility data update without an app update ». C'est faux pour les backends (et les clients de store).
10. **TRD « Bundled RetroArch »** et **RETROARCH.md** : « signs it with the Cartouche certificate and embeds it in the app ». Le pipeline de release n'embarque pas RetroArch (`app.yml:169-172`).
11. **TRD MCP** : « Tool list: mockup/MCP.md ». Ce fichier liste `read_game_state` et `watch`, qui n'existent pas.
12. **TRD Runners** : « bundles freetype, gnutls, MoltenVK and SDL2 ». La recette en cours (`pins.env:13,28`) ajoute SDL3 en révision 2.
13. **PRD Steam Play 5** (« After a crash, the panel suggests another backend ») : rien dans le code ne réagit à un crash.
14. **TRD Advanced / README** : « D3DMetal DLSS is hidden; no frame-generation switch ». À réviser quand wip/wp4-launch-gfx sera fusionné.
15. **`.claude/reports/feature-audit.md`** : obsolète sur Favoris, vérification, archives, CrossOver par défaut et sauvegardes cloud (voir le résumé).

## 3. Manques et fonctions partielles qui comptent pour 0.1.0, par ordre

1. **RetroArch n'est pas embarqué dans la release** (PARTIAL). `release.yml` → `app.yml` n'appelle jamais `make retroarch-embed`. Une v0.1.0 serait livrée sans le RetroArch « bundled » promis (MCP stdio, Coach, Time Machine) et dépendrait du repli sur la release officielle. À corriger : ajouter le build et l'embed de RetroArch au workflow app/release.
2. **Cartouche Wine 26.3.0-2 n'est pas publié** (PARTIAL). Sans lui, pas de manette dans les jeux Windows (SDL3) et pas de Wine Mono/Gecko pour .NET, alors que la sélection des runtimes y compte. `runners.json` épingle encore 26.3.0-1. Les recettes Mono/Gecko ne sont pas visibles dans ce dépôt.
3. **Signature, clé Sparkle et tap Homebrew** (3 × PARTIAL, mainteneur). Le certificat auto-signé et ses secrets, le secret `SPARKLE_PRIVATE_KEY` et le test de flux étranger, le dépôt `homebrew-cartouche`. Sans eux, ni release, ni mise à jour, ni installation par `brew`.
4. **FPS et temps de jeu pour les jeux d'installeur et de store** (PARTIAL). La PRD et la TRD promettent « the same … FPS features as Steam games ». Le compteur n'est injecté que par `compat_run.sh` et le stockage est indexé par app_id Steam.
5. **Mesure FPS validée sur de vrais runners** (PARTIAL). L'injection par runner, la précision ±1 fps et le surcoût < 1 % par backend sont des critères de succès de la PRD encore sans preuve.
6. **Classification avec preuves et confiance (ADR 0028)** (PARTIAL). Les cas ambigus ou contradictoires ne sont pas montrés à l'utilisateur, alors que la spec l'exige.
7. **WineHQ et GPTK comme outils Steam** (PARTIAL). Les offsets ntdll ne sont pas épinglés. Seul Cartouche Wine passe par Steam.
8. **CI « boot » de Wine** (PARTIAL). Le résultat du run n'est pas enregistré, alors que c'est la preuve du premier démarrage du runner par défaut.
9. **Backends et clients de store non mis à jour à distance** (PARTIAL). Si Epic change d'API ou si DXMT doit être corrigé, il faut une nouvelle version de l'app. La TRD promet le contraire pour les backends.
10. **Suggestion de backend après un crash** (PARTIAL). Promis par la PRD (Steam Play 5) ; seule une suggestion fondée sur les rapports existe. Il est facile de l'accrocher au futur avis de crash de wip/wp1-errors.
11. **Collections Steam importées mais invisibles** (PARTIAL). Les données sont déjà là ; il manque l'affichage dans la barre latérale.
12. **Login Items sans interrupteur** (PARTIAL). Il faut soit ajouter l'option dans Réglages > Général, soit retirer la ligne de PRIVACY.
13. **Observateur de Téléchargements** (MISSING). Il faut décider : le supprimer de PRIVACY et de `Info.plist` (recommandé, la TRD le dit retiré), ou l'implémenter.
14. **Outils MCP du Coach `read_game_state` / `watch`** (MISSING). Le Coach est expérimental ; on peut retirer ces outils de `mockup/MCP.md` ou les ajouter au niveau Full.
15. **Valeurs par défaut globales (stockage, glyphes, disposition des futurs jeux)** (MISSING, reconnu par la TRD). Ce n'est pas bloquant ; on peut le reporter explicitement en 0.1.1.

Hors de cette liste, car déjà en cours sur des branches : bandeau d'erreur, échecs de store et avis de crash (wp1) ; emplacement des jeux (wp2) ; arguments et environnement par jeu, DLSS/DXR pour D3DMetal et import GPTK (wp4) ; Wine Tools et Stop pour Steam (wp5) ; GStreamer (26.3.0-3). Les points 1 à 3 de la liste viennent avant ces branches pour pouvoir publier une release.
