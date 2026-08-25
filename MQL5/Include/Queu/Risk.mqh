//+------------------------------------------------------------------+
//|                                                         Risk.mqh |
//|      Queu - dimensionnement des positions et garde-fous de compte |
//+------------------------------------------------------------------+
#property copyright "Queu"
#property strict

#ifndef QUEU_RISK_MQH
#define QUEU_RISK_MQH

#include <Queu/Utils.mqh>

//+------------------------------------------------------------------+
//| Perte, en devise du compte, d'un lot pour une distance de stop    |
//| donnee (exprimee en prix). Retourne 0 si le symbole ne fournit    |
//| pas de tick value exploitable.                                    |
//+------------------------------------------------------------------+
double QLossPerLot(const string sym, const double slDistancePrice)
  {
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0 || slDistancePrice <= 0.0)
      return 0.0;

   return (slDistancePrice / tickSize) * tickValue;
  }

//+------------------------------------------------------------------+
//| Volume a engager pour risquer 'riskMoney' si le stop est touche.  |
//| Retourne 0.0 si le calcul est impossible ou si le resultat tombe  |
//| sous le lot minimum du broker.                                    |
//+------------------------------------------------------------------+
double QLotForRisk(const string sym, const double riskMoney, const double slDistancePrice)
  {
   double lossPerLot = QLossPerLot(sym, slDistancePrice);
   if(lossPerLot <= 0.0 || riskMoney <= 0.0)
      return 0.0;

   return QNormalizeVolume(sym, riskMoney / lossPerLot);
  }

//+------------------------------------------------------------------+
//| Garde-fou journalier : fige le trading quand l'equity a decroche  |
//| (ou atteint sa cible) par rapport au debut de la journee serveur. |
//+------------------------------------------------------------------+
class CQDailyGuard
  {
private:
   datetime          m_day;            // minuit de la journee suivie
   double            m_equityAtOpen;   // equity au premier tick de la journee
   bool              m_halted;         // seuil franchi -> plus d'ouverture
   string            m_reason;

   static datetime   DayStart(const datetime t)
     {
      MqlDateTime d;
      TimeToStruct(t, d);
      d.hour = 0;
      d.min  = 0;
      d.sec  = 0;
      return StructToTime(d);
     }

public:
                     CQDailyGuard(): m_day(0), m_equityAtOpen(0.0), m_halted(false), m_reason("") {}

   //--- a appeler a chaque tick, avant toute decision d'entree
   void              Refresh(const datetime now)
     {
      datetime today = DayStart(now);
      if(today != m_day)
        {
         m_day          = today;
         m_equityAtOpen = AccountInfoDouble(ACCOUNT_EQUITY);
         m_halted       = false;
         m_reason       = "";
        }
     }

   //--- maxLossPct / maxProfitPct : 0 desactive le garde-fou
   void              Evaluate(const double maxLossPct, const double maxProfitPct)
     {
      if(m_halted || m_equityAtOpen <= 0.0)
         return;

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double pct    = (equity - m_equityAtOpen) / m_equityAtOpen * 100.0;

      if(maxLossPct > 0.0 && pct <= -maxLossPct)
        {
         m_halted = true;
         m_reason = StringFormat("perte journaliere %.2f%% <= -%.2f%%", pct, maxLossPct);
        }
      else
         if(maxProfitPct > 0.0 && pct >= maxProfitPct)
           {
            m_halted = true;
            m_reason = StringFormat("objectif journalier %.2f%% >= %.2f%%", pct, maxProfitPct);
           }
     }

   bool              Halted()       const { return m_halted; }
   string            Reason()       const { return m_reason; }
   double            EquityAtOpen() const { return m_equityAtOpen; }
  };

//+------------------------------------------------------------------+
//| Sizing adaptatif.                                                 |
//|                                                                   |
//| Deux mecanismes distincts, tous deux orientes vers la croissance  |
//| geometrique du capital plutot que vers l'esperance par trade :    |
//|                                                                   |
//| 1. Kelly fractionnaire estime sur une fenetre glissante de        |
//|    resultats en R. Dans ce montage, la fraction de Kelly est      |
//|    DIRECTEMENT le pourcentage d'equity a risquer : un trade perd  |
//|    exactement le montant risque quand le stop est touche, ce qui  |
//|    est l'hypothese du pari de Kelly.                              |
//|      f* = p - (1 - p) / b,  b = gain moyen / perte moyenne en R   |
//|    Le plein Kelly est inexploitable en pratique : p et b sont     |
//|    estimes, et une surestimation mene a la ruine. On applique     |
//|    donc une fraction (0.25 par defaut) et un plafond dur.         |
//|                                                                   |
//| 2. Throttle de drawdown : reduction lineaire du risque quand      |
//|    l'equity decroche de son plus haut. Reduit la profondeur des   |
//|    creux, au prix d'une reprise plus lente.                       |
//+------------------------------------------------------------------+
class CQAdaptiveRisk
  {
private:
   double            m_r[];          // resultats recents, en multiples de R
   int               m_window;
   double            m_peakEquity;

public:
                     CQAdaptiveRisk(): m_window(50), m_peakEquity(0.0) {}

   void              Init(const int window)
     {
      m_window = (int)MathMax(2.0, (double)window);
      ArrayResize(m_r, 0);
      m_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
     }

   int               Count(void) const { return ArraySize(m_r); }

   //--- empile un resultat ; la fenetre glisse par la gauche
   void              PushR(const double r)
     {
      int n = ArraySize(m_r);
      if(n < m_window)
        {
         ArrayResize(m_r, n + 1);
         m_r[n] = r;
         return;
        }

      for(int i = 0; i < n - 1; i++)
         m_r[i] = m_r[i + 1];
      m_r[n - 1] = r;
     }

   //--- p = taux de reussite, b = ratio gain/perte moyens, f = Kelly plein
   bool              KellyStats(double &p, double &b, double &f) const
     {
      p = b = f = 0.0;

      int n = ArraySize(m_r);
      if(n < 2)
         return false;

      double sumWin = 0.0, sumLoss = 0.0;
      int    nWin = 0, nLoss = 0;

      for(int i = 0; i < n; i++)
        {
         if(m_r[i] > 0.0)
           {
            sumWin += m_r[i];
            nWin++;
           }
         else
           {
            sumLoss += MathAbs(m_r[i]);
            nLoss++;
           }
        }

      if(nWin == 0 || nLoss == 0)
         return false;                  // pas de quoi estimer un ratio

      double avgWin  = sumWin / nWin;
      double avgLoss = sumLoss / nLoss;
      if(avgLoss <= 0.0)
         return false;

      p = (double)nWin / (double)n;
      b = avgWin / avgLoss;
      f = p - (1.0 - p) / b;

      return true;
     }

   //--- multiplicateur de risque lie au drawdown courant
   double            DrawdownMultiplier(const double ddStartPct, const double ddFullPct,
                                        const double minMultiple)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > m_peakEquity)
         m_peakEquity = equity;

      if(m_peakEquity <= 0.0 || ddStartPct <= 0.0 || ddFullPct <= ddStartPct)
         return 1.0;

      double ddPct = (m_peakEquity - equity) / m_peakEquity * 100.0;

      if(ddPct <= ddStartPct)
         return 1.0;
      if(ddPct >= ddFullPct)
         return minMultiple;

      //--- interpolation lineaire entre les deux seuils
      double t = (ddPct - ddStartPct) / (ddFullPct - ddStartPct);
      return 1.0 - t * (1.0 - minMultiple);
     }

   //--- pourcentage d'equity a risquer sur le prochain trade
   double            RiskPercent(const double basePct,
                                 const bool   useKelly,
                                 const double kellyFraction,
                                 const int    minSamples,
                                 const double minMultiple,
                                 const double maxMultiple,
                                 const bool   useDDThrottle,
                                 const double ddStartPct,
                                 const double ddFullPct,
                                 const double ddMinMultiple)
     {
      double risk = basePct;

      if(useKelly && Count() >= minSamples)
        {
         double p, b, f;
         if(KellyStats(p, b, f))
           {
            if(f <= 0.0)
              {
               //--- l'edge recent est nul ou negatif : on ne coupe pas le
               //--- trading (l'echantillon est court) mais on reduit au plancher
               risk = basePct * minMultiple;
              }
            else
              {
               risk = 100.0 * kellyFraction * f;
               risk = MathMax(basePct * minMultiple,
                              MathMin(basePct * maxMultiple, risk));
              }
           }
        }

      if(useDDThrottle)
         risk *= DrawdownMultiplier(ddStartPct, ddFullPct, ddMinMultiple);

      return MathMax(0.0, risk);
     }
  };

#endif // QUEU_RISK_MQH
