# Queu — QueuBreakoutEA

Expert Advisor MQL5 (MetaTrader 5) pour instruments à forte amplitude :
**XAUUSD (or)** et **BTCUSD**, avec l'outillage quantitatif nécessaire pour
décider s'il a réellement un edge.

> **Aucune performance n'est promise ni garantie.** Ce dépôt ne contient pas une
> machine à profits : il contient une stratégie et, surtout, de quoi la
> **mesurer honnêtement**. La partie qui a le plus d'effet sur le rendement réel
> n'est pas la logique d'entrée — c'est le critère d'optimisation et le journal
> d'analyse, parce que ce sont eux qui vous empêchent de mettre en production un
> jeu de paramètres sur-appris.

---

## Sommaire

- [Deux moteurs d'entrée](#deux-moteurs-dentrée)
- [Moteur 1 — cassure de canal](#moteur-1--cassure-de-canal)
- [Moteur 2 — chaîne de régressions linéaires](#moteur-2--chaîne-de-régressions-linéaires)
- [Moteur 3 — retour à la moyenne multi-horizon](#moteur-3--retour-à-la-moyenne-multi-horizon)
- [Moteur 4 — retournement sur épuisement](#moteur-4--retournement-sur-épuisement)
- [Ce qui améliore réellement le rendement](#ce-qui-améliore-réellement-le-rendement)
  - [1. Le critère d'optimisation (levier principal)](#1-le-critère-doptimisation-levier-principal)
  - [2. Le sizing adaptatif](#2-le-sizing-adaptatif)
  - [3. La qualité du signal](#3-la-qualité-du-signal)
  - [4. La mesure](#4-la-mesure)
- [Installation](#installation)
- [Protocole d'optimisation en deux passes](#protocole-doptimisation-en-deux-passes)
- [Presets](#presets)
- [Garde-fous de risque](#garde-fous-de-risque)
- [Notes d'exploitation](#notes-dexploitation)

---

## Deux moteurs d'entrée

`InpEngine` choisit la condition d'entrée. **Les deux moteurs partagent
intégralement** la gestion du risque, les garde-fous, le journal et le critère
d'optimisation — seule la condition d'entrée diffère.

| Moteur | Achète… | Stop indexé sur |
|---|---|---|
| `QUEU_ENGINE_BREAKOUT` | la **cassure** du canal Donchian | ATR |
| `QUEU_ENGINE_REGRESSION` | le **repli** dans une tendance établie | σ des résidus |
| `QUEU_ENGINE_BOTH` | les deux, premier signal servi | selon le moteur |
| `QUEU_ENGINE_MEANREV` | le **bas du canal** rapide, dans le sens des horizons lents | dev du canal |
| `QUEU_ENGINE_REVERSAL` | le **rebond** sur la bande rapide, contre des horizons lents **épuisés** | dev du canal |

Ce ne sont pas deux variantes du même signal : l'un entre quand le prix
s'échappe, l'autre quand il revient. **Ils ne se déclenchent pas aux mêmes
moments**, ce qui les rend combinables — et comparables, puisque le journal
enregistre le contexte de régression même pour les trades de cassure. Tu peux
donc demander après coup : *les cassures rendent-elles mieux quand la tendance
de fond est nette ?*

---

## Moteur 1 — cassure de canal

Cassure de volatilité (*volatility breakout*) : le schéma qui correspond au
comportement de l'or et du BTC, faits de longues compressions suivies
d'expansions directionnelles rapides.

**Entrée**, évaluée uniquement à la clôture d'une bougie :

1. La clôture précédente dépasse un **canal Donchian** (calculé sur les bougies
   *antérieures* à celle qui casse) d'une marge de `InpBreakoutATR × ATR`. La
   marge écarte les cassures marginales, qui sont majoritairement du bruit.
2. **Filtre de tendance** EMA, optionnellement sur une timeframe supérieure.
3. **Filtre ADX** : le marché doit être en expansion.
4. **Filtre de ratio d'efficience** (voir plus bas).
5. **Filtres de coût** : spread absolu et/ou spread rapporté à l'ATR.

**Sortie** — tout est indexé sur l'ATR :

| Mécanisme | Rôle | Défaut |
|---|---|---|
| Stop loss `InpSL_ATR` | Perte maximale. **Obligatoire** : l'EA refuse de démarrer sans. | 2.0 ATR |
| Break-even `InpBE_ATR` | Sécurise dès que le gain couvre X ATR. | 1.0 ATR |
| Trailing `InpTrail_ATR` | Suit le marché, ne recule jamais. | 2.0 ATR |
| TP partiel `InpPartial_R` | Clôture une fraction à un multiple de R. | **désactivé** |

Le take profit fixe est désactivé par défaut : sur une stratégie de cassure,
un TP coupe précisément les trades longs qui font la rentabilité de l'approche.
Le TP partiel est également désactivé par défaut — il **réduit la variance mais
aussi l'espérance**. À activer seulement si le journal montre que les gains
latents sont mal capturés.

---

## Moteur 2 — chaîne de régressions linéaires

### Pourquoi une régression plutôt qu'un canal

Le Donchian dit **où** le prix est allé, mais rien sur la **qualité du chemin**.
Une régression OLS sur les clôtures donne trois informations d'un seul calcul :

| Sortie | Interprétation |
|---|---|
| **pente** β | direction et vitesse du régime |
| **R²** | quelle fraction du mouvement est linéaire plutôt que du bruit |
| **σ** des résidus | volatilité **autour de la tendance**, pas amplitude absolue du prix |

Le R² est le cousin statistiquement fondé du ratio d'efficience. Et σ donne une
unité de stop plus fine que l'ATR : elle mesure l'écart **à la droite**, donc un
stop à 2,5 σ est serré dans une tendance propre et large dans une tendance
chahutée — automatiquement, sans paramètre supplémentaire.

### La chaîne

Quatre régressions emboîtées sur une échelle géométrique **N, 2N, 4N, 8N**,
toutes se terminant sur la même bougie. Chaque pente est normalisée :

```
slopeATR = β × N / ATR        →  « ATR parcourus par fenêtre »
```

Cette normalisation n'est pas cosmétique. Pour une même tendance relative, la
pente brute de l'or vaut 0,40 et celle du BTC 12,00 — un facteur 30. Une fois
normalisées, **les deux valent exactement 3,200**. C'est ce qui rend un seuil
unique utilisable sur les deux instruments.

### La logique d'entrée

1. **Régime** = accord des signes de pente sur les échelons **longs**
   (`InpReg_RegimeFrom=1` → 2N, 4N, 8N). L'échelon court est exclu à dessein :
   pendant un repli sa pente s'inverse alors que le régime de fond tient
   toujours — et c'est précisément ce repli qu'on cherche à acheter.
2. **Qualité** : R² de l'échelon long ≥ `InpReg_MinR2`, et pente normalisée
   ≥ `InpReg_MinSlopeATR`.
3. **Timing** : le prix doit être retombé sous la droite courte d'au moins
   `InpReg_EntrySigma × σ`.
4. **Garde-fou de structure** : le prix doit rester du bon côté de la droite
   longue (`InpReg_RequireAboveLong`). Sinon ce n'est plus un repli, c'est une
   cassure de tendance en cours.
5. **Stop** placé à `InpReg_StopSigma × σ` de la droite courte. Si le repli est
   déjà plus profond que ce niveau, **le setup est invalidé** : il ne reste plus
   de place entre l'entrée et l'invalidation. Ce garde-fou découle de la
   géométrie, il n'a pas de paramètre.

`InpReg_StopSigma` doit dépasser `InpReg_EntrySigma`, sinon le stop est atteint
dès l'entrée — l'EA refuse de démarrer dans ce cas.

### Sortie sur rupture de régime

`InpReg_ExitOnBreak` ferme la position quand les pentes cessent de s'accorder.
**Seul le désaccord de signe déclenche la sortie, pas la baisse de qualité** :
réappliquer les seuils d'entrée ferait sortir bien trop tôt, un R² se dégradant
naturellement à chaque respiration du marché.

### Ce que ce moteur n'applique pas

Les filtres EMA / ADX / efficience sont **ignorés** en mode régression : la
chaîne fait déjà ce travail, avec ses seuils de R² et de pente. Les empiler
serait redondant et sur-filtrerait. Les filtres de **coût** (spread, ATR
minimum) et tous les garde-fous de risque restent actifs.

### Rapport avec le « Linear Regression Channel » de LonesomeTheBlue

L'indicateur Pine bien connu de TradingView calcule la même droite. Vérification
faite ligne par ligne :

- **Pente et intercept : OLS exact, identiques aux miens.** Sa formule
  `mid − slope·floor(len/2) + ((1−len%2)/2)·slope` se réduit exactement à
  `mid − slope·(len−1)/2` — le correctif de parité gère simplement les longueurs
  paires et impaires. Écart mesuré : 1,4 × 10⁻¹⁶.
- **La dispersion diffère.** Sa boucle prédit `slope·(len−x) + intercept` pour la
  bougie `x`, alors que la droite y vaut `intercept + slope·(len−1−x)`. Chaque
  résidu est donc décalé de exactement `−slope`, ce qui donne l'identité
  (vérifiée numériquement à 3 × 10⁻¹⁴) :

```
dev_Pine = √(SSres/n + pente²)      au lieu de      σ = √(SSres/(n−2))
```

Conséquence concrète :

| Série | `dev` Pine | Dispersion réelle | Écart |
|---|---|---|---|
| Bruit fort, pente faible | 3,141 | 3,141 | négligeable |
| Bruit faible, **pente forte** | 1,557 | 0,414 | **× 3,8** |
| **Droite parfaite** | 2,000 | **0,000** | le canal ne se referme jamais |

La largeur du canal se trouve mélangée à la pente. Ce n'est pas nécessairement
à « corriger » — ça évite les canaux dégénérés de largeur nulle — mais ce n'est
pas une mesure de dispersion. `InpReg_DevMode` laisse le choix :

| Mode | Formule | Usage |
|---|---|---|
| `QREG_DEV_STDERR` (défaut) | √(SSres/(n−2)) | trading — estimateur standard |
| `QREG_DEV_POP` | √(SSres/n) | écart-type de population |
| `QREG_DEV_PINE` | √(SSres/n + pente²) | **parité visuelle** avec TradingView |

Le preset `QueuRegression_XAUUSD_PineParity.set` active le mode PINE avec
`InpReg_BasePeriod=25` (échelons 25/50/**100**/200 — 100 est la longueur par
défaut de l'indicateur) et `InpReg_ChannelMult=2.0` (son `devlen`). Utilise-le
pour comparer l'EA à ce que tu vois sur ton graphique ; pour trader, reste en
mode erreur-type.

### La contradiction apparente sur `outofchannel`, et sa résolution

L'indicateur signale une **rupture** quand le prix sort du canal par le bas en
tendance haussière. C'est exactement ma condition d'**entrée**. Contradiction ?
Non — différence d'échelle, et c'est le cœur de l'intérêt d'une chaîne :

| Situation | Lecture |
|---|---|
| Prix sous le canal **court**, échelons longs toujours d'accord | **respiration** → on achète |
| Prix sort du canal **long** (`InpReg_ExitOnChannel`) | **vraie rupture** → on sort |

Un indicateur à canal unique ne peut pas faire cette distinction : il n'a qu'une
échelle. C'est précisément ce que la chaîne apporte. L'EA transpose donc son
`outofchannel` fidèlement, mais l'applique à l'échelon **long** comme condition
de sortie, `InpReg_ChannelMult` jouant le rôle de son `devlen`.

### Validation

Les formules OLS ont été vérifiées contre une implémentation de référence à
résidus explicites : **erreur relative maximale 7,8 × 10⁻¹⁴** sur six jeux de
données (tendance pure, tendance bruitée, série plate, baissière, échelle BTC,
échelle or). L'identité de forme fermée `Sxx = n(n²−1)/12` est exacte jusqu'à
n = 321, et les cas limites (série constante, droite parfaite) ne produisent ni
division par zéro ni R² hors de [0, 1].

---

## Moteur 3 — retour à la moyenne multi-horizon

Acheter le bas du canal M1 / vendre le haut, mais **uniquement dans le sens des
horizons lents** (M3, M5). Contre-tendance sur le bruit, dans le sens du régime.

### D'abord le coût, parce qu'à M1 c'est lui qui décide

Avant toute question de signal, il y a une contrainte purement arithmétique.
En notant `r = coût / dev` (spread + commissions rapportés à **une déviation du
canal**), avec une entrée à `D` dev sous la droite, un stop à `S` dev et une
cible à `T` dev au-delà de la droite :

```
gain net    = (D + T)·dev − coût
perte nette = (S − D)·dev + coût
p*          = perte / (gain + perte)
```

`tools/meanrev_breakeven.py` tabule ça. Le coût maximal absorbable pour rester
sous 60 % de taux de réussite requis :

| Géométrie | coût/dev max |
|---|---|
| D=1,5 · S=2,5 · cible sur la droite | 0,50 |
| D=2,0 · S=3,0 · cible sur la droite | 0,80 |
| D=2,0 · S=2,5 · cible sur la droite | 1,00 |
| **D=2,0 · S=3,0 · cible +1 dev** | **1,40** |

Trois enseignements, par ordre d'importance :

1. **Viser au-delà de la droite est le plus gros levier** — 0,80 → 1,40, presque
   le double de coût absorbable. C'est pourquoi `InpMR_TargetDev` vaut 0,5 par
   défaut et non 0.
2. **Entrer profond compte plus qu'entrer tôt** — à 1,5 dev la tolérance tombe à
   0,50. Une entrée précoce attrape plus de signaux mais paie proportionnellement
   bien plus cher.
3. **Le stop serré aide autant que l'entrée profonde**, à condition qu'il ne se
   fasse pas balayer — ce que ce calcul ne dit pas : il fixe le seuil, pas la
   fréquence.

L'EA calcule `p*` **en direct** à partir du spread courant et de la largeur du
canal, et refuse le trade si `p*` dépasse `InpMR_MaxBreakeven`. C'est le filtre
de coût qui compte à cette échelle — et c'est pourquoi les presets M1
**désactivent** `InpMaxSpreadATRRatio` : à M1 l'ATR est trop petit pour que ce
ratio ait un sens.

### Les cinq modes de confirmation

`InpMR_Confirm` — c'est **la** question ouverte de ce setup, donc c'est un
paramètre à optimiser (valeurs 0 à 4), pas à choisir d'avance.

| Mode | Règle | Arbitrage |
|---|---|---|
| `SIGN` (0) | Les deux pentes lentes de même signe | Le plus permissif. Ton idée littérale. Un régime quasi plat passe le filtre. |
| `SIGN_R2` (1) | + R² minimal sur **chaque** horizon | Écarte les régimes lents mal définis. **Défaut.** |
| `VOTE` (2) | Score `Σ signe·R²`, seuil sur \|score\| | Tolère un désaccord si l'horizon dissident est de mauvaise qualité. Plus de signaux. |
| `POSITION` (3) | + le prix doit être dans la moitié basse du canal lent (pour un achat) | Évite d'acheter un repli qui part du **haut** du canal lent, où il reste peu de place avant la bande opposée. |
| `SLOPE` (4) | + pente normalisée minimale (ATR/fenêtre) | Un signe de pente ne dit rien de l'amplitude. Le plus sélectif. |

Deux choix **orthogonaux**, testables indépendamment :

- **`InpMR_RequireOpposite`** — exiger que le canal rapide soit de couleur
  opposée (rouge dans un M3/M5 vert). C'est ta formulation exacte. La désactiver
  donne un setup plus simple : « touche de bande basse dans une tendance
  haussière », sans exiger que le repli soit déjà installé. Plus de signaux,
  potentiellement plus tôt — à mesurer.
- **`InpMR_UseNested`** — remplacer les deux timeframes par deux **longueurs**
  sur la TF de travail. Une régression de 50 bougies en M5 et une de 250 bougies
  en M1 couvrent toutes deux **250 minutes** : les deux modes visent le même
  horizon. La différence est la matière — le M5 agrège en OHLC (moins de bruit,
  moins de points), le M1 garde toutes les clôtures (statistique plus fine, bruit
  plus présent). Aucun n'est supérieur *a priori*, mais le mode imbriqué évite
  les questions de synchronisation de barres entre timeframes.

### Sorties

La cible est **fixe** (`mid + T·dev`). Trailing et break-even sont désactivés
dans les presets M1 : déplacer le stop rogne le gain sans rallonger la cible.
L'EA émet un avertissement au démarrage s'ils sont laissés actifs.

---

## Moteur 4 — retournement sur épuisement

Les moteurs 3 et 4 se ressemblent de loin — tous deux entrent sur une bande du
canal rapide — mais leurs prémisses sont **opposées**. Ne pas les confondre :

| | Moteur 3 `MEANREV` | Moteur 4 `REVERSAL` |
|---|---|---|
| Horizons lents (M3/M5) | **verts**, d'accord avec le trade | **rouges**, en désaccord |
| Prix dans le canal lent | partie **basse** | partie **haute**, voire **sorti** |
| Canal rapide (M1) | **rouge** — le repli est en cours | **vert** — a déjà basculé |
| Nature | continuation | **contre-tendance sur épuisement** |

La thèse du moteur 4 : *la baisse de fond n'arrive plus à faire baisser le prix.
Il stagne en haut de son canal descendant, ou en est sorti. Le M1 a déjà tourné.
J'achète le premier repli plutôt que la pleine impulsion.*

### La séquence, pour un achat

1. **Canal rapide vert** — c'est lui qui donne la direction candidate.
2. **Les deux horizons lents rouges** — obligatoire, sans exception.
3. **Qualité minimale des lents** (`InpRV_MinSlowR2`) — sans un R² plancher, le
   signe de la pente est du bruit et parler de canal « rouge » n'a aucun sens.
4. **Épuisement** sur au moins `InpRV_ExhaustRequire` horizon(s) — voir ci-dessous.
5. **Rebond confirmé** sur la bande basse du canal M1 : le prix doit avoir
   **percé** la bande dans les `InpRV_BounceBars` dernières bougies, puis être
   **revenu au-dessus**. Une simple touche ne suffit pas — c'est ce que veut dire
   « rebond ».
6. **Filtre de coût** : `p*` calculé en direct, refus au-delà de
   `InpRV_MaxBreakeven`.

Symétrique pour la vente.

### Les deux définitions de l'épuisement — à départager

C'est **le** point à mesurer, et j'ai une opinion :

| Critère | Déclenchement | Signification |
|---|---|---|
| `InpRV_AcceptBreakout` | le prix **sort** du canal lent par le haut | rare, significatif |
| `InpRV_AcceptPosition` | le prix est au-dessus de `InpRV_SlowPosMin` **dans** le canal | fréquent, ambigu |

**Être haut dans un canal descendant est l'état normal de chaque respiration
d'une baisse saine.** Pris seul, ce critère se déclenchera en permanence et
produira surtout des shorts manqués retournés en achats. La sortie effective du
canal, elle, dit quelque chose : le prix a monté plus vite que la dérive
baissière ne descend.

Les presets activent les deux (ta spécification littérale), mais **le premier
A/B test à faire est `InpRV_AcceptPosition=false`**. Le journal tranchera : les
colonnes `reg_r2` et `reg_slope_atr` sont déjà enregistrées, et
`analyze_queu.py` les découpe en tranches.

### Variantes orthogonales

| Paramètre | Alternative |
|---|---|
| `InpRV_ExhaustRequire` | 1 = un seul horizon épuisé suffit · 2 = les deux |
| `InpRV_RequireBounce` | `false` = entrée dès la touche, sans confirmation |
| `InpRV_RequireFlatten` | `true` = exige en plus que la pente lente **ralentisse**, en comparant la régression courante à la même un demi-cycle plus tôt. Un vrai épuisement décélère avant de se retourner ; une respiration ordinaire laisse la pente de fond intacte. |
| `InpRV_UseNested` | remplace les deux timeframes par deux longueurs sur la TF de travail |

### Mise en garde

C'est un setup de **contre-tendance au niveau du régime**. Ce type de signal a
structurellement un taux de réussite plus faible qu'une continuation — le seuil
de rentabilité de la section précédente compte donc double ici. Les presets
partent à `InpRiskPercent=0.20` (or) et `0.15` (BTC), soit moins que tous les
autres moteurs, délibérément.

---

## Micro-scalping : ce que le flux d'un broker permet réellement

Avant toute stratégie à l'échelle de la minute, il faut savoir ce que le broker
publie. Sur un compte **CFD retail**, la réponse est sévère.

| Ce qu'une spec order-flow demande | API MT5 | Sur un CFD BTCUSD/XAUUSD |
|---|---|---|
| Delta (sens de l'agresseur) | `MqlTick.flags` → `TICK_FLAG_BUY/SELL` | Renseigné **uniquement** en bourse. En CFD : `BID`/`ASK` seulement — des cotations, pas des transactions |
| Volume réel échangé | `SYMBOL_VOLUME_REAL` | Généralement absent. Le `volume` des bougies est un **compte de ticks** |
| Low Volume Node | dérivé du volume réel | Sans volume réel, on profile l'activité de cotation |
| Carnet niveau 2 | `MarketBookAdd/Get` | Souvent vide ou synthétique |
| Réaction « milliseconde » | `OnTick` | Événementiel sur cotation ; le testeur ne le modélise pas |

**`MQL5/Scripts/Queu/QueuBrokerAudit.mq5` répond pour ton broker.** Script en
lecture seule, à lancer sur le graphique du symbole. Il recense les flags des
ticks, compare `tick_volume` et `real_volume`, teste le carnet, mesure la
distribution du spread et la cadence, puis rend un verdict couche par couche.

### L'arithmétique qui décide avant le signal

Pour un scalp de stop `S`, cible `k·S` et coût aller-retour `c`, en posant
`f = c/S` :

```
p* = (1 + f) / (k + 1)
```

`tools/scalp_breakeven.py` tabule ça :

| f ↓ · cible → | 0,8 R | 1,3 R | 1,8 R |
|---|---|---|---|
| 0,00 | 55,6 % | 43,5 % | 35,7 % |
| 0,20 | 66,7 % | 52,2 % | 42,9 % |
| 0,30 | **72,2 %** | 56,5 % | 46,4 % |
| 0,50 | 83,3 % | 65,2 % | 53,6 % |

**Un stop serré n'améliore rien** — il augmente `f`, donc `p*`. « TP rapide
0,8 R » et « SL serré » se combattent : à 0,8 R, dès que le coût atteint 30 %
de la distance de stop, il faut 72 % de réussite. Zone morte.

### Les proxys honnêtes

`MQL5/Include/Queu/Microstructure.mqh` maintient une bande glissante de ticks à
**coût constant** — pas d'appel à `CopyTicks` en boucle, pas de tri par tick.
Les noms disent ce qui est mesuré :

| Champ | Ce que c'est | Ce que ce **n'est pas** |
|---|---|---|
| `quotePressure` | règle du tick sur le mid, ∈ [−1,1] | **pas** le delta : direction des cotes, pas sens des agresseurs |
| `absorption` | pression orientée qui ne déplace pas le prix | **pas** l'absorption au sens carnet — inférence indirecte |
| `efficiency` | \|déplacement\| / chemin parcouru, au tick | — |
| `flicker` | taux d'inversions de sens | — |
| `toxicity` | **le pire** des composants, pas leur moyenne | un score de veto : une seule condition sévère doit suffire |

Le tampon circulaire a été porté en Python et validé contre un calcul en force
brute — ce qui a révélé un compteur d'inversions qui n'était jamais décrémenté
à l'expiration (1992 comptées au lieu de 16), saturant `toxicity` à 1,0 de façon
permanente. Corrigé et revérifié sur 41 points de contrôle.

---

## Ce qui améliore réellement le rendement

### 1. Le critère d'optimisation (levier principal)

MT5 propose par défaut le profit ou le facteur de récupération. **Optimiser sur
ces critères sélectionne presque systématiquement du sur-apprentissage** : ils
ignorent la taille de l'échantillon, la forme de la distribution, et le nombre
de jeux de paramètres essayés.

`OnTester()` retourne ici le **Deflated Sharpe Ratio** (Bailey & López de Prado,
2014) :

- Le **PSR** (*Probabilistic Sharpe Ratio*) est la probabilité que le vrai
  Sharpe dépasse un seuil, compte tenu du nombre d'observations, de l'asymétrie
  et de l'épaisseur des queues. Une stratégie « petits gains réguliers, grosse
  perte rare » est fortement dépréciée — c'est voulu.
- Le **DSR** mesure le PSR non pas contre zéro, mais contre le **Sharpe
  atteignable par pur hasard** quand on a essayé `T` jeux de paramètres.

Ordre de grandeur, avec un écart-type de Sharpe/trade de 0,5 entre passes :

| Passes d'optimisation | Sharpe/trade atteignable **sans aucun edge** |
|---|---|
| 2 | 0,26 |
| 10 | 0,79 |
| 100 | 1,27 |
| 1 000 | 1,63 |
| 10 000 | 1,93 |

Autrement dit : après 1 000 passes, un Sharpe par trade de 1,6 n'est **pas** une
découverte. Le profit brut ne vous le dira jamais.

Une passe est en outre rejetée d'office (`return 0`) si elle repose sur moins de
`InpTester_MinTrades` trades ou dépasse `InpTester_MaxDDPct` de drawdown.

Les fonctions `QNormCDF` et `QNormInv` de `Stats.mqh` ont été validées contre
une implémentation de référence : erreur maximale 7,0 × 10⁻⁸ et 5,0 × 10⁻⁹
respectivement, conformes aux tolérances théoriques des algorithmes employés
(Abramowitz & Stegun 26.2.17, et Acklam).

### 2. Le sizing adaptatif

> **Attention à un faux levier.** Le sizing est *déjà* neutre en volatilité :
> le stop vaut `k × ATR` et le lot vaut `risque / distance_stop`, donc le lot est
> déjà proportionnel à `1/ATR`. Ajouter un « vol targeting » par-dessus serait
> redondant. Deux mécanismes réellement additifs sont fournis.

**Throttle de drawdown** (`InpUseDDThrottle`, **activé par défaut**) — réduction
linéaire du risque entre `InpDD_ThrottleStart` et `InpDD_ThrottleFull` de
drawdown.

**Kelly fractionnaire** (`InpUseKelly`, **désactivé par défaut**) — estime
`f* = p − (1−p)/b` sur une fenêtre glissante de résultats en R. Dans ce montage,
`f*` est directement le pourcentage d'equity à risquer, puisqu'un trade perd
exactement le montant risqué quand le stop est touché : c'est l'hypothèse du pari
de Kelly. Le plein Kelly est inexploitable en pratique (`p` et `b` sont estimés,
et une surestimation mène à la ruine), d'où la fraction et les bornes dures.

**Pourquoi ces défauts.** Monte-Carlo, 600 trades, 600 tirages, risque de base
0,5 %, comparé au sizing fixe :

| Scénario | Throttle DD seul | Kelly seul |
|---|---|---|
| Edge solide (p=0,40, 2R) | médiane −1 %, **DD p95 14 %→12 %** | **médiane ×1,9**, DD p95 14 %→30 % |
| Edge mince (p=0,36, 2R) | ≈ neutre, **DD p95 22 %→15 %** | médiane +6 %, **p05 −18 %**, DD p95 39 % |
| Aucun edge (p=0,333) | **DD p95 33 %→18 %**, p05 +14 % | médiane −6 %, **p05 −12 %**, DD p95 41 % |
| Edge négatif (p=0,30) | **DD p95 48 %→23 %**, p05 +43 % | n'aide pas |

Lecture : **le throttle de drawdown est une assurance quasi gratuite** — il ne
coûte ~1 % de médiane que quand tout va bien, et améliore massivement le 5ᵉ
percentile quand ça va mal. **Kelly ne paie que si l'edge est réel et bien
estimé** ; avec un edge mince ou nul, il amplifie les pertes et double les
drawdowns.

**N'activez Kelly qu'après** avoir démontré un edge sur un échantillon suffisant
(le mode `trades` de l'outil d'analyse affiche le Kelly estimé et le nombre de
trades qui le soutient).

### 3. La qualité du signal

**Ratio d'efficience de Kaufman** (`InpUseERFilter`) :

```
ER = |variation nette sur n bougies| / somme des variations absolues
```

Borné dans [0, 1] : 1 = mouvement parfaitement directionnel, 0 = bruit pur. Il
mesure directement le rapport signal/bruit du chemin parcouru, là où l'ADX ne
mesure qu'une moyenne lissée qui réagit avec retard et sature en forte
volatilité. Les deux filtres sont complémentaires et activables séparément.

### 4. La mesure

**Journal de trades** (`InpWriteJournal`) — un CSV par symbole dans le dossier
commun des terminaux, contenant pour chaque trade le **contexte d'entrée**
(ATR, ratio d'efficience, ADX, spread, heure, jour) et le **résultat** en
multiples de R, avec MAE et MFE.

C'est ce fichier qui permet de répondre à la seule question qui compte : **où se
trouve réellement l'edge, et où paie-t-on pour rien.**

```bash
python3 tools/analyze_queu.py trades  Queu_Trades_XAUUSD_770101.csv
python3 tools/analyze_queu.py passes  Queu_Passes_XAUUSD.csv
```

Le mode `trades` produit l'espérance en R par direction, par heure, par jour, par
tranche d'efficience, par tranche d'ADX, et — quand le journal les contient —
par tranche de **R²** et de **pente normalisée**. Il signale les groupes à espérance
négative, et analyse les excursions (« la moitié du gain latent est-elle
rendue ? », « les perdants passaient-ils près de 1 R de gain ? »).

Le mode `passes` fournit les valeurs de déflation à réinjecter et distingue les
plateaux robustes des pics de sur-apprentissage — y compris le cas piégeux où la
meilleure passe repose sur un réglage dont la moyenne, *une fois cette passe
exclue*, est inférieure à la moyenne générale.

Aucune dépendance externe : bibliothèque standard Python uniquement.

---

## Installation

Copie l'arborescence dans le dossier de données MT5
(*Fichier → Ouvrir le dossier de données*) :

```
MQL5/Experts/Queu/QueuBreakoutEA.mq5
MQL5/Include/Queu/Utils.mqh
MQL5/Include/Queu/Risk.mqh
MQL5/Include/Queu/Stats.mqh
MQL5/Include/Queu/Regression.mqh
MQL5/Include/Queu/Journal.mqh
MQL5/Presets/*.set
```

Dans MetaEditor, ouvre `QueuBreakoutEA.mq5` et compile (**F7**).

---

## Protocole d'optimisation en deux passes

Le seuil de déflation dépend de l'écart-type des Sharpe **entre les passes**.
Cette valeur se **mesure**, elle ne se devine pas. D'où deux passes.

**Passe 1 — mesurer.**

1. `InpTester_Trials = 0` et `InpTester_TrialsSD = 0` (déflation désactivée ;
   le critère retombe sur le PSR contre zéro).
2. Lance l'optimisation. L'EA écrit un résumé par passe dans
   `Queu_Passes_<symbole>.csv` du dossier commun. La collecte passe par les
   *frames* MT5 : c'est le terminal principal qui écrit, pas les agents, ce qui
   évite que des dizaines de processus se disputent le fichier.
3. Analyse :

```bash
python3 tools/analyze_queu.py passes Queu_Passes_XAUUSD.csv
```

L'outil affiche les deux valeurs exactes à recopier.

**Passe 2 — sélectionner.**

4. Renseigne `InpTester_Trials` et `InpTester_TrialsSD` avec ces valeurs.
5. Relance l'optimisation. Le critère est désormais le DSR : les passes qui ne
   battent pas le seuil de hasard retournent une valeur nulle.
6. Si **aucune** passe ne survit à la déflation, c'est le résultat : ce jeu de
   paramètres n'a pas d'edge démontrable sur ces données. Élargir la période ou
   revoir la stratégie — ne pas passer en réel.

**Puis, dans tous les cas :**

7. **Walk-forward** : optimise sur une période, valide sur une autre. Un jeu de
   paramètres optimisé et validé sur la même période ne prouve rien.
8. **Ticks réels** dans le testeur. Tout autre mode surestime une stratégie à
   trailing stop.
9. **Vérifie le spread du test.** Le testeur utilise souvent un spread fixe
   irréaliste — c'est l'erreur qui rend rentables des stratégies qui ne le sont
   pas, surtout sur BTC.
10. **Forward test en démo**, plusieurs semaines, sur le broker que tu utiliseras.
11. **Réel à risque réduit** (`InpRiskPercent` à 0,1–0,25 pour commencer).

---

## Presets

| Fichier | Instrument | Particularités |
|---|---|---|
| `QueuBreakoutEA_XAUUSD_H1.set` | XAUUSD H1 | **Cassure.** Session 07h–20h, stops 2 ATR, marge 0,10 ATR, ER ≥ 0,30, risque 0,5 % |
| `QueuBreakoutEA_BTCUSD_H1.set` | BTCUSD H1 | **Cassure.** 24/7 sauf week-end, tendance H4, stops 2,5 ATR, marge 0,15 ATR, risque 0,35 % |
| `QueuRegression_XAUUSD_H1.set` | XAUUSD H1 | **Régression.** N=20, R² ≥ 0,35, repli 1,0 σ, stop 2,5 σ, magic 770103 |
| `QueuRegression_BTCUSD_H1.set` | BTCUSD H1 | **Régression.** N=24, R² ≥ 0,30, repli 1,2 σ, stop 3,0 σ, magic 770104 |
| `QueuRegression_XAUUSD_PineParity.set` | XAUUSD H1 | **Parité TradingView.** Mode PINE, échelons 25/50/100/200, `devlen`=2, magic 770105 |
| `QueuMeanRev_XAUUSD_M1.set` | XAUUSD **M1** | **Retour à la moyenne.** M3/M5, D=2 S=3 T=+0,5, `p*` max 60 %, magic 770106 |
| `QueuMeanRev_BTCUSD_M1.set` | BTCUSD **M1** | **Retour à la moyenne.** N=60, mêmes seuils, week-end exclu, magic 770107 |
| `QueuReversal_XAUUSD_M1.set` | XAUUSD **M1** | **Retournement.** M3/M5 épuisés, rebond confirmé, D=1 S=2 T=+1, magic 770108 |
| `QueuReversal_BTCUSD_M1.set` | BTCUSD **M1** | **Retournement.** N=60, risque 0,15 %, week-end exclu, magic 770109 |

Les magic numbers des presets de régression sont distincts : les deux moteurs
peuvent tourner **en parallèle** sur le même compte sans se marcher dessus.

Les écarts ne sont pas cosmétiques :

- **Stops et marge de cassure plus larges sur BTC** — le bruit intra-bougie
  déclenche un stop à 2 ATR nettement plus souvent, et produit davantage de
  fausses cassures.
- **Tendance en H4 sur BTC** — le H1 change de régime trop souvent.
- **Week-end exclu sur BTC** — le marché est ouvert, mais la liquidité du
  week-end élargit les spreads et fabrique des cassures qui ne tiennent pas.
- **Session restreinte sur l'or** — les cassures hors Londres/New York ont peu
  de volume derrière elles.
- **Repli plus profond et stop plus large sur BTC en régression** (1,2 σ / 3,0 σ
  contre 1,0 σ / 2,5 σ) — la dispersion du BTC autour de la droite a des queues
  plus épaisses ; un stop à 2,5 σ serait emporté par la simple respiration.
- **Filtre spread/ATR plutôt qu'en points absolus** — 400 points de spread est
  normal sur BTC et catastrophique sur l'or ; seul le ratio est comparable.

Ce sont des **points de départ**, pas des réglages validés : le `point`, le
spread et la taille de contrat varient beaucoup d'un broker à l'autre, ce qui
déplace tous les optima.

---

## Garde-fous de risque

- **Dimensionnement sur la distance de stop réelle**, après élargissement
  éventuel au `stops level` du broker.
- **Refus plutôt que dépassement** — si le volume calculé tombe sous le lot
  minimum, l'EA **saute le trade** et le journalise, au lieu d'ouvrir une
  position qui risque bien plus que demandé. Critique sur BTC.
  `InpForceMinLot=true` inverse ce choix, en le signalant.
- **Coupe-circuit journalier** en perte (`InpMaxDailyLossPct`) et en gain.
- **Pause après perte** (`InpCooldownBars`), déclenchée sur le R réalisé de la
  position complète — les clôtures partielles ne la déclenchent pas.
- **Vérification de marge** avant chaque envoi.
- **Distances de stop broker** (`stops level`, `freeze level`) respectées.

---

## Notes d'exploitation

- **Toutes les heures sont en heure serveur du broker.** Vérifie le décalage
  avant de régler la session.
- **Un magic number par instance** : `770101` (or), `770102` (BTC).
- Les entrées sont évaluées à la clôture des bougies ; la **gestion des stops et
  le suivi MAE/MFE tournent à chaque tick**, pour qu'une position ne reste jamais
  non protégée.
- Le **journal détaillé est automatiquement désactivé en optimisation** — des
  dizaines d'agents écriraient dans le même fichier.
- Le panneau de statut affiche l'ATR, le spread, le ratio d'efficience, le
  **risque qui sera appliqué au prochain trade**, l'état de l'estimation Kelly,
  et la **raison exacte** d'un refus d'ouverture.
