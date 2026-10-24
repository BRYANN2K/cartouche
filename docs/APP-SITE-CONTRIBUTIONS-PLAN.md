# Partager les résultats et les fixes depuis Cartouche

Plan préparé le 24 octobre 2026. Proposition de mise en œuvre ; aucun changement fonctionnel n’est effectué par ce document.

## Objectif

Depuis la fiche d’un jeu dans l’app, l’utilisateur peut partager un résultat ou proposer le réglage qui a résolu son problème. Les contributions sont reçues par notre site, examinées, puis accessibles aux autres utilisateurs sur le site et dans l’app. Le système actuel reste disponible pour consulter les données lorsque notre service ne répond pas ou ne couvre pas un jeu.

Le partage est la priorité. Un simple remplacement du téléchargement de compatibilité ne suffit pas.

## Ce qui existe déjà

| Dans l’app | Dans le site / backend |
|---|---|
| `PerformanceStore` conserve les sessions et leurs mesures localement. | `POST /contributors` crée un identifiant de contribution pseudonyme. |
| `PerformanceReport.make` prépare déjà des données filtrées. | Les rapports ont des consentements, une clé d’idempotence et une modération. |
| `PerformanceSharing` possède une abstraction d’envoi, mais son endpoint par défaut est `nil`. | Les rapports peuvent être consultés par leur auteur, modifiés et retirés. |
| `PerformanceModel` contient un chemin de partage conditionné par une préférence. | Les propositions de fixes et leurs nouvelles révisions sont stockées en attente. |
| Le fichier GitHub `compat.json.gz` et les requêtes MacGamingDB ont leurs caches. | Les fixes publiés disposent d’artefacts signés et d’un registre de révocation. |

Le format `PerformanceReport` actuel n’est pas le contrat `reportInput` du backend : il faudra un adaptateur. Il ne suffit pas de remplacer l’URL de `PerformanceSharing`.

L’app ne possède pas encore de parcours complet de publication de fix. Le backend ne fournit pas encore tous les outils nécessaires à son suivi par l’auteur : liste de ses fixes, retrait et idempotence des propositions/révisions.

Les exports existent dans le dépôt du site, mais leur mise à disposition publique et l’accessibilité de l’API de production devront être vérifiées avant une activation dans l’app. Un artefact CI ne constitue pas à lui seul un flux public pour les clients.

## Parcours proposé dans l’app

### Partager un résultat

1. Depuis un jeu ou une session terminée : bouton **Partager mes résultats**.
2. Une feuille présente le jeu, la date et la méthode réellement utilisée : Native, Wine ou autre méthode reconnue.
3. Préremplir les informations disponibles dans la session : runner et version, backend, traduction, résolution, durée mesurée et FPS. Utiliser le matériel réel du Mac ; le défaut M5 / 16 Go du site n’a aucun rôle dans la collecte de l’app.
4. L’utilisateur choisit le résultat : jouable, problèmes, menu uniquement ou ne démarre pas. Une mesure FPS ou une fermeture du processus ne prouve pas à elle seule que le jeu est jouable.
5. Si le jeu possède un anti-cheat identifié, demander éventuellement le mode testé et son résultat. Ne rien afficher à ce sujet pour les autres jeux ; ne pas déduire le succès du matchmaking à partir des FPS.
6. Afficher un aperçu lisible et un choix explicite pour partager les statistiques et le matériel. Un rapport sans statistiques reste possible. Les champs partagés et la licence de contribution sont visibles avant confirmation.
7. Après confirmation : **En attente de validation**, avec accès à **Mes contributions**. Le rapport devient public uniquement après publication par la modération.

Première version : envoi manuel. Ne pas activer la branche existante d’envoi automatique simplement parce qu’un endpoint devient disponible. Un éventuel partage automatique sera une option séparée, désactivée par défaut et ajoutée ultérieurement.

### Partager un fix

1. Depuis la configuration du jeu : bouton **Partager un fix**.
2. L’app prépare une proposition à partir des réglages concernés et affiche exactement ce qui sera partagé. Montrer les différences avec une configuration de référence connue, lorsqu’elle existe ; ne pas inventer une comparaison avant/après.
3. L’utilisateur ajoute un titre, le problème résolu et les conditions dans lesquelles le fix a fonctionné.
4. Si disponible, associer un rapport de validation appartenant au même jeu. Un rapport encore en attente peut être suivi comme dépendance locale ; le backend doit vérifier son admissibilité lors de la publication du fix.
5. Envoyer une proposition, sans modifier les réglages d’autres utilisateurs.
6. Dans **Mes contributions** : suivre la validation, lire le motif d’un rejet, proposer une révision et retirer une proposition selon les possibilités ajoutées à l’API.

Limiter le premier format aux opérations que le backend sait déjà représenter : backend graphique, traduction Rosetta/FEX, version Mac/Windows et Metal HUD. Un environnement personnalisé, des arguments libres, un patch de fichiers ou une commande shell ne peuvent pas être présentés comme un fix structuré pris en charge par ce format. Ne pas exporter un préfixe Wine entier.

## Ordre d’implémentation

### Lot 1 — Contrat et réception fiables

- Stabiliser et documenter les contrats Swift ↔ API pour les rapports et les fixes, avec des fixtures partagées.
- Résoudre les jeux par identifiant de magasin exact. Pour les jeux importés manuellement, faire confirmer l’identité avant le premier partage ; une similarité de titre n’est pas une identité fiable.
- Ajouter un client de contribution Swift injectable pour les tests.
- Créer l’identifiant pseudonyme au premier partage et conserver le secret dans le Trousseau. Aucun compte Steam ni identifiant matériel n’est nécessaire. Ne jamais embarquer la clé d’administration ou de signature dans l’app.
- Ajouter au backend l’idempotence des propositions de fixes et des révisions. Les rapports possèdent déjà cette protection.
- Ajouter le suivi des fixes par l’auteur et définir précisément le retrait : retrait d’un brouillon ou d’une proposition, et traitement d’un fix déjà publié via le mécanisme de révocation.
- Vérifier la correspondance des mesures. Le backend accepte `second-buckets-v1` ou `frame-times-v1`, et n’accepte un 1 % low que pour les vrais frame times. Ne pas envoyer le low calculé sur des buckets de secondes en le rebaptisant frame-times.
- Conserver les champs inconnus comme inconnus : build du jeu, API observée, mode anti-cheat. Ne pas fabriquer une version pour satisfaire les conditions d’un fix.

Livrable : une soumission de rapport et une proposition de fix complètent le parcours dans un environnement de test, avec authentification d’auteur et reprise sans doublon.

### Lot 2 — Partage de résultats dans l’app

- Ajouter la feuille d’aperçu et de consentement.
- Adapter `StoredSession` au contrat du backend, sans envoyer le format local tel quel.
- Autoriser aussi les rapports manuels sans FPS, notamment « ne démarre pas ».
- Ajouter une file d’envoi locale persistante : brouillon → confirmé → envoi → reçu / validation → publié ou rejeté. Séparer l’état de transport de l’état de modération.
- Hors ligne, conserver uniquement ce que l’utilisateur a confirmé pour envoi et annoncer qu’il est en attente. Réutiliser la même clé lors d’une reprise du même contenu. Une modification de contenu doit produire une nouvelle opération.
- Respecter les délais de reprise et les réponses 429. Ne pas recréer un contributeur en boucle si le Trousseau ou le réseau échoue.
- Ajouter **Mes contributions** pour consulter, modifier et retirer ses rapports. Un brouillon local doit pouvoir être supprimé avant son envoi.

Livrable : un utilisateur peut envoyer un résultat depuis l’app et suivre son statut sans ouvrir le site.

### Lot 3 — Propositions de fixes et modération

- Ajouter l’éditeur simple, l’aperçu des réglages et le lien éventuel à une session ou un rapport.
- Vérifier que le jeu, les builds et les backends requis sont connus ; expliquer un champ manquant sans inventer sa valeur.
- Réutiliser la file d’envoi et le suivi d’auteur.
- Prévoir une interface de modération utilisable pour rapports et fixes ; les endpoints administrateur existent déjà. Le secret administrateur reste côté outil de modération.
- Publication d’un rapport : recalculer les cohortes, puis actualiser les données lues par le site et l’app. Publication d’un fix : produire l’artefact signé et mettre à jour le registre.
- Prévoir la régénération des fichiers catalogue après modération, avec reprise en cas d’échec. Mettre à jour la base seule ne rafraîchit pas automatiquement les fichiers statiques déjà servis.

Livrable : un fix partagé dans l’app peut être examiné, publié et retrouvé sur la fiche du jeu.

### Lot 4 — Lire les contributions validées et conserver le fallback

- Ajouter un flux public versionné destiné à l’app, à partir des exports existants. Ne pas faire décoder le snapshot backend V2 par le décodeur strict de l’ancien `compat.json.gz` V1.
- Extraire la politique actuelle du site dans un module partagé entre son interface et son export : client Mac officiel, CrossOver positif, confirmations utilisateur et exceptions par mode. Éviter une deuxième interprétation indépendante dans chaque écran Swift.
- Inclure provenance, dates, méthode et contexte des mesures. Représenter séparément l’anti-cheat présent, l’absence connue et l’information inconnue ; l’absence d’information ne constitue pas une preuve d’absence.
- Résolution de lecture : données Cartouche applicables → dernière copie Cartouche encore utilisable → ancien fichier GitHub et MacGamingDB pour les données manquantes → aucune information inventée.
- Une réponse valide « incompatible », un anti-cheat explicitement absent ou une révocation ne déclenche pas le fallback pour restaurer une ancienne valeur contraire. Les données Linux du système historique restent marquées Linux et ne remplacent pas un verdict Mac.
- Charger le cache immédiatement et rafraîchir sans bloquer l’app. Conserver des caches distincts et la dernière copie valide ; respecter les expirations des cohortes et les retraits. Le flux destiné au cache doit définir ces règles, contrairement aux routes actuelles de rapports publics en `no-store`.
- Faire lire le même résultat résolu à la fiche jeu, aux badges de bibliothèque et aux outils de l’agent. L’agent ne doit pas continuer à annoncer une interdiction Wine à partir d’une simple ligne de log ou d’une règle Linux contredite par une déclaration Mac pertinente.
- Préserver les préférences réseau et les refus de partage existants. Mettre à jour les textes de confidentialité et d’attribution pour décrire les nouveaux échanges.

Le fallback concerne la consultation. Un échec d’envoi vers notre site reste dans la file locale ; il ne doit jamais provoquer un envoi vers MacGamingDB ou un autre service.

### Lot 5 — Utiliser un fix partagé

- Afficher les fixes publiés et leurs conditions depuis la fiche du jeu.
- Avant application : vérifier la signature avec une clé publique de confiance distribuée avec l’app, le hash, l’expiration, les révocations et la correspondance du jeu/runner/build/backend.
- Présenter les changements, demander l’action explicite de l’utilisateur, sauvegarder les réglages précédents et permettre l’annulation.
- Une lecture hors ligne ne suffit pas à appliquer un fix si son registre de validation/révocation est expiré. L’ancien système de compatibilité ne remplace pas ces vérifications.
- Conserver l’application dans le mécanisme existant de configuration du jeu ; ne pas exécuter de code provenant du texte d’une contribution.

Livrable : un autre utilisateur peut utiliser un fix validé depuis l’app et revenir à ses réglages précédents.

## Validation avant activation

| Cas | Résultat attendu |
|---|---|
| Aucun partage accepté | Aucune session envoyée. |
| Partage sans statistiques | Aucun matériel ni FPS dans la requête. |
| Session mesurée | Méthode, durée et métriques décrivent réellement le collecteur. |
| Jeu sans anti-cheat identifié | Aucun formulaire ou badge anti-cheat. |
| Réseau coupé après réception serveur | Reprise de l’envoi sans rapport ni fix en double. |
| App fermée avec un envoi confirmé en attente | File retrouvée au redémarrage ; possibilité d’annuler un envoi non reçu. |
| Identité de jeu incertaine | Confirmation du jeu avant envoi. |
| Rapport ou fix en attente | Visible par son auteur, absent des résultats publics. |
| Rapport modifié / retiré | Statut et agrégats actualisés, sans republier l’ancien contenu depuis le cache. |
| Fix révoqué ou signature invalide | Pas d’application. |
| Site indisponible ou format inconnu | Consultation avec cache valide puis système historique, sans perte de configuration locale. |
| Dota Native, CS2, Deadlock, GTA Online | Même politique et même provenance que le site, avec les exceptions conservées. |
| Fix appliqué puis annulé | Retour exact à la configuration sauvegardée. |

Commencer par un petit groupe de testeurs, puis activer le partage manuel. Garder un moyen de désactiver la source Cartouche et les envois sans désactiver les jeux ni supprimer les brouillons.

## Périmètre recommandé pour la première livraison

**Livrer d’abord le partage manuel des résultats, le suivi des contributions et la proposition de fixes simples.** Conserver toute la lecture historique pendant cette livraison. Brancher ensuite les contributions validées comme source principale, puis l’application contrôlée des fixes. Reporter le partage automatique, les scripts, les patchs arbitraires et la migration des identités contributeur entre navigateur et app.

## Points de code inspectés

App : `PerformanceSharing.swift`, `PerformanceModel.swift`, `PerformanceStore.swift`, `PrivacyChoices.swift`, `CompatibilityClient.swift`, `CompatibilityModel.swift`, `CompatibilityPanel.swift`, `AntiCheatSummary.swift`, `LibraryGrid.swift`, `AgentReadTools.swift`, `AgentActionTools.swift`, `AgentDiagnose.swift`.

Site : `backend/src/contracts.ts`, `backend/src/app.ts`, `backend/src/service.ts`, `backend/src/exports.ts`, `backend/src/compatibility-declarations.json`, `src/scripts/games-model.mjs`, `src/scripts/publish-catalogue.mjs`, `.github/workflows/community-data.yml`.

## Revue du plan contre le code (24 octobre 2026)

Points corrigés ou précisés après lecture du code réel :

- **Version du jeu.** `recipeInput.applies_to.game_builds` exigeait au moins une valeur, ce qui forçait l’app à inventer une version. Le backend accepte maintenant une liste vide : « version non enregistrée ». L’app lit le `buildid` des manifestes Steam quand il existe ; sinon la liste reste vide et l’application d’un fix exigeant une version est refusée faute de comparaison possible.
- **Sessions mesurées.** Les sessions de `PerformanceStore` viennent uniquement de l’outil Steam Play (`compat_run.sh`) : elles sont toujours en Wine. Une partie en version Mac n’a pas de mesure ; son rapport est manuel.
- **1 % low.** `PlayStats.low1` est calculé sur des buckets d’une seconde. Il n’est jamais envoyé ; `excluded_seconds` est calculé à partir des échantillons non comptés.
- **Jeu absent du catalogue.** Une soumission vers un jeu inconnu du backend reçoit `404 game_not_found`. L’app propose alors le jeu (`POST /game-proposals`) et retente le lendemain, sans changer de service.
- **Révisions et retraits de rapports.** `PATCH` et `DELETE` n’ont pas de clé d’idempotence ; ils utilisent `If-Match`. Une reprise après réception côté serveur reçoit `409` ; l’app relit alors « Mes contributions » pour constater l’état réel.
- **Absence d’anti-cheat.** Aucune source actuelle ne déclare explicitement « aucun anti-cheat ». Le flux prévoit l’état `absent`, réservé à un marqueur explicite revu ; en pratique les états sont `present` ou `unknown`.
- **Signature.** Chaque artefact contient sa clé publique ; l’app l’ignore et n’accepte que les clés listées dans `CartoucheFixKeys` (Info.plist), par `key_id`. Le registre expire après 24 h : hors ligne au-delà, aucun fix ne s’applique.
- **Traductions.** `make l10ncheck` exige le français, l’italien et le chinois simplifié pour chaque nouveau texte.
- **Lectures publiques.** Le site lisait l’API pour chaque ligne et chaque page. Les lectures publiques passent par des fichiers statiques versionnés (`cartouche-game-v1`, `cartouche-search-v1`), aussi servis en mémoire par l’API et les outils MCP.
- **Politique partagée.** Elle vit dans `backend/src/compat-policy.mjs`, importée par `games-model.mjs`, l’export du catalogue et le flux de l’app.

## État de la mise en œuvre

| Lot | État |
|---|---|
| 1 | Fait : contrats et fixtures partagées (`docs/schema/contributions`), identité exacte, client injectable, secret au Trousseau, idempotence des fixes, suivi et retrait par l’auteur. |
| 2 | Fait : feuille d’aperçu et de consentement, rapports sans FPS, file persistante, reprise, 429, « Mes contributions ». Modification d’un rapport publié : opération prévue dans la file, sans écran dédié. |
| 3 | Fait côté backend : éditeur de fix, client de modération privé (`npm run moderate`), exports marqués à régénérer avec reprise. Pas d’interface web de modération. |
| 4 | Fait : flux V1 de l’app, cache distinct, résolution unique pour la fiche, les badges et l’agent. |
| 5 | Fait : vérification signature/hash/expiration/révocation/correspondance, aperçu, sauvegarde et annulation exacte. |

Activation restante : URL de production (`CartoucheCommunityURL`), clé publique de signature (`CartoucheFixKeys`), clé privée et `FIX_SIGNING_KEY_*` côté serveur, hébergement public des fichiers exportés.
