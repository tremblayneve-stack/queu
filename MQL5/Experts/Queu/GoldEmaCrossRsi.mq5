//+------------------------------------------------------------------+
//|                                              GoldEmaCrossRsi.mq5 |
//|                                                             Queu |
//|                                                                  |
//|  XAUUSD H1 — croisement EMA 20 / EMA 50 filtre par le RSI 14.    |
//|                                                                  |
//|  Long  : EMA20 croise AU-DESSUS de EMA50 sur la bougie fermee    |
//|           (index 1) ET RSI(14) > 50                              |
//|  Short : croisement inverse ET RSI(14) < 50                      |
//|                                                                  |
//|  Stop  : 1.5 x ATR(14)        Cible : 3.0 x ATR(14)              |
//|  Risque: 0.8 % du balance     Une seule position a la fois       |
//|                                                                  |
//|  Fichier autonome : aucun indicateur custom, aucune dependance.  |
//|                                                                  |
//|  NOTE SUR LE FILTRE DE SPREAD : « 35 points » n'a pas le meme    |
//|  sens selon le broker. Sur un XAUUSD a 2 decimales, 35 points    |
//|  valent 0.35 USD ; a 3 decimales, 0.035 USD. L'EA affiche les    |
//|  decimales et le spread median au demarrage : VERIFIE que le     |
//|  seuil correspond a ce que tu crois avant de lancer quoi que ce  |
//|  soit.                                                            |
//+------------------------------------------------------------------+
#property copyright "Queu"
#property version   "1.00"
#property description "XAUUSD H1 : croisement EMA 20/50 filtre RSI 14, stops en ATR"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Parametres                                                        |
//+------------------------------------------------------------------+
input group "=== Indicateurs ==="
input int    InpFastEMA        = 20;         // Periode EMA rapide
input int    InpSlowEMA        = 50;         // Periode EMA lente
input int    InpRSI_Period     = 14;         // Periode RSI
input double InpRSI_Level      = 50.0;       // Seuil RSI (long au-dessus, short en dessous)
input int    InpATR_Period     = 14;         // Periode ATR

input group "=== Geometrie ==="
input double InpSL_ATR         = 1.5;        // Stop loss  = X x ATR
input double InpTP_ATR         = 3.0;        // Take profit = X x ATR

input group "=== Risque et execution ==="
input double InpRiskPercent    = 0.8;        // Risque par trade (% du balance)
input double InpMaxSpreadPts   = 35.0;       // Spread maximum, en points (0 = filtre off)
input ulong  InpMagicNumber    = 20260825;   // Magic number
input ulong  InpSlippage       = 30;         // Deviation maximale (points)
input bool   InpEnableTrading  = true;       // Autoriser l'ouverture de positions
input bool   InpVerboseLog     = true;       // Journal detaille

//+------------------------------------------------------------------+
//| Etat global                                                       |
//+------------------------------------------------------------------+
CTrade   g_trade;

int      g_hFast = INVALID_HANDLE;
int      g_hSlow = INVALID_HANDLE;
int      g_hRSI  = INVALID_HANDLE;
int      g_hATR  = INVALID_HANDLE;

datetime g_lastBarTime = 0;
double   g_point       = 0.0;
int      g_digits      = 0;

//--- lecture des indicateurs sur les deux dernieres bougies fermees
struct Readings
  {
   bool     valid;
   double   fast1, fast2;      // EMA rapide sur les bougies 1 et 2
   double   slow1, slow2;      // EMA lente
   double   rsi1;              // RSI sur la bougie 1
   double   atr1;              // ATR sur la bougie 1
  };

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 1 — UTILITAIRES BROKER                                  |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Distance minimale imposee entre le marche et un niveau (SL/TP).   |
//| On retient le maximum entre stops level et freeze level.          |
//+------------------------------------------------------------------+
double MinStopDistance(void)
  {
   const long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops, freeze) * g_point;
  }

//+------------------------------------------------------------------+
//| Arrondit un prix sur la grille de ticks du symbole.               |
//| NormalizeDouble seul ne suffit pas : certains brokers cotent par  |
//| pas de tick superieur au dernier chiffre significatif.            |
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
//|                                                                   |
//| Retourne 0.0 si le resultat tombe SOUS le lot minimum. C'est      |
//| deliberé : remonter silencieusement au lot minimum ferait         |
//| depasser le risque annonce, parfois de beaucoup sur un petit      |
//| compte. Le trade est alors ignore et journalise.                  |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
  {
   const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   //--- epsilon : sans lui, un 0.9999999 se plancherait a 0.99
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
//| Spread courant, en points.                                        |
//+------------------------------------------------------------------+
double CurrentSpreadPoints(void)
  {
   if(g_point <= 0.0)
      return 0.0;

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (ask - bid) / g_point;
  }

//+------------------------------------------------------------------+
//| Positions ouvertes par cet EA sur ce symbole.                     |
//+------------------------------------------------------------------+
int CountOwnPositions(void)
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
//|                                                                  |
//|  SECTION 2 — LECTURE DES INDICATEURS                             |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Copie 'count' valeurs a partir de la bougie 'start'.               |
//|                                                                   |
//| ArraySetAsSeries(true) rend l'indexation intuitive : buf[0]       |
//| correspond a 'start', buf[1] a la bougie precedente. Sans cela    |
//| l'ordre est inverse — et un croisement lu a l'envers produit      |
//| exactement le signal contraire, sans jamais lever d'erreur.       |
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
//| Toutes les valeurs necessaires a la decision, en une passe.       |
//+------------------------------------------------------------------+
Readings ReadIndicators(void)
  {
   Readings r;
   r.valid = false;
   r.fast1 = r.fast2 = r.slow1 = r.slow2 = r.rsi1 = r.atr1 = 0.0;

   double fast[], slow[], rsi[], atr[];

   //--- deux valeurs pour les EMA : le croisement se lit entre 2 et 1
   if(!ReadBuffer(g_hFast, 1, 2, fast))
      return r;
   if(!ReadBuffer(g_hSlow, 1, 2, slow))
      return r;
   if(!ReadBuffer(g_hRSI, 1, 1, rsi))
      return r;
   if(!ReadBuffer(g_hATR, 1, 1, atr))
      return r;

   r.fast1 = fast[0];      // bougie 1, fermee
   r.fast2 = fast[1];      // bougie 2
   r.slow1 = slow[0];
   r.slow2 = slow[1];
   r.rsi1  = rsi[0];
   r.atr1  = atr[0];

   if(r.atr1 <= 0.0)
      return r;

   r.valid = true;
   return r;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 3 — SIGNAL                                              |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Direction du signal : +1 achat, -1 vente, 0 rien.                 |
//|                                                                   |
//| Le croisement est evalue entre la bougie 2 et la bougie 1, toutes |
//| deux FERMEES. Lire la bougie 0, encore en formation, produirait   |
//| un signal qui peut disparaitre avant la cloture : c'est le        |
//| look-ahead bias qui rend un backtest brillant et un compte reel   |
//| perdant.                                                          |
//+------------------------------------------------------------------+
int DetectSignal(const Readings &r, string &reason)
  {
   reason = "";
   if(!r.valid)
      return 0;

   //--- croisement haussier : la rapide etait sous ou sur la lente, elle
   //--- est desormais strictement au-dessus
   const bool crossUp   = (r.fast2 <= r.slow2) && (r.fast1 > r.slow1);
   const bool crossDown = (r.fast2 >= r.slow2) && (r.fast1 < r.slow1);

   if(!crossUp && !crossDown)
      return 0;

   const bool rsiLong  = (r.rsi1 > InpRSI_Level);
   const bool rsiShort = (r.rsi1 < InpRSI_Level);

   if(crossUp && rsiLong)
     {
      reason = StringFormat("croisement HAUSSIER | EMA%d %.2f > EMA%d %.2f "
                            "(bougie 2 : %.2f vs %.2f) | RSI %.1f > %.1f | ATR %.2f",
                            InpFastEMA, r.fast1, InpSlowEMA, r.slow1,
                            r.fast2, r.slow2, r.rsi1, InpRSI_Level, r.atr1);
      return 1;
     }

   if(crossDown && rsiShort)
     {
      reason = StringFormat("croisement BAISSIER | EMA%d %.2f < EMA%d %.2f "
                            "(bougie 2 : %.2f vs %.2f) | RSI %.1f < %.1f | ATR %.2f",
                            InpFastEMA, r.fast1, InpSlowEMA, r.slow1,
                            r.fast2, r.slow2, r.rsi1, InpRSI_Level, r.atr1);
      return -1;
     }

   //--- croisement present mais RSI en desaccord : on trace la raison, c'est
   //--- l'information la plus utile pour regler le seuil plus tard
   if(InpVerboseLog)
      PrintFormat("[SIGNAL] Croisement %s ignore : RSI %.1f du mauvais cote de %.1f.",
                  crossUp ? "haussier" : "baissier", r.rsi1, InpRSI_Level);

   return 0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 4 — MONEY MANAGEMENT                                    |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Volume risquant InpRiskPercent du BALANCE si le stop est touche.  |
//|                                                                   |
//| Le calcul part de la distance de stop REELLE transmise par        |
//| l'appelant, apres elargissement eventuel au stops level du        |
//| broker. Dimensionner sur la distance theorique (1.5 x ATR) ferait |
//| depasser le risque des que le broker impose un plancher plus      |
//| large.                                                            |
//+------------------------------------------------------------------+
double CalculateLot(const double stopDistance)
  {
   if(stopDistance <= 0.0)
      return 0.0;

   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0)
     {
      PrintFormat("[RISQUE] Tick value (%.5f) ou tick size (%.5f) invalide : "
                  "dimensionnement impossible.", tickValue, tickSize);
      return 0.0;
     }

   const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   const double riskMoney = balance * InpRiskPercent / 100.0;

   //--- perte, en devise du compte, d'un lot si le stop est touche
   const double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return 0.0;

   const double raw = riskMoney / lossPerLot;
   const double lot = NormalizeVolume(raw);

   if(lot <= 0.0)
     {
      PrintFormat("[RISQUE] Volume calcule %.4f sous le lot minimum %.2f. "
                  "Trade IGNORE plutot que de depasser le risque de %.2f%% "
                  "(balance %.2f, risque %.2f, distance stop %.2f).",
                  raw, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                  InpRiskPercent, balance, riskMoney, stopDistance);
      return 0.0;
     }

   if(InpVerboseLog)
      PrintFormat("[RISQUE] balance %.2f | risque %.2f (%.2f%%) | perte/lot %.2f "
                  "| volume %.2f", balance, riskMoney, InpRiskPercent, lossPerLot, lot);

   return lot;
  }

//+------------------------------------------------------------------+
//| Marge libre suffisante ?                                          |
//+------------------------------------------------------------------+
bool HasMargin(const ENUM_ORDER_TYPE type, const double volume, const double price)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, volume, price, margin))
     {
      PrintFormat("[RISQUE] OrderCalcMargin a echoue (erreur %d).", GetLastError());
      return false;
     }

   const double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin)
     {
      PrintFormat("[RISQUE] Marge requise %.2f > marge libre %.2f. Trade ignore.",
                  margin, freeMargin);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 5 — EXECUTION                                           |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Ouvre la position et rend compte du resultat.                     |
//+------------------------------------------------------------------+
bool OpenPosition(const int dir, const double atr, const string reason)
  {
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
     {
      Print("[EXEC] Cotation indisponible.");
      return false;
     }

   const bool   isBuy = (dir > 0);
   const double entry = isBuy ? ask : bid;

   double slDist = InpSL_ATR * atr;
   double tpDist = InpTP_ATR * atr;

   //--- plancher impose par le broker : on elargit plutot que de se faire
   //--- rejeter, et le lot sera recalcule sur la distance reelle
   const double minDist = MinStopDistance();
   if(slDist < minDist)
     {
      PrintFormat("[EXEC] Stop elargi de %.2f a %.2f (stops level du broker).",
                  slDist, minDist);
      slDist = minDist;
     }
   if(tpDist < minDist)
      tpDist = minDist;

   const double sl = NormalizePrice(isBuy ? entry - slDist : entry + slDist);
   const double tp = NormalizePrice(isBuy ? entry + tpDist : entry - tpDist);

   //--- le volume se calcule sur la distance REELLE apres normalisation
   const double realStop = MathAbs(entry - sl);
   const double lot = CalculateLot(realStop);
   if(lot <= 0.0)
      return false;

   const ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!HasMargin(type, lot, entry))
      return false;

   PrintFormat("[ENTREE] %s", reason);
   PrintFormat("[ENTREE] %s %.2f lot | entree %.2f | SL %.2f (%.2f) | TP %.2f (%.2f) "
               "| R:R %.2f", isBuy ? "ACHAT" : "VENTE", lot, entry, sl, realStop,
               tp, MathAbs(tp - entry), MathAbs(tp - entry) / realStop);

   const bool ok = isBuy
                   ? g_trade.Buy(lot, _Symbol, 0.0, sl, tp, "EMA-RSI")
                   : g_trade.Sell(lot, _Symbol, 0.0, sl, tp, "EMA-RSI");

   const uint retcode = g_trade.ResultRetcode();

   if(!ok)
     {
      PrintFormat("[ERREUR] Ouverture refusee : retcode=%u (%s), erreur terminal=%d",
                  retcode, g_trade.ResultRetcodeDescription(), GetLastError());

      //--- les retcodes qui meritent un diagnostic explicite
      switch(retcode)
        {
         case TRADE_RETCODE_INVALID_STOPS:
            Print("[ERREUR] Stops refuses : verifie SYMBOL_TRADE_STOPS_LEVEL "
                  "et la normalisation des prix.");
            break;
         case TRADE_RETCODE_INVALID_VOLUME:
            Print("[ERREUR] Volume refuse : verifie min/max/step du symbole.");
            break;
         case TRADE_RETCODE_NO_MONEY:
            Print("[ERREUR] Fonds insuffisants pour ce volume.");
            break;
         case TRADE_RETCODE_MARKET_CLOSED:
            Print("[ERREUR] Marche ferme.");
            break;
         case TRADE_RETCODE_REQUOTE:
         case TRADE_RETCODE_PRICE_CHANGED:
         case TRADE_RETCODE_PRICE_OFF:
            Print("[ERREUR] Prix change pendant l'envoi. Augmente InpSlippage "
                  "si cela se repete.");
            break;
         case TRADE_RETCODE_TRADE_DISABLED:
            Print("[ERREUR] Trading desactive pour ce symbole ou ce compte.");
            break;
         default:
            break;
        }
      return false;
     }

   PrintFormat("[ENTREE] Execute a %.2f, volume %.2f, deal %I64u (retcode %u).",
               g_trade.ResultPrice(), g_trade.ResultVolume(),
               g_trade.ResultDeal(), retcode);
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|  SECTION 6 — CYCLE DE VIE                                        |
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
   if(InpFastEMA < 2 || InpSlowEMA < 2)
     {
      Print("[INIT] Les periodes d'EMA doivent valoir au moins 2.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpFastEMA >= InpSlowEMA)
     {
      Print("[INIT] InpFastEMA doit etre STRICTEMENT inferieur a InpSlowEMA, "
            "sinon aucun croisement n'a de sens.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRSI_Period < 2 || InpATR_Period < 2)
     {
      Print("[INIT] Les periodes RSI et ATR doivent valoir au moins 2.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRSI_Level <= 0.0 || InpRSI_Level >= 100.0)
     {
      Print("[INIT] InpRSI_Level doit etre dans ]0, 100[.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpSL_ATR <= 0.0 || InpTP_ATR <= 0.0)
     {
      Print("[INIT] Les multiplicateurs d'ATR doivent etre strictement positifs.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
     {
      Print("[INIT] InpRiskPercent doit etre dans ]0, 10]. Au-dela, une serie de "
            "pertes parfaitement normale suffit a ruiner le compte.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- handles
   g_hFast = iMA(_Symbol, _Period, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow = iMA(_Symbol, _Period, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hRSI  = iRSI(_Symbol, _Period, InpRSI_Period, PRICE_CLOSE);
   g_hATR  = iATR(_Symbol, _Period, InpATR_Period);

   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE ||
      g_hRSI == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
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

   //--- amorce du filtre de nouvelle bougie : sans cela l'EA evaluerait
   //--- immediatement la bougie deja en cours au moment de l'attachement
   g_lastBarTime = iTime(_Symbol, _Period, 0);

   //--- avertissements de contexte
   if(_Period != PERIOD_H1)
      PrintFormat("[INIT] Attention : strategie prevue pour H1, graphique en %s.",
                  EnumToString((ENUM_TIMEFRAMES)_Period));

   PrintFormat("[INIT] GoldEmaCrossRsi | %s %s | EMA %d/%d | RSI %d seuil %.0f | "
               "ATR %d | SL %.1fx TP %.1fx | risque %.2f%% | magic %I64u",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
               InpFastEMA, InpSlowEMA, InpRSI_Period, InpRSI_Level, InpATR_Period,
               InpSL_ATR, InpTP_ATR, InpRiskPercent, InpMagicNumber);

   PrintFormat("[INIT] Symbole : %d decimales, point %.10g, tick size %.10g, "
               "stops level %d points.",
               g_digits, g_point, SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));

   PrintFormat("[INIT] Filtre de spread : %.0f points = %.5f en prix. Spread "
               "actuel : %.0f points. VERIFIE que ce seuil correspond a ce que "
               "tu attends sur CE broker.",
               InpMaxSpreadPts, InpMaxSpreadPts * g_point, CurrentSpreadPoints());

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hFast != INVALID_HANDLE) IndicatorRelease(g_hFast);
   if(g_hSlow != INVALID_HANDLE) IndicatorRelease(g_hSlow);
   if(g_hRSI  != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(g_hATR  != INVALID_HANDLE) IndicatorRelease(g_hATR);

   g_hFast = g_hSlow = g_hRSI = g_hATR = INVALID_HANDLE;

   PrintFormat("[DEINIT] Arret, raison %d.", reason);
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   //--- FILTRE DE NOUVELLE BOUGIE : tout ce qui suit ne s'execute qu'une
   //--- fois par bougie. C'est ce qui garantit qu'un signal detecte sur la
   //--- bougie 1 ne peut pas declencher plusieurs entrees.
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
         Print("[GARDE] Trading desactive dans le terminal (bouton AutoTrading).");
         warned = true;
        }
      return;
     }

   //--- une seule position a la fois
   if(CountOwnPositions() >= 1)
      return;

   //--- filtre de spread
   const double spread = CurrentSpreadPoints();
   if(InpMaxSpreadPts > 0.0 && spread > InpMaxSpreadPts)
     {
      if(InpVerboseLog)
         PrintFormat("[GARDE] Spread %.0f points > %.0f : bougie ignoree.",
                     spread, InpMaxSpreadPts);
      return;
     }

   //--- signal
   const Readings r = ReadIndicators();
   if(!r.valid)
     {
      if(InpVerboseLog)
         Print("[SIGNAL] Indicateurs non disponibles (historique insuffisant ?).");
      return;
     }

   string reason = "";
   const int dir = DetectSignal(r, reason);
   if(dir == 0)
      return;

   OpenPosition(dir, r.atr1, reason);
  }
//+------------------------------------------------------------------+
