//+------------------------------------------------------------------+
//|                                                      Journal.mqh |
//|      Queu - journal de trades exploitable hors MetaTrader        |
//|                                                                  |
//|  Enregistre pour chaque trade le contexte de marche au moment    |
//|  de l'entree (ATR, ratio d'efficience, ADX, spread, heure) et    |
//|  son resultat en multiples de R, MAE et MFE incluses.            |
//|                                                                  |
//|  C'est ce fichier qui permet de repondre a la seule question qui |
//|  compte pour ameliorer le rendement : OU se trouve reellement    |
//|  l'edge, et ou est-on en train de payer pour rien.               |
//+------------------------------------------------------------------+
#property copyright "Queu"

#ifndef QUEU_JOURNAL_MQH
#define QUEU_JOURNAL_MQH

//+------------------------------------------------------------------+
//| Contexte conserve entre l'ouverture et la cloture d'une position. |
//+------------------------------------------------------------------+
struct QTradeCtx
  {
   ulong             ticket;
   datetime          openTime;
   int               dir;          // +1 achat, -1 vente
   double            volume;
   double            entry;
   double            sl;
   double            tp;
   double            riskPrice;    // |entree - stop| initial : l'unite de R
   double            atr;
   double            er;           // ratio d'efficience de Kaufman
   double            adx;
   double            regSlopeATR;  // pente normalisee de l'echelon long
   double            regR2;        // qualite de tendance de l'echelon long
   double            spreadPts;
   double            mfe;          // excursion favorable max, en prix
   double            mae;          // excursion adverse max, en prix
   double            riskPct;      // risque engage, en % d'equity
   double            riskMoney;    // 1 R exprime en devise du compte
   double            pnlAccum;     // P&L cumule, cloture partielle comprise
   bool              partialDone;  // prise de profit partielle deja effectuee
  };

//+------------------------------------------------------------------+
//| Journal CSV. Ecrit dans le dossier commun des terminaux pour que  |
//| les agents du testeur convergent vers un seul fichier.            |
//+------------------------------------------------------------------+
class CQJournal
  {
private:
   QTradeCtx         m_ctx[];
   string            m_file;
   bool              m_writeCsv;

   int               Find(const ulong ticket) const
     {
      for(int i = ArraySize(m_ctx) - 1; i >= 0; i--)
         if(m_ctx[i].ticket == ticket)
            return i;
      return -1;
     }

   void              WriteHeaderIfNeeded(void)
     {
      int h = FileOpen(m_file, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
      if(h == INVALID_HANDLE)
        {
         PrintFormat("[Queu] Ecriture du journal desactivee : ouverture de %s impossible (%d).",
                     m_file, GetLastError());
         m_writeCsv = false;
         return;
        }

      if(FileSize(h) == 0)
         FileWrite(h,
                   "ticket", "open_time", "close_time", "dir", "volume",
                   "entry", "exit", "sl", "tp",
                   "risk_price", "risk_pct", "r_multiple", "pnl_money",
                   "mfe_r", "mae_r",
                   "atr", "efficiency_ratio", "adx",
                   "reg_slope_atr", "reg_r2", "spread_pts",
                   "hour", "day_of_week", "hold_seconds");

      FileClose(h);
     }

public:
                     CQJournal(): m_file(""), m_writeCsv(false) {}

   void              Init(const string filename, const bool enabled)
     {
      m_file     = filename;
      m_writeCsv = enabled;
      ArrayResize(m_ctx, 0);

      if(m_writeCsv)
         WriteHeaderIfNeeded();
     }

   bool              WritesCsv(void) const { return m_writeCsv; }

   //--- a appeler juste apres l'ouverture d'une position
   void              OnOpen(const QTradeCtx &ctx)
     {
      int i = Find(ctx.ticket);
      if(i < 0)
        {
         i = ArraySize(m_ctx);
         ArrayResize(m_ctx, i + 1);
        }
      m_ctx[i] = ctx;
     }

   //--- a appeler a chaque tick : suit les excursions extremes
   void              Track(const ulong ticket, const double price)
     {
      int i = Find(ticket);
      if(i < 0)
         return;

      double move = (m_ctx[i].dir > 0) ? (price - m_ctx[i].entry)
                                       : (m_ctx[i].entry - price);

      if(move > m_ctx[i].mfe)
         m_ctx[i].mfe = move;
      if(move < m_ctx[i].mae)
         m_ctx[i].mae = move;
     }

   //--- cumule le P&L d'une cloture (totale ou partielle) sur la position
   void              AddPnL(const ulong ticket, const double pnl)
     {
      int i = Find(ticket);
      if(i >= 0)
         m_ctx[i].pnlAccum += pnl;
     }

   //--- resultat de la position en multiples de R, calcule sur l'argent
   //--- pour rester juste en presence de clotures partielles
   bool              RealizedR(const ulong ticket, double &r) const
     {
      r = 0.0;
      int i = Find(ticket);
      if(i < 0 || m_ctx[i].riskMoney <= 0.0)
         return false;

      r = m_ctx[i].pnlAccum / m_ctx[i].riskMoney;
      return true;
     }

   //--- risque initial de la position, en prix : l'unite de R
   bool              InitialRisk(const ulong ticket, double &risk) const
     {
      risk = 0.0;
      int i = Find(ticket);
      if(i < 0 || m_ctx[i].riskPrice <= 0.0)
         return false;

      risk = m_ctx[i].riskPrice;
      return true;
     }

   bool              PartialDone(const ulong ticket) const
     {
      int i = Find(ticket);
      return (i >= 0 && m_ctx[i].partialDone);
     }

   void              SetPartialDone(const ulong ticket)
     {
      int i = Find(ticket);
      if(i >= 0)
         m_ctx[i].partialDone = true;
     }

   //--- a appeler a la cloture ; 'drop' retire le contexte du suivi
   void              OnClose(const ulong ticket, const datetime closeTime,
                             const double closePrice, const double pnlMoney,
                             const bool drop)
     {
      int i = Find(ticket);
      if(i < 0)
         return;

      double risk = m_ctx[i].riskPrice;
      if(risk <= 0.0)
         risk = 1.0;                       // evite une division par zero

      double move = (m_ctx[i].dir > 0) ? (closePrice - m_ctx[i].entry)
                                       : (m_ctx[i].entry - closePrice);

      MqlDateTime dt;
      TimeToStruct(m_ctx[i].openTime, dt);

      int h = m_writeCsv
              ? FileOpen(m_file, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',')
              : INVALID_HANDLE;
      if(h != INVALID_HANDLE)
        {
         FileSeek(h, 0, SEEK_END);
         FileWrite(h,
                   (string)ticket,
                   TimeToString(m_ctx[i].openTime, TIME_DATE | TIME_SECONDS),
                   TimeToString(closeTime, TIME_DATE | TIME_SECONDS),
                   (m_ctx[i].dir > 0 ? "BUY" : "SELL"),
                   DoubleToString(m_ctx[i].volume, 2),
                   DoubleToString(m_ctx[i].entry, _Digits),
                   DoubleToString(closePrice, _Digits),
                   DoubleToString(m_ctx[i].sl, _Digits),
                   DoubleToString(m_ctx[i].tp, _Digits),
                   DoubleToString(risk, _Digits),
                   DoubleToString(m_ctx[i].riskPct, 4),
                   DoubleToString(move / risk, 4),
                   DoubleToString(pnlMoney, 2),
                   DoubleToString(m_ctx[i].mfe / risk, 4),
                   DoubleToString(m_ctx[i].mae / risk, 4),
                   DoubleToString(m_ctx[i].atr, _Digits),
                   DoubleToString(m_ctx[i].er, 4),
                   DoubleToString(m_ctx[i].adx, 2),
                   DoubleToString(m_ctx[i].regSlopeATR, 4),
                   DoubleToString(m_ctx[i].regR2, 4),
                   DoubleToString(m_ctx[i].spreadPts, 1),
                   (string)dt.hour,
                   (string)dt.day_of_week,
                   (string)(long)(closeTime - m_ctx[i].openTime));
         FileClose(h);
        }

      if(drop)
        {
         int last = ArraySize(m_ctx) - 1;
         if(i != last)
            m_ctx[i] = m_ctx[last];
         ArrayResize(m_ctx, last);
        }
     }
  };

#endif // QUEU_JOURNAL_MQH
