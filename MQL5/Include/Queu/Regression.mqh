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

//--- etat d'un canal vis-a-vis du prix
#define QREG_CHANNEL_INTACT        0
#define QREG_CHANNEL_BROKEN_DOWN  -1   // pente haussiere, prix sous la bande basse
#define QREG_CHANNEL_BROKEN_UP     1   // pente baissiere, prix au-dessus de la bande haute

//+------------------------------------------------------------------+
//| Mesure de dispersion utilisee pour la largeur du canal.           |
//|                                                                   |
//| STDERR est l'erreur-type de la regression, l'estimateur standard  |
//| qui tient compte des deux parametres estimes.                     |
//|                                                                   |
//| PINE reproduit le "Linear Regression Channel" de LonesomeTheBlue. |
//| Sa boucle evalue la droite avec un decalage d'une bougie, ce qui  |
//| decale chaque residu de -pente et donne exactement                |
//|     dev = sqrt(SSres/n + pente^2)                                 |
//| La largeur du canal se trouve donc melangee a la pente : sur une  |
//| tendance propre et raide les bandes sont nettement plus larges    |
//| que la dispersion reelle, et sur une droite parfaite le canal     |
//| conserve une largeur de |pente| au lieu de se refermer.           |
//| A n'utiliser que pour coller visuellement a l'indicateur.          |
//+------------------------------------------------------------------+
enum ENUM_QREG_DEV
  {
   QREG_DEV_STDERR = 0,   // Erreur-type sqrt(SSres/(n-2)) - recommande
   QREG_DEV_POP    = 1,   // Ecart-type de population sqrt(SSres/n)
   QREG_DEV_PINE   = 2    // Compatible LonesomeTheBlue sqrt(SSres/n + pente^2)
  };

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
   double            devPop;      // ecart-type de population des residus
   double            devPine;     // dispersion au sens du script Pine
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
   out.devPop    = 0.0;
   out.devPine   = 0.0;
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

   out.r2     = (syy > 0.0) ? 1.0 - ssres / syy : 0.0;
   out.sigma  = (n > 2) ? MathSqrt(ssres / (dn - 2.0)) : 0.0;
   out.devPop = MathSqrt(ssres / dn);

   //--- forme fermee de la dispersion du script Pine : les residus y sont
   //--- tous decales de -pente, d'ou le terme en pente^2. Verifie
   //--- numeriquement contre le portage fidele de sa boucle.
   out.devPine = MathSqrt(ssres / dn + out.slope * out.slope);

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

//+------------------------------------------------------------------+
//| Modes de confirmation multi-horizon pour le retour a la moyenne.  |
//|                                                                   |
//| Le principe commun : on entre a CONTRE-tendance sur l'horizon      |
//| rapide (on achete le bas du canal) mais seulement DANS LE SENS de |
//| la tendance des horizons lents. Ce qui change d'un mode a l'autre, |
//| c'est la severite avec laquelle les horizons lents doivent         |
//| s'accorder, et donc l'arbitrage entre nombre de signaux et taux    |
//| de faux signaux.                                                   |
//+------------------------------------------------------------------+
enum ENUM_QMR_CONFIRM
  {
   QMR_CONFIRM_SIGN     = 0,  // Accord de signe des pentes lentes
   QMR_CONFIRM_SIGN_R2  = 1,  // Accord de signe + R2 minimal sur chaque
   QMR_CONFIRM_VOTE     = 2,  // Vote pondere par le R2 (accord partiel tolere)
   QMR_CONFIRM_POSITION = 3,  // Accord de signe + place restante dans le canal lent
   QMR_CONFIRM_SLOPE    = 4   // Accord de signe + amplitude minimale de la pente
  };

//+------------------------------------------------------------------+
//| Position du prix dans un canal, 0 = bande basse, 1 = bande haute. |
//| Sert a savoir s'il reste de la place avant la bande opposee.      |
//+------------------------------------------------------------------+
double QRegPositionInChannel(const QRegResult &r, const double close,
                             const double mult, const ENUM_QREG_DEV mode)
  {
   if(!r.valid)
      return 0.5;

   double band = QRegDev(r, mode) * mult;
   if(band <= 0.0)
      return 0.5;

   double lower = r.value - band;
   double pos   = (close - lower) / (2.0 * band);

   if(pos < 0.0)
      pos = 0.0;
   if(pos > 1.0)
      pos = 1.0;

   return pos;
  }

//+------------------------------------------------------------------+
//| Taux de reussite minimal d'un retour a la moyenne, compte tenu du |
//| cout. Geometrie : entree a D dev sous la droite, cible a T dev    |
//| au-dessus, stop a S dev sous la droite.                           |
//|                                                                   |
//|   gain net   = (D + T) * dev - cout                               |
//|   perte nette = (S - D) * dev + cout                              |
//|   p*         = perte / (gain + perte)                             |
//|                                                                   |
//| Retourne 1.0 quand la cible ne couvre meme pas le cout : le trade |
//| est alors perdant par construction, quel que soit le signal.      |
//+------------------------------------------------------------------+
double QRegBreakevenRate(const double dev, const double cost,
                         const double D, const double S, const double T)
  {
   if(dev <= 0.0 || S <= D)
      return 1.0;

   double win  = (D + T) * dev - cost;
   double loss = (S - D) * dev + cost;

   if(win <= 0.0 || loss <= 0.0)
      return 1.0;

   return loss / (win + loss);
  }

//+------------------------------------------------------------------+
//| Dispersion selon le mode choisi.                                  |
//+------------------------------------------------------------------+
double QRegDev(const QRegResult &r, const ENUM_QREG_DEV mode)
  {
   if(!r.valid)
      return 0.0;

   switch(mode)
     {
      case QREG_DEV_POP:
         return r.devPop;
      case QREG_DEV_PINE:
         return r.devPine;
      default:
         return r.sigma;
     }
  }

//+------------------------------------------------------------------+
//| Etat du canal, transposition directe de 'outofchannel' du script. |
//|                                                                   |
//| Le script signale une cassure quand le prix quitte le canal DU    |
//| MAUVAIS COTE : sous la bande basse en tendance haussiere, ou      |
//| au-dessus de la bande haute en tendance baissiere.                |
//+------------------------------------------------------------------+
int QRegChannelBreak(const QRegResult &r, const double close,
                     const double mult, const ENUM_QREG_DEV mode)
  {
   if(!r.valid || close <= 0.0)
      return QREG_CHANNEL_INTACT;

   double band = QRegDev(r, mode) * mult;
   if(band <= 0.0)
      return QREG_CHANNEL_INTACT;

   if(r.slope > 0.0 && close < r.value - band)
      return QREG_CHANNEL_BROKEN_DOWN;
   if(r.slope < 0.0 && close > r.value + band)
      return QREG_CHANNEL_BROKEN_UP;

   return QREG_CHANNEL_INTACT;
  }

#endif // QUEU_REGRESSION_MQH
