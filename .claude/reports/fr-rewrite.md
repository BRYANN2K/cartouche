# Réécriture française — Cartouche

## Périmètre

Relecture des 1 420 clés de Localizable.xcstrings et des trois messages de
InfoPlist.xcstrings. Lecture des valeurs françaises, des variantes et du contexte
Swift : bibliothèque, installation, import, consoles, commandes, comptes,
performances, autorisations et diagnostics. Les messages techniques restent
précis ; les chaînes déjà naturelles restent inchangées.

La branche intègre `main` (`a46a8bb`), y compris les options avancées.
Les traductions françaises manquantes de cette révision sont complétées.
Les autres langues, clés, commentaires et métadonnées ne sont pas modifiés.

### Décisions de contexte

- **Jeux hors boutique** : `GameSource.installer` regroupe des jeux déjà installés
  depuis un fichier ou un dossier. Ce n’est pas une liste de programmes d’installation.
- **Installer** : le badge Steam absent mène au parcours de téléchargement puis
  d’installation. « Obtenir » ne décrit pas cette action.
- **Version de Wine** : les choix proposés sont Wine CrossOver / WineHQ /
  CrossOver. Leur rôle reste distinct de l’outil de compatibilité Steam Play.
- **Vos performances** : cette section mesure les FPS et le temps de jeu.
- **Programme de lancement** : le champ « Starts with » choisit l’exécutable,
  et non une touche de départ.

## Les 40 changements les plus visibles

| # | Avant → après | Emplacement / clé |
| --- | --- | --- |
| 1 | Obtenir → **Installer** | `app/Sources/NotProtonApp/Library/LibraryModel.swift:344` (Get) |
| 2 | Installateurs Windows → **Jeux hors boutique** | `app/Sources/NotProtonApp/Library/Game.swift:37` (Windows Installers) |
| 3 | Pas encore d’installateurs Windows → **Aucun jeu hors boutique** | `app/Sources/NotProtonApp/Library/Views/LibraryStates.swift:314` (No Windows installers yet) |
| 4 | Installateur → **Programme d’installation** | `app/Sources/NotProtonApp/Installer/InstallSheetView.swift:165` (Installer) |
| 5 | Vérification de l’installateur → **Vérification du programme d’installation** | `app/Sources/NotProtonApp/Installer/InstallSheetView.swift:72` (Checking the Installer) |
| 6 | Déposez un jeu, un installateur, une archive ou des ROMs → **Déposez un jeu, un programme d’installation, une archive ou des ROM** | `app/Sources/NotProtonApp/Library/Drop/DropViews.swift:55` (Drop a game, an installer, an archive or ROMs) |
| 7 | Votre jeu → **Vos performances** | `app/Sources/NotProtonApp/Library/GamePanelContent.swift:41` (Your Play) |
| 8 | Prévu sur ce Mac → **Performances estimées sur ce Mac** | `app/Sources/NotProtonApp/Library/GamePanelContent.swift:42` (Expected on This Mac) |
| 9 | Graphismes rapportés sur Mac → **Rendus utilisés sur Mac** | `app/Sources/NotProtonApp/Library/GamePanelContent.swift:44` (Graphics Reported on Macs) |
| 10 | Le meilleur → **Meilleure** | `app/Sources/NotProtonApp/Performance/YourPlayViews.swift:111` (Best) |
| 11 | Optimal avec %@ → **Meilleures performances avec %@** | `Parcours / message interpolé : `Best with %@`` (Best with %@) |
| 12 | Utilisée → **Configuration actuelle** | `app/Sources/NotProtonApp/Performance/YourPlayViews.swift:138` (In Use) |
| 13 | 1 % low → **1 % les plus bas** | `app/Sources/NotProtonApp/Performance/YourPlayViews.swift:46` (1% low) |
| 14 | Contrôles → **Commandes** | `app/Sources/NotProtonApp/Library/Views/GamePanel.swift:79` (Controls) |
| 15 | Contrôles de %@ → **Commandes de %@** | `Parcours / message interpolé : `Controls for %@`` (Controls for %@) |
| 16 | Southpaw → **Gaucher** | `app/Sources/NotProtonApp/Controls/ControllerLayout.swift:105` (Southpaw) |
| 17 | Disposition → **Configuration des commandes** | `app/Sources/NotProtonApp/Controls/ControlsViews.swift:136` (Layout) |
| 18 | Obtenir d’autres rendus graphiques… → **Ajouter un moteur de rendu…** | `app/Sources/NotProtonApp/Setup/SetupDefaultsSection.swift:32` (Get More Graphics Backends…) |
| 19 | Rendus graphiques → **Moteurs de rendu** | `app/Sources/NotProtonApp/Setup/SetupDefaultsSection.swift:98` (Graphics Backends) |
| 20 | Runner par défaut → **Version de Wine par défaut** | `app/Sources/NotProtonApp/Setup/SetupDefaultsSection.swift:13` (Default runner) |
| 21 | Runner → **Version de Wine** | `app/Sources/NotProtonApp/Library/GameActions.swift:91` (Runner) |
| 22 | Runners → **Versions de Wine** | `app/Sources/NotProtonApp/Library/Views/SettingsWindow.swift:289` (Runners) |
| 23 | Configurer un runner… → **Configurer Wine…** | `app/Sources/NotProtonApp/Library/Views/GamePanel.swift:305` (Set Up a Runner…) |
| 24 | Essayer un autre runner → **Essayer une autre version de Wine** | `app/Sources/NotProtonApp/Installer/InstallSheetView.swift:490` (Try Another Runner) |
| 25 | Launcher de l’éditeur → **Lanceur de l’éditeur** | `app/Sources/NotProtonApp/Installer/InstallSheetView.swift:538` (Launcher from the publisher) |
| 26 | Ajoutez des jeux installés par un autre launcher → **Ajoutez des jeux installés avec un autre lanceur** | `app/Sources/NotProtonApp/Stores/StoreViews.swift:127` (Add games another launcher installed) |
| 27 | Rapatriez vos jeux sur ce Mac → **Retrouvez vos jeux sur ce Mac** | `app/Sources/NotProtonApp/Library/Views/LibraryStates.swift:107` (Bring your games to this Mac) |
| 28 | Ajouté par vous → **Ajout manuel** | `app/Sources/NotProtonApp/Onboarding/OnboardingView.swift:484` (Added by you) |
| 29 | Pause → **Mettre en pause** | `app/Sources/NotProtonApp/Activity/Views/ActivityViews.swift:329` (Pause) |
| 30 | En attente de vous → **Demandes à confirmer** | `app/Sources/NotProtonApp/Agent/AgentViews.swift:29` (Waiting for You) |
| 31 | Recueillir les diagnostics… → **Créer un rapport de diagnostic…** | `app/Sources/NotProtonApp/Library/Views/SettingsWindow.swift:235` (Collect Diagnostics…) |
| 32 | Revérifier → **Vérifier à nouveau** | `app/Sources/NotProtonApp/Installer/InstallSheetView.swift:92` (Check Again) |
| 33 | Utiliser sur place → **Utiliser sans copier** | `app/Sources/NotProtonApp/Library/Drop/DropClassifierAdapter.swift:3` (Use in Place) |
| 34 | Sauvegardes cloud → **Sauvegardes dans le cloud** | `app/Sources/NotProtonApp/Stores/StoreViews.swift:45` (Cloud saves) |
| 35 | Permission de la manette → **Autorisation pour les manettes** | `app/Sources/NotProtonApp/Views/StatusView.swift:333` (Controller permission) |
| 36 | Connecter → **Se connecter** | `app/Sources/NotProtonApp/Agent/AgentViews.swift:73` (Connect) |
| 37 | Connecter %@ → **Se connecter à %@** | `Parcours / message interpolé : `Connect %@`` (Connect %@) |
| 38 | Suggérer les installateurs qui apparaissent dans Téléchargements → **Proposer d’installer les jeux téléchargés** | `app/Sources/NotProtonApp/Permissions/Permission.swift:92` (Suggest installers that appear in Downloads) |
| 39 | Démarre avec → **Programme de lancement** | `app/Sources/NotProtonApp/Library/Drop/DropViews.swift:283` (Starts with) |
| 40 | Metal HUD → **Indicateurs Metal** | `app/Sources/NotProtonApp/Library/Views/AdvancedGameRows.swift:44` (Metal HUD) |

## Validation

- JSON chargé sans erreur ; format xcstringstool exact, dictionnaires vides et
  absence de saut de ligne final vérifiés.
- Contrôle des arguments de format par position et type sur toutes les variantes
  françaises des deux catalogues : 1 468 variantes, aucune différence avec l’anglais.
  Les caractères `%` littéraux ne sont pas traités comme des arguments.
- Comparaison structurelle avant/après : aucune modification hors `fr` dans les catalogues.
- Aucune traduction requise ne manque ; les noms protégés `shouldTranslate: false`
  restent inchangés.
- Pas de build Release dans ce worktree : validation de remplacement par script,
  conformément au contrat. `make -s l10ncheck` n’a donc pas été lancé.
- Pas de modification de logique, de constante ou de données utilisateur.

## Limite des références

La recherche web n’est pas configurée (clé Serper absente). Les conventions des
produits cités servent de référence éditoriale connue, sans prétendre à une
vérification de leurs interfaces actuelles. Aucun accès aux comptes utilisateur.

## Onboarding et réglages

Deuxième passe sur `main` (`9257327`), après l’intégration de l’assistant v2
et de la nouvelle fenêtre Réglages. Relecture des 110 clés ajoutées depuis la
première passe et des 255 libellés directement utilisés par ces vues, avec leurs
appels Swift. 49 clés françaises modifiées, sans changement des autres langues.

Les boutons « Steam Settings… » ouvrent la rubrique Steam **dans Cartouche**,
non les préférences du client Steam. Les indications pointent donc vers
« Réglages > Steam ». L’étape Wine lance ses téléchargements en arrière-plan :
le texte le dit explicitement. L’aperçu de manette reste un aperçu, pas un test
interactif promis par le texte.

| Avant → après | Emplacement / clé |
| --- | --- |
| %lld jeux dans la bibliothèque → **%lld jeu dans la bibliothèque / %lld jeux dans la bibliothèque** | %lld games in the library |
| %lld autres jeux installés → **%lld autre jeu installé / %lld autres jeux installés** | %lld other installed games |
| Un outil de compatibilité Steam doit être réparé. Vérifiez-le dans les Réglages. → **Un outil de compatibilité Steam doit être réparé. Consultez Réglages > Steam dans Cartouche.** | A Steam compatibility tool needs repair. Review it in Settings. |
| Un foyer pour vos classiques. → **Retrouvez vos classiques.** | A home for your classics. |
| Une autre intégration est installée dans Steam. Vérifiez-la dans les Réglages avant d’installer Cartouche. → **Un autre outil modifie déjà Steam. Consultez Réglages > Steam dans Cartouche avant de poursuivre l’installation.** | Another integration is installed in Steam. Review it in Settings before installing Cartouche. |
| Emportez votre bibliothèque. → **Retrouvez toute votre bibliothèque.** | Bring your library along. |
| Cartouche n’a pas pu vérifier ses fichiers installés. Vérifiez les réglages Steam avant de continuer. → **Cartouche n’a pas pu vérifier ses fichiers installés. Ouvrez Réglages > Steam dans Cartouche avant de continuer.** | Cartouche could not verify its installed files. Review Steam Settings before continuing. |
| Cartouche n’est pas installé dans Steam. Configurez-le dans les Réglages. → **Cartouche n’est pas installé dans Steam. Configurez-le dans Réglages > Steam.** | Cartouche is not installed in Steam. Set it up in Settings. |
| Choisissez un runner. Les téléchargements ne vous retiendront pas. → **Choisissez une version de Wine. Vous pouvez continuer pendant les téléchargements.** | Choose a runner. Downloads won’t hold you up. |
| Choisissez uniquement les systèmes auxquels vous jouez. → **Choisissez les consoles qui vous intéressent.** | Choose only the systems you play. |
| Connectez votre manette par Bluetooth ou USB. Aucune configuration nécessaire. → **Connectez votre manette en Bluetooth ou en USB. Aucune configuration nécessaire.** | Connect by Bluetooth or USB. No setup required. |
| Connectez-vous maintenant, ou revenez dans Réglages. → **Connectez-vous maintenant ou plus tard dans les Réglages.** | Connect now, or come back in Settings. |
| Se poursuit dans Activité → **Suivez la progression dans Activité** | Continues in Activity |
| Copie de D3DMetal depuis l’image → **Copie de D3DMetal depuis l’image disque** | Copying D3DMetal from the image |
| D3DMetal nécessite le Game Porting Toolkit d’Apple. Utilisez votre propre image disque obtenue auprès d’Apple. → **D3DMetal nécessite le Game Porting Toolkit d’Apple. Utilisez l’image disque téléchargée sur le site d’Apple.** | D3DMetal needs Apple’s Game Porting Toolkit. Use your own disk image from Apple. |
| DXMT et DXVK sont inclus avec le runner, sans choix à faire. → **DXMT et DXVK sont inclus avec cette version de Wine. Rien à choisir.** | DXMT and DXVK come with the runner — nothing to pick. |
| Les téléchargements s’affichent ici et dans Activité → **Suivez les téléchargements ici et dans Activité** | Downloads appear here and in Activity |
| Déposez le .dmg du Game Porting Toolkit ici → **Déposez le fichier .dmg du Game Porting Toolkit ici** | Drop the Game Porting Toolkit .dmg here |
| Tous ces choix sont disponibles dans Réglages. → **Vous pouvez modifier tous ces choix dans les Réglages.** | Every choice is available in Settings. |
| Recherchez des jaquettes et des rapports de compatibilité par nom de jeu. → **Rechercher des jaquettes et des avis de compatibilité à partir du nom du jeu.** | Find covers and compatibility reports by game name. |
| Télécharger → **Installer** | Get it |
| Télécharger chez Apple → **Télécharger sur le site d’Apple** | Get it from Apple |
| Continuez à explorer pendant que la configuration se termine en arrière-plan. → **Découvrez Cartouche pendant que la configuration se termine en arrière-plan.** | Keep exploring while setup finishes in the background. |
| Faites place au jeu. → **Place au jeu.** | Make room for play. |
| Aucun outil de compatibilité n’est configuré pour Steam. Configurez-en un dans les Réglages. → **Aucun outil de compatibilité n’est configuré pour Steam. Configurez-en un dans Réglages > Steam.** | No compatibility tool is set up for Steam. Set one up in Settings. |
| Aucune manette connectée. Vos choix s’appliqueront lorsque vous en brancherez une. → **Aucune manette connectée. Vos choix s’appliqueront dès que vous en connecterez une.** | No controller connected — your choices apply when you plug one in. |
| Uniquement les accès nécessaires, au bon moment. → **Les autorisations nécessaires, au moment où vous en avez besoin.** | Only the access you need, when you need it. |
| Jouer aux jeux au clavier avec la manette → **Jouer à la manette aux jeux prévus pour le clavier** | Play keyboard-only games with the controller |
| Jouez-y à la manette. L’autorisation Accessibilité sera nécessaire plus tard. → **Jouez-y à la manette. L’autorisation Accessibilité vous sera demandée au premier usage.** | Play them with the controller — needs Accessibility later. |
| PlayStation affiche ○△□×, Xbox affiche ABXY. → **Symboles PlayStation : ○△□×. Symboles Xbox : ABXY.** | PlayStation shows ○△□×, Xbox shows ABXY. |
| Prévisualisez la disposition. Personnalisez chaque jeu dans Commandes. → **Visualisez la configuration ci-dessus. Personnalisez les commandes de chaque jeu dans Commandes.** | Preview the layout. Customize each game in Controls. |
| Recevoir les bêtas → **Recevoir les versions bêta** | Receive beta updates |
| Recommandé — active D3DMetal et DXMT → **Recommandé pour utiliser D3DMetal et DXMT** | Recommended — unlocks D3DMetal and DXMT |
| Restaurer le préfixe sauvegardé → **Restaurer une sauvegarde du préfixe** | Restore prefix backup |
| Restaurer la sélection → **Restaurer la sauvegarde** | Restore selected |
| Restaurer la sauvegarde sélectionnée ? → **Restaurer la sauvegarde sélectionnée ?** | Restore selected backup? |
| Runners… → **Versions de Wine…** | Runners… |
| Enregistré sur ce Mac → **Choix enregistrés sur ce Mac** | Saved on this Mac |
| Configurez une version de Wine dans Réglages > Compatibilité pour jouer à %@. → **Configurez une version de Wine dans Réglages > Versions de Wine pour jouer à %@.** | Set up a runner in Settings > Compatibility to play %@. |
| Réglages Steam… → **Réglages > Steam…** | Steam Settings… |
| Steam est introuvable. Choisissez ou installez Steam dans les Réglages. → **Steam est introuvable. Choisissez son emplacement ou installez-le dans Réglages > Steam.** | Steam could not be found. Choose or install Steam in Settings. |
| Des fichiers de l’intégration de Cartouche à Steam sont manquants ou modifiés. Réparez-la dans les Réglages. → **Certains fichiers de l’intégration de Cartouche à Steam sont manquants ou ont été modifiés. Réparez l’installation dans Réglages > Steam.** | Steam’s Cartouche integration has missing or changed files. Repair it in Settings. |
| La sauvegarde est utilisée. Quittez d’abord le jeu. → **La sauvegarde est en cours d’utilisation. Quittez d’abord le jeu.** | The backup is in use. Quit the game first. |
| L’image ne contient pas de Game Porting Toolkit. → **L’image disque ne contient pas de Game Porting Toolkit.** | The image holds no Game Porting Toolkit. |
| Le runner n’est pas encore prêt. → **Cette version de Wine n’est pas encore prête.** | The runner is not ready yet. |
| Quand vous ouvrez un jeu, Cartouche demande ses rapports Mac à MacGamingDB. Quand un jeu Windows n’a pas de jaquette, son nom peut être recherché dans la boutique Steam. Aucun des deux services ne reçoit d’identifiant de compte ou de Mac. → **Quand vous ouvrez un jeu, Cartouche consulte les avis Mac de MacGamingDB. Si un jeu Windows n’a pas de jaquette, son nom peut être recherché dans la boutique Steam. Aucun identifiant de compte ou de Mac n’est transmis à ces services.** | When you open a game, Cartouche asks MacGamingDB for its Mac reports. When a Windows game has no cover, its name may be looked up in the Steam store. Neither service receives an account or a Mac identifier. |
| Vos comptes et votre historique de jeu restent sur ce Mac. Rien n’est partagé automatiquement. → **Vos comptes et votre historique de jeu restent sur ce Mac. Aucune donnée n’est partagée automatiquement.** | Your accounts and play history stay on this Mac. Nothing is shared automatically. |
| Vous pouvez jouer. → **À vous de jouer.** | You’re ready to play. |
| macOS peut demander l’accès aux volumes amovibles à la première lecture par Cartouche. → **Au premier accès à ce disque, macOS peut vous demander d’autoriser l’accès aux volumes amovibles.** | macOS may ask for Removable Volumes the first time Cartouche reads it. |

Validation : JSON et format xcstringstool exacts ; comparaison structurelle
confirmant que seul `fr` change ; 1 531 variantes françaises contrôlées, aucun
argument de format perdu ou modifié ; toutes les clés traduisibles ont `fr` ;
`git diff --check` sans erreur. Pas de build Release dans ce worktree :
`make -s l10ncheck` reste à lancer après compilation Release.
Aucune constante ni logique modifiée. Références en ligne toujours non vérifiées
(Serper non configuré) ; les décisions du glossaire existant sont appliquées.
