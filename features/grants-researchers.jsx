/* ============================================================================
   UniPortal — Kutatók a pályázati modulban (79 + 80 migráció)

   KÉT LISTA, KÉT JELENTÉS:
     • Törzs       — a MI kutatóink: akiket felvettünk, azonosítóval, profillal
     • Felderítés  — akiket a források (OpenAlex, MTMT) az NJE-hez affiliálnak

   A kettő szándékosan nem ugyanaz. A forrás publikációs affiliációt állít, nem
   munkaviszonyt: van a listában, aki évekkel ezelőtt volt itt, van, aki egyetlen
   társszerzős cikk miatt szerepel, és van névazonosságból eredő hibás találat.
   Ezért a felderítésből kézi döntéssel lépnek be a személyek a törzsbe.

   Mérve 2026-09-24: az OpenAlex 727 szerzőt sorol NJE-affiliációval (382
   ORCID-del), az MTMT 306-ot (113 ORCID-del); az átfedés ORCID-en 70.
   ============================================================================ */

const GRTR_api = {
  lista:        (p)        => GRT_rpc('grants_researchers', {
                               p_q: p.q || null, p_tipus: p.tipus || null, p_kar: p.kar || null,
                               p_allapot: p.allapot || null, p_szures: p.szures || null,
                               p_limit: p.limit || 100, p_offset: p.offset || 0 }),
  get:          (id)       => GRT_rpc('grants_researcher_get', { p_id: id }),
  save:         (adat)     => GRT_rpc('grants_researcher_save', { p_adat: adat }),
  skillsSet:    (id, it)   => GRT_rpc('grants_researcher_skills_set', { p_id: id, p_items: it }),
  options:      ()         => GRT_rpc('grants_researcher_options'),
  syncTeachers: ()         => GRT_rpc('grants_researcher_sync_teachers'),
  identityDecide: (c, d)   => GRT_rpc('grants_identity_decide', { p_candidate: c, p_dontes: d }),
  identityClear:  (id, f)  => GRT_rpc('grants_identity_clear', { p_id: id, p_forras: f }),

  felderites:   (p)        => GRT_rpc('grants_discovered', {
                               p_forras: p.forras || null, p_q: p.q || null,
                               p_allapot: p.allapot || null, p_min_mu: p.minMu || null,
                               p_limit: p.limit || 100, p_offset: p.offset || 0 }),
  felderitesStat: ()       => GRT_rpc('grants_discovery_stats'),
  link:         (id, r)    => GRT_rpc('grants_discovered_link', { p_id: id, p_researcher: r || null }),
  ujKutato:     (id, t)    => GRT_rpc('grants_discovered_create', { p_id: id, p_tipus: t || 'kutato' }),
  kihagy:       (id, ok)   => GRT_rpc('grants_discovered_ignore', { p_id: id, p_ok: ok || null }),
  kotegelt:     (p)        => GRT_rpc('grants_discovered_bulk_create', {
                               p_forras: p.forras, p_min_mu: p.minMu,
                               p_csak_utolso_affiliacio: p.csakUtolso !== false,
                               p_limit: p.limit || 200 }),
  // A felderítés és a profilbetöltés Edge Functionben fut.
  felderitesInditas: (forras) => {
    if (!window.sb || !window.sb.functions) throw new Error('A felderítő szolgáltatás nem elérhető.');
    return window.sb.functions.invoke('grants-discover', { body: { forras } })
      .then(async ({ data, error }) => {
        if (error) {
          let r = '';
          try { const t = await error.context.text(); const j = JSON.parse(t); r = j.hiba || t; } catch (e) {}
          throw new Error(r || error.message);
        }
        if (data && data.ok === false) throw new Error(data.hiba || 'A felderítés hibára futott.');
        return data;
      });
  },
};

const GRTR_TIPUS = { oktato: 'oktató', kutato: 'kutató', phd: 'PhD-hallgató',
                     asszisztens: 'asszisztens', egyeb: 'egyéb' };
const GRTR_SKILL = { modszer: 'módszer', infrastruktura: 'infrastruktúra', nyelv: 'nyelv',
                     trl: 'TRL', ipari: 'ipari kapcsolat', szerep: 'szerep', egyeb: 'egyéb' };

/* --- egy kutató profilja ------------------------------------------------- */
function GRTR_ProfilModal({ open, id, onClose, onValtozott }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [ujSkill, setUjSkill] = useState({ kulcs: 'modszer', ertek: '' });

  const betolt = () => GRTR_api.get(id).then(setD).catch(e => setErr(GRT_msg(e)));

  useEffect(() => {
    if (!open || !id) { setD(null); setErr(''); return; }
    setD(null); setErr(''); betolt();
  }, [open, id]);

  const ment = async (mit) => {
    setBusy(true); setErr('');
    try { setD(await GRTR_api.save({ id, ...mit })); onValtozott && onValtozott(); }
    catch (e) { setErr(GRT_msg(e)); }
    finally { setBusy(false); }
  };

  const dontes = async (candId, dont) => {
    setBusy(true); setErr('');
    try { setD(await GRTR_api.identityDecide(candId, dont)); onValtozott && onValtozott(); }
    catch (e) { setErr(GRT_msg(e)); }
    finally { setBusy(false); }
  };

  const kotesTorles = async (forras) => {
    if (!window.confirm('Visszavonod az összekötést? A forrásból betöltött publikációk és témák is törlődnek — '
                        + 'ez szándékos: ha az azonosító más emberhez tartozott, a hamis adat nem maradhat ott.')) return;
    setBusy(true);
    try { setD(await GRTR_api.identityClear(id, forras)); onValtozott && onValtozott(); }
    catch (e) { setErr(GRT_msg(e)); }
    finally { setBusy(false); }
  };

  const skillHozzaad = async () => {
    if (!ujSkill.ertek.trim()) return;
    const uj = (d.kompetenciak || []).concat([{ kulcs: ujSkill.kulcs, ertek: ujSkill.ertek.trim() }]);
    setBusy(true);
    try { setD(await GRTR_api.skillsSet(id, uj)); setUjSkill({ ...ujSkill, ertek: '' }); }
    catch (e) { setErr(GRT_msg(e)); }
    finally { setBusy(false); }
  };
  const skillTorol = async (k, e2) => {
    const uj = (d.kompetenciak || []).filter(x => !(x.kulcs === k && x.ertek === e2));
    setBusy(true);
    try { setD(await GRTR_api.skillsSet(id, uj)); }
    catch (e) { setErr(GRT_msg(e)); }
    finally { setBusy(false); }
  };

  return (
    <UModal open={open} onClose={onClose} max="max-w-4xl"
      icon={<Lucide.UserSearch size={20} />} title={d ? d.nev : 'Kutató'}
      subtitle={d ? [GRTR_TIPUS[d.tipus] || d.tipus, d.kar, d.intezet].filter(Boolean).join(' · ') : ''}>
      {err && (
        <div className="bg-red-50 border border-red-100 rounded-2xl px-4 py-3 text-sm font-bold text-red-600 flex gap-2 mb-4">
          <Lucide.AlertCircle size={16} className="flex-none mt-0.5" /> {err}
        </div>
      )}
      {!err && !d && <div className="space-y-3"><SkeletonBar h={20} /><SkeletonBar /><SkeletonBar w="70%" /></div>}
      {d && (
        <div className="space-y-5">
          {/* hiányosságok: kimondjuk, mit veszít vele */}
          {(d.hianyok || []).length > 0 && (
            <div className="bg-amber-50 border border-amber-100 rounded-2xl px-4 py-3">
              <p className="text-[10px] font-black text-amber-600 uppercase tracking-widest mb-1.5">
                Ami hiányzik a profilból
              </p>
              <ul className="space-y-1">
                {d.hianyok.map((h, i) => (
                  <li key={i} className="text-[11px] text-amber-700 font-medium leading-relaxed">• {h}</li>
                ))}
              </ul>
            </div>
          )}

          <div className="grid gap-4 sm:grid-cols-2">
            <div className="bg-slate-50 rounded-2xl p-4">
              <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Azonosítók</p>
              <dl className="space-y-1.5 text-sm">
                <div className="flex items-center justify-between gap-2">
                  <dt className="text-slate-400 font-medium">ORCID</dt>
                  <dd className="font-bold text-slate-700">
                    {d.orcid
                      ? <a href={'https://orcid.org/' + d.orcid} target="_blank" rel="noopener noreferrer"
                          className="text-primary hover:underline">{d.orcid}</a>
                      : <span className="text-slate-300">nincs</span>}
                  </dd>
                </div>
                <div className="flex items-center justify-between gap-2">
                  <dt className="text-slate-400 font-medium">OpenAlex</dt>
                  <dd className="font-bold text-slate-700 flex items-center gap-1.5">
                    {d.openalex_id
                      ? (<>
                          <a href={'https://openalex.org/' + d.openalex_id} target="_blank" rel="noopener noreferrer"
                            className="text-primary hover:underline">{d.openalex_id}</a>
                          <button onClick={() => kotesTorles('openalex')} disabled={busy}
                            title="Összekötés visszavonása" className="text-slate-400 hover:text-red-500">
                            <Lucide.Unlink size={13} />
                          </button>
                        </>)
                      : <span className="text-slate-300">nincs</span>}
                  </dd>
                </div>
                <div className="flex items-center justify-between gap-2">
                  <dt className="text-slate-400 font-medium">MTMT</dt>
                  <dd className="font-bold text-slate-700 flex items-center gap-1.5">
                    {d.mtmt_id
                      ? (<>
                          <a href={'https://m2.mtmt.hu/gui2/?type=authors&mode=browse&sel=' + d.mtmt_id}
                            target="_blank" rel="noopener noreferrer" className="text-primary hover:underline">
                            {d.mtmt_id}
                          </a>
                          <button onClick={() => kotesTorles('mtmt')} disabled={busy}
                            title="Összekötés visszavonása" className="text-slate-400 hover:text-red-500">
                            <Lucide.Unlink size={13} />
                          </button>
                        </>)
                      : <span className="text-slate-300">nincs</span>}
                  </dd>
                </div>
              </dl>
              <p className="text-[10px] text-slate-400 font-medium mt-2 leading-relaxed">
                Utolsó szinkron: {d.utolso_szinkron ? GRT_dt(d.utolso_szinkron) : 'még nem futott'}
                {d.szinkron_hiba ? ' — hiba: ' + d.szinkron_hiba : ''}
              </p>
            </div>

            <div className="bg-slate-50 rounded-2xl p-4">
              <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Publikációs adat</p>
              <div className="grid grid-cols-2 gap-2 text-sm">
                <div><span className="text-slate-400 font-medium">Mű: </span>
                  <span className="font-black text-slate-700">{d.szamok?.mu ?? 0}</span></div>
                <div><span className="text-slate-400 font-medium">Idézet: </span>
                  <span className="font-black text-slate-700">{d.szamok?.idezet ?? 0}</span></div>
                <div><span className="text-slate-400 font-medium">OpenAlexből: </span>
                  <span className="font-bold text-slate-600">{d.szamok?.mu_openalex ?? 0}</span></div>
                <div><span className="text-slate-400 font-medium">MTMT-ből: </span>
                  <span className="font-bold text-slate-600">{d.szamok?.mu_mtmt ?? 0}</span></div>
                {d.szamok?.elso_ev && (
                  <div className="col-span-2 text-[11px] text-slate-400 font-bold">
                    {d.szamok.elso_ev}–{d.szamok.utolso_ev} közötti termés
                  </div>
                )}
              </div>
            </div>
          </div>

          {/* azonosító-javaslatok */}
          {(d.jeloltek || []).filter(j => j.allapot === 'javasolt').length > 0 && (
            <div>
              <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1.5">
                Összekötési javaslatok — döntés kell
              </p>
              <div className="space-y-2">
                {d.jeloltek.filter(j => j.allapot === 'javasolt').map(j => (
                  <div key={j.id} className="border border-slate-100 rounded-2xl px-4 py-3">
                    <div className="flex items-start justify-between gap-3 flex-wrap">
                      <div className="min-w-0">
                        <div className="flex items-center gap-2 flex-wrap mb-1">
                          <UBadge tone="slate">{j.forras}</UBadge>
                          {j.pontszam && <UBadge tone="blue">{Math.round(Number(j.pontszam) * 100)}%</UBadge>}
                          {j.orcid && <UBadge tone="green">ORCID</UBadge>}
                        </div>
                        <p className="text-sm font-black text-slate-800">{j.nev || j.kulso_id}</p>
                        <p className="text-[11px] text-slate-400 font-bold">
                          {[j.intezmeny, j.mu_db ? j.mu_db + ' mű' : null,
                            j.idezet ? j.idezet + ' idézet' : null].filter(Boolean).join(' · ')}
                        </p>
                        {j.indok && j.indok.figyelmeztetes && (
                          <p className="text-[11px] text-red-600 font-bold mt-1">⚠ {j.indok.figyelmeztetes}</p>
                        )}
                      </div>
                      <div className="flex gap-1.5 flex-none">
                        <button onClick={() => dontes(j.id, 'megerositve')} disabled={busy}
                          className={U_btnPrimary + ' py-2 px-3 text-xs'}>
                          <Lucide.Check size={14} /> Ez ő
                        </button>
                        <button onClick={() => dontes(j.id, 'elvetve')} disabled={busy}
                          className={U_btnGhost + ' py-2 px-3 text-xs'}>
                          <Lucide.X size={14} /> Nem ő
                        </button>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* témaprofil */}
          {(d.temak || []).length > 0 && (
            <div>
              <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1.5">
                Témaprofil (a művekből számolva)
              </p>
              <div className="flex flex-wrap gap-1.5">
                {d.temak.slice(0, 18).map((t, i) => (
                  <span key={i} className="inline-flex items-center gap-1 bg-primary/5 text-primary
                                           rounded-full px-2.5 py-1 text-[11px] font-bold">
                    {t.topic}
                    <span className="text-primary/50">{Number(t.suly).toFixed(1)}</span>
                  </span>
                ))}
              </div>
            </div>
          )}

          {/* kompetenciák — amit publikációból nem lehet kiolvasni */}
          <div>
            <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1.5">
              Kompetenciák — ezt publikációból nem lehet kiolvasni
            </p>
            <div className="flex flex-wrap gap-1.5 mb-2">
              {(d.kompetenciak || []).length === 0 && (
                <p className="text-[11px] text-slate-400 font-medium">Még nincs megadva.</p>
              )}
              {(d.kompetenciak || []).map((k, i) => (
                <span key={i} className="inline-flex items-center gap-1.5 bg-slate-100 text-slate-600
                                         rounded-full px-2.5 py-1 text-[11px] font-bold">
                  <span className="text-slate-400">{GRTR_SKILL[k.kulcs] || k.kulcs}:</span> {k.ertek}
                  <button onClick={() => skillTorol(k.kulcs, k.ertek)} disabled={busy}
                    className="text-slate-400 hover:text-red-500"><Lucide.X size={12} /></button>
                </span>
              ))}
            </div>
            <div className="flex gap-2">
              <select className={U_input + ' py-2 w-auto text-xs'} value={ujSkill.kulcs}
                onChange={e => setUjSkill({ ...ujSkill, kulcs: e.target.value })}>
                {Object.entries(GRTR_SKILL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select>
              <input className={U_input + ' py-2 text-xs'} value={ujSkill.ertek}
                onChange={e => setUjSkill({ ...ujSkill, ertek: e.target.value })}
                onKeyDown={e => { if (e.key === 'Enter') skillHozzaad(); }}
                placeholder="például: végeselem-szimuláció, 3D nyomtató labor, TRL 4-6, angol C1" />
              <button onClick={skillHozzaad} disabled={busy || !ujSkill.ertek.trim()}
                className={U_btnGhost + ' py-2 px-3 text-xs'}><Lucide.Plus size={14} /> Hozzáadás</button>
            </div>
          </div>

          {/* legutóbbi művek */}
          {(d.muvek || []).length > 0 && (
            <div>
              <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1.5">
                Legutóbbi művek ({d.szamok?.mu ?? 0} közül)
              </p>
              <div className="space-y-1 max-h-64 overflow-y-auto">
                {d.muvek.map(w => (
                  <div key={w.id} className="text-[11px] border-b border-slate-50 pb-1">
                    <span className="font-bold text-slate-700">{w.ev || '—'}</span>
                    <span className="text-slate-600"> · {w.cim}</span>
                    {w.forrasnev && <span className="text-slate-400"> · {w.forrasnev}</span>}
                    {w.idezet ? <span className="text-slate-400"> · {w.idezet} idézet</span> : null}
                    <UBadge tone="slate" className="ml-1">{w.forras}</UBadge>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* alapadatok szerkesztése */}
          <div className="border-t border-slate-100 pt-4 grid gap-3 sm:grid-cols-2">
            <UField label="Típus">
              <select className={U_input} value={d.tipus} onChange={e => ment({ tipus: e.target.value })}>
                {Object.entries(GRTR_TIPUS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select>
            </UField>
            <UField label="ORCID" hint="A profil elsődleges azonosítója.">
              <input className={U_input} defaultValue={d.orcid || ''}
                onBlur={e => { if (e.target.value !== (d.orcid || '')) ment({ orcid: e.target.value }); }}
                placeholder="0000-0000-0000-0000" />
            </UField>
            <UField label="Kar"><input className={U_input} defaultValue={d.kar || ''}
              onBlur={e => { if (e.target.value !== (d.kar || '')) ment({ kar: e.target.value }); }} /></UField>
            <UField label="Intézet"><input className={U_input} defaultValue={d.intezet || ''}
              onBlur={e => { if (e.target.value !== (d.intezet || '')) ment({ intezet: e.target.value }); }} /></UField>
          </div>

          <div className="flex flex-wrap gap-4 items-center">
            <label className="flex items-center gap-2 text-xs font-bold text-slate-600">
              <input type="checkbox" checked={!!d.gepi_epites}
                onChange={e => ment({ gepi_epites: e.target.checked })} />
              gépi profilépítés (a kutató kikapcsolhatja)
            </label>
            <label className="flex items-center gap-2 text-xs font-bold text-slate-600">
              <input type="checkbox" checked={!!d.csapatkereses}
                onChange={e => ment({ csapatkereses: e.target.checked })} />
              szerepeljen a belső csapatkeresésben
            </label>
          </div>
          {!d.gepi_epites && (
            <p className="text-[11px] text-amber-700 font-medium">
              A gépi építés kikapcsolva: ez a profil nem frissül és nem kerül javaslatba.
              A meglévő adat megmarad.
            </p>
          )}
        </div>
      )}
    </UModal>
  );
}

/* --- felderített szerző sora -------------------------------------------- */
function GRTR_FelderitesSor({ s, onLink, onUj, onKihagy, busy }) {
  const konflikt = s.javaslat_ok === 'orcid_nevkonflikt';
  return (
    <div className="border border-slate-100 rounded-2xl px-4 py-3">
      <div className="flex items-start justify-between gap-3 flex-wrap">
        <div className="min-w-0">
          <div className="flex items-center gap-2 flex-wrap mb-1">
            <UBadge tone={s.forras === 'openalex' ? 'blue' : 'violet'}>{s.forras}</UBadge>
            {s.orcid && <UBadge tone="green">ORCID</UBadge>}
            {s.utolso_affiliacio === true && <UBadge tone="primary">jelenlegi affiliáció</UBadge>}
            {s.utolso_affiliacio === false && <UBadge tone="slate">korábbi affiliáció</UBadge>}
            {s.allapot === 'osszekotve' && <UBadge tone="green">összekötve</UBadge>}
            {s.allapot === 'kihagyva' && <UBadge tone="slate">kihagyva</UBadge>}
          </div>
          <p className="text-sm font-black text-slate-800">{s.nev || s.kulso_id}</p>
          <p className="text-[11px] text-slate-400 font-bold">
            {[s.mu_db != null ? s.mu_db + ' mű' : null,
              s.idezet != null ? s.idezet + ' idézet' : null,
              s.h_index != null ? 'h-index ' + s.h_index : null,
              s.szervezeti_egyseg].filter(Boolean).join(' · ')}
          </p>
          {(s.temak || []).length > 0 && (
            <p className="text-[11px] text-slate-400 font-medium mt-1 line-clamp-1">
              {(s.temak || []).map(t => t.topic).filter(Boolean).slice(0, 5).join(', ')}
            </p>
          )}
          {s.javasolt_nev && (
            <p className={'text-[11px] font-bold mt-1 ' + (konflikt ? 'text-red-600' : 'text-primary')}>
              {konflikt
                ? '⚠ Az ORCID egyezik ' + s.javasolt_nev + '-val/-vel, de a nevek nem fedik egymást — ellenőrizni kell.'
                : 'Javaslat: ' + s.javasolt_nev + (s.javaslat_ok === 'orcid' ? ' (ORCID alapján)' : ' (név alapján)')}
            </p>
          )}
          {s.kutato_nev && <p className="text-[11px] text-emerald-700 font-bold mt-1">Kutató: {s.kutato_nev}</p>}
        </div>
        {s.allapot === 'uj' && (
          <div className="flex gap-1.5 flex-none flex-wrap justify-end">
            {s.javasolt_id && !konflikt && (
              <button onClick={() => onLink(s.id)} disabled={busy} className={U_btnPrimary + ' py-2 px-3 text-xs'}>
                <Lucide.Link2 size={14} /> Összekötés
              </button>
            )}
            <button onClick={() => onUj(s.id)} disabled={busy} className={U_btnGhost + ' py-2 px-3 text-xs'}>
              <Lucide.UserPlus size={14} /> Új kutató
            </button>
            <button onClick={() => onKihagy(s.id)} disabled={busy} className={U_btnGhost + ' py-2 px-3 text-xs'}>
              <Lucide.EyeOff size={14} /> Kihagyás
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

/* ============================================================================
   A Kutatók nézet
   ============================================================================ */
function GRTR_KutatokView() {
  const [ful, setFul] = useState('torzs');
  const [err, setErr] = useState('');
  const [toast, setToast] = useState('');
  const [busy, setBusy] = useState(false);
  const [opts, setOpts] = useState(null);
  const [stat, setStat] = useState(null);

  // törzs
  const [q, setQ] = useState('');
  const [tipus, setTipus] = useState('');
  const [kar, setKar] = useState('');
  const [szures, setSzures] = useState('');
  const [lista, setLista] = useState(null);
  const [nyitottId, setNyitottId] = useState(null);

  // felderítés
  const [fForras, setFForras] = useState('openalex');
  const [fAllapot, setFAllapot] = useState('uj');
  const [fQ, setFQ] = useState('');
  const [fMinMu, setFMinMu] = useState('');
  const [fLista, setFLista] = useState(null);
  const [kotegMinMu, setKotegMinMu] = useState('5');

  const optsBetolt = () => {
    GRTR_api.options().then(setOpts).catch(e => setErr(GRT_msg(e)));
    GRTR_api.felderitesStat().then(setStat).catch(() => {});
  };
  useEffect(() => { optsBetolt(); }, []);

  const torzsBetolt = () => GRTR_api.lista({ q, tipus, kar, szures, limit: 100 })
    .then(setLista).catch(e => setErr(GRT_msg(e)));
  useEffect(() => {
    if (ful !== 'torzs') return;
    let el = true;
    const t = setTimeout(() => { if (el) torzsBetolt(); }, 300);
    return () => { el = false; clearTimeout(t); };
  }, [ful, q, tipus, kar, szures]);

  const feldBetolt = () => GRTR_api.felderites({
      forras: fForras, allapot: fAllapot, q: fQ,
      minMu: fMinMu ? Number(fMinMu) : null, limit: 100 })
    .then(setFLista).catch(e => setErr(GRT_msg(e)));
  useEffect(() => {
    if (ful !== 'felderites') return;
    let el = true;
    const t = setTimeout(() => { if (el) feldBetolt(); }, 300);
    return () => { el = false; clearTimeout(t); };
  }, [ful, fForras, fAllapot, fQ, fMinMu]);

  const muvelet = async (fn, uzenet) => {
    setBusy(true); setErr('');
    try {
      const r = await fn();
      setToast(typeof uzenet === 'function' ? uzenet(r) : uzenet);
      feldBetolt(); optsBetolt();
      if (ful === 'torzs') torzsBetolt();
    } catch (e) { setErr(GRT_msg(e)); }
    finally { setBusy(false); }
  };

  const sz = (opts && opts.szamok) || {};
  const fstat = (stat && stat.forrasonkent) || {};

  return (
    <div className="space-y-4">
      {err && (
        <div className="bg-red-50 border border-red-100 rounded-2xl px-4 py-3 text-sm font-bold text-red-600 flex gap-2">
          <Lucide.AlertCircle size={16} className="flex-none mt-0.5" /> {err}
        </div>
      )}

      <div className="grid gap-3 sm:grid-cols-4">
        {[
          { c: 'Kutató a törzsben', v: sz.osszes, tone: 'text-slate-700' },
          { c: 'Azonosítóval összekötve', v: sz.osszekotve, tone: 'text-emerald-600' },
          { c: 'Döntésre váró javaslat', v: sz.jelolt, tone: 'text-amber-600' },
          { c: 'Betöltött publikáció', v: sz.mu, tone: 'text-sky-600' },
        ].map(k => (
          <div key={k.c} className="bg-white border border-slate-100 rounded-2xl p-4">
            <p className={'text-2xl font-black ' + k.tone}>{k.v ?? 0}</p>
            <p className="text-[10px] font-black text-slate-400 uppercase tracking-wider mt-0.5">{k.c}</p>
          </div>
        ))}
      </div>

      <div className="flex items-center gap-2 flex-wrap">
        {[{ id: 'torzs', cim: 'Törzs', ikon: <Lucide.Users size={14} /> },
          { id: 'felderites', cim: 'Felderítés', ikon: <Lucide.Radar size={14} /> }].map(t => (
          <button key={t.id} onClick={() => setFul(t.id)}
            className={'inline-flex items-center gap-1.5 px-4 py-2 rounded-xl text-xs font-black transition-all '
                       + (ful === t.id ? 'bg-primary text-white'
                                       : 'bg-white border border-slate-100 text-slate-500 hover:border-slate-200')}>
            {t.ikon} {t.cim}
          </button>
        ))}
        <div className="flex-1" />
        {ful === 'torzs' && (
          <button onClick={() => muvelet(() => GRTR_api.syncTeachers(),
                                         r => `Törzs feltöltve: ${r.uj} új kutató (összesen ${r.osszes}).`)}
            disabled={busy} className={U_btnGhost + ' py-2 px-3 text-xs'}>
            <Lucide.UserCog size={14} /> Feltöltés az oktatói nyilvántartásból
          </button>
        )}
      </div>

      {ful === 'torzs' && (
        <>
          <div className="bg-white border border-slate-100 rounded-2xl p-4 grid gap-3 sm:grid-cols-4">
            <div className="relative sm:col-span-2">
              <Lucide.Search size={16} className="absolute left-3.5 top-1/2 -translate-y-1/2 text-slate-300" />
              <input className={U_input + ' pl-10'} value={q} onChange={e => setQ(e.target.value)}
                placeholder="Keresés névre, ORCID-re, e-mailre…" />
            </div>
            <select className={U_input} value={tipus} onChange={e => setTipus(e.target.value)}>
              <option value="">Minden típus</option>
              {Object.entries(GRTR_TIPUS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
            <select className={U_input} value={szures} onChange={e => setSzures(e.target.value)}>
              <option value="">Mind</option>
              <option value="jelolt">Döntésre váró javaslat</option>
              <option value="hianyos">Nincs összekötött azonosító</option>
              <option value="kikapcsolt">Gépi építés kikapcsolva</option>
            </select>
          </div>

          {lista === null ? (
            <div className="space-y-2">{[0, 1, 2, 3].map(i => <SkeletonBar key={i} h={70} />)}</div>
          ) : (lista.sorok || []).length === 0 ? (
            <UEmpty icon={<Lucide.Users size={28} />} title="Nincs kutató a törzsben"
              subtitle="Töltsd fel az oktatói nyilvántartásból, vagy vegyél fel valakit a Felderítés fülön." />
          ) : (
            <div className="space-y-2">
              <p className="text-[11px] font-bold text-slate-400">{lista.mutatva} / {lista.ossz} kutató</p>
              {lista.sorok.map(r => (
                <button key={r.id} type="button" onClick={() => setNyitottId(r.id)}
                  className="w-full text-left border border-slate-100 rounded-2xl px-4 py-3 bg-white
                             hover:border-primary/40 transition-all">
                  <div className="flex items-start justify-between gap-3 flex-wrap">
                    <div className="min-w-0">
                      <div className="flex items-center gap-2 flex-wrap mb-1">
                        <UBadge tone="slate">{GRTR_TIPUS[r.tipus] || r.tipus}</UBadge>
                        {r.orcid && <UBadge tone="green">ORCID</UBadge>}
                        {r.openalex_id && <UBadge tone="blue">OpenAlex</UBadge>}
                        {r.mtmt_id && <UBadge tone="violet">MTMT</UBadge>}
                        {Number(r.jelolt_db) > 0 && <UBadge tone="amber">{r.jelolt_db} javaslat</UBadge>}
                        {!r.gepi_epites && <UBadge tone="slate">kikapcsolva</UBadge>}
                      </div>
                      <p className="text-sm font-black text-slate-800">{r.nev}</p>
                      <p className="text-[11px] text-slate-400 font-bold">
                        {[r.kar, r.intezet, r.mu_db + ' mű', r.topic_db + ' téma'].filter(Boolean).join(' · ')}
                      </p>
                    </div>
                    <div className="text-right flex-none">
                      <p className="text-[11px] font-bold text-slate-400">
                        {r.utolso_szinkron ? GRT_dt(r.utolso_szinkron) : 'nincs szinkron'}
                      </p>
                      {(r.hianyok || []).length > 0 && (
                        <p className="text-[11px] font-black text-amber-600">{r.hianyok.length} hiányosság</p>
                      )}
                    </div>
                  </div>
                </button>
              ))}
            </div>
          )}
        </>
      )}

      {ful === 'felderites' && (
        <>
          <div className="bg-slate-50 rounded-2xl px-4 py-3 flex gap-2.5">
            <Lucide.Info size={15} className="text-slate-400 flex-none mt-0.5" />
            <p className="text-[11px] text-slate-500 font-medium leading-relaxed">
              Ez a lista azt mutatja, kit sorol a forrás az NJE-hez — ami <b>nem ugyanaz</b>, mint hogy
              ki a mai kutatónk. Van, aki évekkel ezelőtt volt itt, és van, aki egyetlen társszerzős cikk
              miatt szerepel. Ezért a törzsbe döntéssel lépnek be: <i>Összekötés</i> meglévő kutatóval,
              <i> Új kutató</i> felvétele, vagy <i>Kihagyás</i>.
            </p>
          </div>

          <div className="bg-white border border-slate-100 rounded-2xl p-4">
            <div className="grid gap-3 sm:grid-cols-4">
              <select className={U_input} value={fForras} onChange={e => setFForras(e.target.value)}>
                <option value="openalex">OpenAlex ({(fstat.openalex || {}).osszes ?? 0})</option>
                <option value="mtmt">MTMT ({(fstat.mtmt || {}).osszes ?? 0})</option>
              </select>
              <select className={U_input} value={fAllapot} onChange={e => setFAllapot(e.target.value)}>
                <option value="uj">Döntésre vár</option>
                <option value="osszekotve">Összekötve</option>
                <option value="kihagyva">Kihagyva</option>
                <option value="">Mind</option>
              </select>
              <input className={U_input} value={fQ} onChange={e => setFQ(e.target.value)}
                placeholder="Keresés névre, ORCID-re…" />
              <input type="number" min="0" className={U_input} value={fMinMu}
                onChange={e => setFMinMu(e.target.value)} placeholder="legalább ennyi mű" />
            </div>

            {(fstat[fForras] || {}).uj > 0 && (
              <div className="mt-3 pt-3 border-t border-slate-100 flex items-center gap-2 flex-wrap">
                <span className="text-[11px] font-black text-slate-400 uppercase tracking-wider">
                  Kötegelt felvétel:
                </span>
                <span className="text-[11px] font-bold text-slate-500">legalább</span>
                <input type="number" min="0" value={kotegMinMu} onChange={e => setKotegMinMu(e.target.value)}
                  className="w-16 bg-slate-50 border border-slate-100 rounded-lg px-2 py-1 text-xs" />
                <span className="text-[11px] font-bold text-slate-500">mű, jelenlegi affiliációval</span>
                <button disabled={busy}
                  onClick={() => {
                    if (!window.confirm(`Felveszünk minden olyan ${fForras}-szerzőt, akinek legalább `
                        + `${kotegMinMu} műve van, jelenlegi NJE-affiliációval, és nincs rá javaslat. `
                        + 'Akinél javaslat van, azt kihagyja — ott előbb emberi döntés kell.')) return;
                    muvelet(() => GRTR_api.kotegelt({ forras: fForras, minMu: Number(kotegMinMu) || 0 }),
                            r => `${r.felvett} kutató felvéve (törzs: ${r.kutato_db}).`);
                  }}
                  className={U_btnGhost + ' py-1.5 px-3 text-xs'}>
                  <Lucide.UsersRound size={14} /> Felvétel
                </button>
                <span className="text-[11px] text-slate-400 font-medium">
                  {(fstat[fForras] || {}).javaslattal ?? 0} tételnél van javaslat — azok egyenként dőlnek el.
                </span>
              </div>
            )}
          </div>

          {fLista === null ? (
            <div className="space-y-2">{[0, 1, 2, 3].map(i => <SkeletonBar key={i} h={70} />)}</div>
          ) : (fLista.sorok || []).length === 0 ? (
            <UEmpty icon={<Lucide.Radar size={28} />} title="Nincs találat"
              subtitle="Indíts felderítést az Adatforrások fülön, vagy engedd fel a szűrőket." />
          ) : (
            <div className="space-y-2">
              <p className="text-[11px] font-bold text-slate-400">
                {fLista.mutatva} / {fLista.ossz} szerző
                {(fstat[fForras] || {}).orcid != null
                  ? ` · ${(fstat[fForras] || {}).orcid} ORCID-del a forrásban` : ''}
              </p>
              {fLista.sorok.map(s => (
                <GRTR_FelderitesSor key={s.id} s={s} busy={busy}
                  onLink={(id) => muvelet(() => GRTR_api.link(id), r => `Összekötve: ${r.kutato_nev}.`)}
                  onUj={(id) => muvelet(() => GRTR_api.ujKutato(id), r => `Felvéve: ${r.kutato_nev}.`)}
                  onKihagy={(id) => muvelet(() => GRTR_api.kihagy(id, 'nem a mi kutatónk'), 'Kihagyva.')} />
              ))}
            </div>
          )}
        </>
      )}

      <GRTR_ProfilModal open={!!nyitottId} id={nyitottId} onClose={() => setNyitottId(null)}
        onValtozott={() => { torzsBetolt(); optsBetolt(); }} />
      <UToast msg={toast} onDone={() => setToast('')} />
    </div>
  );
}
