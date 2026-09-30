/* ============================================================
   UniPortal — ÜGYNÖKSÉGI PORTÁL: jelentkeztetés, diáklista,
   marketinganyagok, üzenetek   (108_agency_portal.sql)
   ------------------------------------------------------------
   Ez a fájl az app.jsx moduljába van fűzve (build.mjs), a
   features/programs.jsx és features/agency.jsx UTÁN — onnan használja a
   PROG_folyamatAllapot / PROG_FolyamatMegnyitas / AGENCY_* darabokat.

   MIÉRT KELLETT: az ügynöki felület a DEMO `students` táblát mutatta, a
   valódi jelentkezés viszont az admission_processes sorokban él. Az ügynök
   így nem tudott jelentkezést indítani, és a diákjai valódi állapotát sem
   látta — pedig épp ezért használja a portált.

   AZ ÜGYNÖK–DIÁK HOZZÁRENDELÉS a jelentkezés SORÁN van (agency_id), nem
   e-mail-egyezésen: az e-mail megváltozhat, elgépelhető, és utólag nem
   lehetne eldönteni, ki hozta a diákot.

   MIGRÁCIÓ NÉLKÜL IS ELINDUL: ha a 108 még nem futott le, a felület ezt
   KIMONDJA, ahelyett hogy üres listát vagy néma hibát mutatna.
   ============================================================ */

const AGN_HIANYZIK = /Could not find the (table|function)|schema cache|does not exist|agency_id/i;
const AGN_hibaSzoveg = (e) => {
  const m = String((e && (e.message || e.error_description || e.error)) || e || '');
  if (/AGENCY_REQUIRED/.test(m)) return 'Ehhez ügynökségi fiók kell. Ha ügynökként vagy belépve, szólj a koordinátornak, hogy kösse a fiókodat az ügynökséghez.';
  if (/EMAIL_INVALID/.test(m)) return 'Érvényes e-mail-cím kell a jelentkezőhöz.';
  if (/NAME_REQUIRED/.test(m)) return 'A jelentkező neve kötelező.';
  if (/STAFF_ONLY/.test(m)) return 'Üzenetet csak ügyintéző küldhet az ügynökségeknek.';
  /* A 110-es migráció szigorúbb hibái: a tesztelésen kiderült, hogy ezek
     nélkül a felület szó nélkül továbblépett egy másik ügynökség sorára. */
  if (/EMAIL_TAKEN_BY_OTHER_AGENCY/.test(m)) return 'Erre az e-mail-címre már van jelentkezés, amelyet egy másik ügynökség indított. Egyeztess a felvételi irodával.';
  if (/EMAIL_NOT_ASCII/.test(m)) return 'Az e-mail-cím nem tartalmazhat ékezetes betűt — ellenőrizd az elgépelést.';
  if (AGN_HIANYZIK.test(m)) return 'Az ügynökségi modul adatbázis-része még nincs telepítve (108_agency_portal.sql).';
  if (/row-level security|permission denied|42501/i.test(m)) return 'Ehhez nincs jogosultságod.';
  return m || 'Ismeretlen hiba.';
};
const AGN_nincsTelepitve = (e) => AGN_HIANYZIK.test(String((e && (e.message || e.error)) || e || ''));

const AGN_api = {
  async start(o) {
    const { data, error } = await window.sb.rpc('agency_application_start', {
      p_name: o.name, p_email: o.email, p_country: o.country || null,
      p_program_ids: o.programIds || [], p_term: o.term || null,
    });
    if (error) throw error;
    return Array.isArray(data) ? data[0] : data;
  },
  async list(agencyId) {
    let q = window.sb.from('admission_process_list')
      .select('id,ref_no,owner_email,applicant_name,stage,student_step,done,created_at,updated_at,program_id,agency_id,data')
      .order('updated_at', { ascending: false }).limit(500);
    if (agencyId) q = q.eq('agency_id', agencyId);
    else q = q.not('agency_id', 'is', null);
    const { data, error } = await q;
    if (error) throw error;
    return data || [];
  },
  async messages() {
    const { data, error } = await window.sb.rpc('agency_messages');
    if (error) throw error;
    return data || [];
  },
  async markRead(id) { try { await window.sb.rpc('agency_message_mark_read', { p_id: id }); } catch (e) {} },
  async send(o) {
    const { data, error } = await window.sb.rpc('agency_message_send', {
      p_agency: o.agencyId || null, p_subject: o.subject, p_body: o.body,
      p_kind: o.kind || 'notice', p_process: o.processId || null,
    });
    if (error) throw error;
    return data;
  },
  async assets() {
    const { data, error } = await window.sb.from('agency_asset').select('*')
      .order('uploaded_at', { ascending: false }).limit(200);
    if (error) throw error;
    return data || [];
  },
  async addAsset(row) {
    const { data, error } = await window.sb.from('agency_asset').insert(row).select().single();
    if (error) throw error;
    return data;
  },
  async setAsset(id, patch) {
    const { error } = await window.sb.from('agency_asset').update(patch).eq('id', id);
    if (error) throw error;
  },
};

/* Marketinganyag feltöltése a documents tárolóba, a 'marketing/' előtag alá.
   A típusokat ugyanaz a lista korlátozza, mint a jelentkezői feltöltésnél. */
async function AGN_marketingUpload(file, ownerId) {
  if (!window.sb) throw new Error('Nincs adatbázis-kapcsolat.');
  if (!ownerId) throw new Error('Ismeretlen feltöltő — jelentkezz be újra.');
  if (typeof DOC_tipusOk === 'function' && !DOC_tipusOk(file)) throw new Error(DOC_tipusHiba(file));
  if (file.size > 20 * 1024 * 1024) throw new Error('A fájl nagyobb 20 MB-nál.');
  const safe = (typeof DOC_safeName === 'function') ? DOC_safeName(file.name)
    : String(file.name || 'file').replace(/[^a-zA-Z0-9._-]/g, '_').slice(-80);
  const path = 'marketing/' + Date.now().toString(36) + '-' + safe;
  await FEL_upload('documents', path, file, {
    upsert: true, contentType: file.type || 'application/octet-stream', cim: file.name,
  });
  return path;
}

const AGN_MSG_CIMKE = {
  circular:     { cimke: 'Körlevél',    szin: 'bg-sky-50 text-sky-700 border-sky-200' },
  missing_docs: { cimke: 'Hiánypótlás', szin: 'bg-amber-50 text-amber-700 border-amber-200' },
  decision:     { cimke: 'Döntés',      szin: 'bg-emerald-50 text-emerald-700 border-emerald-200' },
  notice:       { cimke: 'Értesítés',   szin: 'bg-slate-50 text-slate-600 border-slate-200' },
};
const AGN_ASSET_KIND = [
  { id: 'brochure',     label: 'Brosúra' },
  { id: 'logo',         label: 'Logó és arculat' },
  { id: 'photo',        label: 'Fotó' },
  { id: 'presentation', label: 'Prezentáció' },
  { id: 'other',        label: 'Egyéb' },
];
const AGN_kindLabel = (k) => (AGN_ASSET_KIND.find(x => x.id === k) || {}).label || 'Egyéb';

/* A jelentkezés állapota EGY forrásból: ugyanaz a számítás, amit a hallgató
   sávja és az irodai lista használ (PROG_folyamatAllapot). */
function AGN_allapot(sor, katalogus) {
  const proc = { ...sor, status: sor.stage === 'office' ? 'submitted' : 'draft' };
  try { return PROG_folyamatAllapot(proc, katalogus || []); } catch (e) { return null; }
}

const AGN_Ures = ({ ikon, cim, alcim, gomb }) => (
  <div className="bg-white rounded-3xl border border-dashed border-slate-200 p-10 text-center">
    <div className="inline-flex items-center justify-center w-12 h-12 rounded-2xl bg-slate-50 mb-3">
      {ikon || <Lucide.Inbox size={22} className="text-slate-300" />}
    </div>
    <h3 className="font-black text-slate-800">{cim}</h3>
    {alcim && <p className="text-sm text-slate-400 font-medium mt-1.5 max-w-lg mx-auto leading-relaxed">{alcim}</p>}
    {gomb}
  </div>
);

const AGN_Hiba = ({ szoveg, onClose }) => (!szoveg ? null : (
  <div className="mb-4 flex items-start gap-2 rounded-2xl border border-red-100 bg-red-50 px-4 py-3 text-sm font-bold text-red-600">
    <Lucide.AlertCircle size={16} className="flex-none mt-0.5" />
    <span className="flex-1">{szoveg}</span>
    {onClose && <button onClick={onClose} className="text-red-400 hover:text-red-600"><Lucide.X size={14} /></button>}
  </div>
));

/* ============================================================
   1. DIÁK JELENTKEZTETÉSE + A JELENTKEZTETETT DIÁKOK LISTÁJA
   ============================================================ */
function AGN_DiakokFul({ user, agencies, myAgencyId }) {
  const isAgent = user && user.role === 'AGENT';
  const [sorok, setSorok] = useState(null);
  const [kat, setKat] = useState([]);
  const [hiba, setHiba] = useState('');
  const [telepitve, setTelepitve] = useState(true);
  const [q, setQ] = useState('');
  const [uj, setUj] = useState(null);           // { name, email, country, ids, term }
  const [busy, setBusy] = useState(false);
  const [nyit, setNyit] = useState(null);       // megnyitott jelentkezés azonosítója
  // A választható képzések: nyitott, fokozatot adó képzések a katalógusból.
  const kepzesek = (kat || []).filter(x => x && x.is_open !== false
    && (typeof PROG_kind !== 'function' || PROG_kind(x) === 'degree'));

  const tolt = React.useCallback(async () => {
    setHiba('');
    try {
      /* A DOKUMENTUMTÍPUSOKAT IS BE KELL TÖLTENI: enélkül az egyedi típus a
         nyers kulcsával jelent meg a hiányzók között („c_teszt_dokumentum_ybtv"),
         nem a nevével — külügyi iroda, 2026-09-30. */
      const [lista, programok] = await Promise.all([
        AGN_api.list(isAgent ? (myAgencyId || user.agencyId) : ''),
        (typeof PROG_loadPrograms === 'function' ? PROG_loadPrograms() : Promise.resolve([])),
        (typeof PROG_loadDocTypes === 'function' ? PROG_loadDocTypes() : Promise.resolve(null)),
      ]);
      setKat(programok || []);
      setSorok(lista);
    } catch (e) {
      if (AGN_nincsTelepitve(e)) { setTelepitve(false); setSorok([]); }
      else { setHiba(AGN_hibaSzoveg(e)); setSorok([]); }
    }
  }, [isAgent, myAgencyId, user && user.agencyId]);
  useEffect(() => { tolt(); }, [tolt]);

  const indit = async () => {
    if (!uj) return;
    setBusy(true); setHiba('');
    try {
      const sor = await AGN_api.start({
        name: uj.name, email: uj.email, country: uj.country,
        programIds: uj.ids || [], term: uj.term || '',
      });
      setUj(null);
      await tolt();
      if (sor && sor.id) setNyit(sor.id);
    } catch (e) { setHiba(AGN_hibaSzoveg(e)); }
    finally { setBusy(false); }
  };

  if (nyit) {
    return (
      <div className="animate-in fade-in duration-300">
        <button onClick={() => { setNyit(null); tolt(); }} className="flex items-center gap-2 text-sm font-bold text-slate-400 hover:text-primary mb-4">
          <Lucide.ArrowLeft size={16} /> Vissza a diákjaimhoz
        </button>
        {typeof PROG_FolyamatMegnyitas === 'function'
          ? <PROG_FolyamatMegnyitas processId={nyit} user={user} onExit={() => { setNyit(null); tolt(); }} />
          : <AGN_Ures cim="A jelentkezési felület nem érhető el" alcim="Töltsd újra az oldalt." />}
      </div>
    );
  }

  const szurt = (sorok || []).filter(s => {
    if (!q) return true;
    const t = (s.applicant_name || '') + ' ' + (s.owner_email || '') + ' ' + ('FV-' + String(s.ref_no || '').padStart(5, '0'));
    return t.toLowerCase().includes(q.toLowerCase());
  });

  return (
    <div className="space-y-5 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <AGN_Hiba szoveg={hiba} onClose={() => setHiba('')} />
      {!telepitve && (
        <div className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm font-bold text-amber-800" data-agn-nincs-migracio="1">
          Az ügynökségi modul adatbázis-része még nincs telepítve (108_agency_portal.sql). A lista addig üres marad.
        </div>
      )}

      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="relative flex-1 min-w-[220px] max-w-md">
          <Lucide.Search size={16} className="absolute left-3.5 top-1/2 -translate-y-1/2 text-slate-400" />
          <input value={q} onChange={e => setQ(e.target.value)} placeholder="Keresés név, e-mail vagy azonosító szerint…"
            className="w-full bg-white border border-slate-200 rounded-2xl pl-10 pr-3 py-2.5 text-sm font-semibold text-slate-700 focus:outline-none focus:ring-2 focus:ring-primary/20" />
        </div>
        {isAgent && (
          <button onClick={() => setUj({ name: '', email: '', country: '', ids: [],
              term: (typeof PROG_upcomingTerms === 'function' ? (PROG_upcomingTerms()[0] || {}).code : '') || '' })}
            disabled={!telepitve} data-agn-uj-jelentkezo="1"
            className="bg-primary text-white px-5 py-2.5 rounded-2xl text-sm font-black inline-flex items-center gap-2 disabled:opacity-40">
            <Lucide.UserPlus size={16} /> Új jelentkező
          </button>
        )}
      </div>

      {sorok === null ? (
        <div className="h-40 rounded-3xl bg-white border border-slate-100 animate-pulse" />
      ) : szurt.length === 0 ? (
        <AGN_Ures ikon={<Lucide.Users size={22} className="text-slate-300" />}
          cim={q ? 'Nincs találat' : 'Még nincs jelentkeztetett diákod'}
          alcim={q ? 'Próbálj másik keresőkifejezést.' : 'Az „Új jelentkező" gombbal indíthatsz jelentkezést a diák nevében. A jelentkezés a diákhoz és az ügynökségedhez is kötve marad.'} />
      ) : (
        <div className="bg-white rounded-3xl border border-slate-100 shadow-sm overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-left min-w-[860px]" data-agn-diaklista="1">
              <thead className="bg-slate-50 text-slate-400 text-[10px] font-black uppercase tracking-wider">
                <tr>
                  <th className="px-5 py-3">Azonosító</th>
                  <th className="px-5 py-3">Jelentkező</th>
                  <th className="px-5 py-3">Képzés</th>
                  <th className="px-5 py-3">Folyamat</th>
                  <th className="px-5 py-3">Hiányzó dokumentum</th>
                  <th className="px-5 py-3">Állapot</th>
                  <th className="px-5 py-3 text-right">Művelet</th>
                </tr>
              </thead>
              <tbody>
                {szurt.map(s => {
                  const fa = AGN_allapot(s, kat);
                  const hianyzo = fa ? (fa.dok.hianyzik || []) : [];
                  const kovetkezo = fa && fa.aktualis ? fa.aktualis.label : '—';
                  const progNev = (fa && fa.valasztott && fa.valasztott.length)
                    ? fa.valasztott.map(x => x.code || x.name).join(' · ')
                    : (s.program_id || '—');
                  return (
                    <tr key={s.id} className="border-t border-slate-50 hover:bg-slate-50/60 align-top" data-agn-sor={s.id}>
                      <td className="px-5 py-3 text-[12px] font-mono font-bold text-slate-500 whitespace-nowrap">
                        {s.ref_no ? 'FV-' + String(s.ref_no).padStart(5, '0') : '—'}
                      </td>
                      <td className="px-5 py-3">
                        <div className="font-bold text-slate-800" data-echo-noi18n>{s.applicant_name || '—'}</div>
                        <div className="text-[11px] text-slate-400 font-semibold" data-echo-noi18n>{s.owner_email}</div>
                      </td>
                      <td className="px-5 py-3 text-[12px] font-bold text-slate-600" data-echo-noi18n>{progNev}</td>
                      <td className="px-5 py-3">
                        <div className="text-[12px] font-bold text-slate-600">{fa ? `${fa.kesz}/${fa.osszes} lépés kész` : '—'}</div>
                        {/* KÉT CSOMÓPONT: összefűzve a lépés neve magyar maradt
                            angol módban („Következő: Dokumentumok"). */}
                        <div className="text-[11px] text-slate-400 font-semibold"><span>Következő:</span> <span>{kovetkezo}</span></div>
                      </td>
                      <td className="px-5 py-3">
                        {hianyzo.length === 0
                          ? <span className="text-[11px] font-bold text-emerald-600 inline-flex items-center gap-1"><Lucide.Check size={12} /> Minden feltöltve</span>
                          : <div className="flex flex-wrap gap-1">
                              {hianyzo.slice(0, 4).map(d => (
                                <span key={d.id} className="px-1.5 py-0.5 rounded bg-red-50 text-red-600 text-[10px] font-bold">{d.label}</span>
                              ))}
                              {hianyzo.length > 4 && <span className="text-[10px] font-bold text-slate-400">{'+' + (hianyzo.length - 4)}</span>}
                            </div>}
                      </td>
                      <td className="px-5 py-3">
                        <span className={'text-[10px] font-black px-2 py-1 rounded-full whitespace-nowrap '
                          + (!fa ? 'bg-slate-100 text-slate-500'
                            : fa.kod === 'rejected' || fa.kod === 'cancelled' ? 'bg-red-50 text-red-600'
                            : fa.kod === 'accepted' || fa.kod === 'admitted' ? 'bg-emerald-50 text-emerald-600'
                            : fa.kod === 'student' ? 'bg-amber-50 text-amber-700' : 'bg-primary/10 text-primary')}>
                          {fa ? fa.cimke : (s.stage === 'student' ? 'Hallgató tölti ki' : 'Beadva')}
                        </span>
                      </td>
                      <td className="px-5 py-3 text-right">
                        <button onClick={() => setNyit(s.id)} data-agn-megnyit={s.id}
                          className="px-3 py-1.5 rounded-lg text-[11px] font-bold bg-slate-100 text-slate-600 hover:bg-slate-200 inline-flex items-center gap-1">
                          <Lucide.ArrowRight size={13} /> Megnyitás
                        </button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* --- új jelentkező --- */}
      {uj && (
        <UModal open onClose={() => setUj(null)} max="max-w-xl" title="Új jelentkező"
          subtitle="A jelentkezés az ügynökségedhez kötve jön létre — később is látszik, hogy te hoztad a diákot."
          icon={<Lucide.UserPlus size={20} />}>
          <div className="space-y-4">
            <div className="grid sm:grid-cols-2 gap-4">
              <UField label="A jelentkező teljes neve">
                <input className={U_input} value={uj.name} data-agn-nev="1"
                  onChange={e => setUj({ ...uj, name: e.target.value })} placeholder="pl. Adeyemi Oluwaseun" />
              </UField>
              <UField label="E-mail-címe">
                <input className={U_input} value={uj.email} data-agn-email="1" type="email"
                  onChange={e => setUj({ ...uj, email: e.target.value })} placeholder="diak@example.com" />
              </UField>
            </div>
            <UField label="Állampolgárság (opcionális)">
              <input className={U_input} value={uj.country} data-agn-orszag="1"
                onChange={e => setUj({ ...uj, country: e.target.value })} placeholder="pl. Nigeria" />
            </UField>
            {/* A KÉPZÉST ITT KELL MEGADNI: a jelentkezési folyamat egy konkrét
                képzésből nyílik meg (ugyanaz a nézet, mint az önálló
                jelentkezőnél), és a választás a folyamat első lépésében
                bármikor módosítható. */}
            <UField label={'Képzés (legfeljebb ' + (typeof PROG_MAX_DEGREES !== 'undefined' ? PROG_MAX_DEGREES : 3) + ', a sorrend a preferencia)'}>
              <div className="max-h-44 overflow-y-auto rounded-2xl border border-slate-100 divide-y divide-slate-50" data-agn-kepzeslista="1">
                {(kepzesek || []).length === 0 && <div className="px-3 py-3 text-[12px] font-semibold text-slate-400">Nincs nyitott képzés a kínálatban.</div>}
                {(kepzesek || []).map(pg => {
                  const on = (uj.ids || []).includes(pg.id);
                  const tele = !on && (uj.ids || []).length >= (typeof PROG_MAX_DEGREES !== 'undefined' ? PROG_MAX_DEGREES : 3);
                  return (
                    <label key={pg.id} className={'flex items-start gap-3 px-3 py-2.5 cursor-pointer ' + (tele ? 'opacity-40' : 'hover:bg-slate-50')}>
                      <input type="checkbox" checked={on} disabled={tele} data-agn-kepzes={pg.id}
                        onChange={() => setUj(u => ({ ...u, ids: on ? (u.ids || []).filter(x => x !== pg.id) : [...(u.ids || []), pg.id] }))}
                        className="mt-0.5" />
                      <span className="min-w-0">
                        <span className="block text-[13px] font-bold text-slate-700" data-echo-noi18n>{pg.name}</span>
                        <span className="block text-[11px] font-semibold text-slate-400" data-echo-noi18n>{[pg.degree, pg.faculty].filter(Boolean).join(' · ')}</span>
                      </span>
                    </label>
                  );
                })}
              </div>
            </UField>
            <UField label="Félév">
              <select className={U_input} value={uj.term} data-agn-felev="1"
                onChange={e => setUj({ ...uj, term: e.target.value })}>
                {(typeof PROG_upcomingTerms === 'function' ? PROG_upcomingTerms() : []).map(t => (
                  <option key={t.code} value={t.code}>{typeof PROG_termLabel === 'function' ? PROG_termLabel(t.code, true) : t.code}</option>
                ))}
              </select>
            </UField>
            <div className="rounded-2xl border border-slate-100 bg-slate-50 px-4 py-3 text-[12px] font-semibold text-slate-500 leading-relaxed">
              A jelentkezés ezután ugyanúgy folytatódik, mint az önálló jelentkezőknél: személyes adatok, dokumentumok, beadás.
              A diák a saját e-mail-címével be tud lépni, és maga is folytathatja.
            </div>
            <AGN_Hiba szoveg={hiba} onClose={() => setHiba('')} />
            <div className="flex justify-end gap-2">
              <button onClick={() => setUj(null)} className={U_btnGhost}>Mégse</button>
              <button onClick={indit} disabled={busy || !uj.name.trim() || !uj.email.trim() || !(uj.ids || []).length}
                data-agn-inditas="1" className={U_btnPrimary + ' disabled:opacity-40'}>
                {busy ? 'Indítás…' : 'Jelentkezés indítása'}
              </button>
            </div>
          </div>
        </UModal>
      )}
    </div>
  );
}

/* ============================================================
   2. ÜZENETEK
   ============================================================ */
function AGN_UzenetekFul({ user, agencies, myAgencyId }) {
  const isAgent = user && user.role === 'AGENT';
  const staff = !isAgent;
  const [lista, setLista] = useState(null);
  const [hiba, setHiba] = useState('');
  const [telepitve, setTelepitve] = useState(true);
  const [ir, setIr] = useState(null);     // { agencyId, subject, body, kind }
  const [busy, setBusy] = useState(false);

  const tolt = React.useCallback(async () => {
    setHiba('');
    try { setLista(await AGN_api.messages()); }
    catch (e) {
      if (AGN_nincsTelepitve(e)) { setTelepitve(false); setLista([]); }
      else { setHiba(AGN_hibaSzoveg(e)); setLista([]); }
    }
  }, []);
  useEffect(() => { tolt(); }, [tolt]);

  const kuld = async () => {
    setBusy(true); setHiba('');
    try {
      await AGN_api.send({ agencyId: ir.agencyId || null, subject: ir.subject, body: ir.body, kind: ir.kind || 'notice' });
      setIr(null); await tolt();
    } catch (e) { setHiba(AGN_hibaSzoveg(e)); }
    finally { setBusy(false); }
  };

  const olvas = async (m) => {
    if (m.olvasott) return;
    await AGN_api.markRead(m.id);
    setLista(l => (l || []).map(x => x.id === m.id ? { ...x, olvasott: true } : x));
  };

  return (
    <div className="space-y-5 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <AGN_Hiba szoveg={hiba} onClose={() => setHiba('')} />
      {!telepitve && (
        <div className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm font-bold text-amber-800">
          Az ügynökségi modul adatbázis-része még nincs telepítve (108_agency_portal.sql).
        </div>
      )}
      {staff && (
        <div className="flex justify-end">
          <button onClick={() => setIr({ agencyId: '', subject: '', body: '', kind: 'circular' })}
            disabled={!telepitve} data-agn-uj-uzenet="1"
            className="bg-primary text-white px-5 py-2.5 rounded-2xl text-sm font-black inline-flex items-center gap-2 disabled:opacity-40">
            <Lucide.Send size={16} /> Üzenet az ügynökségeknek
          </button>
        </div>
      )}

      {lista === null ? (
        <div className="h-40 rounded-3xl bg-white border border-slate-100 animate-pulse" />
      ) : lista.length === 0 ? (
        <AGN_Ures ikon={<Lucide.MessageSquare size={22} className="text-slate-300" />}
          cim="Nincs üzenet"
          alcim={isAgent
            ? 'Itt kapod meg a koordinátori körleveleket, a hiánypótlási felszólításokat és a felvételi döntésekről szóló értesítéseket.'
            : 'Itt küldhetsz körlevelet az ügynökségeknek, vagy címzett üzenetet egyetlen ügynökségnek.'} />
      ) : (
        <div className="space-y-3" data-agn-uzenetlista="1">
          {lista.map(m => {
            const t = AGN_MSG_CIMKE[m.kind] || AGN_MSG_CIMKE.notice;
            const ag = (agencies || []).find(a => a.id === m.agency_id);
            return (
              <div key={m.id} onClick={() => olvas(m)} data-agn-uzenet={m.id} data-olvasott={m.olvasott ? '1' : '0'}
                className={'bg-white rounded-2xl border p-5 cursor-pointer transition-all hover:shadow-sm '
                  + (m.olvasott ? 'border-slate-100' : 'border-primary/30 bg-primary/5')}>
                <div className="flex flex-wrap items-center gap-2 mb-1.5">
                  <span className={'text-[10px] font-black px-2 py-1 rounded-full border ' + t.szin}>{t.cimke}</span>
                  {!m.olvasott && <span className="text-[10px] font-black px-2 py-1 rounded-full bg-primary text-white">Új</span>}
                  <span className="text-[11px] font-bold text-slate-400">
                    {m.agency_id ? <span data-echo-noi18n>{(ag && ag.name) || m.agency_id}</span> : 'Minden ügynökségnek'}
                  </span>
                  <span className="text-[11px] font-semibold text-slate-400 ml-auto">{DL_dateLong ? DL_dateLong(m.sent_at) : String(m.sent_at).slice(0, 10)}</span>
                </div>
                <div className="font-black text-slate-800">{m.subject}</div>
                <p className="text-sm text-slate-600 mt-1 leading-relaxed whitespace-pre-wrap">{m.body}</p>
                {m.sent_by && <div className="text-[11px] font-bold text-slate-400 mt-2" data-echo-noi18n>{m.sent_by}</div>}
              </div>
            );
          })}
        </div>
      )}

      {ir && (
        <UModal open onClose={() => setIr(null)} max="max-w-xl" title="Üzenet az ügynökségeknek"
          subtitle="Körlevél mindenkinek, vagy címzett üzenet egy ügynökségnek." icon={<Lucide.Send size={20} />}>
          <div className="space-y-4">
            <div className="grid sm:grid-cols-2 gap-4">
              <UField label="Címzett">
                <select className={U_input} value={ir.agencyId} data-agn-cimzett="1"
                  onChange={e => setIr({ ...ir, agencyId: e.target.value })}>
                  <option value="">Minden ügynökségnek (körlevél)</option>
                  {(agencies || []).map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
                </select>
              </UField>
              <UField label="Típus">
                <select className={U_input} value={ir.kind} onChange={e => setIr({ ...ir, kind: e.target.value })}>
                  <option value="circular">Körlevél</option>
                  <option value="missing_docs">Hiánypótlási felszólítás</option>
                  <option value="decision">Felvételi döntés</option>
                  <option value="notice">Értesítés</option>
                </select>
              </UField>
            </div>
            <UField label="Tárgy">
              <input className={U_input} value={ir.subject} data-agn-targy="1"
                onChange={e => setIr({ ...ir, subject: e.target.value })} />
            </UField>
            <UField label="Üzenet">
              <textarea className={U_input + ' min-h-[140px]'} value={ir.body} data-agn-szoveg="1"
                onChange={e => setIr({ ...ir, body: e.target.value })} />
            </UField>
            <AGN_Hiba szoveg={hiba} onClose={() => setHiba('')} />
            <div className="flex justify-end gap-2">
              <button onClick={() => setIr(null)} className={U_btnGhost}>Mégse</button>
              <button onClick={kuld} disabled={busy || !ir.subject.trim() || !ir.body.trim()}
                data-agn-kuldes="1" className={U_btnPrimary + ' disabled:opacity-40'}>
                {busy ? 'Küldés…' : 'Küldés'}
              </button>
            </div>
          </div>
        </UModal>
      )}
    </div>
  );
}

/* ============================================================
   3. LETÖLTHETŐ MARKETINGANYAGOK
   ============================================================ */
function AGN_AnyagtarFul({ user, myAgencyId }) {
  const staff = !(user && user.role === 'AGENT');
  const [lista, setLista] = useState(null);
  const [hiba, setHiba] = useState('');
  const [telepitve, setTelepitve] = useState(true);
  const [busy, setBusy] = useState(false);
  const [uj, setUj] = useState(null);   // { title, kind, description, link }
  const [elonezet, setElonezet] = useState(null);   // az oldalról nyíló olvasó

  const tolt = React.useCallback(async () => {
    setHiba('');
    try { setLista(await AGN_api.assets()); }
    catch (e) {
      if (AGN_nincsTelepitve(e)) { setTelepitve(false); setLista([]); }
      else { setHiba(AGN_hibaSzoveg(e)); setLista([]); }
    }
  }, []);
  useEffect(() => { tolt(); }, [tolt]);

  const feltolt = async (e) => {
    const file = e.target.files && e.target.files[0];
    e.target.value = '';
    if (!file || !uj) return;
    setBusy(true); setHiba('');
    try {
      /* A 'marketing/' ELŐTAG KÖTÖTT (110). A documents tároló alapszabálya
         csak a SAJÁT mappát engedi olvasni (első szegmens = auth.uid()),
         ezért az iroda feltöltését az ügynök nem tudta letölteni — mérve:
         „A fájl most nem érhető el." A marketing előtagra külön szabály van. */
      const path = await AGN_marketingUpload(file, user && user.id);
      await AGN_api.addAsset({
        id: 'AST-' + Date.now().toString(36), title: uj.title || file.name,
        description: uj.description || null, kind: uj.kind || 'other',
        path, file_name: file.name, file_size: file.size,
        uploaded_by: (user && (user.name || user.email)) || null,
      });
      setUj(null); await tolt();
    } catch (e2) { setHiba(AGN_hibaSzoveg(e2)); }
    finally { setBusy(false); }
  };

  const letolt = async (a) => {
    if (a.link) { window.open(a.link, '_blank', 'noopener'); return; }
    const url = await AGENCY_signedUrl(a.path);
    if (url) window.open(url, '_blank', 'noopener');
    else setHiba('A fájl most nem érhető el. Próbáld újra, vagy szólj a koordinátornak.');
  };

  return (
    <div className="space-y-5 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <AGN_Hiba szoveg={hiba} onClose={() => setHiba('')} />
      {!telepitve && (
        <div className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm font-bold text-amber-800">
          Az ügynökségi modul adatbázis-része még nincs telepítve (108_agency_portal.sql).
        </div>
      )}
      {staff && (
        <div className="flex justify-end">
          <button onClick={() => setUj({ title: '', kind: 'brochure', description: '' })}
            disabled={!telepitve} data-agn-uj-anyag="1"
            className="bg-primary text-white px-5 py-2.5 rounded-2xl text-sm font-black inline-flex items-center gap-2 disabled:opacity-40">
            <Lucide.Upload size={16} /> Anyag feltöltése
          </button>
        </div>
      )}

      {lista === null ? (
        <div className="h-40 rounded-3xl bg-white border border-slate-100 animate-pulse" />
      ) : lista.length === 0 ? (
        <AGN_Ures ikon={<Lucide.FolderOpen size={22} className="text-slate-300" />}
          cim="Még nincs letölthető anyag"
          alcim={staff ? 'Töltsd fel a brosúrákat, a logócsomagot és a kampuszfotókat — minden jóváhagyott ügynökség látni fogja.'
                       : 'A koordinátor még nem töltött fel marketinganyagot. Szólj neki, ha szükséged van rá.'} />
      ) : (
        <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-4" data-agn-anyaglista="1">
          {lista.map(a => (
            <div key={a.id} className={'bg-white rounded-3xl border p-5 flex flex-col ' + (a.is_active ? 'border-slate-100' : 'border-slate-100 opacity-60')}>
              <div className="flex items-start justify-between gap-3">
                <span className="px-2 py-1 rounded-lg bg-primary/10 text-primary text-[10px] font-black">{AGN_kindLabel(a.kind)}</span>
                {!a.is_active && <span className="text-[10px] font-black text-slate-400">Archivált</span>}
              </div>
              <h3 className="font-black text-slate-800 mt-3 leading-snug" data-echo-noi18n>{a.title}</h3>
              {a.description && <p className="text-[12px] text-slate-500 mt-1 leading-relaxed flex-1" data-echo-noi18n>{a.description}</p>}
              <div className="text-[11px] font-bold text-slate-400 mt-2" data-echo-noi18n>
                {[a.file_name, a.file_size ? AGENCY_kb(a.file_size) : ''].filter(Boolean).join(' · ')}
              </div>
              <div className="flex items-center gap-2 mt-4">
                {!a.link && (
                  <button onClick={() => setElonezet({ entry: { path: a.path, type: '' }, fileName: a.file_name || a.title, label: a.title })}
                    data-agn-elonezet={a.id} title="Előnézet"
                    className="w-9 h-9 flex-none rounded-xl bg-slate-100 text-slate-600 hover:bg-slate-200 flex items-center justify-center">
                    <Lucide.Eye size={15} />
                  </button>
                )}
                <button onClick={() => letolt(a)} data-agn-letoltes={a.id}
                  className="flex-1 bg-slate-900 text-white px-4 py-2 rounded-xl text-[13px] font-bold inline-flex items-center justify-center gap-1.5">
                  <Lucide.Download size={14} /> Letöltés
                </button>
                {staff && (
                  <button onClick={async () => { await AGN_api.setAsset(a.id, { is_active: !a.is_active }); tolt(); }}
                    title={a.is_active ? 'Archiválás' : 'Visszaállítás'}
                    className="w-9 h-9 rounded-xl bg-slate-100 text-slate-500 hover:bg-slate-200 flex items-center justify-center">
                    {a.is_active ? <Lucide.Archive size={15} /> : <Lucide.RotateCcw size={15} />}
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {elonezet && typeof DocReader === 'function' && (
        <DocReader entry={elonezet.entry} fileName={elonezet.fileName} label={elonezet.label}
          Icon={Lucide.FileText} onClose={() => setElonezet(null)} />
      )}
      {uj && (
        <UModal open onClose={() => setUj(null)} max="max-w-lg" title="Marketinganyag feltöltése"
          subtitle="Minden jóváhagyott ügynökség látni és letölteni fogja." icon={<Lucide.Upload size={20} />}>
          <div className="space-y-4">
            <UField label="Megnevezés"><input className={U_input} value={uj.title} onChange={e => setUj({ ...uj, title: e.target.value })} placeholder="pl. Egyetemi brosúra 2027" /></UField>
            <UField label="Típus">
              <select className={U_input} value={uj.kind} onChange={e => setUj({ ...uj, kind: e.target.value })}>
                {AGN_ASSET_KIND.map(k => <option key={k.id} value={k.id}>{k.label}</option>)}
              </select>
            </UField>
            <UField label="Rövid leírás (opcionális)"><input className={U_input} value={uj.description} onChange={e => setUj({ ...uj, description: e.target.value })} /></UField>
            <AGN_Hiba szoveg={hiba} onClose={() => setHiba('')} />
            <div className="flex justify-end gap-2">
              <button onClick={() => setUj(null)} className={U_btnGhost}>Mégse</button>
              <label className={U_btnPrimary + ' cursor-pointer ' + (busy ? 'opacity-50 pointer-events-none' : '')}>
                <Lucide.Upload size={16} /> {busy ? 'Feltöltés…' : 'Fájl kiválasztása'}
                <input type="file" accept={typeof DOC_ACCEPT !== 'undefined' ? DOC_ACCEPT : undefined} className="hidden" onChange={feltolt} />
              </label>
            </div>
          </div>
        </UModal>
      )}
    </div>
  );
}

/* ============================================================
   4. JUTALÉK — CSAK TÁJÉKOZTATÁS
   Az ügynök NEM írhatja át; a százalékot az iroda állítja (agency_decide).
   ============================================================ */
function AGN_JutalekInfo({ agency, myAgencyId, user }) {
  const rate = agency ? Number(agency.commissionRate || 0) : null;
  const [sorok, setSorok] = React.useState(null);
  const [kat, setKat] = React.useState([]);

  /* A TÉTELES LISTA. A tesztmérnök jelezte (2026-09-30), hogy a kulcs önmagában
     kevés: az ügynök azt akarja látni, MELYIK diákja után mennyi jutalék jár.
     A lista a saját jelentkezéseiből áll össze; az összeg TÁJÉKOZTATÓ — a
     kötelező érvényű összeg a kiküldött számlán van, és a jutalék csak a
     BEIRATKOZÁS lezárása után számolható el. */
  React.useEffect(() => {
    let el = false;
    (async () => {
      try {
        const [lista, programok] = await Promise.all([
          AGN_api.list(myAgencyId || (user && user.agencyId) || ''),
          (typeof PROG_loadPrograms === 'function' ? PROG_loadPrograms() : Promise.resolve([])),
        ]);
        if (el) return;
        setKat(programok || []); setSorok(lista || []);
      } catch (e) { if (!el) setSorok([]); }
    })();
    return () => { el = true; };
  }, [myAgencyId, user && user.agencyId]);

  const tetelek = (sorok || []).map(s => {
    const d = (s.data && s.data.decision) || null;
    const felvett = !!(d && d.outcome === 'admitted');
    const pid = (d && d.programId) || (Array.isArray(s.data && s.data.program_ids) ? s.data.program_ids[0] : s.program_id);
    const pg = (kat || []).find(x => x.id === pid) || null;
    const tandij = pg ? Number(pg.tuition || 0) : 0;
    return { id: s.id, nev: s.applicant_name || s.owner_email, program: pg ? (pg.code || pg.name) : (pid || '—'),
             felvett, tandij, osszeg: (rate && tandij) ? Math.round(tandij * rate / 100) : 0 };
  }).filter(x => x.felvett);

  return (
    <div className="space-y-6">
      <div className="bg-white rounded-3xl border border-slate-100 shadow-sm p-6" data-agn-jutalek="1">
        <div className="flex items-center gap-2 mb-1">
          <Lucide.Percent size={16} className="text-primary" />
          <span className="text-xs font-black text-slate-400 uppercase tracking-wide">Jutalék</span>
        </div>
        {rate == null ? (
          <p className="text-sm text-slate-500 mt-2">A jutalékkulcsot a felvételi iroda állítja be az ügynökséghez.</p>
        ) : (
          <>
            <div className="text-4xl font-black text-slate-900 mt-2" data-agn-kulcs="1">{rate + '%'}</div>
            <p className="text-sm text-slate-500 mt-2 leading-relaxed">
              Ennyi jutalék jár beiratkozott diákonként. A kulcsot a felvételi iroda állítja — a portálon tájékoztatásul látszik, módosítani innen nem lehet.
            </p>
            <ul className="mt-4 space-y-2 text-[13px] text-slate-600">
              <li className="flex items-start gap-2"><Lucide.Dot size={16} className="text-primary flex-none mt-0.5" /><span>A jutalék a BEIRATKOZÁS lezárása után számolható el, nem a jelentkezéskor.</span></li>
              <li className="flex items-start gap-2"><Lucide.Dot size={16} className="text-primary flex-none mt-0.5" /><span>Az elszámolást az iroda nyitja meg időszakonként; a számlát a „Jutalék és számlázás" fülön csatolod.</span></li>
              <li className="flex items-start gap-2"><Lucide.Dot size={16} className="text-primary flex-none mt-0.5" /><span>Kérdés esetén a koordinátor az „Üzenetek" fülön elérhető.</span></li>
            </ul>
          </>
        )}
      </div>

      {/* TÉTELES VÁRHATÓ JUTALÉK */}
      <div className="bg-white rounded-3xl border border-slate-100 shadow-sm overflow-hidden" data-agn-jutalek-tetelek="1">
        <div className="px-6 py-4 border-b border-slate-50">
          <h3 className="font-black text-slate-800">Várható jutalék diákonként</h3>
          <p className="text-[12px] font-semibold text-slate-400 mt-0.5">
            A felvett diákjaid. Az összeg TÁJÉKOZTATÓ, a képzés tandíja és a fenti kulcs alapján — a kötelező érvényű összeg a kiküldött számlán van.
          </p>
        </div>
        {sorok === null ? (
          <div className="h-24 animate-pulse bg-slate-50" />
        ) : tetelek.length === 0 ? (
          <div className="px-6 py-8 text-center text-[13px] font-semibold text-slate-400">
            Még nincs felvett diákod. A jutalék a felvételi döntés és a beiratkozás után számolható el.
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left min-w-[520px]">
              <thead className="bg-slate-50 text-slate-400 text-[10px] font-black uppercase tracking-wider">
                <tr>
                  <th className="px-6 py-3">Diák</th>
                  <th className="px-6 py-3">Képzés</th>
                  <th className="px-6 py-3 text-right">Tandíj / félév</th>
                  <th className="px-6 py-3 text-right">Kulcs</th>
                  <th className="px-6 py-3 text-right">Várható jutalék</th>
                </tr>
              </thead>
              <tbody>
                {tetelek.map(t => (
                  <tr key={t.id} className="border-t border-slate-50" data-agn-tetel={t.id}>
                    <td className="px-6 py-3 text-[13px] font-bold text-slate-700" data-echo-noi18n>{t.nev}</td>
                    <td className="px-6 py-3 text-[13px] text-slate-500" data-echo-noi18n>{t.program}</td>
                    <td className="px-6 py-3 text-[13px] text-slate-500 text-right tabular-nums">{t.tandij ? AGENCY_eur(t.tandij) : '—'}</td>
                    <td className="px-6 py-3 text-[13px] text-slate-500 text-right tabular-nums">{rate + '%'}</td>
                    <td className="px-6 py-3 text-[13px] font-black text-slate-800 text-right tabular-nums">{t.osszeg ? AGENCY_eur(t.osszeg) : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
