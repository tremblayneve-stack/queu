#!/usr/bin/env python3
"""
Analyse quantitative du journal de CANDIDATS (Queu_Candidates_*.csv).

Ce fichier contient tous les signaux detectes, PRIS OU REJETES, avec leurs
features, le masque des veto qui les ont bloques, et leur resultat force par
triple barriere. C'est cette exhaustivite qui permet de repondre a la seule
question qui compte sur un systeme filtre :

    chaque veto bloque-t-il des perdants, ou des gagnants ?

Un journal de trades ordinaire ne peut pas y repondre : il ne contient que
les survivants de ses propres filtres.

Contenu :
  1. Couverture et repartition des veto
  2. Efficacite de chaque veto, mesuree sur ce qu'il a bloque
  3. Information Coefficient par feature, pondere par l'unicite des
     etiquettes et assorti d'un effectif EFFECTIF, car des etiquettes qui
     se chevauchent gonflent artificiellement toute significativite
  4. Validation croisee PURGEE avec embargo : la seule facon honnete de
     tester une regle quand les etiquettes se chevauchent dans le temps

Bibliotheque standard uniquement.
"""

import csv
import math
import statistics
import sys
from collections import defaultdict
from datetime import datetime

VETOS = [
    (1,   "TOXICITY"),
    (2,   "SPREAD"),
    (4,   "FLICKER"),
    (8,   "PAIN"),
    (16,  "TICKRATE"),
    (32,  "CONTEXT"),
    (64,  "BREAKEVEN"),
    (128, "POSITIONS"),
    (256, "SESSION"),
]

FEATURES = ["quote_pressure", "absorption", "efficiency", "flicker", "toxicity",
            "spread_ratio", "spread_pts", "tick_rate", "max_gap_sec",
            "r2_fast", "slope_fast_atr", "r2_slow", "slope_slow_atr",
            "pos_slow_channel"]


# ---------------------------------------------------------------- outils
def title(s):
    print("\n" + s)
    print("=" * len(s))


def rank(xs):
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    r = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            r[order[k]] = avg
        i = j + 1
    return r


def pearson(a, b, w=None):
    n = len(a)
    if n < 3:
        return 0.0
    if w is None:
        w = [1.0] * n
    sw = sum(w)
    if sw <= 0:
        return 0.0
    ma = sum(wi * ai for wi, ai in zip(w, a)) / sw
    mb = sum(wi * bi for wi, bi in zip(w, b)) / sw
    cov = sum(wi * (ai - ma) * (bi - mb) for wi, ai, bi in zip(w, a, b))
    va = sum(wi * (ai - ma) ** 2 for wi, ai in zip(w, a))
    vb = sum(wi * (bi - mb) ** 2 for wi, bi in zip(w, b))
    if va <= 0 or vb <= 0:
        return 0.0
    return cov / math.sqrt(va * vb)


def spearman(a, b, w=None):
    return pearson(rank(a), rank(b), w)


def parse_time(s):
    for fmt in ("%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(s.strip(), fmt)
        except ValueError:
            pass
    return None


# ------------------------------------------------------- chargement
def load(path):
    rows = []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        for d in csv.DictReader(f):
            try:
                r = {
                    "id": int(float(d["id"])),
                    "t": parse_time(d["time"]),
                    "dir": int(float(d["dir"])),
                    "kind": int(float(d["kind"])),
                    "taken": int(float(d["taken"])),
                    "veto": int(float(d["veto_mask"])),
                    "r": float(d["r_multiple"]),
                    "label": int(float(d["label"])),
                    "bars": int(float(d["bars_held"])),
                    "ambiguous": int(float(d.get("ambiguous", 0) or 0)),
                }
                for fn in FEATURES:
                    r[fn] = float(d.get(fn) or 0.0)
                if r["t"] is None:
                    continue
                rows.append(r)
            except (KeyError, ValueError):
                continue
    rows.sort(key=lambda x: x["t"])
    return rows


# --------------------------------------------- unicite des etiquettes
def uniqueness_weights(rows, bar_seconds):
    """Poids d'unicite : une etiquette dont la fenetre chevauche beaucoup
    d'autres apporte moins d'information independante. Sans cette
    ponderation, toute significativite est surestimee."""
    spans = []
    for r in rows:
        start = r["t"].timestamp()
        end = start + max(1, r["bars"]) * bar_seconds
        spans.append((start, end))

    # concurrence moyenne sur la duree de chaque etiquette
    events = []
    for s, e in spans:
        events.append((s, 1))
        events.append((e, -1))
    events.sort()

    weights = []
    for s, e in spans:
        conc = 0
        for t, delta in events:
            if t >= e:
                break
            if t <= s:
                conc += delta
        # concurrence au demarrage, minorée a 1
        weights.append(1.0 / max(1, conc))
    return weights


def effective_n(weights):
    """Effectif effectif de Kish : (sum w)^2 / sum(w^2)."""
    sw = sum(weights)
    sw2 = sum(w * w for w in weights)
    return (sw * sw / sw2) if sw2 > 0 else 0.0


# ------------------------------------------------------------ sections
def coverage(rows):
    title(f"1. COUVERTURE — {len(rows)} candidats")
    taken = [r for r in rows if r["taken"]]
    blocked = [r for r in rows if not r["taken"]]
    amb = [r for r in rows if r["ambiguous"]]

    print(f"  pris                  {len(taken):>6}  ({len(taken)/len(rows)*100:.1f}%)")
    print(f"  bloques par un veto   {len(blocked):>6}  ({len(blocked)/len(rows)*100:.1f}%)")
    print(f"  etiquettes ambigues   {len(amb):>6}  "
          f"(les deux barrieres franchies dans la meme bougie)")
    if amb:
        print("    -> retenues comme perdantes (choix pessimiste). Elles biaisent")
        print("       vers le bas ; les exclure donnerait la borne optimiste.")

    by_kind = defaultdict(list)
    for r in rows:
        by_kind[r["kind"]].append(r["r"])
    names = {1: "fade d'absorption", 2: "continuation"}
    print(f"\n  {'signal':<22}{'n':>7}{'R moyen':>11}{'% gagnants':>13}")
    for k in sorted(by_kind):
        v = by_kind[k]
        wins = sum(1 for x in v if x > 0)
        print(f"  {names.get(k, str(k)):<22}{len(v):>7}{statistics.mean(v):>11.4f}"
              f"{wins/len(v)*100:>12.1f}%")

    lab = defaultdict(int)
    for r in rows:
        lab[r["label"]] += 1
    print(f"\n  barriere atteinte : cible {lab.get(1,0)} | "
          f"stop {lab.get(-1,0)} | temps {lab.get(0,0)}")


def veto_efficacy(rows):
    title("2. EFFICACITE DES VETO — bloquent-ils des perdants ou des gagnants ?")
    base = statistics.mean(r["r"] for r in rows)
    print(f"\n  R moyen de TOUS les candidats : {base:+.4f}")
    print(f"\n  {'veto':<12}{'bloques':>9}{'R bloques':>12}{'R passes':>11}"
          f"{'gain':>10}   verdict")

    for bit, name in VETOS:
        hit = [r["r"] for r in rows if r["veto"] & bit]
        oth = [r["r"] for r in rows if not (r["veto"] & bit)]
        if len(hit) < 5 or len(oth) < 5:
            print(f"  {name:<12}{len(hit):>9}{'—':>12}{'—':>11}{'—':>10}   "
                  f"echantillon trop mince")
            continue
        mh, mo = statistics.mean(hit), statistics.mean(oth)
        gain = mo - base
        # test de Welch sur la difference des moyennes : sans lui, un ecart
        # de 0.002 serait presente comme un resultat
        vh = statistics.pvariance(hit) if len(hit) > 1 else 0.0
        vo = statistics.pvariance(oth) if len(oth) > 1 else 0.0
        se = math.sqrt(vh / len(hit) + vo / len(oth))
        t = (mo - mh) / se if se > 0 else 0.0
        if abs(t) < 2.0:
            verdict = f"non significatif (t={t:+.1f})"
        elif t > 0:
            verdict = f"UTILE — bloque du perdant (t={t:+.1f})"
        else:
            verdict = f"NUISIBLE — bloque du gagnant (t={t:+.1f})"
        print(f"  {name:<12}{len(hit):>9}{mh:>12.4f}{mo:>11.4f}{gain:>+10.4f}   {verdict}")

    print("\n  t est le test de Welch sur la difference des moyennes. En dessous de")
    print("  |t| = 2, l'ecart observe est compatible avec le hasard : ne rien en")
    print("  conclure, meme si le signe semble favorable.")
    print("\n  'R passes' est l'esperance des candidats que ce veto n'a pas bloques.")
    print("  Si elle est INFERIEURE au R des bloques, le veto detruit de la valeur :")
    print("  il ecarte precisement les signaux qu'il fallait prendre.")


def feature_ic(rows, bar_seconds):
    title("3. INFORMATION COEFFICIENT PAR FEATURE")
    ws = uniqueness_weights(rows, bar_seconds)
    n_eff = effective_n(ws)
    ys = [r["r"] for r in rows]

    print(f"\n  n brut = {len(rows)}    n EFFECTIF (Kish) = {n_eff:.0f}")
    if n_eff < len(rows) * 0.6:
        print(f"  -> les etiquettes se chevauchent fortement : l'effectif reel vaut")
        print(f"     {n_eff/len(rows)*100:.0f}% du nombre de lignes. Toute statistique")
        print("     calculee sur n brut serait surestimee.")

    print(f"\n  {'feature':<20}{'IC':>9}{'t-stat':>9}{'|t|>2':>8}")
    out = []
    for fn in FEATURES:
        xs = [r[fn] for r in rows]
        if len(set(xs)) < 3:
            continue
        ic = spearman(xs, ys, ws)
        if abs(ic) >= 1.0 or n_eff < 4:
            continue
        t = ic * math.sqrt(max(0.0, n_eff - 2)) / math.sqrt(max(1e-12, 1 - ic * ic))
        out.append((abs(ic), fn, ic, t))

    for _, fn, ic, t in sorted(out, reverse=True):
        flag = "oui" if abs(t) > 2 else ""
        print(f"  {fn:<20}{ic:>+9.4f}{t:>+9.2f}{flag:>8}")

    print("\n  Reperes : un IC de 0.02 a 0.05 est deja un vrai signal en pratique.")
    print("  Un IC eleve sur peu de donnees effectives n'est pas une decouverte.")


def purged_cv(rows, bar_seconds, k=5, embargo_frac=0.01):
    title(f"4. VALIDATION CROISEE PURGEE ({k} plis, embargo {embargo_frac*100:.0f}%)")
    print("\n  Les etiquettes se chevauchent dans le temps : un decoupage naif")
    print("  laisserait fuir de l'information du test vers l'entrainement. On")
    print("  PURGE donc tout echantillon d'entrainement dont la fenetre d'etiquette")
    print("  chevauche le pli de test, plus un embargo apres celui-ci.")

    n = len(rows)
    if n < k * 20:
        print(f"\n  Trop peu de candidats ({n}) pour {k} plis. Il en faut ~{k*20}.")
        return

    ts = [r["t"].timestamp() for r in rows]
    ends = [ts[i] + max(1, rows[i]["bars"]) * bar_seconds for i in range(n)]
    span = ts[-1] - ts[0]
    emb = span * embargo_frac

    print(f"\n  {'feature':<20}{'seuil median':>14}{'R hors ech.':>13}{'plis +':>8}")
    results = []
    for fn in FEATURES:
        vals = [r[fn] for r in rows]
        if len(set(vals)) < 10:
            continue

        oos, thr_used, pos_folds = [], [], 0
        for f in range(k):
            lo = ts[0] + span * f / k
            hi = ts[0] + span * (f + 1) / k
            test = [i for i in range(n) if lo <= ts[i] < hi]
            # purge : tout echantillon dont l'etiquette chevauche le pli
            train = [i for i in range(n)
                     if not (lo <= ts[i] < hi)
                     and not (ts[i] < hi and ends[i] > lo)
                     and not (lo - emb < ts[i] < hi + emb)]
            if len(train) < 20 or len(test) < 10:
                continue

            # meilleur seuil univarie sur l'entrainement
            cands = sorted(set(vals[i] for i in train))
            step = max(1, len(cands) // 40)
            best, best_thr = -1e9, None
            for c in cands[::step]:
                sel = [rows[i]["r"] for i in train if vals[i] >= c]
                if len(sel) < 10:
                    continue
                m = statistics.mean(sel)
                if m > best:
                    best, best_thr = m, c
            if best_thr is None:
                continue

            sel_test = [rows[i]["r"] for i in test if vals[i] >= best_thr]
            if len(sel_test) < 5:
                continue
            m = statistics.mean(sel_test)
            oos.append(m)
            thr_used.append(best_thr)
            if m > 0:
                pos_folds += 1

        if len(oos) >= 3:
            results.append((statistics.mean(oos), fn, statistics.median(thr_used),
                            pos_folds, len(oos)))

    if not results:
        print("\n  Aucune feature n'a pu etre evaluee sur assez de plis.")
        return

    for m, fn, thr, pos, nf in sorted(results, reverse=True):
        print(f"  {fn:<20}{thr:>14.4f}{m:>+13.4f}{pos:>5}/{nf}")

    print("\n  'R hors echantillon' est l'esperance obtenue en appliquant un seuil")
    print("  choisi UNIQUEMENT sur les donnees d'entrainement. Une feature qui")
    print("  brille en IC mais s'effondre ici ne generalise pas.")
    print("  Une regle credible est positive sur la MAJORITE des plis, pas")
    print("  seulement en moyenne : un seul pli peut porter tout le resultat.")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("Usage : python3 tools/research_micro.py <Queu_Candidates_*.csv> "
              "[secondes_par_bougie]")
        sys.exit(1)

    bar_seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
    rows = load(sys.argv[1])
    if len(rows) < 30:
        sys.exit(f"Seulement {len(rows)} candidats exploitables : trop peu pour conclure.")

    coverage(rows)
    veto_efficacy(rows)
    feature_ic(rows, bar_seconds)
    purged_cv(rows, bar_seconds)

    title("LECTURE")
    print("  Un veto NUISIBLE doit etre desactive, pas ajuste.")
    print("  Une feature a fort IC mais negative en validation purgee est du bruit.")
    print("  Sans plusieurs centaines de candidats, aucune de ces mesures ne tranche.")


if __name__ == "__main__":
    main()
