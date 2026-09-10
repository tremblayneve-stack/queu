//+------------------------------------------------------------------+
//|                                             QueuTradeAutopsy.mq5 |
//|                                                             Queu |
//|                                                                  |
//|  Autopsie de l'historique REEL d'un compte.                      |
//|                                                                  |
//|  Pour chaque groupe de trades (position initiale + renforts), le |
//|  script reconstruit le contexte du canal de regression AU MOMENT |
//|  DE L'ENTREE sur deux timeframes, puis mesure ce que le prix a   |
//|  fait ensuite. Le tout part dans un CSV exploitable par          |
//|  tools/angle_autopsy.py.                                         |
//|                                                                  |
//|  LECTURE SEULE. Ce script ne trade pas, ne modifie rien.         |
//|                                                                  |
//|  ----------------------------------------------------------------|
//|  DEFINITION DE L'ANGLE — a lire avant d'interpreter quoi que ce  |
//|  soit.                                                           |
//|                                                                  |
//|  « L'angle d'un canal » n'existe pas dans l'absolu : il depend   |
//|  de l'echelle verticale choisie. Change le zoom du graphique et  |
//|  l'angle change ; deux brokers donnent deux angles pour le meme  |
//|  marche. Un seuil en degres lu a l'oeil n'est donc transportable |
//|  nulle part.                                                     |
//|                                                                  |
//|  Convention retenue ici, explicite et invariante d'echelle :     |
//|                                                                  |
//|      1 bougie horizontalement  =  1 ATR verticalement            |
//|      angle = atan( pente_par_bougie / ATR ) en degres            |
//|                                                                  |
//|  Un canal qui monte d'un ATR par bougie vaut 45 degres. En       |
//|  pratique les valeurs utiles vivent entre -25 et +25 degres.     |
//|                                                                  |
//|  L'angle etant une transformation MONOTONE de la pente           |
//|  normalisee, decouper par angle ou par pente donne le meme       |
//|  classement. L'angle apporte tout de meme une chose : atan       |
//|  comprime les extremes, donc des tranches d'angle de largeur     |
//|  egale encaissent mieux les valeurs aberrantes.                  |
//+------------------------------------------------------------------+
#property copyright "Queu"
#property version   "1.00"
#property script_show_inputs

input int             InpDaysBack     = 14;          // Profondeur d'historique (jours)
input string          InpSymbolFilter = "";          // Symbole (vide = celui du graphique)
input long            InpMagicFilter  = 0;           // Magic (0 = tous)
input ENUM_TIMEFRAMES InpTF_Fast      = PERIOD_M1;   // Timeframe rapide
input ENUM_TIMEFRAMES InpTF_Slow      = PERIOD_M3;   // Timeframe lent
input int             InpChannelBars  = 100;         // Longueur du canal (bougies)
input int             InpATR_Period   = 14;          // Periode ATR
input int             InpFwdShort     = 3;           // Fenetre avant courte (minutes)
input int             InpFwdLong      = 15;          // Fenetre avant longue (minutes)

//+------------------------------------------------------------------+
//| Contexte de canal a un instant donne.                             |
//+------------------------------------------------------------------+
struct ChannelSnap
  {
   bool     valid;
   double   angleDeg;    // convention : 1 bougie = 1 ATR
   double   slopeATR;    // pente par bougie, en ATR
   double   r2;
   double   dev;         // ecart-type des residus, en prix
   double   devFromMid;  // (prix - mediane) / dev  -> +2 = bande haute a 2 dev
   double   atr;
  };

//+------------------------------------------------------------------+
//| Regression lineaire sur les bougies CLOSES avant 'when'.          |
//|                                                                   |
//| iBarShift donne la bougie qui CONTIENT 'when' ; celle-ci n'etait  |
//| pas terminee a cet instant. On part donc de shift+1, sinon on     |
//| injecte de l'information future dans l'analyse et tous les        |
//| resultats deviennent flatteurs et faux.                           |
//+------------------------------------------------------------------+
ChannelSnap ChannelAt(const string sym, const ENUM_TIMEFRAMES tf,
                      const datetime when, const int period,
                      const int atrHandle, const double refPrice)
  {
   ChannelSnap c;
   c.valid = false;
   c.angleDeg = c.slopeATR = c.r2 = c.dev = c.devFromMid = c.atr = 0.0;

   if(period < 5)
      return c;

   const int shift = iBarShift(sym, tf, when, false);
   if(shift < 0)
      return c;

   //--- ATR de la bougie close precedant l'entree
   double atrBuf[];
   if(CopyBuffer(atrHandle, 0, shift + 1, 1, atrBuf) != 1 || atrBuf[0] <= 0.0)
      return c;
   c.atr = atrBuf[0];

   double y[];
   if(CopyClose(sym, tf, shift + 1, period, y) != period)
      return c;

   const double n   = (double)period;
   const double mx  = (n - 1.0) / 2.0;
   const double sxx = n * (n * n - 1.0) / 12.0;
   if(sxx <= 0.0)
      return c;

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

   const double slope = sxy / sxx;              // prix par bougie
   const double inter = my - slope * mx;
   const double mid   = inter + slope * (n - 1.0);

   double ssres = syy - slope * sxy;
   if(ssres < 0.0)
      ssres = 0.0;

   c.dev = MathSqrt(ssres / n);
   c.r2  = (syy > 0.0) ? MathMax(0.0, MathMin(1.0, 1.0 - ssres / syy)) : 0.0;

   //--- normalisation : la pente s'exprime en ATR par bougie, et l'angle
   //--- decoule de la convention 1 bougie = 1 ATR
   c.slopeATR = slope / c.atr;
   c.angleDeg = MathArctan(c.slopeATR) * 180.0 / M_PI;

   c.devFromMid = (c.dev > 0.0) ? (refPrice - mid) / c.dev : 0.0;

   c.valid = true;
   return c;
  }

//+------------------------------------------------------------------+
//| Excursions extremes apres l'entree, exprimees en ATR de la TF     |
//| rapide. Signees selon le sens du trade : positif = favorable.     |
//+------------------------------------------------------------------+
void ForwardExcursion(const string sym, const datetime entryTime,
                      const double entryPrice, const int dir,
                      const int minutes, const double atr,
                      double &mfeATR, double &maeATR)
  {
   mfeATR = 0.0;
   maeATR = 0.0;
   if(atr <= 0.0 || minutes < 1)
      return;

   const int shift = iBarShift(sym, PERIOD_M1, entryTime, false);
   if(shift < 0)
      return;

   //--- on avance dans le temps : les indices DIMINUENT
   const int from = MathMax(0, shift - minutes);
   double best = -DBL_MAX, worst = DBL_MAX;

   for(int i = shift; i >= from; i--)
     {
      const double h = iHigh(sym, PERIOD_M1, i);
      const double l = iLow(sym, PERIOD_M1, i);
      if(h <= 0.0 || l <= 0.0)
         continue;

      const double fav = (dir > 0) ? (h - entryPrice) : (entryPrice - l);
      const double adv = (dir > 0) ? (l - entryPrice) : (entryPrice - h);

      if(fav > best)  best  = fav;
      if(adv < worst) worst = adv;
     }

   if(best  > -DBL_MAX) mfeATR = best  / atr;
   if(worst <  DBL_MAX) maeATR = worst / atr;
  }

//+------------------------------------------------------------------+
//| Stop loss de l'ordre d'ouverture, 0 s'il a ete pose apres coup.   |
//+------------------------------------------------------------------+
double OpeningStopLoss(const ulong dealTicket)
  {
   const ulong order = (ulong)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
   if(order == 0 || !HistoryOrderSelect(order))
      return 0.0;
   return HistoryOrderGetDouble(order, ORDER_SL);
  }

//+------------------------------------------------------------------+
void OnStart(void)
  {
   const string sym = (InpSymbolFilter == "") ? _Symbol : InpSymbolFilter;

   const datetime to   = TimeCurrent();
   const datetime from = to - (datetime)(InpDaysBack * 86400);

   if(!HistorySelect(from, to))
     {
      PrintFormat("[AUTOPSIE] HistorySelect a echoue (%d).", GetLastError());
      return;
     }

   const int hAtrFast = iATR(sym, InpTF_Fast, InpATR_Period);
   const int hAtrSlow = iATR(sym, InpTF_Slow, InpATR_Period);
   if(hAtrFast == INVALID_HANDLE || hAtrSlow == INVALID_HANDLE)
     {
      Print("[AUTOPSIE] Creation des handles ATR impossible.");
      return;
     }
   Sleep(300);                                   // laisse les buffers se remplir

   const string file = StringFormat("Queu_Autopsy_%s_%I64d.csv",
                                    sym, AccountInfoInteger(ACCOUNT_LOGIN));
   const int h = FileOpen(file, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h == INVALID_HANDLE)
     {
      PrintFormat("[AUTOPSIE] Impossible d'ouvrir %s (%d).", file, GetLastError());
      IndicatorRelease(hAtrFast);
      IndicatorRelease(hAtrSlow);
      return;
     }

   FileWrite(h,
             "cluster_id,account,symbol,open_time,close_time,duration_sec,direction,"
             "n_entries,total_volume,entry_price,exit_price,"
             "pnl_money,pnl_pct_balance,balance_before,"
             "first_sl,risk_price,r_multiple,used_reinforcement,"
             "fast_angle_deg,fast_slope_atr,fast_r2,fast_dev_from_mid,fast_atr,"
             "slow_angle_deg,slow_slope_atr,slow_r2,slow_dev_from_mid,slow_atr,"
             "angle_diff_deg,aligned,"
             "mfe_short_atr,mae_short_atr,mfe_long_atr,mae_long_atr");

   //================================================================
   //  Regroupement des deals en GRAPPES.
   //
   //  Une grappe court du moment ou l'exposition nette quitte zero
   //  jusqu'a ce qu'elle y revienne. Cette definition est exacte et
   //  independante du mode du compte : en netting les renforts
   //  alimentent la meme position, en hedging ils en creent de
   //  nouvelles, mais dans les deux cas l'exposition nette raconte la
   //  meme histoire.
   //================================================================
   const int total = HistoryDealsTotal();

   int      clusterId   = 0;
   bool     inCluster   = false;
   double   netVolume   = 0.0;
   int      dir         = 0;
   int      nEntries    = 0;
   double   volSum      = 0.0;
   double   pnlSum      = 0.0;
   datetime openTime    = 0;
   datetime closeTime   = 0;
   double   entryPrice  = 0.0;
   double   exitPrice   = 0.0;
   double   firstSL     = 0.0;
   double   balanceRun  = AccountInfoDouble(ACCOUNT_BALANCE);
   double   balanceBefore = 0.0;

   //--- on reconstitue la balance en remontant le temps depuis maintenant,
   //--- puis on la relit dans l'ordre chronologique
   double allPnl = 0.0;
   for(int i = 0; i < total; i++)
     {
      const ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != sym) continue;
      if(InpMagicFilter != 0 && HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicFilter) continue;
      allPnl += HistoryDealGetDouble(d, DEAL_PROFIT)
              + HistoryDealGetDouble(d, DEAL_SWAP)
              + HistoryDealGetDouble(d, DEAL_COMMISSION);
     }
   balanceRun = AccountInfoDouble(ACCOUNT_BALANCE) - allPnl;   // balance au debut

   int written = 0;

   for(int i = 0; i < total; i++)
     {
      const ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != sym)
         continue;
      if(InpMagicFilter != 0 && HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicFilter)
         continue;

      const ENUM_DEAL_TYPE  dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(d, DEAL_TYPE);
      if(dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL)
         continue;                                 // depot, retrait, credit...

      const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
      const double vol   = HistoryDealGetDouble(d, DEAL_VOLUME);
      const double price = HistoryDealGetDouble(d, DEAL_PRICE);
      const datetime t   = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      const double pnl   = HistoryDealGetDouble(d, DEAL_PROFIT)
                         + HistoryDealGetDouble(d, DEAL_SWAP)
                         + HistoryDealGetDouble(d, DEAL_COMMISSION);

      const int sign = (dtype == DEAL_TYPE_BUY) ? 1 : -1;

      if(entry == DEAL_ENTRY_IN)
        {
         if(!inCluster)
           {
            //--- ouverture d'une grappe
            inCluster     = true;
            clusterId++;
            dir           = sign;
            nEntries      = 0;
            volSum        = 0.0;
            pnlSum        = 0.0;
            openTime      = t;
            entryPrice    = price;
            firstSL       = OpeningStopLoss(d);
            netVolume     = 0.0;
            balanceBefore = balanceRun;
           }
         nEntries++;
         volSum    += vol;
         netVolume += sign * vol;
        }
      else
        {
         netVolume += sign * vol;                  // sortie : sens oppose
         exitPrice  = price;
        }

      pnlSum     += pnl;
      balanceRun += pnl;
      closeTime   = t;

      //--- l'exposition est revenue a zero : la grappe est close
      if(inCluster && MathAbs(netVolume) < 1e-8)
        {
         inCluster = false;

         const ChannelSnap fast = ChannelAt(sym, InpTF_Fast, openTime,
                                            InpChannelBars, hAtrFast, entryPrice);
         const ChannelSnap slow = ChannelAt(sym, InpTF_Slow, openTime,
                                            InpChannelBars, hAtrSlow, entryPrice);
         if(!fast.valid || !slow.valid)
           {
            PrintFormat("[AUTOPSIE] Grappe %d (%s) ignoree : historique de bougies "
                        "insuffisant a cette date.", clusterId,
                        TimeToString(openTime, TIME_DATE | TIME_MINUTES));
            continue;
           }

         double mfeS, maeS, mfeL, maeL;
         ForwardExcursion(sym, openTime, entryPrice, dir, InpFwdShort, fast.atr, mfeS, maeS);
         ForwardExcursion(sym, openTime, entryPrice, dir, InpFwdLong,  fast.atr, mfeL, maeL);

         const double angleDiff = fast.angleDeg - slow.angleDeg;
         const int    aligned   = ((fast.slopeATR > 0.0 && slow.slopeATR > 0.0) ||
                                   (fast.slopeATR < 0.0 && slow.slopeATR < 0.0)) ? 1 : 0;

         const double riskPrice = (firstSL > 0.0) ? MathAbs(entryPrice - firstSL) : 0.0;
         const double rMultiple = (riskPrice > 0.0 && volSum > 0.0)
                                  ? pnlSum / (riskPrice * volSum
                                              * SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE)
                                              / MathMax(1e-12, SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE)))
                                  : 0.0;

         const double pctBalance = (balanceBefore > 0.0) ? pnlSum / balanceBefore * 100.0 : 0.0;

         FileWrite(h,
                   (string)clusterId,
                   (string)AccountInfoInteger(ACCOUNT_LOGIN),
                   sym,
                   TimeToString(openTime,  TIME_DATE | TIME_SECONDS),
                   TimeToString(closeTime, TIME_DATE | TIME_SECONDS),
                   (string)(long)(closeTime - openTime),
                   (dir > 0 ? "BUY" : "SELL"),
                   (string)nEntries,
                   DoubleToString(volSum, 2),
                   DoubleToString(entryPrice, _Digits),
                   DoubleToString(exitPrice, _Digits),
                   DoubleToString(pnlSum, 2),
                   DoubleToString(pctBalance, 4),
                   DoubleToString(balanceBefore, 2),
                   DoubleToString(firstSL, _Digits),
                   DoubleToString(riskPrice, _Digits),
                   DoubleToString(rMultiple, 4),
                   (string)(nEntries > 1 ? 1 : 0),
                   DoubleToString(fast.angleDeg, 4),
                   DoubleToString(fast.slopeATR, 6),
                   DoubleToString(fast.r2, 4),
                   DoubleToString(fast.devFromMid, 4),
                   DoubleToString(fast.atr, _Digits),
                   DoubleToString(slow.angleDeg, 4),
                   DoubleToString(slow.slopeATR, 6),
                   DoubleToString(slow.r2, 4),
                   DoubleToString(slow.devFromMid, 4),
                   DoubleToString(slow.atr, _Digits),
                   DoubleToString(angleDiff, 4),
                   (string)aligned,
                   DoubleToString(mfeS, 4), DoubleToString(maeS, 4),
                   DoubleToString(mfeL, 4), DoubleToString(maeL, 4));
         written++;
        }
     }

   if(inCluster)
      PrintFormat("[AUTOPSIE] Une grappe est encore OUVERTE (%d entrees depuis %s) : "
                  "non exportee.", nEntries, TimeToString(openTime, TIME_DATE | TIME_MINUTES));

   FileClose(h);
   IndicatorRelease(hAtrFast);
   IndicatorRelease(hAtrSlow);

   PrintFormat("[AUTOPSIE] %d grappes exportees sur %d jours vers %s "
               "(dossier COMMUN des terminaux).", written, InpDaysBack, file);
   PrintFormat("[AUTOPSIE] Compte %I64d | symbole %s | canal %d bougies | %s vs %s",
               AccountInfoInteger(ACCOUNT_LOGIN), sym, InpChannelBars,
               EnumToString(InpTF_Fast), EnumToString(InpTF_Slow));
   Print("[AUTOPSIE] Etape suivante : python3 tools/angle_autopsy.py <ce fichier>");

   if(written < 30)
      PrintFormat("[AUTOPSIE] ATTENTION : %d grappes seulement. En dessous d'une "
                  "centaine, aucune regle d'angle ne pourra etre distinguee du "
                  "hasard. Augmente InpDaysBack.", written);
  }
