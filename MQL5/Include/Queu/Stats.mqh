//+------------------------------------------------------------------+
//|                                                        Stats.mqh |
//|         Queu - outillage statistique pour l'evaluation des EA    |
//|                                                                  |
//|  Contient de quoi juger une serie de rendements autrement que    |
//|  par le profit brut : moments, Sharpe, Sortino, drawdown, et     |
//|  surtout le Probabilistic / Deflated Sharpe Ratio, qui corrige   |
//|  le Sharpe du biais de tests multiples introduit par une         |
//|  optimisation (Bailey & Lopez de Prado, 2014).                   |
//+------------------------------------------------------------------+
#property copyright "Queu"

#ifndef QUEU_STATS_MQH
#define QUEU_STATS_MQH

#define QUEU_EULER_MASCHERONI 0.5772156649015329

//+------------------------------------------------------------------+
//| Fonction de repartition de la loi normale centree reduite.        |
//| Abramowitz & Stegun 26.2.17, precision ~7.5e-8.                   |
//+------------------------------------------------------------------+
double QNormCDF(const double x)
  {
   const double p  = 0.2316419;
   const double b1 = 0.319381530;
   const double b2 = -0.356563782;
   const double b3 = 1.781477937;
   const double b4 = -1.821255978;
   const double b5 = 1.330274429;

   double ax = MathAbs(x);
   double t  = 1.0 / (1.0 + p * ax);
   double phi = MathExp(-0.5 * ax * ax) / MathSqrt(2.0 * M_PI);

   double poly = t * (b1 + t * (b2 + t * (b3 + t * (b4 + t * b5))));
   double cdf  = 1.0 - phi * poly;

   return (x >= 0.0) ? cdf : 1.0 - cdf;
  }

//+------------------------------------------------------------------+
//| Quantile de la loi normale centree reduite (inverse de QNormCDF). |
//| Algorithme de Peter Acklam, erreur relative < 1.15e-9.            |
//+------------------------------------------------------------------+
double QNormInv(const double prob)
  {
   if(prob <= 0.0)
      return -DBL_MAX;
   if(prob >= 1.0)
      return DBL_MAX;

   static const double a[6] = {-3.969683028665376e+01,  2.209460984245205e+02,
                               -2.759285104469687e+02,  1.383577518672690e+02,
                               -3.066479806614716e+01,  2.506628277459239e+00};
   static const double b[5] = {-5.447609879822406e+01,  1.615858368580409e+02,
                               -1.556989798598866e+02,  6.680131188771972e+01,
                               -1.328068155288572e+01};
   static const double c[6] = {-7.784894002430293e-03, -3.223964580411365e-01,
                               -2.400758277161838e+00, -2.549732539343734e+00,
                                4.374664141464968e+00,  2.938163982698783e+00};
   static const double d[4] = { 7.784695709041462e-03,  3.224671290700398e-01,
                                2.445134137142996e+00,  3.754408661907416e+00};

   const double pLow  = 0.02425;
   const double pHigh = 1.0 - pLow;

   double q, r, x;

   if(prob < pLow)
     {
      q = MathSqrt(-2.0 * MathLog(prob));
      x = (((((c[0]*q + c[1])*q + c[2])*q + c[3])*q + c[4])*q + c[5]) /
          ((((d[0]*q + d[1])*q + d[2])*q + d[3])*q + 1.0);
     }
   else
      if(prob <= pHigh)
        {
         q = prob - 0.5;
         r = q * q;
         x = (((((a[0]*r + a[1])*r + a[2])*r + a[3])*r + a[4])*r + a[5]) * q /
             (((((b[0]*r + b[1])*r + b[2])*r + b[3])*r + b[4])*r + 1.0);
        }
      else
        {
         q = MathSqrt(-2.0 * MathLog(1.0 - prob));
         x = -(((((c[0]*q + c[1])*q + c[2])*q + c[3])*q + c[4])*q + c[5]) /
              ((((d[0]*q + d[1])*q + d[2])*q + d[3])*q + 1.0);
        }

   return x;
  }

//+------------------------------------------------------------------+
//| Moments d'une serie. skew et kurt sont les estimateurs simples ;  |
//| kurt est la kurtosis NON excedentaire (3.0 pour une gaussienne),  |
//| c'est la convention attendue par la formule du PSR.               |
//+------------------------------------------------------------------+
bool QMoments(const double &x[], double &mean, double &sd, double &skew, double &kurt)
  {
   int n = ArraySize(x);
   mean = sd = skew = 0.0;
   kurt = 3.0;

   if(n < 2)
      return false;

   double s = 0.0;
   for(int i = 0; i < n; i++)
      s += x[i];
   mean = s / n;

   double m2 = 0.0, m3 = 0.0, m4 = 0.0;
   for(int i = 0; i < n; i++)
     {
      double d  = x[i] - mean;
      double d2 = d * d;
      m2 += d2;
      m3 += d2 * d;
      m4 += d2 * d2;
     }

   //--- ecart-type d'echantillon (n-1) pour le Sharpe
   sd = MathSqrt(m2 / (n - 1));
   if(sd <= 0.0)
      return false;

   //--- moments centres en population (n) pour skew / kurtosis
   double var = m2 / n;
   double sdp = MathSqrt(var);
   if(sdp <= 0.0)
      return false;

   skew = (m3 / n) / (sdp * sdp * sdp);
   kurt = (m4 / n) / (var * var);

   return true;
  }

//+------------------------------------------------------------------+
//| Sharpe par observation (non annualise).                           |
//+------------------------------------------------------------------+
double QSharpe(const double &x[])
  {
   double mean, sd, skew, kurt;
   if(!QMoments(x, mean, sd, skew, kurt))
      return 0.0;
   return mean / sd;
  }

//+------------------------------------------------------------------+
//| Sortino par observation : ne penalise que la volatilite baissiere.|
//+------------------------------------------------------------------+
double QSortino(const double &x[], const double target = 0.0)
  {
   int n = ArraySize(x);
   if(n < 2)
      return 0.0;

   double mean = 0.0;
   for(int i = 0; i < n; i++)
      mean += x[i];
   mean /= n;

   double dd = 0.0;
   int    cnt = 0;
   for(int i = 0; i < n; i++)
      if(x[i] < target)
        {
         double d = x[i] - target;
         dd += d * d;
         cnt++;
        }

   if(cnt == 0)
      return 0.0;                    // aucune observation baissiere : non defini

   double downside = MathSqrt(dd / n);
   if(downside <= 0.0)
      return 0.0;

   return (mean - target) / downside;
  }

//+------------------------------------------------------------------+
//| Probabilistic Sharpe Ratio.                                       |
//| Probabilite que le vrai Sharpe depasse 'benchmark', compte tenu   |
//| de la taille d'echantillon, de l'asymetrie et des queues.         |
//| Une serie tres asymetrique a gauche ou a queues epaisses voit son |
//| Sharpe fortement deprecie : exactement le profil d'une strategie  |
//| qui encaisse de petits gains puis une grosse perte.               |
//+------------------------------------------------------------------+
double QProbabilisticSharpe(const double &x[], const double benchmark)
  {
   int n = ArraySize(x);
   if(n < 3)
      return 0.0;

   double mean, sd, skew, kurt;
   if(!QMoments(x, mean, sd, skew, kurt))
      return 0.0;

   double sr = mean / sd;

   //--- variance asymptotique de l'estimateur du Sharpe
   double denom = 1.0 - skew * sr + ((kurt - 1.0) / 4.0) * sr * sr;
   if(denom <= 0.0)
      return 0.0;

   double z = (sr - benchmark) * MathSqrt((double)(n - 1)) / MathSqrt(denom);
   return QNormCDF(z);
  }

//+------------------------------------------------------------------+
//| Seuil de Sharpe attendu sous l'hypothese nulle quand on a teste   |
//| 'trials' jeux de parametres. C'est le maximum qu'on obtiendrait   |
//| par pure chance en optimisant : tout Sharpe en dessous n'est pas  |
//| une decouverte, c'est du bruit selectionne.                       |
//|                                                                   |
//| trialsSharpeSD : ecart-type des Sharpe observes entre les passes  |
//| d'optimisation. Voir le README pour le protocole en deux passes.  |
//+------------------------------------------------------------------+
double QExpectedMaxSharpe(const int trials, const double trialsSharpeSD)
  {
   if(trials < 2 || trialsSharpeSD <= 0.0)
      return 0.0;

   double t = (double)trials;
   double g = QUEU_EULER_MASCHERONI;

   double z1 = QNormInv(1.0 - 1.0 / t);
   double z2 = QNormInv(1.0 - 1.0 / (t * M_E));

   return trialsSharpeSD * ((1.0 - g) * z1 + g * z2);
  }

//+------------------------------------------------------------------+
//| Deflated Sharpe Ratio : le PSR mesure contre le seuil de tests    |
//| multiples plutot que contre zero. C'est la valeur a maximiser en  |
//| optimisation si l'objectif est de tenir hors echantillon.         |
//+------------------------------------------------------------------+
double QDeflatedSharpe(const double &x[], const int trials, const double trialsSharpeSD)
  {
   double benchmark = QExpectedMaxSharpe(trials, trialsSharpeSD);
   return QProbabilisticSharpe(x, benchmark);
  }

//+------------------------------------------------------------------+
//| Drawdown maximal relatif d'une courbe d'equity reconstituee en    |
//| composant les rendements.                                         |
//+------------------------------------------------------------------+
double QMaxDrawdownFromReturns(const double &r[])
  {
   int n = ArraySize(r);
   if(n < 1)
      return 0.0;

   double equity = 1.0, peak = 1.0, maxDD = 0.0;
   for(int i = 0; i < n; i++)
     {
      equity *= (1.0 + r[i]);
      if(equity > peak)
         peak = equity;
      if(peak > 0.0)
        {
         double dd = (peak - equity) / peak;
         if(dd > maxDD)
            maxDD = dd;
        }
     }
   return maxDD;
  }

//+------------------------------------------------------------------+
//| Ratio d'efficience de Kaufman sur les 'period' dernieres bougies. |
//|                                                                   |
//|   ER = |variation nette| / somme des variations absolues          |
//|                                                                   |
//| Borne dans [0, 1] : 1 = mouvement parfaitement directionnel,      |
//| 0 = bruit pur. Discrimine mieux tendance et range que l'ADX,      |
//| qui reagit avec retard et sature en forte volatilite.             |
//+------------------------------------------------------------------+
double QEfficiencyRatio(const string sym, const ENUM_TIMEFRAMES tf,
                        const int period, const int shift = 1)
  {
   if(period < 2)
      return 0.0;

   double c[];
   if(CopyClose(sym, tf, shift, period + 1, c) != period + 1)
      return 0.0;

   //--- CopyClose remplit du plus ancien au plus recent
   int last = ArraySize(c) - 1;
   double net = MathAbs(c[last] - c[0]);

   double path = 0.0;
   for(int i = 1; i <= last; i++)
      path += MathAbs(c[i] - c[i - 1]);

   if(path <= 0.0)
      return 0.0;

   return net / path;
  }

#endif // QUEU_STATS_MQH
