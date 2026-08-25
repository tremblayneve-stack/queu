# Queu — QueuBreakoutEA

Expert Advisor MQL5 (MetaTrader 5) conçu pour les instruments à forte amplitude :
**XAUUSD (or)** et **BTCUSD**.

> **Aucune performance n'est promise ni garantie.** Ce dépôt contient une
> stratégie *testable*, pas une machine à profits. La valeur vient du backtest,
> de l'optimisation walk-forward et du forward test en démo que tu feras
> ensuite. Ne passe jamais en réel un réglage qui n'a pas survécu à ces trois
> étapes.

---

## Stratégie

Cassure de volatilité (*volatility breakout*), le schéma qui exploite le mieux
le comportement de l'or et du BTC : de longues phases de compression suivies
d'expansions directionnelles rapides.

**Entrée** — à la clôture d'une bougie seulement (jamais en cours de bougie) :

1. La clôture de la bougie précédente dépasse le plus haut (ou casse le plus bas)
   d'un **canal Donchian** calculé sur les `InpChannelPeriod` bougies *antérieures*.
   Le canal exclut volontairement la bougie qui casse — sans ça la condition
   serait mathématiquement impossible à satisfaire.
2. **Filtre de tendance** : l'EMA rapide doit être du bon côté de l'EMA lente.
   Configurable sur une timeframe supérieure (`InpTrendTF`) pour n'acheter que
   les cassures alignées avec la tendance de fond.
3. **Filtre ADX** : le marché doit être en expansion, pas en range. Sans ce
   filtre, une stratégie de cassure se fait déchirer par les faux signaux.
4. **Filtres de coût** : spread absolu et/ou spread rapporté à l'ATR. Le second
   est le plus important ici — un spread de 400 points est normal sur BTC et
   catastrophique sur l'or, seul le ratio spread/ATR est comparable entre les deux.

**Sortie** — trois mécanismes, tous indexés sur l'ATR :

| Mécanisme | Rôle |
|---|---|
| Stop loss `InpSL_ATR` | Perte maximale, posé dès l'ouverture. Obligatoire — l'EA refuse de démarrer sans. |
| Break-even `InpBE_ATR` | Ramène le stop au-delà du prix d'entrée dès que le gain couvre X ATR. |
| Trailing `InpTrail_ATR` | Suit le marché à X ATR de distance, ne recule jamais. |

Le take profit (`InpTP_ATR`) est **désactivé par défaut** : sur une stratégie de
cassure, laisser courir via le trailing capte les mouvements longs qui font la
rentabilité de l'approche. Un TP fixe coupe exactement les trades dont tu as besoin.

---

## Garde-fous de risque

Ce sont eux qui font la différence entre un EA utilisable et un EA qui vide un compte.

- **Dimensionnement par le risque** — `InpRiskPercent` fixe le pourcentage d'equity
  perdu si le stop est touché. Le volume est calculé depuis la distance de stop
  *réelle* (après élargissement éventuel au stops level du broker), pas depuis
  la distance théorique.
- **Refus plutôt que dépassement** — si le volume calculé tombe sous le lot
  minimum du broker, l'EA **saute le trade** et le journalise, au lieu d'ouvrir
  silencieusement une position qui risque bien plus que demandé. Comportement
  critique sur BTC, où le lot minimum représente souvent une exposition importante.
  `InpForceMinLot=true` inverse ce choix, en le signalant dans le journal.
- **Coupe-circuit journalier** — `InpMaxDailyLossPct` gèle toute nouvelle
  ouverture quand l'equity décroche du seuil par rapport au début de la journée
  serveur. `InpMaxDailyProfitPct` fait l'inverse (arrêt sur objectif atteint).
- **Pause après perte** — `InpCooldownBars` bloque les entrées pendant N bougies
  après une clôture perdante, pour ne pas enchaîner les cassures ratées dans un
  même range.
- **Vérification de marge** avant chaque envoi d'ordre.
- **Distance minimale des stops** respectée (`stops level` et `freeze level`).

---

## Installation

Copie l'arborescence dans le dossier de données MT5
(*Fichier → Ouvrir le dossier de données*) :

```
MQL5/Experts/Queu/QueuBreakoutEA.mq5
MQL5/Include/Queu/Utils.mqh
MQL5/Include/Queu/Risk.mqh
MQL5/Presets/*.set          ->  a copier dans MQL5/Presets/
```

Puis, dans MetaEditor, ouvre `QueuBreakoutEA.mq5` et compile (**F7**).
L'EA apparaît ensuite dans le Navigateur de MT5.

---

## Presets

Deux points de départ sont fournis. **Ce sont des points de départ, pas des
réglages validés** : le spread, le `point` et la taille de contrat de l'or et du
BTC varient énormément d'un broker à l'autre, ce qui déplace tous les optima.

| Fichier | Instrument | Particularités |
|---|---|---|
| `QueuBreakoutEA_XAUUSD_H1.set` | XAUUSD H1 | Session 07h–20h (Londres + New York), stops à 2 ATR, risque 0.5 % |
| `QueuBreakoutEA_BTCUSD_H1.set` | BTCUSD H1 | 24/7 sauf week-end, filtre de tendance en H4, stops à 2.5 ATR, risque 0.35 % |

Les écarts entre les deux ne sont pas cosmétiques :

- **Stops plus larges sur BTC** (2.5 vs 2.0 ATR) — le bruit intra-bougie du BTC
  déclenche un stop à 2 ATR nettement plus souvent que sur l'or.
- **Filtre de tendance en H4 sur BTC** — le H1 du BTC produit trop de faux
  changements de régime.
- **Week-end exclu sur BTC** — le marché est ouvert, mais la liquidité du
  week-end élargit les spreads et fabrique des cassures qui ne tiennent pas.
- **Session restreinte sur l'or** — les cassures de l'or hors des heures de
  Londres et New York ont peu de volume derrière elles.

---

## Protocole de validation

Ne saute aucune étape.

1. **Backtest** — testeur de stratégie, mode *Toutes les ticks basées sur des
   ticks réels*. Tout autre mode surestime les résultats d'une stratégie à
   trailing stop.
2. **Vérifie le spread du test.** Le testeur utilise souvent un spread fixe
   irréaliste. Compare avec le spread réel constaté sur ton compte, surtout sur
   BTC — c'est l'erreur qui rend rentables des stratégies qui ne le sont pas.
3. **Optimise sur une période, valide sur une autre** (walk-forward). Un jeu de
   paramètres optimisé et validé sur la même période ne prouve rien.
4. **Méfie-toi des optima isolés.** Un réglage rentable dont les voisins immédiats
   sont perdants est du sur-apprentissage. Cherche des plateaux, pas des pics.
5. **Forward test en démo**, plusieurs semaines minimum, sur le compte du broker
   que tu utiliseras en réel.
6. **Réel avec un risque réduit** (`InpRiskPercent` à 0.1–0.25 pour commencer).

---

## Notes d'exploitation

- **Toutes les heures sont en heure serveur du broker**, pas en heure locale.
  Vérifie le décalage avant de régler `InpSessionFrom` / `InpSessionTo`.
- **Un magic number par instance.** Les presets utilisent `770101` (or) et
  `770102` (BTC) pour que deux instances sur le même compte ne se marchent pas
  dessus.
- Les entrées sont évaluées à la clôture des bougies ; la **gestion des stops
  tourne à chaque tick**, pour qu'une position ouverte ne reste jamais non
  protégée en attendant la fin d'une bougie.
- Le panneau d'état affiché sur le graphique indique l'ATR, le spread, le nombre
  de positions et — utile pour le débogage — **la raison exacte** pour laquelle
  l'EA refuse d'ouvrir.
