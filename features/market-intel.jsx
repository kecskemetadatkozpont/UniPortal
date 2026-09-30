/* ============================================================
   PIACFIGYELŐ — marketing- és versenytársfigyelés (112_market_intel.sql)

   MIT VÁLASZOL MEG
     „Hol és mivel szólítják meg a versenytársaink ugyanazokat a diákokat,
     akikre mi is pályázunk — és mi hol nem vagyunk ott?”

   HONNAN JÖN AZ ADAT
     Kizárólag a 112-es migráció mi_* függvényeiből. Azok maguk ellenőrzik a
     jogosultságot (market_intel); a felület nem az egyetlen védvonal. Ha a
     migráció még nem futott le, a képernyő ezt KIMONDJA.

   MI NINCS ITT — SZÁNDÉKOSAN
     Kommentelő, követő, magánszemély. A modul nyilvános INTÉZMÉNYI
     kommunikációt figyel, aggregált szinten. Becsült hirdetési költés sincs:
     a hirdetéskönyvtár nem ad összeget, egy kitalált szám pedig rosszabb,
     mint a semmi.

   ADAT NÉLKÜL IS HASZNÁLHATÓ
     A Források fül a gyűjtés beindítása ELŐTT is működik: itt lehet felvenni,
     mely intézmény mely csatornáját figyeljük. A betöltő ebből dolgozik.
   ============================================================ */

const MI_rpc = async (nev, args) => {
  if (!window.sb) throw new Error('Nincs adatbázis-kapcsolat.');
  const { data, error } = await window.sb.rpc(nev, args || {});
  if (error) throw error;
  return data;
};
const MI_nincsMigracio = (e) => {
  const m = ((e && e.message) || '') + ((e && e.code) || '');
  return /mi_dashboard|mi_context|mi_sources|schema cache|PGRST202/i.test(m);
};
const MI_hiba = (e) => {
  const m = (e && e.message) || '';
  if (/MI_FORBIDDEN/.test(m)) return 'Ehhez a képernyőhöz piacfigyelő jogosultság kell.';
  if (/MI_NOT_AUTHENTICATED/.test(m)) return 'Jelentkezz be újra.';
  if (/MI_INVALID/.test(m)) return m.replace(/^.*MI_INVALID:\s*/, '');
  if (/MI_NOT_FOUND/.test(m)) return 'Ez a tétel már nem létezik.';
  return m || 'Ismeretlen hiba.';
};

const MI_PLATFORMOK = [
  ['facebook', 'Facebook'], ['instagram', 'Instagram'], ['tiktok', 'TikTok'],
  ['youtube', 'YouTube'], ['linkedin', 'LinkedIn'],
  ['web', 'Weboldal'], ['ads', 'Hirdetéskönyvtár'], ['trends', 'Keresleti index'],
];
const MI_KOROK = [['szuk', 'Szűk kör'], ['bo', 'Bő kör'], ['regionalis', 'Regionális']];
const MI_ABLAKOK = [[14, '14 nap'], [28, '28 nap'], [90, '90 nap']];
const MI_ALLAPOTOK = [['uj', 'Új'], ['folyamatban', 'Folyamatban'], ['lezart', 'Lezárva'], ['nem_erdekes', 'Nem érdekes']];

const MI_cimke = (lista, kod) => { const x = lista.find(p => p[0] === kod); return x ? x[1] : (kod || '—'); };
const MI_szam = (n) => (n === null || n === undefined || n === '') ? '—' : Number(n).toLocaleString('hu-HU');
const MI_datum = (d) => { try { return d ? new Date(d).toLocaleDateString('hu-HU') : '—'; } catch (e) { return '—'; } };
const MI_nap = (d) => { try { return d ? new Date(d).toLocaleDateString('hu-HU', { month: 'short', day: 'numeric' }) : '—'; } catch (e) { return '—'; } };

/* A mintavétel dátuma minden szám mellé. Nem díszítés: a bevonási adatok
   pontossága platformonként más, és a felület ettől lesz értelmezhető. */
function MI_Kartya({ cimke, ertek, utotag, alcim, kiemelt }) {
  return (
    <div className={'rounded-2xl border p-4 ' + (kiemelt ? 'border-primary bg-primary/5' : 'border-slate-100 bg-white')}
         data-mi-kartya={cimke}>
      <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest">{cimke}</p>
      <p className={'text-2xl font-black mt-1 ' + (kiemelt ? 'text-primary' : 'text-slate-800')}>
        {ertek}{utotag && <span className="text-sm font-bold text-slate-400 ml-1">{utotag}</span>}
      </p>
      {alcim && <p className="text-[11px] font-semibold text-slate-400 mt-1">{alcim}</p>}
    </div>
  );
}

/* Heti oszlopok. Szándékosan nem diagramkönyvtárból: három sorozat, kevés
   adatpont — a saját rajz kevesebb, mint a beillesztés. */
function MI_Idosor({ sorok }) {
  if (!sorok || !sorok.length) return null;
  const max = Math.max(1, ...sorok.map(s => Math.max(s.poszt || 0, s.hirdetes || 0, s.jelentkezes || 0)));
  return (
    <div className="flex items-end gap-3 h-40 px-1" data-mi-idosor="1">
      {sorok.map((s, i) => (
        <div key={i} className="flex-1 flex flex-col items-center gap-1.5 min-w-0">
          <div className="w-full flex items-end justify-center gap-1 h-32">
            <div className="w-1/4 bg-slate-200 rounded-t" style={{ height: ((s.poszt || 0) / max * 100) + '%' }} title={'Poszt: ' + (s.poszt || 0)} />
            <div className="w-1/4 bg-violet-300 rounded-t" style={{ height: ((s.hirdetes || 0) / max * 100) + '%' }} title={'Hirdetés: ' + (s.hirdetes || 0)} />
            <div className="w-1/4 bg-primary rounded-t" style={{ height: ((s.jelentkezes || 0) / max * 100) + '%' }} title={'Jelentkezés: ' + (s.jelentkezes || 0)} />
          </div>
          <span className="text-[9px] font-bold text-slate-400 truncate w-full text-center">{MI_nap(s.het)}</span>
        </div>
      ))}
    </div>
  );
}

function MI_Jelmagyarazat() {
  return (
    <div className="flex items-center gap-4 text-[10px] font-bold text-slate-400">
      <span className="inline-flex items-center gap-1.5"><i className="w-2.5 h-2.5 rounded bg-slate-200 inline-block" />Versenytárs-poszt</span>
      <span className="inline-flex items-center gap-1.5"><i className="w-2.5 h-2.5 rounded bg-violet-300 inline-block" />Új hirdetés</span>
      <span className="inline-flex items-center gap-1.5"><i className="w-2.5 h-2.5 rounded bg-primary inline-block" />A mi jelentkezéseink</span>
    </div>
  );
}

function MI_Doboz({ cim, alcim, jobb, children }) {
  return (
    <div className="bg-white rounded-2xl border border-slate-100 shadow-sm overflow-hidden">
      <div className="p-5 border-b border-slate-50 flex items-start justify-between gap-4">
        <div>
          <h3 className="font-bold text-slate-800">{cim}</h3>
          {alcim && <p className="text-xs text-slate-400 mt-0.5">{alcim}</p>}
        </div>
        {jobb}
      </div>
      {children}
    </div>
  );
}

/* ---- Források: a gyűjtés listája. A betöltő EBBŐL dolgozik. ---- */
function MI_Forrasok({ sorok, onMent, onTorol, busy }) {
  const [szerk, setSzerk] = React.useState(null);   // null | {} | sor
  const ures = { kulcs: '', intezmeny: '', platform: 'instagram', kor: 'szuk', cim: '', orszag: '', sajat: false, aktiv: true, megjegyzes: '', mezo_terkep: {} };
  const mezo = (k, v) => setSzerk(s => ({ ...s, [k]: v }));
  // A mezőtérkép JSON. Szövegként szerkesztjük, mert a gyűjtő mezőnevei
  // Actoronként mások — és a hibás JSON-t KIMONDJUK, nem csendben eldobjuk.
  const [terkepSzoveg, setTerkepSzoveg] = React.useState('');
  const [terkepHiba, setTerkepHiba] = React.useState('');
  React.useEffect(() => {
    if (!szerk) return;
    const t = szerk.mezo_terkep;
    setTerkepSzoveg(t && Object.keys(t).length ? JSON.stringify(t, null, 2) : '');
    setTerkepHiba('');
  }, [szerk && szerk.kulcs, szerk && szerk.id]);
  const terkepOlvas = () => {
    const sz = (terkepSzoveg || '').trim();
    if (!sz) return {};
    try {
      const j = JSON.parse(sz);
      if (!j || typeof j !== 'object' || Array.isArray(j)) throw new Error('nem objektum');
      return j;
    } catch (e) { return null; }
  };

  return (
    <MI_Doboz cim="Amit figyelünk" alcim="Egy sor = egy intézmény egy csatornája. A kulcs stabil azonosító: ezzel hivatkozik rá a betöltő."
      jobb={<button onClick={() => setSzerk(ures)} className={U_btnPrimary + ' text-xs'} data-mi-uj-forras="1">
        <Lucide.Plus size={15} /> Új forrás
      </button>}>
      {!sorok.length
        ? <UEmpty icon={<Lucide.Radar size={28} />} title="Még nincs figyelt forrás"
            subtitle="Vedd fel az intézményeket és a csatornáikat. Ehhez nem kell a gyűjtés — a lista a betöltés beállításának az alapja." />
        : (
          <div className="overflow-x-auto">
            <table className="w-full text-left">
              <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                <tr>
                  <th className="px-5 py-3">Intézmény</th>
                  <th className="px-5 py-3">Csatorna</th>
                  <th className="px-5 py-3">Kör</th>
                  <th className="px-5 py-3">Kulcs</th>
                  <th className="px-5 py-3">Utolsó adat</th>
                  <th className="px-5 py-3"></th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-50">
                {sorok.map(s => (
                  <tr key={s.id} className="hover:bg-slate-50/60" data-mi-forras-sor={s.kulcs}>
                    <td className="px-5 py-3">
                      <span className="font-bold text-slate-700 text-sm">{s.intezmeny}</span>
                      {s.sajat && <UBadge tone="primary" className="ml-2">saját</UBadge>}
                      {!s.aktiv && <UBadge tone="slate" className="ml-2">szünetel</UBadge>}
                    </td>
                    <td className="px-5 py-3 text-sm text-slate-600">{MI_cimke(MI_PLATFORMOK, s.platform)}</td>
                    <td className="px-5 py-3 text-sm text-slate-600">{MI_cimke(MI_KOROK, s.kor)}</td>
                    <td className="px-5 py-3 text-[11px] font-mono text-slate-400">{s.kulcs}</td>
                    <td className="px-5 py-3 text-sm">
                      {s.utolso_adat
                        ? <span className="text-slate-600">{MI_datum(s.utolso_adat)}</span>
                        : <span className="text-amber-600 font-bold text-xs">még nincs</span>}
                    </td>
                    <td className="px-5 py-3 text-right whitespace-nowrap">
                      <button onClick={() => setSzerk(s)} className="text-xs font-bold text-slate-500 hover:text-primary px-2">Szerkesztés</button>
                      <button onClick={() => onTorol(s)} className="text-xs font-bold text-slate-400 hover:text-red-600 px-2">Törlés</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

      <UModal open={!!szerk} onClose={() => setSzerk(null)} max="max-w-xl"
        title="Figyelt forrás" subtitle="A kulcs később nem változik — a betöltés erre hivatkozik." icon={<Lucide.Radar size={20} />}>
        {szerk && (
          <div className="space-y-4">
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <UField label="Intézmény">
                <input className={U_input} value={szerk.intezmeny || ''} data-mi-intezmeny="1"
                  onChange={e => mezo('intezmeny', e.target.value)} placeholder="Óbudai Egyetem" />
              </UField>
              <UField label="Csatorna">
                <select className={U_input} value={szerk.platform || 'instagram'} data-mi-platform="1"
                  onChange={e => mezo('platform', e.target.value)}>
                  {MI_PLATFORMOK.map(([k, c]) => <option key={k} value={k}>{c}</option>)}
                </select>
              </UField>
              <UField label="Kulcs" hint="Kisbetű, kötőjel — például obuda-instagram">
                <input className={U_input} value={szerk.kulcs || ''} data-mi-kulcs="1"
                  onChange={e => mezo('kulcs', e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, '-'))} />
              </UField>
              <UField label="Kör">
                <select className={U_input} value={szerk.kor || 'szuk'} onChange={e => mezo('kor', e.target.value)}>
                  {MI_KOROK.map(([k, c]) => <option key={k} value={k}>{c}</option>)}
                </select>
              </UField>
            </div>
            <UField label="Cím" hint="Az oldal vagy a figyelt aloldal teljes címe.">
              <input className={U_input} value={szerk.cim || ''} onChange={e => mezo('cim', e.target.value)} placeholder="https://…" />
            </UField>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <UField label="Ország" hint="Csak keresleti indexnél kell.">
                <input className={U_input} value={szerk.orszag || ''} onChange={e => mezo('orszag', e.target.value)} />
              </UField>
              <div className="flex items-end gap-5 pb-3">
                <label className="inline-flex items-center gap-2 text-sm font-bold text-slate-600">
                  <input type="checkbox" checked={!!szerk.sajat} data-mi-sajat="1"
                    onChange={e => mezo('sajat', e.target.checked)} /> A mi csatornánk
                </label>
                <label className="inline-flex items-center gap-2 text-sm font-bold text-slate-600">
                  <input type="checkbox" checked={szerk.aktiv !== false} onChange={e => mezo('aktiv', e.target.checked)} /> Aktív
                </label>
              </div>
            </div>
            <UField label="Mezőtérkép (nem kötelező)"
              hint="Melyik gyűjtő-mező melyik a miénk. Példa: {&quot;kovetok&quot;: &quot;followersCount&quot;, &quot;bevonas&quot;: &quot;likesCount&quot;}. Üresen hagyva a betöltő a szokásos mezőneveket próbálja.">
              <textarea className={U_input + ' font-mono text-xs h-24'} data-mi-terkep="1"
                value={terkepSzoveg} onChange={e => { setTerkepSzoveg(e.target.value); setTerkepHiba(''); }}
                placeholder={'{\n  "kovetok": "followersCount"\n}'} />
            </UField>
            {terkepHiba && <p className="text-xs font-bold text-red-600" data-mi-terkep-hiba="1">{terkepHiba}</p>}

            <div className="flex justify-end gap-2 pt-2">
              <button onClick={() => setSzerk(null)} className="px-5 py-3 rounded-xl font-bold text-sm text-slate-500 hover:bg-slate-50">Mégse</button>
              <button disabled={busy} data-mi-forras-ment="1" className={U_btnPrimary + ' disabled:opacity-50'}
                onClick={async () => {
                  const t = terkepOlvas();
                  if (t === null) { setTerkepHiba(NY_t('A mezőtérkép nem érvényes JSON — javítsd, vagy hagyd üresen.')); return; }
                  const ok = await onMent({ ...szerk, mezo_terkep: t });
                  if (ok) setSzerk(null);
                }}>
                {busy ? 'Mentés…' : 'Mentés'}
              </button>
            </div>
          </div>
        )}
      </UModal>
    </MI_Doboz>
  );
}

const MarketIntelView = ({ user }) => {
  const [ablak, setAblak] = React.useState(28);
  const [orszag, setOrszag] = React.useState('');
  const [kor, setKor] = React.useState('');
  const [ful, setFul] = React.useState('attekintes');
  const [adat, setAdat] = React.useState(null);
  const [forrasok, setForrasok] = React.useState([]);
  const [ctx, setCtx] = React.useState(null);
  const [toltes, setToltes] = React.useState(true);
  const [hiba, setHiba] = React.useState('');
  const [nincsModul, setNincsModul] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [lap, setLap] = React.useState(null);   // intézmény-lap

  const betolt = React.useCallback(async () => {
    setToltes(true); setHiba('');
    try {
      const [c, d, f] = await Promise.all([
        MI_rpc('mi_context'),
        MI_rpc('mi_dashboard', { p_napok: ablak, p_orszag: orszag || null, p_kor: kor || null }),
        MI_rpc('mi_sources'),
      ]);
      setCtx(c); setAdat(d); setForrasok(f || []); setNincsModul(false);
    } catch (e) {
      if (MI_nincsMigracio(e)) setNincsModul(true); else setHiba(MI_hiba(e));
    } finally { setToltes(false); }
  }, [ablak, orszag, kor]);

  React.useEffect(() => { betolt(); }, [betolt]);

  const forrasMent = async (sor) => {
    setBusy(true);
    try { await MI_rpc('mi_source_save', { p: sor }); await betolt(); return true; }
    catch (e) { NY_alert(MI_hiba(e)); return false; }
    finally { setBusy(false); }
  };
  const forrasTorol = async (sor) => {
    if (!window.confirm(NY_t('Biztosan törlöd ezt a forrást? A hozzá gyűjtött adat is törlődik.'))) return;
    try { await MI_rpc('mi_source_delete', { p_id: sor.id }); await betolt(); }
    catch (e) { NY_alert(MI_hiba(e)); }
  };
  const riasztasAllit = async (r, allapot) => {
    try { await MI_rpc('mi_alert_set', { p_id: r.id, p_allapot: allapot }); await betolt(); }
    catch (e) { NY_alert(MI_hiba(e)); }
  };
  const intezmenyLap = async (nev) => {
    try { setLap({ intezmeny: nev, toltes: true }); setLap(await MI_rpc('mi_institution', { p_intezmeny: nev, p_napok: 90 })); }
    catch (e) { setLap(null); NY_alert(MI_hiba(e)); }
  };

  if (nincsModul) {
    return (
      <div className="bg-white rounded-2xl border border-slate-100 shadow-sm">
        <UEmpty icon={<Lucide.DatabaseZap size={28} />} title="A piacfigyelő adatbázisa még nincs telepítve"
          subtitle="A 112_market_intel.sql migráció még nem futott le ezen a példányon. Amíg nem fut le, ez a képernyő nem tud adatot mutatni." />
      </div>
    );
  }

  const k = (adat && adat.kartyak) || {};
  const orszagLista = ((adat && adat.orszagok) || []).map(o => o.orszag).filter(Boolean);
  const FULEK = [
    ['attekintes', 'Áttekintés'], ['versenytarsak', 'Versenytársak'], ['hirdetesek', 'Hirdetések'],
    ['orszagok', 'Országok'], ['riasztasok', 'Riasztások'], ['forrasok', 'Források'],
  ];

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500" data-mi-nezet="1">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h2 className="text-2xl font-black text-slate-800">Piacfigyelő</h2>
          <p className="text-sm text-slate-400">Mit csinál a mezőny, és mi jön be nekünk — ugyanarra a hétre.</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <select className="bg-white border border-slate-100 rounded-xl px-3 py-2 text-xs font-bold text-slate-600"
            value={ablak} onChange={e => setAblak(Number(e.target.value))} data-mi-ablak="1" aria-label="Időszak">
            {MI_ABLAKOK.map(([v, c]) => <option key={v} value={v}>{c}</option>)}
          </select>
          <select className="bg-white border border-slate-100 rounded-xl px-3 py-2 text-xs font-bold text-slate-600"
            value={orszag} onChange={e => setOrszag(e.target.value)} data-mi-orszag="1" aria-label="Forrásország">
            <option value="">Minden ország</option>
            {orszagLista.map(o => <option key={o} value={o}>{o}</option>)}
          </select>
          <select className="bg-white border border-slate-100 rounded-xl px-3 py-2 text-xs font-bold text-slate-600"
            value={kor} onChange={e => setKor(e.target.value)} data-mi-kor="1" aria-label="Kör">
            <option value="">Minden kör</option>
            {MI_KOROK.map(([v, c]) => <option key={v} value={v}>{c}</option>)}
          </select>
        </div>
      </div>

      {hiba && <div className="bg-red-50 border border-red-100 text-red-700 rounded-2xl px-5 py-3 text-sm font-bold">{hiba}</div>}

      <div className="flex gap-1 overflow-x-auto pb-1" data-mi-fulsav="1">
        {FULEK.map(([k2, c]) => (
          <button key={k2} onClick={() => setFul(k2)} data-mi-ful={k2}
            className={'px-4 py-2 rounded-xl text-xs font-bold whitespace-nowrap transition-all ' +
              (ful === k2 ? 'bg-slate-900 text-white' : 'text-slate-500 hover:bg-slate-100')}>
            {c}{k2 === 'riasztasok' && adat && adat.riasztasok && adat.riasztasok.length > 0 &&
              <span className="ml-1.5 px-1.5 py-0.5 rounded-md bg-amber-100 text-amber-700 text-[10px]">{adat.riasztasok.length}</span>}
          </button>
        ))}
      </div>

      {toltes && <p className="text-sm text-slate-400 font-bold">Betöltés…</p>}

      {!toltes && ctx && !ctx.adat_van && ful !== 'forrasok' && (
        <div className="bg-amber-50 border border-amber-100 rounded-2xl p-5">
          <p className="font-bold text-amber-900 text-sm">Még nincs begyűjtött adat</p>
          <p className="text-xs text-amber-800 mt-1">
            A táblák a helyükön vannak, de a betöltő még nem hozott semmit. Addig is vedd fel a Források fülön,
            mely intézmények mely csatornáit figyeljük — a gyűjtés ebből a listából dolgozik.
          </p>
        </div>
      )}

      {ful === 'attekintes' && !toltes && (
        <div className="space-y-6">
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
            <MI_Kartya cimke="Részesedés" ertek={k.reszesedes === null || k.reszesedes === undefined ? '—' : k.reszesedes} utotag={k.reszesedes != null ? '%' : ''} alcim="a mezőny bevonásából" />
            <MI_Kartya cimke="Követő" ertek={(k.koveto_valtozas > 0 ? '+' : '') + MI_szam(k.koveto_valtozas)} alcim="a saját csatornáinkon" />
            <MI_Kartya cimke="Aktív hirdetés" ertek={MI_szam(k.aktiv_hirdetes)} alcim="a figyelt mezőnyben" />
            <MI_Kartya cimke="Jelentkezés" ertek={MI_szam(k.jelentkezes)} alcim="ebben az időszakban" kiemelt />
          </div>

          <MI_Doboz cim="Aktivitás és jelentkezés egy időtengelyen"
            alcim="Versenytárs-posztok és új hirdetések hetente, mellettük a mi jelentkezéseink ugyanarra a hétre."
            jobb={<MI_Jelmagyarazat />}>
            <div className="p-5">
              {adat && adat.idosor && adat.idosor.length
                ? <MI_Idosor sorok={adat.idosor} />
                : <p className="text-sm text-slate-400 text-center py-8">Ehhez az időszakhoz még nincs adat.</p>}
            </div>
          </MI_Doboz>

          {adat && adat.nema_forrasok && adat.nema_forrasok.length > 0 && (
            <div className="bg-white rounded-2xl border border-amber-200 p-5" data-mi-nema="1">
              <p className="font-bold text-slate-800 text-sm flex items-center gap-2">
                <Lucide.AlertCircle size={16} className="text-amber-500" />
                Két napja nem hoz adatot {adat.nema_forrasok.length} forrás
              </p>
              <p className="text-xs text-slate-500 mt-1">
                A gyűjtés ilyenkor csendben nullát mutatna. Ellenőrizd a forrást a Források fülön.
              </p>
              <div className="flex flex-wrap gap-1.5 mt-3">
                {adat.nema_forrasok.map(f => (
                  <span key={f.kulcs} className="px-2 py-1 rounded-lg bg-amber-50 text-amber-800 text-[11px] font-bold">
                    {f.intezmeny} · {MI_cimke(MI_PLATFORMOK, f.platform)}
                  </span>
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      {ful === 'versenytarsak' && !toltes && (
        <MI_Doboz cim="Versenytárs-tábla" alcim="Sorra kattintva megnyílik az intézmény lapja.">
          {!(adat && adat.intezmenyek && adat.intezmenyek.length)
            ? <UEmpty icon={<Lucide.Building2 size={28} />} title="Nincs figyelt intézmény" subtitle="A Források fülön vedd fel őket." />
            : (
              <div className="overflow-x-auto">
                <table className="w-full text-left">
                  <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                    <tr>
                      <th className="px-5 py-3">Intézmény</th>
                      <th className="px-5 py-3">Kör</th>
                      <th className="px-5 py-3">Csatorna</th>
                      <th className="px-5 py-3">Követő</th>
                      <th className="px-5 py-3">Poszt</th>
                      <th className="px-5 py-3">Átlagos bevonás</th>
                      <th className="px-5 py-3">Aktív hirdetés</th>
                      <th className="px-5 py-3">Utolsó poszt</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-50">
                    {adat.intezmenyek.map(s => (
                      <tr key={s.intezmeny} onClick={() => intezmenyLap(s.intezmeny)}
                        className="hover:bg-slate-50 cursor-pointer" data-mi-intezmeny-sor={s.intezmeny}>
                        <td className="px-5 py-3 font-bold text-slate-700 text-sm">
                          {s.intezmeny}{s.sajat && <UBadge tone="primary" className="ml-2">mi</UBadge>}
                        </td>
                        <td className="px-5 py-3 text-xs text-slate-500">{MI_cimke(MI_KOROK, s.kor)}</td>
                        <td className="px-5 py-3 text-sm text-slate-600">{MI_szam(s.csatorna_db)}</td>
                        <td className="px-5 py-3 text-sm text-slate-600 tabular-nums">{MI_szam(s.koveto)}</td>
                        <td className="px-5 py-3 text-sm text-slate-600 tabular-nums">{MI_szam(s.poszt)}</td>
                        <td className="px-5 py-3 text-sm text-slate-600 tabular-nums">{MI_szam(s.bevonas)}</td>
                        <td className="px-5 py-3 text-sm text-slate-600 tabular-nums">{MI_szam(s.hirdetes)}</td>
                        <td className="px-5 py-3 text-xs text-slate-400">{MI_datum(s.utolso_poszt)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
        </MI_Doboz>
      )}

      {ful === 'hirdetesek' && !toltes && (
        <MI_Doboz cim="Hirdetés-fal" alcim="Ami 30 napnál tovább fut, az náluk működik. Becsült költést szándékosan nem mutatunk.">
          {!(adat && adat.hirdetesek && adat.hirdetesek.length)
            ? <UEmpty icon={<Lucide.Megaphone size={28} />} title="Nincs hirdetés ebben az időszakban" />
            : (
              <div className="p-5 grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
                {adat.hirdetesek.map(h => (
                  <div key={h.id} className="rounded-2xl border border-slate-100 p-4" data-mi-hirdetes={h.id}>
                    <div className="flex items-center justify-between gap-2">
                      <span className="font-bold text-slate-700 text-sm truncate">{h.intezmeny}</span>
                      <UBadge tone={h.napok >= 30 ? 'green' : 'slate'}>{h.napok} nap</UBadge>
                    </div>
                    {h.kreativ && <p className="text-xs text-slate-500 mt-2 line-clamp-3">{h.kreativ}</p>}
                    <div className="flex flex-wrap gap-1 mt-3">
                      {(h.orszagok || []).map(o => (
                        <span key={o} className="px-1.5 py-0.5 rounded bg-slate-100 text-slate-600 text-[10px] font-bold">{o}</span>
                      ))}
                    </div>
                    <p className="text-[10px] text-slate-400 mt-2">
                      {MI_cimke(MI_PLATFORMOK, h.platform)} · {MI_datum(h.elso_latas)} – {MI_datum(h.utolso_latas)}
                    </p>
                  </div>
                ))}
              </div>
            )}
        </MI_Doboz>
      )}

      {ful === 'orszagok' && !toltes && (
        <MI_Doboz cim="Országtábla" alcim="Ahol a kereslet és a versenytárs célzása magas, a mi jelentkezőszámunk viszont alacsony — ott van tennivaló.">
          {!(adat && adat.orszagok && adat.orszagok.length)
            ? <UEmpty icon={<Lucide.Globe size={28} />} title="Nincs országadat" />
            : (
              <div className="overflow-x-auto">
                <table className="w-full text-left">
                  <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                    <tr>
                      <th className="px-5 py-3">Ország</th>
                      <th className="px-5 py-3">Kereslet</th>
                      <th className="px-5 py-3">Versenytárs-célzás</th>
                      <th className="px-5 py-3">A mi jelentkezőink</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-50">
                    {adat.orszagok.map(o => (
                      <tr key={o.orszag} className="hover:bg-slate-50/60" data-mi-orszag-sor={o.orszag}>
                        <td className="px-5 py-3 font-bold text-slate-700 text-sm">{o.orszag}</td>
                        <td className="px-5 py-3 text-sm text-slate-600 tabular-nums">{MI_szam(o.kereslet)}</td>
                        <td className="px-5 py-3 text-sm text-slate-600 tabular-nums">{MI_szam(o.celzas)}</td>
                        <td className="px-5 py-3 text-sm font-bold text-slate-800 tabular-nums">{MI_szam(o.jelentkezes)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
        </MI_Doboz>
      )}

      {ful === 'riasztasok' && !toltes && (
        <MI_Doboz cim="Riasztások" alcim="Feladatok, nem értesítések: mindegyiket valaki lezárja.">
          {!(adat && adat.riasztasok && adat.riasztasok.length)
            ? <UEmpty icon={<Lucide.BellOff size={28} />} title="Nincs nyitott riasztás" subtitle="Ami keletkezik, itt jelenik meg." />
            : (
              <div className="divide-y divide-slate-50">
                {adat.riasztasok.map(r => (
                  <div key={r.id} className="p-5 flex items-start justify-between gap-4" data-mi-riasztas={r.id}>
                    <div className="min-w-0">
                      <p className="font-bold text-slate-800 text-sm flex items-center gap-2">
                        <span className={'w-2 h-2 rounded-full ' + (r.sulyossag === 'surgos' ? 'bg-red-500' : r.sulyossag === 'figyelem' ? 'bg-amber-500' : 'bg-slate-300')} />
                        {r.cim}
                      </p>
                      {r.reszlet && <p className="text-xs text-slate-500 mt-1">{r.reszlet}</p>}
                      <p className="text-[10px] text-slate-400 mt-1">{MI_datum(r.keletkezett)} · {MI_cimke(MI_ALLAPOTOK, r.allapot)}</p>
                    </div>
                    <div className="flex gap-1 flex-none">
                      {r.allapot === 'uj' && (
                        <button onClick={() => riasztasAllit(r, 'folyamatban')} data-mi-riasztas-folyamat={r.id}
                          className="text-[11px] font-bold text-slate-500 hover:text-primary px-2 py-1">Elvállalom</button>
                      )}
                      <button onClick={() => riasztasAllit(r, 'lezart')} data-mi-riasztas-lezar={r.id}
                        className="text-[11px] font-bold text-slate-500 hover:text-emerald-600 px-2 py-1">Lezárás</button>
                      <button onClick={() => riasztasAllit(r, 'nem_erdekes')}
                        className="text-[11px] font-bold text-slate-400 hover:text-slate-700 px-2 py-1">Nem érdekes</button>
                    </div>
                  </div>
                ))}
              </div>
            )}
        </MI_Doboz>
      )}

      {ful === 'forrasok' && !toltes && (
        <MI_Forrasok sorok={forrasok} onMent={forrasMent} onTorol={forrasTorol} busy={busy} />
      )}

      <UModal open={!!lap} onClose={() => setLap(null)} max="max-w-3xl"
        title={(lap && lap.intezmeny) || ''} subtitle="Az elmúlt 90 nap" icon={<Lucide.Building2 size={20} />}>
        {lap && lap.toltes && <p className="text-sm text-slate-400">Betöltés…</p>}
        {lap && !lap.toltes && (
          <div className="space-y-5">
            <div>
              <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Csatornák</p>
              <div className="flex flex-wrap gap-2">
                {(lap.csatornak || []).map(c => (
                  <span key={c.kulcs} className="px-2.5 py-1.5 rounded-xl border border-slate-100 text-xs font-bold text-slate-600">
                    {MI_cimke(MI_PLATFORMOK, c.platform)} · {MI_szam(c.koveto)}
                  </span>
                ))}
                {!(lap.csatornak || []).length && <span className="text-xs text-slate-400">—</span>}
              </div>
            </div>
            <div>
              <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Legjobban teljesítő posztok</p>
              {!(lap.posztok || []).length ? <p className="text-xs text-slate-400">Nincs adat.</p> : (
                <div className="divide-y divide-slate-50 border border-slate-100 rounded-xl">
                  {lap.posztok.map((p, i) => (
                    <div key={i} className="px-4 py-2.5 flex items-center justify-between gap-3">
                      <span className="text-xs text-slate-600 truncate">
                        {MI_datum(p.kelt)} · {p.formatum || '—'}{p.nyelv ? ' · ' + p.nyelv : ''}
                      </span>
                      <span className="text-xs font-bold text-slate-800 tabular-nums flex-none">{MI_szam(p.bevonas)}</span>
                    </div>
                  ))}
                </div>
              )}
            </div>
            <div>
              <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Weboldal-változások</p>
              {!(lap.valtozasok || []).length ? <p className="text-xs text-slate-400">Nincs változás.</p> : (
                <div className="space-y-1.5">
                  {lap.valtozasok.map((v, i) => (
                    <p key={i} className="text-xs text-slate-600">
                      <span className="font-bold">{v.mezo}</span>: {v.regi || '—'} → {v.uj || '—'}
                      <span className="text-slate-400"> ({MI_datum(v.eszlelve)})</span>
                    </p>
                  ))}
                </div>
              )}
            </div>
          </div>
        )}
      </UModal>
    </div>
  );
};
