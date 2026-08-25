#!/usr/bin/env python3
"""
Analyse hors MetaTrader des sorties de QueuBreakoutEA.

Deux modes :

  trades  <fichier>   Journal de trades (Queu_Trades_*.csv).
                      Repond a : ou se trouve reellement l'edge, et ou
                      paie-t-on pour rien.

  passes  <fichier>   Resume des passes d'optimisation (Queu_Passes_*.csv).
                      Fournit les deux valeurs a reinjecter dans l'EA pour
                      la seconde passe (InpTester_Trials, InpTester_TrialsSD)
                      et distingue les plateaux robustes des pics de
                      sur-apprentissage.

Sans dependance externe : bibliotheque standard uniquement.
"""

import csv
import math
import statistics
import sys
from collections import defaultdict

# --------------------------------------------------------------------------
# Statistiques (memes formules que MQL5/Include/Queu/Stats.mqh)
# --------------------------------------------------------------------------
EULER = 0.5772156649015329


def norm_cdf(x):
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def norm_inv(p):
    if not 0.0 < p < 1.0:
        raise ValueError("quantile hors domaine")
    # bissection sur erf : precision suffisante et sans table de coefficients
    lo, hi = -40.0, 40.0
    for _ in range(200):
        mid = (lo + hi) / 2.0
        if norm_cdf(mid) < p:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2.0


def moments(x):
    n = len(x)
    m = sum(x) / n
    m2 = sum((v - m) ** 2 for v in x)
    m3 = sum((v - m) ** 3 for v in x)
    m4 = sum((v - m) ** 4 for v in x)
    sd = math.sqrt(m2 / (n - 1)) if n > 1 else 0.0
    var = m2 / n
    sdp = math.sqrt(var) if var > 0 else 0.0
    skew = (m3 / n) / sdp ** 3 if sdp > 0 else 0.0
    kurt = (m4 / n) / var ** 2 if var > 0 else 3.0
    return m, sd, skew, kurt


def psr(x, benchmark=0.0):
    """Probabilistic Sharpe Ratio."""
    n = len(x)
    if n < 3:
        return 0.0
    m, sd, sk, ku = moments(x)
    if sd <= 0:
        return 0.0
    sr = m / sd
    den = 1.0 - sk * sr + ((ku - 1.0) / 4.0) * sr * sr
    if den <= 0:
        return 0.0
    return norm_cdf((sr - benchmark) * math.sqrt(n - 1) / math.sqrt(den))


def expected_max_sharpe(trials, trials_sd):
    """Sharpe atteignable par pur hasard apres 'trials' essais."""
    if trials < 2 or trials_sd <= 0:
        return 0.0
    t = float(trials)
    return trials_sd * ((1 - EULER) * norm_inv(1 - 1 / t)
                        + EULER * norm_inv(1 - 1 / (t * math.e)))


def max_drawdown(returns):
    eq, peak, mdd = 1.0, 1.0, 0.0
    for r in returns:
        eq *= (1.0 + r)
        peak = max(peak, eq)
        if peak > 0:
            mdd = max(mdd, (peak - eq) / peak)
    return mdd


# --------------------------------------------------------------------------
# Presentation
# --------------------------------------------------------------------------
def title(s):
    print("\n" + s)
    print("=" * len(s))


def bucket_table(rows, keyfn, label, min_n=8):
    """Esperance par sous-groupe. Isole ou l'edge existe vraiment."""
    groups = defaultdict(list)
    for r in rows:
        groups[keyfn(r)].append(r["r"])

    usable = {k: v for k, v in groups.items() if len(v) >= min_n}
    if not usable:
        print(f"  (pas assez de trades par {label} pour conclure, "
              f"minimum {min_n} par groupe)")
        return

    print(f"  {label:<16}{'n':>6}{'esperance R':>14}{'taux reussite':>15}{'total R':>10}")
    for k in sorted(usable):
        v = usable[k]
        wins = sum(1 for x in v if x > 0)
        flag = "  <-- negatif" if statistics.mean(v) < 0 else ""
        print(f"  {str(k):<16}{len(v):>6}{statistics.mean(v):>14.3f}"
              f"{wins / len(v) * 100:>14.1f}%{sum(v):>10.1f}{flag}")

    ignored = len(groups) - len(usable)
    if ignored:
        print(f"  ({ignored} groupe(s) ignore(s), moins de {min_n} trades)")


# --------------------------------------------------------------------------
# Mode trades
# --------------------------------------------------------------------------
def analyze_trades(path):
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        raw = list(csv.DictReader(f))

    rows = []
    for d in raw:
        try:
            rows.append({
                "r": float(d["r_multiple"]),
                "pnl": float(d["pnl_money"]),
                "risk_pct": float(d["risk_pct"]),
                "mfe": float(d["mfe_r"]),
                "mae": float(d["mae_r"]),
                "er": float(d["efficiency_ratio"]),
                "adx": float(d["adx"]),
                "spread": float(d["spread_pts"]),
                "hour": int(float(d["hour"])),
                "dow": int(float(d["day_of_week"])),
                "dir": d["dir"].strip(),
                "hold": float(d["hold_seconds"]),
            })
        except (KeyError, ValueError):
            continue

    if not rows:
        sys.exit(f"Aucun trade exploitable dans {path}")

    rs = [r["r"] for r in rows]
    n = len(rs)
    wins = [x for x in rs if x > 0]
    losses = [x for x in rs if x <= 0]

    title(f"Journal de trades — {path}")
    print(f"  trades                {n}")
    print(f"  taux de reussite      {len(wins) / n * 100:.1f}%")
    print(f"  esperance             {statistics.mean(rs):+.4f} R par trade")
    print(f"  total                 {sum(rs):+.1f} R")
    if wins and losses:
        aw, al = statistics.mean(wins), abs(statistics.mean(losses))
        print(f"  gain moyen            {aw:+.3f} R")
        print(f"  perte moyenne         {-al:+.3f} R")
        print(f"  ratio gain/perte      {aw / al:.2f}")
        pf = sum(wins) / abs(sum(losses))
        print(f"  facteur de profit     {pf:.3f}")
        kelly = len(wins) / n - (1 - len(wins) / n) / (aw / al)
        print(f"  Kelly plein estime    {kelly:+.4f}  "
              f"(soit {kelly * 100:+.2f}% d'equity par trade)")
        print(f"  quart de Kelly        {kelly * 25:+.3f}% par trade")

    # rendements composes reels, pour un drawdown honnete
    comp = [r["r"] * r["risk_pct"] / 100.0 for r in rows]
    m, sd, sk, ku = moments(rs)
    if sd > 0:
        sr = m / sd
        print(f"\n  Sharpe par trade      {sr:.4f}")
        print(f"  Sharpe annualise*     {sr * math.sqrt(n):.3f}   "
              f"(*sur la duree du jeu de donnees, pas par an)")
        print(f"  asymetrie             {sk:+.3f}")
        print(f"  kurtosis              {ku:.2f}")
        print(f"  PSR contre 0          {psr(rs):.4f}   "
              f"probabilite que le vrai Sharpe soit positif")
        if sk < -0.5:
            print("  ATTENTION : asymetrie negative marquee — profil "
                  "'petits gains reguliers, grosses pertes rares'.")
        if ku > 6:
            print("  ATTENTION : queues epaisses — le risque de perte extreme "
                  "est sous-estime par l'ecart-type seul.")
    print(f"  drawdown max          {max_drawdown(comp) * 100:.2f}%  "
          f"(rendements composes au risque reellement engage)")

    title("Excursions — le stop et la sortie sont-ils bien places ?")
    print(f"  MFE moyenne           {statistics.mean(r['mfe'] for r in rows):.3f} R")
    print(f"  MAE moyenne           {statistics.mean(r['mae'] for r in rows):.3f} R")
    won = [r for r in rows if r["r"] > 0]
    lost = [r for r in rows if r["r"] <= 0]
    if won:
        capture = statistics.mean(r["r"] / r["mfe"] for r in won if r["mfe"] > 0)
        print(f"  capture des gagnants  {capture * 100:.1f}% de la MFE conservee")
        if capture < 0.5:
            print("  -> plus de la moitie du gain latent est rendue : "
                  "le trailing est trop lache, ou le TP partiel manquant.")
    if lost:
        worst = statistics.mean(r["mfe"] for r in lost)
        print(f"  MFE moyenne des perdants {worst:.3f} R")
        if worst > 0.8:
            print("  -> les perdants passaient en moyenne pres de 1 R de gain : "
                  "un break-even plus precoce recupererait une partie de ces trades.")

    title("Ou se trouve l'edge")
    bucket_table(rows, lambda r: r["dir"], "direction")
    print()
    bucket_table(rows, lambda r: f"{r['hour']:02d}h", "heure serveur")
    print()
    bucket_table(rows, lambda r: ["dim", "lun", "mar", "mer", "jeu", "ven", "sam"][r["dow"]],
                 "jour")
    print()
    bucket_table(rows, lambda r: f"ER {math.floor(r['er'] * 10) / 10:.1f}-"
                                f"{math.floor(r['er'] * 10) / 10 + 0.1:.1f}",
                 "efficience")
    print()
    bucket_table(rows, lambda r: f"ADX {int(r['adx'] // 10) * 10}-{int(r['adx'] // 10) * 10 + 10}",
                 "force ADX")

    title("Lecture")
    print("  Un groupe a esperance negative avec assez de trades est un candidat")
    print("  a l'exclusion par filtre (session, seuil d'ER, seuil d'ADX).")
    print("  Attention : plus on decoupe, plus on risque de sur-apprendre. Ne")
    print("  retirer un groupe que s'il a une justification de marche, pas")
    print("  seulement une statistique defavorable sur un echantillon court.")


# --------------------------------------------------------------------------
# Mode passes
# --------------------------------------------------------------------------
def analyze_passes(path):
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        raw = list(csv.DictReader(f))

    rows = []
    for d in raw:
        try:
            rows.append({k: float(v) for k, v in d.items() if v not in (None, "")})
        except ValueError:
            continue
    rows = [r for r in rows if "sharpe_per_trade" in r and r.get("n_trades", 0) > 0]

    if len(rows) < 2:
        sys.exit(f"Moins de deux passes exploitables dans {path}")

    sharpes = [r["sharpe_per_trade"] for r in rows]
    trials = len(rows)
    sd = statistics.stdev(sharpes)

    title(f"Passes d'optimisation — {path}")
    print(f"  passes retenues       {trials}")
    print(f"  Sharpe/trade moyen    {statistics.mean(sharpes):+.4f}")
    print(f"  Sharpe/trade ecart-t. {sd:.4f}")
    print(f"  Sharpe/trade max      {max(sharpes):+.4f}")

    title("Valeurs a reinjecter dans l'EA pour la seconde passe")
    print(f"  InpTester_Trials   = {trials}")
    print(f"  InpTester_TrialsSD = {sd:.4f}")
    print()
    seuil = expected_max_sharpe(trials, sd)
    print(f"  Seuil de deflation : {seuil:.4f} Sharpe/trade.")
    print(f"  Autrement dit, avec {trials} jeux de parametres essayes, un Sharpe")
    print(f"  par trade allant jusqu'a {seuil:.4f} est atteignable SANS aucun edge,")
    print("  par simple selection du meilleur tirage. Toute passe en dessous de ce")
    print("  seuil est du bruit, quel que soit son profit affiche.")

    above = [r for r in rows if r["sharpe_per_trade"] > seuil]
    print(f"\n  passes au-dessus du seuil : {len(above)} / {trials} "
          f"({len(above) / trials * 100:.1f}%)")
    if not above:
        print("  -> AUCUNE passe ne survit a la deflation. Le jeu de parametres")
        print("     teste n'a pas d'edge demontrable sur ces donnees. Elargir la")
        print("     periode ou revoir la strategie ; ne pas passer en reel.")

    title("Profit brut contre Sharpe deflate : le meme classement ?")
    by_profit = sorted(rows, key=lambda r: r.get("net_profit", 0), reverse=True)
    by_dsr = sorted(rows, key=lambda r: r["sharpe_per_trade"], reverse=True)
    cols = ["channel_period", "sl_atr", "trail_atr", "breakout_atr", "er_min", "adx_min"]

    def line(r):
        prm = " ".join(f"{c.split('_')[0]}={r.get(c, 0):g}" for c in cols if c in r)
        return (f"    n={r.get('n_trades', 0):>4.0f}  profit={r.get('net_profit', 0):>10,.0f}  "
                f"SR/trade={r['sharpe_per_trade']:+.4f}  DD={r.get('max_dd_pct', 0):>5.1f}%  {prm}")

    print("  Meilleures passes par PROFIT :")
    for r in by_profit[:3]:
        print(line(r))
    print("\n  Meilleures passes par SHARPE PAR TRADE :")
    for r in by_dsr[:3]:
        print(line(r))
    if by_profit[0] is not by_dsr[0]:
        print("\n  -> Les deux classements divergent. C'est le cas courant, et c'est")
        print("     exactement pourquoi optimiser sur le profit brut selectionne du")
        print("     sur-apprentissage : le profit recompense quelques trades chanceux.")

    title("La meilleure passe repose-t-elle sur un reglage robuste ?")
    best_pass = by_dsr[0]
    suspect = []
    for col in cols:
        if col not in best_pass:
            continue
        vals = defaultdict(list)
        for r in rows:
            if col in r:
                vals[r[col]].append(r["sharpe_per_trade"])
        if len(vals) < 3:
            continue
        # La passe championne gonfle la moyenne de son propre groupe et se
        # rend ainsi invisible. On l'exclut des deux moyennes comparees.
        top = best_pass["sharpe_per_trade"]

        def without_top(seq):
            out = list(seq)
            if top in out:
                out.remove(top)
            return out

        peers = without_top(vals[best_pass[col]])
        if not peers:
            continue

        here = statistics.mean(peers)
        overall_pool = [x for v in vals.values() for x in without_top(v)]
        if not overall_pool:
            continue
        overall = statistics.mean(overall_pool)

        best_val = max(vals, key=lambda k: statistics.mean(without_top(vals[k]))
                       if without_top(vals[k]) else -1e9)
        if here < overall:
            suspect.append((col, best_pass[col], here, best_val,
                            statistics.mean(without_top(vals[best_val]))))

    if suspect:
        print("  La passe la mieux classee s'appuie sur des valeurs dont la")
        print("  moyenne est INFERIEURE a la moyenne generale :")
        for col, val, here, bval, bmean in suspect:
            print(f"    {col:<16} = {val:g}  (moyenne {here:+.4f}) alors que "
                  f"{bval:g} donne {bmean:+.4f}")
        print()
        print("  C'est la signature typique du sur-apprentissage : le meilleur")
        print("  resultat provient d'un tirage chanceux sur un reglage globalement")
        print("  mediocre, pas d'un reglage reellement superieur. Preferer une")
        print("  valeur situee au centre d'un plateau du tableau ci-dessous.")
    else:
        print("  Les valeurs de la meilleure passe sont toutes au-dessus de la")
        print("  moyenne de leur parametre : pas de signature evidente de pic isole.")

    title("Stabilite des parametres — chercher des plateaux, pas des pics")
    for col in cols:
        vals = defaultdict(list)
        for r in rows:
            if col in r:
                vals[r[col]].append(r["sharpe_per_trade"])
        usable = {k: v for k, v in vals.items() if len(v) >= 3}
        if len(usable) < 3:
            continue
        print(f"\n  {col}")
        for k in sorted(usable):
            v = usable[k]
            mean = statistics.mean(v)
            bar = "#" * max(0, min(40, int((mean - min(sharpes)) /
                                           (max(sharpes) - min(sharpes) + 1e-12) * 40)))
            print(f"    {k:>8g}  n={len(v):>3}  SR moy={mean:+.4f}  {bar}")
        best = max(usable, key=lambda k: statistics.mean(usable[k]))
        neigh = [k for k in sorted(usable) if k != best]
        if neigh:
            bm = statistics.mean(usable[best])
            near = [k for k in neigh if abs(k - best) <= (max(usable) - min(usable)) / 4]
            if near and statistics.mean([statistics.mean(usable[k]) for k in near]) < bm * 0.5:
                print(f"    ATTENTION : {best:g} est un pic isole, ses voisins sont")
                print("    nettement moins bons. Signature classique de sur-apprentissage.")


# --------------------------------------------------------------------------
def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("trades", "passes"):
        print(__doc__)
        sys.exit(1)
    if sys.argv[1] == "trades":
        analyze_trades(sys.argv[2])
    else:
        analyze_passes(sys.argv[2])


if __name__ == "__main__":
    main()
