/* ===========================================================================
   multiprogram.jsx — Egy jelentkező, több program  (II/4)

   A kollégák kérése (észrevételek, 8. tétel):
     "A személyhez tartozó lépések — dokumentum-ellenőrzés, matek, interjú —
      egyszer történjenek, a programhoz tartozók programonként."

   Ez a modul a PROGRAM-szintű felét mutatja: a jelölési sorrendet, a
   szakonkénti döntést, a felvételi levelet és a beiratkozást. A személy-
   szintű állapot (dokumentum, matek, interjú) marad ott, ahol eddig volt —
   a jelentkező adatlapján, egyetlen példányban.

   Adatbázis: 32_multi_program.sql
   =========================================================================== */

/* ---------- 1. Hibaszövegek ---------------------------------------------- */
const MP_PGERR = {
  '42501':   'Ehhez a művelethez nincs jogosultsága.',
  'PGRST301':'A munkamenet lejárt. Jelentkezzen be újra.',
  '23503':   'A hivatkozott sor nem létezik (jelentkező vagy program).',
  '23505':   'Erre a szakra már van jelentkezés.',
  '42P01':   'A modul táblái hiányoznak — a 32_multi_program.sql még nem futott le.',
  '42883':   'A modul függvényei hiányoznak — a 32_multi_program.sql még nem futott le.',
  'PGRST205':'A modul táblái hiányoznak — a 32_multi_program.sql még nem futott le.',
  'PGRST202':'A modul függvényei hiányoznak — a 32_multi_program.sql még nem futott le.',
};
const MP_MISSING_RE = /Could not find the (table|function)|schema cache|does not exist/i;

function MP_msg(e) {
  if (!e) return 'Ismeretlen hiba.';
  const raw = String(e.message || e.details || e.hint || e);
  const code = e.code || (e.error && e.error.code);
  /* A szerver saját magyar mondata a legjobb üzenet — ha van, azt adjuk. */
  if (/[őűáéíóöúüÁÉÍÓÖŐÚÜŰ]/.test(raw) && raw.length > 12) return raw;
  if (code && MP_PGERR[code]) return MP_PGERR[code];
  for (const k in MP_PGERR) { if (raw.indexOf(k) >= 0) return MP_PGERR[k]; }
  if (MP_MISSING_RE.test(raw)) {
    return 'A modul még nem érhető el — a 32_multi_program.sql migráció nem futott le.';
  }
  if (/Failed to fetch|NetworkError|network/i.test(raw)) return 'Nincs kapcsolat a kiszolgálóval.';
  return raw || 'Ismeretlen hiba.';
}

/* ---------- 2. Adatelérés ------------------------------------------------- */
async function MP_rpc(name, args) {
  if (!window.sb) throw new Error('Nincs adatbázis-kapcsolat.');
  const { data, error } = await window.sb.rpc(name, args || {});
  if (error) throw error;
  return data;
}

const MP_api = {
  /* A jelentkező programjai, jelölési sorrendben. A programs beágyazása
     miatt a szöveges címkét is vissza kell adni: a katalógushoz még nem
     kötött sorokat CSAK az tartja életben. */
  list: async (studentId) => {
    if (!window.sb) throw new Error('Nincs adatbázis-kapcsolat.');
    const { data, error } = await window.sb
      .from('student_program')
      .select('*, programs(id, code, name, level, faculty, tuition, currency)')
      .eq('student_id', studentId)
      .order('preference', { ascending: true });
    if (error) throw error;
    return data || [];
  },
  catalogue: async () => {
    if (!window.sb) return [];
    const { data, error } = await window.sb
      .from('programs').select('id, code, name, level, faculty').order('name');
    if (error) throw error;
    return data || [];
  },
  add:    (student, programId, label) =>
            MP_rpc('student_program_add',
              { p_student: student, p_program_id: programId || null,
                p_label: label || null, p_preference: null }),
  decide: (id, decision, note) =>
            MP_rpc('student_program_decide',
              { p_id: id, p_decision: decision, p_note: note || null }),
  enrol:  (id) => MP_rpc('student_program_enrol', { p_id: id }),
  link:   (id, programId) =>
            MP_rpc('student_program_link', { p_id: id, p_program_id: programId }),
  remove: async (id) => {
    if (!window.sb) throw new Error('Nincs adatbázis-kapcsolat.');
    const { error } = await window.sb.from('student_program').delete().eq('id', id);
    if (error) throw error;
  },
  /* A jelölési sorrend átírása. Két lépésben megy: előbb egy ütközésmentes
     sávba toljuk (a student_program_pref_uniq egyedi index miatt), aztán a
     végleges helyükre. Egy körben ugyanis két sor pillanatnyilag ugyanazt a
     sorszámot kapná, és az index jogosan visszadobná. */
  reorder: async (rows) => {
    if (!window.sb) throw new Error('Nincs adatbázis-kapcsolat.');
    for (let i = 0; i < rows.length; i++) {
      const { error } = await window.sb.from('student_program')
        .update({ preference: 100 + i }).eq('id', rows[i].id);
      if (error) throw error;
    }
    for (let i = 0; i < rows.length; i++) {
      const { error } = await window.sb.from('student_program')
        .update({ preference: i + 1 }).eq('id', rows[i].id);
      if (error) throw error;
    }
  },
};

/* ---------- 3. Címkék ----------------------------------------------------- */
const MP_DECISION_LABEL = {
  Pending: 'Elbírálás alatt', Admitted: 'Felvéve', Rejected: 'Elutasítva',
  Waitlisted: 'Várólistán',   Withdrawn: 'Visszalépett',
};
const MP_DECISION_CLASS = {
  Pending:    'bg-slate-50 text-slate-600 border-slate-200',
  Admitted:   'bg-emerald-50 text-emerald-700 border-emerald-200',
  Rejected:   'bg-red-50 text-red-700 border-red-200',
  Waitlisted: 'bg-amber-50 text-amber-700 border-amber-200',
  Withdrawn:  'bg-slate-100 text-slate-400 border-slate-200',
};
const MP_LETTER_LABEL = {
  None: 'Nincs', Draft: 'Piszkozat', Issued: 'Kiállítva', Sent: 'Elküldve',
};

const MP_Badge = ({ text, cls }) => (
  <span className={'inline-flex items-center px-2 py-1 rounded-lg border text-[10px] font-bold uppercase tracking-wide ' + (cls || 'bg-slate-50 text-slate-600 border-slate-200')}>
    {text}
  </span>
);

const MP_Err = ({ text, onClose }) => !text ? null : (
  <div className="flex items-start gap-2 bg-red-50 border border-red-200 text-red-700 rounded-xl px-4 py-3 text-sm">
    <Lucide.AlertCircle size={16} className="mt-0.5 shrink-0" />
    <span className="flex-1">{text}</span>
    {onClose && <button onClick={onClose} className="text-red-400 hover:text-red-700"><Lucide.X size={14} /></button>}
  </div>
);

const MP_Ok = ({ text, onClose }) => !text ? null : (
  <div className="flex items-start gap-2 bg-emerald-50 border border-emerald-200 text-emerald-700 rounded-xl px-4 py-3 text-sm">
    <Lucide.CheckCircle2 size={16} className="mt-0.5 shrink-0" />
    <span className="flex-1">{text}</span>
    {onClose && <button onClick={onClose} className="text-emerald-500 hover:text-emerald-700"><Lucide.X size={14} /></button>}
  </div>
);

/* A programnév: a katalógusból, ha be van kötve — különben a szöveges
   címke. Enélkül a még nem kötött sorok némán üresen jelennének meg. */
function MP_name(row) {
  if (row && row.programs && row.programs.name) return row.programs.name;
  return (row && row.program_label) || '(nincs megadva)';
}

/* ---------- 4. A panel ----------------------------------------------------
   Egy jelentkező programjai. Ügyintézőként szerkeszthető, jelentkezőként
   olvasható. A személy-szintű lépések SZÁNDÉKOSAN nincsenek itt: azok
   egyszer futnak, és a fenti adatlapon látszanak. */
function MP_ProgramPanel({ studentId, canEdit }) {
  const [rows, setRows]       = React.useState(null);
  const [cat, setCat]         = React.useState([]);
  const [err, setErr]         = React.useState('');
  const [ok, setOk]           = React.useState('');
  const [busy, setBusy]       = React.useState('');
  const [adding, setAdding]   = React.useState(false);
  const [pick, setPick]       = React.useState('');

  const reload = React.useCallback(async () => {
    try {
      setErr('');
      const r = await MP_api.list(studentId);
      setRows(r);
    } catch (e) { setErr(MP_msg(e)); setRows([]); }
  }, [studentId]);

  React.useEffect(() => { if (studentId) reload(); }, [studentId, reload]);
  React.useEffect(() => {
    if (!canEdit) return;
    MP_api.catalogue().then(setCat).catch(() => setCat([]));
  }, [canEdit]);

  if (!studentId) return null;

  const act = async (fn, siker) => {
    try { setBusy('1'); setErr(''); setOk(''); await fn(); setOk(siker || ''); await reload(); }
    catch (e) { setErr(MP_msg(e)); }
    finally { setBusy(''); }
  };

  const elo = (rows || []).filter(r => r.decision !== 'Withdrawn');
  const beiratkozott = (rows || []).find(r => r.enrolled);

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div>
          <div className="text-xs font-bold text-slate-400 uppercase tracking-wide">
            Megjelölt szakok
          </div>
          <div className="text-[11px] text-slate-400 mt-0.5">
            A dokumentum-ellenőrzés, a matek és az interjú személyhez tartozik —
            azok egyszer futnak, nem szakonként.
          </div>
        </div>
        {canEdit && (
          <button onClick={() => { setAdding(a => !a); setPick(''); }}
                  className={U_btnGhost + ' !py-2 !px-3 text-xs'}>
            <Lucide.Plus size={14} /> Szak hozzáadása
          </button>
        )}
      </div>

      <MP_Err text={err} onClose={() => setErr('')} />
      <MP_Ok  text={ok}  onClose={() => setOk('')} />

      {adding && canEdit && (
        <div className="flex gap-2 items-center bg-slate-50 border border-slate-100 rounded-xl p-3">
          <select value={pick} onChange={e => setPick(e.target.value)}
                  className={U_input + ' !py-2 text-sm flex-1'}>
            <option value="">Válasszon szakot…</option>
            {cat.map(p => (
              <option key={p.id} value={p.id}>
                {p.name}{p.faculty ? ' — ' + p.faculty : ''}
              </option>
            ))}
          </select>
          <button disabled={!pick || !!busy}
                  onClick={() => act(() => MP_api.add(studentId, pick, null), 'Szak hozzáadva.')
                                   .then(() => { setAdding(false); setPick(''); })}
                  className={U_btnPrimary + ' !py-2 !px-4 text-xs'}>
            Hozzáadás
          </button>
        </div>
      )}

      {rows === null && <div className="text-sm text-slate-400 py-4">Betöltés…</div>}

      {rows !== null && rows.length === 0 && (
        <div className="text-sm text-slate-400 bg-slate-50 border border-slate-100 rounded-xl px-4 py-6 text-center">
          Ehhez a jelentkezőhöz még nincs rögzítve szak.
        </div>
      )}

      {(rows || []).map((r, i) => (
        <div key={r.id}
             className={'border rounded-xl p-4 ' +
               (r.enrolled ? 'border-emerald-200 bg-emerald-50/40'
                           : r.decision === 'Withdrawn' ? 'border-slate-100 bg-slate-50/60 opacity-60'
                           : 'border-slate-100 bg-white')}>
          <div className="flex items-start justify-between gap-3 flex-wrap">
            <div className="min-w-0">
              <div className="flex items-center gap-2 flex-wrap">
                <span className="text-[10px] font-bold text-slate-400 uppercase">
                  {r.preference}. hely
                </span>
                <span className="font-bold text-slate-700">{MP_name(r)}</span>
                {r.enrolled && <MP_Badge text="Beiratkozott" cls="bg-emerald-100 text-emerald-700 border-emerald-300" />}
              </div>
              <div className="flex items-center gap-2 mt-2 flex-wrap">
                <MP_Badge text={MP_DECISION_LABEL[r.decision] || r.decision}
                          cls={MP_DECISION_CLASS[r.decision]} />
                <span className="text-[11px] text-slate-400">
                  Levél: {MP_LETTER_LABEL[r.letter_state] || r.letter_state}
                </span>
                {!r.program_id && (
                  <span className="text-[11px] text-amber-600">
                    Nincs katalógushoz kötve
                  </span>
                )}
              </div>
              {r.note && <div className="text-[11px] text-slate-400 mt-1.5">{r.note}</div>}
            </div>

            {canEdit && r.decision !== 'Withdrawn' && (
              <div className="flex items-center gap-1.5 flex-wrap shrink-0">
                <select value={r.decision} disabled={!!busy}
                        onChange={e => act(() => MP_api.decide(r.id, e.target.value),
                                           'Döntés rögzítve.')}
                        className="bg-slate-50 border border-slate-100 rounded-lg px-2 py-1.5 text-xs text-slate-700">
                  {['Pending','Admitted','Waitlisted','Rejected','Withdrawn'].map(d => (
                    <option key={d} value={d}>{MP_DECISION_LABEL[d]}</option>
                  ))}
                </select>
                {r.decision === 'Admitted' && !r.enrolled && (
                  <button disabled={!!busy}
                          onClick={() => act(() => MP_api.enrol(r.id), 'Beiratkozás rögzítve.')}
                          className={U_btnPrimary + ' !py-1.5 !px-3 text-xs'}>
                    Beiratkozás
                  </button>
                )}
                <button disabled={!!busy}
                        onClick={() => act(() => MP_api.remove(r.id), 'Jelentkezés törölve.')}
                        className={U_btnGhost + ' !py-1.5 !px-2 text-xs !text-red-600 hover:!bg-red-50'}>
                  <Lucide.Trash2 size={13} />
                </button>
              </div>
            )}
          </div>
        </div>
      ))}

      {beiratkozott && elo.length > 1 && (
        <div className="text-[11px] text-slate-400 px-1">
          A beiratkozás után a többi jelentkezés az intézményi szabály szerint
          lezárul. A szabály a <code>student_program_setting</code> táblában
          állítható.
        </div>
      )}
    </div>
  );
}
