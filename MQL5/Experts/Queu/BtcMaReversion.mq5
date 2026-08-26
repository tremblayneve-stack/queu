//+------------------------------------------------------------------+
//|                                                BtcMaReversion.mq5|
//|                                                             Queu |
//|                                                                  |
//|  Retour a la moyenne mobile sur BTC.                             |
//|                                                                  |
//|  Le prix s'ecarte VITE de sa moyenne mobile, on prend le         |
//|  contre-pied, on sort au retour sur la moyenne.                  |
//|                                                                  |
//|  Concu pour le BALAYAGE : le type de moyenne, sa periode et le   |
//|  timeframe de travail sont de simples inputs. Deux parametres    |
//|  couvrent EMA 9 / 14 / 20 / 21 et SMA 20, et un troisieme couvre |
//|  M1 et M5, sans jamais toucher au code ni changer de graphique.  |
//|                                                                  |
//|  DEUX CONDITIONS DISTINCTES, a ne pas confondre :                |
//|    InpMinDistATR       le prix est LOIN de la moyenne            |
//|    InpMinExpansionATR  il s'en est eloigne VITE                  |
//|  Une derive lente a 3 ATR de la moyenne est une tendance, pas    |
//|  une sur-extension. Les deux seuils sont separes pour que tu     |
//|  puisses mesurer lequel porte reellement le signal.              |
//|                                                                  |
//|  Fichier autonome : aucun indicateur custom, aucune dependance.  |
//+------------------------------------------------------------------+
#property copyright "Queu"
#property version   "1.00"
#property description "BTC mean reversion : ecart rapide a une MA parametrable, sortie au retour"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Parametres                                                        |
//+------------------------------------------------------------------+
input group "=== Moyenne mobile (a balayer) ==="
input ENUM_TIMEFRAMES InpTimeframe   = PERIOD_M5;  // Timeframe de travail (M1 ou M5)
input ENUM_MA_METHOD  InpMA_Method   = MODE_EMA;   // Type de moyenne (EMA / SMA / SMMA / LWMA)
input int             InpMA_Period   = 20;         // Periode de la moyenne
input ENUM_APPLIED_PRICE InpMA_Price = PRICE_CLOSE;// Prix applique

input group "=== Declenchement ==="
input int    InpATR_Period        = 14;    // Periode ATR
input double InpMinDistATR        = 2.0;   // Distance MINIMALE a la MA (x ATR) — a optimiser
input double InpMinExpansionATR   = 1.0;   // Expansion MINIMALE sur N bougies (x ATR)
input int    InpExpansionBars     = 5;     // N : fenetre de mesure de l'expansion
input double InpMaxDistATR        = 0.0;   // Distance MAXIMALE (0 = off) — ecarte les cassures

input group "=== Filtre de regime ==="
input double InpMaxMASlopeATR     = 0.0;   // Pente max de la MA sur N bougies, x ATR (0 = off)
input int    InpSlopeBars         = 20;    // Fenetre de mesure de la pente

input group "=== Sorties ==="
input double InpSL_ATR            = 2.5;   // Stop loss = X x ATR
input bool   InpStopBeyondExtreme = true;  // Reculer le stop derriere l'extreme de l'excursion
input int    InpExtremeLookback   = 5;     // Bougies definissant cet extreme
input double InpExtremeBufferATR  = 0.30;  // Marge au-dela de l'extreme (x ATR)
input int    InpMaxBarsInTrade    = 40;    // Time-stop en bougies (0 = off)
input double InpMinRR             = 0.50;  // Ratio gain/risque minimal exige

input group "=== Risque et execution ==="
input double InpRiskPercent       = 0.5;   // Risque par trade (% du balance)
input double InpMaxSpreadPts      = 0.0;   // Spread max en points (0 = off)
input ulong  InpMagicNumber       = 990177;// Magic number
input ulong  InpSlippage          = 100;   // Deviation maximale (points)
input bool   InpEnableTrading     = true;  // Autoriser l'ouverture
input bool   InpVerboseLog        = false; // Journal detaille (couteux en optimisation)

//+------------------------------------------------------------------+
//| Etat global                                                       |
//+------------------------------------------------------------------+
CTrade   g_trade;

int      g_hMA  = INVALID_HANDLE;
int      g_hATR = INVALID_HANDLE;

ENUM_TIMEFRAMES g_tf = PERIOD_CURRENT;
datetime g_lastBarTime = 0;
double   g_point  = 0.0;
int      g_digits = 0;

//--- photographie du marche a la cloture de la bougie 1
struct Context
  {
   bool     valid;
   double   ma1;          // MA sur la bougie 1
   double   maPast;       // MA il y a InpSlopeBars bougies
   double   close1;       // cloture de la bougie 1
   double   atr1;         // ATR sur la bougie 1
   double   dist;         // ecart signe : close1 - ma1
   double   distATR;      // |ecart| en multiples d'ATR
   double   expansionATR; // croissance de l'ecart sur InpExpansionBars, en ATR
   double   slopeATR;     // pente de la MA sur InpSlopeBars, en ATR
  };

//--- description d'un signal pret a l'execution
struct Setup
  {
   bool     valid;
   int      dir;          // +1 achat, -1 vente
   double   entry;
   double   sl;
   double   tp;
   double   rr;
   string   reason;
  };

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 1 — UTILITAIRES BROKER                                  |
//|                                                                  |
//+------------------------------------------------------------------+

double MinStopDistance(void)
  {
   const long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops, freeze) * g_point;
  }

//+------------------------------------------------------------------+
//| Arrondi sur la grille de ticks : NormalizeDouble seul ne suffit   |
//| pas, certains brokers cotent par pas superieur au dernier chiffre.|
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
  {
   const double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      return NormalizeDouble(price, g_digits);
   return NormalizeDouble(MathRound(price / tick) * tick, g_digits);
  }

//+------------------------------------------------------------------+
//| Aligne un volume sur le pas du broker.                            |
//| Retourne 0 si le resultat tombe sous le minimum : remonter        |
//| silencieusement au lot minimum ferait depasser le risque annonce. |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
  {
   const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;

   volume = MathFloor(volume / step + 1e-8) * step;   // epsilon anti-arrondi

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

double CurrentSpreadPoints(void)
  {
   if(g_point <= 0.0)
      return 0.0;
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK)
           - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
  }

int CountOwnPositions(void)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 2 — LECTURE DU MARCHE                                   |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Copie 'count' valeurs a partir de la bougie 'start'.               |
//|                                                                   |
//| ArraySetAsSeries(true) rend l'indexation intuitive : out[0]       |
//| correspond a 'start', out[1] a la bougie precedente. Sans cela    |
//| l'ordre est inverse, et une pente lue a l'envers donne exactement |
//| le signal contraire sans jamais lever d'erreur.                   |
//+------------------------------------------------------------------+
bool ReadBuffer(const int handle, const int start, const int count, double &out[])
  {
   ArraySetAsSeries(out, true);
   if(CopyBuffer(handle, 0, start, count, out) != count)
      return false;
   for(int i = 0; i < count; i++)
      if(out[i] == EMPTY_VALUE)
         return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Toutes les mesures necessaires a la decision, en une passe.       |
//+------------------------------------------------------------------+
Context ReadContext(void)
  {
   Context c;
   c.valid = false;
   c.ma1 = c.maPast = c.close1 = c.atr1 = 0.0;
   c.dist = c.distATR = c.expansionATR = c.slopeATR = 0.0;

   const int needed = MathMax(InpExpansionBars, InpSlopeBars) + 2;

   double ma[], atr[];
   if(!ReadBuffer(g_hMA, 1, needed, ma))
      return c;
   if(!ReadBuffer(g_hATR, 1, 1, atr) || atr[0] <= 0.0)
      return c;

   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, g_tf, 1, needed, closes) != needed)
      return c;

   c.ma1    = ma[0];
   c.close1 = closes[0];
   c.atr1   = atr[0];

   if(c.ma1 <= 0.0 || c.close1 <= 0.0)
      return c;

   c.dist    = c.close1 - c.ma1;
   c.distATR = MathAbs(c.dist) / c.atr1;

   //--- expansion : de combien l'ecart a-t-il GRANDI sur la fenetre.
   //--- C'est la mesure de « rapidement », distincte de « loin ».
   const int eb = MathMin(InpExpansionBars, needed - 1);
   const double distPast = MathAbs(closes[eb] - ma[eb]);
   c.expansionATR = (MathAbs(c.dist) - distPast) / c.atr1;

   //--- pente de la MA elle-meme, normalisee : sans normalisation aucun
   //--- seuil n'est transposable d'un regime de volatilite a l'autre
   const int sb = MathMin(InpSlopeBars, needed - 1);
   c.maPast   = ma[sb];
   c.slopeATR = (c.ma1 - c.maPast) / c.atr1;

   c.valid = true;
   return c;
  }

//+------------------------------------------------------------------+
//| Extreme de l'excursion sur les dernieres bougies closes.          |
//+------------------------------------------------------------------+
bool ExcursionExtreme(const bool wantHigh, double &value)
  {
   const int n = MathMax(1, InpExtremeLookback);
   double buf[];
   const int got = wantHigh ? CopyHigh(_Symbol, g_tf, 1, n, buf)
                            : CopyLow(_Symbol, g_tf, 1, n, buf);
   if(got != n)
      return false;

   value = buf[0];
   for(int i = 1; i < n; i++)
      value = wantHigh ? MathMax(value, buf[i]) : MathMin(value, buf[i]);
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 3 — SIGNAL                                              |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Construit le setup complet, ou renvoie invalide avec la raison.   |
//|                                                                   |
//| Ordre des tests : du moins couteux au plus couteux, et du plus    |
//| discriminant au moins discriminant, pour que le journal indique   |
//| la vraie cause du rejet.                                          |
//+------------------------------------------------------------------+
Setup BuildSetup(const Context &c)
  {
   Setup s;
   s.valid = false;
   s.dir = 0;
   s.entry = s.sl = s.tp = s.rr = 0.0;
   s.reason = "";

   if(!c.valid)
      return s;

   //--- 1. le prix est-il assez LOIN de la moyenne ?
   if(c.distATR < InpMinDistATR)
      return s;

   //--- ecart absurde : au-dela, ce n'est plus une sur-extension mais une
   //--- cassure de regime, et le retour a la moyenne n'a plus de raison
   if(InpMaxDistATR > 0.0 && c.distATR > InpMaxDistATR)
     {
      if(InpVerboseLog)
         PrintFormat("[SIGNAL] Ecart %.2f ATR > plafond %.2f : cassure probable.",
                     c.distATR, InpMaxDistATR);
      return s;
     }

   //--- 2. s'en est-il eloigne VITE ? Une derive lente est une tendance.
   if(InpMinExpansionATR > 0.0 && c.expansionATR < InpMinExpansionATR)
     {
      if(InpVerboseLog)
         PrintFormat("[SIGNAL] Ecart de %.2f ATR mais expansion de seulement "
                     "%.2f ATR sur %d bougies : derive, pas impulsion.",
                     c.distATR, c.expansionATR, InpExpansionBars);
      return s;
     }

   //--- 3. filtre de regime : fader une MA en pente forte revient a se
   //---    placer devant le mouvement. C'est le mode d'echec principal du
   //---    retour a la moyenne sur BTC.
   const int dir = (c.dist > 0.0) ? -1 : 1;   // au-dessus -> vendre

   if(InpMaxMASlopeATR > 0.0)
     {
      const bool against = (dir > 0 && c.slopeATR < 0.0) || (dir < 0 && c.slopeATR > 0.0);
      if(against && MathAbs(c.slopeATR) > InpMaxMASlopeATR)
        {
         if(InpVerboseLog)
            PrintFormat("[SIGNAL] Ecarte : pente de la MA %.2f ATR contre le trade "
                        "(plafond %.2f).", c.slopeATR, InpMaxMASlopeATR);
         return s;
        }
     }

   //--- geometrie
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return s;

   s.entry = (dir > 0) ? ask : bid;

   //--- stop : multiple d'ATR, eventuellement recule derriere l'extreme
   //--- de l'excursion pour ne pas se faire sortir par la meche qui a
   //--- justement cree le signal
   double slPrice = (dir > 0) ? s.entry - InpSL_ATR * c.atr1
                              : s.entry + InpSL_ATR * c.atr1;

   if(InpStopBeyondExtreme)
     {
      double extreme;
      if(ExcursionExtreme(dir < 0, extreme))
        {
         const double buffer = InpExtremeBufferATR * c.atr1;
         const double beyond = (dir > 0) ? extreme - buffer : extreme + buffer;
         //--- on ne garde que le plus PROTECTEUR des deux
         slPrice = (dir > 0) ? MathMin(slPrice, beyond) : MathMax(slPrice, beyond);
        }
     }

   //--- cible : la moyenne mobile. C'est la sortie principale ; la gestion
   //--- dynamique fermera plus tot si la MA vient a la rencontre du prix.
   const double tpPrice = c.ma1;

   const double risk   = MathAbs(s.entry - slPrice);
   const double reward = MathAbs(tpPrice - s.entry);

   if(risk <= 0.0 || reward <= 0.0)
      return s;

   //--- la cible doit etre du bon cote de l'entree
   if((dir > 0 && tpPrice <= s.entry) || (dir < 0 && tpPrice >= s.entry))
     {
      if(InpVerboseLog)
         Print("[SIGNAL] Ecarte : la MA est deja depassee, plus rien a capter.");
      return s;
     }

   s.rr = reward / risk;

   //--- sur ce schema le stop est large et la cible proche : sans ce filtre
   //--- on risque regulierement 3 pour gagner 1
   if(InpMinRR > 0.0 && s.rr < InpMinRR)
     {
      if(InpVerboseLog)
         PrintFormat("[SIGNAL] Ecarte : ratio %.2f < %.2f exige.", s.rr, InpMinRR);
      return s;
     }

   s.dir   = dir;
   s.sl    = slPrice;
   s.tp    = tpPrice;
   s.valid = true;
   s.reason = StringFormat(
                 "%s | close=%.2f MA=%.2f ecart=%.2f ATR (min %.2f) | expansion=%.2f ATR "
                 "sur %d bougies | pente MA=%.2f ATR | ATR=%.2f | RR=%.2f",
                 (dir > 0 ? "ACHAT" : "VENTE"), c.close1, c.ma1, c.distATR,
                 InpMinDistATR, c.expansionATR, InpExpansionBars, c.slopeATR,
                 c.atr1, s.rr);
   return s;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 4 — RISQUE                                              |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Volume risquant InpRiskPercent du balance sur la distance de stop |
//| REELLE transmise, apres elargissement eventuel au stops level.    |
//+------------------------------------------------------------------+
double CalculateLot(const double stopDistance)
  {
   if(stopDistance <= 0.0)
      return 0.0;

   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
     {
      Print("[RISQUE] Tick value ou tick size invalide : dimensionnement impossible.");
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
      PrintFormat("[RISQUE] Volume calcule %.4f sous le lot minimum %.2f. Trade "
                  "IGNORE plutot que de depasser %.2f%% (balance %.2f, stop %.2f).",
                  raw, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                  InpRiskPercent, balance, stopDistance);
   return lot;
  }

bool HasMargin(const ENUM_ORDER_TYPE type, const double volume, const double price)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, volume, price, margin))
     {
      PrintFormat("[RISQUE] OrderCalcMargin a echoue (%d).", GetLastError());
      return false;
     }
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      PrintFormat("[RISQUE] Marge requise %.2f > marge libre %.2f.",
                  margin, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 5 — EXECUTION                                           |
//|                                                                  |
//+------------------------------------------------------------------+

bool ExecuteSetup(Setup &s)
  {
   const double minDist = MinStopDistance();

   double sl = s.sl;
   double tp = s.tp;

   //--- plancher broker : on elargit plutot que de se faire rejeter
   if(s.dir > 0)
     {
      if(s.entry - sl < minDist) sl = s.entry - minDist;
      if(tp - s.entry < minDist) tp = s.entry + minDist;
     }
   else
     {
      if(sl - s.entry < minDist) sl = s.entry + minDist;
      if(s.entry - tp < minDist) tp = s.entry - minDist;
     }

   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   //--- le volume se calcule sur la distance REELLE, apres normalisation
   const double realStop = MathAbs(s.entry - sl);
   const double lot = CalculateLot(realStop);
   if(lot <= 0.0)
      return false;

   const ENUM_ORDER_TYPE type = (s.dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!HasMargin(type, lot, s.entry))
      return false;

   PrintFormat("[ENTREE] %s", s.reason);
   PrintFormat("[ENTREE] %.2f lot | entree %.2f | SL %.2f (%.2f) | TP %.2f",
               lot, s.entry, sl, realStop, tp);

   const bool ok = (s.dir > 0)
                   ? g_trade.Buy(lot, _Symbol, 0.0, sl, tp, "MA-REV")
                   : g_trade.Sell(lot, _Symbol, 0.0, sl, tp, "MA-REV");

   if(!ok)
     {
      const uint rc = g_trade.ResultRetcode();
      PrintFormat("[ERREUR] Ouverture refusee : retcode=%u (%s), erreur=%d",
                  rc, g_trade.ResultRetcodeDescription(), GetLastError());
      switch(rc)
        {
         case TRADE_RETCODE_INVALID_STOPS:
            Print("[ERREUR] Stops refuses : verifie SYMBOL_TRADE_STOPS_LEVEL."); break;
         case TRADE_RETCODE_INVALID_VOLUME:
            Print("[ERREUR] Volume refuse : verifie min/max/step."); break;
         case TRADE_RETCODE_NO_MONEY:
            Print("[ERREUR] Fonds insuffisants."); break;
         case TRADE_RETCODE_MARKET_CLOSED:
            Print("[ERREUR] Marche ferme."); break;
         case TRADE_RETCODE_REQUOTE:
         case TRADE_RETCODE_PRICE_CHANGED:
         case TRADE_RETCODE_PRICE_OFF:
            Print("[ERREUR] Prix change pendant l'envoi : augmente InpSlippage."); break;
         default: break;
        }
      return false;
     }

   PrintFormat("[ENTREE] Execute a %.2f, volume %.2f.",
               g_trade.ResultPrice(), g_trade.ResultVolume());
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 6 — GESTION DE POSITION                                 |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Sortie principale : retour sur la moyenne mobile.                 |
//|                                                                   |
//| Le TP place chez le broker vise la MA telle qu'elle etait A       |
//| L'ENTREE : c'est un filet de securite si le terminal se           |
//| deconnecte. Mais la MA se deplace vers le prix pendant le retour, |
//| donc la sortie dynamique ci-dessous se declenche presque toujours |
//| la premiere, et a un meilleur prix.                               |
//|                                                                   |
//| On lit la MA sur la bougie 0 : c'est sa valeur COURANTE, la seule |
//| pertinente pour decider de sortir maintenant.                     |
//+------------------------------------------------------------------+
void ManageOpenPosition(void)
  {
   if(CountOwnPositions() == 0)
      return;

   double ma[];
   if(!ReadBuffer(g_hMA, 0, 1, ma))
      return;
   const double maNow = ma[0];
   if(maNow <= 0.0)
      return;

   const long barSec = (long)PeriodSeconds(g_tf);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      const bool isBuy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)
                          == POSITION_TYPE_BUY);
      const double market = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                  : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(market <= 0.0)
         continue;

      string why = "";

      //--- le prix a rejoint la moyenne : objectif atteint
      if((isBuy && market >= maNow) || (!isBuy && market <= maNow))
         why = StringFormat("retour sur la MA (%.2f)", maNow);

      //--- un retour a la moyenne qui n'a pas eu lieu au bout de N bougies
      //--- a probablement echoue : on libere le capital
      if(why == "" && InpMaxBarsInTrade > 0 && barSec > 0)
        {
         const long age = (long)(TimeCurrent()
                                 - (datetime)PositionGetInteger(POSITION_TIME));
         if(age >= (long)InpMaxBarsInTrade * barSec)
            why = StringFormat("time-stop (%d bougies)", InpMaxBarsInTrade);
        }

      if(why == "")
         continue;

      if(g_trade.PositionClose(ticket))
         PrintFormat("[SORTIE] #%I64u ferme : %s.", ticket, why);
      else
         PrintFormat("[ERREUR] Cloture refusee : retcode=%u (%s)",
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 7 — CYCLE DE VIE                                        |
//|                                                                  |
//+------------------------------------------------------------------+

int OnInit(void)
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_tf     = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period()
                                               : InpTimeframe;

   if(g_point <= 0.0)
     {
      Print("[INIT] Point du symbole indisponible.");
      return INIT_FAILED;
     }

   //--- validation
   if(InpMA_Period < 2)
     {
      Print("[INIT] InpMA_Period doit valoir au moins 2.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpATR_Period < 2)
     {
      Print("[INIT] InpATR_Period doit valoir au moins 2.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinDistATR <= 0.0)
     {
      Print("[INIT] InpMinDistATR doit etre strictement positif.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxDistATR > 0.0 && InpMaxDistATR <= InpMinDistATR)
     {
      Print("[INIT] InpMaxDistATR doit depasser InpMinDistATR, sinon aucune "
            "distance ne satisfait les deux bornes.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpExpansionBars < 1 || InpSlopeBars < 1)
     {
      Print("[INIT] InpExpansionBars et InpSlopeBars doivent valoir au moins 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpSL_ATR <= 0.0)
     {
      Print("[INIT] InpSL_ATR doit etre strictement positif : cet EA ne trade "
            "jamais sans stop.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 5.0)
     {
      Print("[INIT] InpRiskPercent doit etre dans ]0, 5]. La consigne est 0.5 %.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- handles, tous sur le timeframe de TRAVAIL et non celui du graphique
   g_hMA  = iMA(_Symbol, g_tf, InpMA_Period, 0, InpMA_Method, InpMA_Price);
   g_hATR = iATR(_Symbol, g_tf, InpATR_Period);

   if(g_hMA == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
     {
      PrintFormat("[INIT] Creation des handles impossible (erreur %d).", GetLastError());
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   //--- amorce : pas d'evaluation de la bougie deja en cours a l'attachement
   g_lastBarTime = iTime(_Symbol, g_tf, 0);

   PrintFormat("[INIT] BtcMaReversion | %s | TF de travail %s | MA %s(%d) sur %s | "
               "ATR %d | dist>=%.2f exp>=%.2f | SL %.1fx | risque %.2f%% | magic %I64u",
               _Symbol, EnumToString(g_tf), EnumToString(InpMA_Method), InpMA_Period,
               EnumToString(InpMA_Price), InpATR_Period, InpMinDistATR,
               InpMinExpansionATR, InpSL_ATR, InpRiskPercent, InpMagicNumber);

   if(g_tf != (ENUM_TIMEFRAMES)Period())
      PrintFormat("[INIT] Attention : TF de travail (%s) different du graphique (%s). "
                  "Dans le testeur, lance le test SUR le timeframe de travail, sinon "
                  "la modelisation des ticks ne correspondra pas aux bougies lues.",
                  EnumToString(g_tf), EnumToString((ENUM_TIMEFRAMES)Period()));

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hMA  != INVALID_HANDLE) IndicatorRelease(g_hMA);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   g_hMA = g_hATR = INVALID_HANDLE;

   PrintFormat("[DEINIT] Arret, raison %d.", reason);
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   //--- la sortie tourne a CHAQUE TICK : le retour sur la moyenne peut se
   //--- produire en milieu de bougie, l'attendre couterait le mouvement
   ManageOpenPosition();

   //--- les entrees ne s'evaluent qu'a la cloture d'une bougie
   const datetime barTime = iTime(_Symbol, g_tf, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;
   g_lastBarTime = barTime;

   if(!InpEnableTrading)
      return;

   if(!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   //--- une seule position a la fois
   if(CountOwnPositions() >= 1)
      return;

   if(InpMaxSpreadPts > 0.0)
     {
      const double sp = CurrentSpreadPoints();
      if(sp > InpMaxSpreadPts)
        {
         if(InpVerboseLog)
            PrintFormat("[GARDE] Spread %.0f > %.0f : bougie ignoree.",
                        sp, InpMaxSpreadPts);
         return;
        }
     }

   const Context c = ReadContext();
   Setup s = BuildSetup(c);
   if(s.valid)
      ExecuteSetup(s);
  }
//+------------------------------------------------------------------+
