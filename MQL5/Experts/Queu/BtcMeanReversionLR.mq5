//+------------------------------------------------------------------+
//|                                           BtcMeanReversionLR.mq5 |
//|                                                             Queu |
//|                                                                  |
//|  Mean reversion sur BTCUSD M5.                                   |
//|                                                                  |
//|  Fade d'une impulsion sur-etendue : le prix s'ecarte de l'EMA 20 |
//|  de plus de N ATR ET touche une bande d'un canal de regression   |
//|  lineaire, sur une bougie directionnelle forte. On prend le      |
//|  contre-pied, cible le retour vers la mediane.                   |
//|                                                                  |
//|  Fichier AUTONOME : la regression lineaire est calculee dans     |
//|  l'EA, aucun indicateur custom n'est requis.                     |
//|                                                                  |
//|  AVERTISSEMENT : une strategie de retour a la moyenne encaisse   |
//|  ses pires pertes exactement quand le BTC part en tendance forte,|
//|  ou la bande superieure se fait chevaucher pendant des heures.   |
//|  Le filtre de pente (InpMaxSlopeATR) existe pour ca. Ne pas le   |
//|  desactiver sans avoir mesure ce que ca coute.                   |
//+------------------------------------------------------------------+
#property copyright "Queu"
#property link      "https://github.com/tremblayneve-stack/queu"
#property version   "1.00"
#property description "Mean reversion BTCUSD M5 : EMA 20 + canal de regression lineaire"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Parametres                                                        |
//+------------------------------------------------------------------+
input group "=== Indicateurs ==="
input int    InpEMA_Period      = 20;      // EMA_Period
input int    InpLR_Period       = 100;     // LR_Period (longueur de la regression)
input double InpLR_Deviation    = 2.0;     // LR_Deviation (ecarts-types des bandes)
input int    InpATR_Period      = 14;      // ATR_Period

input group "=== Conditions d'entree ==="
input double InpATR_Multiplier  = 1.4;     // ATR_Multiplier (ecart min a l'EMA)
input double InpMinBodyRatio    = 0.55;    // Corps / amplitude min de la bougie
input double InpMinBodyATR      = 0.60;    // Corps min en multiples d'ATR
input bool   InpRequireBreak    = false;   // true = cassure stricte, false = touche suffit
input double InpMaxSlopeATR     = 3.0;     // Pente max du canal, ATR/fenetre (0 = filtre off)

input group "=== Sorties ==="
input int    InpImpulseLookback = 3;       // Bougies definissant l'extreme de l'impulsion
input double InpSL_BufferATR    = 0.50;    // Marge du stop au-dela de l'extreme (x ATR)
input double InpMinRR           = 0.80;    // Ratio gain/risque minimal exige
input bool   InpUseTrailing     = true;    // Trailing leger une fois en profit
input double InpTrailStartATR   = 1.00;    // Declenche le trailing a X ATR de gain
input double InpTrailDistATR    = 1.50;    // Distance du trailing (x ATR)
input int    InpMaxBarsInTrade  = 0;       // Time-stop en bougies (0 = desactive)

input group "=== Risque et execution ==="
input double InpRiskPercent     = 0.5;     // RiskPercent (% du balance)
input double InpMaxSpreadPoints = 300;     // MaxSpreadPoints (0 = filtre off)
input ulong  InpMagicNumber     = 880501;  // MagicNumber
input ulong  InpSlippage        = 100;     // Slippage (points)
input bool   InpEnableTrading   = true;    // EnableTrading
input bool   InpVerboseLog      = true;    // Logs detailles

//+------------------------------------------------------------------+
//| Etat global                                                       |
//+------------------------------------------------------------------+
CTrade   g_trade;

int      g_hEMA = INVALID_HANDLE;
int      g_hATR = INVALID_HANDLE;

datetime g_lastBarTime = 0;
double   g_point       = 0.0;
int      g_digits      = 0;

//--- resultat du canal de regression lineaire
struct LRChannel
  {
   bool     valid;
   double   slope;       // prix par bougie
   double   intercept;
   double   mid;         // droite evaluee sur la bougie 1
   double   upper;
   double   lower;
   double   dev;         // ecart-type des residus, en prix
   double   r2;          // qualite de l'ajustement, [0, 1]
   double   slopeATR;    // pente normalisee : ATR parcourus par fenetre
  };

//--- description d'un signal, pour separer detection et execution
struct Signal
  {
   bool     valid;
   int      dir;         // +1 achat, -1 vente
   double   entry;
   double   sl;
   double   tp;
   double   rr;
   string   reason;
  };

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 1 — CANAL DE REGRESSION LINEAIRE                        |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Regression lineaire par moindres carres sur les clotures des      |
//| bougies [1 .. period], la bougie 0 etant exclue : elle n'est pas  |
//| terminee, l'inclure introduirait un look-ahead bias.              |
//|                                                                   |
//| L'abscisse est l'indice 0..n-1 du plus ancien au plus recent, si  |
//| bien que la pente est directement orientee dans le sens du temps. |
//| Les sommes en x ont une forme fermee :                            |
//|     moyenne(x) = (n-1)/2        Sxx = n(n^2-1)/12                 |
//| ce qui evite une boucle et toute accumulation d'erreur.           |
//|                                                                   |
//| La demi-largeur des bandes est l'ecart-type des RESIDUS, calcule  |
//| par decomposition SSres = Syy - pente * Sxy : c'est la dispersion |
//| autour de la droite, et non l'amplitude du prix.                  |
//+------------------------------------------------------------------+
bool ComputeLRChannel(const int period, const double atr, LRChannel &ch)
  {
   ch.valid = false;

   if(period < 3)
      return false;

   double y[];
   if(CopyClose(_Symbol, _Period, 1, period, y) != period)
     {
      if(InpVerboseLog)
         PrintFormat("[LR] CopyClose insuffisant (%d bougies demandees).", period);
      return false;
     }

   const double n  = (double)period;
   const double mx = (n - 1.0) / 2.0;
   const double sxx = n * (n * n - 1.0) / 12.0;

   if(sxx <= 0.0)
      return false;

   double my = 0.0;
   for(int i = 0; i < period; i++)
      my += y[i];
   my /= n;

   double sxy = 0.0, syy = 0.0;
   for(int i = 0; i < period; i++)
     {
      const double dy = y[i] - my;
      sxy += ((double)i - mx) * dy;
      syy += dy * dy;
     }

   ch.slope     = sxy / sxx;
   ch.intercept = my - ch.slope * mx;

   //--- la droite evaluee sur la bougie 1, la plus recente de la fenetre
   ch.mid = ch.intercept + ch.slope * (n - 1.0);

   double ssres = syy - ch.slope * sxy;
   if(ssres < 0.0)
      ssres = 0.0;                          // garde-fou contre l'arrondi

   ch.dev = MathSqrt(ssres / n);
   ch.r2  = (syy > 0.0) ? 1.0 - ssres / syy : 0.0;
   ch.r2  = MathMax(0.0, MathMin(1.0, ch.r2));

   ch.upper = ch.mid + InpLR_Deviation * ch.dev;
   ch.lower = ch.mid - InpLR_Deviation * ch.dev;

   //--- pente normalisee : sans cela, aucun seuil n'est transposable
   //--- d'un instrument ou d'un regime de volatilite a l'autre
   ch.slopeATR = (atr > 0.0) ? ch.slope * n / atr : 0.0;

   ch.valid = (ch.dev > 0.0);
   return ch.valid;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 2 — DETECTION DU SIGNAL                                 |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Lit une valeur unique d'un buffer d'indicateur.                   |
//+------------------------------------------------------------------+
bool ReadBuffer(const int handle, const int shift, double &out)
  {
   double tmp[];
   if(CopyBuffer(handle, 0, shift, 1, tmp) != 1)
      return false;
   out = tmp[0];
   return (out != EMPTY_VALUE && out != 0.0);
  }

//+------------------------------------------------------------------+
//| Une bougie directionnelle forte : corps dominant l'amplitude ET   |
//| corps significatif face a l'ATR. Les deux conditions sont         |
//| necessaires : un grand corps sur une bougie minuscule ne dit      |
//| rien, un gros corps noye dans des meches non plus.                |
//+------------------------------------------------------------------+
bool StrongCandle(const int shift, const double atr, const int wantDir, string &desc)
  {
   const double o = iOpen(_Symbol, _Period, shift);
   const double c = iClose(_Symbol, _Period, shift);
   const double h = iHigh(_Symbol, _Period, shift);
   const double l = iLow(_Symbol, _Period, shift);

   if(o <= 0.0 || c <= 0.0 || h <= 0.0 || l <= 0.0)
      return false;

   const double body  = MathAbs(c - o);
   const double range = h - l;

   if(range <= 0.0 || atr <= 0.0)
      return false;

   const int dir = (c > o) ? 1 : ((c < o) ? -1 : 0);
   if(dir != wantDir)
      return false;

   const double ratio  = body / range;
   const double bodyAtr = body / atr;

   desc = StringFormat("corps=%.1f%% de l'amplitude, %.2f ATR", ratio * 100.0, bodyAtr);

   return (ratio >= InpMinBodyRatio && bodyAtr >= InpMinBodyATR);
  }

//+------------------------------------------------------------------+
//| Extreme de l'impulsion sur les 'bars' dernieres bougies closes.   |
//+------------------------------------------------------------------+
bool ImpulseExtreme(const int bars, const bool wantHigh, double &value)
  {
   const int n = MathMax(1, bars);
   double buf[];

   const int got = wantHigh ? CopyHigh(_Symbol, _Period, 1, n, buf)
                            : CopyLow(_Symbol, _Period, 1, n, buf);
   if(got != n)
      return false;

   value = buf[0];
   for(int i = 1; i < n; i++)
      value = wantHigh ? MathMax(value, buf[i]) : MathMin(value, buf[i]);

   return true;
  }

//+------------------------------------------------------------------+
//| Detection complete du signal sur la bougie 1.                     |
//|                                                                   |
//| Sequence, dans cet ordre :                                        |
//|   1. le prix s'est ecarte de l'EMA de plus de N ATR               |
//|   2. il touche (ou casse) la bande du canal du meme cote          |
//|   3. la bougie qui l'y a porte est une impulsion directionnelle   |
//|   4. le canal n'est pas en tendance trop marquee (filtre de pente)|
//|   5. la geometrie stop / cible offre un ratio acceptable          |
//+------------------------------------------------------------------+
Signal DetectSignal(void)
  {
   Signal s;
   s.valid  = false;
   s.dir    = 0;
   s.entry  = 0.0;
   s.sl     = 0.0;
   s.tp     = 0.0;
   s.rr     = 0.0;
   s.reason = "";

   double ema, atr;
   if(!ReadBuffer(g_hEMA, 1, ema) || !ReadBuffer(g_hATR, 1, atr) || atr <= 0.0)
      return s;

   LRChannel ch;
   if(!ComputeLRChannel(InpLR_Period, atr, ch))
      return s;

   const double close1 = iClose(_Symbol, _Period, 1);
   const double high1  = iHigh(_Symbol, _Period, 1);
   const double low1   = iLow(_Symbol, _Period, 1);
   if(close1 <= 0.0)
      return s;

   //--- 1. ecart a l'EMA
   const double distance = MathAbs(close1 - ema);
   const double required = InpATR_Multiplier * atr;
   if(distance < required)
      return s;

   //--- 4. filtre de pente : en tendance marquee, fader la bande revient a
   //---    se placer devant le mouvement. C'est le mode d'echec principal
   //---    du retour a la moyenne sur BTC.
   if(InpMaxSlopeATR > 0.0 && MathAbs(ch.slopeATR) > InpMaxSlopeATR)
     {
      if(InpVerboseLog)
         PrintFormat("[SIGNAL] Ecarte : pente du canal %.2f ATR/fenetre > %.2f.",
                     ch.slopeATR, InpMaxSlopeATR);
      return s;
     }

   //--- 2. contact avec une bande, du bon cote de l'EMA
   int dir = 0;
   string bandDesc = "";

   const bool aboveEma = (close1 > ema);
   const bool touchUp  = InpRequireBreak ? (close1 > ch.upper) : (high1 >= ch.upper);
   const bool touchDn  = InpRequireBreak ? (close1 < ch.lower) : (low1  <= ch.lower);

   if(aboveEma && touchUp)
     {
      dir = -1;                             // sur-extension haussiere : on vend
      bandDesc = StringFormat("bande sup %.2f %s", ch.upper,
                              InpRequireBreak ? "cassee" : "touchee");
     }
   else
      if(!aboveEma && touchDn)
        {
         dir = 1;                           // sur-extension baissiere : on achete
         bandDesc = StringFormat("bande inf %.2f %s", ch.lower,
                                 InpRequireBreak ? "cassee" : "touchee");
        }

   if(dir == 0)
      return s;

   //--- 3. impulsion : la bougie doit aller DANS le sens de la sur-extension,
   //---    c'est elle que l'on fade. Pour une vente, on veut une bougie
   //---    haussiere forte.
   string candleDesc = "";
   if(!StrongCandle(1, atr, -dir, candleDesc))
     {
      if(InpVerboseLog)
         PrintFormat("[SIGNAL] Ecarte : impulsion insuffisante (%s).",
                     candleDesc == "" ? "sens ou forme incorrects" : candleDesc);
      return s;
     }

   //--- geometrie
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return s;

   s.entry = (dir > 0) ? ask : bid;

   //--- stop au-dela de l'extreme de l'impulsion, plus une marge d'ATR
   double extreme = 0.0;
   if(!ImpulseExtreme(InpImpulseLookback, dir < 0, extreme))
      return s;

   const double buffer = InpSL_BufferATR * atr;
   s.sl = (dir > 0) ? extreme - buffer : extreme + buffer;

   //--- cible : mediane du canal, ou EMA si elle est plus proche du prix.
   //--- Pour une vente les deux sont sous le prix : la plus proche est la
   //--- plus HAUTE des deux.
   s.tp = (dir > 0) ? MathMin(ch.mid, ema) : MathMax(ch.mid, ema);

   const double risk   = MathAbs(s.entry - s.sl);
   const double reward = MathAbs(s.tp - s.entry);

   if(risk <= 0.0 || reward <= 0.0)
     {
      if(InpVerboseLog)
         Print("[SIGNAL] Ecarte : geometrie degeneree (stop ou cible du mauvais cote).");
      return s;
     }

   //--- la cible doit etre du bon cote de l'entree
   if((dir > 0 && s.tp <= s.entry) || (dir < 0 && s.tp >= s.entry))
     {
      if(InpVerboseLog)
         Print("[SIGNAL] Ecarte : la mediane est deja depassee, plus rien a capter.");
      return s;
     }

   s.rr = reward / risk;

   //--- 5. ratio minimal. Sur ce schema le stop est souvent large et la
   //---    cible proche : sans ce filtre on risque 3 pour gagner 1.
   if(InpMinRR > 0.0 && s.rr < InpMinRR)
     {
      if(InpVerboseLog)
         PrintFormat("[SIGNAL] Ecarte : ratio %.2f < %.2f exige.", s.rr, InpMinRR);
      return s;
     }

   s.dir   = dir;
   s.valid = true;
   s.reason = StringFormat(
                 "%s | close=%.2f EMA=%.2f ecart=%.2f (%.2f ATR requis %.2f) | %s | "
                 "canal mid=%.2f dev=%.2f R2=%.2f pente=%.2f ATR/fen | impulsion %s | RR=%.2f",
                 (dir > 0 ? "ACHAT" : "VENTE"),
                 close1, ema, distance, distance / atr, required,
                 bandDesc, ch.mid, ch.dev, ch.r2, ch.slopeATR,
                 candleDesc, s.rr);

   return s;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 3 — MONEY MANAGEMENT                                    |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Aligne un volume sur le pas du broker. Retourne 0 si le resultat  |
//| tombe sous le minimum : a l'appelant de decider, plutot que de    |
//| remonter silencieusement au lot minimum et de depasser le risque. |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
  {
   const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   //--- epsilon : evite qu'un 0.999999 se plancher a 0.99
   volume = MathFloor(volume / step + 1e-8) * step;

   int decimals = 0;
   double s = step;
   while(s < 1.0 && decimals < 8)
     {
      s *= 10.0;
      decimals++;
     }
   volume = NormalizeDouble(volume, decimals);

   if(volume > vmax)
      volume = vmax;
   if(volume < vmin)
      return 0.0;

   return volume;
  }

//+------------------------------------------------------------------+
//| Volume risquant InpRiskPercent du BALANCE si le stop est touche.  |
//|                                                                   |
//| Le calcul part de la distance de stop REELLE, apres elargissement |
//| eventuel au stops level du broker : dimensionner sur la distance  |
//| theorique ferait depasser le risque annonce.                      |
//+------------------------------------------------------------------+
double CalculateLot(const double stopDistance)
  {
   if(stopDistance <= 0.0)
      return 0.0;

   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0)
     {
      Print("[RISQUE] Tick value ou tick size indisponible : dimensionnement impossible.");
      return 0.0;
     }

   const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   const double riskMoney = balance * InpRiskPercent / 100.0;

   const double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return 0.0;

   const double raw = riskMoney / lossPerLot;
   const double lot = NormalizeVolume(raw);

   if(lot <= 0.0)
      PrintFormat("[RISQUE] Volume calcule %.4f sous le lot minimum %.2f. Trade ignore "
                  "plutot que de depasser le risque de %.2f%%.",
                  raw, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), InpRiskPercent);

   return lot;
  }

//+------------------------------------------------------------------+
//| Marge suffisante pour l'ordre envisage ?                          |
//+------------------------------------------------------------------+
bool HasMargin(const ENUM_ORDER_TYPE type, const double volume, const double price)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, volume, price, margin))
     {
      PrintFormat("[RISQUE] OrderCalcMargin a echoue (%d).", GetLastError());
      return false;
     }

   const double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin)
     {
      PrintFormat("[RISQUE] Marge requise %.2f > marge libre %.2f.", margin, freeMargin);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 4 — GESTION DES POSITIONS                               |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Distance minimale imposee par le broker entre le marche et un     |
//| niveau. On prend le maximum entre stops level et freeze level.    |
//+------------------------------------------------------------------+
double MinStopDistance(void)
  {
   const long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops, freeze) * g_point;
  }

//+------------------------------------------------------------------+
//| Nombre de positions ouvertes par cet EA sur ce symbole.           |
//+------------------------------------------------------------------+
int CountPositions(void)
  {
   int total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      total++;
     }
   return total;
  }

//+------------------------------------------------------------------+
//| Spread courant en points.                                         |
//+------------------------------------------------------------------+
double CurrentSpread(void)
  {
   if(g_point <= 0.0)
      return 0.0;
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK)
           - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
  }

//+------------------------------------------------------------------+
//| Ouvre la position decrite par le signal.                          |
//+------------------------------------------------------------------+
bool ExecuteSignal(Signal &s)
  {
   const double minDist = MinStopDistance();

   //--- le broker impose un plancher : on elargit plutot que de se faire
   //--- rejeter, et le lot sera calcule sur la distance reelle
   double sl = s.sl;
   double tp = s.tp;

   if(s.dir > 0)
     {
      if(s.entry - sl < minDist)
         sl = s.entry - minDist;
      if(tp - s.entry < minDist)
         tp = s.entry + minDist;
     }
   else
     {
      if(sl - s.entry < minDist)
         sl = s.entry + minDist;
      if(s.entry - tp < minDist)
         tp = s.entry - minDist;
     }

   sl = NormalizeDouble(sl, g_digits);
   tp = NormalizeDouble(tp, g_digits);

   const double stopDistance = MathAbs(s.entry - sl);
   const double lot = CalculateLot(stopDistance);
   if(lot <= 0.0)
      return false;

   const ENUM_ORDER_TYPE type = (s.dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!HasMargin(type, lot, s.entry))
      return false;

   PrintFormat("[ENTREE] %s", s.reason);
   PrintFormat("[ENTREE] lot=%.2f SL=%.2f TP=%.2f (distance stop %.2f, %.2f%% du balance)",
               lot, sl, tp, stopDistance, InpRiskPercent);

   const bool ok = (s.dir > 0)
                   ? g_trade.Buy(lot, _Symbol, 0.0, sl, tp, "MR-LR")
                   : g_trade.Sell(lot, _Symbol, 0.0, sl, tp, "MR-LR");

   if(!ok)
     {
      PrintFormat("[ERREUR] Ouverture refusee : retcode=%u (%s), erreur=%d",
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription(),
                  GetLastError());
      return false;
     }

   PrintFormat("[ENTREE] Execute a %.2f, ticket %I64u.",
               g_trade.ResultPrice(), g_trade.ResultOrder());
   return true;
  }

//+------------------------------------------------------------------+
//| Trailing leger et time-stop sur les positions de l'EA.            |
//+------------------------------------------------------------------+
void ManagePositions(const double atr)
  {
   if(atr <= 0.0)
      return;

   const double minDist = MinStopDistance();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      const ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const bool   isBuy  = (type == POSITION_TYPE_BUY);
      const double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      const double curSL  = PositionGetDouble(POSITION_SL);
      const double curTP  = PositionGetDouble(POSITION_TP);

      //--- time-stop : un retour a la moyenne qui n'a pas eu lieu au bout de
      //--- N bougies a probablement echoue
      if(InpMaxBarsInTrade > 0)
        {
         const datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
         const long age = (long)(TimeCurrent() - opened);
         if(age >= (long)InpMaxBarsInTrade * PeriodSeconds(_Period))
           {
            if(g_trade.PositionClose(ticket))
               PrintFormat("[SORTIE] #%I64u ferme par time-stop (%d bougies).",
                           ticket, InpMaxBarsInTrade);
            else
               PrintFormat("[ERREUR] Cloture time-stop refusee : retcode=%u",
                           g_trade.ResultRetcode());
            continue;
           }
        }

      if(!InpUseTrailing)
         continue;

      const double market = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                  : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(market <= 0.0)
         continue;

      const double profit = isBuy ? (market - open) : (open - market);
      if(profit < InpTrailStartATR * atr)
         continue;

      double newSL = isBuy ? market - InpTrailDistATR * atr
                           : market + InpTrailDistATR * atr;
      newSL = NormalizeDouble(newSL, g_digits);

      //--- ne jamais reculer le stop, ni violer la distance minimale
      if(isBuy)
        {
         if(newSL <= curSL || market - newSL < minDist)
            continue;
        }
      else
        {
         if((curSL > 0.0 && newSL >= curSL) || newSL - market < minDist)
            continue;
        }

      if(g_trade.PositionModify(ticket, newSL, curTP))
        {
         if(InpVerboseLog)
            PrintFormat("[TRAILING] #%I64u SL deplace a %.2f (gain %.2f, %.2f ATR).",
                        ticket, newSL, profit, profit / atr);
        }
      else
         PrintFormat("[ERREUR] Modification SL refusee : retcode=%u (%s)",
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 5 — CYCLE DE VIE                                        |
//|                                                                  |
//+------------------------------------------------------------------+

int OnInit(void)
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(g_point <= 0.0)
     {
      Print("[INIT] Point du symbole indisponible.");
      return INIT_FAILED;
     }

   //--- validation des parametres
   if(InpEMA_Period < 2)
     {
      Print("[INIT] EMA_Period doit valoir au moins 2.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpLR_Period < 10)
     {
      Print("[INIT] LR_Period doit valoir au moins 10 pour une regression exploitable.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpLR_Deviation <= 0.0)
     {
      Print("[INIT] LR_Deviation doit etre strictement positif.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpATR_Period < 2 || InpATR_Multiplier <= 0.0)
     {
      Print("[INIT] ATR_Period >= 2 et ATR_Multiplier > 0 sont requis.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
     {
      Print("[INIT] RiskPercent doit etre dans ]0, 10]. Au-dela, une serie de "
            "pertes normale suffit a ruiner le compte.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinBodyRatio < 0.0 || InpMinBodyRatio > 1.0)
     {
      Print("[INIT] InpMinBodyRatio doit etre dans [0, 1] : c'est un rapport.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpImpulseLookback < 1)
     {
      Print("[INIT] InpImpulseLookback doit valoir au moins 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- handles
   g_hEMA = iMA(_Symbol, _Period, InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR = iATR(_Symbol, _Period, InpATR_Period);

   if(g_hEMA == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
     {
      PrintFormat("[INIT] Creation des handles impossible (erreur %d).", GetLastError());
      return INIT_FAILED;
     }

   //--- execution
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   //--- amorce le detecteur : pas d'entree sur la bougie deja en cours
   g_lastBarTime = iTime(_Symbol, _Period, 0);

   if(_Period != PERIOD_M5)
      PrintFormat("[INIT] Attention : la strategie est calibree pour M5, "
                  "le graphique est en %s.", EnumToString((ENUM_TIMEFRAMES)_Period));

   PrintFormat("[INIT] BtcMeanReversionLR sur %s %s | EMA %d | LR %d x %.1f dev | "
               "ATR %d x %.2f | risque %.2f%% | magic %I64u",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
               InpEMA_Period, InpLR_Period, InpLR_Deviation,
               InpATR_Period, InpATR_Multiplier, InpRiskPercent, InpMagicNumber);

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hEMA != INVALID_HANDLE)
      IndicatorRelease(g_hEMA);
   if(g_hATR != INVALID_HANDLE)
      IndicatorRelease(g_hATR);

   g_hEMA = INVALID_HANDLE;
   g_hATR = INVALID_HANDLE;

   Comment("");
   PrintFormat("[DEINIT] Arret, raison %d.", reason);
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   double atr;
   if(!ReadBuffer(g_hATR, 1, atr) || atr <= 0.0)
      return;

   //--- la gestion des positions tourne a chaque tick : une position ouverte
   //--- ne doit pas attendre la cloture d'une bougie pour etre suivie
   ManagePositions(atr);

   //--- les entrees ne sont evaluees qu'a la cloture d'une bougie
   const datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;
   g_lastBarTime = barTime;

   if(!InpEnableTrading)
      return;

   if(!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      static bool warned = false;
      if(!warned)
        {
         Print("[GARDE] Trading desactive dans le terminal.");
         warned = true;
        }
      return;
     }

   if(CountPositions() >= 1)
      return;                               // une position a la fois

   const double spread = CurrentSpread();
   if(InpMaxSpreadPoints > 0.0 && spread > InpMaxSpreadPoints)
     {
      if(InpVerboseLog)
         PrintFormat("[GARDE] Spread %.0f pts > %.0f : signal ignore.",
                     spread, InpMaxSpreadPoints);
      return;
     }

   Signal s = DetectSignal();
   if(s.valid)
      ExecuteSignal(s);
  }
//+------------------------------------------------------------------+
