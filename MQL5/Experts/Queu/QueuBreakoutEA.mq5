//+------------------------------------------------------------------+
//|                                              QueuBreakoutEA.mq5  |
//|                                                             Queu |
//|                                                                  |
//|  Breakout de volatilite pour instruments a forte amplitude       |
//|  (XAUUSD, BTCUSD). Cassure d'un canal Donchian confirmee a la    |
//|  cloture, filtree par tendance (EMA) et par force du mouvement   |
//|  (ADX), avec stops et trailing indexes sur l'ATR.                |
//|                                                                  |
//|  Aucune performance n'est garantie. A valider en backtest puis   |
//|  en demo avant tout usage en reel.                               |
//+------------------------------------------------------------------+
#property copyright "Queu"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Queu/Utils.mqh>
#include <Queu/Risk.mqh>

//+------------------------------------------------------------------+
//| Parametres                                                        |
//+------------------------------------------------------------------+
input group "=== General ==="
input ulong           InpMagic              = 770101;    // Magic number
input string          InpComment            = "QueuBrk"; // Commentaire des ordres
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_H1; // Timeframe de travail
input ulong           InpSlippagePoints     = 30;        // Deviation max (points)
input bool            InpShowPanel          = true;      // Afficher le panneau d'etat

input group "=== Signal ==="
input int             InpChannelPeriod      = 20;        // Periode du canal Donchian
input int             InpATRPeriod          = 14;        // Periode ATR
input bool            InpAllowLong          = true;      // Autoriser les achats
input bool            InpAllowShort         = true;      // Autoriser les ventes
input bool            InpCloseOnOpposite    = false;     // Cloturer sur signal inverse

input group "=== Filtres de tendance ==="
input bool            InpUseTrendFilter     = true;      // Filtre EMA
input ENUM_TIMEFRAMES InpTrendTF            = PERIOD_CURRENT; // TF du filtre (CURRENT = TF de travail)
input int             InpEmaFast            = 21;        // EMA rapide
input int             InpEmaSlow            = 50;        // EMA lente
input bool            InpUseADXFilter       = true;      // Filtre ADX
input int             InpADXPeriod          = 14;        // Periode ADX
input double          InpADXMin             = 20.0;      // ADX minimum

input group "=== Filtre de volatilite / cout ==="
input double          InpMinATRPoints       = 0.0;       // ATR minimum en points (0 = off)
input double          InpMaxSpreadPoints    = 0.0;       // Spread max en points (0 = off)
input double          InpMaxSpreadATRRatio  = 0.12;      // Spread max / ATR (0 = off)

input group "=== Risque ==="
input double          InpRiskPercent        = 0.5;       // Risque par trade (% equity)
input double          InpFixedLot           = 0.0;       // Lot fixe (> 0 ignore le % de risque)
input bool            InpForceMinLot        = false;     // Forcer le lot min si le risque calcule est trop petit
input int             InpMaxPositions       = 1;         // Positions simultanees max (cet EA)
input double          InpMaxDailyLossPct    = 3.0;       // Perte journaliere max % (0 = off)
input double          InpMaxDailyProfitPct  = 0.0;       // Gain journalier max % (0 = off)
input int             InpCooldownBars       = 2;         // Bougies d'attente apres une perte (0 = off)

input group "=== Stops ==="
input double          InpSL_ATR             = 2.0;       // Stop loss = ATR x
input double          InpTP_ATR             = 0.0;       // Take profit = ATR x (0 = pas de TP)
input bool            InpUseBreakEven       = true;      // Activer le break-even
input double          InpBE_ATR             = 1.0;       // Declenche le BE a ATR x de gain
input double          InpBE_LockATR         = 0.10;      // Verrouille ATR x au-dela de l'entree
input bool            InpUseTrailing        = true;      // Activer le trailing stop
input double          InpTrail_ATR          = 2.0;       // Distance du trailing = ATR x
input double          InpTrailStepPoints    = 20.0;      // Amelioration min pour deplacer le stop (points)

input group "=== Session (heure serveur) ==="
input bool            InpUseSession         = false;     // Restreindre a une plage horaire
input int             InpSessionFrom        = 7;         // Heure de debut
input int             InpSessionTo          = 20;        // Heure de fin
input bool            InpSkipWeekend        = false;     // Ne pas ouvrir samedi/dimanche (utile en crypto)

//+------------------------------------------------------------------+
//| Etat global                                                       |
//+------------------------------------------------------------------+
CTrade         g_trade;
CQDailyGuard   g_guard;

string          g_sym;
ENUM_TIMEFRAMES g_tf;
ENUM_TIMEFRAMES g_trendTF;

int      g_hATR      = INVALID_HANDLE;
int      g_hEmaFast  = INVALID_HANDLE;
int      g_hEmaSlow  = INVALID_HANDLE;
int      g_hADX      = INVALID_HANDLE;

datetime g_lastBar      = 0;
datetime g_cooldownEnd  = 0;
string   g_blockReason  = "";

//+------------------------------------------------------------------+
//| Lit une valeur unique d'un buffer d'indicateur.                   |
//+------------------------------------------------------------------+
bool CopyOne(const int handle, const int buffer, const int shift, double &out)
  {
   double tmp[];
   if(CopyBuffer(handle, buffer, shift, 1, tmp) != 1)
      return false;

   out = tmp[0];
   return (out != EMPTY_VALUE);
  }

//+------------------------------------------------------------------+
//| Bornes du canal Donchian calculees sur les bougies 2..period+1.   |
//| La bougie 1 est exclue : c'est elle qui doit casser le canal.     |
//+------------------------------------------------------------------+
bool ChannelBounds(double &upper, double &lower)
  {
   double highs[], lows[];

   if(CopyHigh(g_sym, g_tf, 2, InpChannelPeriod, highs) != InpChannelPeriod)
      return false;
   if(CopyLow(g_sym, g_tf, 2, InpChannelPeriod, lows) != InpChannelPeriod)
      return false;

   upper = highs[ArrayMaximum(highs)];
   lower = lows[ArrayMinimum(lows)];
   return (upper > 0.0 && lower > 0.0);
  }

//+------------------------------------------------------------------+
//| Positions ouvertes par cet EA sur ce symbole.                     |
//+------------------------------------------------------------------+
int CountOwnPositions(void)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//| Filtres d'autorisation d'ouverture.                               |
//+------------------------------------------------------------------+
bool EntryAllowed(const double atr)
  {
   g_blockReason = "";

   if(!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      g_blockReason = "trading desactive dans le terminal";
      return false;
     }

   if(g_guard.Halted())
     {
      g_blockReason = g_guard.Reason();
      return false;
     }

   if(CountOwnPositions() >= InpMaxPositions)
     {
      g_blockReason = "nombre max de positions atteint";
      return false;
     }

   datetime now = TimeCurrent();
   if(g_cooldownEnd > 0 && now < g_cooldownEnd)
     {
      g_blockReason = "pause apres perte jusqu'a " + TimeToString(g_cooldownEnd, TIME_MINUTES);
      return false;
     }

   MqlDateTime dt;
   TimeToStruct(now, dt);

   if(InpSkipWeekend && (dt.day_of_week == 0 || dt.day_of_week == 6))
     {
      g_blockReason = "week-end exclu";
      return false;
     }

   if(InpUseSession && !QHourInWindow(dt.hour, InpSessionFrom, InpSessionTo))
     {
      g_blockReason = StringFormat("hors session (%02d:00, fenetre %02d-%02d)",
                                   dt.hour, InpSessionFrom, InpSessionTo);
      return false;
     }

   double point  = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   double spread = QSpreadPoints(g_sym);

   if(InpMaxSpreadPoints > 0.0 && spread > InpMaxSpreadPoints)
     {
      g_blockReason = StringFormat("spread %.0f pts > %.0f", spread, InpMaxSpreadPoints);
      return false;
     }

   if(InpMaxSpreadATRRatio > 0.0 && atr > 0.0 && point > 0.0)
     {
      double ratio = (spread * point) / atr;
      if(ratio > InpMaxSpreadATRRatio)
        {
         g_blockReason = StringFormat("spread/ATR %.3f > %.3f", ratio, InpMaxSpreadATRRatio);
         return false;
        }
     }

   if(InpMinATRPoints > 0.0 && point > 0.0 && (atr / point) < InpMinATRPoints)
     {
      g_blockReason = StringFormat("ATR %.0f pts < %.0f", atr / point, InpMinATRPoints);
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Filtre de tendance : +1 haussier, -1 baissier, 0 neutre.          |
//+------------------------------------------------------------------+
int TrendBias(void)
  {
   if(!InpUseTrendFilter)
      return 0;

   double fast, slow;
   if(!CopyOne(g_hEmaFast, 0, 1, fast) || !CopyOne(g_hEmaSlow, 0, 1, slow))
      return 0;

   if(fast > slow)
      return 1;
   if(fast < slow)
      return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//| Verifie la marge disponible avant d'envoyer un ordre.             |
//+------------------------------------------------------------------+
bool HasMarginFor(const ENUM_ORDER_TYPE type, const double volume, const double price)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(type, g_sym, volume, price, margin))
      return false;

   return (margin <= AccountInfoDouble(ACCOUNT_MARGIN_FREE));
  }

//+------------------------------------------------------------------+
//| Ouvre une position dans la direction demandee.                    |
//+------------------------------------------------------------------+
bool OpenTrade(const bool isBuy, const double atr)
  {
   double entry = isBuy ? SymbolInfoDouble(g_sym, SYMBOL_ASK)
                        : SymbolInfoDouble(g_sym, SYMBOL_BID);
   if(entry <= 0.0)
      return false;

   double slDist = atr * InpSL_ATR;
   double minDist = QMinStopDistance(g_sym);

   // le broker impose une distance plancher : on elargit plutot que de
   // se faire rejeter, et le lot sera recalcule sur la distance reelle
   if(slDist < minDist)
      slDist = minDist;
   if(slDist <= 0.0)
      return false;

   double sl = isBuy ? entry - slDist : entry + slDist;
   double tp = 0.0;
   if(InpTP_ATR > 0.0)
     {
      double tpDist = MathMax(atr * InpTP_ATR, minDist);
      tp = isBuy ? entry + tpDist : entry - tpDist;
     }

   sl = QNormalizePrice(g_sym, sl);
   if(tp > 0.0)
      tp = QNormalizePrice(g_sym, tp);

   //--- volume
   double volume = 0.0;
   if(InpFixedLot > 0.0)
     {
      volume = QNormalizeVolume(g_sym, InpFixedLot);
     }
   else
     {
      double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
      volume = QLotForRisk(g_sym, riskMoney, MathAbs(entry - sl));
     }

   if(volume <= 0.0)
     {
      if(!InpForceMinLot)
        {
         PrintFormat("[Queu] Trade ignore : volume calcule sous le lot minimum "
                     "(risque %.2f%%, distance SL %.5f). Active InpForceMinLot "
                     "ou augmente le risque si c'est voulu.",
                     InpRiskPercent, MathAbs(entry - sl));
         return false;
        }
      volume = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
      PrintFormat("[Queu] Volume force au lot minimum %.2f : le risque reel depasse %.2f%%.",
                  volume, InpRiskPercent);
     }

   ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!HasMarginFor(type, volume, entry))
     {
      PrintFormat("[Queu] Marge libre insuffisante pour %.2f lot.", volume);
      return false;
     }

   bool ok = isBuy ? g_trade.Buy(volume, g_sym, 0.0, sl, tp, InpComment)
                   : g_trade.Sell(volume, g_sym, 0.0, sl, tp, InpComment);

   if(!ok)
     {
      PrintFormat("[Queu] Echec ouverture %s : retcode=%d (%s)",
                  isBuy ? "BUY" : "SELL", g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return false;
     }

   PrintFormat("[Queu] %s %.2f lot @ %.5f | SL %.5f | TP %.5f | ATR %.5f",
               isBuy ? "BUY" : "SELL", volume, g_trade.ResultPrice(), sl, tp, atr);
   return true;
  }

//+------------------------------------------------------------------+
//| Cloture toutes les positions de l'EA dans une direction donnee.   |
//+------------------------------------------------------------------+
void CloseDirection(const ENUM_POSITION_TYPE dir)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != dir)
         continue;

      if(!g_trade.PositionClose(ticket))
         PrintFormat("[Queu] Echec cloture #%I64u : %d", ticket, g_trade.ResultRetcode());
     }
  }

//+------------------------------------------------------------------+
//| Break-even et trailing stop sur les positions de l'EA.            |
//+------------------------------------------------------------------+
void ManageOpenPositions(const double atr)
  {
   if(atr <= 0.0)
      return;
   if(!InpUseBreakEven && !InpUseTrailing)
      return;

   double point   = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   double minDist = QMinStopDistance(g_sym);
   double step    = InpTrailStepPoints * point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      bool   isBuy     = (type == POSITION_TYPE_BUY);

      double market = isBuy ? SymbolInfoDouble(g_sym, SYMBOL_BID)
                            : SymbolInfoDouble(g_sym, SYMBOL_ASK);
      if(market <= 0.0)
         continue;

      double profitDist = isBuy ? (market - entry) : (entry - market);
      double newSL      = currentSL;

      //--- break-even : on securise des que le gain couvre InpBE_ATR
      if(InpUseBreakEven && InpBE_ATR > 0.0 && profitDist >= atr * InpBE_ATR)
        {
         double lock = atr * InpBE_LockATR;
         double be   = isBuy ? entry + lock : entry - lock;

         if(isBuy && (newSL == 0.0 || be > newSL))
            newSL = be;
         if(!isBuy && (newSL == 0.0 || be < newSL))
            newSL = be;
        }

      //--- trailing : le stop suit le marche a InpTrail_ATR de distance
      if(InpUseTrailing && InpTrail_ATR > 0.0)
        {
         double trail = isBuy ? market - atr * InpTrail_ATR
                              : market + atr * InpTrail_ATR;

         if(isBuy && trail > entry && (newSL == 0.0 || trail > newSL + step))
            newSL = trail;
         if(!isBuy && trail < entry && (newSL == 0.0 || trail < newSL - step))
            newSL = trail;
        }

      if(newSL == currentSL || newSL == 0.0)
         continue;

      //--- respecte la distance minimale imposee par le broker
      if(isBuy && (market - newSL) < minDist)
         continue;
      if(!isBuy && (newSL - market) < minDist)
         continue;

      //--- ne jamais reculer le stop
      if(isBuy && currentSL > 0.0 && newSL <= currentSL)
         continue;
      if(!isBuy && currentSL > 0.0 && newSL >= currentSL)
         continue;

      newSL = QNormalizePrice(g_sym, newSL);
      if(!g_trade.PositionModify(ticket, newSL, currentTP))
         PrintFormat("[Queu] Echec modification SL #%I64u : %d (%s)",
                     ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Evalue le signal sur la bougie qui vient de cloturer.             |
//+------------------------------------------------------------------+
void EvaluateSignal(const double atr)
  {
   double upper, lower;
   if(!ChannelBounds(upper, lower))
      return;

   double close1 = iClose(g_sym, g_tf, 1);
   if(close1 <= 0.0)
      return;

   bool breakUp   = (close1 > upper);
   bool breakDown = (close1 < lower);

   if(!breakUp && !breakDown)
      return;

   //--- signal inverse : on peut liberer la position existante d'abord
   if(InpCloseOnOpposite)
     {
      if(breakUp)
         CloseDirection(POSITION_TYPE_SELL);
      if(breakDown)
         CloseDirection(POSITION_TYPE_BUY);
     }

   //--- filtres directionnels
   int bias = TrendBias();
   if(bias > 0 && breakDown)
      return;
   if(bias < 0 && breakUp)
      return;

   if(InpUseADXFilter)
     {
      double adx;
      if(!CopyOne(g_hADX, 0, 1, adx) || adx < InpADXMin)
        {
         g_blockReason = "ADX sous le seuil";
         return;
        }
     }

   if(!EntryAllowed(atr))
      return;

   if(breakUp && InpAllowLong)
      OpenTrade(true, atr);
   else
      if(breakDown && InpAllowShort)
         OpenTrade(false, atr);
  }

//+------------------------------------------------------------------+
//| Panneau d'etat                                                    |
//+------------------------------------------------------------------+
void UpdatePanel(const double atr)
  {
   if(!InpShowPanel)
      return;

   double point = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   string txt = StringFormat(
                   "QueuBreakoutEA  |  %s %s\n"
                   "ATR: %.5f (%.0f pts)   Spread: %.0f pts\n"
                   "Positions EA: %d / %d\n"
                   "Equity debut de journee: %.2f   Equity: %.2f\n"
                   "Etat: %s",
                   g_sym, EnumToString(g_tf),
                   atr, (point > 0.0 ? atr / point : 0.0), QSpreadPoints(g_sym),
                   CountOwnPositions(), InpMaxPositions,
                   g_guard.EquityAtOpen(), AccountInfoDouble(ACCOUNT_EQUITY),
                   (g_blockReason == "" ? "actif" : g_blockReason));

   Comment(txt);
  }

//+------------------------------------------------------------------+
//| Initialisation                                                    |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   g_sym = _Symbol;
   g_tf  = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpTimeframe;
   g_trendTF = (InpTrendTF == PERIOD_CURRENT) ? g_tf : InpTrendTF;

   //--- validation des parametres
   if(InpChannelPeriod < 2)
     {
      Print("[Queu] InpChannelPeriod doit valoir au moins 2.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpATRPeriod < 1)
     {
      Print("[Queu] InpATRPeriod doit valoir au moins 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpSL_ATR <= 0.0)
     {
      Print("[Queu] InpSL_ATR doit etre strictement positif : cet EA ne trade jamais sans stop.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpFixedLot <= 0.0 && InpRiskPercent <= 0.0)
     {
      Print("[Queu] Definis InpRiskPercent > 0 ou InpFixedLot > 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpUseTrendFilter && InpEmaFast >= InpEmaSlow)
     {
      Print("[Queu] InpEmaFast doit etre inferieur a InpEmaSlow.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxPositions < 1)
     {
      Print("[Queu] InpMaxPositions doit valoir au moins 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- indicateurs
   g_hATR = iATR(g_sym, g_tf, InpATRPeriod);
   if(g_hATR == INVALID_HANDLE)
     {
      Print("[Queu] Creation du handle ATR impossible.");
      return INIT_FAILED;
     }

   if(InpUseTrendFilter)
     {
      g_hEmaFast = iMA(g_sym, g_trendTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      g_hEmaSlow = iMA(g_sym, g_trendTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hEmaFast == INVALID_HANDLE || g_hEmaSlow == INVALID_HANDLE)
        {
         Print("[Queu] Creation des handles EMA impossible.");
         return INIT_FAILED;
        }
     }

   if(InpUseADXFilter)
     {
      g_hADX = iADX(g_sym, g_tf, InpADXPeriod);
      if(g_hADX == INVALID_HANDLE)
        {
         Print("[Queu] Creation du handle ADX impossible.");
         return INIT_FAILED;
        }
     }

   //--- execution
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(g_sym);
   g_trade.SetAsyncMode(false);

   g_guard.Refresh(TimeCurrent());

   //--- amorce le detecteur : pas d'entree sur la bougie deja en cours
   //--- au moment ou l'EA est attache
   g_lastBar = (datetime)iTime(g_sym, g_tf, 0);

   PrintFormat("[Queu] QueuBreakoutEA initialise sur %s %s | canal %d | ATR %d | risque %.2f%%",
               g_sym, EnumToString(g_tf), InpChannelPeriod, InpATRPeriod, InpRiskPercent);

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinitialisation                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hATR     != INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hEmaFast != INVALID_HANDLE) IndicatorRelease(g_hEmaFast);
   if(g_hEmaSlow != INVALID_HANDLE) IndicatorRelease(g_hEmaSlow);
   if(g_hADX     != INVALID_HANDLE) IndicatorRelease(g_hADX);

   Comment("");
  }

//+------------------------------------------------------------------+
//| Boucle principale                                                 |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   double atr;
   if(!CopyOne(g_hATR, 0, 1, atr) || atr <= 0.0)
      return;

   g_guard.Refresh(TimeCurrent());
   g_guard.Evaluate(InpMaxDailyLossPct, InpMaxDailyProfitPct);

   //--- la gestion des stops tourne a chaque tick : une position ouverte
   //--- ne doit pas attendre la cloture d'une bougie pour etre protegee
   ManageOpenPositions(atr);

   //--- les entrees, elles, ne sont evaluees qu'a la cloture d'une bougie
   if(QIsNewBar(g_sym, g_tf, g_lastBar))
      EvaluateSignal(atr);

   UpdatePanel(atr);
  }

//+------------------------------------------------------------------+
//| Detecte les cloture perdantes pour declencher la pause.           |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(InpCooldownBars <= 0)
      return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;

   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != g_sym)
      return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(pnl >= 0.0)
      return;

   g_cooldownEnd = TimeCurrent() + (datetime)(InpCooldownBars * PeriodSeconds(g_tf));
   PrintFormat("[Queu] Cloture perdante (%.2f). Pause jusqu'a %s.",
               pnl, TimeToString(g_cooldownEnd, TIME_DATE | TIME_MINUTES));
  }
