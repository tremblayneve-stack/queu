//+------------------------------------------------------------------+
//|                                                   Regression.mqh |
//|        Queu - chaine de regressions lineaires embointees         |
//|                                                                  |
//|  Une regression OLS sur les cloture fournit trois informations    |
//|  d'un seul calcul :                                              |
//|    - la pente      : direction et vitesse du regime              |
//|    - le R2         : quelle fraction du mouvement est lineaire    |
//|                      plutot que du bruit                          |
//|    - sigma         : ecart-type des residus, c'est-a-dire la      |
//|                      volatilite AUTOUR DE LA TENDANCE et non      |
//|                      l'amplitude absolue du prix                  |
//|                                                                  |
//|  La "chaine" est un faisceau de ces regressions sur une echelle   |
//|  geometrique (N, 2N, 4N, 8N), toutes se terminant sur la meme     |
//|  bougie. L'accord des pentes definit le regime ; sigma de la      |
//|  fenetre courte sert au timing et au placement du stop.           |
//+------------------------------------------------------------------+
#property copyright "Queu"

#ifndef QUEU_REGRESSION_MQH
#define QUEU_REGRESSION_MQH

#define QUEU_REG_RUNGS 4

//+------------------------------------------------------------------+
//| Resultat d'une regression sur une fenetre.                        |
//+------------------------------------------------------------------+
struct QRegResult
  {
   bool              valid;
   int               period;
   double            slope;       // prix par bougie
   double            intercept;
   double            r2;          // dans [0, 1]
   double            sigma;       // erreur-type des residus, en prix
   double            value;       // droite evaluee sur la bougie la plus recente
   double            slopeATR;    // pente normalisee : ATR parcourus par fenetre
  };

//+------------------------------------------------------------------+
//| Regression OLS des cloture sur 'period' bougies se terminant a    |
//| 'shift'. L'abscisse est l'indice 0..n-1 du plus ancien au plus    |
//| recent, ce qui rend la pente directement orientee dans le sens du |
//| temps.                                                            |
//|                                                                   |
//| slopeATR normalise la pente en "ATR par fenetre" : sans cela les  |
//| pentes ne sont comparables ni entre echelles, ni entre l'or et    |
//| le BTC.                                                           |
//+------------------------------------------------------------------+
bool QRegress(const string sym, const ENUM_TIMEFRAMES tf,
              const int period, const int shift,
              const double atr, QRegResult &out)
  {
   out.valid     = false;
   out.period    = period;
   out.slope     = 0.0;
   out.intercept = 0.0;
   out.r2        = 0.0;
   out.sigma     = 0.0;
   out.value     = 0.0;
   out.slopeATR  = 0.0;

   if(period < 3)
      return false;

   double y[];
   if(CopyClose(sym, tf, shift, period, y) != period)
      return false;

   int    n  = period;
   double dn = (double)n;

   //--- x = 0..n-1 : moyenne et somme des carres connues en forme fermee
   double mx  = (dn - 1.0) / 2.0;
   double sxx = dn * (dn * dn - 1.0) / 12.0;
   if(sxx <= 0.0)
      return false;

   double my = 0.0;
   for(int i = 0; i < n; i++)
      my += y[i];
   my /= dn;

   double sxy = 0.0, syy = 0.0;
   for(int i = 0; i < n; i++)
     {
      double dy = y[i] - my;
      sxy += ((double)i - mx) * dy;
      syy += dy * dy;
     }

   out.slope     = sxy / sxx;
   out.intercept = my - out.slope * mx;

   //--- droite evaluee sur la bougie la plus recente de la fenetre
   out.value = out.intercept + out.slope * (dn - 1.0);

   //--- somme des carres residuels par decomposition : SSres = Syy - b*Sxy
   double ssres = syy - out.slope * sxy;
   if(ssres < 0.0)
      ssres = 0.0;                       // garde-fou contre l'erreur d'arrondi

   out.r2    = (syy > 0.0) ? 1.0 - ssres / syy : 0.0;
   out.sigma = (n > 2) ? MathSqrt(ssres / (dn - 2.0)) : 0.0;

   if(out.r2 < 0.0)
      out.r2 = 0.0;
   if(out.r2 > 1.0)
      out.r2 = 1.0;

   if(atr > 0.0)
      out.slopeATR = out.slope * dn / atr;

   out.valid = true;
   return true;
  }

//+------------------------------------------------------------------+
//| Faisceau de regressions sur une echelle geometrique N, 2N, 4N, 8N.|
//| L'echelon 0 est le plus court (timing), l'echelon 3 le plus long  |
//| (regime de fond).                                                 |
//+------------------------------------------------------------------+
struct QRegChain
  {
   bool              valid;
   QRegResult        rung[QUEU_REG_RUNGS];
  };

bool QRegChainCompute(const string sym, const ENUM_TIMEFRAMES tf,
                      const int basePeriod, const int shift,
                      const double atr, QRegChain &out)
  {
   out.valid = false;
   if(basePeriod < 3)
      return false;

   int period = basePeriod;
   for(int k = 0; k < QUEU_REG_RUNGS; k++)
     {
      if(!QRegress(sym, tf, period, shift, atr, out.rung[k]))
         return false;
      period *= 2;
     }

   out.valid = true;
   return true;
  }

//+------------------------------------------------------------------+
//| Regime issu des echelons 'from' a 3 : +1 haussier, -1 baissier,   |
//| 0 si les pentes ne s'accordent pas.                               |
//|                                                                   |
//| L'echelon court est volontairement exclu par defaut : pendant un  |
//| repli, sa pente s'inverse alors que le regime de fond tient       |
//| toujours. C'est precisement ce repli que l'on cherche a acheter.  |
//+------------------------------------------------------------------+
int QRegChainBias(const QRegChain &chain, const int from,
                  const double minSlopeATR, const double minR2)
  {
   if(!chain.valid || from < 0 || from >= QUEU_REG_RUNGS)
      return 0;

   int sign = 0;
   for(int k = from; k < QUEU_REG_RUNGS; k++)
     {
      if(!chain.rung[k].valid)
         return 0;

      int s = (chain.rung[k].slope > 0.0) ? 1 : ((chain.rung[k].slope < 0.0) ? -1 : 0);
      if(s == 0)
         return 0;

      if(sign == 0)
         sign = s;
      else
         if(s != sign)
            return 0;                    // desaccord : pas de regime net
     }

   //--- qualite et amplitude jugees sur l'echelon le plus long
   const QRegResult longest = chain.rung[QUEU_REG_RUNGS - 1];

   if(minR2 > 0.0 && longest.r2 < minR2)
      return 0;
   if(minSlopeATR > 0.0 && MathAbs(longest.slopeATR) < minSlopeATR)
      return 0;

   return sign;
  }

#endif // QUEU_REGRESSION_MQH
