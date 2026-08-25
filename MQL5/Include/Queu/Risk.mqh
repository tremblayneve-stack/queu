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

#endif // QUEU_RISK_MQH
