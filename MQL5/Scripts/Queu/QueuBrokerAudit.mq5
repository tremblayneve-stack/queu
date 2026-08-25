//+------------------------------------------------------------------+
//|                                              QueuBrokerAudit.mq5 |
//|                                                             Queu |
//|                                                                  |
//|  Audit du flux de donnees d'un broker, prealable indispensable a  |
//|  toute strategie de micro-scalping.                              |
//|                                                                  |
//|  Repond a trois questions dont depend TOUT le reste :            |
//|    1. Le delta est-il calculable ? (flags acheteur/vendeur)      |
//|    2. Le volume reel existe-t-il, ou seulement le compte de ticks|
//|    3. Le cout permet-il seulement de scalper ?                   |
//|                                                                  |
//|  A executer sur le graphique du symbole a auditer. Ne trade pas, |
//|  ne modifie rien : lecture seule.                                |
//+------------------------------------------------------------------+
#property copyright "Queu"
#property version   "1.00"
#property script_show_inputs

input int    InpWindowMinutes = 60;    // Fenetre d'analyse des ticks (minutes)
input int    InpBarsToCheck   = 500;   // Bougies M1 examinees pour le volume
input double InpStopPoints    = 0.0;   // Stop envisage en points (0 = estime via ATR M1)

//+------------------------------------------------------------------+
string Line(const int n = 70)
  {
   string s = "";
   for(int i = 0; i < n; i++)
      s += "=";
   return s;
  }

void Head(const string t)
  {
   Print(" ");
   Print(Line());
   Print("  ", t);
   Print(Line());
  }

//+------------------------------------------------------------------+
//| Percentile d'un tableau deja trie.                                |
//+------------------------------------------------------------------+
double Pct(const double &sorted[], const double p)
  {
   int n = ArraySize(sorted);
   if(n == 0)
      return 0.0;

   int idx = (int)MathRound(p * (n - 1));
   if(idx < 0)
      idx = 0;
   if(idx >= n)
      idx = n - 1;

   return sorted[idx];
  }

//+------------------------------------------------------------------+
void OnStart(void)
  {
   string sym   = _Symbol;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

   Head("AUDIT BROKER — " + sym + "  (" + AccountInfoString(ACCOUNT_COMPANY) + ")");
   PrintFormat("  serveur          %s", AccountInfoString(ACCOUNT_SERVER));
   PrintFormat("  heure serveur    %s", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   PrintFormat("  heure GMT        %s", TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS));
   PrintFormat("  decalage serveur %+.1f h par rapport a GMT",
               (double)(TimeCurrent() - TimeGMT()) / 3600.0);

   //================================================================
   Head("1. PROPRIETES DU SYMBOLE");
   PrintFormat("  digits / point            %d  /  %.10g",
               (int)SymbolInfoInteger(sym, SYMBOL_DIGITS), point);
   PrintFormat("  tick size / tick value    %.10g  /  %.5f %s",
               SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE),
               SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE),
               AccountInfoString(ACCOUNT_CURRENCY));
   PrintFormat("  volume min / step / max   %.2f  /  %.2f  /  %.2f",
               SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN),
               SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP),
               SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX));
   PrintFormat("  stops level / freeze      %d  /  %d points",
               (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL),
               (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL));
   PrintFormat("  spread flottant           %s",
               SymbolInfoInteger(sym, SYMBOL_SPREAD_FLOAT) ? "oui" : "NON (fixe)");
   PrintFormat("  mode d'execution          %d  (2 = Market, 3 = Exchange)",
               (int)SymbolInfoInteger(sym, SYMBOL_TRADE_EXEMODE));
   PrintFormat("  mode de calcul            %d  (0 = Forex, 2 = CFD, 4 = Exchange)",
               (int)SymbolInfoInteger(sym, SYMBOL_TRADE_CALC_MODE));

   long stopsLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopsLevel > 0)
      PrintFormat("  ATTENTION : stops level de %d points. Aucun stop ne peut etre "
                  "place plus pres que ca du marche — plancher dur pour tout scalp.",
                  (int)stopsLevel);

   //================================================================
   Head("2. TICKS — LE DELTA EST-IL CALCULABLE ?");

   MqlTick ticks[];
   ulong toMsc   = (ulong)TimeCurrent() * 1000;
   ulong fromMsc = toMsc - (ulong)InpWindowMinutes * 60 * 1000;

   int n = -1;
   for(int attempt = 0; attempt < 5 && n < 0; attempt++)
     {
      n = CopyTicksRange(sym, ticks, COPY_TICKS_ALL, fromMsc, toMsc);
      if(n < 0)
         Sleep(500);            // le terminal telecharge encore l'historique
     }

   if(n <= 0)
     {
      PrintFormat("  ECHEC : aucun tick recupere (erreur %d).", GetLastError());
      Print("  Ouvre le graphique, laisse le terminal telecharger, puis relance.");
      return;
     }

   int cBid = 0, cAsk = 0, cLast = 0, cVol = 0, cBuy = 0, cSell = 0;
   double volRealSum = 0.0;

   for(int i = 0; i < n; i++)
     {
      uint f = ticks[i].flags;
      if((f & TICK_FLAG_BID)    != 0) cBid++;
      if((f & TICK_FLAG_ASK)    != 0) cAsk++;
      if((f & TICK_FLAG_LAST)   != 0) cLast++;
      if((f & TICK_FLAG_VOLUME) != 0) cVol++;
      if((f & TICK_FLAG_BUY)    != 0) cBuy++;
      if((f & TICK_FLAG_SELL)   != 0) cSell++;
      volRealSum += ticks[i].volume_real;
     }

   PrintFormat("  fenetre                   %d minutes,  %d ticks", InpWindowMinutes, n);
   PrintFormat("  TICK_FLAG_BID             %6d  (%5.1f%%)", cBid,  100.0 * cBid  / n);
   PrintFormat("  TICK_FLAG_ASK             %6d  (%5.1f%%)", cAsk,  100.0 * cAsk  / n);
   PrintFormat("  TICK_FLAG_LAST            %6d  (%5.1f%%)", cLast, 100.0 * cLast / n);
   PrintFormat("  TICK_FLAG_VOLUME          %6d  (%5.1f%%)", cVol,  100.0 * cVol  / n);
   PrintFormat("  TICK_FLAG_BUY             %6d  (%5.1f%%)  <-- decisif", cBuy,  100.0 * cBuy  / n);
   PrintFormat("  TICK_FLAG_SELL            %6d  (%5.1f%%)  <-- decisif", cSell, 100.0 * cSell / n);
   PrintFormat("  somme volume_real         %.2f", volRealSum);

   bool deltaOk = (cBuy + cSell) > n / 20;    // au moins 5% des ticks etiquetes

   Print(" ");
   if(deltaOk)
     {
      Print("  >>> DELTA CALCULABLE. Les ticks portent le sens de l'agresseur.");
      Print("      Absorption, divergence delta/prix et cascades sont implementables");
      Print("      au sens propre de la specification.");
     }
   else
     {
      Print("  >>> DELTA NON CALCULABLE sur ce flux.");
      Print("      Les ticks ne sont que des mises a jour de COTATION, pas des");
      Print("      transactions avec sens d'agresseur. Toute 'absorption' ou");
      Print("      'divergence delta' construite la-dessus mesurerait autre chose");
      Print("      que ce qu'elle pretend. Seuls des PROXY explicites sont honnetes :");
      Print("      regle du tick (sens du mid), intensite de cotation, dynamique du spread.");
     }

   //================================================================
   Head("3. VOLUME — REEL OU COMPTE DE TICKS ?");

   MqlRates rates[];
   int nb = CopyRates(sym, PERIOD_M1, 1, InpBarsToCheck, rates);
   if(nb > 0)
     {
      long sumTick = 0, sumReal = 0;
      int  barsWithReal = 0;
      for(int i = 0; i < nb; i++)
        {
         sumTick += rates[i].tick_volume;
         sumReal += (long)rates[i].real_volume;
         if(rates[i].real_volume > 0)
            barsWithReal++;
        }
      PrintFormat("  bougies M1 examinees      %d", nb);
      PrintFormat("  somme tick_volume         %I64d", sumTick);
      PrintFormat("  somme real_volume         %I64d", sumReal);
      PrintFormat("  bougies avec real_volume  %d / %d  (%.1f%%)",
                  barsWithReal, nb, 100.0 * barsWithReal / nb);

      Print(" ");
      if(barsWithReal > nb / 2)
         Print("  >>> VOLUME REEL DISPONIBLE. Profil de volume et LVN implementables.");
      else
        {
         Print("  >>> PAS DE VOLUME REEL. Le champ 'volume' est un COMPTE DE TICKS :");
         Print("      il mesure l'activite de cotation, pas la taille echangee.");
         Print("      Un 'Low Volume Node' construit dessus est un noeud de faible");
         Print("      ACTIVITE, ce qui n'est pas la meme chose — utile, mais a nommer");
         Print("      correctement.");
        }
     }

   //================================================================
   Head("4. CARNET D'ORDRES (niveau 2)");

   MqlBookInfo book[];
   bool bookAdded = MarketBookAdd(sym);
   Sleep(300);
   bool bookOk = bookAdded && MarketBookGet(sym, book) && ArraySize(book) > 0;

   if(bookOk)
     {
      PrintFormat("  profondeur disponible     %d niveaux", ArraySize(book));
      Print("  >>> CARNET DISPONIBLE.");
     }
   else
     {
      PrintFormat("  MarketBookAdd             %s", bookAdded ? "accepte" : "refuse");
      PrintFormat("  niveaux recus             %d", ArraySize(book));
      Print("  >>> PAS DE CARNET EXPLOITABLE. L'absorption au sens carnet");
      Print("      (gros bloc passif qui encaisse) n'est pas observable.");
     }
   if(bookAdded)
      MarketBookRelease(sym);

   //================================================================
   Head("5. COUT — LE SCALPING EST-IL SEULEMENT POSSIBLE ?");

   double spreads[];
   ArrayResize(spreads, n);
   int ns = 0;
   long maxGapMsc = 0;

   for(int i = 0; i < n; i++)
     {
      if(ticks[i].ask > 0.0 && ticks[i].bid > 0.0 && point > 0.0)
        {
         spreads[ns] = (ticks[i].ask - ticks[i].bid) / point;
         ns++;
        }
      if(i > 0)
        {
         long gap = (long)(ticks[i].time_msc - ticks[i - 1].time_msc);
         if(gap > maxGapMsc)
            maxGapMsc = gap;
        }
     }
   ArrayResize(spreads, ns);

   if(ns > 0)
     {
      ArraySort(spreads);
      double med = Pct(spreads, 0.50);
      double p90 = Pct(spreads, 0.90);
      double p99 = Pct(spreads, 0.99);

      PrintFormat("  spread median             %.1f points", med);
      PrintFormat("  spread p90                %.1f points", p90);
      PrintFormat("  spread p99                %.1f points", p99);
      PrintFormat("  spread max                %.1f points", spreads[ns - 1]);
      PrintFormat("  cadence                   %.2f ticks/seconde",
                  (double)n / (InpWindowMinutes * 60.0));
      PrintFormat("  plus long silence         %.1f secondes", maxGapMsc / 1000.0);

      //--- distance de stop de reference
      double stopPts = InpStopPoints;
      if(stopPts <= 0.0)
        {
         int h = iATR(sym, PERIOD_M1, 14);
         double buf[];
         if(h != INVALID_HANDLE && CopyBuffer(h, 0, 1, 1, buf) == 1 && point > 0.0)
            stopPts = (buf[0] / point) * 1.5;      // stop micro ~ 1.5 ATR M1
         if(h != INVALID_HANDLE)
            IndicatorRelease(h);
        }

      if(stopPts > 0.0)
        {
         Print(" ");
         PrintFormat("  Stop de reference retenu  %.1f points%s", stopPts,
                     InpStopPoints > 0.0 ? " (saisi)" : " (1.5 x ATR M1)");
         Print(" ");
         Print("  Taux de reussite minimal  p* = (1 + cout/stop) / (cible + 1)");
         Print(" ");
         PrintFormat("  %-22s %10s %10s %10s", "cout retenu", "0.8 R", "1.3 R", "1.8 R");

         double costs[3];
         string labels[3];
         costs[0] = med;  labels[0] = "spread median";
         costs[1] = p90;  labels[1] = "spread p90";
         costs[2] = p90 + stopPts * 0.1; labels[2] = "p90 + slippage 10%";

         for(int c = 0; c < 3; c++)
           {
            double f = costs[c] / stopPts;
            string row = StringFormat("  %-22s", labels[c]);
            double ks[3];
            ks[0] = 0.8; ks[1] = 1.3; ks[2] = 1.8;
            for(int j = 0; j < 3; j++)
              {
               double p = (1.0 + f) / (ks[j] + 1.0);
               row += StringFormat("%9.1f%%", p * 100.0);
              }
            Print(row);
           }

         double fMed = med / stopPts;
         Print(" ");
         PrintFormat("  f median = %.3f", fMed);
         if(fMed > 0.5)
            Print("  >>> COUT PROHIBITIF a cette distance de stop. Il faut soit un stop "
                  "nettement plus large, soit renoncer au micro-scalping sur ce symbole.");
         else
            if(fMed > 0.25)
               Print("  >>> COUT LOURD mais pas redhibitoire. Viser au moins 1.8 R, "
                     "et surveiller le p90 : c'est lui qui decide en pratique.");
            else
               Print("  >>> COUT SUPPORTABLE. Le facteur limitant sera la qualite du signal.");
        }
     }

   //================================================================
   Head("VERDICT PAR COUCHE DE LA SPECIFICATION");
   PrintFormat("  Couche 0  etat micro          %s", "PARTIEL — sans delta ni volume reel, l'etat");
   Print("                                se lit sur le spread, la cadence et la volatilite");
   PrintFormat("  Couche 1  forced micro-move   %s", deltaOk ? "COMPLET" : "PROXY SEULEMENT");
   Print("  Couche 2  toxicite            IMPLEMENTABLE — spread, cadence, oscillation");
   Print("  Couche 3  veto rapide         IMPLEMENTABLE");
   Print("  Couche 4  risque micro        IMPLEMENTABLE — deja en place dans l'EA");
   Print(" ");
   Print("  Copie ce rapport et transmets-le : il determine ce qui peut etre construit.");
   Print(Line());
  }
