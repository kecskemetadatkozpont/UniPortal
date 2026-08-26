/* ===========================================================================
   roles.jsx — Szerepkörök szerkesztése (szuperadmin)

   Eddig a szerepkör -> menüpont leképezés az app.jsx-ben volt beégetve, tehát
   egy szerepkör átalakításához kódot kellett módosítani és deployolni. Innentől
   a táblából jön, és itt szerkeszthető.

   AMIT NEM LEHET, ÉS MIÉRT
     A SUPERADMIN hozzáférése nem szerkeszthető. Nem óvatoskodásból: ha
     elvehető lenne, a szuperadmin ki tudná zárni magát abból a képernyőből is,
     amivel visszaállítaná — és nem maradna út vissza. A szerver is elutasítja,
     nem csak a felület rejti el.

   Adatbázis: 39_role_admin.sql
   =========================================================================== */

const ROLE_PGERR = {
  '42501':   'Ehhez a művelethez nincs jogosultsága.',
  '23505':   'Ilyen kódú szerepkör már van.',
  '42P01':   'A modul táblái hiányoznak — a 39_role_admin.sql még nem futott le.',
  '42883':   'A modul függvényei hiányoznak — a 39_role_admin.sql még nem futott le.',
  'PGRST205':'A modul táblái hiányoznak — a 39_role_admin.sql még nem futott le.',
  'PGRST202':'A modul függvényei hiányoznak — a 39_role_admin.sql még nem futott le.',
};

function ROLE_msg(e) {
  if (!e) return 'Ismeretlen hiba.';
  const raw = String(e.message || e.details || e.hint || e);
  const code = e.code || (e.error && e.error.code);
  if (/[őűáéíóöúüÁÉÍÓÖŐÚÜŰ]/.test(raw) && raw.length > 12) return raw;
  if (code && ROLE_PGERR[code]) return ROLE_PGERR[code];
  for (const k in ROLE_PGERR) { if (raw.indexOf(k) >= 0) return ROLE_PGERR[k]; }
  if (/Could not find the (table|function)|schema cache/i.test(raw)) {
    return 'A modul még nem érhető el — a 39_role_admin.sql nem futott le.';
  }
  return raw || 'Ismeretlen hiba.';
}

async function ROLE_rpc(name, args) {
  if (!window.sb) throw new Error('Nincs adatbázis-kapcsolat.');
  const { data, error } = await window.sb.rpc(name, args || {});
  if (error) throw error;
  return data;
}

const ROLE_api = {
  list: async () => {
    if (!window.sb) return [];
    const { data, error } = await window.sb.from('role_definition').select('*').order('sorrend');
    if (error) throw error;
    return data || [];
  },
  perms: async () => {
    if (!window.sb) return [];
    const { data, error } = await window.sb.from('role_permission').select('*');
    if (error) throw error;
    return data || [];
  },
  save: (kod, nev, leiras, szin, sorrend, aktiv) =>
    ROLE_rpc('role_save', { p_kod: kod, p_nev: nev ?? null, p_leiras: leiras ?? null,
                            p_szin: szin ?? null, p_sorrend: sorrend ?? null,
                            p_aktiv: aktiv ?? null }),
  setPerm: (kod, permission, ad) =>
    ROLE_rpc('role_permission_set', { p_kod: kod, p_permission: permission, p_ad: ad }),
  remove: (kod) => ROLE_rpc('role_delete', { p_kod: kod }),
};

/* ---------------------------------------------------------------------------
   ROLE_Tab — a Regisztrációk ötödik füle
   --------------------------------------------------------------------------- */
function ROLE_Tab({ rows, user }) {
  const [szerepek, setSzerepek] = useState(null);
  const [jogok, setJogok]       = useState([]);
  const [nyitott, setNyitott]   = useState('');
  const [err, setErr]           = useState('');
  const [ok, setOk]             = useState('');
  const [ujKod, setUjKod]       = useState('');
  const [ujNev, setUjNev]       = useState('');
  const isSuper = !!(user && user.role === 'SUPERADMIN');

  const betolt = React.useCallback(async () => {
    try {
      setErr('');
      const [r, p] = await Promise.all([ROLE_api.list(), ROLE_api.perms()]);
      setSzerepek(r); setJogok(p);
    } catch (e) { setErr(ROLE_msg(e)); setSzerepek([]); }
  }, []);
  useEffect(() => { betolt(); }, [betolt]);

  const jogaiSzerepnek = (kod) => jogok.filter(j => j.role_kod === kod).map(j => j.permission);
  const viselok = (kod) => (rows || []).filter(r => r.role === kod).length;

  const muvelet = async (fn, siker) => {
    try { setErr(''); setOk(''); await fn(); setOk(siker || ''); await betolt(); }
    catch (e) { setErr(ROLE_msg(e)); }
  };

  return (
    <div className="mt-6 space-y-4">
      <p className="text-[12px] text-slate-400 max-w-3xl">
        Itt állítható be, melyik szerepkör mit lát a menüben. A <strong>Superadmin</strong>
        {' '}hozzáférése szándékosan nem szerkeszthető — enélkül ki lehetne zárni magadat
        abból a képernyőből is, amivel visszaállítanád.
      </p>

      {err && (
        <div className="flex items-start gap-2 bg-red-50 border border-red-200 text-red-700 rounded-xl px-4 py-3 text-sm font-semibold">
          <Lucide.AlertCircle size={16} className="mt-0.5 flex-none" />
          <span className="flex-1">{err}</span>
          <button onClick={() => setErr('')} className="text-red-400 hover:text-red-700"><Lucide.X size={14} /></button>
        </div>
      )}
      {ok && (
        <div className="flex items-start gap-2 bg-emerald-50 border border-emerald-200 text-emerald-700 rounded-xl px-4 py-3 text-sm font-semibold">
          <Lucide.CheckCircle2 size={16} className="mt-0.5 flex-none" />
          <span className="flex-1">{ok}</span>
          <button onClick={() => setOk('')} className="text-emerald-500 hover:text-emerald-700"><Lucide.X size={14} /></button>
        </div>
      )}

      {szerepek === null && <div className="text-sm text-slate-400 py-6">Betöltés…</div>}

      <div className="space-y-3">
        {(szerepek || []).map(sz => {
          const j = jogaiSzerepnek(sz.kod);
          const nyit = nyitott === sz.kod;
          const zarolt = sz.kod === 'SUPERADMIN';
          const db = viselok(sz.kod);
          return (
            <div key={sz.kod} className={'bg-white border rounded-2xl overflow-hidden ' +
              (sz.aktiv ? 'border-slate-100' : 'border-slate-200 bg-slate-50/60')}>
              <div className="flex items-start gap-4 p-4">
                <div className={'w-10 h-10 rounded-xl flex-none flex items-center justify-center ' +
                  (zarolt ? 'bg-primary/10 text-primary' : 'bg-slate-100 text-slate-500')}>
                  <Lucide.Shield size={18} />
                </div>
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="font-black text-slate-800">{sz.nev}</span>
                    <code className="text-[10px] font-bold text-slate-400 bg-slate-50 border border-slate-200 rounded px-1.5 py-0.5">{sz.kod}</code>
                    {zarolt && <span className="text-[10px] font-bold text-primary inline-flex items-center gap-1"><Lucide.Lock size={10} /> nem szerkeszthető</span>}
                    {!sz.aktiv && <span className="text-[10px] font-bold text-slate-400">kikapcsolva</span>}
                    <span className="text-[11px] font-bold text-slate-400">{db} fiók</span>
                  </div>
                  {sz.leiras && <p className="text-[13px] text-slate-500 mt-0.5">{sz.leiras}</p>}
                  <p className="text-[11px] text-slate-400 mt-1">
                    {zarolt ? 'Minden felület' : j.length + ' menüpont'}
                  </p>
                </div>
                {!zarolt && isSuper && (
                  <button onClick={() => setNyitott(nyit ? '' : sz.kod)}
                    className={U_btnGhost + ' !py-2 !px-3 text-xs flex-none'}>
                    <Lucide.Sliders size={14} /> {nyit ? 'Bezár' : 'Beállítás'}
                  </button>
                )}
              </div>

              {nyit && !zarolt && (
                <div className="border-t border-slate-100 p-4 space-y-4 bg-slate-50/50">
                  <div className="grid sm:grid-cols-2 gap-3">
                    <div>
                      <label className="text-[11px] font-black text-slate-400 uppercase tracking-wide">Megnevezés</label>
                      <input defaultValue={sz.nev} className={U_input + ' mt-1'}
                        onBlur={e => e.target.value.trim() && e.target.value !== sz.nev &&
                          muvelet(() => ROLE_api.save(sz.kod, e.target.value.trim()), 'Megnevezés mentve.')} />
                    </div>
                    <div>
                      <label className="text-[11px] font-black text-slate-400 uppercase tracking-wide">Leírás</label>
                      <input defaultValue={sz.leiras || ''} className={U_input + ' mt-1'}
                        onBlur={e => e.target.value !== (sz.leiras || '') &&
                          muvelet(() => ROLE_api.save(sz.kod, null, e.target.value), 'Leírás mentve.')} />
                    </div>
                  </div>

                  <div>
                    <label className="text-[11px] font-black text-slate-400 uppercase tracking-wide">
                      Mit lásson a menüben
                    </label>
                    <div className="flex flex-wrap gap-1.5 mt-2">
                      {(typeof MENU_ITEMS !== 'undefined' ? MENU_ITEMS : []).map(mi => {
                        const be = j.includes(mi.id);
                        return (
                          <button key={mi.id} type="button"
                            onClick={() => muvelet(() => ROLE_api.setPerm(sz.kod, mi.id, !be),
                              (be ? 'Elvéve: ' : 'Hozzáadva: ') + mi.label)}
                            className={'px-2.5 py-1 rounded-lg border text-[11px] font-bold transition-colors ' +
                              (be ? 'bg-primary text-white border-primary'
                                  : 'bg-white text-slate-500 border-slate-200 hover:border-primary')}>
                            {mi.label}
                          </button>
                        );
                      })}
                    </div>
                    <p className="text-[11px] text-slate-400 mt-2">
                      Néhány képernyőnek saját szabálya van (Regisztrációk, ECHO- és
                      kollégiumi jogosultságok) — azt ez a lista nem írja felül.
                    </p>
                  </div>

                  <div className="flex items-center gap-3 pt-2 border-t border-slate-200">
                    <button onClick={() => muvelet(() => ROLE_api.save(sz.kod, null, null, null, null, !sz.aktiv),
                        sz.aktiv ? 'Kikapcsolva.' : 'Bekapcsolva.')}
                      className={U_btnGhost + ' !py-2 !px-3 text-xs'}>
                      {sz.aktiv ? 'Kikapcsolás' : 'Bekapcsolás'}
                    </button>
                    {!sz.beepitett && (
                      <button onClick={() => muvelet(() => ROLE_api.remove(sz.kod), 'Szerepkör törölve.')}
                        className={U_btnGhost + ' !py-2 !px-3 text-xs !text-red-600 hover:!bg-red-50'}>
                        <Lucide.Trash2 size={14} /> Törlés
                      </button>
                    )}
                    <span className="ml-auto text-[11px] text-slate-400">
                      {sz.beepitett ? 'Beépített szerepkör — törölni nem, kikapcsolni lehet.' : 'Saját szerepkör.'}
                    </span>
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>

      {isSuper && (
        <div className="bg-white border border-dashed border-slate-200 rounded-2xl p-4">
          <label className="text-[11px] font-black text-slate-400 uppercase tracking-wide">Új szerepkör</label>
          <div className="flex gap-2 mt-2 flex-wrap">
            <input value={ujKod} onChange={e => setUjKod(e.target.value.toUpperCase())}
              placeholder="KÓD (pl. KOORDINATOR)" className={U_input + ' flex-1 min-w-[180px]'} />
            <input value={ujNev} onChange={e => setUjNev(e.target.value)}
              placeholder="Megnevezés" className={U_input + ' flex-1 min-w-[180px]'} />
            <button disabled={!ujKod.trim() || !ujNev.trim()}
              onClick={() => muvelet(() => ROLE_api.save(ujKod.trim(), ujNev.trim()), 'Szerepkör létrehozva.')
                .then(() => { setUjKod(''); setUjNev(''); })}
              className={U_btnPrimary + ' !py-2 !px-4 text-sm'}>Létrehozás</button>
          </div>
          <p className="text-[11px] text-slate-400 mt-2">
            Az új szerepkör kezdetben egyetlen menüpontot sem lát — a Beállítás alatt
            add hozzá, amit szeretnél.
          </p>
        </div>
      )}
    </div>
  );
}
