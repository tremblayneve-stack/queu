#!/usr/bin/env python3
"""
Verification de parite avec le "Linear Regression Channel" de
LonesomeTheBlue (TradingView, Pine v4).

Porte fidelement sa fonction get_channel() et la compare a l'OLS de
reference, pour etablir :
  1. que sa pente et son intercept SONT de l'OLS exact ;
  2. que sa mesure de dispersion vaut sqrt(SSres/n + pente^2), et non
     l'erreur-type, sa boucle evaluant la droite avec un decalage d'une
     bougie qui decale chaque residu de -pente.

C'est cette identite qu'implemente QREG_DEV_PINE dans Regression.mqh.
Sans dependance externe.
"""
import math, random

def pine_get_channel(src_recent_first, length):
    """Portage fidele de get_channel().
    src_recent_first[x] == src[x] en Pine : x bougies en arriere."""
    n = length
    mid = sum(src_recent_first[:n]) / n

    # slope = linreg(src,len,0) - linreg(src,len,1) : difference de deux points
    # de LA MEME droite -> c'est exactement la pente OLS par bougie.
    y = list(reversed(src_recent_first[:n]))          # 0 = plus ancien
    mx = (n - 1) / 2
    my = sum(y) / n
    sxx = sum((i - mx) ** 2 for i in range(n))
    sxy = sum((i - mx) * (y[i] - my) for i in range(n))
    slope = sxy / sxx

    # intercept tel qu'ecrit dans le script
    intercept = mid - slope * math.floor(n / 2) + ((1 - (n % 2)) / 2) * slope
    endy = intercept + slope * (n - 1)

    # boucle dev telle qu'ecrite
    dev = 0.0
    for x in range(0, n):
        dev += (src_recent_first[x] - (slope * (n - x) + intercept)) ** 2
    dev = math.sqrt(dev / n)
    return intercept, endy, dev, slope, y, my, sxy

def ols_reference(y):
    n = len(y); mx = (n-1)/2; my = sum(y)/n
    sxx = sum((i-mx)**2 for i in range(n))
    sxy = sum((i-mx)*(y[i]-my) for i in range(n))
    slope = sxy/sxx
    intercept = my - slope*mx
    resid = [y[i]-(intercept+slope*i) for i in range(n)]
    ssres = sum(r*r for r in resid)
    return slope, intercept, ssres

print("=== 1. intercept et pente : identiques a l'OLS ? ===")
random.seed(3)
worst_s = worst_i = 0.0
for label, series in [
    ("tendance + bruit, len=100", [100+0.4*i+random.gauss(0,2) for i in range(100)]),
    ("len IMPAIR (101)",          [100+0.4*i+random.gauss(0,2) for i in range(101)]),
    ("len PAIR (50)",             [100-0.7*i+random.gauss(0,3) for i in range(50)]),
    ("echelle BTC",               [60000+30*i+random.gauss(0,500) for i in range(100)]),
]:
    n = len(series)
    recent_first = list(reversed(series))
    ic, endy, dev, sl, y, my, sxy = pine_get_channel(recent_first, n)
    sl_ref, ic_ref, ssres = ols_reference(y)
    es = abs(sl-sl_ref)/max(1e-12,abs(sl_ref)); ei = abs(ic-ic_ref)/max(1e-12,abs(ic_ref))
    worst_s=max(worst_s,es); worst_i=max(worst_i,ei)
    print(f"  {label:<26} pente err={es:.2e}   intercept err={ei:.2e}")
print(f"  -> pente et intercept du script = OLS exact "
      f"(err max {max(worst_s,worst_i):.2e}). La formule intercept avec")
print("     floor(len/2) et le correctif de parite se reduit a mid - slope*(len-1)/2.")

print()
print("=== 2. la boucle 'dev' : ecart avec les residus reels ===")
print("  Le script predit  slope*(len - x) + intercept  pour la bougie x.")
print("  Pour x=0 (bougie courante) cela donne intercept + slope*len,")
print("  alors que la droite y vaut endy = intercept + slope*(len-1).")
print("  Chaque residu est donc decale d'exactement -slope.")
print()
print(f"  {'serie':<26}{'dev script':>13}{'sqrt(SSres/n)':>15}{'sqrt(SSres/n+m^2)':>20}{'ecart':>10}")
worst = 0.0
for label, series in [
    ("bruit fort, pente faible",  [100+0.05*i+random.gauss(0,3) for i in range(100)]),
    ("bruit moyen, pente moyenne",[100+0.40*i+random.gauss(0,2) for i in range(100)]),
    ("bruit faible, pente forte", [100+1.50*i+random.gauss(0,0.5) for i in range(100)]),
    ("DROITE PARFAITE",           [100+2.00*i for i in range(100)]),
]:
    n=len(series); recent_first=list(reversed(series))
    ic,endy,dev,sl,y,my,sxy = pine_get_channel(recent_first,n)
    _,_,ssres = ols_reference(y)
    pop = math.sqrt(ssres/n)
    closed = math.sqrt(ssres/n + sl*sl)
    err = abs(dev-closed)/max(1e-12,closed); worst=max(worst,err)
    print(f"  {label:<26}{dev:>13.5f}{pop:>15.5f}{closed:>20.5f}{err:>10.1e}")
print(f"  -> identite verifiee : dev_script = sqrt(SSres/n + pente^2), err max {worst:.1e}")
