# Installeur Windows : la feature star

Date : 2026-10-18. Cible : les installeurs en plusieurs parties (setup.exe + fichiers .bin), comme les installeurs hors ligne GOG. Les repacks utilisent le même format (Inno Setup + décompression FreeArc via `unarc.dll` / `ISDone.dll`), donc le même moteur les couvre.

## Règle produit

- La feature s'appelle **« Install from a Windows installer »**. Rien dans l'app, le README ou le site ne parle de repacks.
- L'app n'ajoute **aucune fonction de contournement de DRM** (pas de copie de crack, pas d'émulateur Steam, pas de détection de « scene release »).
- Raison : un fork public qui cible le piratage s'expose à un retrait DMCA sur GitHub. Le moteur générique, lui, est défendable : il sert GOG, les jeux DRM-free et les vieux jeux.

## Le parcours en 6 temps

### 1. Arrivée du dossier
- Glisser un dossier, un `setup.exe`, ou ouvrir avec l'app.
- **Bonus** : surveiller `~/Downloads`. Quand un dossier avec `setup.exe` + `.bin` apparaît et n'évolue plus depuis 1 minute, notification macOS : « Ready to install: <nom> ». (Désactivable.)

### 2. Analyse (2 à 5 s, sans rien lancer)
- Type d'installeur : signature Inno Setup dans `setup.exe`, présence de `unarc.dll` / `ISDone.dll` = décompression lourde.
- Parties : `*.bin` / `*-N.bin` / `*.bin.001`, numérotation continue, aucune vide.
- **Intégrité en natif** : si un fichier `.md5` est présent, calcul des MD5 en Swift (multi-cœur) au lieu du script `.bat` Windows. Beaucoup plus rapide.
- **Nom du jeu** : nom du dossier nettoyé (on retire `[ … ]`, `v1.2.3`, `+ DLC`, `MULTi10`), puis recherche dans l'API MacGamingDB (`/games/search`) pour trouver l'App ID Steam.
- Avec l'App ID : jaquette, données de compatibilité, **meilleur setup connu** (runner + backend) pré-choisi.
- **Espace** : taille des `.bin` × 2,5 en estimation de l'espace installé, plus 10 % de marge temporaire. Comparé à l'espace libre du disque cible.

### 3. Préparation
- Un prefix neuf par jeu, avec le runner choisi.
- Disque cible : interne de préférence. Avertissement si le dossier source est sur NTFS ou exFAT (pas supporté par NotProton).
- Chemin d'install court et en ASCII : `C:\Games\<Nom>`. Évite une cause classique d'erreur `unarc`.
- `caffeinate` pendant l'install : le Mac ne se met pas en veille. Conseil affiché si le MacBook est sur batterie.

### 4. Installation
- Lancement avec les options Inno Setup : `/DIR="C:\Games\<Nom>"`, `/LANG=english`, `/NORESTART`, `/LOG="C:\install.log"`.
- **Deux modes** :
  - **Guidé** (par défaut) : la fenêtre de l'installeur s'affiche, avec le dossier déjà rempli. L'utilisateur coche ses options (langues, composants).
  - **Automatique** : ajoute `/VERYSILENT /SUPPRESSMSGBOXES`. Si l'installeur ne le supporte pas (il affiche quand même sa fenêtre), on bascule en mode guidé.
- **Toujours sous Rosetta** pour l'install, même si le jeu tournera ensuite avec FEX : la décompression est plus fiable.
- **Progression** : taille du dossier cible comparée à la taille estimée, mise à jour chaque seconde. Vitesse en Mo/s, temps restant, et charge CPU.
- **La jaquette se colore pendant l'install** avec le même shader que les téléchargements. C'est le moment « wow » de la feature.
- Fermer la feuille ne coupe rien : l'install continue en arrière-plan (carte d'activité en bas à gauche), notification à la fin.
- **Une seule install à la fois** (la décompression prend tout le CPU). Les suivantes attendent dans une file.

### 5. Après l'install
- **Redistribuables** : les dossiers `_Redist` (Visual C++, DirectX, .NET) ne sont pas lancés. Leurs équivalents winetricks sont installés à la place, en silence.
- **Détection de l'exe**, par ordre de confiance :
  1. Raccourcis `.lnk` créés dans le menu Démarrer ou sur le bureau du prefix.
  2. Clé `Uninstall` du registre (`DisplayIcon`, `InstallLocation`).
  3. Plus gros `.exe` du dossier, en excluant `unins*`, `setup*`, `*crash*`, `*redist*`, `launcher` si un autre exe existe.
- L'utilisateur confirme l'exe (pré-sélectionné). Option « Show in Steam » cochée.
- **Nettoyage** : « Delete installer files and free 38.2 GB? » avec confirmation. Jamais automatique.

### 6. Premier lancement
- Le setup recommandé est déjà appliqué. La fiche affiche l'estimation pour ce Mac, comme pour les jeux Steam.
- Si le jeu plante au premier lancement : bannière avec le backend alternatif à essayer.

## Erreurs et réponses

| Problème | Détection | Message et action |
|---|---|---|
| Partie manquante | Numérotation des `.bin` | « setup-3.bin is missing ». Install désactivé, bouton Check Again |
| Fichier corrompu | MD5 différent | « setup-2.bin is damaged. Download it again. » |
| Pas assez de place | Estimation de l'étape 2 | Espace manquant chiffré, bouton Choose Another Disk |
| Erreur `unarc.dll` / `ISDone.dll` | Code de sortie + log | Causes probables, dans l'ordre : mémoire, chemin, fichier abîmé. Boutons : Verify Files, Try Again |
| Installeur figé | Dossier qui ne grossit plus depuis 5 min et CPU à 0 | « The installer seems stuck. » Boutons : Show Installer Window, Stop |
| Mac en veille | Évité par `caffeinate` | – |
| Disque NTFS / exFAT | Type de volume | « Copy the installer to this Mac first? » avec la taille |

## Pourquoi c'est la feature star

- Personne ne le fait bien sur Mac aujourd'hui : Whisky, CrossOver et Heroic lancent l'exe et laissent l'utilisateur seul face aux erreurs.
- Les trois choses qui manquent partout : **l'analyse avant install** (fichiers, espace, intégrité), **une vraie progression**, et **un jeu configuré à la fin** (bon backend, jaquette, raccourci Steam).

## Vérifié sur un vrai installeur (2026-10-18)

Analyse statique d'un dossier téléchargé (rien n'a été lancé) : `setup.exe` 5,6 Mo + 2 parties (11,9 Go au total), sur disque APFS.

| Hypothèse du design | Résultat |
|---|---|
| Installeur Inno Setup | **Confirmé** : `Inno Setup Setup Data (5.5.0) (u)`. Cette version gère `/DIR`, `/LOG`, `/VERYSILENT`. |
| Parties nommées `setup-N.bin` | **Faux** : ici `<préfixe>-01.bin`, `<préfixe>-02.bin`. Il faut accepter tout `*.bin` numéroté, quel que soit le préfixe. |
| Fichier `.md5` à côté | **Dans un sous-dossier** `MD5/`, chemins Windows relatifs (`*..\<préfixe>-01.bin`) et lignes de commentaire `;`. Le parseur doit gérer les deux. |
| Parties optionnelles | Le fichier MD5 prévient : « If you miss selective download files - that's OK ». Une partie absente n'est donc **pas toujours** bloquante : il faut distinguer les parties obligatoires des optionnelles (langues, bonus). |
| Contrôle MD5 en natif | **Confirmé** : les deux sommes correspondent, en **18 s** pour 11,9 Go (une partie par cœur). Le script Windows n'est pas nécessaire. |
| `unarc.dll` / `ISDone.dll` visibles | **Non** : ils sont compressés dans `setup.exe`, invisibles par simple lecture. Pour les détecter sans rien lancer, il faut lister le contenu avec `innoextract --list`. |
| Taille installée ≈ 2,5 × les .bin | **Pas vérifiable** sans installer. Reste une hypothèse. |

### Contenu de `setup.exe` (innoextract 1.9, `--list`, rien d'extrait ni de lancé)

- Setup Inno **5.5.0.1 unicode**, langues anglais et russe, **sans mot de passe**.
- **Décompression lourde confirmée** : `unarc.dll`, `ISDone.dll`, `facompress.dll`, plus une chaîne de décompresseurs FreeArc (`cls-lollypop`, `cls-srep`, `cls-magic2`, `cls-mpzz`), `razor`, `xtool.exe`, `x5.exe`, `fsb.exe`, `liblz4.dll`, `unity.dll`.
- Ces outils existent en **versions x86 et x64** et tournent comme **processus séparés** : sous Wine, plusieurs exe Windows en parallèle, traduits par Rosetta. Le CPU et la RAM seront très sollicités.
- **Interface sur mesure** (`botva2.dll`, `bass.dll`, `music.mp3`) : fenêtre d'installeur personnalisée avec musique. Le mode Guidé est le cas réaliste. Le mode Automatique (`/VERYSILENT`) reste à tester.
- `idp.dll` (Inno Download Plugin) : l'installeur peut essayer de télécharger quelque chose. À surveiller sous Wine (réseau, pare-feu).
- **Redistribuables** : `app/_Redist/dxwebsetup.exe` est copié dans le dossier du jeu. Notre règle tient : ne pas le lancer, installer l'équivalent winetricks.
- `tmp/records.inf` : **vérifié, ce ne sont pas des tailles**. Trois lignes (`2601 374 0 0`, `982316 141259 0 0`, `15083 2169 0 0`) dont la première colonne fait 1 000 000 au total : ce sont les **poids de progression** de chaque archive. Utile pour découper la barre de progression par phase, pas pour la taille.
- `tmp/CLS.ini` : les décompresseurs prennent jusqu'à **75 % de la RAM** et **100 % des cœurs**, et écrivent leurs fichiers temporaires **dans le dossier du jeu** (`TempPath={app}`). Il faut donc compter de l'espace temporaire sur le disque cible, et l'option `lower_memory` du plan B peut abaisser ces valeurs.

Conséquences pour le design :
- Détection des parties : « même préfixe + numéro », pas un nom fixe.
- Partie manquante : avertissement orange (« peut-être optionnelle ») si le fichier MD5 l'annonce, rouge sinon.
- Ajouter `innoextract` (open source, licence zlib) à l'app pour l'analyse : il détecte la décompression lourde, les langues et un éventuel mot de passe sans rien lancer.
- `records.inf` sert à la progression par phase. La taille installée reste une estimation.

## À vérifier
- Que `/DIR` et `/LOG` sont respectés par les installeurs Inno modifiés.
- Le ratio taille installée / taille des `.bin` (2,5 est une hypothèse), à mesurer sur plusieurs installeurs.
- Le comportement de `unarc.dll` sous Rosetta avec beaucoup de cœurs (mémoire par thread).

## Moteur d'analyse (code)

Package Swift `installer/` (InstallerKit), sans dépendance à l'app NotProton :
- `PartScanner` : exe + parties numérotées, quel que soit le préfixe, et parties manquantes.
- `Checksums` : trouve le `.md5` (sous-dossiers compris), lit les chemins Windows, vérifie en parallèle.
- `InnoInspector` : lit `innoextract --info` et `--list` (rien n'est exécuté ni extrait).
- `GameName`, `SpaceEstimate`, `InnoCommand`, `ExeDetector`.
- CLI : `swift run installer-inspect <dossier> [--verify] [--json]`.
- 9 tests (Swift Testing), tous verts.

Résultat sur le dossier téléchargé : 2 parties (11,1 Go), Inno 5.5.0.1, décompression lourde (10 outils), fenêtre sur mesure, téléchargement possible pendant l'install, `dxwebsetup.exe` à remplacer, MD5 vérifiés en 19 s, commande `/DIR=C:\Games\CarX Street /NORESTART /LOG=C:\installer.log /LANG=en`.
