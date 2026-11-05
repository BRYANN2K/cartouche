---
title: "Générer des images sur Mac avec MetalFX et le Neural Engine : un frame gen pour les jeux Windows sous Wine"
date: 2026-10-27
author: Bryan
tags: [macOS, Metal, MetalFX, Core ML, Apple Neural Engine, Wine, frame generation, Cartouche]
---

# Générer des images sur Mac avec MetalFX et le Neural Engine

*Comment j'ai construit un frame gen pour les jeux Windows qui tournent dans Wine sur Apple Silicon : un hook dans le processus du jeu, MetalFX, une passe de réparation maison et un réseau de flux optique sur le Neural Engine. Avec les mesures, les impasses et ce qu'elles m'ont appris.*

## Le problème

Cartouche est un lanceur de jeux gratuit pour macOS. Il fait tourner des jeux Windows dans Wine, avec DXMT (Direct3D 11 vers Metal) ou D3DMetal (le traducteur d'Apple). Sur un MacBook Air M4, beaucoup de jeux tournent entre 30 et 45 fps.

Sur PC, la génération d'images (DLSS Frame Generation, FSR 3, Lossless Scaling) double la fluidité affichée. Sur Mac, aucune n'est disponible pour un jeu Wine :
- DLSS-G exige du matériel NVIDIA ;
- Lossless Scaling est un logiciel Windows commercial ;
- les jeux ne fournissent presque jamais les données que ces techniques attendent.

macOS 26 a ajouté `MTLFXFrameInterpolator` à MetalFX : une API qui fabrique l'image intermédiaire entre deux images. Elle a été pensée pour un moteur de jeu qui lui fournit sa profondeur, ses vecteurs de mouvement et sa caméra. Un jeu Windows sous Wine ne lui donne rien de tout ça. Il ne présente que des images finies.

Tout l'article tourne autour de cette question : comment nourrir MetalFX quand on ne voit que les images finales ?

Toutes les mesures viennent d'un MacBook Air M4 (24 Go), sous macOS 27, avec un écran externe à 144 Hz fixe.

## 1. S'installer dans le processus du jeu

La première décision est architecturale. Les outils comme Lossless Scaling ou DraFG capturent l'écran depuis une application externe. Sur Mac, ce serait ScreenCaptureKit. Cette voie ajoute une copie, de la latence, et ne voit jamais les données internes du jeu.

Cartouche lance lui-même le jeu. Il peut donc insérer une bibliothèque dans son processus avec `DYLD_INSERT_LIBRARIES`. Le jeu tourne en x86_64 sous Rosetta, donc la bibliothèque aussi.

Elle remplace trois méthodes par swizzling :
- `-[CAMetalLayer nextDrawable]` ;
- `-[MTLCommandBuffer presentDrawable:]` et ses variantes `afterMinimumDuration:` et `atTime:` ;
- `-[CAMetalDrawable present]`.

DXMT et D3DMetal présentent tous deux par ces chemins. La bibliothèque récupère donc chaque image réelle juste avant son affichage, la garde, puis présente elle-même : l'image générée d'abord, la réelle ensuite.

```text
image réelle N ─► copie ─► mouvement ─► MetalFX(N−1, N) ─► réparation ─► présente « N−½ »
                                                                         puis présente « N »
```

Conséquence directe : l'image N n'est affichée qu'après l'image N−½. L'interpolation coûte donc structurellement environ une demi-période de latence, plus le temps de calcul. C'est le prix de toute interpolation : l'extrapolation l'évite, mais au prix d'erreurs visibles.

## 2. Un banc de mesure avant tout

Le premier prototype « marchait », mais avec un ghosting énorme. Pour avancer autrement qu'à l'œil, j'ai construit trois bancs.

**`framegen-tune`** est une scène Metal en 3D : des cubes qui tournent, un sol en damier, une caméra qui oscille et un logo fixe en guise de HUD. Le banc rend aussi la **vraie** image du milieu et le **vrai** mouvement par pixel. Chaque image générée est comparée à la vérité, avec trois mesures :
- `ghost%` : la part des pixels qui s'écartent de plus de 24 niveaux sur 255 ;
- `2x2%` : la même chose sur des moyennes de blocs 2×2, pour ne pas compter comme fantôme le crénelage qui diffère entre deux rastérisations ;
- un score sur la zone du HUD.

**`framegen-wine`** fait tourner une vraie scène Direct3D 11, compilée avec mingw-w64, dans le Wine de Cartouche. Elle passe par DXMT et par D3DMetal, avec une charge GPU réglable et un mode qui appelle DLSS.

**Le sample FSR d'AMD**, sous licence MIT, apporte une scène Sponza en D3D12 qui sature le GPU : le cas réaliste du jeu lourd.

Chaque exécution peut écrire une CSV par seconde, avec les fps rendus et affichés, le coût GPU, la latence, l'histogramme des intervalles d'affichage et la confiance de la réparation.

## 3. Première surprise : MetalFX se moque de la profondeur

Hypothèse de départ : MetalFX ghoste parce qu'on lui donne une profondeur constante, donc aucun ordre d'occlusion. J'ai fait tourner le banc avec cinq profondeurs différentes, en lui donnant le **vrai** mouvement :

| Profondeur donnée à MetalFX (vrai mouvement) | 72 fps 2x2% | 40 fps 2x2% |
|---|---:|---:|
| Constante 0,5 | 6,52 | 19,31 |
| Vraie profondeur, vraie caméra | 6,51 | 19,29 |
| Vraie profondeur, caméra et matrices macOS 27 | 6,49 | 19,29 |
| Rampe verticale | 6,53 | 19,33 |
| Bruit aléatoire | 6,58 | 19,33 |

Toutes les profondeurs donnent le même résultat, même du bruit. Dans cet usage, MetalFX ne tire aucun ordre d'occlusion de la profondeur. Trois pistes tombent d'un coup :
- la pseudo-profondeur ;
- l'estimation de profondeur monoculaire ;
- les matrices de caméra.

Le même banc montre deux autres choses :
- **Avec des entrées parfaites, MetalFX laisse encore 19 % de blocs faux à 40 fps.** Le plancher vient de MetalFX lui-même, et il grandit avec l'amplitude du mouvement.
- **Notre estimateur GPU est proche du vrai mouvement** : 8,45 % contre 6,52 % à 72 fps. Améliorer le flux ne rapporterait qu'un ou deux points.

Le levier est donc ailleurs : **réparer ce que MetalFX produit**.

## 4. La passe de réparation

Après MetalFX, une passe compute décide, pixel par pixel, si on garde sa sortie ou si on la remplace par une reconstruction en laquelle on a confiance.

Pour un pixel de sortie `q` à mi-chemin, chaque vecteur candidat `v` (convention MetalFX : de l'image courante vers sa position dans la précédente) désigne deux points :
- `p = q + v/2` dans l'image précédente ;
- `c = q − v/2` dans l'image courante.

Si `v` est le bon mouvement, les patchs autour de `p` et de `c` se ressemblent. Le coût d'un candidat est donc l'écart moyen de luminance entre deux patchs 3×3.

On évalue six candidats : le vecteur du pixel, ceux de quatre voisins à 16 px, et le vecteur nul. Le vecteur nul couvre tout ce qui ne bouge pas, en particulier un HUD que MetalFX aurait entraîné avec la scène. Les candidats sont mélangés par un softmax de leurs coûts :

```metal
float w = exp(-(cost[k] - best) / sigma);           // poids de chaque hypothèse
mixed  += w * 0.5 * (prev.sample(s, p) + cur.sample(s, c));
...
float trust = 1 - smoothstep(sure_lo, sure_hi, best);       // on croit la reconstruction ?
float alpha = smoothstep(far_lo, far_hi, distance(fx, mixed)) * trust;  // MetalFX s'en écarte ?
out = mix(fx, mixed, alpha);
```

MetalFX est remplacé seulement quand deux conditions sont réunies : on a une hypothèse fiable, et MetalFX s'en écarte nettement. C'est typiquement un bord dédoublé ou un HUD traîné.

Deux détails ont compté pour le coût :
- **Les coûts sont calculés sur la luminance d'analyse**, environ 960 px de large en 1080p, et seul le mélange des couleurs se fait en pleine résolution. Le surcoût passe d'environ 2,2 ms à environ 1,2 ms en 1080p.
- **Une sortie anticipée** garde le pixel de MetalFX dès qu'aucun candidat n'est fiable.

S'y ajoute un **masque de stabilité** : un pixel strictement identique depuis 4 images réelles est copié depuis la dernière. C'est un HUD protégé sans image sans HUD.

| Scène 3D, mouvement estimé | 72 fps 2x2% | 40 fps 2x2% |
|---|---:|---:|
| MetalFX seul | 8,45 | 21,50 |
| MetalFX, réparation et masque | **3,87** | **8,90** |

Les fantômes sont divisés par deux à 40 fps. Avec la réparation, notre mouvement estimé fait mieux que MetalFX nourri du vrai mouvement sans réparation (6,52 et 19,31).

## 5. Ce qui coûte vraiment sur le GPU

Lossless Scaling a la réputation d'être léger. Sa propre interface explique une partie de l'astuce : le flux est estimé à résolution réduite (son réglage « flow scale »), et l'image est reconstruite en pleine résolution par une synthèse simple.

Chez moi, en 1080p, la décomposition était :

| Étape | Coût GPU |
|---|---:|
| Capture et mouvement aller | environ 3 ms |
| Vérification retour (une 2e recherche complète) | environ 1,7 ms |
| **MetalFX en pleine résolution** | **environ 4 ms** |
| Réparation et HUD | environ 1,3 ms |

MetalFX était le poste le plus cher. Je le fais donc tourner en demi-résolution dès 1280 px de large, en laissant la réparation en pleine résolution rattraper les détails.

| | 72 fps 2x2% | 40 fps 2x2% | GPU 1080p |
|---|---:|---:|---:|
| MetalFX pleine résolution | 3,87 | 8,90 | 9,4 ms |
| MetalFX demi-résolution | 3,92 | 8,37 | **6,4 ms** |

On gagne 3 ms sans perte de qualité, et même un léger gain à 40 fps.

## 6. Le pacing : un test qui ne pouvait pas passer

Le présentateur chaîne ses présentations avec `presentDrawable:afterMinimumDuration:`. Chaque délai est arrondi au rafraîchissement, et la dette d'arrondi est reportée sur l'image suivante. Le test d'origine exigeait un écart type des intervalles inférieur à une demi-période de rafraîchissement.

Or, sur un écran à fréquence fixe, une période de sortie de `n + f` rafraîchissements impose un plancher :

```text
σ_min = refresh · √(f · (1 − f))
40 → 80 fps à 144 Hz : 12,5 ms = 1,8 refresh  →  σ_min = 6,94 · √(0,8 · 0,2) = 2,78 ms
40 → 80 fps à 120 Hz : 1,5 refresh            →  σ_min = refresh / 2 exactement
```

Le test était donc impossible à réussir par construction. Je l'ai remplacé par une comparaison honnête : le même jeu de test présentant **lui-même** 80 fps, sur le même écran.

| 144 Hz, intervalles de 3 refreshes ou plus | par seconde |
|---|---:|
| Jeu natif à 80 fps | 4,8 à 7,8 |
| Notre génération de 40 à 80 fps | **1,4 à 2,4** |

Le compositeur de macOS rate des rafraîchissements, même pour un jeu natif. Notre pacing fait déjà mieux. Les à-coups restants venaient d'un réglage `aim = 0.97` : la sortie tournait 3 % plus vite que le jeu pour ne jamais le freiner, et se vidait environ trois fois par seconde. `aim` suit maintenant la latence mesurée des images réelles, tenue à une demi-période plus 1 ms.

Une impasse instructive : une horloge absolue avec `presentDrawable:atTime:`. En mode fenêtré, quand les deux présentations partagent un command buffer, le compositeur jette systématiquement l'image générée. Même corrigée, elle faisait 190 à 208 à-coups en 20 s, contre 57 en mode chaîné.

## 7. Quand le jeu donne ses vecteurs

Certains jeux fournissent leurs vecteurs de mouvement à leur upscaler (DLSS, FSR, XeSS). Sous DXMT avec `DXMT_ENABLE_NVEXT=1`, un appel DLSS devient, dans le même processus, un `MTLFXTemporalScaler` de MetalFX. On peut donc l'observer avec l'API publique.

La bibliothèque swizzle `newTemporalScalerWithDevice:`, puis `encodeToCommandBuffer:` sur la classe concrète renvoyée (ici `_MFXTemporalScalingEffectV4`). Elle copie la texture de mouvement **dans le command buffer du jeu**, en alternant entre deux textures. La copie utilisable est celle dont le command buffer du jeu est terminé.

Je n'ai pas de jeu DLSS. Ma scène D3D11 a donc un mode `dlss` : elle rend en deux tiers de la résolution, produit sa profondeur et ses vecteurs, et appelle `NVSDK_NGX_D3D11_*` dans le `nvngx.dll` de DXMT. Le chemin complet est ainsi testé sans NVIDIA.

| Scène 3D, avec réparation | 72 fps 2x2% | 40 fps 2x2% |
|---|---:|---:|
| Mouvement estimé | 3,92 | 8,37 |
| **Vecteurs du jeu** | **1,73** | **3,03** |

Avec les données du jeu, le ghosting est divisé par trois à 40 fps.

Une règle juridique : la licence du Game Porting Toolkit interdit de désassembler D3DMetal. Je n'observe donc que mes propres appels à l'API publique MetalFX, dans le processus du jeu. Je ne lis jamais le binaire.

## 8. Le Neural Engine

NVIDIA fait tourner ses réseaux sur les Tensor Cores. Apple Silicon a un accélérateur dédié, le Neural Engine (ANE), qui reste inactif pendant qu'on joue. Ce qui coûte le plus de GPU après MetalFX, c'est le mouvement. Pourquoi ne pas le calculer sur l'ANE ?

### Rosetta, l'obstacle

Premier test : `MLAllComputeDevices()` liste bien le Neural Engine dans un processus x86_64. Mais à l'exécution, Core ML se rabat sur le CPU :

| Réseau de la taille de RIFE-lite, 480×272 | CPU | GPU | ANE |
|---|---:|---:|---:|
| Processus arm64 | 5,29 ms | 3,53 ms | **1,28 ms** |
| Processus x86_64 (Rosetta) | 77,6 ms | 3,77 ms | 77,4 ms (repli CPU) |

Même constat pour `VTOpticalFlow` et le flux optique de Vision : refusés sous Rosetta. Le jeu étant x86_64, le réseau doit tourner **ailleurs**.

### Un réseau, et une version allégée

J'utilise Practical-RIFE 4.25.lite, dont le code et les poids sont déclarés sous licence MIT par leur auteur. Pour la conversion Core ML, j'ai réécrit le passage avant avec des tailles fixes et une grille de warp constante, sinon le tracé bute sur l'arithmétique de formes.

`MLComputePlan` confirme que les 293 opérations tournent sur l'ANE, `grid_sample` compris. Pourtant, une paire en 512×256 coûtait **9,8 ms**, plus que sur le GPU. Le coupable n'est pas le réseau : ce sont les warps et le dernier bloc, tous en pleine résolution d'entrée.

La version « lean » déforme les entrées **à la résolution de chaque bloc** et retire le dernier bloc pleine taille :

| 512×256, RIFE 4.25.lite | GPU (Core ML) | ANE |
|---|---:|---:|
| Complet | 6,80 ms | 9,78 ms |
| **Lean** | 3,44 ms | **2,06 ms** |
| Lean, entrées et sorties IOSurface sans copie | — | **2,10 ms** |

Les entrées sont des `CVPixelBuffer` en `OneComponent16Half` adossés à des IOSurface : trois plans RGB empilés en hauteur, lus par `MLMultiArray initWithPixelBuffer:shape:`. Les sorties sont écrites directement dans nos surfaces grâce à `MLPredictionOptions.outputBackings`. Aucune copie.

### Un assistant arm64

```text
jeu (Wine, x86_64)                               framegen-ane (arm64)
  image N ─► GPU : 512×256 FP16 ─► IOSurface ─┐
                                              ├─ réveil ─► Core ML sur l'ANE
  IOSurface flux ◄────────── réveil ──────────┘            flux t→0, t→1 et masque
  ─► GPU : flux → mouvement MetalFX ─► MetalFX ─► réparation ─► présentation
```

- **Lancement :** la bibliothèque lance l'assistant avec `posix_spawn`, avec un environnement **propre**. Sinon, il hériterait de `DYLD_INSERT_LIBRARIES` et de la bibliothèque x86_64.
- **Rendez-vous :** sur un service Mach par processus. `bootstrap_check_in` fonctionne sans launchd pour un nom créé à la volée.
- **Les surfaces :** elles passent dans un message Mach complexe, sous forme de ports `IOSurfaceCreateMachPort`.
- **La synchronisation :** une page `shm_open` et `os_sync_wait_on_address` en mode `SHARED`, entre un processus Rosetta et un processus natif.

| Aller-retour jeu ↔ assistant | p50 | p95 |
|---|---:|---:|
| Échange seul | 0,04 ms | 0,51 ms |
| RIFE, requêtes enchaînées | 1,96 ms | 2,18 ms |
| RIFE, en cadence de jeu (une requête toutes les 25 ms) | 3,4 ms | 4,8 ms |

Le surcoût en cadence réelle (environ 1,4 ms) résiste au préchauffage, à la QoS user-interactive et à l'attente active. Il vient de l'ANE lui-même, qui redémarre après une pause. À côté d'un jeu qui sature complètement le GPU et la mémoire, le p95 monte à 14 ms. La bibliothèque attend donc au plus 6 ms. Au-delà, cette image-là utilise le flux GPU.

### Des flux de RIFE au mouvement de MetalFX

RIFE donne deux flux **depuis l'image du milieu** : vers l'image précédente (`F₀`) et vers la courante (`F₁`). MetalFX attend, **pour chaque pixel de l'image courante**, le vecteur vers sa position dans la précédente. Le point du milieu qui tombe sur le pixel courant `c` est à peu près `c − F₁(c)`. On y relit les deux flux :

```metal
float2 later = ane_flows(flow, q / size, 2) * scale;     // F1 au pixel courant
float2 uv    = (q - later) / size;                        // le point du milieu correspondant
float2 v     = ane_flows(flow, uv, 0) - ane_flows(flow, uv, 2);   // F0 − F1 = courant → précédent
motion.write(half4(half2(v * scale), 0, 0), gid);
```

### Résultats

| Scène 3D, 2x2% | 72 fps | 40 fps |
|---|---:|---:|
| Flux GPU, MetalFX, réparation | 3,92 | 8,37 |
| RIFE seul (sa propre synthèse) | 6,52 | 9,30 |
| **Flux RIFE sur l'ANE, MetalFX, réparation** | **3,53** | **7,06** |

| Scène D3D11 en 720p, DXMT | Sans ANE | Avec ANE |
|---|---:|---:|
| Images servies par l'ANE | — | 100 % (3,1 ms) |
| GPU de la bibliothèque par image générée | 4,8 ms | **3,7 ms** |
| Latence affichée | 15,6 ms | 20,7 ms |

Le flux sur l'ANE est meilleur **et** libère le GPU. En échange, il ajoute quelques millisecondes de latence : c'est acceptable à 40 → 80 fps, plus juste à 60 → 120 fps.

## 9. Ce que font les autres

| | Où tourne le réseau | Accès au jeu | Sur Mac |
|---|---|---|---|
| DLSS 3 et 4 | Tensor Cores | Données du moteur | Non |
| Lossless Scaling | GPU | Capture d'écran | Non |
| DraFG (Draske) | GPU (CUDA, Vulkan, Metal), modèle de 206 K paramètres | Capture d'écran | Oui, via ScreenCaptureKit |
| uncapped | API ML d'Apple (VideoToolbox, Vision) | Carte d'acquisition | Oui, application native |
| **Cartouche** | **ANE** pour le flux ; GPU pour MetalFX et la réparation | **Dans le processus**, et vecteurs du jeu si disponibles | Oui, jeux Wine |

Je n'ai trouvé aucun frame gen de jeu publié qui fasse tourner son réseau sur un NPU. Mesurées dans les mêmes conditions (512×256, arm64), les API ML publiques d'Apple sont nettement plus lentes que RIFE lean sur l'ANE :
- `VTOpticalFlow` : 9,7 ms ;
- Vision, précision basse : 20,8 ms ;
- RIFE lean sur l'ANE : 2,1 ms.

## 10. Ce que j'en retiens

1. **Mesurer avant d'optimiser.** La profondeur, que je croyais centrale, ne compte pas. Le coût de MetalFX, que je croyais faible, était le premier poste. Un test de pacing « raisonnable » était mathématiquement impossible.
2. **Corriger la sortie plutôt que tout réinventer.** Une passe à six hypothèses après MetalFX divise le ghosting par deux pour environ 1 ms.
3. **Comparer à la bonne référence.** Le jeu natif au même débit, pas un idéal théorique.
4. **Sous Rosetta, l'ANE impose un détour par un processus natif.** Avec les IOSurface et un réveil en mémoire partagée, ce détour coûte 0,04 ms.
5. **La latence est le vrai sujet.** Le calcul sur l'ANE prend 2 ms. Le reste vient du redémarrage de l'ANE et de la contention avec un GPU saturé.

## La suite

- Un réseau entraîné par Cartouche, beaucoup plus petit (DraFG montre que 200 K paramètres suffisent), appris par imitation de RIFE sur nos propres scènes de synthèse. L'entraînement se fait la nuit sur le M4, sans GPU cloud. Il doit donner moins de latence et une licence entièrement propre.
- Des rapports de vrais jeux, D3DMetal avec DLSS compris, avant de sortir la fonction de l'expérimental.
- L'intégration dans l'application : livrer l'assistant, choisir l'activation par défaut.

*Cartouche est gratuit et open source. Les décisions détaillées sont dans les ADR 0038 à 0044 du dépôt, et la référence technique dans `docs/FRAME-GENERATION.md`.*

---

### Notes et licences

- **MetalFX, Core ML, IOSurface, VideoToolbox et Vision** sont des API publiques d'Apple.
- **Practical-RIFE** (hzwer) : code sous licence MIT, poids déclarés « sous la même licence MIT » par le projet. Ses données d'entraînement ne sont pas documentées.
- **AMD FidelityFX SDK** (MIT) a servi de lecture et de banc de test (sample FSR). Aucun code n'en est dérivé à ce jour.
- **DXMT** (MIT jusqu'à la v0.80) : seule l'interface de son shim NGX a été lue.
- **D3DMetal** n'a jamais été désassemblé ni modifié.
- Les principes génériques cités sur les frame gen commerciaux (flux en résolution réduite, synthèse légère, hypothèses pondérées) viennent de leur documentation publique et de la littérature. Aucun code, poids ni shader tiers propriétaire n'est utilisé.
