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
#include <Queu/Stats.mqh>
#include <Queu/Regression.mqh>
#include <Queu/Journal.mqh>

//+------------------------------------------------------------------+
//| Parametres                                                        |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Moteur d'entree. Les deux moteurs partagent toute la gestion du   |
//| risque, le journal et le critere d'optimisation ; seule la        |
//| condition d'entree differe.                                        |
//+------------------------------------------------------------------+
enum ENUM_QUEU_ENGINE
  {
   QUEU_ENGINE_BREAKOUT   = 0,   // Cassure de canal Donchian
   QUEU_ENGINE_REGRESSION = 1,   // Chaine de regressions : repli en tendance
   QUEU_ENGINE_BOTH       = 2    // Les deux (premier signal servi)
  };

input group "=== General ==="
input ENUM_QUEU_ENGINE InpEngine            = QUEU_ENGINE_BREAKOUT; // Moteur d'entree
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

input group "=== Chaine de regressions lineaires ==="
input int             InpReg_BasePeriod     = 20;        // Echelon court N (les autres : 2N, 4N, 8N)
input int             InpReg_RegimeFrom     = 1;         // Premier echelon du regime (0=N, 1=2N...)
input double          InpReg_MinR2          = 0.35;      // R2 minimum de l'echelon long
input double          InpReg_MinSlopeATR    = 1.00;      // Pente min de l'echelon long (ATR/fenetre)
input ENUM_QREG_DEV   InpReg_DevMode        = QREG_DEV_STDERR; // Mesure de dispersion (PINE = parite LonesomeTheBlue)
input double          InpReg_EntrySigma     = 1.00;      // Repli requis sous la droite courte (x sigma)
input double          InpReg_StopSigma      = 2.50;      // Stop a x sigma de la droite courte
input bool            InpReg_RequireAboveLong = true;    // Exiger le prix du bon cote de l'echelon long
input bool            InpReg_ExitOnBreak    = true;      // Sortir si le regime se casse (desaccord de pente)
input bool            InpReg_ExitOnChannel  = true;      // Sortir si le canal LONG est casse
input double          InpReg_ChannelMult    = 2.00;      // Largeur du canal long (x dispersion)

input group "=== Qualite du signal ==="
input bool            InpUseERFilter        = true;      // Filtre ratio d'efficience (Kaufman)
input int             InpERPeriod           = 20;        // Periode du ratio d'efficience
input double          InpERMin              = 0.30;      // ER minimum (0 = bruit, 1 = tendance pure)
input double          InpBreakoutATR        = 0.10;      // Marge de cassure au-dela du canal (x ATR)

input group "=== Sizing adaptatif ==="
input bool            InpUseDDThrottle      = true;      // Reduire le risque en drawdown
input double          InpDD_ThrottleStart   = 5.0;       // Debut de reduction (% de drawdown)
input double          InpDD_ThrottleFull    = 15.0;      // Reduction maximale atteinte a (%)
input double          InpDD_MinMultiple     = 0.25;      // Multiplicateur de risque au plancher
input bool            InpUseKelly           = false;     // Kelly fractionnaire (voir README avant d'activer)
input double          InpKellyFraction      = 0.25;      // Fraction de Kelly appliquee
input int             InpKellyWindow        = 50;        // Fenetre glissante (trades)
input int             InpKellyMinSamples    = 30;        // Trades requis avant activation
input double          InpKellyMinMultiple   = 0.25;      // Borne basse (x risque de base)
input double          InpKellyMaxMultiple   = 3.0;       // Borne haute (x risque de base)

input group "=== Prise de profit partielle ==="
input bool            InpUsePartial         = false;     // Cloturer une fraction a un multiple de R
input double          InpPartial_R          = 1.0;       // Declenchement (multiples de R)
input double          InpPartialPct         = 50.0;      // Fraction cloturee (%)

input group "=== Mesure ==="
input bool            InpWriteJournal       = true;      // Journal CSV des trades (dossier commun)
input int             InpTester_MinTrades   = 30;        // Trades min pour valider une passe
input int             InpTester_Trials      = 0;         // Passes d'optimisation (0 = deflation off)
input double          InpTester_TrialsSD    = 0.0;       // Ecart-type des Sharpe/trade entre passes
input double          InpTester_MaxDDPct    = 30.0;      // Drawdown au-dela duquel la passe est rejetee

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
CQAdaptiveRisk g_arisk;
CQJournal      g_journal;

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
//| Identifiant de la position issue d'un deal d'ouverture.           |
//+------------------------------------------------------------------+
ulong PositionIdFromDeal(const ulong deal)
  {
   if(deal == 0 || !HistoryDealSelect(deal))
      return 0;
   return (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
  }

//+------------------------------------------------------------------+
//| Une position portant cet identifiant est-elle encore ouverte ?    |
//+------------------------------------------------------------------+
bool PositionExistsById(const ulong posId)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER) == posId)
         return true;
     }
   return false;
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
bool OpenTrade(const bool isBuy, const double atr, const double slDistRequested)
  {
   double entry = isBuy ? SymbolInfoDouble(g_sym, SYMBOL_ASK)
                        : SymbolInfoDouble(g_sym, SYMBOL_BID);
   if(entry <= 0.0)
      return false;

   //--- chaque moteur impose sa propre distance de stop : ATR pour la
   //--- cassure, sigma de la regression pour le repli en tendance
   double slDist  = slDistRequested;
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
   double volume    = 0.0;
   double riskPct   = InpRiskPercent;
   double riskMoney = 0.0;

   if(InpFixedLot > 0.0)
     {
      volume = QNormalizeVolume(g_sym, InpFixedLot);
     }
   else
     {
      //--- le risque de base est module par le drawdown courant et,
      //--- si active, par le Kelly fractionnaire estime sur l'historique
      riskPct = g_arisk.RiskPercent(InpRiskPercent,
                                    InpUseKelly, InpKellyFraction, InpKellyMinSamples,
                                    InpKellyMinMultiple, InpKellyMaxMultiple,
                                    InpUseDDThrottle, InpDD_ThrottleStart,
                                    InpDD_ThrottleFull, InpDD_MinMultiple);

      riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * riskPct / 100.0;
      volume    = QLotForRisk(g_sym, riskMoney, MathAbs(entry - sl));
     }

   if(volume <= 0.0)
     {
      if(!InpForceMinLot)
        {
         PrintFormat("[Queu] Trade ignore : volume calcule sous le lot minimum "
                     "(risque %.3f%%, distance SL %.5f). Active InpForceMinLot "
                     "ou augmente le risque si c'est voulu.",
                     riskPct, MathAbs(entry - sl));
         return false;
        }
      volume = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
      PrintFormat("[Queu] Volume force au lot minimum %.2f : le risque reel depasse %.3f%%.",
                  volume, riskPct);
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

   //--- contexte conserve pour le journal, le TP partiel et le sizing Kelly
   ulong posId = PositionIdFromDeal(g_trade.ResultDeal());
   if(posId != 0)
     {
      double filled = g_trade.ResultPrice();
      if(filled <= 0.0)
         filled = entry;

      double adxVal = 0.0;
      if(g_hADX != INVALID_HANDLE)
         CopyOne(g_hADX, 0, 1, adxVal);

      //--- enregistre le contexte de regression meme pour un trade de
      //--- cassure : cela permet de demander apres coup si les cassures
      //--- rendent mieux quand la tendance de fond est nette
      double regSlope = 0.0, regR2 = 0.0;
      QRegChain ctxChain;
      if(QRegChainCompute(g_sym, g_tf, InpReg_BasePeriod, 1, atr, ctxChain))
        {
         regSlope = ctxChain.rung[QUEU_REG_RUNGS - 1].slopeATR;
         regR2    = ctxChain.rung[QUEU_REG_RUNGS - 1].r2;
        }

      QTradeCtx ctx;
      ctx.ticket      = posId;
      ctx.openTime    = TimeCurrent();
      ctx.dir         = isBuy ? 1 : -1;
      ctx.volume      = volume;
      ctx.entry       = filled;
      ctx.sl          = sl;
      ctx.tp          = tp;
      ctx.riskPrice   = MathAbs(filled - sl);
      ctx.atr         = atr;
      ctx.er          = QEfficiencyRatio(g_sym, g_tf, InpERPeriod, 1);
      ctx.adx         = adxVal;
      ctx.regSlopeATR = regSlope;
      ctx.regR2       = regR2;
      ctx.spreadPts   = QSpreadPoints(g_sym);
      ctx.mfe         = 0.0;
      ctx.mae         = 0.0;
      ctx.riskPct     = riskPct;
      ctx.riskMoney   = (riskMoney > 0.0)
                        ? riskMoney
                        : QLossPerLot(g_sym, ctx.riskPrice) * volume;
      ctx.pnlAccum    = 0.0;
      ctx.partialDone = false;

      g_journal.OnOpen(ctx);
     }

   PrintFormat("[Queu] %s %.2f lot @ %.5f | SL %.5f | TP %.5f | ATR %.5f | risque %.3f%%",
               isBuy ? "BUY" : "SELL", volume, g_trade.ResultPrice(), sl, tp, atr, riskPct);
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

      ulong  posId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      bool   isBuy     = (type == POSITION_TYPE_BUY);

      double market = isBuy ? SymbolInfoDouble(g_sym, SYMBOL_BID)
                            : SymbolInfoDouble(g_sym, SYMBOL_ASK);
      if(market <= 0.0)
         continue;

      g_journal.Track(posId, market);

      double profitDist = isBuy ? (market - entry) : (entry - market);
      double newSL      = currentSL;

      //--- prise de profit partielle a un multiple du risque initial.
      //--- Reduit la variance des resultats, au prix d'une esperance plus
      //--- faible : les trades les plus rentables sont amputes.
      if(InpUsePartial && InpPartial_R > 0.0 && !g_journal.PartialDone(posId))
        {
         double risk0;
         if(g_journal.InitialRisk(posId, risk0) && profitDist >= risk0 * InpPartial_R)
           {
            double posVol   = PositionGetDouble(POSITION_VOLUME);
            double closeVol = QNormalizeVolume(g_sym, posVol * InpPartialPct / 100.0);
            double leftover = posVol - closeVol;

            //--- ne pas laisser un residu sous le lot minimum, il serait
            //--- impossible a cloturer proprement ensuite
            if(closeVol > 0.0 && leftover >= SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN))
              {
               if(g_trade.PositionClosePartial(ticket, closeVol))
                 {
                  g_journal.SetPartialDone(posId);
                  PrintFormat("[Queu] Prise partielle %.2f lot a %.1f R sur #%I64u.",
                              closeVol, InpPartial_R, ticket);
                  continue;   // etat de la position modifie : on reprend au tick suivant
                 }
              }
           }
        }

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
//| Moteur 1 — cassure de canal Donchian.                             |
//| Retourne +1 / -1 dans 'dir' et la distance de stop associee.      |
//+------------------------------------------------------------------+
bool BreakoutSignal(const double atr, int &dir, double &slDist)
  {
   dir = 0;

   double upper, lower;
   if(!ChannelBounds(upper, lower))
      return false;

   double close1 = iClose(g_sym, g_tf, 1);
   if(close1 <= 0.0)
      return false;

   //--- marge de cassure : exiger un depassement d'une fraction d'ATR
   //--- ecarte les cassures marginales, qui sont majoritairement du bruit
   double margin = atr * InpBreakoutATR;

   bool breakUp   = (close1 > upper + margin);
   bool breakDown = (close1 < lower - margin);

   if(!breakUp && !breakDown)
      return false;

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
      return false;
   if(bias < 0 && breakUp)
      return false;

   if(InpUseADXFilter)
     {
      double adx;
      if(!CopyOne(g_hADX, 0, 1, adx) || adx < InpADXMin)
        {
         g_blockReason = "ADX sous le seuil";
         return false;
        }
     }

   //--- ratio d'efficience : mesure directement le rapport signal/bruit
   //--- du chemin parcouru, la ou l'ADX ne mesure qu'une moyenne lissee
   if(InpUseERFilter)
     {
      double er = QEfficiencyRatio(g_sym, g_tf, InpERPeriod, 1);
      if(er < InpERMin)
        {
         g_blockReason = StringFormat("ratio d'efficience %.2f < %.2f", er, InpERMin);
         return false;
        }
     }

   if(breakUp && InpAllowLong)
      dir = 1;
   else
      if(breakDown && InpAllowShort)
         dir = -1;

   if(dir == 0)
      return false;

   slDist = atr * InpSL_ATR;
   return true;
  }

//+------------------------------------------------------------------+
//| Moteur 2 — chaine de regressions lineaires : repli en tendance.    |
//|                                                                   |
//| Le regime est defini par l'accord des pentes sur les echelons     |
//| LONGS (2N, 4N, 8N par defaut). L'echelon court est exclu a        |
//| dessein : pendant un repli sa pente s'inverse alors que le regime |
//| de fond tient toujours — et c'est ce repli que l'on achete.       |
//|                                                                   |
//| L'echelon court sert au timing et au stop, via sigma, qui mesure  |
//| la dispersion AUTOUR DE LA DROITE et non l'amplitude du prix.     |
//|                                                                   |
//| Ce moteur n'applique pas les filtres EMA / ADX / efficience : la  |
//| chaine fait deja ce travail, avec ses seuils de R2 et de pente.   |
//| Les filtres de cout (spread, ATR) restent actifs via EntryAllowed.|
//+------------------------------------------------------------------+
bool RegressionSignal(const double atr, int &dir, double &slDist)
  {
   dir = 0;

   QRegChain chain;
   if(!QRegChainCompute(g_sym, g_tf, InpReg_BasePeriod, 1, atr, chain))
      return false;

   int regime = QRegChainBias(chain, InpReg_RegimeFrom,
                              InpReg_MinSlopeATR, InpReg_MinR2);
   if(regime == 0)
     {
      g_blockReason = "regime de regression non etabli";
      return false;
     }

   QRegResult shortRung = chain.rung[0];
   QRegResult longRung  = chain.rung[QUEU_REG_RUNGS - 1];

   //--- la dispersion du timing suit le mode choisi : sigma statistique,
   //--- ecart-type de population, ou parite avec l'indicateur Pine
   double dev = QRegDev(shortRung, InpReg_DevMode);
   if(dev <= 0.0)
      return false;

   double close1 = iClose(g_sym, g_tf, 1);
   if(close1 <= 0.0)
      return false;

   double offset = InpReg_EntrySigma * dev;
   double stopPx = 0.0;

   if(regime > 0)
     {
      if(!InpAllowLong)
         return false;

      //--- le prix doit etre retombe sous la droite courte : on achete
      //--- le repli, pas la poursuite
      if(close1 > shortRung.value - offset)
        {
         g_blockReason = "pas de repli suffisant sous la droite";
         return false;
        }

      //--- mais rester du bon cote de la structure longue, sinon ce n'est
      //--- plus un repli : c'est une cassure de tendance en cours
      if(InpReg_RequireAboveLong && close1 < longRung.value)
        {
         g_blockReason = "prix sous la droite longue : repli invalide";
         return false;
        }

      stopPx = shortRung.value - InpReg_StopSigma * dev;
      slDist = close1 - stopPx;
      dir    = 1;
     }
   else
     {
      if(!InpAllowShort)
         return false;

      if(close1 < shortRung.value + offset)
        {
         g_blockReason = "pas de rebond suffisant au-dessus de la droite";
         return false;
        }

      if(InpReg_RequireAboveLong && close1 > longRung.value)
        {
         g_blockReason = "prix au-dessus de la droite longue : rebond invalide";
         return false;
        }

      stopPx = shortRung.value + InpReg_StopSigma * dev;
      slDist = stopPx - close1;
      dir    = -1;
     }

   //--- un repli deja plus profond que le stop invalide le setup :
   //--- il n'y a plus de place entre l'entree et l'invalidation
   if(slDist <= 0.0)
     {
      g_blockReason = "repli au-dela du niveau de stop";
      dir = 0;
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Sortie sur rupture de regime, pour les positions du moteur de     |
//| regression.                                                       |
//|                                                                   |
//| Seul le DESACCORD DE SIGNE declenche la sortie, pas la baisse de  |
//| qualite : reappliquer les seuils d'entree ferait sortir bien trop |
//| tot, un R2 se degradant naturellement pendant chaque respiration. |
//+------------------------------------------------------------------+
void CheckRegimeExit(const double atr)
  {
   if(InpEngine == QUEU_ENGINE_BREAKOUT)
      return;
   if(!InpReg_ExitOnBreak && !InpReg_ExitOnChannel)
      return;
   if(CountOwnPositions() == 0)
      return;

   QRegChain chain;
   if(!QRegChainCompute(g_sym, g_tf, InpReg_BasePeriod, 1, atr, chain))
      return;

   int regime = QRegChainBias(chain, InpReg_RegimeFrom, 0.0, 0.0);

   if(InpReg_ExitOnBreak)
     {
      if(regime <= 0)
         CloseDirection(POSITION_TYPE_BUY);
      if(regime >= 0)
         CloseDirection(POSITION_TYPE_SELL);
     }

   //--- Cassure du canal, au sens de 'outofchannel' du script Pine, mais
   //--- lue sur l'echelon LONG et non sur le court.
   //---
   //--- C'est la reconciliation d'une contradiction apparente : sortir du
   //--- canal par le bas dans une tendance haussiere est, pour un canal
   //--- unique, un signal de rupture. Ici c'est justement la condition
   //--- d'ENTREE, mesuree sur l'echelon court. La difference est l'echelle :
   //--- un repli sous le canal court pendant que les echelons longs tiennent
   //--- est une respiration ; une sortie du canal LONG est une vraie
   //--- rupture de tendance. Un indicateur a canal unique ne peut pas faire
   //--- cette distinction.
   if(InpReg_ExitOnChannel)
     {
      double close1 = iClose(g_sym, g_tf, 1);
      int    brk    = QRegChannelBreak(chain.rung[QUEU_REG_RUNGS - 1], close1,
                                       InpReg_ChannelMult, InpReg_DevMode);

      if(brk == QREG_CHANNEL_BROKEN_DOWN)
         CloseDirection(POSITION_TYPE_BUY);
      if(brk == QREG_CHANNEL_BROKEN_UP)
         CloseDirection(POSITION_TYPE_SELL);
     }
  }

//+------------------------------------------------------------------+
//| Evalue le signal sur la bougie qui vient de cloturer.              |
//+------------------------------------------------------------------+
void EvaluateSignal(const double atr)
  {
   int    dir    = 0;
   double slDist = 0.0;
   bool   signal = false;

   if(InpEngine == QUEU_ENGINE_BREAKOUT || InpEngine == QUEU_ENGINE_BOTH)
      signal = BreakoutSignal(atr, dir, slDist);

   //--- en mode BOTH, la regression n'est consultee que si la cassure
   //--- n'a rien produit : premier signal servi
   if(!signal && (InpEngine == QUEU_ENGINE_REGRESSION || InpEngine == QUEU_ENGINE_BOTH))
      signal = RegressionSignal(atr, dir, slDist);

   if(!signal || dir == 0 || slDist <= 0.0)
      return;

   if(!EntryAllowed(atr))
      return;

   OpenTrade(dir > 0, atr, slDist);
  }

//+------------------------------------------------------------------+
//| Panneau d'etat                                                    |
//+------------------------------------------------------------------+
void UpdatePanel(const double atr)
  {
   if(!InpShowPanel)
      return;

   double point = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   double er    = InpUseERFilter ? QEfficiencyRatio(g_sym, g_tf, InpERPeriod, 1) : 0.0;

   //--- sizing courant, affiche avant meme le prochain trade
   double riskNow = g_arisk.RiskPercent(InpRiskPercent,
                                        InpUseKelly, InpKellyFraction, InpKellyMinSamples,
                                        InpKellyMinMultiple, InpKellyMaxMultiple,
                                        InpUseDDThrottle, InpDD_ThrottleStart,
                                        InpDD_ThrottleFull, InpDD_MinMultiple);

   string kelly = "off";
   if(InpUseKelly)
     {
      double kp, kb, kf;
      if(g_arisk.Count() < InpKellyMinSamples)
         kelly = StringFormat("echantillon %d/%d", g_arisk.Count(), InpKellyMinSamples);
      else
         if(g_arisk.KellyStats(kp, kb, kf))
            kelly = StringFormat("p=%.2f b=%.2f f*=%+.3f", kp, kb, kf);
     }

   //--- etat de la chaine de regressions, quand elle est en service
   string reg = "off";
   if(InpEngine != QUEU_ENGINE_BREAKOUT)
     {
      QRegChain c;
      if(QRegChainCompute(g_sym, g_tf, InpReg_BasePeriod, 1, atr, c))
        {
         int rg = QRegChainBias(c, InpReg_RegimeFrom, InpReg_MinSlopeATR, InpReg_MinR2);
         reg = StringFormat("%s  R2=%.2f  pente=%+.2f ATR/fen.  dev=%.5f (%s)",
                            (rg > 0 ? "HAUSSIER" : (rg < 0 ? "BAISSIER" : "aucun")),
                            c.rung[QUEU_REG_RUNGS - 1].r2,
                            c.rung[QUEU_REG_RUNGS - 1].slopeATR,
                            QRegDev(c.rung[0], InpReg_DevMode),
                            EnumToString(InpReg_DevMode));
        }
      else
         reg = "historique insuffisant";
     }

   string txt = StringFormat(
                   "QueuBreakoutEA  |  %s %s  |  moteur %s\n"
                   "ATR: %.5f (%.0f pts)   Spread: %.0f pts   ER: %.2f\n"
                   "Positions EA: %d / %d\n"
                   "Risque prochain trade: %.3f%%  (base %.2f%%)   Kelly: %s\n"
                   "Equity debut de journee: %.2f   Equity: %.2f\n"
                   "Regression: %s\n"
                   "Etat: %s",
                   g_sym, EnumToString(g_tf), EnumToString(InpEngine),
                   atr, (point > 0.0 ? atr / point : 0.0), QSpreadPoints(g_sym), er,
                   CountOwnPositions(), InpMaxPositions,
                   riskNow, InpRiskPercent, kelly,
                   g_guard.EquityAtOpen(), AccountInfoDouble(ACCOUNT_EQUITY),
                   reg,
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
   if(InpUseERFilter && (InpERPeriod < 2 || InpERMin < 0.0 || InpERMin > 1.0))
     {
      Print("[Queu] InpERPeriod >= 2 et InpERMin dans [0, 1] sont requis.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpUseDDThrottle && InpDD_ThrottleFull <= InpDD_ThrottleStart)
     {
      Print("[Queu] InpDD_ThrottleFull doit etre superieur a InpDD_ThrottleStart.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpUseKelly && (InpKellyFraction <= 0.0 || InpKellyFraction > 1.0))
     {
      Print("[Queu] InpKellyFraction doit etre dans ]0, 1]. Le plein Kelly (1.0) "
            "est deja tres agressif : 0.25 est le reglage usuel.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpUseKelly && InpKellyMinSamples > InpKellyWindow)
     {
      Print("[Queu] InpKellyMinSamples ne peut pas depasser InpKellyWindow : "
            "le seuil ne serait jamais atteint.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpEngine != QUEU_ENGINE_BREAKOUT)
     {
      if(InpReg_BasePeriod < 3)
        {
         Print("[Queu] InpReg_BasePeriod doit valoir au moins 3.");
         return INIT_PARAMETERS_INCORRECT;
        }
      if(InpReg_RegimeFrom < 0 || InpReg_RegimeFrom >= QUEU_REG_RUNGS)
        {
         PrintFormat("[Queu] InpReg_RegimeFrom doit etre dans [0, %d].", QUEU_REG_RUNGS - 1);
         return INIT_PARAMETERS_INCORRECT;
        }
      if(InpReg_MinR2 < 0.0 || InpReg_MinR2 > 1.0)
        {
         Print("[Queu] InpReg_MinR2 doit etre dans [0, 1] : c'est un coefficient "
               "de determination.");
         return INIT_PARAMETERS_INCORRECT;
        }
      if(InpReg_StopSigma <= InpReg_EntrySigma)
        {
         Print("[Queu] InpReg_StopSigma doit depasser InpReg_EntrySigma, sinon le "
               "stop est atteint des l'entree et aucun trade n'est possible.");
         return INIT_PARAMETERS_INCORRECT;
        }

      //--- l'echelon le plus long consomme 8N bougies : verifier la profondeur
      int needed = InpReg_BasePeriod * 8;
      if(Bars(g_sym, g_tf) < needed + 10)
         PrintFormat("[Queu] Attention : %d bougies disponibles, l'echelon long en "
                     "demande %d. Le moteur restera inactif jusqu'a ce que "
                     "l'historique soit suffisant.", Bars(g_sym, g_tf), needed);
     }

   if(InpUsePartial && (InpPartialPct <= 0.0 || InpPartialPct >= 100.0))
     {
      Print("[Queu] InpPartialPct doit etre dans ]0, 100[.");
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
   g_arisk.Init(InpKellyWindow);

   //--- en optimisation, des dizaines d'agents ecriraient dans le meme
   //--- fichier : le journal detaille n'a de sens que hors optimisation
   bool writeJournal = InpWriteJournal && !MQLInfoInteger(MQL_OPTIMIZATION);
   g_journal.Init(StringFormat("Queu_Trades_%s_%I64u.csv", g_sym, InpMagic), writeJournal);

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
     {
      CheckRegimeExit(atr);   // liberer avant d'evaluer une nouvelle entree
      EvaluateSignal(atr);
     }

   UpdatePanel(atr);
  }

//+------------------------------------------------------------------+
//| Comptabilise les clotures : journal, sizing adaptatif, cooldown.  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
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

   ulong    posId = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   double   price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   datetime when  = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   g_journal.AddPnL(posId, pnl);

   //--- une cloture partielle laisse la position ouverte : on n'arrete pas
   //--- le compteur de R tant que le trade n'est pas termine
   bool   closedOut = !PositionExistsById(posId);
   double r         = 0.0;
   bool   haveR     = g_journal.RealizedR(posId, r);

   if(closedOut && haveR)
      g_arisk.PushR(r);

   g_journal.OnClose(posId, when, price, pnl, closedOut);

   if(closedOut && haveR && r < 0.0 && InpCooldownBars > 0)
     {
      g_cooldownEnd = TimeCurrent() + (datetime)(InpCooldownBars * PeriodSeconds(g_tf));
      PrintFormat("[Queu] Trade perdant cloture (%.2f R). Pause jusqu'a %s.",
                  r, TimeToString(g_cooldownEnd, TIME_DATE | TIME_MINUTES));
     }
  }

//+------------------------------------------------------------------+
//| Colonnes du resume de passe, partagees entre agent et terminal.   |
//+------------------------------------------------------------------+
#define QUEU_STAT_COLS 21

string QueuTesterHeader(void)
  {
   return "n_trades,sharpe_per_trade,sortino,max_dd_pct,psr_vs_zero,dsr,"
          "net_profit,profit_factor,mean_return_pct,"
          "channel_period,atr_period,sl_atr,trail_atr,"
          "breakout_atr,er_min,adx_min,risk_pct,"
          "engine,reg_base,reg_min_r2,reg_entry_sigma";
  }

//+------------------------------------------------------------------+
//| Ecrit une ligne de resume dans le fichier commun.                 |
//+------------------------------------------------------------------+
void QueuWriteTesterRow(const double &st[])
  {
   if(ArraySize(st) < QUEU_STAT_COLS)
      return;

   string file = StringFormat("Queu_Passes_%s.csv", _Symbol);

   //--- plusieurs processus peuvent viser le fichier : quelques essais
   for(int attempt = 0; attempt < 5; attempt++)
     {
      int h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
      if(h == INVALID_HANDLE)
         continue;

      if(FileSize(h) == 0)
         FileWrite(h, QueuTesterHeader());

      FileSeek(h, 0, SEEK_END);
      FileWrite(h,
                DoubleToString(st[0],  0), DoubleToString(st[1],  6),
                DoubleToString(st[2],  6), DoubleToString(st[3],  3),
                DoubleToString(st[4],  6), DoubleToString(st[5],  6),
                DoubleToString(st[6],  2), DoubleToString(st[7],  4),
                DoubleToString(st[8],  6),
                DoubleToString(st[9],  0), DoubleToString(st[10], 0),
                DoubleToString(st[11], 3), DoubleToString(st[12], 3),
                DoubleToString(st[13], 3), DoubleToString(st[14], 3),
                DoubleToString(st[15], 2), DoubleToString(st[16], 4),
                DoubleToString(st[17], 0), DoubleToString(st[18], 0),
                DoubleToString(st[19], 3), DoubleToString(st[20], 3));
      FileClose(h);
      return;
     }
  }

//+------------------------------------------------------------------+
//| Critere d'optimisation personnalise.                              |
//|                                                                   |
//| MT5 propose par defaut le profit ou le facteur de recuperation.   |
//| Optimiser sur ces criteres selectionne presque toujours du        |
//| sur-apprentissage : ils ne tiennent compte ni de la taille de     |
//| l'echantillon, ni de la forme de la distribution, ni du nombre    |
//| de jeux de parametres essayes.                                    |
//|                                                                   |
//| On retourne ici le Deflated Sharpe Ratio : la probabilite que la  |
//| performance observee ne soit PAS le meilleur tirage d'une serie   |
//| de tests sur du bruit. Une passe est rejetee d'office si elle     |
//| repose sur trop peu de trades ou si son drawdown depasse la       |
//| tolerance.                                                        |
//+------------------------------------------------------------------+
double OnTester(void)
  {
   if(!HistorySelect(0, TimeCurrent()))
      return 0.0;

   double rets[];
   ArrayResize(rets, 0);

   double balance = TesterStatistics(STAT_INITIAL_DEPOSIT);
   if(balance <= 0.0)
      balance = AccountInfoDouble(ACCOUNT_BALANCE);   // repli si non renseigne
   if(balance <= 0.0)
      return 0.0;                                     // rien de normalisable
   double grossProfit = 0.0;
   double grossLoss   = 0.0;
   double netProfit   = 0.0;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_SWAP)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION);

      //--- rendement rapporte au capital DISPONIBLE avant le trade :
      //--- c'est ce qui rend la serie coherente avec une composition
      if(balance > 0.0)
        {
         int n = ArraySize(rets);
         ArrayResize(rets, n + 1);
         rets[n] = pnl / balance;
        }

      balance   += pnl;
      netProfit += pnl;

      if(pnl >= 0.0)
         grossProfit += pnl;
      else
         grossLoss += -pnl;
     }

   int n = ArraySize(rets);
   if(n < InpTester_MinTrades)
      return 0.0;                         // echantillon insuffisant : non evaluable

   double maxDD = QMaxDrawdownFromReturns(rets) * 100.0;
   if(InpTester_MaxDDPct > 0.0 && maxDD > InpTester_MaxDDPct)
      return 0.0;                         // hors tolerance de risque

   double sharpe  = QSharpe(rets);
   double sortino = QSortino(rets, 0.0);
   double psr0    = QProbabilisticSharpe(rets, 0.0);
   double dsr     = QDeflatedSharpe(rets, InpTester_Trials, InpTester_TrialsSD);

   double mean = 0.0;
   for(int i = 0; i < n; i++)
      mean += rets[i];
   mean = (mean / n) * 100.0;

   double pf = (grossLoss > 0.0) ? grossProfit / grossLoss : 0.0;

   double st[QUEU_STAT_COLS];
   st[0]  = (double)n;
   st[1]  = sharpe;
   st[2]  = sortino;
   st[3]  = maxDD;
   st[4]  = psr0;
   st[5]  = dsr;
   st[6]  = netProfit;
   st[7]  = pf;
   st[8]  = mean;
   st[9]  = (double)InpChannelPeriod;
   st[10] = (double)InpATRPeriod;
   st[11] = InpSL_ATR;
   st[12] = InpTrail_ATR;
   st[13] = InpBreakoutATR;
   st[14] = InpERMin;
   st[15] = InpADXMin;
   st[16] = InpRiskPercent;
   st[17] = (double)InpEngine;
   st[18] = (double)InpReg_BasePeriod;
   st[19] = InpReg_MinR2;
   st[20] = InpReg_EntrySigma;

   if(MQLInfoInteger(MQL_OPTIMIZATION))
      FrameAdd("queu", 0, dsr, st);       // collecte centralisee par le terminal
   else
      QueuWriteTesterRow(st);             // backtest unique : ecriture directe

   return dsr;
  }

//+------------------------------------------------------------------+
//| Optimisation : prepare le fichier de collecte des passes.         |
//+------------------------------------------------------------------+
int OnTesterInit(void)
  {
   PrintFormat("[Queu] Optimisation demarree. Resume des passes : Queu_Passes_%s.csv "
               "(dossier commun des terminaux).", _Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Une passe s'est terminee : le terminal recupere sa trame.         |
//| Ecrire ici plutot que dans l'agent evite que des dizaines de      |
//| processus se disputent le meme fichier.                           |
//+------------------------------------------------------------------+
void OnTesterPass(void)
  {
   ulong  pass;
   string name;
   ulong  id;
   double value;
   double data[];

   while(FrameNext(pass, name, id, value, data))
      if(name == "queu")
         QueuWriteTesterRow(data);
  }

//+------------------------------------------------------------------+
//| Fin d'optimisation.                                               |
//+------------------------------------------------------------------+
void OnTesterDeinit(void)
  {
   PrintFormat("[Queu] Optimisation terminee. Analyse : "
               "python3 tools/analyze_queu.py passes Queu_Passes_%s.csv", _Symbol);
  }
