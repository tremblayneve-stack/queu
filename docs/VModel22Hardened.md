# V MODEL v2.2 Hardened — Continuation Focus

EA autonome : `MQL5/Experts/Queu/VModel22Hardened.mq5`
Preset : `MQL5/Presets/VModel22_NAS100_M5.set`
Instrument : **NAS100.s (PU Prime)**, graphique **M5**, magic `20261150`.

> Mode par défaut : **signaux seulement** (`InpTradeEnabled = false`). Le plan
> de trade est dessiné sur le graphique, écrit dans le journal Experts et dans
> `VMODEL22_decisions.csv`. Aucun ordre n'est envoyé.

## Installation

1. Copier `VModel22Hardened.mq5` dans `MQL5/Experts/Queu/` et le preset dans `MQL5/Presets/`.
2. Compiler dans MetaEditor (**F7**). Fichier autonome, seule dépendance : `Trade/Trade.mqh`.
3. Attacher à un graphique NAS100.s M5, charger le preset.
4. Journaux : `Fichier → Ouvrir le dossier de données commun → Files` :
   `VMODEL22_trades.csv` et `VMODEL22_decisions.csv` (séparateur `;`).

## Heure New York

| `InpTimeMode` | Principe | Testeur |
|---|---|---|
| `VM_TIME_NY_ALIGNED` (défaut) | serveur = NY + `InpAlignedShiftH` h toute l'année (PU Prime : GMT+2/+3 calé sur les dates DST US → 7 h) | identique |
| `VM_TIME_AUTO` | décalage serveur/GMT mesuré en direct, puis UTC → NY selon les règles DST US | repli sur ALIGNÉ |
| `VM_TIME_MANUAL` | décalage GMT fixe du serveur (+1 h l'été US si coché) | identique |

Le tableau de bord affiche l'heure NY calculée : **vérifiez-la** contre une
horloge de New York avant toute autre chose.

## Ce que fait l'EA, bougie M5 par bougie M5

1. **Structure et scores** sur M1, M5, M15, M30, H1, H4 (bougies fermées
   seulement ; un pivot de longueur L n'est utilisé qu'après la clôture des L
   bougies de droite).
   Score = 40·structure + 20·HH/HL + 15·EMA 20/50/100/200 + 15·pente EMA20 +
   10·momentum 8 bougies, divisé par 2 en consolidation.
   Local = .25 M1 + .40 M5 + .35 M15 ; Supérieur = .30 M30 + .35 H1 + .35 H4 ;
   Global = .65 Local + .35 Supérieur.
2. **FVG** M5/M15/M30/H1 (M1 et H4 calculés, n'arment pas), tailles min
   8/14/20/28 points, âge max 120 bougies de leur timeframe.
3. **Armement** au premier touch d'un FVG *neuf* : âge ≥ 4 bougies, Local ≥ 48,
   Global ≥ 28, garde Supérieur ≤ −52 ⇒ Local ≥ 62, M5 > −50, fenêtre
   10:00–15:00 NY. Le touch consomme le FVG, qu'il arme ou non.
4. **Confirmations** : 2 bougies M5 distinctes parmi BOS (swing L3 < 25 bougies),
   IFVG (FVG contraire ≤ 20 bougies), pin bar, engulfing, double bottom/top
   (≥ 0,7 ATR, contexte contraire). Annulation si clôture au-delà du bord opposé,
   expiration après 60 min.
5. **Entrée** après revalidation complète (scores, fenêtre, limites, spread).
6. **Gestion** : 30 % à 2,2 R + BE +0,5 ; 30 % à 3,5 R ; trailing pivot M5 L3
   ± 3 pts ; TP3 broker sur la liquidité ; fermeture 16:25 NY ; coupure à
   −2,8 % journalier (réalisé + latent, ce magic uniquement).

## Choix d'interprétation (là où la spécification laisse du jeu)

Ces points sont codés tels quels ; chacun est un paramètre ou une fonction
isolée, facile à changer.

- **Unités** : « points » = points d'indice (1.0 de prix NAS100), via
  `InpIndexPoint`. Ce ne sont pas des `_Point` broker.
- **Âge minimum de 4 bougies** : compté en bougies du timeframe *du FVG*
  (cohérent avec l'âge max de 120). Un FVG H1 arme donc au plus tôt 4 h après sa
  création.
- **Fenêtre d'armement** : jugée sur l'heure d'ouverture de la bougie de touch
  (10:00 ≤ ouverture < 15:00). L'entrée exige l'heure courante < 15:00.
- **Plusieurs FVG touchés sur la même bougie** : priorité au timeframe le plus
  élevé, puis au plus grand. Les autres sont consommés et journalisés en refus.
- **Confirmations** : une bougie compte pour une confirmation même si plusieurs
  types y apparaissent (tous sont journalisés).
- **Stop loss** : candidats dans l'ordre — plus bas depuis l'armement (M5),
  dernier pivot M5 L3, dernier pivot M15 L3. Le premier ≤ 42 pts est retenu,
  puis porté à 20 pts minimum. Aucun ≤ 42 ⇒ trade refusé.
- **TP3** : liquidité = pivots non balayés M5 (L3), M15, M30, H1, H4 et
  haut/bas de la veille ; on prend le plus proche offrant ≥ 4 R après le
  retrait de 1,5 pt, sinon 4,5 R.
- **Ventes** : SL et TP3 décalés du spread courant (ils se déclenchent au Ask).
- **Partiels** : 30 % du volume *initial*. Si le lot minimum l'empêche, le
  palier est franchi sans fermeture (journalisé) et le BE s'applique quand même.
- **Mode signaux** : chaque signal compte dans le maximum de trades du jour
  (pour que le rythme des signaux reflète celui du trading réel).
- **Pertes consécutives** : remises à zéro chaque jour de trading (17:00 NY).
- **InpMaxPositions** : la gestion suit une seule position ; la valeur est
  forcée à 1.

## Journaux

`VMODEL22_decisions.csv` — une ligne par décision : `ARM`, `REFUS_ARM`,
`CONFIRM`, `ANNUL`, `EXPIRE`, `ENTREE`, `SIGNAL`, `REFUS_ENTREE`, `TP1`, `TP2`,
`BE`, `TRAIL`, `SORTIE_FORCEE`, `SORTIE`, `STOP_JOUR` (+ `ETAT` si
`InpLogEveryBar`). Colonnes : heures serveur/NY, sens, FVG (tf, bornes, âge),
les 3 scores agrégés et les 6 scores, états M5/M15, spread, confirmations,
raison exacte.

`VMODEL22_trades.csv` — une ligne par trade fermé : ouverture/fermeture NY,
sens, zone FVG, confirmations, scores à l'entrée, entrée/SL/distance,
TP1/TP2/TP3 et source, lot, risque, spread, paliers atteints, MFE/MAE (R),
profit (argent et R), raison de sortie (`SL`, `BE`, `TRAIL_SL`, `TP3`,
`FERMETURE_1625`, `PERTE_JOUR`, `MANUEL`…).

## Redémarrage

Position (ticket, R initial, palier, BE en attente, MFE/MAE, TP) et compteurs
du jour sont dans les GlobalVariables `VM22_<magic>_*` ; les textes (zone FVG,
confirmations, source TP3) dans `Common\Files\VMODEL22_ctx_<magic>.txt`. Une
position du magic sans trace persistante est adoptée (palier estimé depuis le
SL). En testeur, ces variables sont effacées à chaque passe.

## Avant de passer en réel

1. Vérifier l'heure NY affichée et le spread typique de NAS100.s.
2. Laisser tourner en signaux, puis lire `VMODEL22_decisions.csv` : quelle
   condition refuse le plus ? Les refus ont-ils du sens sur le graphique ?
3. Backtester en « Chaque tick basé sur les ticks réels » ; la gestion
   (partiels, BE, trailing) est tick par tick.
4. Démo, puis réel avec `InpTradeEnabled = true` au risque par défaut (0,16 %).

Aucune performance n'est promise : la spécification vise une espérance proche
de zéro ou légèrement positive après spread, et des données propres pour itérer.
