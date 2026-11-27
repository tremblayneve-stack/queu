//+------------------------------------------------------------------+
//|                                            VModel22Hardened.mq5  |
//|                                                             Queu |
//|                                                                  |
//|  V MODEL v2.2 Hardened -- Continuation Focus                     |
//|  Instrument cible : NAS100.s (PU Prime), graphique M5.           |
//|                                                                  |
//|  UN SEUL type de trade : la CONTINUATION dans le sens de la      |
//|  tendance apres un retour dans un Fair Value Gap (FVG) neuf.     |
//|  Le module Retournement (sweep de liquidite) n'existe pas dans   |
//|  cette version : InpRevOn est conserve pour compatibilite des    |
//|  presets mais il est ignore.                                     |
//|                                                                  |
//|  Chaine de decision (a chaque bougie M5 fermee) :                |
//|    1. Structure + scores sur M1 M5 M15 M30 H1 H4 (sans repaint)  |
//|    2. Detection / suivi des FVG (M5 M15 M30 H1 arment)           |
//|    3. Armement strict sur le 1er touch d'un FVG neuf (60 min)    |
//|    4. 2 confirmations M5 (BOS / IFVG / pin / engulfing / double) |
//|    5. Revalidation des scores, SL 20..42 pts, TP 2.2R/3.5R/liq.  |
//|    6. Gestion : partiels 30/30, BE+0.5, trailing pivot M5 L3,    |
//|       fermeture forcee 16:25 NY, perte journaliere 2.8 %.        |
//|                                                                  |
//|  Par defaut : SIGNAUX SEULEMENT (InpTradeEnabled = false). Le    |
//|  plan de trade est dessine et journalise, aucun ordre envoye.    |
//|                                                                  |
//|  Unites : toutes les distances "points" de ce fichier sont des   |
//|  POINTS D'INDICE (1.0 de prix sur NAS100), pas des _Point.       |
//|  InpIndexPoint permet d'adapter si le broker cote autrement.     |
//|                                                                  |
//|  Fichier autonome : aucun indicateur custom, aucune dependance   |
//|  hors bibliotheque standard (Trade.mqh).                         |
//+------------------------------------------------------------------+
#property copyright "Queu"
#property version   "2.20"
#property description "V MODEL v2.2 Hardened - Continuation FVG multi-timeframe, NAS100 M5, session NY"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations d'entree                                             |
//+------------------------------------------------------------------+
enum ENUM_VM_TIMEMODE
  {
   VM_TIME_NY_ALIGNED = 0, // Serveur aligne sur la cloture NY (serveur = NY + N h, ex. PU Prime)
   VM_TIME_AUTO       = 1, // Auto : decalage serveur/GMT mesure en direct + DST US (repli aligne en testeur)
   VM_TIME_MANUAL     = 2  // Manuel : decalage GMT fixe du serveur (+1h l'ete US si coche)
  };

//+------------------------------------------------------------------+
//| Parametres                                                        |
//+------------------------------------------------------------------+
input group "=== General ==="
input bool   InpTradeEnabled      = false;     // Trading reel (false = SIGNAUX SEULEMENT)
input ulong  InpMagic             = 20261150;  // Magic number
input string InpComment           = "VM22";    // Commentaire des ordres
input ulong  InpDeviationPts      = 50;        // Deviation max a l'execution (en _Point broker)
input double InpIndexPoint        = 1.0;       // Valeur en prix d'1 point d'indice
input bool   InpRevOn             = false;     // Module Retournement (NON INCLUS - ignore)

input group "=== Heure New York ==="
input ENUM_VM_TIMEMODE InpTimeMode = VM_TIME_NY_ALIGNED; // Methode de conversion serveur -> NY
input int    InpAlignedShiftH     = 7;         // Mode aligne : heures serveur - NY (PU Prime = 7)
input int    InpManualGMTOffset   = 2;         // Mode manuel : decalage GMT du serveur (hiver)
input bool   InpManualServerUsDst = true;      // Mode manuel : le serveur suit l'heure d'ete US
input int    InpEntryStartH       = 10;        // Fenetre d'entree : debut (heure NY)
input int    InpEntryStartM       = 0;         // Fenetre d'entree : debut (minute)
input int    InpEntryEndH         = 15;        // Fenetre d'entree : fin (heure NY)
input int    InpEntryEndM         = 0;         // Fenetre d'entree : fin (minute)
input int    InpForceCloseH       = 16;        // Fermeture forcee (heure NY)
input int    InpForceCloseM       = 25;        // Fermeture forcee (minute)
input int    InpDayStartH         = 17;        // Debut de la journee de trading (heure NY)

input group "=== Risque et protections ==="
input double InpRiskPct           = 0.16;      // Risque par trade (% du balance)
input int    InpMaxTradesDay      = 7;         // Trades max par jour
input int    InpMaxConsecLoss     = 4;         // Pertes consecutives max (bloque la journee)
input double InpDailyLossPct      = 2.8;       // Perte journaliere max % (realise + latent)
input int    InpMaxPositions      = 1;         // Positions simultanees max (geree : 1)
input double InpMaxSpread         = 4.5;       // Spread max (points d'indice)
input double InpMaxSpreadSLPct    = 12.0;      // Spread max en % de la distance du SL
input double InpCommissionPerLot  = 0.0;       // Commission aller-retour par lot (devise du compte)

input group "=== Scores multi-timeframe ==="
input double InpContMinLocal      = 48;        // Score Local minimum (dans le sens du trade)
input double InpContMinGlobal     = 28;        // Score Global minimum
input double InpLocalStrong       = 58;        // Seuil tendance forte (Local)
input double InpHTFStrong         = 58;        // Seuil tendance forte (Superieur)
input double InpHTFOpposeLimit    = 52;        // Superieur contraire si <= -X ...
input double InpLocalOverride     = 62;        // ... alors Local exige >= X
input double InpM5OpposeLimit     = 50;        // Refus si score M5 <= -X (structure M5 contraire)
input int    InpATRPeriod         = 14;        // Periode ATR
input int    InpSlopeBars         = 5;         // Pente EMA20 : mesuree sur N bougies
input double InpSlopeFullATR      = 1.0;       // Pente EMA20 donnant la note pleine (x ATR)
input int    InpMomBars           = 8;         // Momentum : deplacement net sur N bougies
input double InpMomFullATR        = 3.0;       // Momentum donnant la note pleine (x ATR)
input int    InpConsolBars        = 12;        // Consolidation : fenetre (bougies)
input double InpConsolATR         = 2.8;       // Consolidation : amplitude max (x ATR)

input group "=== Fair Value Gaps ==="
input double InpFvgMinM1          = 4;         // Taille min FVG M1 (calcule, n'arme pas)
input double InpFvgMinM5          = 8;         // Taille min FVG M5
input double InpFvgMinM15         = 14;        // Taille min FVG M15
input double InpFvgMinM30         = 20;        // Taille min FVG M30
input double InpFvgMinH1          = 28;        // Taille min FVG H1
input double InpFvgMinH4          = 40;        // Taille min FVG H4 (calcule, n'arme pas)
input int    InpFvgMaxAge         = 120;       // Age max (bougies de son timeframe)
input int    InpFvgMinAge         = 4;         // Bougies (de son timeframe) ecoulees avant armement
input int    InpArmMinutes        = 60;        // Duree de vie d'un setup arme (minutes)

input group "=== Confirmations M5 ==="
input int    InpConfNeeded        = 2;         // Confirmations requises (bougies distinctes)
input int    InpBosPivotLen       = 3;         // BOS : longueur du swing
input int    InpBosMaxAge         = 25;        // BOS : age max du swing (bougies)
input int    InpIfvgMaxAge        = 20;        // IFVG : age max du FVG contraire (bougies)
input double InpIfvgMinSize       = 4;         // IFVG : taille min du FVG contraire (points)
input double InpPatternMinATR     = 0.7;       // Patterns : taille min (x ATR M5)
input bool   InpUsePinBar         = true;      // Pattern pin bar
input bool   InpUseEngulfing      = true;      // Pattern engulfing
input bool   InpUseDouble         = true;      // Pattern double bottom / double top

input group "=== Stop loss et take profit ==="
input double InpSLBuffer          = 3.0;       // Buffer au-dela de l'extreme (points)
input double InpSLMin             = 20.0;      // Distance SL minimale (points)
input double InpSLMaxAbs          = 42.0;      // Distance SL maximale (points, au-dela : refus)
input double InpTP1_RR            = 2.2;       // TP1 (R)
input double InpTP2_RR            = 3.5;       // TP2 (R)
input double InpTP1_Pct           = 30.0;      // % du volume initial ferme a TP1
input double InpTP2_Pct           = 30.0;      // % du volume initial ferme a TP2
input double InpTP3_MinRR         = 4.0;       // TP3 : liquidite offrant au moins X R
input double InpTP3_DefaultRR     = 4.5;       // TP3 par defaut sans liquidite valable (R)
input double InpTP3_Offset        = 1.5;       // TP3 : s'arreter X points avant la liquidite
input double InpBE_Offset         = 0.5;       // Break-even : offset (points)
input double InpTrailBuffer       = 3.0;       // Trailing : buffer sous/sur le pivot M5 L3

input group "=== Affichage et journaux ==="
input bool   InpShowDashboard     = true;      // Tableau de bord
input int    InpDashX             = 8;         // Tableau de bord : X
input int    InpDashY             = 20;        // Tableau de bord : Y
input int    InpDashFontSize      = 9;         // Tableau de bord : taille police
input bool   InpDrawPlans         = true;      // Dessiner zones armees et plans de trade
input bool   InpWriteLogs         = true;      // Ecrire les CSV (Common\Files)
input string InpFilePrefix        = "VMODEL22";// Prefixe des fichiers CSV
input bool   InpLogEveryBar       = false;     // Journaliser aussi un etat a chaque bougie M5
input bool   InpVerbose           = true;      // Messages detailles dans le journal Experts

//+------------------------------------------------------------------+
//| Constantes                                                        |
//+------------------------------------------------------------------+
#define TF_M1      0
#define TF_M5      1
#define TF_M15     2
#define TF_M30     3
#define TF_H1      4
#define TF_H4      5
#define NTF        6
#define BARS_HIST  400

#define BRK_NONE   0
#define BRK_BOS    1
#define BRK_CHOCH  2

#define FVG_NEW      0
#define FVG_TOUCHED  1
#define FVG_MIT50    2
#define FVG_INVALID  3

#define DASH_PREFIX "VM22_dash_"
#define PLAN_PREFIX "VM22_plan_"

ENUM_TIMEFRAMES g_tfs[NTF]    = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4};
string          g_tfName[NTF] = {"M1", "M5", "M15", "M30", "H1", "H4"};
int             g_pivLen[NTF] = {2, 2, 2, 2, 3, 3};

//+------------------------------------------------------------------+
//| Structures                                                        |
//+------------------------------------------------------------------+
// Etat de structure et score d'une unite de temps
struct TFState
  {
   bool     valid;
   datetime lastBar;     // heure d'ouverture de la derniere bougie FERMEE traitee
   int      bars;
   double   atr;
   double   score;       // -100 .. +100
   int      trend;       // tendance de structure (derniere cassure) +1 / -1 / 0
   int      hhhl;        // +1 HH+HL, -1 LH+LL, 0 sinon
   int      emaAlign;    // +1 20>50>100>200, -1 inverse, 0 sinon
   double   slopeATR;    // pente EMA20 en ATR
   double   momATR;      // momentum en ATR
   bool     consol;
   int      lastBreak;   // BRK_*
   int      breakAgo;    // bougies depuis la derniere cassure (0 = derniere fermee)
   double   sh1, sh2;    // deux derniers sommets (1 = plus recent)
   double   sl1, sl2;    // deux derniers creux
   string   state;       // Tendance / Continuation / Retournement / Consolidation / Transition
  };

// Bougies fermees d'une unite de temps (serie : r[0] = derniere fermee)
struct RatesBuf
  {
   MqlRates r[];
  };

// Fair Value Gap
struct FVGZone
  {
   int      tf;
   int      dir;       // +1 haussier, -1 baissier
   double   top;
   double   bot;
   datetime created;   // heure de CLOTURE de la bougie 3
   int      state;     // FVG_*
   bool     consumed;
  };

// Setup arme
struct SetupState
  {
   bool     active;
   int      dir;
   int      tf;
   double   top;
   double   bot;
   datetime fvgCreated;
   datetime armBar;     // ouverture de la bougie M5 d'armement
   datetime expire;     // heure serveur limite
   int      conf;
   string   confTags;
   double   extLow;     // plus bas depuis l'armement (bougie d'armement incluse)
   double   extHigh;
   double   armLocal, armSup, armGlobal;
  };

// Position suivie
struct PosState
  {
   bool     active;
   ulong    ticket;
   ulong    ident;
   int      dir;
   double   entry;
   double   sl0;
   double   dist;       // risque initial en prix (1 R)
   double   initVol;
   int      stage;      // 0 = aucun palier, 1 = TP1 fait, 2 = TP2 fait (trailing)
   bool     bePending;
   double   mfe;        // en R
   double   mae;        // en R
   double   tp1, tp2, tp3;
   double   riskMoney;
   datetime openTime;
   double   sLocal, sSup, sGlobal;
   double   sTF[NTF];
   double   spread;
   string   fvg;
   string   confs;
   string   tp3src;
   string   closeReason;
   int      finalizeTries;
  };

// Compteurs de la journee de trading (17:00 NY -> 17:00 NY)
struct DayState
  {
   int      key;
   double   startBal;
   datetime startServer;
   int      trades;
   int      wins;
   int      losses;
   int      consec;
   double   sumR;
   double   pnl;
   bool     stopped;
   string   stopReason;
  };

//+------------------------------------------------------------------+
//| Variables globales                                                |
//+------------------------------------------------------------------+
CTrade      g_trade;
TFState     g_tf[NTF];
RatesBuf    g_rb[NTF];
FVGZone     g_fvg[];
SetupState  g_setup;
PosState    g_pos;
DayState    g_day;

int g_hATR[NTF], g_hE20[NTF], g_hE50[NTF], g_hE100[NTF], g_hE200[NTF];

double   g_local = 0, g_sup = 0, g_global = 0;
bool     g_scoresValid   = false;
datetime g_lastM5Open    = 0;   // ouverture de la bougie M5 en formation deja vue
datetime g_lastProcM5    = 0;   // derniere bougie M5 fermee traitee
int      g_autoOffset    = 0;   // decalage serveur - GMT (mode auto)
string   g_lastDecision  = "-";
string   g_setupReason   = "aucun FVG neuf touche";
uint     g_lastDashMs    = 0;
double   g_realizedCache = 0;
datetime g_realizedAt    = 0;
bool     g_realizedDirty = true;

string g_fileTrades, g_fileDecisions, g_fileCtx;

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 1 : UTILITAIRES                                          |
//|                                                                  |
//+------------------------------------------------------------------+
double Clamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
int    SignD(double v)                       { return v > 0 ? 1 : (v < 0 ? -1 : 0); }
double IP(double pts)                        { return pts * InpIndexPoint; }
string F1(double v)                          { return DoubleToString(v, 1); }
string F2(double v)                          { return DoubleToString(v, 2); }
string FP(double v)                          { return DoubleToString(v, _Digits); }
string SG(double v)                          { return StringFormat("%+.1f", v); }
string DirStr(int d)                         { return d > 0 ? "ACHAT" : (d < 0 ? "VENTE" : "-"); }
string DirShort(int d)                       { return d > 0 ? "haussier" : "baissier"; }
double Bid()                                 { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }
double Ask()                                 { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
double SpreadPrice()                         { return Ask() - Bid(); }

double NormPrice(double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0)
      return NormalizeDouble(p, _Digits);
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
  }

int VolDigits()
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      return 2;
   return (int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9));
  }

double NormVolDown(double v)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      step = 0.01;
   return NormalizeDouble(MathFloor(v / step + 1e-9) * step, VolDigits());
  }

bool LogsOn()
  {
   return InpWriteLogs && !MQLInfoInteger(MQL_OPTIMIZATION);
  }

bool DashOn()
  {
   if(!InpShowDashboard || MQLInfoInteger(MQL_OPTIMIZATION))
      return false;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return false;
   return true;
  }

// Ajoute une ligne a un CSV de Common\Files (en-tete si fichier vide)
void AppendCSV(string file, string header, string line)
  {
   if(!LogsOn())
      return;
   int h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON |
                    FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("[VM22] impossible d'ouvrir %s (erreur %d)", file, GetLastError());
      return;
     }
   if(FileSize(h) == 0)
      FileWriteString(h, header + "\r\n");
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
  }

// Retire les ';' d'un texte libre pour ne pas casser le CSV
string CsvSafe(string s)
  {
   StringReplace(s, ";", ",");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return s;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 2 : HEURE NEW YORK ET HEURE D'ETE                        |
//|                                                                  |
//| Trois methodes :                                                 |
//|  - ALIGNE : le serveur est cale sur la cloture NY (minuit serveur|
//|    = 17:00 NY toute l'annee). C'est le cas de PU Prime (GMT+2    |
//|    l'hiver, GMT+3 l'ete, bascule aux dates US). NY = serveur - 7h|
//|    Fonctionne a l'identique en testeur.                          |
//|  - AUTO : decalage serveur/GMT mesure en direct, puis UTC -> NY  |
//|    selon les regles DST US. En testeur TimeGMT() n'est pas       |
//|    fiable : repli automatique sur ALIGNE.                        |
//|  - MANUEL : decalage GMT fixe (+1h l'ete US si coche).           |
//+------------------------------------------------------------------+
// n-ieme dimanche d'un mois (00:00 de ce jour)
datetime NthSunday(int year, int month, int n)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = year;
   s.mon  = month;
   s.day  = 1;
   datetime t = StructToTime(s);
   TimeToStruct(t, s);
   int first = 1 + (7 - s.day_of_week) % 7;
   return t + (datetime)((first - 1 + 7 * (n - 1)) * 86400);
  }

// Heure d'ete US active a cet instant UTC ?
// Debut : 2e dimanche de mars 02:00 EST (07:00 UTC). Fin : 1er dimanche de novembre 02:00 EDT (06:00 UTC).
bool IsUsDst(datetime utc)
  {
   MqlDateTime d;
   TimeToStruct(utc, d);
   datetime start = NthSunday(d.year, 3, 2) + 7 * 3600;
   datetime end   = NthSunday(d.year, 11, 1) + 6 * 3600;
   return (utc >= start && utc < end);
  }

datetime UtcToNY(datetime utc)
  {
   return utc - (datetime)((IsUsDst(utc) ? 4 : 5) * 3600);
  }

void RefreshServerOffset()
  {
   if(InpTimeMode != VM_TIME_AUTO || MQLInfoInteger(MQL_TESTER))
      return;
   datetime gmt = TimeGMT();
   datetime srv = TimeTradeServer();
   if(gmt <= 0 || srv <= 0)
      return;
   long off = (long)(srv - gmt);
   g_autoOffset = (int)(MathRound(off / 900.0) * 900);
  }

datetime ServerToNY(datetime srv)
  {
   int mode = InpTimeMode;
   if(mode == VM_TIME_AUTO && MQLInfoInteger(MQL_TESTER))
      mode = VM_TIME_NY_ALIGNED;
   if(mode == VM_TIME_NY_ALIGNED)
      return srv - (datetime)(InpAlignedShiftH * 3600);
   datetime utc;
   if(mode == VM_TIME_AUTO)
      utc = srv - (datetime)g_autoOffset;
   else
     {
      utc = srv - (datetime)(InpManualGMTOffset * 3600);
      if(InpManualServerUsDst && IsUsDst(utc))
         utc -= 3600;
     }
   return UtcToNY(utc);
  }

int NYMinutes(datetime ny)        { return (int)(((long)ny % 86400) / 60); }
int MinOf(int h, int m)           { return h * 60 + m; }

int NYDayOfWeek(datetime ny)
  {
   MqlDateTime d;
   TimeToStruct(ny, d);
   return d.day_of_week;
  }

bool InEntryWindow(datetime ny)
  {
   int dow = NYDayOfWeek(ny);
   if(dow == 0 || dow == 6)
      return false;
   int m = NYMinutes(ny);
   return (m >= MinOf(InpEntryStartH, InpEntryStartM) && m < MinOf(InpEntryEndH, InpEntryEndM));
  }

bool InForceCloseZone(datetime ny)
  {
   int m = NYMinutes(ny);
   return (m >= MinOf(InpForceCloseH, InpForceCloseM) && m < MinOf(InpDayStartH, 0));
  }

// Cle de la journee de trading : date de (NY + (24 - 17) h). A 17:00 NY la cle change.
int TradingDayKey(datetime ny)
  {
   MqlDateTime d;
   TimeToStruct(ny + (datetime)((24 - InpDayStartH) * 3600), d);
   return d.year * 10000 + d.mon * 100 + d.day;
  }

// Heure NY du debut de la journee de trading courante
datetime TradingDayStartNY(datetime ny)
  {
   long shift   = (long)(24 - InpDayStartH) * 3600;
   long shifted = (long)ny + shift;
   return (datetime)(shifted - shifted % 86400 - shift);
  }

string SessionName(datetime ny)
  {
   int dow = NYDayOfWeek(ny);
   int m   = NYMinutes(ny);
   if(dow == 6 || (dow == 5 && m >= MinOf(InpDayStartH, 0)) || (dow == 0 && m < MinOf(InpDayStartH, 0)))
      return "Week-end";
   if(m >= MinOf(InpDayStartH, 0) || m < 180)
      return "Asie";
   if(m < 570)
      return "Londres";
   if(m < MinOf(InpEntryStartH, InpEntryStartM))
      return "NY ouverture (attente)";
   if(m < MinOf(InpEntryEndH, InpEntryEndM))
      return "NY - FENETRE D'ENTREE";
   if(m < MinOf(InpForceCloseH, InpForceCloseM))
      return "NY - gestion seulement";
   return "Fermeture forcee";
  }

string NYStr(datetime ny, bool withDate = false)
  {
   return TimeToString(ny, withDate ? (TIME_DATE | TIME_SECONDS) : TIME_SECONDS);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 3 : PERSISTANCE (GlobalVariables + fichier de contexte)  |
//|                                                                  |
//| Les numeriques vont dans les GlobalVariables du terminal ; les   |
//| textes (zone FVG, confirmations, source TP3) dans un petit       |
//| fichier Common\Files. Un redemarrage retrouve la position, son   |
//| palier, son R initial et les compteurs du jour.                  |
//+------------------------------------------------------------------+
string GVN(string k)                      { return "VM22_" + IntegerToString((long)InpMagic) + "_" + k; }
void   GVS(string k, double v)            { GlobalVariableSet(GVN(k), v); }
double GVG(string k, double def = 0)      { string n = GVN(k); return GlobalVariableCheck(n) ? GlobalVariableGet(n) : def; }

void SaveDay()
  {
   GVS("d_key", g_day.key);
   GVS("d_bal", g_day.startBal);
   GVS("d_start", (double)g_day.startServer);
   GVS("d_trades", g_day.trades);
   GVS("d_wins", g_day.wins);
   GVS("d_losses", g_day.losses);
   GVS("d_consec", g_day.consec);
   GVS("d_sumR", g_day.sumR);
   GVS("d_pnl", g_day.pnl);
   GVS("d_stop", g_day.stopped ? 1 : 0);
  }

void LoadDay()
  {
   g_day.key         = (int)GVG("d_key", 0);
   g_day.startBal    = GVG("d_bal", 0);
   g_day.startServer = (datetime)GVG("d_start", 0);
   g_day.trades      = (int)GVG("d_trades", 0);
   g_day.wins        = (int)GVG("d_wins", 0);
   g_day.losses      = (int)GVG("d_losses", 0);
   g_day.consec      = (int)GVG("d_consec", 0);
   g_day.sumR        = GVG("d_sumR", 0);
   g_day.pnl         = GVG("d_pnl", 0);
   g_day.stopped     = (GVG("d_stop", 0) > 0.5);
   g_day.stopReason  = g_day.stopped ? "restaure apres redemarrage" : "";
  }

void SavePos()
  {
   if(!g_pos.active)
      return;
   GVS("p_ticket", (double)g_pos.ticket);
   GVS("p_ident", (double)g_pos.ident);
   GVS("p_dir", g_pos.dir);
   GVS("p_entry", g_pos.entry);
   GVS("p_sl0", g_pos.sl0);
   GVS("p_dist", g_pos.dist);
   GVS("p_vol", g_pos.initVol);
   GVS("p_stage", g_pos.stage);
   GVS("p_be", g_pos.bePending ? 1 : 0);
   GVS("p_mfe", g_pos.mfe);
   GVS("p_mae", g_pos.mae);
   GVS("p_tp1", g_pos.tp1);
   GVS("p_tp2", g_pos.tp2);
   GVS("p_tp3", g_pos.tp3);
   GVS("p_risk", g_pos.riskMoney);
   GVS("p_open", (double)g_pos.openTime);
   GVS("p_sloc", g_pos.sLocal);
   GVS("p_ssup", g_pos.sSup);
   GVS("p_sglo", g_pos.sGlobal);
   GVS("p_spr", g_pos.spread);
   for(int i = 0; i < NTF; i++)
      GVS("p_s" + g_tfName[i], g_pos.sTF[i]);
  }

void SaveCtx()
  {
   if(MQLInfoInteger(MQL_OPTIMIZATION))
      return;
   int h = FileOpen(g_fileCtx, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h, g_pos.fvg + "\r\n");
   FileWriteString(h, g_pos.confs + "\r\n");
   FileWriteString(h, g_pos.tp3src + "\r\n");
   FileClose(h);
  }

void LoadCtx()
  {
   g_pos.fvg    = "?";
   g_pos.confs  = "?";
   g_pos.tp3src = "?";
   if(!FileIsExist(g_fileCtx, FILE_COMMON))
      return;
   int h = FileOpen(g_fileCtx, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   if(!FileIsEnding(h)) g_pos.fvg    = FileReadString(h);
   if(!FileIsEnding(h)) g_pos.confs  = FileReadString(h);
   if(!FileIsEnding(h)) g_pos.tp3src = FileReadString(h);
   FileClose(h);
  }

void ResetPos()
  {
   g_pos.active = false;
   g_pos.ticket = 0;
   g_pos.ident  = 0;
   g_pos.dir    = 0;
   g_pos.entry  = 0;
   g_pos.sl0    = 0;
   g_pos.dist   = 0;
   g_pos.initVol = 0;
   g_pos.stage  = 0;
   g_pos.bePending = false;
   g_pos.mfe = 0;
   g_pos.mae = 0;
   g_pos.tp1 = 0;
   g_pos.tp2 = 0;
   g_pos.tp3 = 0;
   g_pos.riskMoney = 0;
   g_pos.openTime  = 0;
   g_pos.sLocal = 0;
   g_pos.sSup   = 0;
   g_pos.sGlobal = 0;
   for(int i = 0; i < NTF; i++)
      g_pos.sTF[i] = 0;
   g_pos.spread = 0;
   g_pos.fvg    = "";
   g_pos.confs  = "";
   g_pos.tp3src = "";
   g_pos.closeReason = "";
   g_pos.finalizeTries = 0;
  }

void ClearPosPersist()
  {
   GlobalVariablesDeleteAll(GVN("p_"));
   if(!MQLInfoInteger(MQL_OPTIMIZATION) && FileIsExist(g_fileCtx, FILE_COMMON))
      FileDelete(g_fileCtx, FILE_COMMON);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 4 : STRUCTURE MULTI-TIMEFRAME ET SCORES                  |
//|                                                                  |
//| Toutes les donnees sont des bougies FERMEES (CopyRates depuis    |
//| l'index 1). Un pivot de longueur L a l'index p n'est connu qu'a  |
//| la cloture de la bougie p-L : le parcours chronologique ne       |
//| l'utilise qu'a partir de ce moment. Aucun repaint.               |
//+------------------------------------------------------------------+
void ResetTF(int i)
  {
   g_tf[i].valid = false;
   g_tf[i].lastBar = 0;
   g_tf[i].bars = 0;
   g_tf[i].atr = 0;
   g_tf[i].score = 0;
   g_tf[i].trend = 0;
   g_tf[i].hhhl = 0;
   g_tf[i].emaAlign = 0;
   g_tf[i].slopeATR = 0;
   g_tf[i].momATR = 0;
   g_tf[i].consol = false;
   g_tf[i].lastBreak = BRK_NONE;
   g_tf[i].breakAgo = 9999;
   g_tf[i].sh1 = 0;
   g_tf[i].sh2 = 0;
   g_tf[i].sl1 = 0;
   g_tf[i].sl2 = 0;
   g_tf[i].state = "n/d";
  }

// Pivot haut : strictement plus haut que les L bougies plus recentes, >= aux L plus anciennes
bool IsPivotHigh(const MqlRates &r[], int p, int L, int n)
  {
   if(p - L < 0 || p + L > n - 1)
      return false;
   double h = r[p].high;
   for(int j = 1; j <= L; j++)
     {
      if(r[p - j].high >= h)
         return false;
      if(r[p + j].high > h)
         return false;
     }
   return true;
  }

bool IsPivotLow(const MqlRates &r[], int p, int L, int n)
  {
   if(p - L < 0 || p + L > n - 1)
      return false;
   double l = r[p].low;
   for(int j = 1; j <= L; j++)
     {
      if(r[p - j].low <= l)
         return false;
      if(r[p + j].low < l)
         return false;
     }
   return true;
  }

// Dernier pivot confirme (le plus recent) de longueur L sur le timeframe i.
// dir > 0 : pivot BAS sous refPrice (stop d'un achat). dir < 0 : pivot HAUT au-dessus.
bool FindLastPivot(int i, int L, int dir, double refPrice, double &level)
  {
   int n = g_tf[i].bars;
   for(int p = L; p <= n - 1 - L && p < 300; p++)
     {
      if(dir > 0 && IsPivotLow(g_rb[i].r, p, L, n) && g_rb[i].r[p].low < refPrice)
        {
         level = g_rb[i].r[p].low;
         return true;
        }
      if(dir < 0 && IsPivotHigh(g_rb[i].r, p, L, n) && g_rb[i].r[p].high > refPrice)
        {
         level = g_rb[i].r[p].high;
         return true;
        }
     }
   return false;
  }

// Parcours chronologique : BOS / CHoCH, tendance de structure, deux derniers swings
void ComputeStructure(int i)
  {
   int n = g_tf[i].bars;
   int L = g_pivLen[i];
   int trend = 0, lastBreak = BRK_NONE, breakAgo = 9999;
   double sh = 0, sl = 0;
   bool shBroken = true, slBroken = true;
   double sh1 = 0, sh2 = 0, sl1 = 0, sl2 = 0;

   for(int k = n - 1 - 2 * L; k >= 0; k--)
     {
      // Pivot confirme par la cloture de la bougie k
      int p = k + L;
      if(IsPivotHigh(g_rb[i].r, p, L, n))
        {
         sh2 = sh1;
         sh1 = g_rb[i].r[p].high;
         sh = sh1;
         shBroken = false;
        }
      if(IsPivotLow(g_rb[i].r, p, L, n))
        {
         sl2 = sl1;
         sl1 = g_rb[i].r[p].low;
         sl = sl1;
         slBroken = false;
        }
      double c = g_rb[i].r[k].close;
      if(!shBroken && sh > 0 && c > sh)
        {
         lastBreak = (trend == -1) ? BRK_CHOCH : BRK_BOS;
         trend = 1;
         shBroken = true;
         breakAgo = k;
        }
      if(!slBroken && sl > 0 && c < sl)
        {
         lastBreak = (trend == 1) ? BRK_CHOCH : BRK_BOS;
         trend = -1;
         slBroken = true;
         breakAgo = k;
        }
     }
   g_tf[i].trend = trend;
   g_tf[i].lastBreak = lastBreak;
   g_tf[i].breakAgo = breakAgo;
   g_tf[i].sh1 = sh1;
   g_tf[i].sh2 = sh2;
   g_tf[i].sl1 = sl1;
   g_tf[i].sl2 = sl2;
   int hh = 0;
   if(sh2 > 0 && sl2 > 0)
     {
      if(sh1 > sh2 && sl1 > sl2)
         hh = 1;
      else if(sh1 < sh2 && sl1 < sl2)
         hh = -1;
     }
   g_tf[i].hhhl = hh;
  }

bool ReadBuf(int handle, int count, double &buf[])
  {
   ArraySetAsSeries(buf, true);
   if(handle == INVALID_HANDLE)
      return false;
   return (CopyBuffer(handle, 0, 1, count, buf) == count);
  }

// Met a jour un timeframe s'il a une nouvelle bougie fermee. Retourne true si mis a jour.
bool UpdateTF(int i)
  {
   ENUM_TIMEFRAMES tf = g_tfs[i];
   datetime t1 = iTime(_Symbol, tf, 1);
   if(t1 <= 0)
      return false;
   if(g_tf[i].valid && t1 == g_tf[i].lastBar)
      return false;

   ArraySetAsSeries(g_rb[i].r, true);
   int n = CopyRates(_Symbol, tf, 1, BARS_HIST, g_rb[i].r);
   if(n < 60)
     {
      g_tf[i].valid = false;
      return false;
     }
   int ns = MathMax(2, InpSlopeBars + 1);
   double atr[], e20[], e50[], e100[], e200[];
   if(!ReadBuf(g_hATR[i], 1, atr) || !ReadBuf(g_hE20[i], ns, e20) || !ReadBuf(g_hE50[i], 1, e50) ||
      !ReadBuf(g_hE100[i], 1, e100) || !ReadBuf(g_hE200[i], 1, e200) || atr[0] <= 0)
     {
      g_tf[i].valid = false;
      return false;
     }
   g_tf[i].bars = n;
   double a = atr[0];
   g_tf[i].atr = a;

   // Alignement des EMA
   int al = 0;
   if(e20[0] > e50[0] && e50[0] > e100[0] && e100[0] > e200[0])
      al = 1;
   else if(e20[0] < e50[0] && e50[0] < e100[0] && e100[0] < e200[0])
      al = -1;
   g_tf[i].emaAlign = al;
   g_tf[i].slopeATR = (e20[0] - e20[ns - 1]) / a;
   int mb = MathMin(InpMomBars, n - 1);
   g_tf[i].momATR = (g_rb[i].r[0].close - g_rb[i].r[mb].close) / a;

   ComputeStructure(i);

   // Consolidation : N bougies dans moins de X ATR et aucune cassure recente
   int cb = MathMin(InpConsolBars, n);
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int k = 0; k < cb; k++)
     {
      hi = MathMax(hi, g_rb[i].r[k].high);
      lo = MathMin(lo, g_rb[i].r[k].low);
     }
   g_tf[i].consol = ((hi - lo) < InpConsolATR * a && g_tf[i].breakAgo >= InpConsolBars);

   // Score -100 .. +100
   double s = 40.0 * g_tf[i].trend
            + 20.0 * g_tf[i].hhhl
            + 15.0 * g_tf[i].emaAlign
            + 15.0 * Clamp(g_tf[i].slopeATR / MathMax(1e-9, InpSlopeFullATR), -1, 1)
            + 10.0 * Clamp(g_tf[i].momATR / MathMax(1e-9, InpMomFullATR), -1, 1);
   if(g_tf[i].consol)
      s *= 0.5;
   g_tf[i].score = s;

   // Etat textuel
   double strong = (i >= TF_M30) ? InpHTFStrong : InpLocalStrong;
   string st = "Transition";
   if(g_tf[i].consol)
      st = "Consolidation";
   else if(g_tf[i].lastBreak == BRK_CHOCH && g_tf[i].breakAgo < InpConsolBars)
      st = "Retournement";
   else if(g_tf[i].trend != 0 && MathAbs(s) >= strong && SignD(g_tf[i].momATR) == g_tf[i].trend)
      st = "Tendance";
   else if(g_tf[i].trend != 0 && g_tf[i].lastBreak == BRK_BOS && SignD(s) == g_tf[i].trend)
      st = "Continuation";
   g_tf[i].state = st;

   datetime prev = g_tf[i].lastBar;
   g_tf[i].lastBar = t1;
   g_tf[i].valid = true;
   DetectFVG(i, prev);
   return true;
  }

void ComputeAggregates()
  {
   g_scoresValid = true;
   for(int i = 0; i < NTF; i++)
      if(!g_tf[i].valid)
         g_scoresValid = false;
   g_local  = 0.25 * g_tf[TF_M1].score  + 0.40 * g_tf[TF_M5].score + 0.35 * g_tf[TF_M15].score;
   g_sup    = 0.30 * g_tf[TF_M30].score + 0.35 * g_tf[TF_H1].score + 0.35 * g_tf[TF_H4].score;
   g_global = 0.65 * g_local + 0.35 * g_sup;
  }

string ScoresStr()
  {
   return "L " + SG(g_local) + " S " + SG(g_sup) + " G " + SG(g_global);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 5 : FAIR VALUE GAPS                                      |
//|                                                                  |
//| FVG haussier : bas(bougie 3) > haut(bougie 1). Zone [haut1,bas3].|
//| FVG baissier : haut(bougie 3) < bas(bougie 1). Zone [haut3,bas1].|
//| Cree a la CLOTURE de la bougie 3. Etats suivis bougie M5 par     |
//| bougie M5 : Neuf -> Touche -> Mitige 50 % ; Invalide sur cloture |
//| au-dela du bord oppose ; supprime au-dela de l'age max.          |
//| M1 et H4 sont calcules (tableau de bord) mais n'arment jamais.   |
//+------------------------------------------------------------------+
double FvgMinSize(int i)
  {
   switch(i)
     {
      case TF_M1:  return InpFvgMinM1;
      case TF_M5:  return InpFvgMinM5;
      case TF_M15: return InpFvgMinM15;
      case TF_M30: return InpFvgMinM30;
      case TF_H1:  return InpFvgMinH1;
     }
   return InpFvgMinH4;
  }

bool IsArmTF(int i) { return (i == TF_M5 || i == TF_M15 || i == TF_M30 || i == TF_H1); }

string FvgStateStr(int s)
  {
   switch(s)
     {
      case FVG_NEW:     return "Neuf";
      case FVG_TOUCHED: return "Touche";
      case FVG_MIT50:   return "Mitige50";
     }
   return "Invalide";
  }

// Applique une bougie a un FVG. Retourne true si c'est le premier touch d'un FVG neuf.
bool ApplyBarToFVG(FVGZone &z, const MqlRates &b)
  {
   bool wasNew  = (z.state == FVG_NEW);
   bool touched = (z.dir > 0) ? (b.low <= z.top) : (b.high >= z.bot);
   bool invalid = (z.dir > 0) ? (b.close < z.bot) : (b.close > z.top);
   double mid   = 0.5 * (z.top + z.bot);
   bool mit     = (z.dir > 0) ? (b.low <= mid) : (b.high >= mid);
   if(invalid)
     {
      z.state = FVG_INVALID;
      return false;
     }
   if(mit && z.state < FVG_MIT50)
      z.state = FVG_MIT50;
   else if(touched && z.state < FVG_TOUCHED)
      z.state = FVG_TOUCHED;
   return (wasNew && touched);
  }

void AddFVG(const FVGZone &z)
  {
   int n = ArraySize(g_fvg);
   for(int j = 0; j < n; j++)
      if(g_fvg[j].tf == z.tf && g_fvg[j].dir == z.dir && g_fvg[j].created == z.created)
         return;
   ArrayResize(g_fvg, n + 1, 64);
   g_fvg[n] = z;
  }

// Detecte les FVG formes par les bougies fermees plus recentes que 'prev'.
// prev == 0 : chargement de l'historique (age max), etats rejoues avec les bougies du meme TF.
void DetectFVG(int i, datetime prev)
  {
   int n = g_tf[i].bars;
   int ps = PeriodSeconds(g_tfs[i]);
   double minSz = IP(FvgMinSize(i));
   int maxK = MathMin(n - 3, InpFvgMaxAge);
   for(int k = maxK; k >= 0; k--)
     {
      if(prev > 0 && g_rb[i].r[k].time <= prev)
         continue;
      double c1h = g_rb[i].r[k + 2].high, c1l = g_rb[i].r[k + 2].low;
      double c3h = g_rb[i].r[k].high,     c3l = g_rb[i].r[k].low;
      FVGZone z;
      z.tf = i;
      z.dir = 0;
      z.top = 0;
      z.bot = 0;
      z.state = FVG_NEW;
      z.consumed = false;
      z.created = g_rb[i].r[k].time + (datetime)ps;
      if(c3l - c1h >= minSz)
        {
         z.dir = 1;
         z.bot = c1h;
         z.top = c3l;
        }
      else if(c1l - c3h >= minSz)
        {
         z.dir = -1;
         z.top = c1l;
         z.bot = c3h;
        }
      if(z.dir == 0)
         continue;
      // Rejoue les bougies deja fermees apres la creation (pas de FVG "neuf" deja touche)
      for(int j = k - 1; j >= 0 && z.state != FVG_INVALID; j--)
         ApplyBarToFVG(z, g_rb[i].r[j]);
      if(z.state == FVG_INVALID)
         continue;
      AddFVG(z);
     }
  }

// Bougies completes du timeframe du FVG ecoulees depuis sa creation, a l'instant 'atTime'
int FvgAgeBars(const FVGZone &z, datetime atTime)
  {
   ENUM_TIMEFRAMES tf = g_tfs[z.tf];
   int sc = iBarShift(_Symbol, tf, z.created, false);
   int sn = iBarShift(_Symbol, tf, atTime, false);
   if(sc < 0 || sn < 0)
      return (int)((atTime - z.created) / PeriodSeconds(tf));
   return MathMax(0, sc - sn);
  }

int CountActiveFVG(int tf, int dir)
  {
   int c = 0;
   for(int j = 0; j < ArraySize(g_fvg); j++)
      if(g_fvg[j].tf == tf && g_fvg[j].state != FVG_INVALID && (dir == 0 || g_fvg[j].dir == dir))
         c++;
   return c;
  }

void CompactFVG()
  {
   int n = ArraySize(g_fvg), w = 0;
   for(int j = 0; j < n; j++)
     {
      if(g_fvg[j].state == FVG_INVALID)
         continue;
      if(w != j)
         g_fvg[w] = g_fvg[j];
      w++;
     }
   if(w != n)
      ArrayResize(g_fvg, w, 64);
  }

string FvgDesc(int tf, int dir, double top, double bot)
  {
   return g_tfName[tf] + " " + DirShort(dir) + " [" + FP(bot) + " - " + FP(top) + "]";
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 6 : JOURNAL DES DECISIONS                                |
//|                                                                  |
//| Une ligne par decision (autorisation ou refus) avec les scores   |
//| exacts du moment. Evenements :                                   |
//|  ARM / REFUS_ARM / CONFIRM / ANNUL / EXPIRE / ENTREE / SIGNAL /  |
//|  REFUS_ENTREE / TP1 / TP2 / BE / TRAIL / SORTIE_FORCEE /         |
//|  STOP_JOUR / ETAT                                                |
//+------------------------------------------------------------------+
string DecisionHeader()
  {
   return "heure_serveur;heure_ny;evenement;sens;fvg_tf;fvg_bas;fvg_haut;fvg_age;"
          "local;superieur;global;M1;M5;M15;M30;H1;H4;etat_M5;etat_M15;spread;confirmations;raison";
  }

void LogDecision(string ev, int dir, int tf, double bot, double top, int age, string conf, string reason)
  {
   g_lastDecision = ev + (dir != 0 ? " " + DirStr(dir) : "") + " : " + reason;
   if(InpVerbose)
      PrintFormat("[VM22] %s %s %s | %s | %s", ev, DirStr(dir),
                  (tf >= 0 ? g_tfName[tf] : ""), ScoresStr(), reason);
   if(!LogsOn())
      return;
   datetime srv = TimeCurrent();
   string line = TimeToString(srv, TIME_DATE | TIME_SECONDS) + ";" +
                 TimeToString(ServerToNY(srv), TIME_DATE | TIME_SECONDS) + ";" +
                 ev + ";" + DirStr(dir) + ";" +
                 (tf >= 0 ? g_tfName[tf] : "") + ";" +
                 (tf >= 0 ? FP(bot) : "") + ";" + (tf >= 0 ? FP(top) : "") + ";" +
                 (age >= 0 ? IntegerToString(age) : "") + ";" +
                 F1(g_local) + ";" + F1(g_sup) + ";" + F1(g_global);
   for(int i = 0; i < NTF; i++)
      line += ";" + F1(g_tf[i].score);
   line += ";" + g_tf[TF_M5].state + ";" + g_tf[TF_M15].state + ";" +
           F2(SpreadPrice() / InpIndexPoint) + ";" + CsvSafe(conf) + ";" + CsvSafe(reason);
   AppendCSV(g_fileDecisions, DecisionHeader(), line);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 7 : CONFIRMATIONS M5                                     |
//|                                                                  |
//| Evaluees sur la bougie M5 qui vient de fermer (r[0]).            |
//|  BOS     : cloture au-dela d'un swing L3 de moins de 25 bougies  |
//|            pas encore casse.                                     |
//|  IFVG    : cloture qui traverse un FVG contraire de <= 20 bougies|
//|            encore intact.                                        |
//|  PIN     : pin bar de rejet apres un mouvement contraire.        |
//|  ENGULF  : engulfing apres un mouvement contraire.               |
//|  DOUBLE  : double bottom / double top a hauteur >= 0.7 ATR.      |
//| Patterns : taille >= InpPatternMinATR x ATR M5. Les autres       |
//| figures (doji, harami, etoiles...) sont volontairement absentes. |
//+------------------------------------------------------------------+
bool ConfBOS(int dir)
  {
   int n = g_tf[TF_M5].bars;
   int L = InpBosPivotLen;
   double c0 = g_rb[TF_M5].r[0].close;
   // Swing confirme AVANT la bougie courante : p - L >= 1
   for(int p = L + 1; p <= InpBosMaxAge && p <= n - 1 - L; p++)
     {
      if(dir > 0 && IsPivotHigh(g_rb[TF_M5].r, p, L, n))
        {
         double lvl = g_rb[TF_M5].r[p].high;
         bool intact = true;
         for(int k = 1; k < p; k++)
            if(g_rb[TF_M5].r[k].close > lvl) { intact = false; break; }
         return (intact && c0 > lvl);
        }
      if(dir < 0 && IsPivotLow(g_rb[TF_M5].r, p, L, n))
        {
         double lvl = g_rb[TF_M5].r[p].low;
         bool intact = true;
         for(int k = 1; k < p; k++)
            if(g_rb[TF_M5].r[k].close < lvl) { intact = false; break; }
         return (intact && c0 < lvl);
        }
     }
   return false;
  }

bool ConfIFVG(int dir)
  {
   int n = g_tf[TF_M5].bars;
   double c0 = g_rb[TF_M5].r[0].close;
   double minSz = IP(InpIfvgMinSize);
   for(int j = 1; j <= InpIfvgMaxAge && j + 2 <= n - 1; j++)
     {
      double c1h = g_rb[TF_M5].r[j + 2].high, c1l = g_rb[TF_M5].r[j + 2].low;
      double c3h = g_rb[TF_M5].r[j].high,     c3l = g_rb[TF_M5].r[j].low;
      if(dir > 0 && c1l - c3h >= minSz)          // FVG baissier [c3h, c1l]
        {
         double top = c1l;
         bool intact = true;
         for(int k = 1; k < j; k++)
            if(g_rb[TF_M5].r[k].close > top) { intact = false; break; }
         if(intact && c0 > top)
            return true;
        }
      if(dir < 0 && c3l - c1h >= minSz)          // FVG haussier [c1h, c3l]
        {
         double bot = c1h;
         bool intact = true;
         for(int k = 1; k < j; k++)
            if(g_rb[TF_M5].r[k].close < bot) { intact = false; break; }
         if(intact && c0 < bot)
            return true;
        }
     }
   return false;
  }

// Contexte contraire prealable : le mouvement des bougies precedentes va contre le trade
bool PriorContrary(int dir)
  {
   if(g_tf[TF_M5].bars < 8)
      return false;
   double moved = g_rb[TF_M5].r[1].close - g_rb[TF_M5].r[4].close;
   return (dir > 0) ? (moved < 0) : (moved > 0);
  }

bool ConfPin(int dir)
  {
   MqlRates b = g_rb[TF_M5].r[0];
   double rng = b.high - b.low;
   double atr = g_tf[TF_M5].atr;
   if(rng < InpPatternMinATR * atr || rng <= 0)
      return false;
   double body = MathAbs(b.close - b.open);
   double lowW = MathMin(b.open, b.close) - b.low;
   double upW  = b.high - MathMax(b.open, b.close);
   if(body > 0.33 * rng)
      return false;
   // Nouveau plus bas/haut local OU mouvement contraire prealable
   double ext = (dir > 0) ? DBL_MAX : -DBL_MAX;
   for(int k = 1; k <= 5; k++)
      ext = (dir > 0) ? MathMin(ext, g_rb[TF_M5].r[k].low) : MathMax(ext, g_rb[TF_M5].r[k].high);
   bool ctx = PriorContrary(dir) || ((dir > 0) ? (b.low <= ext) : (b.high >= ext));
   if(!ctx)
      return false;
   if(dir > 0)
      return (lowW >= 0.6 * rng && b.close >= b.low + 0.5 * rng);
   return (upW >= 0.6 * rng && b.close <= b.high - 0.5 * rng);
  }

bool ConfEngulf(int dir)
  {
   MqlRates b0 = g_rb[TF_M5].r[0];
   MqlRates b1 = g_rb[TF_M5].r[1];
   double atr = g_tf[TF_M5].atr;
   if((b0.high - b0.low) < InpPatternMinATR * atr)
      return false;
   double body0 = MathAbs(b0.close - b0.open), body1 = MathAbs(b1.close - b1.open);
   if(body0 <= body1 || !PriorContrary(dir))
      return false;
   if(dir > 0)
      return (b0.close > b0.open && b1.close < b1.open && b0.close >= b1.open && b0.open <= b1.close);
   return (b0.close < b0.open && b1.close > b1.open && b0.close <= b1.open && b0.open >= b1.close);
  }

bool ConfDouble(int dir)
  {
   int n = g_tf[TF_M5].bars;
   double atr = g_tf[TF_M5].atr;
   MqlRates b0 = g_rb[TF_M5].r[0];
   double rng0 = b0.high - b0.low;
   if(rng0 <= 0)
      return false;
   // Bougie de confirmation dans le sens du trade, cloture dans la bonne moitie
   if(dir > 0 && !(b0.close > b0.open && b0.close >= b0.low + 0.5 * rng0))
      return false;
   if(dir < 0 && !(b0.close < b0.open && b0.close <= b0.high - 0.5 * rng0))
      return false;
   // Second creux/sommet : extreme des bougies 0..1
   int b = (dir > 0) ? (g_rb[TF_M5].r[0].low <= g_rb[TF_M5].r[1].low ? 0 : 1)
                     : (g_rb[TF_M5].r[0].high >= g_rb[TF_M5].r[1].high ? 0 : 1);
   double second = (dir > 0) ? g_rb[TF_M5].r[b].low : g_rb[TF_M5].r[b].high;
   double tol = MathMax(0.15 * atr, IP(2.0));
   for(int p = b + 3; p <= 30 && p <= n - 3; p++)
     {
      bool piv = (dir > 0) ? IsPivotLow(g_rb[TF_M5].r, p, 2, n) : IsPivotHigh(g_rb[TF_M5].r, p, 2, n);
      if(!piv)
         continue;
      double first = (dir > 0) ? g_rb[TF_M5].r[p].low : g_rb[TF_M5].r[p].high;
      if(MathAbs(first - second) > tol)
         continue;
      // Aucun extreme depassant les deux creux entre eux ; ligne de cou = extreme oppose
      double bound = (dir > 0) ? MathMin(first, second) : MathMax(first, second);
      double neck = (dir > 0) ? -DBL_MAX : DBL_MAX;
      bool clean = true;
      for(int k = b + 1; k < p; k++)
        {
         if(dir > 0)
           {
            if(g_rb[TF_M5].r[k].low < bound) { clean = false; break; }
            neck = MathMax(neck, g_rb[TF_M5].r[k].high);
           }
         else
           {
            if(g_rb[TF_M5].r[k].high > bound) { clean = false; break; }
            neck = MathMin(neck, g_rb[TF_M5].r[k].low);
           }
        }
      if(!clean)
         continue;
      double height = (dir > 0) ? (neck - bound) : (bound - neck);
      if(height >= InpPatternMinATR * atr)
         return true;
     }
   return false;
  }

// Retourne la liste des confirmations presentes sur la bougie M5 fermee ("" si aucune)
string CheckConfirmations(int dir)
  {
   string t = "";
   if(ConfBOS(dir))                      t += (t == "" ? "" : "+") + "BOS";
   if(ConfIFVG(dir))                     t += (t == "" ? "" : "+") + "IFVG";
   if(InpUsePinBar && ConfPin(dir))      t += (t == "" ? "" : "+") + "PIN";
   if(InpUseEngulfing && ConfEngulf(dir)) t += (t == "" ? "" : "+") + "ENGULF";
   if(InpUseDouble && ConfDouble(dir))   t += (t == "" ? "" : "+") + (dir > 0 ? "DBL_BOTTOM" : "DBL_TOP");
   return t;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 8 : ARMEMENT ET SUIVI DU SETUP                           |
//+------------------------------------------------------------------+
int CountOurPositions()
  {
   int c = 0;
   for(int k = PositionsTotal() - 1; k >= 0; k--)
     {
      ulong t = PositionGetTicket(k);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         c++;
     }
   return c;
  }

// Protections de capital communes a l'armement et a l'entree
bool CheckRiskGate(string &why)
  {
   if(g_day.stopped)
     {
      why = "journee bloquee : " + g_day.stopReason;
      return false;
     }
   if(g_day.trades >= InpMaxTradesDay)
     {
      why = StringFormat("max trades du jour atteint (%d/%d)", g_day.trades, InpMaxTradesDay);
      return false;
     }
   if(g_day.consec >= InpMaxConsecLoss)
     {
      why = StringFormat("max pertes consecutives atteint (%d/%d)", g_day.consec, InpMaxConsecLoss);
      return false;
     }
   int maxPos = MathMax(1, MathMin(1, InpMaxPositions));
   if(g_pos.active || CountOurPositions() >= maxPos)
     {
      why = "position deja ouverte (max " + IntegerToString(maxPos) + ")";
      return false;
     }
   return true;
  }

// Conditions de score 3 a 6 de la specification
bool CheckScoreGate(int dir, string &why)
  {
   if(!g_scoresValid)
     {
      why = "scores indisponibles (donnees d'un timeframe non pretes)";
      return false;
     }
   double L = g_local * dir, G = g_global * dir, S = g_sup * dir, m5 = g_tf[TF_M5].score * dir;
   if(L < InpContMinLocal)
     {
      why = StringFormat("score Local %s insuffisant (min %.0f en %s)", SG(g_local), InpContMinLocal, DirStr(dir));
      return false;
     }
   if(G < InpContMinGlobal)
     {
      why = StringFormat("score Global %s insuffisant (min %.0f en %s)", SG(g_global), InpContMinGlobal, DirStr(dir));
      return false;
     }
   if(S <= -InpHTFOpposeLimit && L < InpLocalOverride)
     {
      why = StringFormat("Superieur %s fortement contraire : Local %s doit atteindre %.0f",
                         SG(g_sup), SG(g_local), InpLocalOverride);
      return false;
     }
   if(m5 <= -InpM5OpposeLimit)
     {
      why = StringFormat("structure M5 fortement contraire (M5 %s)", SG(g_tf[TF_M5].score));
      return false;
     }
   return true;
  }

void DrawArmZone()
  {
   if(!InpDrawPlans || MQLInfoInteger(MQL_OPTIMIZATION))
      return;
   string nm = PLAN_PREFIX + "arm_" + IntegerToString((long)g_setup.armBar);
   ObjectDelete(0, nm);
   ObjectCreate(0, nm, OBJ_RECTANGLE, 0, g_setup.fvgCreated, g_setup.top,
                g_setup.expire, g_setup.bot);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, g_setup.dir > 0 ? clrSeaGreen : clrIndianRed);
   ObjectSetInteger(0, nm, OBJPROP_FILL, true);
   ObjectSetInteger(0, nm, OBJPROP_BACK, true);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, nm, OBJPROP_TOOLTIP, "Setup arme " + DirStr(g_setup.dir) + " " +
                   FvgDesc(g_setup.tf, g_setup.dir, g_setup.top, g_setup.bot));
  }

// Tentative d'armement sur le premier touch d'un FVG neuf. 'z' devient consomme si arme.
void EvaluateArm(FVGZone &z, const MqlRates &b)
  {
   datetime barClose = b.time + PeriodSeconds(PERIOD_M5);
   int age = FvgAgeBars(z, barClose);
   string why = "";
   bool ok = true;
   if(z.consumed)
     { ok = false; why = "FVG deja consomme"; }
   else if(age < InpFvgMinAge)
     { ok = false; why = StringFormat("FVG trop recent (%d bougies %s < %d)", age, g_tfName[z.tf], InpFvgMinAge); }
   else if(!InEntryWindow(ServerToNY(b.time)))
     { ok = false; why = "hors fenetre d'entree NY (bougie de touch " + NYStr(ServerToNY(b.time)) + ")"; }
   else if(g_setup.active)
     { ok = false; why = "un setup est deja arme"; }
   else if(!CheckRiskGate(why))
      ok = false;
   else if(!CheckScoreGate(z.dir, why))
      ok = false;

   if(!ok)
     {
      g_setupReason = "dernier refus : " + why;
      LogDecision("REFUS_ARM", z.dir, z.tf, z.bot, z.top, age, "", why);
      return;
     }
   z.consumed = true;
   g_setup.active     = true;
   g_setup.dir        = z.dir;
   g_setup.tf         = z.tf;
   g_setup.top        = z.top;
   g_setup.bot        = z.bot;
   g_setup.fvgCreated = z.created;
   g_setup.armBar     = b.time;
   g_setup.expire     = barClose + InpArmMinutes * 60;
   g_setup.conf       = 0;
   g_setup.confTags   = "";
   g_setup.extLow     = b.low;
   g_setup.extHigh    = b.high;
   g_setup.armLocal   = g_local;
   g_setup.armSup     = g_sup;
   g_setup.armGlobal  = g_global;
   string msg = StringFormat("touch FVG %s neuf, %d bougies ; arme jusqu'a %s NY",
                             FvgDesc(z.tf, z.dir, z.top, z.bot), age, NYStr(ServerToNY(g_setup.expire)));
   g_setupReason = msg;
   LogDecision("ARM", z.dir, z.tf, z.bot, z.top, age, "", msg);
   DrawArmZone();
  }

void DisarmSetup(string ev, string why)
  {
   if(!g_setup.active)
      return;
   LogDecision(ev, g_setup.dir, g_setup.tf, g_setup.bot, g_setup.top, -1, g_setup.confTags, why);
   g_setup.active = false;
   g_setupReason = ev + " : " + why;
  }

// Met a jour les FVG avec la bougie M5 fermee et tente l'armement sur les premiers touches
void ProcessFVGsOnM5(const MqlRates &b)
  {
   datetime barClose = b.time + PeriodSeconds(PERIOD_M5);
   int cand[];
   int nc = 0;
   int n = ArraySize(g_fvg);
   for(int j = 0; j < n; j++)
     {
      if(g_fvg[j].state == FVG_INVALID || b.time < g_fvg[j].created)
         continue;
      if(FvgAgeBars(g_fvg[j], barClose) > InpFvgMaxAge)
        {
         g_fvg[j].state = FVG_INVALID;
         continue;
        }
      bool first = ApplyBarToFVG(g_fvg[j], b);
      if(first && IsArmTF(g_fvg[j].tf))
        {
         ArrayResize(cand, nc + 1);
         cand[nc++] = j;
        }
     }
   if(nc > 0)
     {
      // Priorite : timeframe le plus eleve, puis FVG le plus grand
      int best = cand[0];
      for(int c = 1; c < nc; c++)
        {
         int j = cand[c];
         double szj = g_fvg[j].top - g_fvg[j].bot, szb = g_fvg[best].top - g_fvg[best].bot;
         if(g_fvg[j].tf > g_fvg[best].tf || (g_fvg[j].tf == g_fvg[best].tf && szj > szb))
            best = j;
        }
      for(int c = 0; c < nc; c++)
        {
         int j = cand[c];
         if(j == best)
            continue;
         LogDecision("REFUS_ARM", g_fvg[j].dir, g_fvg[j].tf, g_fvg[j].bot, g_fvg[j].top,
                     FvgAgeBars(g_fvg[j], barClose), "",
                     "FVG concurrent prioritaire touche sur la meme bougie (" + g_tfName[g_fvg[best].tf] + ")");
        }
      EvaluateArm(g_fvg[best], b);
     }
   CompactFVG();
  }

// Suivi du setup arme sur chaque nouvelle bougie M5 fermee
void ProcessSetupOnM5(const MqlRates &b)
  {
   if(!g_setup.active || b.time <= g_setup.armBar)
      return;
   datetime barClose = b.time + PeriodSeconds(PERIOD_M5);
   g_setup.extLow  = MathMin(g_setup.extLow, b.low);
   g_setup.extHigh = MathMax(g_setup.extHigh, b.high);

   if((g_setup.dir > 0 && b.close < g_setup.bot) || (g_setup.dir < 0 && b.close > g_setup.top))
     {
      DisarmSetup("ANNUL", "cloture M5 " + FP(b.close) + " au-dela du bord oppose du FVG");
      return;
     }
   if(barClose > g_setup.expire)
     {
      DisarmSetup("EXPIRE", StringFormat("aucune entree apres %d minutes (%d/%d confirmations)",
                                         InpArmMinutes, g_setup.conf, InpConfNeeded));
      return;
     }
   string tags = CheckConfirmations(g_setup.dir);
   if(tags != "")
     {
      g_setup.conf++;
      g_setup.confTags += (g_setup.confTags == "" ? "" : " | ") + tags;
      string msg = StringFormat("confirmation %d/%d : %s", g_setup.conf, InpConfNeeded, tags);
      g_setupReason = "arme, " + msg;
      LogDecision("CONFIRM", g_setup.dir, g_setup.tf, g_setup.bot, g_setup.top, -1, g_setup.confTags, msg);
     }
   if(g_setup.conf >= InpConfNeeded)
      TryEntry();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 9 : STOP LOSS, TAKE PROFIT, SIZING, ENTREE               |
//|                                                                  |
//| Echelles de prix :                                               |
//|  - achat : entree au Ask ; SL, TP et R mesures sur le Bid.       |
//|  - vente : entree au Bid ; le SL et le TP se declenchent sur le  |
//|    Ask, donc SL et TP3 sont decales du spread courant pour que   |
//|    la sortie corresponde au niveau lu sur le graphique (Bid).    |
//|  - R courant : achat (Bid - entree)/dist, vente (entree - Ask)/  |
//|    dist. Le SL correspond exactement a -1 R dans les deux sens.  |
//+------------------------------------------------------------------+
// Candidats dans l'ordre : plus bas depuis l'armement (M5), dernier pivot M5 L3,
// dernier pivot M15 L3. Le premier dont la distance <= SLMax est retenu, puis porte a SLMin.
bool ComputeSL(int dir, double entry, double bid, double ask, double &sl, double &dist, string &src, string &why)
  {
   double spread = ask - bid;
   double buf = IP(InpSLBuffer);
   double cand[3];
   string name[3] = {"M5 extreme depuis armement", "M5 pivot L3", "M15 pivot L3"};
   double lvl = 0;
   cand[0] = (dir > 0) ? g_setup.extLow - buf : g_setup.extHigh + buf + spread;
   cand[1] = 0;
   cand[2] = 0;
   if(FindLastPivot(TF_M5, 3, dir, dir > 0 ? bid : ask, lvl))
      cand[1] = (dir > 0) ? lvl - buf : lvl + buf + spread;
   if(g_tf[TF_M15].valid && FindLastPivot(TF_M15, 3, dir, dir > 0 ? bid : ask, lvl))
      cand[2] = (dir > 0) ? lvl - buf : lvl + buf + spread;

   string tried = "";
   for(int c = 0; c < 3; c++)
     {
      if(cand[c] <= 0)
         continue;
      double d = (dir > 0) ? entry - cand[c] : cand[c] - entry;
      if(d <= 0)
         continue;
      tried += (tried == "" ? "" : ", ") + name[c] + " " + F1(d / InpIndexPoint);
      if(d > IP(InpSLMaxAbs))
         continue;
      double s = cand[c];
      src = name[c];
      if(d < IP(InpSLMin))
        {
         s = (dir > 0) ? entry - IP(InpSLMin) : entry + IP(InpSLMin);
         src += " (porte au minimum " + F1(InpSLMin) + ")";
        }
      sl = NormPrice(s);
      dist = (dir > 0) ? entry - sl : sl - entry;
      return true;
     }
   why = "SL trop large (> " + F1(InpSLMaxAbs) + " pts) : " + (tried == "" ? "aucun niveau valide" : tried);
   return false;
  }

// Liquidite non balayee la plus proche offrant au moins InpTP3_MinRR.
// Sources : pivots M5 (L3), M15, M30, H1, H4 non depasses depuis, haut/bas de la veille (D1).
bool FindLiquidity(int dir, double entry, double dist, double bid, double ask, double &level, string &src)
  {
   bool found = false;
   double best = 0;
   int tfs[5] = {TF_M5, TF_M15, TF_M30, TF_H1, TF_H4};
   for(int a = 0; a < 5; a++)
     {
      int i = tfs[a];
      if(!g_tf[i].valid)
         continue;
      int L = (i == TF_M5) ? 3 : g_pivLen[i];
      int n = g_tf[i].bars;
      // Extreme des bougies plus recentes que p, bougie en formation incluse
      double ext = (dir > 0) ? iHigh(_Symbol, g_tfs[i], 0) : iLow(_Symbol, g_tfs[i], 0);
      for(int p = 0; p < n - L; p++)
        {
         if(p >= L)
           {
            bool piv = (dir > 0) ? IsPivotHigh(g_rb[i].r, p, L, n) : IsPivotLow(g_rb[i].r, p, L, n);
            if(piv)
              {
               double lv = (dir > 0) ? g_rb[i].r[p].high : g_rb[i].r[p].low;
               bool unswept = (dir > 0) ? (lv > ext && lv > bid) : (lv < ext && lv < bid);
               if(unswept)
                 {
                  double target = (dir > 0) ? lv - IP(InpTP3_Offset) : lv + IP(InpTP3_Offset);
                  double rr = (dir > 0) ? (target - entry) / dist : (entry - target) / dist;
                  if(rr >= InpTP3_MinRR && (!found || (dir > 0 ? lv < best : lv > best)))
                    {
                     best = lv;
                     found = true;
                     src = "pivot " + g_tfName[i] + " " + FP(lv);
                    }
                 }
              }
           }
         ext = (dir > 0) ? MathMax(ext, g_rb[i].r[p].high) : MathMin(ext, g_rb[i].r[p].low);
        }
     }
   // Haut / bas de la journee precedente
   double pd = (dir > 0) ? iHigh(_Symbol, PERIOD_D1, 1) : iLow(_Symbol, PERIOD_D1, 1);
   double td = (dir > 0) ? iHigh(_Symbol, PERIOD_D1, 0) : iLow(_Symbol, PERIOD_D1, 0);
   if(pd > 0 && td > 0 && ((dir > 0 && td < pd) || (dir < 0 && td > pd)))
     {
      double target = (dir > 0) ? pd - IP(InpTP3_Offset) : pd + IP(InpTP3_Offset);
      double rr = (dir > 0) ? (target - entry) / dist : (entry - target) / dist;
      if(rr >= InpTP3_MinRR && (!found || (dir > 0 ? pd < best : pd > best)))
        {
         best = pd;
         found = true;
         src = (dir > 0 ? "haut" : "bas") + string(" de la veille ") + FP(pd);
        }
     }
   level = best;
   return found;
  }

// Lot exact pour que la perte au SL = risque choisi (conversion de devise via OrderCalcProfit)
bool ComputeLot(int dir, double entry, double sl, double &lot, double &riskMoney, double &realRisk, string &why)
  {
   double budget = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double profit = 0, lossPerLot = 0;
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcProfit(ot, _Symbol, 1.0, entry, sl, profit) && profit < 0)
      lossPerLot = -profit;
   else
     {
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv <= 0)
         tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tv <= 0 || ts <= 0)
        {
         why = "valeur du tick indisponible";
         return false;
        }
      lossPerLot = MathAbs(entry - sl) / ts * tv;
     }
   lossPerLot += MathMax(0.0, InpCommissionPerLot);
   if(lossPerLot <= 0)
     {
      why = "perte par lot nulle";
      return false;
     }
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double raw  = budget / lossPerLot;
   lot = NormVolDown(raw);
   if(lot < vmin - 1e-9)
     {
      why = StringFormat("lot minimum %.2f depasse le risque autorise (lot calcule %.4f, risque min %.2f > %.2f)",
                         vmin, raw, vmin * lossPerLot, budget);
      return false;
     }
   if(vmax > 0 && lot > vmax)
      lot = NormVolDown(vmax);
   double margin = 0;
   if(OrderCalcMargin(ot, _Symbol, lot, entry, margin) && margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      why = StringFormat("marge insuffisante (%.2f requise)", margin);
      return false;
     }
   riskMoney = budget;
   realRisk  = lot * lossPerLot;
   return true;
  }

void DrawLevel(string tag, datetime t0, datetime t1, double price, color clr, int style, string label)
  {
   string nm = PLAN_PREFIX + tag;
   ObjectDelete(0, nm);
   ObjectCreate(0, nm, OBJ_TREND, 0, t0, price, t1, price);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, nm, OBJPROP_STYLE, style);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, nm, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, nm, OBJPROP_TOOLTIP, label + " " + FP(price));
   string tn = nm + "_t";
   ObjectDelete(0, tn);
   ObjectCreate(0, tn, OBJ_TEXT, 0, t1, price);
   ObjectSetString(0, tn, OBJPROP_TEXT, label + " " + FP(price));
   ObjectSetInteger(0, tn, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, tn, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, tn, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, tn, OBJPROP_SELECTABLE, false);
  }

void DrawPlan(int dir, double entry, double sl, double tp1, double tp2, double tp3, string head)
  {
   if(!InpDrawPlans || MQLInfoInteger(MQL_OPTIMIZATION))
      return;
   datetime t0 = TimeCurrent();
   datetime t1 = t0 + 2 * 3600;
   string id = IntegerToString((long)t0) + "_";
   DrawLevel(id + "E",   t0, t1, entry, clrDodgerBlue, STYLE_SOLID, head + " ENTREE");
   DrawLevel(id + "SL",  t0, t1, sl,    clrRed,        STYLE_SOLID, "SL");
   DrawLevel(id + "TP1", t0, t1, tp1,   clrLimeGreen,  STYLE_DOT,   "TP1 " + F1(InpTP1_RR) + "R");
   DrawLevel(id + "TP2", t0, t1, tp2,   clrLimeGreen,  STYLE_DOT,   "TP2 " + F1(InpTP2_RR) + "R");
   DrawLevel(id + "TP3", t0, t1, tp3,   clrGold,       STYLE_DASH,  "TP3");
   string an = PLAN_PREFIX + id + "arrow";
   ObjectDelete(0, an);
   ObjectCreate(0, an, dir > 0 ? OBJ_ARROW_BUY : OBJ_ARROW_SELL, 0, t0, entry);
   ObjectSetInteger(0, an, OBJPROP_SELECTABLE, false);
  }

void RefuseEntry(string why)
  {
   LogDecision("REFUS_ENTREE", g_setup.dir, g_setup.tf, g_setup.bot, g_setup.top, -1, g_setup.confTags, why);
   g_setupReason = "REFUS_ENTREE : " + why;
   g_setup.active = false;
  }

// Confirmations obtenues : revalidation complete puis envoi (ou signal)
void TryEntry()
  {
   int dir = g_setup.dir;
   string why = "";
   datetime nyNow = ServerToNY(TimeCurrent());
   if(!InEntryWindow(nyNow))         { RefuseEntry("hors fenetre d'entree NY a la confirmation"); return; }
   if(!CheckRiskGate(why))           { RefuseEntry(why); return; }
   if(!CheckScoreGate(dir, why))     { RefuseEntry("contexte deteriore : " + why); return; }

   double bid = Bid(), ask = Ask();
   double spread = ask - bid;
   if(bid <= 0 || ask <= 0)          { RefuseEntry("prix indisponible"); return; }
   if(spread > IP(InpMaxSpread))
     { RefuseEntry(StringFormat("spread %.2f > max %.2f", spread / InpIndexPoint, InpMaxSpread)); return; }

   double entry = (dir > 0) ? ask : bid;
   double sl = 0, dist = 0;
   string slSrc = "";
   if(!ComputeSL(dir, entry, bid, ask, sl, dist, slSrc, why)) { RefuseEntry(why); return; }
   if(spread > dist * InpMaxSpreadSLPct / 100.0)
     {
      RefuseEntry(StringFormat("spread %.2f = %.1f%% du SL (max %.1f%%)", spread / InpIndexPoint,
                               100.0 * spread / dist, InpMaxSpreadSLPct));
      return;
     }
   long stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(dist < stopsLvl * _Point)
     { RefuseEntry("SL plus proche que le stops level du broker"); return; }

   // Take profits
   double tp1 = (dir > 0) ? entry + InpTP1_RR * dist : entry - InpTP1_RR * dist;
   double tp2 = (dir > 0) ? entry + InpTP2_RR * dist : entry - InpTP2_RR * dist;
   double liq = 0, tp3 = 0;
   string tp3src = "";
   if(FindLiquidity(dir, entry, dist, bid, ask, liq, tp3src))
      tp3 = (dir > 0) ? liq - IP(InpTP3_Offset) : liq + IP(InpTP3_Offset) + spread;
   else
     {
      tp3 = (dir > 0) ? entry + InpTP3_DefaultRR * dist : entry - InpTP3_DefaultRR * dist + spread;
      tp3src = "defaut " + F1(InpTP3_DefaultRR) + "R";
     }
   tp1 = NormPrice(tp1);
   tp2 = NormPrice(tp2);
   tp3 = NormPrice(tp3);

   double lot = 0, riskMoney = 0, realRisk = 0;
   if(!ComputeLot(dir, entry, sl, lot, riskMoney, realRisk, why)) { RefuseEntry(why); return; }

   string fvg = FvgDesc(g_setup.tf, dir, g_setup.top, g_setup.bot);
   string plan = StringFormat("%s %.2f lots @ %s | SL %s (%.1f pts, %s) | TP1 %s TP2 %s TP3 %s (%s) | risque %.2f | spread %.2f",
                              DirStr(dir), lot, FP(entry), FP(sl), dist / InpIndexPoint, slSrc,
                              FP(tp1), FP(tp2), FP(tp3), tp3src, realRisk, spread / InpIndexPoint);

   if(!InpTradeEnabled)
     {
      g_day.trades++;
      SaveDay();
      LogDecision("SIGNAL", dir, g_setup.tf, g_setup.bot, g_setup.top, -1, g_setup.confTags, "MODE SIGNAUX : " + plan);
      PrintFormat("[VM22] ===== SIGNAL %s ===== %s | FVG %s | confirmations %s",
                  DirStr(dir), plan, fvg, g_setup.confTags);
      DrawPlan(dir, entry, sl, tp1, tp2, tp3, "SIGNAL " + DirStr(dir));
      g_setupReason = "signal emis : " + DirStr(dir) + " " + fvg;
      g_setup.active = false;
      return;
     }

   bool ok = (dir > 0) ? g_trade.Buy(lot, _Symbol, 0, sl, tp3, InpComment + " " + g_tfName[g_setup.tf])
                       : g_trade.Sell(lot, _Symbol, 0, sl, tp3, InpComment + " " + g_tfName[g_setup.tf]);
   uint rc = g_trade.ResultRetcode();
   if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED && rc != TRADE_RETCODE_DONE_PARTIAL))
     {
      RefuseEntry(StringFormat("ordre rejete par le broker (retcode %u : %s)", rc, g_trade.ResultRetcodeDescription()));
      return;
     }

   // Retrouve la position ouverte
   ResetPos();
   for(int k = PositionsTotal() - 1; k >= 0; k--)
     {
      ulong t = PositionGetTicket(k);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      g_pos.active  = true;
      g_pos.ticket  = t;
      g_pos.ident   = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      g_pos.entry   = PositionGetDouble(POSITION_PRICE_OPEN);
      g_pos.initVol = PositionGetDouble(POSITION_VOLUME);
      g_pos.openTime = (datetime)PositionGetInteger(POSITION_TIME);
      break;
     }
   if(!g_pos.active)
     {
      LogDecision("ENTREE", dir, g_setup.tf, g_setup.bot, g_setup.top, -1, g_setup.confTags,
                  "ordre execute mais position introuvable : " + plan);
      g_setup.active = false;
      return;
     }
   g_pos.dir   = dir;
   g_pos.sl0   = sl;
   g_pos.dist  = MathMax(_Point, (dir > 0) ? g_pos.entry - sl : sl - g_pos.entry);
   g_pos.tp1   = NormPrice((dir > 0) ? g_pos.entry + InpTP1_RR * g_pos.dist : g_pos.entry - InpTP1_RR * g_pos.dist);
   g_pos.tp2   = NormPrice((dir > 0) ? g_pos.entry + InpTP2_RR * g_pos.dist : g_pos.entry - InpTP2_RR * g_pos.dist);
   g_pos.tp3   = tp3;
   g_pos.riskMoney = (realRisk > 0) ? realRisk : riskMoney;
   g_pos.sLocal  = g_local;
   g_pos.sSup    = g_sup;
   g_pos.sGlobal = g_global;
   for(int i = 0; i < NTF; i++)
      g_pos.sTF[i] = g_tf[i].score;
   g_pos.spread  = spread / InpIndexPoint;
   g_pos.fvg     = fvg;
   g_pos.confs   = g_setup.confTags;
   g_pos.tp3src  = tp3src;
   g_day.trades++;
   SaveDay();
   SavePos();
   SaveCtx();
   g_realizedDirty = true;
   LogDecision("ENTREE", dir, g_setup.tf, g_setup.bot, g_setup.top, -1, g_setup.confTags,
               "ticket " + IntegerToString((long)g_pos.ticket) + " : " + plan);
   DrawPlan(dir, g_pos.entry, sl, g_pos.tp1, g_pos.tp2, tp3, DirStr(dir));
   g_setupReason = "position ouverte " + DirStr(dir) + " " + fvg;
   g_setup.active = false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 10 : GESTION DE LA POSITION OUVERTE                      |
//|                                                                  |
//| A chaque tick :                                                  |
//|  - 2.2 R : ferme 30 % du volume initial, SL au BE + 0.5 point    |
//|           (reessaye a chaque tick si le broker refuse).          |
//|  - 3.5 R : ferme encore 30 %.                                    |
//|  - ensuite : trailing sous/sur le dernier pivot M5 L3 +/- 3 pts. |
//|  - 16:25 NY ou perte journaliere atteinte : fermeture forcee.    |
//| Le SL ne s'eloigne jamais.                                       |
//+------------------------------------------------------------------+
double CurrentR()
  {
   if(!g_pos.active || g_pos.dist <= 0)
      return 0;
   return (g_pos.dir > 0) ? (Bid() - g_pos.entry) / g_pos.dist : (g_pos.entry - Ask()) / g_pos.dist;
  }

// Modifie le SL seulement s'il se rapproche (et respecte stops/freeze level)
bool TightenSL(double newSL, string tag)
  {
   if(!PositionSelectByTicket(g_pos.ticket))
      return false;
   newSL = NormPrice(newSL);
   double cur = PositionGetDouble(POSITION_SL);
   double tp  = PositionGetDouble(POSITION_TP);
   double ts  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0)
      ts = _Point;
   if(cur > 0)
     {
      if(g_pos.dir > 0 && newSL <= cur + ts * 0.5)
         return true;   // deja aussi serre : rien a faire
      if(g_pos.dir < 0 && newSL >= cur - ts * 0.5)
         return true;
     }
   long lvl = MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   double minGap = lvl * _Point;
   if(g_pos.dir > 0 && Bid() - newSL < minGap + ts)
      return false;
   if(g_pos.dir < 0 && newSL - Ask() < minGap + ts)
      return false;
   if(!g_trade.PositionModify(g_pos.ticket, newSL, tp))
      return false;
   uint rc = g_trade.ResultRetcode();
   if(rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_NO_CHANGES)
      return false;
   if(InpVerbose)
      PrintFormat("[VM22] %s : SL %s -> %s", tag, FP(cur), FP(newSL));
   return true;
  }

// Ferme pct % du volume INITIAL si le reliquat reste >= lot minimum
bool ClosePartialPct(double pct, string tag)
  {
   if(!PositionSelectByTicket(g_pos.ticket))
      return false;
   double vol  = PositionGetDouble(POSITION_VOLUME);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double v    = NormVolDown(g_pos.initVol * pct / 100.0);
   if(v < vmin - 1e-9 || vol - v < vmin - 1e-9)
     {
      LogDecision(tag, g_pos.dir, -1, 0, 0, -1, "",
                  StringFormat("partiel %.0f%% impossible (volume %.2f, lot min %.2f) : palier franchi sans fermeture",
                               pct, vol, vmin));
      return false;
     }
   if(!g_trade.PositionClosePartial(g_pos.ticket, v))
     {
      PrintFormat("[VM22] %s : fermeture partielle refusee (%u %s)", tag, g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return false;
     }
   g_realizedDirty = true;
   LogDecision(tag, g_pos.dir, -1, 0, 0, -1, "",
               StringFormat("ferme %.2f lot (%.0f%% du volume initial) a %s R", v, pct, F2(CurrentR())));
   return true;
  }

void ClosePositionNow(string reason)
  {
   if(!g_pos.active || !PositionSelectByTicket(g_pos.ticket))
      return;
   g_pos.closeReason = reason;
   if(!g_trade.PositionClose(g_pos.ticket))
      PrintFormat("[VM22] fermeture %s refusee (%u %s)", reason, g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
   else
      LogDecision("SORTIE_FORCEE", g_pos.dir, -1, 0, 0, -1, "", reason + " a " + F2(CurrentR()) + " R");
   g_realizedDirty = true;
  }

// P&L du jour pour ce magic : realise (historique depuis 17:00 NY) + latent
double DayPnL()
  {
   datetime now = TimeCurrent();
   if(g_realizedDirty || now - g_realizedAt >= 5)
     {
      double sum = 0;
      if(HistorySelect(g_day.startServer, now + 60))
        {
         int nd = HistoryDealsTotal();
         for(int k = 0; k < nd; k++)
           {
            ulong d = HistoryDealGetTicket(k);
            if(d == 0)
               continue;
            if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol || (ulong)HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic)
               continue;
            sum += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
                   HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
           }
        }
      g_realizedCache = sum;
      g_realizedAt = now;
      g_realizedDirty = false;
     }
   double flt = 0;
   for(int k = PositionsTotal() - 1; k >= 0; k--)
     {
      ulong t = PositionGetTicket(k);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      flt += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return g_realizedCache + flt;
  }

void CheckDailyLoss()
  {
   if(g_day.startBal <= 0)
      return;
   double pnl = DayPnL();
   double limit = -g_day.startBal * InpDailyLossPct / 100.0;
   if(pnl > limit)
      return;
   if(!g_day.stopped)
     {
      g_day.stopped = true;
      g_day.stopReason = StringFormat("perte journaliere %.2f <= -%.1f%% (%.2f)", pnl, InpDailyLossPct, limit);
      SaveDay();
      LogDecision("STOP_JOUR", 0, -1, 0, 0, -1, "", g_day.stopReason);
      if(g_setup.active)
         DisarmSetup("ANNUL", "limite de perte journaliere");
     }
   if(g_pos.active)
      ClosePositionNow("PERTE_JOUR");
  }

string ExitReasonFromDeal(long reason)
  {
   if(g_pos.closeReason != "")
      return g_pos.closeReason;
   switch((int)reason)
     {
      case DEAL_REASON_SL:
         if(g_pos.stage >= 2)
            return "TRAIL_SL";
         if(g_pos.stage == 1)
            return "BE";
         return "SL";
      case DEAL_REASON_TP:     return "TP3";
      case DEAL_REASON_SO:     return "STOP_OUT";
      case DEAL_REASON_CLIENT: return "MANUEL";
      case DEAL_REASON_MOBILE: return "MANUEL";
      case DEAL_REASON_WEB:    return "MANUEL";
      case DEAL_REASON_EXPERT: return "EXPERT";
     }
   return "AUTRE";
  }

string TradeHeader()
  {
   return "ouverture_ny;fermeture_ny;sens;zone_fvg;confirmations;local;superieur;global;M1;M5;M15;M30;H1;H4;"
          "entree;sl;sl_dist_pts;tp1;tp2;tp3;source_tp3;lot;risque;spread;paliers;mfe_r;mae_r;"
          "profit;profit_r;sortie;ticket";
  }

// La position n'existe plus : bilan depuis l'historique, CSV, compteurs du jour
void FinalizeTrade()
  {
   if(!HistorySelectByPosition(g_pos.ident))
     {
      g_pos.finalizeTries++;
      if(g_pos.finalizeTries < 50)
         return;
     }
   double profit = 0;
   datetime ct = 0;
   long reason = -1;
   bool outFound = false;
   int nd = HistoryDealsTotal();
   for(int k = 0; k < nd; k++)
     {
      ulong d = HistoryDealGetTicket(k);
      if(d == 0 || (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID) != g_pos.ident)
         continue;
      profit += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
                HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
      long en = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(en == DEAL_ENTRY_OUT || en == DEAL_ENTRY_OUT_BY || en == DEAL_ENTRY_INOUT)
        {
         datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         if(t >= ct)
           {
            ct = t;
            reason = HistoryDealGetInteger(d, DEAL_REASON);
            outFound = true;
           }
        }
     }
   if(!outFound)
     {
      g_pos.finalizeTries++;
      if(g_pos.finalizeTries < 50)
         return;   // historique pas encore disponible : on reessaie au tick suivant
      LogDecision("SORTIE", g_pos.dir, -1, 0, 0, -1, "", "position " + IntegerToString((long)g_pos.ticket) +
                  " disparue sans historique de cloture : aucune ligne de trade ecrite");
      ResetPos();
      ClearPosPersist();
      return;
     }
   double r = (g_pos.riskMoney > 0) ? profit / g_pos.riskMoney : 0;
   string exitR = ExitReasonFromDeal(reason);

   g_day.pnl  += profit;
   g_day.sumR += r;
   if(profit > 0)
     {
      g_day.wins++;
      g_day.consec = 0;
     }
   else if(profit < 0)
     {
      g_day.losses++;
      g_day.consec++;
      if(g_day.consec >= InpMaxConsecLoss && !g_day.stopped)
        {
         g_day.stopped = true;
         g_day.stopReason = StringFormat("%d pertes consecutives", g_day.consec);
         LogDecision("STOP_JOUR", 0, -1, 0, 0, -1, "", g_day.stopReason);
        }
     }
   SaveDay();
   g_realizedDirty = true;

   string paliers = (g_pos.stage == 0) ? "aucun" : (g_pos.stage == 1 ? "TP1" : "TP1+TP2");
   if(exitR == "TP3")
      paliers += "+TP3";
   string line = TimeToString(ServerToNY(g_pos.openTime), TIME_DATE | TIME_SECONDS) + ";" +
                 TimeToString(ServerToNY(ct), TIME_DATE | TIME_SECONDS) + ";" +
                 DirStr(g_pos.dir) + ";" + CsvSafe(g_pos.fvg) + ";" + CsvSafe(g_pos.confs) + ";" +
                 F1(g_pos.sLocal) + ";" + F1(g_pos.sSup) + ";" + F1(g_pos.sGlobal);
   for(int i = 0; i < NTF; i++)
      line += ";" + F1(g_pos.sTF[i]);
   line += ";" + FP(g_pos.entry) + ";" + FP(g_pos.sl0) + ";" + F2(g_pos.dist / InpIndexPoint) + ";" +
           FP(g_pos.tp1) + ";" + FP(g_pos.tp2) + ";" + FP(g_pos.tp3) + ";" + CsvSafe(g_pos.tp3src) + ";" +
           DoubleToString(g_pos.initVol, VolDigits()) + ";" + F2(g_pos.riskMoney) + ";" + F2(g_pos.spread) + ";" +
           paliers + ";" + F2(g_pos.mfe) + ";" + F2(g_pos.mae) + ";" +
           F2(profit) + ";" + F2(r) + ";" + exitR + ";" + IntegerToString((long)g_pos.ticket);
   AppendCSV(g_fileTrades, TradeHeader(), line);
   LogDecision("SORTIE", g_pos.dir, -1, 0, 0, -1, g_pos.confs,
               StringFormat("%s : profit %.2f (%s R), MFE %s R, MAE %s R, paliers %s",
                            exitR, profit, F2(r), F2(g_pos.mfe), F2(g_pos.mae), paliers));
   ResetPos();
   ClearPosPersist();
  }

void ManagePosition()
  {
   if(!g_pos.active)
      return;
   if(!PositionSelectByTicket(g_pos.ticket))
     {
      FinalizeTrade();
      return;
     }
   double r = CurrentR();
   bool dirty = false;
   if(r > g_pos.mfe) { g_pos.mfe = r; dirty = true; }
   if(r < g_pos.mae) { g_pos.mae = r; dirty = true; }

   datetime ny = ServerToNY(TimeCurrent());
   if(InForceCloseZone(ny))
     {
      ClosePositionNow("FERMETURE_1625");
      return;
     }

   // Palier 1 : 2.2 R -> 30 % + break-even
   if(g_pos.stage == 0 && r >= InpTP1_RR)
     {
      ClosePartialPct(InpTP1_Pct, "TP1");
      g_pos.stage = 1;
      g_pos.bePending = true;
      dirty = true;
     }
   if(g_pos.bePending)
     {
      double be = (g_pos.dir > 0) ? g_pos.entry + IP(InpBE_Offset) : g_pos.entry - IP(InpBE_Offset);
      if(TightenSL(be, "BE"))
        {
         g_pos.bePending = false;
         dirty = true;
         LogDecision("BE", g_pos.dir, -1, 0, 0, -1, "", "SL au break-even " + FP(be));
        }
     }
   // Palier 2 : 3.5 R -> 30 %
   if(g_pos.stage == 1 && r >= InpTP2_RR)
     {
      ClosePartialPct(InpTP2_Pct, "TP2");
      g_pos.stage = 2;
      dirty = true;
     }
   // Trailing apres le 2e palier
   if(g_pos.stage >= 2 && !g_pos.bePending && g_tf[TF_M5].valid)
     {
      double lvl = 0;
      double spread = SpreadPrice();
      if(FindLastPivot(TF_M5, 3, g_pos.dir, g_pos.dir > 0 ? Bid() : Ask(), lvl))
        {
         double ns = (g_pos.dir > 0) ? lvl - IP(InpTrailBuffer) : lvl + IP(InpTrailBuffer) + spread;
         double cur = PositionGetDouble(POSITION_SL);
         bool better = (cur <= 0) || (g_pos.dir > 0 ? NormPrice(ns) > cur : NormPrice(ns) < cur);
         if(better && TightenSL(ns, "TRAIL"))
            LogDecision("TRAIL", g_pos.dir, -1, 0, 0, -1, "", "SL suiveur pivot M5 L3 -> " + FP(NormPrice(ns)));
        }
     }
   if(dirty)
      SavePos();
  }

// Restaure la position apres un redemarrage (GlobalVariables), ou adopte une position orpheline
void RestorePosition()
  {
   ResetPos();
   ulong t = (ulong)GVG("p_ticket", 0);
   if(t > 0)
     {
      g_pos.active    = true;
      g_pos.ticket    = t;
      g_pos.ident     = (ulong)GVG("p_ident", 0);
      g_pos.dir       = (int)GVG("p_dir", 0);
      g_pos.entry     = GVG("p_entry", 0);
      g_pos.sl0       = GVG("p_sl0", 0);
      g_pos.dist      = GVG("p_dist", 0);
      g_pos.initVol   = GVG("p_vol", 0);
      g_pos.stage     = (int)GVG("p_stage", 0);
      g_pos.bePending = (GVG("p_be", 0) > 0.5);
      g_pos.mfe       = GVG("p_mfe", 0);
      g_pos.mae       = GVG("p_mae", 0);
      g_pos.tp1       = GVG("p_tp1", 0);
      g_pos.tp2       = GVG("p_tp2", 0);
      g_pos.tp3       = GVG("p_tp3", 0);
      g_pos.riskMoney = GVG("p_risk", 0);
      g_pos.openTime  = (datetime)GVG("p_open", 0);
      g_pos.sLocal    = GVG("p_sloc", 0);
      g_pos.sSup      = GVG("p_ssup", 0);
      g_pos.sGlobal   = GVG("p_sglo", 0);
      g_pos.spread    = GVG("p_spr", 0);
      for(int i = 0; i < NTF; i++)
         g_pos.sTF[i] = GVG("p_s" + g_tfName[i], 0);
      LoadCtx();
      if(g_pos.ident == 0)
         g_pos.ident = t;
      PrintFormat("[VM22] position restauree : ticket %I64u %s palier %d (fermeture detectee au prochain tick si elle n'existe plus)",
                  t, DirStr(g_pos.dir), g_pos.stage);
      return;
     }
   // Position orpheline (aucune trace persistante) : adoption minimale
   for(int k = PositionsTotal() - 1; k >= 0; k--)
     {
      ulong pt = PositionGetTicket(k);
      if(pt == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      g_pos.active  = true;
      g_pos.ticket  = pt;
      g_pos.ident   = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      g_pos.dir     = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      g_pos.entry   = PositionGetDouble(POSITION_PRICE_OPEN);
      g_pos.sl0     = PositionGetDouble(POSITION_SL);
      g_pos.tp3     = PositionGetDouble(POSITION_TP);
      g_pos.initVol = PositionGetDouble(POSITION_VOLUME);
      g_pos.openTime = (datetime)PositionGetInteger(POSITION_TIME);
      g_pos.dist    = (g_pos.sl0 > 0) ? MathAbs(g_pos.entry - g_pos.sl0) : IP(InpSLMin);
      // SL deja du bon cote de l'entree : le premier palier a ete fait
      if(g_pos.sl0 > 0 && ((g_pos.dir > 0 && g_pos.sl0 >= g_pos.entry) || (g_pos.dir < 0 && g_pos.sl0 <= g_pos.entry)))
         g_pos.stage = 1;
      double pr = 0;
      if(g_pos.sl0 > 0 && OrderCalcProfit(g_pos.dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol,
                                          g_pos.initVol, g_pos.entry, g_pos.sl0, pr) && pr < 0)
         g_pos.riskMoney = -pr;
      g_pos.tp1 = NormPrice((g_pos.dir > 0) ? g_pos.entry + InpTP1_RR * g_pos.dist : g_pos.entry - InpTP1_RR * g_pos.dist);
      g_pos.tp2 = NormPrice((g_pos.dir > 0) ? g_pos.entry + InpTP2_RR * g_pos.dist : g_pos.entry - InpTP2_RR * g_pos.dist);
      g_pos.fvg = "adoptee";
      g_pos.confs = "?";
      g_pos.tp3src = "?";
      SavePos();
      SaveCtx();
      PrintFormat("[VM22] position orpheline adoptee : ticket %I64u, palier estime %d", pt, g_pos.stage);
      return;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 11 : JOURNEE DE TRADING                                  |
//+------------------------------------------------------------------+
void CheckDayRollover()
  {
   datetime now = TimeCurrent();
   datetime ny  = ServerToNY(now);
   int key = TradingDayKey(ny);
   if(key == g_day.key && g_day.startBal > 0)
      return;
   bool fresh = (g_day.key != 0 && key != g_day.key);
   g_day.key         = key;
   g_day.startBal    = AccountInfoDouble(ACCOUNT_BALANCE);
   g_day.startServer = now - (ny - TradingDayStartNY(ny));
   g_day.trades      = 0;
   g_day.wins        = 0;
   g_day.losses      = 0;
   g_day.consec      = 0;
   g_day.sumR        = 0;
   g_day.pnl         = 0;
   g_day.stopped     = false;
   g_day.stopReason  = "";
   g_realizedDirty   = true;
   SaveDay();
   if(g_setup.active)
      DisarmSetup("EXPIRE", "nouvelle journee de trading");
   if(fresh && InpVerbose)
      PrintFormat("[VM22] nouvelle journee de trading %d (balance de depart %.2f)", key, g_day.startBal);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 12 : TABLEAU DE BORD                                     |
//+------------------------------------------------------------------+
color ScoreColor(double s, double strong)
  {
   if(s >= strong)          return clrLime;
   if(s >= InpContMinGlobal) return clrMediumSeaGreen;
   if(s <= -strong)         return clrRed;
   if(s <= -InpContMinGlobal) return clrTomato;
   return clrSilver;
  }

void DashText(string id, int x, int y, string text, color clr)
  {
   string nm = DASH_PREFIX + id;
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, InpDashFontSize);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, nm, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, nm, OBJPROP_TEXT, text);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
  }

void DashBackground(int w, int h)
  {
   string nm = DASH_PREFIX + "bg";
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_BGCOLOR, C'18,22,30');
      ObjectSetInteger(0, nm, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, C'70,80,100');
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, nm, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, InpDashX);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, InpDashY);
   ObjectSetInteger(0, nm, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, nm, OBJPROP_YSIZE, h);
  }

string Trunc(string s, int n)
  {
   return (StringLen(s) <= n) ? s : StringSubstr(s, 0, n - 3) + "...";
  }

void UpdateDashboard()
  {
   if(!DashOn())
      return;
   int lh = (int)MathRound(InpDashFontSize * 1.75);
   int x  = InpDashX + 8;
   int y  = InpDashY + 6;
   int cw = (int)MathRound(InpDashFontSize * 0.75);   // largeur approx. d'un caractere
   int row = 0;
   datetime ny = ServerToNY(TimeCurrent());

   DashText("title", x, y + lh * row++, "V MODEL v2.2 Hardened - Continuation   [" +
            (InpTradeEnabled ? "TRADING ACTIF" : "SIGNAUX SEULEMENT") + "]   " + _Symbol,
            InpTradeEnabled ? clrOrange : clrDeepSkyBlue);
   DashText("time", x, y + lh * row++, "NY " + NYStr(ny, true) + "   Session : " + SessionName(ny),
            InEntryWindow(ny) ? clrLime : clrSilver);

   // Scores agreges (trois couleurs)
   string sl = "Local " + SG(g_local), ss = "Sup " + SG(g_sup), sg = "Global " + SG(g_global);
   DashText("sl", x, y + lh * row, sl, ScoreColor(g_local, InpLocalStrong));
   DashText("ss", x + cw * 16, y + lh * row, ss, ScoreColor(g_sup, InpHTFStrong));
   DashText("sg", x + cw * 30, y + lh * row, sg, ScoreColor(g_global, InpLocalStrong));
   DashText("sv", x + cw * 46, y + lh * row, g_scoresValid ? " " : "(donnees incompletes)", clrOrange);
   row++;

   // Six timeframes, deux lignes de trois
   for(int i = 0; i < NTF; i++)
     {
      int r = row + i / 3;
      int c = i % 3;
      string t = StringFormat("%-3s %s %s", g_tfName[i], SG(g_tf[i].score),
                              g_tf[i].valid ? g_tf[i].state : "n/d");
      double strong = (i >= TF_M30) ? InpHTFStrong : InpLocalStrong;
      DashText("tf" + IntegerToString(i), x + c * cw * 25, y + lh * r, t, ScoreColor(g_tf[i].score, strong));
     }
   row += 2;

   // Setup
   string st;
   color sc = clrSilver;
   if(g_setup.active)
     {
      st = StringFormat("Setup ARME : OUI  %s %s  conf %d/%d  expire %s NY",
                        DirStr(g_setup.dir), FvgDesc(g_setup.tf, g_setup.dir, g_setup.top, g_setup.bot),
                        g_setup.conf, InpConfNeeded, NYStr(ServerToNY(g_setup.expire)));
      sc = clrGold;
     }
   else
      st = "Setup ARME : NON  (" + g_setupReason + ")";
   DashText("setup", x, y + lh * row++, Trunc(st, 110), sc);
   DashText("dec", x, y + lh * row++, Trunc("Derniere decision : " + g_lastDecision, 110), clrWhite);

   // Position
   string ps;
   color pc = clrSilver;
   if(g_pos.active && PositionSelectByTicket(g_pos.ticket))
     {
      ps = StringFormat("Position : %s %.2f lot @ %s  palier %d  R %s  MFE %s  MAE %s  SL %s",
                        DirStr(g_pos.dir), PositionGetDouble(POSITION_VOLUME), FP(g_pos.entry), g_pos.stage,
                        F2(CurrentR()), F2(g_pos.mfe), F2(g_pos.mae), FP(PositionGetDouble(POSITION_SL)));
      pc = (CurrentR() >= 0) ? clrLime : clrTomato;
     }
   else
      ps = "Position : aucune";
   DashText("pos", x, y + lh * row++, Trunc(ps, 110), pc);

   // Statistiques du jour
   int closed = g_day.wins + g_day.losses;
   double wr = (closed > 0) ? 100.0 * g_day.wins / closed : 0;
   string ds = StringFormat("Jour : trades %d/%d  winrate %.0f%%  R %s  P&L %.2f  pertes consec %d/%d",
                            g_day.trades, InpMaxTradesDay, wr, SG(g_day.sumR), g_day.pnl,
                            g_day.consec, InpMaxConsecLoss);
   DashText("day", x, y + lh * row++, ds, g_day.pnl >= 0 ? clrWhite : clrTomato);
   if(g_day.stopped)
      DashText("stop", x, y + lh * row++, Trunc("JOURNEE BLOQUEE : " + g_day.stopReason, 110), clrRed);
   else
      ObjectDelete(0, DASH_PREFIX + "stop");

   // Spread et FVG actifs
   string fs = StringFormat("Spread %.2f (max %.1f)   FVG actifs : M5 %d  M15 %d  M30 %d  H1 %d  (M1 %d  H4 %d)",
                            SpreadPrice() / InpIndexPoint, InpMaxSpread,
                            CountActiveFVG(TF_M5, 0), CountActiveFVG(TF_M15, 0), CountActiveFVG(TF_M30, 0),
                            CountActiveFVG(TF_H1, 0), CountActiveFVG(TF_M1, 0), CountActiveFVG(TF_H4, 0));
   DashText("fvg", x, y + lh * row++, fs, SpreadPrice() > IP(InpMaxSpread) ? clrOrange : clrSilver);

   DashBackground(cw * 112, lh * row + 10);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| SECTION 13 : EVENEMENTS                                          |
//+------------------------------------------------------------------+
bool CreateHandles()
  {
   for(int i = 0; i < NTF; i++)
     {
      g_hATR[i]  = iATR(_Symbol, g_tfs[i], InpATRPeriod);
      g_hE20[i]  = iMA(_Symbol, g_tfs[i], 20, 0, MODE_EMA, PRICE_CLOSE);
      g_hE50[i]  = iMA(_Symbol, g_tfs[i], 50, 0, MODE_EMA, PRICE_CLOSE);
      g_hE100[i] = iMA(_Symbol, g_tfs[i], 100, 0, MODE_EMA, PRICE_CLOSE);
      g_hE200[i] = iMA(_Symbol, g_tfs[i], 200, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hATR[i] == INVALID_HANDLE || g_hE20[i] == INVALID_HANDLE || g_hE50[i] == INVALID_HANDLE ||
         g_hE100[i] == INVALID_HANDLE || g_hE200[i] == INVALID_HANDLE)
         return false;
     }
   return true;
  }

void ReleaseHandles()
  {
   for(int i = 0; i < NTF; i++)
     {
      if(g_hATR[i]  != INVALID_HANDLE) IndicatorRelease(g_hATR[i]);
      if(g_hE20[i]  != INVALID_HANDLE) IndicatorRelease(g_hE20[i]);
      if(g_hE50[i]  != INVALID_HANDLE) IndicatorRelease(g_hE50[i]);
      if(g_hE100[i] != INVALID_HANDLE) IndicatorRelease(g_hE100[i]);
      if(g_hE200[i] != INVALID_HANDLE) IndicatorRelease(g_hE200[i]);
     }
  }

// Analyse complete a la cloture d'une bougie M5. false si les donnees M5 ne sont pas pretes.
bool OnNewM5Bar()
  {
   for(int i = 0; i < NTF; i++)
      UpdateTF(i);
   if(!g_tf[TF_M5].valid)
      return false;
   if(g_tf[TF_M5].lastBar == g_lastProcM5)
      return true;
   g_lastProcM5 = g_tf[TF_M5].lastBar;
   ComputeAggregates();

   MqlRates b = g_rb[TF_M5].r[0];
   ProcessSetupOnM5(b);     // setup arme sur une bougie precedente
   ProcessFVGsOnM5(b);      // etats des FVG + armement eventuel

   if(InpLogEveryBar)
      LogDecision("ETAT", g_setup.active ? g_setup.dir : 0, -1, 0, 0, -1, g_setup.confTags,
                  g_setup.active ? "setup arme" : g_setupReason);
   return true;
  }

int OnInit()
  {
   g_fileTrades    = InpFilePrefix + "_trades.csv";
   g_fileDecisions = InpFilePrefix + "_decisions.csv";
   g_fileCtx       = InpFilePrefix + "_ctx_" + IntegerToString((long)InpMagic) + ".txt";

   for(int i = 0; i < NTF; i++)
     {
      ResetTF(i);
      g_hATR[i] = g_hE20[i] = g_hE50[i] = g_hE100[i] = g_hE200[i] = INVALID_HANDLE;
     }
   ArrayResize(g_fvg, 0, 64);
   g_setup.active = false;
   g_setup.confTags = "";
   g_lastM5Open = 0;
   g_lastProcM5 = 0;

   if(!CreateHandles())
     {
      Print("[VM22] echec de creation des indicateurs (EMA/ATR)");
      return INIT_FAILED;
     }
   if(InpTP1_Pct + InpTP2_Pct >= 100.0 || InpTP1_RR >= InpTP2_RR || InpSLMin > InpSLMaxAbs || InpIndexPoint <= 0)
     {
      Print("[VM22] parametres incoherents (TP1/TP2, SLMin/SLMax ou InpIndexPoint)");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviationPts);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetMarginMode();

   if(StringFind(_Symbol, "NAS100") < 0 && StringFind(_Symbol, "US100") < 0 && StringFind(_Symbol, "USTEC") < 0)
      PrintFormat("[VM22] ATTENTION : concu pour NAS100.s, symbole courant %s (tailles en points d'indice a revoir)", _Symbol);
   if(_Period != PERIOD_M5)
      Print("[VM22] graphique recommande : M5 (l'analyse reste faite sur les bougies M5 fermees)");
   if(InpRevOn)
      Print("[VM22] InpRevOn = true IGNORE : le module Retournement n'existe pas dans la v2.2 Hardened");
   if(InpMaxPositions != 1)
      Print("[VM22] InpMaxPositions force a 1 : la gestion suit une seule position");
   if(InpTimeMode == VM_TIME_AUTO && MQLInfoInteger(MQL_TESTER))
      Print("[VM22] mode heure AUTO indisponible en testeur : repli sur le mode ALIGNE");

   RefreshServerOffset();
   // En testeur, aucun etat d'une passe precedente ne doit fuiter dans la suivante
   if(MQLInfoInteger(MQL_TESTER))
      GlobalVariablesDeleteAll(GVN(""));
   LoadDay();
   CheckDayRollover();
   RestorePosition();

   datetime ny = ServerToNY(TimeCurrent());
   PrintFormat("[VM22] V MODEL v2.2 Hardened demarre | %s | magic %I64u | %s | NY %s | DST US %s | risque %.2f%%",
               _Symbol, InpMagic, InpTradeEnabled ? "TRADING ACTIF" : "SIGNAUX SEULEMENT",
               NYStr(ny, true), IsUsDst(ny + 5 * 3600) ? "oui" : "non", InpRiskPct);
   if(LogsOn())
      PrintFormat("[VM22] journaux : Common\\Files\\%s et %s", g_fileTrades, g_fileDecisions);

   EventSetTimer(1);
   UpdateDashboard();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   SavePos();
   SaveDay();
   ReleaseHandles();
   ObjectsDeleteAll(0, DASH_PREFIX);
   ChartRedraw(0);
  }

void OnTick()
  {
   RefreshServerOffset();
   CheckDayRollover();
   ManagePosition();
   CheckDailyLoss();

   datetime m5 = iTime(_Symbol, PERIOD_M5, 0);
   if(m5 > 0 && m5 != g_lastM5Open)
     {
      if(OnNewM5Bar())
         g_lastM5Open = m5;
     }

   uint ms = GetTickCount();
   if(ms - g_lastDashMs >= 500)
     {
      g_lastDashMs = ms;
      UpdateDashboard();
     }
  }

void OnTimer()
  {
   RefreshServerOffset();
   UpdateDashboard();
  }
//+------------------------------------------------------------------+
