#!/usr/bin/env python3
"""
Taux de reussite minimal d'un retour a la moyenne dans un canal de regression.

Geometrie du setup :
    entree  = mid - D * dev      (touche de la bande basse)
    cible   = mid + T * dev      (T=0 -> la droite ; T>0 -> au-dela)
    stop    = mid - S * dev      (S > D)

En notant r = cout / dev  (spread + commissions, exprime en deviations) :

    gain net  = (D + T) * dev - cout
    perte nette = (S - D) * dev + cout
    p* = perte / (gain + perte)

Le resultat ne depend d'aucune donnee de marche : c'est de l'arithmetique.
Il dit combien d'edge il FAUT avant meme de parler de signal.
"""
import sys


def breakeven(D, S, T, r):
    win = (D + T) - r
    loss = (S - D) + r
    if win <= 0:
        return None                      # la cible ne couvre meme pas le cout
    return loss / (win + loss)


def table(D, S, T, ratios):
    print(f"\n  Entree a {D:g} dev sous la droite | cible {T:+g} dev | stop a {S:g} dev")
    print(f"  R:R brut = {(D + T) / (S - D):.2f} : 1")
    print(f"  {'cout/dev':>10}{'gain net':>11}{'perte nette':>13}{'R:R net':>10}{'p* requis':>12}")
    for r in ratios:
        p = breakeven(D, S, T, r)
        win, loss = (D + T) - r, (S - D) + r
        if p is None:
            print(f"  {r:>10.2f}{'—':>11}{'—':>13}{'—':>10}{'IMPOSSIBLE':>12}")
            continue
        flag = ""
        if p > 0.70:
            flag = "  <-- irrealiste"
        elif p > 0.60:
            flag = "  <-- exigeant"
        print(f"  {r:>10.2f}{win:>11.2f}{loss:>13.2f}{win / loss:>10.2f}{p * 100:>11.1f}%{flag}")


def main():
    ratios = [0.00, 0.10, 0.20, 0.30, 0.40, 0.50, 0.75, 1.00]

    print("=" * 72)
    print("  RETOUR A LA MOYENNE EN CANAL : TAUX DE REUSSITE MINIMAL")
    print("=" * 72)
    print("\n  'cout/dev' = (spread + commission) rapporte a UNE deviation du canal.")
    print("  C'est la seule grandeur qui compte : un spread de 20 points est")
    print("  negligeable dans un canal large et fatal dans un canal etroit.")

    table(2.0, 3.0, 0.0, ratios)     # touche 2 dev, cible la droite, stop 3 dev
    table(2.0, 3.0, 1.0, ratios)     # cible au-dela de la droite
    table(1.5, 2.5, 0.0, ratios)     # entree plus precoce
    table(2.0, 2.5, 0.0, ratios)     # stop serre

    print("\n" + "=" * 72)
    print("  SEUIL D'EXPLOITABILITE")
    print("=" * 72)
    print("\n  En visant p* <= 60% (deja exigeant pour un retour a la moyenne),")
    print("  le cout maximal admissible vaut :\n")
    print(f"  {'D (entree)':>12}{'S (stop)':>10}{'T (cible)':>11}{'cout/dev max':>15}")
    for D, S, T in [(2.0, 3.0, 0.0), (2.0, 3.0, 1.0), (1.5, 2.5, 0.0), (2.0, 2.5, 0.0)]:
        lo, hi = 0.0, 5.0
        for _ in range(80):
            mid = (lo + hi) / 2
            p = breakeven(D, S, T, mid)
            if p is None or p > 0.60:
                hi = mid
            else:
                lo = mid
        print(f"  {D:>12g}{S:>10g}{T:>11g}{lo:>15.3f}")

    print("\n  Lecture, dans l'ordre d'importance :")
    print()
    print("  1. VISER AU-DELA DE LA DROITE est le plus gros levier. Passer d'une")
    print("     cible sur la droite a +1 dev fait passer la tolerance de 0.80 a")
    print("     1.40 : presque le double de cout absorbable.")
    print()
    print("  2. ENTRER PROFOND compte plus que d'entrer tot. A 1.5 dev la")
    print("     tolerance tombe a 0.50, contre 0.80 a 2.0 dev. Une entree")
    print("     precoce attrape plus de signaux mais paie proportionnellement")
    print("     bien plus cher.")
    print()
    print("  3. LE STOP SERRE aide autant que l'entree profonde (1.00 contre")
    print("     0.80) -- a condition qu'il ne se fasse pas balayer, ce que ce")
    print("     calcul ne dit pas : il fixe le seuil, pas la frequence.")
    print()
    print("  La pire combinaison est entree precoce + cible sur la droite :")
    print("  au-dela de 0.50 de cout/dev elle est deja hors d'atteinte.")
    print()
    print("  Ce calcul ne dit rien du taux de reussite REEL, seulement du seuil")
    print("  a franchir. Mais il donne le filtre a implementer : refuser tout")
    print("  trade dont le rapport cout/dev depasse le seuil de sa geometrie.")


if __name__ == "__main__":
    main()
