//+------------------------------------------------------------------+
//|                                                        Utils.mqh |
//|              Queu - helpers partages par les EA du parc          |
//+------------------------------------------------------------------+
#property copyright "Queu"
#property strict

#ifndef QUEU_UTILS_MQH
#define QUEU_UTILS_MQH

//+------------------------------------------------------------------+
//| Nombre de decimales implique par le pas de volume du symbole.     |
//+------------------------------------------------------------------+
int QVolumeDigits(const string sym)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;

   int d = 0;
   while(step < 1.0 && d < 8)
     {
      step *= 10.0;
      d++;
     }
   return d;
  }

//+------------------------------------------------------------------+
//| Aligne un volume sur le pas du broker.                            |
//| Retourne 0.0 si le volume tombe sous le minimum : a l'appelant de |
//| decider s'il force le lot minimum ou s'il saute le trade.         |
//+------------------------------------------------------------------+
double QNormalizeVolume(const string sym, double vol)
  {
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   // epsilon : evite qu'un 0.9999999 se plancher a 0.99
   vol = MathFloor(vol / step + 1e-7) * step;
   vol = NormalizeDouble(vol, QVolumeDigits(sym));

   if(vol > vmax)
      vol = vmax;
   if(vol < vmin)
      return 0.0;

   return vol;
  }

//+------------------------------------------------------------------+
//| Arrondit un prix sur la grille de ticks du symbole.               |
//+------------------------------------------------------------------+
double QNormalizePrice(const string sym, const double price)
  {
   double tick = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      return NormalizeDouble(price, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));

   return NormalizeDouble(MathRound(price / tick) * tick,
                          (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
  }

//+------------------------------------------------------------------+
//| Distance minimale (en prix) autorisee entre le marche et un stop. |
//| Prend le max entre stops level et freeze level.                   |
//+------------------------------------------------------------------+
double QMinStopDistance(const string sym)
  {
   long stops  = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   long lvl    = MathMax(stops, freeze);
   return (double)lvl * SymbolInfoDouble(sym, SYMBOL_POINT);
  }

//+------------------------------------------------------------------+
//| Spread courant en points.                                         |
//+------------------------------------------------------------------+
double QSpreadPoints(const string sym)
  {
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   return (ask - bid) / point;
  }

//+------------------------------------------------------------------+
//| Detection de nouvelle bougie. 'last' est conserve par l'appelant. |
//+------------------------------------------------------------------+
bool QIsNewBar(const string sym, const ENUM_TIMEFRAMES tf, datetime &last)
  {
   datetime t = (datetime)iTime(sym, tf, 0);
   if(t == 0 || t == last)
      return false;

   last = t;
   return true;
  }

//+------------------------------------------------------------------+
//| Heure d'une fenetre de session, gestion du passage a minuit.      |
//| from == to  ->  session ouverte 24h.                              |
//+------------------------------------------------------------------+
bool QHourInWindow(const int hour, const int from, const int to)
  {
   if(from == to)
      return true;
   if(from < to)
      return (hour >= from && hour < to);

   // fenetre qui traverse minuit, ex. 22 -> 6
   return (hour >= from || hour < to);
  }

#endif // QUEU_UTILS_MQH
