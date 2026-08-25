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

- [Stratégie](#stratégie)
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

## Stratégie

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
tranche d'efficience et par tranche d'ADX, signale les groupes à espérance
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
| `QueuBreakoutEA_XAUUSD_H1.set` | XAUUSD H1 | Session 07h–20h, stops 2 ATR, marge de cassure 0,10 ATR, ER ≥ 0,30, risque 0,5 % |
| `QueuBreakoutEA_BTCUSD_H1.set` | BTCUSD H1 | 24/7 sauf week-end, tendance en H4, stops 2,5 ATR, marge 0,15 ATR, ER ≥ 0,35, risque 0,35 % |

Les écarts ne sont pas cosmétiques :

- **Stops et marge de cassure plus larges sur BTC** — le bruit intra-bougie
  déclenche un stop à 2 ATR nettement plus souvent, et produit davantage de
  fausses cassures.
- **Tendance en H4 sur BTC** — le H1 change de régime trop souvent.
- **Week-end exclu sur BTC** — le marché est ouvert, mais la liquidité du
  week-end élargit les spreads et fabrique des cassures qui ne tiennent pas.
- **Session restreinte sur l'or** — les cassures hors Londres/New York ont peu
  de volume derrière elles.
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
