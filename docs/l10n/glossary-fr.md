# Glossaire français — Cartouche

Français de France, vouvoiement, actions à l’infinitif. Casse de phrase,
comme sur macOS. Les noms de produits et les identifiants techniques restent inchangés.

| Concept | Choix français | Raison / contexte |
| --- | --- | --- |
| Get (Steam absent) | Installer | La rubrique ouvre le parcours d’installation, pas une acquisition. |
| Windows Installers (source de bibliothèque) | Jeux hors boutique | La rubrique contient les **jeux installés**, pas une collection de fichiers setup.exe. |
| installer (fichier / processus) | programme d’installation | Terme Windows usuel ; jamais « installateur » pour le logiciel. |
| launcher | lanceur | Compréhensible sans emprunt inutile. Les noms Epic Games Launcher / GOG Galaxy restent inchangés. |
| runner | version de Wine | Les choix réels sont Cartouche Wine, WineHQ et CrossOver ; « runner » n’est pas utile au joueur. |
| Cartouche Wine | Cartouche Wine | Nom de notre version de Wine (issue des sources CrossOver de CodeWeavers), jamais traduit ni remplacé par « Wine CrossOver » ; « CrossOver » seul désigne l’application payante de CodeWeavers. |
| compatibility tool | outil de compatibilité | Outil exposé à Steam Play ; distinct de la version de Wine. |
| graphics backend | moteur de rendu | D3DMetal, DXMT ou DXVK. « Rendu graphique » désigne l’image, pas le composant. |
| build | version | Sauf identifiants et valeurs techniques inchangés. |
| install / play / update / uninstall | Installer / Jouer / Mettre à jour / Désinstaller | Vocabulaire familier des boutiques de jeux. |
| verify files | Vérifier les fichiers | Contrôle effectif des fichiers ; « Tailles vérifiées » si seul le contrôle des tailles a eu lieu. |
| library / sign in / sign out | Bibliothèque / Se connecter / Se déconnecter | Formes courtes communes aux lanceurs. |
| controller / controls | manette / commandes | Éviter le calque « contrôles » pour les actions du jeu. |
| controller layout | configuration de la manette | À distinguer de la disposition physique des boutons. |
| remap | réaffecter | Terme naturel pour les touches ; format RetroArch « remappage » conservé. |
| cover | jaquette | Image du jeu, distincte d’une capture d’écran. |
| Your Play | Vos performances | Section de mesures FPS, temps de jeu et comparaison de configurations. |
| reports (ProtonDB / MacGamingDB) | avis | Retours de joueurs ; « rapport » reste réservé aux diagnostics et plantages. |
| 1% low | 1 % les plus bas | Indicateur FPS usuel, sans « low » anglais. |
| prefix | préfixe / préfixe Wine | Terme de la communauté Wine ; conserver sa distinction avec les fichiers du jeu. |
| backup / save file / save state | sauvegarde du préfixe / sauvegarde du jeu / état de sauvegarde | Préciser l’objet dans les explications pour éviter les suppressions ambiguës. |
| cloud saves | sauvegardes dans le cloud | Usage des joueurs, sans construction « sauvegardes cloud ». |
| Use in Place | Utiliser sans copier | Décrit exactement le choix proposé. |
| console core | cœur | Usage libretro / RetroArch. |
| netplay / lobby / LAN | jeu en réseau / salon / réseau local | Distinguer la liste des salons de la partie elle-même. |
| game dumps / ROM | copies de vos jeux / ROM | Fichiers provenant des propres jeux / consoles de l’utilisateur. ROM reste invariable. |
| permission | autorisation | Usage macOS ; « droits » seulement pour les droits d’accès techniques. |
| Settings / System Settings | Réglages / Réglages Système | Respecter les noms Apple. |
| Finder / Trash / Keychain | Finder / Corbeille / trousseau | « Afficher dans le Finder », « Placer dans la Corbeille ». |
| Input Monitoring / App Management | Surveillance de l’entrée / Gestion des apps | Libellés macOS ; situer les autorisations dans Confidentialité et sécurité si utile. |
| Accessibility / Local Network | Accessibilité / Réseau local | Libellés des autorisations macOS. |
| Login Items | Ouverture | Nom de la rubrique macOS ; « ouvrir à la connexion » décrit l’action. |
| controllers (matériel) | manettes | Le panneau Apple peut s’appeler « Contrôleurs de jeu » ; ne pas appliquer ce nom aux boutons de Cartouche. |

## Typographie et limites

- U+00A0 avant `:` ; U+202F avant `; ! ?`, à l’intérieur de `« … »`
  et devant `%` ; apostrophe `’`, points de suspension `…`.
- Boutons et menus courts. Ne pas raccourcir une action au point de la rendre ambiguë.
- Variantes `one` / `other` conservées : en français, 0 prend le singulier.
  Les arguments `%@`, `%lld`, `%d`, les arguments positionnels et `%%` sont intacts.
- Les diagnostics bas niveau gardent les noms techniques nécessaires : ntdll,
  dyld, RVA, PE, hook, detour, cave, bridge, sha256 et noms de fichiers.

## Références et méthode

Vocabulaire de référence : Steam / Steam Play, Epic Games Launcher, GOG Galaxy,
Battle.net et Heroic pour les actions de bibliothèque ; CrossOver pour Wine et
les préfixes ; macOS pour les dialogues système et autorisations. Ce sont des
choix éditoriaux fondés sur les usages francophones, pas une reproduction de
chaque interface. La recherche web n’était pas configurée durant cette passe :
aucune vérification en ligne de leurs versions actuelles n’est revendiquée.
Le contexte Swift de Cartouche prime sur le libellé anglais, notamment pour
« Get », « Windows Installers », « Your Play » et « Starts with ».
