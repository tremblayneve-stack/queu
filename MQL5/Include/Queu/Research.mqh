//+------------------------------------------------------------------+
//|                                                     Research.mqh |
//|      Queu - journal de RECHERCHE : candidats, pas seulement       |
//|             les trades pris                                       |
//|                                                                  |
//|  Un journal de trades ne contient que les signaux ayant survecu  |
//|  aux filtres. Impossible d'y mesurer si un veto aide ou nuit :   |
//|  on n'observe que ses survivants. Ce module enregistre CHAQUE     |
//|  candidat, pris ou rejete, avec ses features, le masque des veto |
//|  qui l'ont bloque, et son resultat force par triple barriere.     |
//|                                                                  |
//|  Etiquetage par TRIPLE BARRIERE (Lopez de Prado) : pour chaque    |
//|  candidat on pose une barriere haute (cible), une barriere basse  |
//|  (stop) et une barriere temporelle, puis on note laquelle est     |
//|  touchee la premiere. C'est l'etiquette qui correspond a la       |
//|  geometrie reelle d'un trade, contrairement a un rendement a      |
//|  horizon fixe.                                                    |
//|                                                                  |
//|  Quand les deux barrieres de prix sont franchies DANS LA MEME     |
//|  bougie, l'ordre est indeterminable : on retient le stop, choix   |
//|  pessimiste, et on marque la ligne comme ambigue pour pouvoir la  |
//|  filtrer a l'analyse.                                             |
//+------------------------------------------------------------------+
#property copyright "Queu"

#ifndef QUEU_RESEARCH_MQH
#define QUEU_RESEARCH_MQH

#define QRES_NFEAT   14
#define QRES_MAXPEND 256

//--- bits du masque de veto
#define QVETO_NONE        0
#define QVETO_TOXICITY    1
#define QVETO_SPREAD      2
#define QVETO_FLICKER     4
#define QVETO_PAIN        8
#define QVETO_TICKRATE    16
#define QVETO_CONTEXT     32
#define QVETO_BREAKEVEN   64
#define QVETO_POSITIONS   128
#define QVETO_SESSION     256

//+------------------------------------------------------------------+
//| Candidat en attente de resolution.                                |
//+------------------------------------------------------------------+
struct QCandidate
  {
   long              id;
   datetime          opened;
   int               dir;          // +1 / -1
   int               kind;         // 1 = absorption fade, 2 = continuation
   double            entry;
   double            stopDist;     // S, en prix : l'unite de R
   double            tpMult;       // k : cible = k * S
   double            upper;
   double            lower;
   int               maxBars;      // barriere temporelle
   int               barsHeld;
   double            mfe;          // en R
   double            mae;          // en R
   bool              taken;        // le trade a-t-il reellement ete ouvert
   int               vetoMask;
   double            f[QRES_NFEAT];
  };

//+------------------------------------------------------------------+
class CQResearch
  {
private:
   QCandidate        m_pend[];
   int               m_count;
   string            m_file;
   bool              m_on;
   long              m_nextId;

   string            Header(void) const
     {
      return "id,time,dir,kind,taken,veto_mask,entry,stop_dist,tp_mult,max_bars,"
             "label,r_multiple,bars_held,mfe_r,mae_r,ambiguous,"
             "quote_pressure,absorption,efficiency,flicker,toxicity,"
             "spread_ratio,spread_pts,tick_rate,max_gap_sec,"
             "r2_fast,slope_fast_atr,r2_slow,slope_slow_atr,pos_slow_channel";
     }

   void              Write(const QCandidate &c, const int label,
                           const double rMultiple, const bool ambiguous)
     {
      if(!m_on)
         return;

      int h = FileOpen(m_file, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
      if(h == INVALID_HANDLE)
         return;

      if(FileSize(h) == 0)
         FileWrite(h, Header());

      FileSeek(h, 0, SEEK_END);
      FileWrite(h,
                (string)c.id,
                TimeToString(c.opened, TIME_DATE | TIME_SECONDS),
                (string)c.dir,
                (string)c.kind,
                (string)(c.taken ? 1 : 0),
                (string)c.vetoMask,
                DoubleToString(c.entry, _Digits),
                DoubleToString(c.stopDist, _Digits),
                DoubleToString(c.tpMult, 3),
                (string)c.maxBars,
                (string)label,
                DoubleToString(rMultiple, 4),
                (string)c.barsHeld,
                DoubleToString(c.mfe, 4),
                DoubleToString(c.mae, 4),
                (string)(ambiguous ? 1 : 0),
                DoubleToString(c.f[0],  5), DoubleToString(c.f[1],  5),
                DoubleToString(c.f[2],  5), DoubleToString(c.f[3],  5),
                DoubleToString(c.f[4],  5), DoubleToString(c.f[5],  5),
                DoubleToString(c.f[6],  2), DoubleToString(c.f[7],  3),
                DoubleToString(c.f[8],  3), DoubleToString(c.f[9],  5),
                DoubleToString(c.f[10], 5), DoubleToString(c.f[11], 5),
                DoubleToString(c.f[12], 5), DoubleToString(c.f[13], 5));
      FileClose(h);
     }

   void              Drop(const int i)
     {
      if(i < 0 || i >= m_count)
         return;
      if(i != m_count - 1)
         m_pend[i] = m_pend[m_count - 1];
      m_count--;
     }

public:
                     CQResearch(): m_count(0), m_file(""), m_on(false), m_nextId(1) {}

   void              Init(const string file, const bool enabled)
     {
      m_file  = file;
      m_on    = enabled;
      m_count = 0;
      m_nextId = 1;
      ArrayResize(m_pend, QRES_MAXPEND);

      if(!m_on)
         return;

      int h = FileOpen(m_file, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
      if(h == INVALID_HANDLE)
        {
         PrintFormat("[Queu] Journal de recherche desactive : %s inaccessible (%d).",
                     m_file, GetLastError());
         m_on = false;
         return;
        }
      if(FileSize(h) == 0)
         FileWrite(h, Header());
      FileClose(h);
     }

   bool              Enabled(void) const { return m_on; }
   int               Pending(void) const { return m_count; }

   //--- enregistre un candidat ; retourne son identifiant, 0 si refuse
   long              Add(QCandidate &c)
     {
      if(!m_on || m_count >= QRES_MAXPEND || c.stopDist <= 0.0)
         return 0;

      c.id       = m_nextId++;
      c.barsHeld = 0;
      c.mfe      = 0.0;
      c.mae      = 0.0;
      c.upper    = (c.dir > 0) ? c.entry + c.tpMult * c.stopDist
                               : c.entry - c.tpMult * c.stopDist;
      c.lower    = (c.dir > 0) ? c.entry - c.stopDist
                               : c.entry + c.stopDist;

      m_pend[m_count] = c;
      m_count++;
      return c.id;
     }

   //--- marque un candidat comme reellement pris
   void              MarkTaken(const long id)
     {
      for(int i = 0; i < m_count; i++)
         if(m_pend[i].id == id)
           {
            m_pend[i].taken = true;
            return;
           }
     }

   //+---------------------------------------------------------------+
   //| A appeler a chaque cloture de bougie, avec le haut et le bas   |
   //| de la bougie qui vient de se fermer.                            |
   //+---------------------------------------------------------------+
   void              ResolveBar(const double barHigh, const double barLow,
                                const double barClose)
     {
      if(!m_on || m_count == 0)
         return;

      for(int i = m_count - 1; i >= 0; i--)
        {
         m_pend[i].barsHeld++;

         double S = m_pend[i].stopDist;
         int    d = m_pend[i].dir;

         //--- excursions extremes, exprimees en R
         double favor = (d > 0) ? (barHigh - m_pend[i].entry) : (m_pend[i].entry - barLow);
         double advers = (d > 0) ? (barLow - m_pend[i].entry) : (m_pend[i].entry - barHigh);
         if(favor / S > m_pend[i].mfe)
            m_pend[i].mfe = favor / S;
         if(advers / S < m_pend[i].mae)
            m_pend[i].mae = advers / S;

         bool hitUp   = (barHigh >= m_pend[i].upper && d > 0) || (barLow <= m_pend[i].upper && d < 0);
         bool hitDown = (barLow <= m_pend[i].lower && d > 0) || (barHigh >= m_pend[i].lower && d < 0);

         if(hitUp && hitDown)
           {
            //--- ordre indeterminable dans la bougie : on retient le stop,
            //--- choix pessimiste, et on marque la ligne comme ambigue
            Write(m_pend[i], -1, -1.0, true);
            Drop(i);
            continue;
           }
         if(hitUp)
           {
            Write(m_pend[i], 1, m_pend[i].tpMult, false);
            Drop(i);
            continue;
           }
         if(hitDown)
           {
            Write(m_pend[i], -1, -1.0, false);
            Drop(i);
            continue;
           }

         if(m_pend[i].barsHeld >= m_pend[i].maxBars)
           {
            //--- barriere temporelle : le resultat est le rendement au
            //--- moment de l'expiration, pas zero
            double r = ((barClose - m_pend[i].entry) * d) / S;
            Write(m_pend[i], 0, r, false);
            Drop(i);
           }
        }
     }

   //--- vide les candidats encore ouverts en fin de test
   void              Flush(const double lastClose)
     {
      for(int i = m_count - 1; i >= 0; i--)
        {
         double r = ((lastClose - m_pend[i].entry) * m_pend[i].dir) / m_pend[i].stopDist;
         Write(m_pend[i], 0, r, false);
         Drop(i);
        }
     }
  };

#endif // QUEU_RESEARCH_MQH
