# Fork NotProton — runners gratuits + lanceur .exe

Date : 2026-10-18. Base : NotProton v1.2.0 (GPL-3.0, Swift + C).

## 1. Le point bloquant

- NotProton ne marche **qu'avec CrossOver** (payant).
- L'auteur l'écrit dans le README : le support d'autres runners que CrossOver **n'est pas prévu**.
- Raison technique : `ntdll-patch` patche `ntdll.dll` à des **offsets (RVA) codés en dur**.
- Chaque build supportée est épinglée par hash dans `app/Sources/NotProtonApp/Model/SupportedRunner.swift`.
- Donc ajouter un runner = **épingler une build précise** (hashes + `ntdll-patch/resolve.py`), pas juste « pointer vers un dossier Wine ».

## 2. Frameworks gratuits pour jouer sur Mac

Deux couches à séparer, comme Proton sur Linux :
- **Runner** = la version de Wine (traduit les appels Windows).
- **Backend graphique** = traduit DirectX vers Metal.

### Runners (Wine)

| Runner | Gratuit | État | Intérêt pour le fork |
|---|---|---|---|
| Wine CrossOver open source (builds Gcenx) | Oui | Actif | **Priorité 1**. Même code que CrossOver, donc patchs ntdll proches. |
| Game Porting Toolkit (Apple, builds Gcenx) | Oui, licence restrictive | Actif | **Priorité 2**. Meilleure perf DX12 via D3DMetal. |
| Wine Staging / Devel macOS (Gcenx, Homebrew) | Oui | Actif | Priorité 3. Upstream, moins optimisé jeux. |
| WhiskyWine (runtime de Whisky) | Oui | **Abandonné avril 2025** | Faible. Réutiliser l'UX, pas le runtime. |
| Sikarugir (ex-Kegworks/Wineskin) | Oui | Actif | Source d'engines Wine + bascule de backends. |

### Backends graphiques

| Backend | DirectX | Perf | Licence |
|---|---|---|---|
| **D3DMetal** (Apple GPTK) | DX11, DX12 | **La meilleure** sur DX12 | Évaluation / non commercial. Redistribution floue. |
| **DXMT** (3Shain) | DX10, DX11 | **Très bonne**, souvent > D3DMetal en DX11 | Open source |
| DXVK-macOS + MoltenVK | DX9 à DX11 | Bonne, vieux jeux | Open source |
| wined3d (OpenGL) | DX9 et moins | Faible | Fallback |
| VKD3D-Proton + MoltenVK | DX12 | Instable sur Mac | Open source |

### Traduction CPU

- **Rosetta 2** : x86_64, déjà supporté par NotProton.
- **FEX** (arm64) : déjà supporté, macOS 26 requis.

### Autres outils gratuits (référence UX, pas à intégrer)

- **Porting Kit** : catalogue de wrappers prêts à l'emploi.
- **Heroic Games Launcher** : Epic/GOG/Amazon, sait utiliser GPTK et Wine.
- **Mythic** : launcher Swift, alpha.
- **MacWrap** : transforme un .exe en .app, beta.

### Point licence

- D3DMetal ne doit **pas être embarqué** dans le fork.
- Solution : l'utilisateur installe GPTK lui-même, le fork le **détecte** et le copie localement (comme NotProton fait déjà avec CrossOver).

## 3. Sélecteur de framework « façon Steam »

NotProton expose déjà des « compatibility tools » dans Steam (menu Propriétés > Compatibilité).
Idée : générer **un compat tool par combinaison runner + backend**.

Exemples de noms dans Steam :
- `Wine-CX 26 · DXMT · Rosetta`
- `Wine-CX 26 · D3DMetal · Rosetta`
- `GPTK 3 · D3DMetal`
- `Wine Staging · DXVK`

Changements de code prévus :
- Généraliser `RunnerBuild` / `CrossOverSource` en un protocole `Runner` (CrossOver, WineBuild, GPTK).
- Ajouter un champ `backend` dans `CompatTool`.
- `compat_run.sh` : poser les variables d'env et DLL overrides selon le backend.

## 4. Lancer un .exe, installer, puis jouer

### Flux proposé

1. **Glisser un .exe ou .msi** dans l'app (ou clic droit > Ouvrir avec).
2. L'app **crée un prefix** (bouteille) dédié, avec le runner choisi.
3. **Snapshot avant** : liste des fichiers de `drive_c` + clés registre `Uninstall`.
4. Lancement de l'installeur.
5. À la fermeture, **snapshot après** et diff.
6. **Détection** des exécutables du jeu, classés par score :
   - cibles des nouveaux `.lnk` (Menu Démarrer, Bureau) : score max ;
   - `DisplayIcon` / `InstallLocation` de la nouvelle clé `Uninstall` ;
   - .exe nouveaux dans `Program Files`, en excluant `unins*`, `setup*`, `vcredist*`, `dxsetup*`, `UnityCrashHandler*`.
7. L'utilisateur **confirme** le bon .exe (choix pré-sélectionné).
8. Création du lanceur.

### Trois sorties possibles pour le lanceur

- **A. Raccourci non-Steam** : NotProton gère déjà les .exe en non-Steam avec runner par défaut (v1.2.0). Coût minimal.
- **B. Vraie app .app** dans `~/Applications` : icône extraite du .exe (l'outil `iconmaker` existe déjà), script qui appelle le runner. Visible dans Launchpad et Spotlight.
- **C. Bibliothèque interne** dans l'app NotProton : liste des jeux, réglages par jeu.

Recommandation : **A + B** d'abord, C plus tard.

### Cas à prévoir

- Installeurs qui lancent le jeu à la fin : détecter le jeu malgré tout.
- Launchers tiers (Rockstar, EA, Ubisoft) : proposer le launcher comme cible.
- Jeux portables sans installeur : sauter l'étape install, aller directement au choix du .exe.
- Réglages par jeu : backend, Rosetta/FEX, variables d'env, HUD Metal.

## 4 bis. Installeurs en plusieurs parties (setup.exe + .bin)

Même format que les installeurs hors ligne GOG : Inno Setup + archives `.bin` à côté.

### Règles de base

- On importe **un dossier**, pas un fichier seul. `setup.exe` lit les `.bin` par chemin relatif.
- On lance l'installeur **sur place**, via le lecteur `Z:` de Wine. Pas de copie des `.bin`.
- **Disque NTFS / exFAT** : NotProton ne le supporte pas encore. Avertir, ou proposer de copier le dossier sur le disque interne.

### Détection du dossier

- Chercher l'installeur : `setup.exe`, sinon le .exe dont la signature est Inno Setup.
- Lister les `.bin` voisins et vérifier qu'il n'en manque aucun (numérotation continue).
- Si un fichier `.md5` est présent : proposer la vérification avant l'installation.
- Repérer les dossiers de redistribuables (`_Redist`, `Redist`, `DirectX`, `vcredist`).

### Installation pilotée

- Passer les options Inno Setup : `/DIR="C:\Games\<Nom>"` et `/NORESTART`.
- Gros avantage : **on connaît le dossier d'install d'avance**, la détection du .exe devient fiable.
- Espace disque : estimer environ 2 à 3 fois la taille des `.bin`, et bloquer si l'espace manque.
- Progression : suivre la taille du dossier cible pendant la décompression.
- Redistribuables Windows : ne pas lancer les `vcredist` / DirectX fournis. Installer plutôt les équivalents Wine (winetricks : `vcrun2022`, `d3dx9`, etc.).

### Pièges connus

- La décompression (`unarc.dll`, `ISDone.dll`) est **lourde en CPU et RAM**, et lente sous Rosetta.
- Erreurs `unarc.dll returned an error code` : souvent manque de RAM, ou un chemin avec des caractères spéciaux.
- Parades : forcer le runner **Rosetta** pour l'installation (FEX plus risqué), activer « limiter la RAM » si l'installeur le propose, utiliser un chemin d'install court en ASCII.
- L'installeur peut proposer de lancer le jeu à la fin : ignorer, la détection se fait sur le dossier `/DIR`.

### Après l'installation

- Proposer (avec confirmation) de **supprimer le dossier d'installeur** pour récupérer l'espace.
- Puis suite normale : choix du .exe, raccourci non-Steam + .app.

## 5. Ordre de travail suggéré

1. Fork + build local de NotProton tel quel.
2. Abstraire `Runner` sans changer le comportement (tests existants verts).
3. Épingler une build Wine-CrossOver Gcenx (hashes + resolve.py).
4. Ajouter le choix de backend (DXMT, D3DMetal détecté, DXVK).
5. Flux .exe → prefix → détection → raccourci non-Steam + .app.

## Sources

- https://github.com/NotProtonNot/NotProton
- https://alternativeto.net/software/sikarugir
- https://blog.apps.deals/whisky-alternatives-mac
- https://github.com/Gcenx/game-porting-toolkit/releases
- https://developer.apple.com/forums/thread/841547
- https://developer.apple.com/games/game-porting-toolkit
