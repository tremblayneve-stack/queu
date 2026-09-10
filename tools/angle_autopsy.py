#!/usr/bin/env python3
"""
Autopsie statistique des grappes exportees par QueuTradeAutopsy.mq5.

Repond a la question posee : existe-t-il une plage d'angle du canal ou le
taux de reussite est nettement meilleur ?

Le piege, et la raison d'etre de ce script : chercher « la meilleure plage
d'angle » parmi des centaines de plages candidates TROUVE TOUJOURS quelque
chose, meme sur des donnees purement aleatoires. Un winrate de 82 % sur une
tranche n'est une decouverte que s'il depasse ce que le hasard produit
quand on cherche aussi fort.

Le script mesure donc explicitement cette barre, par test de permutation :
on melange les resultats au hasard, on relance la MEME recherche, et on
regarde combien de fois elle trouve aussi bien. C'est la seule facon
honnete de repondre.

Bibliotheque standard uniquement.
"""

import csv
import math
import random
import statistics
import sys
from collections import defaultdict

N_PERM = 2000
MIN_FRACTION = 0.15          # une plage doit couvrir >= 15 % des grappes


# ------------------------------------------------------------------ outils
def title(s):
    print("\n" + s)
    print("=" * len(s))


def wilson(k, n, z=1.96):
    """Intervalle de confiance de Wilson : correct meme sur petit n,
    contrairement a l'intervalle normal qui deborde de [0,1]."""
    if n == 0:
        return 0.0, 0.0
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    s = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return max(0.0, (c - s) / d), min(1.0, (c + s) / d)


def welch_t(a, b):
    if len(a) < 2 or len(b) < 2:
        return 0.0
    va, vb = statistics.pvariance(a), statistics.pvariance(b)
    se = math.sqrt(va / len(a) + vb / len(b))
    if se <= 0:
        return 0.0
    return (statistics.mean(a) - statistics.mean(b)) / se


# --------------------------------------------------------------- chargement
def load(path):
    rows = []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        for d in csv.DictReader(f):
            try:
                r = {
                    "id": int(float(d["cluster_id"])),
                    "account": d.get("account", "?").strip(),
                    "open": d["open_time"].strip(),
                    "dir": d["direction"].strip(),
                    "n_entries": int(float(d["n_entries"])),
                    "reinforced": int(float(d["used_reinforcement"])),
                    "pnl": float(d["pnl_money"]),
                    "pct": float(d["pnl_pct_balance"]),
                    "fast_angle": float(d["fast_angle_deg"]),
                    "slow_angle": float(d["slow_angle_deg"]),
                    "fast_r2": float(d["fast_r2"]),
                    "slow_r2": float(d["slow_r2"]),
                    "fast_dev": float(d["fast_dev_from_mid"]),
                    "slow_dev": float(d["slow_dev_from_mid"]),
                    "angle_diff": float(d["angle_diff_deg"]),
                    "aligned": int(float(d["aligned"])),
                    "mfe_s": float(d["mfe_short_atr"]),
                    "mae_s": float(d["mae_short_atr"]),
                    "mfe_l": float(d["mfe_long_atr"]),
                    "mae_l": float(d["mae_long_atr"]),
                    "dur": float(d["duration_sec"]),
                }
                r["win"] = 1 if r["pnl"] > 0 else 0
                r["date"] = r["open"].split()[0]
                rows.append(r)
            except (KeyError, ValueError):
                continue
    return rows


# ------------------------------------------------------- recherche de plage
def best_contiguous(sorted_vals, edges, min_n):
    """Meilleure plage contigue [i,j) sur les valeurs deja triees par angle.
    Retourne (moyenne, i, j). O(1) par plage grace aux sommes prefixes."""
    n = len(sorted_vals)
    pref = [0.0] * (n + 1)
    for k in range(n):
        pref[k + 1] = pref[k] + sorted_vals[k]

    best, bi, bj = -1e18, 0, n
    for a in range(len(edges)):
        for b in range(a + 1, len(edges)):
            i, j = edges[a], edges[b]
            if j - i < min_n:
                continue
            m = (pref[j] - pref[i]) / (j - i)
            if m > best:
                best, bi, bj = m, i, j
    return best, bi, bj


def permutation_barrier(sorted_vals, edges, min_n, n_perm=N_PERM, seed=7):
    """Distribution du MEILLEUR resultat trouvable quand les issues sont
    melangees au hasard. C'est la barre que doit franchir une vraie
    decouverte."""
    rng = random.Random(seed)
    pool = list(sorted_vals)
    maxima = []
    for _ in range(n_perm):
        rng.shuffle(pool)
        m, _, _ = best_contiguous(pool, edges, min_n)
        maxima.append(m)
    maxima.sort()
    return maxima


def q(sorted_list, p):
    if not sorted_list:
        return 0.0
    return sorted_list[min(len(sorted_list) - 1, max(0, int(p * (len(sorted_list) - 1))))]


# ------------------------------------------------------------------ analyses
def coverage(rows):
    title(f"1. COUVERTURE — {len(rows)} grappes")
    accounts = sorted(set(r["account"] for r in rows))
    days = sorted(set(r["date"] for r in rows))
    wins = sum(r["win"] for r in rows)
    reinf = sum(r["reinforced"] for r in rows)

    print(f"  comptes                {', '.join(accounts)}")
    print(f"  jours couverts         {len(days)}  ({days[0]} -> {days[-1]})")
    print(f"  grappes / jour         {len(rows)/max(1,len(days)):.1f}")
    lo, hi = wilson(wins, len(rows))
    print(f"  taux de reussite       {wins/len(rows)*100:.1f}%  "
          f"(IC95 {lo*100:.1f}–{hi*100:.1f}%)")
    print(f"  avec renforts          {reinf}/{len(rows)}  ({reinf/len(rows)*100:.1f}%)")

    w = [r["pnl"] for r in rows if r["win"]]
    l = [r["pnl"] for r in rows if not r["win"]]
    if w and l:
        aw, al = statistics.mean(w), abs(statistics.mean(l))
        print(f"\n  gain moyen             {aw:+.2f}")
        print(f"  perte moyenne          {-al:+.2f}")
        print(f"  ratio perte/gain       {al/aw:.2f}x")
        exp = statistics.mean(r["pnl"] for r in rows)
        print(f"  esperance par grappe   {exp:+.2f}")
        if al / aw > 1.0:
            need = al / (aw + al)
            print(f"\n  Avec ce ratio il faut {need*100:.1f}% de reussite pour etre a")
            print(f"  l'equilibre. Tu es a {wins/len(rows)*100:.1f}%.")
            print("  Si l'ecart est mince, le probleme n'est pas le filtre d'entree")
            print("  mais la TAILLE des pertes — donc la structure des renforts.")


def daily(rows):
    title("2. RENDEMENT JOURNALIER REEL")
    byday = defaultdict(float)
    for r in rows:
        byday[r["date"]] += r["pct"]
    vals = sorted(byday.values())
    if not vals:
        return

    above1 = sum(1 for v in vals if v >= 1.0)
    print(f"  jours mesures          {len(vals)}")
    print(f"  moyenne                {statistics.mean(vals):+.3f}% / jour")
    print(f"  mediane                {statistics.median(vals):+.3f}%")
    print(f"  meilleur / pire        {vals[-1]:+.3f}%  /  {vals[0]:+.3f}%")
    print(f"  jours >= +1%           {above1}/{len(vals)}  ({above1/len(vals)*100:.0f}%)")

    print("\n  Ce que vaut la cible, en composition sur un an (365 jours) :")
    for t in (0.5, 1.0, 2.0):
        print(f"    {t:.1f}% / jour  ->  x{(1+t/100)**365:,.0f}")
    print("  Un objectif de 1 a 2 % par jour SOUTENU multiplie un capital par")
    print("  38 a 1400 en un an. Aucune strategie ne tient ca : la taille de")
    print("  position necessaire finit par depasser la liquidite disponible.")
    print("  Une cible mensuelle est la seule formulation qui reste testable.")


def angle_table(rows, key, label, n_buckets=8):
    title(f"3. TAUX DE REUSSITE PAR TRANCHE D'ANGLE — {label}")
    srt = sorted(rows, key=lambda r: r[key])
    n = len(srt)
    size = max(1, n // n_buckets)

    print(f"  {'plage (deg)':<20}{'n':>5}{'reussite':>11}{'IC95':>16}"
          f"{'PnL moyen':>12}{'renforts':>10}")
    for b in range(n_buckets):
        i, j = b * size, (b + 1) * size if b < n_buckets - 1 else n
        chunk = srt[i:j]
        if len(chunk) < 3:
            continue
        wins = sum(c["win"] for c in chunk)
        lo, hi = wilson(wins, len(chunk))
        rng = f"{chunk[0][key]:+.1f} .. {chunk[-1][key]:+.1f}"
        pnl = statistics.mean(c["pnl"] for c in chunk)
        rf = sum(c["reinforced"] for c in chunk) / len(chunk) * 100
        print(f"  {rng:<20}{len(chunk):>5}{wins/len(chunk)*100:>10.1f}%"
              f"{lo*100:>8.0f}–{hi*100:<7.0f}{pnl:>12.2f}{rf:>9.0f}%")
    print("\n  Les intervalles de Wilson se CHEVAUCHENT presque toujours sur peu")
    print("  de donnees : deux tranches dont les IC se recouvrent ne sont pas")
    print("  distinguables, quelle que soit la difference apparente.")


def hunt(rows, key, label):
    title(f"4. LA MEILLEURE PLAGE D'ANGLE EST-ELLE REELLE ? — {label}")
    srt = sorted(rows, key=lambda r: r[key])
    n = len(srt)
    min_n = max(8, int(n * MIN_FRACTION))
    if n < 40:
        print(f"  {n} grappes : trop peu pour que ce test ait un sens (il en faut ~100).")
        return

    edges = sorted(set(int(p * n / 20) for p in range(21)))
    edges = [e for e in edges if e <= n]
    if edges[-1] != n:
        edges.append(n)

    for metric, name, unit in (("win", "taux de reussite", "%"),
                               ("pct", "gain moyen", "% du solde")):
        vals = [float(r[metric]) for r in srt]
        obs, i, j = best_contiguous(vals, edges, min_n)
        rng = f"{srt[i][key]:+.1f} .. {srt[j-1][key]:+.1f} deg"
        shown = obs * 100 if metric == "win" else obs

        null = permutation_barrier(vals, edges, min_n)
        p = sum(1 for m in null if m >= obs) / len(null)
        barrier = q(null, 0.95)
        bshown = barrier * 100 if metric == "win" else barrier
        base = statistics.mean(vals)
        bshown0 = base * 100 if metric == "win" else base

        print(f"\n  {name.upper()}")
        print(f"    meilleure plage trouvee   {rng}   n={j-i}")
        print(f"    valeur sur cette plage    {shown:.2f} {unit}")
        print(f"    moyenne generale          {bshown0:.2f} {unit}")
        print(f"    barre du hasard (95e)     {bshown:.2f} {unit}   "
              f"<-- ce que la MEME recherche trouve sur des donnees melangees")
        print(f"    p-value                   {p:.3f}")
        if p < 0.05:
            print(f"    -> SIGNIFICATIF. La plage resiste au test de permutation.")
            print(f"       A confirmer hors echantillon avant d'en faire une regle.")
        else:
            print(f"    -> NON SIGNIFICATIF. Le hasard fait aussi bien dans {p*100:.0f}%")
            print( "       des cas. Cette plage n'est pas une decouverte, c'est le")
            print( "       resultat d'avoir cherche parmi des centaines de plages.")


def alignment(rows):
    title("5. ALIGNEMENT DES DEUX TIMEFRAMES")
    a = [r for r in rows if r["aligned"]]
    d = [r for r in rows if not r["aligned"]]
    if len(a) < 8 or len(d) < 8:
        print(f"  Echantillons trop deseuilibres ({len(a)} alignes / {len(d)} non).")
        return

    for name, grp in (("alignes", a), ("non alignes", d)):
        wins = sum(r["win"] for r in grp)
        lo, hi = wilson(wins, len(grp))
        print(f"  {name:<14} n={len(grp):>4}  reussite {wins/len(grp)*100:>5.1f}%  "
              f"(IC95 {lo*100:.0f}–{hi*100:.0f}%)  PnL moyen "
              f"{statistics.mean(r['pnl'] for r in grp):+.2f}")

    t = welch_t([r["pnl"] for r in a], [r["pnl"] for r in d])
    print(f"\n  test de Welch sur le PnL : t = {t:+.2f}")
    print("  -> " + ("ecart credible" if abs(t) > 2 else
                     "compatible avec le hasard : ne rien en conclure"))


def reinforcement(rows):
    title("6. RENFORTS — quand deviennent-ils necessaires ?")
    solo = [r for r in rows if not r["reinforced"]]
    reinf = [r for r in rows if r["reinforced"]]
    if not solo or not reinf:
        print("  Un seul des deux cas est present dans les donnees.")
        return

    for name, grp in (("sans renfort", solo), ("avec renforts", reinf)):
        wins = sum(r["win"] for r in grp)
        print(f"  {name:<15} n={len(grp):>4}  reussite {wins/len(grp)*100:>5.1f}%  "
              f"PnL moyen {statistics.mean(r['pnl'] for r in grp):+8.2f}  "
              f"pire {min(r['pnl'] for r in grp):+8.2f}")

    print(f"\n  angle moyen sans renfort : {statistics.mean(r['fast_angle'] for r in solo):+.2f} deg")
    print(f"  angle moyen avec renforts: {statistics.mean(r['fast_angle'] for r in reinf):+.2f} deg")
    t = welch_t([r["fast_angle"] for r in solo], [r["fast_angle"] for r in reinf])
    print(f"  test de Welch sur l'angle : t = {t:+.2f}  -> " +
          ("l'angle predit le besoin de renfort" if abs(t) > 2 else
           "l'angle ne predit pas le besoin de renfort"))

    worst = min(r["pnl"] for r in reinf)
    tot = sum(r["pnl"] for r in rows)
    if tot != 0:
        print(f"\n  La pire grappe avec renforts vaut {worst:+.2f}, soit "
              f"{abs(worst/tot)*100:.0f}% du resultat net total.")
        print("  Si ce pourcentage est eleve, une seule serie de renforts efface")
        print("  le travail de plusieurs jours : c'est la structure qu'il faut")
        print("  corriger avant tout filtre d'entree.")


def forward(rows):
    title("7. REACTION DU PRIX APRES L'ENTREE (en ATR)")
    print(f"  {'':22}{'MFE court':>11}{'MAE court':>11}{'MFE long':>11}{'MAE long':>11}")
    for name, grp in (("gagnantes", [r for r in rows if r["win"]]),
                      ("perdantes", [r for r in rows if not r["win"]])):
        if not grp:
            continue
        print(f"  {name:<22}{statistics.mean(r['mfe_s'] for r in grp):>11.2f}"
              f"{statistics.mean(r['mae_s'] for r in grp):>11.2f}"
              f"{statistics.mean(r['mfe_l'] for r in grp):>11.2f}"
              f"{statistics.mean(r['mae_l'] for r in grp):>11.2f}")

    losers = [r for r in rows if not r["win"]]
    if losers:
        m = statistics.mean(r["mfe_s"] for r in losers)
        print(f"\n  Les perdantes montent en moyenne a {m:+.2f} ATR dans les premieres")
        print("  minutes. Si ce chiffre est nettement positif, une sortie precoce")
        print("  au premier gain recupererait une partie de ces trades — piste plus")
        print("  simple et plus sure qu'un filtre d'angle.")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("Usage : python3 tools/angle_autopsy.py <Queu_Autopsy_*.csv> [autre.csv ...]")
        sys.exit(1)

    rows = []
    for p in sys.argv[1:]:
        r = load(p)
        print(f"  {p} : {len(r)} grappes")
        rows += r

    if len(rows) < 10:
        sys.exit(f"\nSeulement {len(rows)} grappes exploitables : rien a analyser.")

    coverage(rows)
    daily(rows)
    angle_table(rows, "fast_angle", "timeframe rapide")
    hunt(rows, "fast_angle", "timeframe rapide")
    alignment(rows)
    reinforcement(rows)
    forward(rows)

    title("LECTURE")
    print("  Une plage d'angle n'est exploitable que si elle survit au test de")
    print("  permutation ET se confirme sur une periode qui n'a pas servi a la")
    print("  trouver. Reserve les derniers jours pour cette verification.")


if __name__ == "__main__":
    main()
