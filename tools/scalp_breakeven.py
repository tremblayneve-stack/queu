#!/usr/bin/env python3
"""
Le scalping micro est-il seulement possible a ton niveau de cout ?

Geometrie d'un scalp :
    stop     = S  (distance en prix)
    cible    = k * S   (k = R-multiple vise, 0.8 a 1.8 dans la spec)
    cout     = c  (spread + commission + slippage, aller-retour)

    gain net   = k*S - c
    perte nette = S + c

En posant f = c / S (le cout rapporte a la DISTANCE DE STOP) :

    p* = (1 + f) / (k + 1)

Resultat exact, sans hypothese de marche. Le seul parametre qui compte est f.
Un stop serre ne rend pas le trade meilleur : il augmente f, donc p*.
"""
import sys


def pstar(k, f):
    if k * 1.0 - f <= 0:
        return None                       # la cible ne couvre pas le cout
    return (1.0 + f) / (k + 1.0)


def grid():
    ks = [0.8, 1.0, 1.3, 1.8, 2.5]
    fs = [0.0, 0.10, 0.20, 0.30, 0.50, 0.75, 1.00]

    print("=" * 74)
    print("  TAUX DE REUSSITE MINIMAL D'UN SCALP,  p* = (1+f)/(k+1)")
    print("=" * 74)
    print("\n  f = cout aller-retour / distance de stop")
    print("  k = R-multiple vise\n")
    print("  " + "f".rjust(6) + "".join(f"k={k}".rjust(11) for k in ks))
    for f in fs:
        row = f"  {f:>6.2f}"
        for k in ks:
            p = pstar(k, f)
            row += ("IMPOSSIBLE".rjust(11) if p is None
                    else f"{p*100:>10.1f}%")
        print(row)
    print("\n  Au-dela de 70% de taux requis, aucune strategie discretionnaire")
    print("  ni automatique ne tient durablement. C'est la zone morte.")


def from_points(stop_points, spread_points, commission_points, slippage_points):
    cost = spread_points + commission_points + slippage_points
    f = cost / stop_points if stop_points > 0 else float("inf")
    print("\n" + "=" * 74)
    print("  TON CAS")
    print("=" * 74)
    print(f"\n  stop            {stop_points:>10.1f} points")
    print(f"  spread          {spread_points:>10.1f} points")
    print(f"  commission      {commission_points:>10.1f} points (aller-retour, converti en points)")
    print(f"  slippage estime {slippage_points:>10.1f} points")
    print(f"  cout total      {cost:>10.1f} points")
    print(f"\n  f = cout / stop = {f:.3f}\n")
    print(f"  {'cible':>8}{'p* requis':>14}{'verdict':>28}")
    for k in [0.8, 1.0, 1.3, 1.8, 2.5]:
        p = pstar(k, f)
        if p is None:
            v = "cible sous le cout"
            print(f"  {k:>7.1f}R{'—':>14}{v:>28}")
            continue
        v = ("jouable" if p < 0.55 else
             "exigeant" if p < 0.65 else
             "tres exigeant" if p < 0.70 else
             "zone morte")
        print(f"  {k:>7.1f}R{p*100:>13.1f}%{v:>28}")

    print("\n  Pour ramener p* sous 55% il faut :")
    for k in [1.0, 1.8]:
        fmax = 0.55 * (k + 1.0) - 1.0
        if fmax <= 0:
            print(f"    cible {k}R : impossible quel que soit le cout")
        else:
            print(f"    cible {k:.1f}R -> f <= {fmax:.3f}, "
                  f"soit un stop d'au moins {cost/fmax:.0f} points a cout constant")


def main():
    grid()
    if len(sys.argv) == 5:
        from_points(*[float(x) for x in sys.argv[1:5]])
    else:
        print("\n" + "-" * 74)
        print("  Pour ton broker :")
        print("    python3 tools/scalp_breakeven.py <stop_pts> <spread_pts> "
              "<commission_pts> <slippage_pts>")
        print("  Les valeurs reelles sortent de MQL5/Scripts/Queu/QueuBrokerAudit.mq5,")
        print("  qui mesure le spread median et p90 sur ton propre flux.")
        print("-" * 74)


if __name__ == "__main__":
    main()
