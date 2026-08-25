//+------------------------------------------------------------------+
//|                                             Microstructure.mqh   |
//|        Queu - lecture micro du marche a partir du flux de cotes  |
//|                                                                  |
//|  AVERTISSEMENT DE NOMMAGE, a lire avant d'utiliser ce module.    |
//|                                                                  |
//|  Sur un compte CFD retail, les ticks recus sont des mises a jour |
//|  de COTATION, pas des transactions avec sens d'agresseur. Il n'y |
//|  a donc NI delta, NI volume echange. Tout ce qui est calcule ici |
//|  est un PROXY, et porte un nom qui le dit :                      |
//|                                                                  |
//|    quotePressure  n'est PAS le delta. C'est la regle du tick     |
//|                   appliquee au mid : +1 si le mid monte, -1 s'il |
//|                   descend. Cela mesure la direction des cotes,   |
//|                   pas le sens des agresseurs.                    |
//|                                                                  |
//|    absorption     n'est PAS l'absorption au sens carnet. C'est   |
//|                   une pression de cotation fortement orientee    |
//|                   qui ne produit PAS de deplacement de prix.     |
//|                   L'inference est raisonnable, la mesure reste   |
//|                   indirecte.                                      |
//|                                                                  |
//|  Executer MQL5/Scripts/Queu/QueuBrokerAudit.mq5 pour savoir si   |
//|  le flux du broker permet mieux que ces proxys.                  |
//|                                                                  |
//|  Cout : tout est maintenu de facon incrementale a chaque tick.   |
//|  Aucun appel a CopyTicks en boucle, aucun tri par tick.          |
//+------------------------------------------------------------------+
#property copyright "Queu"

#ifndef QUEU_MICROSTRUCTURE_MQH
#define QUEU_MICROSTRUCTURE_MQH

//+------------------------------------------------------------------+
//| Photographie de l'etat micro sur la fenetre glissante.            |
//+------------------------------------------------------------------+
struct QMicroState
  {
   bool              valid;
   int               ticks;         // ticks dans la fenetre
   double            tickRate;      // ticks par seconde
   double            spreadNow;     // points
   double            spreadBase;    // reference lissee, points
   double            spreadRatio;   // spreadNow / spreadBase
   double            quotePressure; // regle du tick sur le mid, [-1, 1]
   double            displacement;  // deplacement net, points signes
   double            pathLength;    // chemin parcouru, points
   double            efficiency;    // |displacement| / pathLength, [0, 1]
   double            absorption;    // [0, 1], voir avertissement en tete
   double            flicker;       // taux d'inversions de sens, [0, 1]
   double            toxicity;      // [0, 1], pire des composantes
   long              maxGapMsc;     // plus long silence dans la fenetre
  };

//+------------------------------------------------------------------+
//| Bande glissante de ticks, a cout constant par tick.               |
//+------------------------------------------------------------------+
class CQMicroTape
  {
private:
   string            m_sym;
   long              m_windowMsc;
   int               m_cap;

   //--- tampon circulaire
   double            m_mid[];
   double            m_spread[];
   long              m_msc[];
   double            m_absMove[];   // |variation du mid| en points
   double            m_signMove[];  // -1, 0, +1
   long              m_gap[];       // ecart avec le tick precedent
   double            m_isRev[];     // 1 si ce tick inverse le sens, sinon 0
   int               m_head;        // prochain emplacement d'ecriture
   int               m_count;

   //--- sommes entretenues au fil de l'eau
   double            m_sumAbs;
   double            m_sumSign;
   double            m_reversals;   // somme glissante, DECREMENTEE a l'expiration
   long              m_maxGap;
   bool              m_maxGapDirty;

   double            m_spreadEma;
   double            m_emaAlpha;
   double            m_point;
   long              m_lastMsc;
   double            m_lastMid;
   double            m_lastSign;

   int               Idx(const int back) const
     {
      //--- back = 0 : le plus recent
      int i = m_head - 1 - back;
      while(i < 0)
         i += m_cap;
      return i % m_cap;
     }

   void              Expire(const long nowMsc)
     {
      while(m_count > 0)
        {
         int oldest = Idx(m_count - 1);
         if(nowMsc - m_msc[oldest] <= m_windowMsc)
            break;

         m_sumAbs    -= m_absMove[oldest];
         m_sumSign   -= m_signMove[oldest];
         m_reversals -= m_isRev[oldest];
         if(m_gap[oldest] == m_maxGap)
            m_maxGapDirty = true;

         m_count--;
        }
     }

   void              RecomputeMaxGap(void)
     {
      m_maxGap = 0;
      for(int b = 0; b < m_count; b++)
        {
         long g = m_gap[Idx(b)];
         if(g > m_maxGap)
            m_maxGap = g;
        }
      m_maxGapDirty = false;
     }

public:
                     CQMicroTape(): m_windowMsc(60000), m_cap(0), m_head(0), m_count(0),
                                    m_sumAbs(0.0), m_sumSign(0.0), m_reversals(0.0),
                                    m_maxGap(0), m_maxGapDirty(false),
                                    m_spreadEma(0.0), m_emaAlpha(0.01), m_point(0.0),
                                    m_lastMsc(0), m_lastMid(0.0), m_lastSign(0.0) {}

   bool              Init(const string sym, const int windowSeconds,
                          const int capacity, const int spreadEmaTicks)
     {
      m_sym       = sym;
      m_windowMsc = (long)MathMax(1, windowSeconds) * 1000;
      m_cap       = (int)MathMax(64, capacity);
      m_point     = SymbolInfoDouble(sym, SYMBOL_POINT);

      if(m_point <= 0.0)
         return false;

      m_emaAlpha = 2.0 / (MathMax(2, spreadEmaTicks) + 1.0);

      ArrayResize(m_mid,      m_cap);
      ArrayResize(m_spread,   m_cap);
      ArrayResize(m_msc,      m_cap);
      ArrayResize(m_absMove,  m_cap);
      ArrayResize(m_signMove, m_cap);
      ArrayResize(m_gap,      m_cap);
      ArrayResize(m_isRev,    m_cap);

      m_head = m_count = 0;
      m_sumAbs = m_sumSign = 0.0;
      m_reversals = 0.0;
      m_maxGap = 0;
      m_maxGapDirty = false;
      m_spreadEma = 0.0;
      m_lastMsc = 0;
      m_lastMid = 0.0;
      m_lastSign = 0.0;

      return true;
     }

   //--- a appeler une fois par tick. Cout constant.
   void              Update(void)
     {
      MqlTick t;
      if(!SymbolInfoTick(m_sym, t))
         return;
      if(t.bid <= 0.0 || t.ask <= 0.0)
         return;
      if(t.time_msc == m_lastMsc)
         return;                       // deja enregistre

      double mid    = (t.bid + t.ask) / 2.0;
      double spread = (t.ask - t.bid) / m_point;
      long   gap    = (m_lastMsc > 0) ? (long)(t.time_msc - m_lastMsc) : 0;

      double move = (m_lastMid > 0.0) ? (mid - m_lastMid) / m_point : 0.0;
      double sign = (move > 0.0) ? 1.0 : ((move < 0.0) ? -1.0 : 0.0);

      //--- une inversion de sens signale du va-et-vient sans progression.
      //--- Le drapeau est conserve PAR TICK pour pouvoir etre retire quand
      //--- le tick sort de la fenetre ; sans cela le compteur croit sans
      //--- borne et la toxicite reste bloquee au maximum.
      double isRev = (sign != 0.0 && m_lastSign != 0.0 && sign != m_lastSign) ? 1.0 : 0.0;

      //--- le tampon est plein : la plus ancienne entree sort
      if(m_count == m_cap)
        {
         int oldest = Idx(m_count - 1);
         m_sumAbs    -= m_absMove[oldest];
         m_sumSign   -= m_signMove[oldest];
         m_reversals -= m_isRev[oldest];
         if(m_gap[oldest] == m_maxGap)
            m_maxGapDirty = true;
         m_count--;
        }

      m_mid[m_head]      = mid;
      m_spread[m_head]   = spread;
      m_msc[m_head]      = (long)t.time_msc;
      m_absMove[m_head]  = MathAbs(move);
      m_signMove[m_head] = sign;
      m_gap[m_head]      = gap;
      m_isRev[m_head]    = isRev;

      m_sumAbs    += MathAbs(move);
      m_sumSign   += sign;
      m_reversals += isRev;
      if(gap > m_maxGap)
         m_maxGap = gap;

      m_head = (m_head + 1) % m_cap;
      m_count++;

      m_spreadEma = (m_spreadEma <= 0.0) ? spread
                    : m_spreadEma + m_emaAlpha * (spread - m_spreadEma);

      m_lastMsc  = (long)t.time_msc;
      m_lastMid  = mid;
      if(sign != 0.0)
         m_lastSign = sign;

      Expire((long)t.time_msc);
      if(m_maxGapDirty)
         RecomputeMaxGap();
     }

   int               Count(void) const { return m_count; }

   //+---------------------------------------------------------------+
   //| Etat courant. minTicks evite de statuer sur trop peu de donnees.|
   //+---------------------------------------------------------------+
   bool              State(QMicroState &out, const int minTicks,
                           const double toxSpreadRatio, const long toxGapMsc) const
     {
      out.valid = false;
      if(m_count < MathMax(3, minTicks))
         return false;

      int newest = Idx(0);
      int oldest = Idx(m_count - 1);

      double spanSec = (double)(m_msc[newest] - m_msc[oldest]) / 1000.0;
      if(spanSec <= 0.0)
         return false;

      out.ticks        = m_count;
      out.tickRate     = m_count / spanSec;
      out.spreadNow    = m_spread[newest];
      out.spreadBase   = (m_spreadEma > 0.0) ? m_spreadEma : m_spread[newest];
      out.spreadRatio  = (out.spreadBase > 0.0) ? out.spreadNow / out.spreadBase : 1.0;
      out.displacement = (m_mid[newest] - m_mid[oldest]) / m_point;
      out.pathLength   = m_sumAbs;
      out.maxGapMsc    = m_maxGap;

      out.quotePressure = m_sumSign / (double)m_count;
      if(out.quotePressure > 1.0)  out.quotePressure = 1.0;
      if(out.quotePressure < -1.0) out.quotePressure = -1.0;

      out.efficiency = (out.pathLength > 0.0)
                       ? MathMin(1.0, MathAbs(out.displacement) / out.pathLength)
                       : 0.0;

      //--- pression orientee QUI NE FAIT PAS AVANCER LE PRIX : quelque chose
      //--- encaisse. Inference indirecte, voir l'avertissement en tete.
      out.absorption = MathAbs(out.quotePressure) * (1.0 - out.efficiency);

      //--- une marche aleatoire inverse environ une fois sur deux ; au-dela
      //--- c'est du va-et-vient sans progression
      out.flicker = (m_count > 1) ? m_reversals / (double)(m_count - 1) : 0.0;
      if(out.flicker > 1.0)
         out.flicker = 1.0;

      //--- Toxicite = la PIRE des composantes, pas leur moyenne. C'est un
      //--- score de veto : une seule condition severe doit suffire a bloquer,
      //--- une moyenne la diluerait.
      double cSpread = 0.0;
      if(toxSpreadRatio > 1.0)
         cSpread = (out.spreadRatio - 1.0) / (toxSpreadRatio - 1.0);

      double cGap = 0.0;
      if(toxGapMsc > 0)
         cGap = (double)out.maxGapMsc / (double)toxGapMsc;

      //--- au-dela de 0.5 d'inversions on est en regime de bruit
      double cFlick = (out.flicker - 0.5) / 0.5;

      double worst = MathMax(cSpread, MathMax(cGap, cFlick));
      out.toxicity = MathMax(0.0, MathMin(1.0, worst));

      out.valid = true;
      return true;
     }

   //+---------------------------------------------------------------+
   //| Extremes du mid sur la fenetre, en prix.                       |
   //|                                                                |
   //| Balayage lineaire assume : cette methode n'est appelee QUE lors |
   //| de la formation d'un candidat, evenement rare, jamais a chaque  |
   //| tick. Maintenir un minimum et un maximum glissants exacts       |
   //| exigerait deux deques monotones pour un gain nul ici.           |
   //+---------------------------------------------------------------+
   bool              Extremes(double &lo, double &hi) const
     {
      if(m_count < 2)
         return false;

      lo = hi = m_mid[Idx(0)];
      for(int b = 1; b < m_count; b++)
        {
         double v = m_mid[Idx(b)];
         if(v < lo) lo = v;
         if(v > hi) hi = v;
        }
      return true;
     }
  };

#endif // QUEU_MICROSTRUCTURE_MQH
