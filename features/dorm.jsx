/* ============================================================
   UniPortal — Kollégium- és ingatlanüzemeltetési modul
   KÖZÖS RÉTEG  +  "Kollégium" (DORM_OPS) menüpont, 7 füllel
   ------------------------------------------------------------
   Ez a fájl az app.jsx moduljába van fűzve (build.mjs), a
   features/dorm-views.jsx ELŐTT. NINCS import: a React, a hookok,
   a Lucide, a window.sb, a U* atomok (data-layer.jsx), a
   SkeletonRows és a RefreshingBadge a közös modul-scope-ban vannak.

   AMIT EZ A FÁJL DEFINIÁL — és a dorm-views.jsx HASZNÁL:
     DORM_rpc, DORM_api, DORM_ERR,
     DORM_Tabs, DORM_Stat, DORM_Empty, DORM_Hidden
   A dorm-views.jsx DORMV_* burkolói ezekre esnek vissza, ezért a
   szignatúrák TÖBB elnevezési konvenciót is elfogadnak
   (tabs/items/options, tab/active/value, setTab/onChange/onSelect).

   NÉGY KÖVETELMÉNY, AMI VÉGIGMEGY AZ EGÉSZ FÁJLON
   ------------------------------------------------------------
   1. ADATVÉDELEM. A "ki hol lakik" a modul legérzékenyebb adata, és a
      szűrést az ADATBÁZIS végzi (v_room_occupancy / v_room_operational,
      102 policy). A felület ezt SEHOL nem próbálja megkerülni. Ahol egy
      név hiányzik, ott NEM üres cellát mutatunk: a DORM_Hidden kimondja,
      hogy adatvédelmi okból rejtett. Az üres lista gyakran HELYES válasz.
   2. RESZPONZIVITÁS ELEVE. Minden táblázat saját overflow-x-auto
      konténerben ül; a sok oszlopos listák sm alatt kártyára váltanak;
      az érintési célpontok 44 px-esek; a fülsáv kis kijelzőn görgethető.
      A LAP TÖRZSE SOHA nem görög vízszintesen — ezért van minden
      rács- és flex-gyereken min-w-0.
   3. A JOGOSULTSÁG A dorm_my_roles()-BÓL JÖN, nem a profiles.role-ból.
      A profiles.role enumot nem bővítjük (app.jsx filteredMenuItems
      'return false' ága egy ismeretlen szerepkörnek NULLA menüpontot ad).
   4. A FELÜLET SOHA NEM HÍVJA a dorm_module_rollback()-et. A DORM_api-ban
      szándékosan nincs is benne.
   ============================================================ */

/* ============================================================
   1. RÉSZ — KÖZÖS ADATRÉTEG
   ============================================================ */

/* ---------- 1.1 Hibakód → magyar mondat ----------------------------------
   Az RPC-k beszédes hibát dobnak ('DORM_BED_TAKEN: a(z) A-312/B ferohely ...'),
   de a nyers postgres-üzenet ékezet nélküli és technikai. Itt fordítjuk le
   emberi mondattá — a részleteket (melyik ágy, melyik időszak) a nyers
   üzenetből meghagyjuk, mert az az érdemi információ. */
const DORM_ERR = {
  DORM_FORBIDDEN:                'Ehhez a művelethez nincs jogosultsága. A kollégiumi jogosultságot a Szerepkörök fülön lehet kiosztani (KOLI_SYSADMIN vagy admin).',
  DORM_BED_TAKEN:                'Ez a férőhely a kért időszakban már foglalt. Válasszon másik férőhelyet vagy másik időszakot — a szabad helyek listája naprakész.',
  DORM_BED_UNKNOWN:              'Nincs ilyen férőhely. Lehet, hogy időközben kivonták a nyilvántartásból.',
  DORM_BED_NOT_LETTABLE:         'Ez a férőhely jelenleg nem kiadható (fenntartott vagy üzemképtelen). Előbb a férőhely állapotát kell átállítani.',
  DORM_ROOM_UNKNOWN:             'Nincs ilyen szoba.',
  DORM_ROOM_NOT_OPERABLE:        'A szoba nem üzemképes (javítás vagy felújítás alatt), ezért nem osztható ki.',
  DORM_ROOM_STATUS_INVALID:      'Ez a szobaállapot-átmenet nem megengedett.',
  DORM_PERSON_UNKNOWN:           'Nincs ilyen lakó a nyilvántartásban.',
  DORM_PROFILE_NOT_FOUND:        'Nincs ilyen e-mail-címmel UniPortal-fiók. A fióknak előbb regisztrálnia kell, és jóváhagyottnak kell lennie.',
  DORM_PROFILE_TAKEN:            'Ez a fiók már egy másik lakóhoz van kötve.',
  DORM_STUDENT_TAKEN:            'Ez a jelentkezői azonosító már egy másik lakóhoz van kötve.',
  DORM_PERIOD_EMPTY:             'Üres időszak: a záró dátum nem lehet korábbi vagy azonos a kezdő dátumnál.',
  DORM_CATEGORY_UNKNOWN:         'Ismeretlen hibakategória.',
  DORM_QR_UNKNOWN:               'Ismeretlen férőhely-azonosító (QR-kód).',
  DORM_LOCATION_REQUIRED:        'A helyszín megadása kötelező: szoba, férőhely-QR vagy épület.',
  DORM_ISSUE_STATUS_INVALID:     'Ez a hibajegy-állapotátmenet nem megengedett.',
  DORM_APPLICATION_STATUS_INVALID:'Ez a jelentkezés-állapotátmenet nem megengedett.',
  DORM_PREREQ_MISSING:           'A modul egy előfeltétele hiányzik. Valószínűleg egy korábbi migráció nem futott le.',
};

/* A PostgREST/Supabase saját hibakódjai. A PGRST202 azt jelenti, hogy a
   függvény nem létezik — ez a 26-os migráció lefuttatása ELŐTT a normális
   állapot, és nem szabad "ismeretlen hibaként" ijesztgetni vele. */
const DORM_PGERR = {
  PGRST202: 'A kollégiumi modul adatbázis-része még nincs telepítve ezen a példányon (26_dorm.sql).',
  PGRST205: 'A kollégiumi séma még nincs kitéve az API-nak (Exposed schemas: dorm).',
  PGRST301: 'A munkamenet lejárt. Jelentkezzen be újra.',
  '42501':  'Az adatbázis megtagadta a műveletet (jogosultság).',
  '42P01':  'A kollégiumi modul adatbázis-része még nincs telepítve ezen a példányon (26_dorm.sql).',
  '23505':  'Ez az érték már létezik (egyedi azonosító ütközés).',
  '23503':  'A hivatkozott sor nem létezik vagy nem törölhető, mert hivatkoznak rá.',
  '23514':  'Az adatbázis egy ellenőrző feltétele nem teljesült.',
};

/* Egyetlen hibafordító. Sose dobjon tovább nyers postgres-szöveget. */
function DORM_msg(e) {
  if (!e) return 'Ismeretlen hiba.';
  const raw = String((e && e.message) || (e && e.msg) || e || '');
  const code = (e && e.code) || '';
  const hit = raw.match(/DORM_[A-Z_]+/);
  if (hit && DORM_ERR[hit[0]]) {
    // A kettőspont utáni rész az érdemi részlet (melyik ágy, melyik időszak).
    const detail = raw.split(':').slice(1).join(':').trim();
    return DORM_ERR[hit[0]] + (detail && detail.length < 220 ? ' (' + detail + ')' : '');
  }
  if (code && DORM_PGERR[code]) return DORM_PGERR[code];
  for (const k in DORM_PGERR) { if (raw.indexOf(k) >= 0) return DORM_PGERR[k]; }
  if (/Failed to fetch|NetworkError|network/i.test(raw)) return 'Nincs kapcsolat a kiszolgálóval. Ellenőrizze az internetkapcsolatot.';
  return raw || 'Ismeretlen hiba.';
}

/* ---------- 1.2 DORM_rpc — a 13 publikus RPC egyetlen kapuja ---------------
   A modul minden aggregáló hívása ezen megy át: egy hely, ahol a hibát
   magyarra fordítjuk, és egy hely, ahol a hiányzó kapcsolat kiderül. */
async function DORM_rpc(name, args) {
  if (!window.sb) throw new Error('Nincs adatbázis-kapcsolat (a Supabase-kliens nem töltődött be).');
  let res;
  try {
    res = await window.sb.rpc(name, args || {});
  } catch (e) {
    throw new Error(DORM_msg(e));
  }
  if (res && res.error) throw new Error(DORM_msg(res.error));
  return res ? res.data : null;
}

/* ---------- 1.3 DORM_api — a 13 RPC pontos szignatúrával ------------------
   A dorm_module_rollback() SZÁNDÉKOSAN nincs itt: a felületről soha nem
   hívjuk, és amit nem lehet leírni, azt nem lehet véletlenül elsütni sem. */
const DORM_api = {
  myPlacement:   ()            => DORM_rpc('dorm_my_placement'),
  myRoles:       ()            => DORM_rpc('dorm_my_roles'),
  occupancy:     (b, on)       => DORM_rpc('dorm_occupancy_summary', { p_building: b || null, p_on: on || null }),
  freeBeds:      (o)           => DORM_rpc('dorm_free_beds', o || {}),
  openIssues:    (b, overdue)  => DORM_rpc('dorm_open_issues', { p_building: b || null, p_only_overdue: !!overdue }),
  reportIssue:   (o)           => DORM_rpc('dorm_issue_report', o),
  assign:        (o)           => DORM_rpc('dorm_assign', o),
  roleGrant:     (o)           => DORM_rpc('dorm_role_grant', o),
  personLink:    (o)           => DORM_rpc('dorm_person_link', o),
  linkSuggest:   ()            => DORM_rpc('dorm_person_link_suggestions'),
  leaseAlerts:   (d)           => DORM_rpc('dorm_lease_alerts', { p_days: d || 180 }),
  expireOffers:  ()            => DORM_rpc('dorm_expire_offers'),
};

/* ---------- 1.4 Közvetlen tábla-hozzáférés --------------------------------
   A `dorm` séma KITETT (26_dorm.sql 3. szerkezeti döntés), tehát a táblák és
   a három nézet közvetlenül is olvashatók — RLS mögül. A 13 RPC kényelmi és
   aggregáló réteg, nem az egyetlen út befelé: a 7 fül nagy része olyan
   táblát olvas, amire nincs (és nem is kell) külön RPC. */
function DORM_db() {
  if (!window.sb) throw new Error('Nincs adatbázis-kapcsolat.');
  return window.sb.schema ? window.sb.schema('dorm') : window.sb;
}

/* Olvasás. Sosem dob a renderbe: a hívó dönti el, hogy az üres eredmény
   hiba-e vagy helyes válasz (RLS-szűrés). */
async function DORM_sel(table, build) {
  try {
    let q = DORM_db().from(table).select('*');
    if (build) q = build(q);
    const { data, error } = await q;
    if (error) return { rows: [], error: DORM_msg(error) };
    return { rows: Array.isArray(data) ? data : [], error: '' };
  } catch (e) {
    return { rows: [], error: DORM_msg(e) };
  }
}

async function DORM_ins(table, row) {
  const { data, error } = await DORM_db().from(table).insert(row).select();
  if (error) throw new Error(DORM_msg(error));
  return (data && data[0]) || null;
}

async function DORM_upd(table, id, patch) {
  const { data, error } = await DORM_db().from(table).update(patch).eq('id', id).select();
  if (error) throw new Error(DORM_msg(error));
  return (data && data[0]) || null;
}

/* ---------- 1.5 Formázók --------------------------------------------------
   Magyar felület: hu-HU dátum, HUF pénznem, ékezetes rendezés. */
function DORM_d(v) {
  if (!v) return '—';
  const d = new Date(v);
  if (isNaN(d)) return String(v);
  return d.toLocaleDateString('hu-HU', { year: 'numeric', month: '2-digit', day: '2-digit' });
}
function DORM_dt(v) {
  if (!v) return '—';
  const d = new Date(v);
  if (isNaN(d)) return String(v);
  return d.toLocaleString('hu-HU', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });
}
function DORM_money(n, cur) {
  if (n == null || n === '') return '—';
  const c = cur || 'HUF';
  try {
    return new Intl.NumberFormat('hu-HU', { style: 'currency', currency: c, maximumFractionDigits: 0 }).format(Number(n));
  } catch (e) { return Number(n).toLocaleString('hu-HU') + ' ' + c; }
}
function DORM_num(n) {
  if (n == null || n === '') return '—';
  return Number(n).toLocaleString('hu-HU');
}
/* A daterange szövegesen jön a PostgREST-től: '[2026-09-01,2027-06-30)'.
   A felső határ NYITOTT — aki 01-31-én kiköltözik, annak az ágyára aznap
   már be lehet költözni. A felületen ezért "…-ig (nyitott)" nem szerepel:
   a dátumot mutatjuk, a szemantikát a modul viszi. */
function DORM_period(p) {
  if (!p) return { from: null, to: null, text: '—' };
  if (typeof p === 'object') {
    const f = p.from || p.lower || null, t = p.to || p.upper || null;
    return { from: f, to: t, text: (f ? DORM_d(f) : '—') + ' – ' + (t ? DORM_d(t) : 'nyitott') };
  }
  const m = String(p).match(/[\[\(]\s*"?([^,"]*)"?\s*,\s*"?([^\)\]"]*)"?\s*[\)\]]/);
  if (!m) return { from: null, to: null, text: String(p) };
  const from = m[1] || null, to = m[2] || null;
  return { from, to, text: (from ? DORM_d(from) : '—') + ' – ' + (to ? DORM_d(to) : 'nyitott') };
}
const DORM_today = () => new Date().toISOString().slice(0, 10);

/* ---------- 1.6 Szerepkör-logika ------------------------------------------
   A modul öt szerepköre. A hatókör az ÉPÜLET (nincs rekurzió, ellentétben az
   ECHO org-fájával). scope_building is null = intézményi = minden épület. */
const DORM_ROLES = ['GONDNOK', 'KARBANTARTO', 'KOLI_ADMIN', 'INGATLAN', 'KOLI_SYSADMIN'];

const DORM_ROLE_LABEL = {
  GONDNOK:       'Gondnok',
  KARBANTARTO:   'Karbantartó',
  KOLI_ADMIN:    'Kollégiumi adminisztrátor',
  INGATLAN:      'Ingatlangazda',
  KOLI_SYSADMIN: 'Kollégiumi rendszergazda',
};

const DORM_ROLE_HINT = {
  GONDNOK:       'Saját épülete: szobák, be- és kiköltöztetés, kulcs, leltár — LAKÓNÉVVEL.',
  KARBANTARTO:   'Hibabejelentések és munkalapok — LAKÓNÉV NÉLKÜL. Külsős vállalkozó is lehet.',
  KOLI_ADMIN:    'Férőhelykiosztás, szerződések, várólista, díjak. Tipikusan intézményi hatókör.',
  INGATLAN:      'Bérelt épületek: bérleti szerződés, rezsi, bérbeadói kapcsolat, lejáratfigyelés.',
  KOLI_SYSADMIN: 'Grantok kiosztása, katalógusok karbantartása.',
};

/* A UniPortal-oldali admin. A profiles.role enumot NEM bővítjük. */
const DORM_isAdmin = (user) => !!(user && ['SUPERADMIN', 'ADMIN'].includes(user.role));

/* dorm_my_roles() normalizálva. A 'lakó' kulcs ékezetes — az adatbázis így
   adja vissza, és nem írjuk át, mert a másik fájl is erre épít. */
function DORM_normRoles(raw, user) {
  const r = raw || {};
  const list = Array.isArray(r.szerepkorok) ? r.szerepkorok : [];
  return {
    roles:      list,
    buildings:  Array.isArray(r.epuletek) ? r.epuletek : [],
    everywhere: !!r.intezmenyi || DORM_isAdmin(user),
    resident:   !!r['lakó'] || !!r.lako,
    admin:      DORM_isAdmin(user),
    has: (x) => DORM_isAdmin(user) || list.indexOf(x) >= 0,
    hasAny: (arr) => DORM_isAdmin(user) || (arr || []).some(x => list.indexOf(x) >= 0),
  };
}

/* Egyetlen hook, egyetlen dorm_my_roles() hívás nézetenként. */
function DORM_useRoles(user) {
  const [state, setState] = useState({ loading: true, error: '', data: DORM_normRoles(null, user) });
  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const raw = await DORM_api.myRoles();
        if (alive) setState({ loading: false, error: '', data: DORM_normRoles(raw, user) });
      } catch (e) {
        // A migráció lefutása előtt ez a NORMÁLIS állapot: az admin ilyenkor is
        // lát mindent, a többi felhasználó pedig semmit — pontosan helyesen.
        if (alive) setState({ loading: false, error: DORM_msg(e), data: DORM_normRoles(null, user) });
      }
    })();
    return () => { alive = false; };
  }, [user && user.id]);
  return state;
}

/* ============================================================
   2. RÉSZ — A NÉGY KÖZÖS KOMPONENS
   ------------------------------------------------------------
   A dorm-views.jsx DORMV_* burkolói TÖBB elnevezési konvencióval hívják
   ezeket (tabs/items/options, tab/active/value/current,
   setTab/onChange/onSelect/onTab, hint/sub, subtitle/text, label/field,
   reason/title). Mindegyiket elfogadjuk — a burkoló így soha nem tud
   üres propot átadni, és a két fájl egymástól függetlenül fordul.
   ============================================================ */

/* Lucide-ikon névből. A hiányzó ikon nem borítja a rendert: kör lesz belőle. */
const DORM_Ic = ({ n, size = 16, className = '' }) => {
  const C = (typeof Lucide !== 'undefined' && Lucide && (Lucide[n] || Lucide.Circle)) || null;
  return C ? <C size={size} className={className} /> : null;
};

/* ---------- 2.1 DORM_Tabs -------------------------------------------------
   Kis kijelzőn VÍZSZINTESEN GÖRGETHETŐ, sm felett tördelt. A görgetés a
   fülsáv SAJÁT dobozában marad (-mx-1 px-1), ezért a lap törzse akkor sem
   görög, ha hét fül van. Minden fül min-h-[44px]: hüvelykujjnyi célpont.
   A scrollbar el van rejtve, mert a fülsáv fölött vizuális zaj. */
function DORM_Tabs(props) {
  const tabs    = props.tabs || props.items || props.options || [];
  const active  = props.tab != null ? props.tab : (props.active != null ? props.active : (props.value != null ? props.value : props.current));
  const pick    = props.setTab || props.onChange || props.onSelect || props.onTab || (() => {});
  const list    = Array.isArray(tabs) ? tabs : [];
  if (!list.length) return null;
  return (
    <div
      role="tablist"
      className="flex gap-2 mb-6 overflow-x-auto sm:flex-wrap sm:overflow-visible -mx-1 px-1 pb-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
      {list.map((t, i) => {
        const id = t && t.id != null ? t.id : i;
        const on = active === id;
        return (
          <button
            key={id}
            role="tab"
            aria-selected={on}
            onClick={() => pick(id)}
            title={t && t.hint ? t.hint : undefined}
            className={'flex-none inline-flex items-center gap-2 rounded-2xl px-4 min-h-[44px] text-sm font-black whitespace-nowrap transition-all ' +
              (on ? 'bg-primary text-white shadow-lg shadow-primary/10'
                  : 'bg-white border border-slate-100 text-slate-500 hover:text-slate-800 hover:border-slate-200')}>
            {t && t.icon && <DORM_Ic n={t.icon} size={15} />}
            <span>{(t && (t.label || t.title)) || String(id)}</span>
            {t && t.count != null && (
              <span className={'ml-0.5 text-[11px] font-black tabular-nums ' + (on ? 'text-white/70' : 'text-slate-400')}>{t.count}</span>
            )}
          </button>
        );
      })}
    </div>
  );
}

/* ---------- 2.2 DORM_Stat -------------------------------------------------
   Mérőszám-csempe: címke, érték, megjegyzés, opcionális szín. A min-w-0 nem
   dísz: enélkül egy hosszú épületnév kifeszítené a rácsot, és a lap
   vízszintesen görögne — pontosan az, amit a modulban tiltunk. */
const DORM_TONES = {
  slate:   'text-slate-900',
  red:     'text-red-600',
  amber:   'text-amber-600',
  green:   'text-emerald-600',
  emerald: 'text-emerald-600',
  violet:  'text-violet-600',
  blue:    'text-blue-600',
  primary: 'text-primary',
};

function DORM_Stat(props) {
  const label = props.label || props.title || '';
  const hint  = props.hint != null ? props.hint : props.sub;
  const tone  = props.tone || 'slate';
  return (
    <div className="bg-white rounded-2xl border border-slate-100 p-4 min-w-0">
      <div className="flex items-center gap-2 text-[10px] font-black text-slate-400 uppercase tracking-widest min-w-0">
        {props.icon && <DORM_Ic n={props.icon} size={13} className="flex-none" />}
        <span className="truncate">{label}</span>
      </div>
      <div className={'text-2xl font-black mt-1 tabular-nums break-words ' + (DORM_TONES[tone] || DORM_TONES.slate)}>
        {props.value != null && props.value !== '' ? props.value : '—'}
      </div>
      {hint && <div className="text-[11px] text-slate-400 font-medium mt-0.5 leading-snug">{hint}</div>}
    </div>
  );
}

/* ---------- 2.3 DORM_Empty ------------------------------------------------
   Üres állapot. A modulban az ÜRES LISTA GYAKRAN HELYES VÁLASZ (az RLS
   szűrt), ezért itt nem hibát mutatunk, hanem elmondjuk, mit jelent. */
function DORM_Empty(props) {
  const sub = props.subtitle != null ? props.subtitle : props.text;
  return (
    <div className="bg-white rounded-3xl border border-slate-100 py-12 sm:py-14 px-6 text-center">
      <div className="w-14 h-14 rounded-2xl bg-slate-50 text-slate-300 flex items-center justify-center mx-auto mb-4">
        <DORM_Ic n={props.icon || 'Inbox'} size={26} />
      </div>
      <p className="font-black text-slate-700">{props.title || 'Nincs megjeleníthető adat'}</p>
      {sub && <p className="text-sm text-slate-400 mt-1 max-w-md mx-auto leading-relaxed">{sub}</p>}
      {props.action && <div className="mt-5 flex justify-center">{props.action}</div>}
    </div>
  );
}

/* ---------- 2.4 DORM_Hidden -----------------------------------------------
   Ez a komponens a modul egyik lényege. Ahol az adatbázis elrejtette a
   lakó nevét (KARBANTARTO, INGATLAN, vagy VÉDETT lakó), ott NEM üres cellát
   mutatunk: kimondjuk, hogy adatvédelmi okból rejtett. Az üres cella
   "hiányzó adatnak" látszik, és keresni kezdik; ez a jelölő megállítja. */
function DORM_Hidden(props) {
  const label  = props.label || props.field || '';
  const reason = props.reason || props.title || 'Adatvédelmi okból rejtett — ezt az adatot az adatbázis szűri ki, nem a felület.';
  return (
    <span
      title={reason}
      className="inline-flex items-center gap-1.5 text-[11px] font-bold text-slate-400 bg-slate-50 border border-slate-100 rounded-lg px-2 py-1 whitespace-nowrap">
      <DORM_Ic n="EyeOff" size={12} />
      {label ? label + ': rejtve' : 'Adatvédelmi okból rejtett'}
    </span>
  );
}

/* ============================================================
   3. RÉSZ — A "KOLLÉGIUM" MENÜPONT SEGÉDELEMEI
   ------------------------------------------------------------
   Szándékosan kicsik és helyben olvashatók. A DORM_Table a modul
   reszponzív alapszabálya EGY helyen: minden táblázat saját
   overflow-x-auto dobozban ül, tehát a LAP TÖRZSE soha nem görög.
   ============================================================ */

const DORM_Chip = ({ children, cls = 'bg-slate-50 text-slate-600 border-slate-200', icon }) => (
  <span className={'inline-flex items-center gap-1 text-[11px] font-black px-2 py-1 rounded-lg border whitespace-nowrap ' + cls}>
    {icon && <DORM_Ic n={icon} size={11} />} {children}
  </span>
);

/* A bérlemény-jelvény. A "saját vagy bérelt" a modul legfontosabb
   megkülönböztetése: bérelt épületnél más a felelős, más a határidő és van
   bérleti szerződés, aminek lejárata van. Ezért kap külön, LÁTHATÓ jelet. */
const DORM_isLeased = (tenure) => !!tenure && tenure !== 'OWNED' && tenure !== 'OWNED_OUT_OF_USE';

const DORM_TENURE = {
  OWNED:               'Saját tulajdon',
  OWNED_OUT_OF_USE:    'Saját, nem hasznosított',
  LEASED_WHOLE:        'Teljes épület bérlete',
  LEASED_PARTIAL:      'Részleges bérlet',
  CONTRACTED_CAPACITY: 'Szerződött férőhely',
  MANAGED_FOR_OTHER:   'Idegen tulajdon, mi üzemeltetjük',
};

function DORM_TenureChip({ tenure }) {
  if (!tenure) return <span className="text-slate-300">—</span>;
  const leased = DORM_isLeased(tenure);
  return (
    <DORM_Chip icon={leased ? 'Building2' : 'Home'}
      cls={leased ? 'bg-violet-50 text-violet-700 border-violet-200' : 'bg-emerald-50 text-emerald-700 border-emerald-200'}>
      {leased ? 'Bérlemény' : 'Saját'}
    </DORM_Chip>
  );
}

function DORM_Err({ msg, onClose }) {
  if (!msg) return null;
  return (
    <div className="mt-5 flex items-start gap-2 bg-red-50 border border-red-100 text-red-700 rounded-2xl px-4 py-3 text-sm font-semibold">
      <DORM_Ic n="AlertCircle" size={16} className="mt-0.5 flex-none" />
      <span className="min-w-0 break-words">{msg}</span>
      {onClose && (
        <button onClick={onClose} aria-label="Bezárás"
          className="ml-auto flex-none w-6 h-6 flex items-center justify-center text-red-400 hover:text-red-700">
          <DORM_Ic n="X" size={15} />
        </button>
      )}
    </div>
  );
}

/* MÉRVE — ez a függvény korábban a teljes modult megölte:
   a közös SkeletonRows({ rows = 5, cols }) `cols` propja KÖTELEZŐ (nincs
   alapértéke), és a törzse `cols.map(...)`-ot hív. A `<SkeletonRows rows={5} />`
   hívás tehát TypeError-t dobott ("Cannot read properties of undefined"),
   ami a React fát a gyökérig lebontotta: a Kollégium menüpontra kattintva
   FEHÉR LAP jött fel, és onnantól a shell sem élt.
   Ráadásul a SkeletonRows `<tr>`-eket ad vissza, amit egy sima `<div>`-be
   tenni érvénytelen HTML. Ezért itt NEM használjuk: a betöltésjelző saját,
   táblázattól független csíkokból áll, és semmilyen külső propot nem igényel. */
function DORM_Loading({ text = 'Betöltés…' }) {
  return (
    <div className="p-4 sm:p-6 lg:p-8" role="status" aria-live="polite">
      <span className="sr-only">{text}</span>
      <div className="h-5 w-56 max-w-full rounded bg-slate-100 animate-pulse" />
      <div className="mt-6 space-y-3">
        {[0, 1, 2, 3, 4].map(i => (
          <div key={i} className="h-11 rounded-xl bg-slate-100 animate-pulse" style={{ opacity: 1 - i * 0.13 }} />
        ))}
      </div>
    </div>
  );
}

/* Minden táblázat konténere. Egy hely, egy szabály. */
const DORM_Table = ({ children, className = '' }) => (
  <div className={'bg-white rounded-2xl border border-slate-100 overflow-x-auto ' + className}>
    <table className="w-full min-w-[640px] text-sm">{children}</table>
  </div>
);

const DORM_Th = ({ children, className = '' }) => (
  <th className={'text-left text-[10px] font-black text-slate-400 uppercase tracking-widest px-4 py-3 whitespace-nowrap ' + className}>{children}</th>
);

const DORM_Td = ({ children, className = '' }) => (
  <td className={'px-4 py-3 align-middle ' + className}>{children}</td>
);

const DORM_KV = ({ label, children, wide }) => (
  <div className={'min-w-0 ' + (wide ? 'sm:col-span-2' : '')}>
    <div className="text-[10px] font-black text-slate-400 uppercase tracking-widest">{label}</div>
    <div className="text-sm text-slate-800 font-semibold mt-0.5 break-words">{children}</div>
  </div>
);

/* Épületválasztó. A lista az RLS-től jön: aki egy épületre kapott grantot,
   egyetlen elemet lát — ez nem hiba, hanem a hatókör. */
function DORM_BuildingPicker({ buildings, value, onChange, allLabel = 'Minden épület' }) {
  return (
    <select
      value={value || ''}
      onChange={e => onChange(e.target.value)}
      className="w-full sm:w-auto min-h-[44px] bg-white border border-slate-100 rounded-xl px-3 text-sm font-bold text-slate-700 focus:outline-none focus:ring-2 focus:ring-primary/20">
      <option value="">{allLabel}</option>
      {(buildings || []).map(b => (
        <option key={b.id} value={b.id}>
          {(b.code ? b.code + ' · ' : '') + (b.name || '')}{DORM_isLeased(b.tenure) ? ' (bérlemény)' : ''}
        </option>
      ))}
    </select>
  );
}

/* Egy épület emberi neve azonosítóból — a listákban ezt mutatjuk, nem uuid-t. */
function DORM_bName(buildings, id) {
  const b = (buildings || []).find(x => x.id === id);
  if (!b) return '—';
  return (b.code ? b.code + ' · ' : '') + (b.name || '');
}

/* Fejléc-sáv a fülek tetején: cím, magyarázat, jobb oldalt a művelet. */
function DORM_PanelHead({ title, desc, right }) {
  return (
    <div className="flex flex-wrap items-start justify-between gap-3 mb-4">
      <div className="min-w-0">
        <h2 className="text-lg font-black text-slate-900 tracking-tight">{title}</h2>
        {desc && <p className="text-sm text-slate-500 mt-1 max-w-2xl leading-relaxed">{desc}</p>}
      </div>
      {right && <div className="w-full sm:w-auto flex flex-wrap items-center gap-2">{right}</div>}
    </div>
  );
}

/* ============================================================
   4. RÉSZ — A HÉT FÜL
   ============================================================ */

/* ---------- 4.1 Épületek --------------------------------------------------
   Lista + űrlap. A FÉRŐHELY itt SZÁMÍTOTT oszlop (a kiadható ágyak száma a
   dorm_occupancy_summary()-ból), nem beírható törzsadat: a férőhely a
   szoba→ágy szerkezetből adódik, és egy kézzel írt szám azonnal hazudni
   kezdene. A bérelt sor "Bérlemény" jelvényt kap — ez dönti el, hogy a
   Bérlemények fülön egyáltalán megjelenik-e. */
function DORM_BuildingsPanel({ buildings, sites, landlords, summary, canEdit, onReload }) {
  const [open, setOpen] = useState(false);
  const [edit, setEdit] = useState(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr]   = useState('');
  const [f, setF]       = useState({});

  const blank = {
    code: '', name: '', tenure: 'OWNED', address: '', site_id: '', landlord_id: '',
    house_manager: '', house_manager_phone: '', floors_count: '', is_active: true, note: '',
  };
  const start = (row) => {
    setEdit(row || null);
    setF(row ? {
      code: row.code || '', name: row.name || '', tenure: row.tenure || 'OWNED',
      address: row.address || '', site_id: row.site_id || '', landlord_id: row.landlord_id || '',
      house_manager: row.house_manager || '', house_manager_phone: row.house_manager_phone || '',
      floors_count: row.floors_count == null ? '' : String(row.floors_count),
      is_active: row.is_active !== false, note: row.note || '',
    } : blank);
    setErr('');
    setOpen(true);
  };

  const save = async () => {
    if (!f.code.trim() || !f.name.trim()) { setErr('Az épületkód és a név kötelező.'); return; }
    if (DORM_isLeased(f.tenure) && !f.landlord_id) {
      setErr('Bérelt épülethez bérbeadót kell választani — enélkül a Bérlemények fül nem tud kihez fordulni egy hétvégi csőtörésnél.');
      return;
    }
    setBusy(true); setErr('');
    const row = {
      code: f.code.trim(), name: f.name.trim(), tenure: f.tenure,
      address: f.address.trim() || null,
      site_id: f.site_id || null,
      landlord_id: f.landlord_id || null,
      house_manager: f.house_manager.trim() || null,
      house_manager_phone: f.house_manager_phone.trim() || null,
      floors_count: f.floors_count === '' ? null : Number(f.floors_count),
      is_active: !!f.is_active,
      note: f.note.trim() || null,
    };
    try {
      if (edit) await DORM_upd('building', edit.id, row);
      else await DORM_ins('building', row);
      setOpen(false);
      onReload && onReload();
    } catch (e) { setErr(DORM_msg(e)); }
    setBusy(false);
  };

  const capOf = (id) => (summary || []).find(s => s.building_id === id) || null;

  return (
    <div>
      <DORM_PanelHead
        title="Épületek"
        desc="A modul törzsadata. A jogcím (saját vagy bérelt) dönti el, ki a felelős egy hibáért, mi a határidő, és hogy van-e mögötte bérleti szerződés lejárattal."
        right={canEdit && (
          <button onClick={() => start(null)} className={U_btnPrimary + ' min-h-[44px] w-full sm:w-auto'}>
            <DORM_Ic n="Plus" size={16} /> Új épület
          </button>
        )} />

      {!buildings.length ? (
        <DORM_Empty icon="Building2" title="Nincs látható épület"
          subtitle="Vagy még nincs felvéve épület, vagy a hatóköre nem terjed ki egyikre sem. A hatókört a Szerepkörök fülön adják ki, épületre szűkítve." />
      ) : (
        <DORM_Table>
          <thead className="border-b border-slate-100">
            <tr>
              <DORM_Th>Épület</DORM_Th>
              <DORM_Th>Cím</DORM_Th>
              <DORM_Th>Jogcím</DORM_Th>
              <DORM_Th className="text-right">Férőhely</DORM_Th>
              <DORM_Th>Gondnok</DORM_Th>
              <DORM_Th>Státusz</DORM_Th>
              {canEdit && <DORM_Th className="text-right">Művelet</DORM_Th>}
            </tr>
          </thead>
          <tbody>
            {buildings.map(b => {
              const c = capOf(b.id);
              return (
                <tr key={b.id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                  <DORM_Td>
                    <div className="font-black text-slate-800">{b.name}</div>
                    <div className="text-[11px] text-slate-400 font-bold">{b.code}</div>
                  </DORM_Td>
                  <DORM_Td className="text-slate-600 max-w-[260px]"><span className="break-words">{b.address || '—'}</span></DORM_Td>
                  <DORM_Td>
                    <div className="flex flex-col gap-1">
                      <DORM_TenureChip tenure={b.tenure} />
                      <span className="text-[11px] text-slate-400 font-semibold">{DORM_TENURE[b.tenure] || b.tenure}</span>
                    </div>
                  </DORM_Td>
                  <DORM_Td className="text-right tabular-nums">
                    {c ? (
                      <>
                        <div className="font-black text-slate-800">{DORM_num(c.beds_lettable)}</div>
                        <div className="text-[11px] text-slate-400 font-bold">ebből foglalt: {DORM_num(c.beds_occupied)}</div>
                      </>
                    ) : <span className="text-slate-300">—</span>}
                  </DORM_Td>
                  <DORM_Td className="text-slate-600">
                    <div className="font-semibold">{b.house_manager || '—'}</div>
                    {b.house_manager_phone && <div className="text-[11px] text-slate-400 font-bold">{b.house_manager_phone}</div>}
                  </DORM_Td>
                  <DORM_Td>
                    {b.is_active === false
                      ? <DORM_Chip icon="PauseCircle" cls="bg-slate-100 text-slate-500 border-slate-200">Inaktív</DORM_Chip>
                      : <DORM_Chip icon="CheckCircle2" cls="bg-emerald-50 text-emerald-700 border-emerald-200">Aktív</DORM_Chip>}
                  </DORM_Td>
                  {canEdit && (
                    <DORM_Td className="text-right">
                      <button onClick={() => start(b)} className={U_btnGhost + ' !px-3 min-h-[44px]'}>
                        <DORM_Ic n="Pencil" size={14} /> Szerkeszt
                      </button>
                    </DORM_Td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </DORM_Table>
      )}

      <UModal open={open} onClose={() => setOpen(false)} max="max-w-3xl"
        title={edit ? 'Épület szerkesztése' : 'Új épület'}
        subtitle="A jogcím később is módosítható, de a bérelt jogcím bérbeadót és bérleti szerződést feltételez."
        icon={<DORM_Ic n="Building2" size={20} />}>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <UField label="Épületkód"><input className={U_input} value={f.code} onChange={e => setF({ ...f, code: e.target.value })} placeholder="KOLL-A" /></UField>
          <UField label="Név"><input className={U_input} value={f.name} onChange={e => setF({ ...f, name: e.target.value })} placeholder="Kollégium A épület" /></UField>
          <UField label="Cím" hint="Utca, házszám, város."><input className={U_input} value={f.address} onChange={e => setF({ ...f, address: e.target.value })} /></UField>
          <UField label="Jogcím">
            <select className={U_input} value={f.tenure} onChange={e => setF({ ...f, tenure: e.target.value })}>
              {Object.keys(DORM_TENURE).map(k => <option key={k} value={k}>{DORM_TENURE[k]}</option>)}
            </select>
          </UField>
          <UField label="Telephely">
            <select className={U_input} value={f.site_id} onChange={e => setF({ ...f, site_id: e.target.value })}>
              <option value="">— nincs megadva —</option>
              {(sites || []).map(s => <option key={s.id} value={s.id}>{(s.code ? s.code + ' · ' : '') + s.name}</option>)}
            </select>
          </UField>
          <UField label="Bérbeadó" hint={DORM_isLeased(f.tenure) ? 'Bérelt épületnél kötelező.' : 'Saját épületnél üresen marad.'}>
            <select className={U_input} value={f.landlord_id} onChange={e => setF({ ...f, landlord_id: e.target.value })}>
              <option value="">— nincs —</option>
              {(landlords || []).map(l => <option key={l.id} value={l.id}>{l.name}</option>)}
            </select>
          </UField>
          <UField label="Gondnok neve" hint="Szöveges mező. A JOGOSULTSÁGOT nem ez adja, hanem a Szerepkörök fül."><input className={U_input} value={f.house_manager} onChange={e => setF({ ...f, house_manager: e.target.value })} /></UField>
          <UField label="Gondnok telefon"><input className={U_input} value={f.house_manager_phone} onChange={e => setF({ ...f, house_manager_phone: e.target.value })} /></UField>
          <UField label="Szintek száma"><input type="number" className={U_input} value={f.floors_count} onChange={e => setF({ ...f, floors_count: e.target.value })} /></UField>
          <UField label="Státusz">
            <select className={U_input} value={f.is_active ? '1' : '0'} onChange={e => setF({ ...f, is_active: e.target.value === '1' })}>
              <option value="1">Aktív — használatban</option>
              <option value="0">Inaktív — kivezetve</option>
            </select>
          </UField>
          <div className="sm:col-span-2">
            <UField label="Megjegyzés"><textarea rows={2} className={U_input} value={f.note} onChange={e => setF({ ...f, note: e.target.value })} /></UField>
          </div>
        </div>
        <DORM_Err msg={err} onClose={() => setErr('')} />
        <div className="flex flex-col sm:flex-row justify-end gap-2 mt-6">
          <button onClick={() => setOpen(false)} className={U_btnGhost + ' min-h-[44px]'}>Mégsem</button>
          <button onClick={save} disabled={busy} className={U_btnPrimary + ' min-h-[44px]'}>
            {busy ? 'Mentés…' : (edit ? 'Módosítás mentése' : 'Épület felvétele')}
          </button>
        </div>
      </UModal>
    </div>
  );
}

/* ---------- 4.2 Szobák ----------------------------------------------------
   Forrás: dorm.v_room_operational — ÜZEMELTETŐI olvasat, ami a FOGLALTAK
   SZÁMÁT adja, nevet NEM. Ez szándékos: a szobalistához nem kell tudni, ki
   lakik bent, és amit nem kell látni, azt nem is mutatjuk. A nevekhez a
   Lakók fül vezet, külön jogosultsággal. */
const DORM_ROOM_STATUS_TONE = {
  available: 'bg-emerald-50 text-emerald-700 border-emerald-200',
  occupied:  'bg-blue-50 text-blue-700 border-blue-200',
  reserved:  'bg-amber-50 text-amber-700 border-amber-200',
  repair:    'bg-red-50 text-red-700 border-red-200',
  renovation:'bg-red-50 text-red-700 border-red-200',
  closed:    'bg-slate-100 text-slate-500 border-slate-200',
};

function DORM_RoomsPanel({ buildings, building, roomTypes, roomStatuses }) {
  const [rows, setRows] = useState(null);
  const [err, setErr]   = useState('');
  const [q, setQ]       = useState('');
  const [onlyFree, setOnlyFree] = useState(false);

  useEffect(() => {
    let alive = true;
    setRows(null);
    (async () => {
      const r = await DORM_sel('v_room_operational', qq => {
        let x = qq.order('building_code', { ascending: true }).order('level_no', { ascending: true }).order('room_code', { ascending: true }).limit(2000);
        if (building) x = x.eq('building_id', building);
        return x;
      });
      if (!alive) return;
      setErr(r.error);
      setRows(r.rows);
    })();
    return () => { alive = false; };
  }, [building]);

  if (rows === null) return <DORM_Loading text="Szobák betöltése…" />;

  const needle = q.trim().toLowerCase();
  const list = rows.filter(r => {
    if (onlyFree && !(Number(r.beds_lettable || 0) - Number(r.occupied_now || 0) > 0)) return false;
    if (!needle) return true;
    return [r.room_code, r.door_number, r.building_name, r.building_code, r.room_type]
      .some(v => String(v || '').toLowerCase().indexOf(needle) >= 0);
  });

  const typeLabel = (c) => { const t = (roomTypes || []).find(x => x.code === c); return (t && t.label_hu) || c || '—'; };
  const statLabel = (c) => { const s = (roomStatuses || []).find(x => x.code === c); return (s && s.label_hu) || c || '—'; };

  return (
    <div>
      <DORM_PanelHead
        title="Szobák"
        desc="Épület szerint szűrve. A FOGLALTSÁG itt szám, nem névsor — a szobalistához nem kell tudni, ki lakik bent."
        right={
          <>
            <div className="relative w-full sm:w-64">
              <DORM_Ic n="Search" size={15} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
              <input value={q} onChange={e => setQ(e.target.value)} placeholder="Szoba, ajtó, épület…"
                className={U_input + ' pl-9 min-h-[44px]'} />
            </div>
            <button onClick={() => setOnlyFree(v => !v)}
              className={(onlyFree ? U_btnPrimary : U_btnGhost) + ' min-h-[44px]'}>
              <DORM_Ic n="BedDouble" size={15} /> Csak ahol van szabad hely
            </button>
          </>
        } />

      <DORM_Err msg={err} onClose={() => setErr('')} />

      {!list.length ? (
        <DORM_Empty icon="DoorClosed" title="Nincs megjeleníthető szoba"
          subtitle="Az üres lista itt helyes válasz is lehet: a szobákat az adatbázis a hatóköre szerint szűri. Szűkítsen kevesebb szűrőre, vagy válasszon másik épületet." />
      ) : (
        <>
          <div className="text-[11px] font-black text-slate-400 uppercase tracking-widest mb-2">{DORM_num(list.length)} szoba</div>
          <DORM_Table>
            <thead className="border-b border-slate-100">
              <tr>
                <DORM_Th>Szoba</DORM_Th>
                <DORM_Th>Épület</DORM_Th>
                <DORM_Th className="text-right">Szint</DORM_Th>
                <DORM_Th>Típus</DORM_Th>
                <DORM_Th className="text-right">Ágy</DORM_Th>
                <DORM_Th className="text-right">Foglaltság</DORM_Th>
                <DORM_Th>Állapot</DORM_Th>
                <DORM_Th className="text-right">Nyitott hiba</DORM_Th>
              </tr>
            </thead>
            <tbody>
              {list.map(r => {
                const lettable = Number(r.beds_lettable || 0);
                const occ = Number(r.occupied_now || 0);
                const free = Math.max(lettable - occ, 0);
                return (
                  <tr key={r.room_id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                    <DORM_Td>
                      <div className="font-black text-slate-800">{r.room_code}</div>
                      <div className="text-[11px] text-slate-400 font-bold">
                        ajtó: {r.door_number || '—'}{r.is_accessible ? ' · akadálymentes' : ''}
                      </div>
                    </DORM_Td>
                    <DORM_Td className="text-slate-600">
                      <div className="font-semibold truncate max-w-[180px]">{r.building_name}</div>
                      <div className="text-[11px] text-slate-400 font-bold">{r.building_code}</div>
                    </DORM_Td>
                    <DORM_Td className="text-right tabular-nums text-slate-600">{r.level_no == null ? '—' : r.level_no}</DORM_Td>
                    <DORM_Td className="text-slate-600">{typeLabel(r.room_type)}</DORM_Td>
                    <DORM_Td className="text-right tabular-nums">
                      <div className="font-black text-slate-800">{DORM_num(lettable)}</div>
                      <div className="text-[11px] text-slate-400 font-bold">nyilvántartva: {DORM_num(r.beds_registered)}</div>
                    </DORM_Td>
                    <DORM_Td className="text-right tabular-nums">
                      <span className={'font-black ' + (free > 0 ? 'text-emerald-600' : 'text-slate-800')}>{DORM_num(occ)} / {DORM_num(lettable)}</span>
                      <div className="text-[11px] text-slate-400 font-bold">{free > 0 ? free + ' szabad' : 'telt'}</div>
                    </DORM_Td>
                    <DORM_Td>
                      <DORM_Chip cls={DORM_ROOM_STATUS_TONE[r.room_status] || 'bg-slate-50 text-slate-600 border-slate-200'}>
                        {statLabel(r.room_status)}
                      </DORM_Chip>
                    </DORM_Td>
                    <DORM_Td className="text-right tabular-nums">
                      {Number(r.open_issues || 0) > 0
                        ? <DORM_Chip icon="AlertTriangle" cls="bg-red-50 text-red-700 border-red-200">{r.open_issues}{r.worst_open_priority ? ' · ' + r.worst_open_priority : ''}</DORM_Chip>
                        : <span className="text-slate-300">—</span>}
                    </DORM_Td>
                  </tr>
                );
              })}
            </tbody>
          </DORM_Table>
        </>
      )}
    </div>
  );
}

/* ---------- 4.3 Lakók -----------------------------------------------------
   Forrás: dorm.v_room_occupancy — a modul LEGÉRZÉKENYEBB nézete, "ki hol
   lakik". Az adatbázis dönti el, ki látja: GONDNOK (saját épület), KOLI_ADMIN,
   KOLI_SYSADMIN, admin. A KARBANTARTO és az INGATLAN NEM — ezért ez a fül
   nekik nem is jelenik meg, és ha mégis idejutnának, ÜRES lista a helyes
   válasz, nem hibaüzenet.

   A VÉDETT lakó (bántalmazás áldozata, távoltartás, tanúvédelem) neve helyén
   az adatbázis 'VÉDETT' szöveget ad vissza. Azt NEM íratjuk ki nyersen: a
   DORM_Hidden mondja meg, hogy adatvédelmi okból rejtett. */
const DORM_OCC_STATE = {
  ALLOCATED: 'Kiosztva',
  MOVED_IN:  'Beköltözött',
  MOVED_OUT: 'Kiköltözött',
  CANCELLED: 'Visszavonva',
};

const DORM_OCC_TONE = {
  ALLOCATED: 'bg-amber-50 text-amber-700 border-amber-200',
  MOVED_IN:  'bg-emerald-50 text-emerald-700 border-emerald-200',
  MOVED_OUT: 'bg-slate-100 text-slate-500 border-slate-200',
  CANCELLED: 'bg-slate-100 text-slate-400 border-slate-200',
};

/* Egyenleg egy lakóra: kiszámlázott mínusz befizetett, a nem lezárt
   tételekből. A pénzügyi igazság a gazdasági rendszeré — ez tájékoztató
   szám, hogy a kiköltözésnél legyen mire rákérdezni. */
function DORM_balanceOf(charges, personId) {
  let open = 0;
  (charges || []).forEach(c => {
    if (c.person_id !== personId) return;
    if (['waived', 'written_off', 'refunded'].indexOf(c.status) >= 0) return;
    open += Number(c.amount || 0) - Number(c.paid_amount || 0);
  });
  return Math.round(open);
}

function DORM_ResidentsPanel({ building, canSeeNames }) {
  const [rows, setRows] = useState(null);
  const [charges, setCharges] = useState([]);
  const [err, setErr] = useState('');
  const [q, setQ] = useState('');
  const [onlyCurrent, setOnlyCurrent] = useState(true);

  useEffect(() => {
    let alive = true;
    setRows(null);
    (async () => {
      const [occ, ch] = await Promise.all([
        DORM_sel('v_room_occupancy', qq => {
          let x = qq.order('building_code', { ascending: true }).order('room_code', { ascending: true }).limit(2000);
          if (building) x = x.eq('building_id', building);
          return x;
        }),
        DORM_sel('charge', qq => qq.limit(4000)),
      ]);
      if (!alive) return;
      setErr(occ.error);
      setRows(occ.rows);
      setCharges(ch.rows);
    })();
    return () => { alive = false; };
  }, [building]);

  if (!canSeeNames) {
    return <DORM_Empty icon="EyeOff" title="A lakói névsor ehhez a szerepkörhöz nem tartozik"
      subtitle="A „ki hol lakik” adatot az adatbázis GONDNOK (saját épület), KOLI_ADMIN, KOLI_SYSADMIN és admin körre szűkíti. A karbantartói és az ingatlangazdai munkához a szoba és a hiba elég — a felület ezt a korlátot nem kerüli meg." />;
  }
  if (rows === null) return <DORM_Loading text="Lakók betöltése…" />;

  const today = DORM_today();
  const needle = q.trim().toLowerCase();
  const list = rows.filter(r => {
    const p = DORM_period(r.period);
    if (onlyCurrent) {
      if (p.from && String(p.from) > today) return false;
      if (p.to && String(p.to) <= today) return false;
      if (r.state === 'MOVED_OUT' || r.state === 'CANCELLED') return false;
    }
    if (!needle) return true;
    return [r.display_name, r.room_code, r.bed_code, r.building_name, r.student_id, r.contract_ref]
      .some(v => String(v || '').toLowerCase().indexOf(needle) >= 0);
  });

  return (
    <div>
      <DORM_PanelHead
        title="Lakók"
        desc="Ki hol lakik, mettől meddig, milyen szerződéssel, mekkora nyitott egyenleggel. Minden megtekintés naplózódik — a modulnál a jogosulatlan OLVASÁS a kár, nem a módosítás."
        right={
          <>
            <div className="relative w-full sm:w-64">
              <DORM_Ic n="Search" size={15} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
              <input value={q} onChange={e => setQ(e.target.value)} placeholder="Név, szoba, szerződés…" className={U_input + ' pl-9 min-h-[44px]'} />
            </div>
            <button onClick={() => setOnlyCurrent(v => !v)} className={(onlyCurrent ? U_btnPrimary : U_btnGhost) + ' min-h-[44px]'}>
              <DORM_Ic n="CalendarCheck" size={15} /> {onlyCurrent ? 'Csak a mai nap' : 'Teljes előzmény'}
            </button>
          </>
        } />

      <DORM_Err msg={err} onClose={() => setErr('')} />

      {!list.length ? (
        <DORM_Empty icon="Users" title="Nincs megjeleníthető lakó"
          subtitle="Az üres lista itt helyes válasz is lehet: az adatbázis a hatóköre szerint szűr. Ha teljes előzményre vált, a korábbi elhelyezések is megjelennek." />
      ) : (
        <>
          <div className="text-[11px] font-black text-slate-400 uppercase tracking-widest mb-2">{DORM_num(list.length)} elhelyezés</div>
          <DORM_Table>
            <thead className="border-b border-slate-100">
              <tr>
                <DORM_Th>Lakó</DORM_Th>
                <DORM_Th>Hol lakik</DORM_Th>
                <DORM_Th>Mettől meddig</DORM_Th>
                <DORM_Th>Állapot</DORM_Th>
                <DORM_Th>Szerződés</DORM_Th>
                <DORM_Th className="text-right">Egyenleg</DORM_Th>
              </tr>
            </thead>
            <tbody>
              {list.map(r => {
                const p = DORM_period(r.period);
                const hidden = !r.display_name || r.protected || r.display_name === 'VÉDETT';
                const bal = DORM_balanceOf(charges, r.person_id);
                return (
                  <tr key={r.occupancy_id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                    <DORM_Td>
                      {hidden ? (
                        <DORM_Hidden label="Lakó neve" reason="Védett lakó, vagy a szerepköre nem jogosít a névre. Az adatbázis rejtette el, nem a felület." />
                      ) : (
                        <>
                          <div className="font-black text-slate-800 break-words">{r.display_name}</div>
                          <div className="text-[11px] text-slate-400 font-bold">{r.student_id || r.email || '—'}</div>
                        </>
                      )}
                    </DORM_Td>
                    <DORM_Td className="text-slate-600">
                      <div className="font-semibold">{r.room_code} <span className="text-slate-400">/ {r.bed_code}</span></div>
                      <div className="text-[11px] text-slate-400 font-bold truncate max-w-[180px]">{r.building_name}</div>
                    </DORM_Td>
                    <DORM_Td className="text-slate-600 whitespace-nowrap font-semibold">{p.text}</DORM_Td>
                    <DORM_Td>
                      <DORM_Chip cls={DORM_OCC_TONE[r.state] || 'bg-slate-50 text-slate-600 border-slate-200'}>
                        {DORM_OCC_STATE[r.state] || r.state}
                      </DORM_Chip>
                    </DORM_Td>
                    <DORM_Td className="text-slate-600">
                      <div className="font-semibold">{r.contract_ref || '—'}</div>
                      {r.contract_ends_on && <div className="text-[11px] text-slate-400 font-bold">lejár: {DORM_d(r.contract_ends_on)}</div>}
                    </DORM_Td>
                    <DORM_Td className="text-right tabular-nums">
                      <span className={'font-black ' + (bal > 0 ? 'text-red-600' : 'text-emerald-600')}>{DORM_money(bal)}</span>
                      <div className="text-[11px] text-slate-400 font-bold">{bal > 0 ? 'nyitott tartozás' : 'rendezve'}</div>
                    </DORM_Td>
                  </tr>
                );
              })}
            </tbody>
          </DORM_Table>
        </>
      )}
    </div>
  );
}

/* ---------- 4.4 Be- és kiköltözés -----------------------------------------
   Négy dolog EGY képernyőn, mert a valóságban is egyszerre történnek:
   jegyzőkönyv, kulcsátadás, leltár és kaució-elszámolás. A jegyzőkönyv a
   modul egyik legfontosabb bizonyítéka: a bérlet legdrágább pillanata a
   VISSZAADÁS, és az egyetlen védekezés a birtokbaadáskor készült,
   időbélyeges leírás — ami ÉVEK MÚLVA is előkereshető.

   A kaució NEM BEVÉTEL, hanem KÖTELEZETTSÉG: ha bevételként kezeljük, a
   visszafizetéskor lesz baj. És amíg az akadály (kulcs, hátralék, kárügy) ki
   van töltve, a visszafizetés le van tiltva — a pénz az egyetlen megbízható
   kényszerítő erő. */
const DORM_HANDOVER_KIND = {
  BUILDING_TAKEOVER: 'Épület birtokbavétele',
  BUILDING_RETURN:   'Épület visszaadása',
  ROOM_MOVE_IN:      'Beköltözés',
  ROOM_MOVE_OUT:     'Kiköltözés',
  ROOM_SWAP:         'Szobacsere',
  JOINT_INSPECTION:  'Közös szemle',
};

const DORM_DEPOSIT_STATUS = {
  HELD:              'Letétben',
  PARTIALLY_SETTLED: 'Részben elszámolva',
  SETTLED:           'Elszámolva',
  REFUNDED:          'Visszafizetve',
  FORFEITED:         'Elvesztette',
  OVERDUE:           'Késedelmes',
};

function DORM_MoveInOutPanel({ buildings, building, canWrite }) {
  const [rows, setRows]       = useState(null);
  const [keys, setKeys]       = useState([]);
  const [deposits, setDeps]   = useState([]);
  const [err, setErr]         = useState('');
  const [open, setOpen]       = useState(false);
  const [busy, setBusy]       = useState(false);
  const [ferr, setFerr]       = useState('');
  const [sub, setSub]         = useState('log');
  const [f, setF] = useState({
    kind: 'ROOM_MOVE_IN', building_id: '', happened_at: '', participants: '',
    keys_listed: '', deficiencies: '', remarks: '',
  });

  const load = async () => {
    setRows(null);
    const [h, k, d] = await Promise.all([
      DORM_sel('handover', qq => {
        let x = qq.order('happened_at', { ascending: false }).limit(400);
        if (building) x = x.eq('building_id', building);
        return x;
      }),
      DORM_sel('key_issue', qq => qq.order('issued_at', { ascending: false }).limit(400)),
      DORM_sel('deposit', qq => qq.eq('direction', 'HELD_FROM_RESIDENT').order('created_at', { ascending: false }).limit(400)),
    ]);
    setErr(h.error);
    setRows(h.rows);
    setKeys(k.rows);
    setDeps(d.rows);
  };

  useEffect(() => { load(); }, [building]);

  const save = async () => {
    if (!f.building_id) { setFerr('Épületet választani kell — jegyzőkönyv épület nélkül nem kereshető vissza.'); return; }
    setBusy(true); setFerr('');
    try {
      await DORM_ins('handover', {
        kind: f.kind,
        building_id: f.building_id,
        happened_at: f.happened_at ? new Date(f.happened_at).toISOString() : new Date().toISOString(),
        participants: f.participants.trim() || null,
        keys_listed: f.keys_listed.trim()
          ? { tetelek: f.keys_listed.split('\n').map(s => s.trim()).filter(Boolean) }
          : null,
        deficiencies: f.deficiencies.trim() || null,
        remarks: f.remarks.trim() || null,
      });
      setOpen(false);
      setF({ kind: 'ROOM_MOVE_IN', building_id: '', happened_at: '', participants: '', keys_listed: '', deficiencies: '', remarks: '' });
      load();
    } catch (e) { setFerr(DORM_msg(e)); }
    setBusy(false);
  };

  if (rows === null) return <DORM_Loading text="Jegyzőkönyvek betöltése…" />;

  const openKeys = keys.filter(k => !k.returned_at);
  const blocked  = deposits.filter(d => d.settlement_blocked_reason);

  const subTabs = [
    { id: 'log',      label: 'Jegyzőkönyvek', icon: 'ClipboardList', count: rows.length },
    { id: 'keys',     label: 'Kulcsok',       icon: 'KeyRound',      count: openKeys.length },
    { id: 'deposits', label: 'Kaució',        icon: 'PiggyBank',     count: deposits.length },
  ];

  return (
    <div>
      <DORM_PanelHead
        title="Be- és kiköltözés"
        desc="Jegyzőkönyv, kulcsátadás, leltár és kaució-elszámolás. Ami a beköltözéskor nincs leírva, azt a kiköltözéskor nem lehet bizonyítani."
        right={canWrite && (
          <button onClick={() => { setFerr(''); setOpen(true); }} className={U_btnPrimary + ' min-h-[44px] w-full sm:w-auto'}>
            <DORM_Ic n="FilePlus2" size={16} /> Új jegyzőkönyv
          </button>
        )} />

      <DORM_Err msg={err} onClose={() => setErr('')} />

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-5">
        <DORM_Stat label="Jegyzőkönyv" value={DORM_num(rows.length)} icon="ClipboardList" hint="a látható épületekben" />
        <DORM_Stat label="Kint lévő kulcs" value={DORM_num(openKeys.length)} icon="KeyRound" tone={openKeys.length ? 'amber' : 'green'} hint="még nem érkezett vissza" />
        <DORM_Stat label="Kaució letétben" value={DORM_num(deposits.filter(d => d.status === 'HELD').length)} icon="PiggyBank" hint="kötelezettség, nem bevétel" />
        <DORM_Stat label="Blokkolt elszámolás" value={DORM_num(blocked.length)} icon="Lock" tone={blocked.length ? 'red' : 'green'} hint="akadály miatt nem fizethető vissza" />
      </div>

      <DORM_Tabs tabs={subTabs} tab={sub} setTab={setSub} />

      {sub === 'log' && (!rows.length ? (
        <DORM_Empty icon="ClipboardList" title="Még nincs jegyzőkönyv"
          subtitle="Az első birtokbaadási jegyzőkönyv a legfontosabb: erre hivatkozik majd minden későbbi kárvita." />
      ) : (
        <DORM_Table>
          <thead className="border-b border-slate-100">
            <tr>
              <DORM_Th>Esemény</DORM_Th>
              <DORM_Th>Épület</DORM_Th>
              <DORM_Th>Mikor</DORM_Th>
              <DORM_Th>Résztvevők</DORM_Th>
              <DORM_Th>Kulcsok</DORM_Th>
              <DORM_Th>Hiányosság</DORM_Th>
            </tr>
          </thead>
          <tbody>
            {rows.map(h => {
              const kl = h.keys_listed && Array.isArray(h.keys_listed.tetelek) ? h.keys_listed.tetelek : [];
              return (
                <tr key={h.id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                  <DORM_Td><span className="font-black text-slate-800">{DORM_HANDOVER_KIND[h.kind] || h.kind}</span></DORM_Td>
                  <DORM_Td className="text-slate-600 truncate max-w-[200px]">{DORM_bName(buildings, h.building_id)}</DORM_Td>
                  <DORM_Td className="text-slate-600 whitespace-nowrap font-semibold">{DORM_dt(h.happened_at)}</DORM_Td>
                  <DORM_Td className="text-slate-600 max-w-[220px]"><span className="break-words">{h.participants || '—'}</span></DORM_Td>
                  <DORM_Td className="text-slate-600">{kl.length ? kl.length + ' tétel' : '—'}</DORM_Td>
                  <DORM_Td className="max-w-[240px]">
                    {h.deficiencies
                      ? <span className="text-red-600 font-semibold break-words">{h.deficiencies}</span>
                      : <span className="text-emerald-600 font-semibold">nincs</span>}
                  </DORM_Td>
                </tr>
              );
            })}
          </tbody>
        </DORM_Table>
      ))}

      {sub === 'keys' && (!keys.length ? (
        <DORM_Empty icon="KeyRound" title="Nincs kulcskiadási tétel"
          subtitle="A kulcsnyilvántartás akkor ér valamit, ha a kiadás és a visszavétel is rögzül — a kint felejtett kulcs zárcserét jelent." />
      ) : (
        <DORM_Table>
          <thead className="border-b border-slate-100">
            <tr>
              <DORM_Th>Kiadva</DORM_Th>
              <DORM_Th>Lakó</DORM_Th>
              <DORM_Th>Visszavéve</DORM_Th>
              <DORM_Th>Elveszett</DORM_Th>
              <DORM_Th>Zárcsere</DORM_Th>
              <DORM_Th className="text-right">Díj</DORM_Th>
            </tr>
          </thead>
          <tbody>
            {keys.map(k => (
              <tr key={k.id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                <DORM_Td className="text-slate-600 whitespace-nowrap font-semibold">{DORM_dt(k.issued_at)}</DORM_Td>
                <DORM_Td><DORM_Hidden label="Lakó" reason="A kulcsnyilvántartás a személyt azonosítóval hivatkozza; a névhez a Lakók fül jogosultsága kell." /></DORM_Td>
                <DORM_Td>
                  {k.returned_at
                    ? <span className="text-emerald-600 font-semibold whitespace-nowrap">{DORM_dt(k.returned_at)}</span>
                    : <DORM_Chip icon="AlertTriangle" cls="bg-amber-50 text-amber-700 border-amber-200">kint van</DORM_Chip>}
                </DORM_Td>
                <DORM_Td className="text-slate-600">{k.lost_at ? DORM_d(k.lost_at) : '—'}</DORM_Td>
                <DORM_Td>{k.lock_changed ? <DORM_Chip icon="Lock" cls="bg-red-50 text-red-700 border-red-200">megtörtént</DORM_Chip> : <span className="text-slate-300">—</span>}</DORM_Td>
                <DORM_Td className="text-right tabular-nums font-semibold text-slate-700">{DORM_money(k.fee_charged)}</DORM_Td>
              </tr>
            ))}
          </tbody>
        </DORM_Table>
      ))}

      {sub === 'deposits' && (!deposits.length ? (
        <DORM_Empty icon="PiggyBank" title="Nincs lakói kaució nyilvántartva"
          subtitle="A lakótól átvett kaució kötelezettség, nem bevétel. Az elszámolás zárt levezetés: kaució − igazolt kár − elmaradt díj = visszafizetendő." />
      ) : (
        <DORM_Table>
          <thead className="border-b border-slate-100">
            <tr>
              <DORM_Th>Lakó</DORM_Th>
              <DORM_Th className="text-right">Kaució</DORM_Th>
              <DORM_Th className="text-right">Levonás</DORM_Th>
              <DORM_Th className="text-right">Visszafizetendő</DORM_Th>
              <DORM_Th>Állapot</DORM_Th>
              <DORM_Th>Akadály</DORM_Th>
            </tr>
          </thead>
          <tbody>
            {deposits.map(d => {
              const back = Number(d.amount || 0) - Number(d.deductions || 0);
              return (
                <tr key={d.id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                  <DORM_Td><DORM_Hidden label="Lakó" reason="A kaució-sor a személyt azonosítóval hivatkozza; a névhez a Lakók fül jogosultsága kell." /></DORM_Td>
                  <DORM_Td className="text-right tabular-nums font-black text-slate-800">{DORM_money(d.amount, d.currency)}</DORM_Td>
                  <DORM_Td className="text-right tabular-nums text-red-600 font-semibold">{DORM_money(d.deductions, d.currency)}</DORM_Td>
                  <DORM_Td className="text-right tabular-nums font-black text-emerald-700">{DORM_money(back, d.currency)}</DORM_Td>
                  <DORM_Td><DORM_Chip cls="bg-slate-50 text-slate-600 border-slate-200">{DORM_DEPOSIT_STATUS[d.status] || d.status}</DORM_Chip></DORM_Td>
                  <DORM_Td className="max-w-[240px]">
                    {d.settlement_blocked_reason
                      ? <span className="text-red-600 font-semibold break-words">{d.settlement_blocked_reason}</span>
                      : <span className="text-slate-300">—</span>}
                  </DORM_Td>
                </tr>
              );
            })}
          </tbody>
        </DORM_Table>
      ))}

      <UModal open={open} onClose={() => setOpen(false)} max="max-w-2xl"
        title="Új jegyzőkönyv" subtitle="Amit ma nem írunk le, azt később nem lehet bizonyítani."
        icon={<DORM_Ic n="ClipboardList" size={20} />}>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <UField label="Esemény típusa">
            <select className={U_input} value={f.kind} onChange={e => setF({ ...f, kind: e.target.value })}>
              {Object.keys(DORM_HANDOVER_KIND).map(k => <option key={k} value={k}>{DORM_HANDOVER_KIND[k]}</option>)}
            </select>
          </UField>
          <UField label="Épület">
            <select className={U_input} value={f.building_id} onChange={e => setF({ ...f, building_id: e.target.value })}>
              <option value="">— válasszon —</option>
              {(buildings || []).map(b => <option key={b.id} value={b.id}>{(b.code ? b.code + ' · ' : '') + b.name}</option>)}
            </select>
          </UField>
          <UField label="Mikor történt" hint="Üresen hagyva a mostani időpont.">
            <input type="datetime-local" className={U_input} value={f.happened_at} onChange={e => setF({ ...f, happened_at: e.target.value })} />
          </UField>
          <UField label="Résztvevők" hint="Ki volt jelen: gondnok, lakó, bérbeadó képviselője.">
            <input className={U_input} value={f.participants} onChange={e => setF({ ...f, participants: e.target.value })} />
          </UField>
          <div className="sm:col-span-2">
            <UField label="Átadott kulcsok, kártyák" hint="Soronként egy tétel.">
              <textarea rows={3} className={U_input} value={f.keys_listed} onChange={e => setF({ ...f, keys_listed: e.target.value })} placeholder={'A/312 szobakulcs\nbelépőkártya #0421'} />
            </UField>
          </div>
          <div className="sm:col-span-2">
            <UField label="Hiányosságok, sérülések" hint="A leltár és az állapot rögzítése. Ez a mező védi a lakót és az egyetemet is.">
              <textarea rows={3} className={U_input} value={f.deficiencies} onChange={e => setF({ ...f, deficiencies: e.target.value })} />
            </UField>
          </div>
          <div className="sm:col-span-2">
            <UField label="Megjegyzés"><textarea rows={2} className={U_input} value={f.remarks} onChange={e => setF({ ...f, remarks: e.target.value })} /></UField>
          </div>
        </div>
        <DORM_Err msg={ferr} onClose={() => setFerr('')} />
        <div className="flex flex-col sm:flex-row justify-end gap-2 mt-6">
          <button onClick={() => setOpen(false)} className={U_btnGhost + ' min-h-[44px]'}>Mégsem</button>
          <button onClick={save} disabled={busy} className={U_btnPrimary + ' min-h-[44px]'}>{busy ? 'Mentés…' : 'Jegyzőkönyv rögzítése'}</button>
        </div>
      </UModal>
    </div>
  );
}

/* ---------- 4.5 Várólista -------------------------------------------------
   A várólista NEM SORSZÁM, hanem PONTSZÁM: a rangsort minden kiosztáskor
   újraszámoljuk, mert közben új jelentkező is jöhet. Ezért itt pont szerint
   rendezünk, és a pontok bontását is meg lehet nézni — enélkül a "miért
   kaptam kevesebbet, mint a szobatársam" kérdésre nincs védhető válasz.

   AZ EGY KATTINTÁSOS AJÁNLATTÉTEL a szabad helyek listájából dolgozik
   (dorm_free_beds), és MINDIG ad LEJÁRATOT. A lejárat nélküli ajánlat a
   legnagyobb kapacitásvesztés-forrás: a hely beragad egy jelentkezőnél, aki
   már rég máshol lakik. A lejárt ajánlatokat a dorm_expire_offers() söpri. */
const DORM_APP_STATUS = {
  Draft: 'Piszkozat', Submitted: 'Beadva', Ineligible: 'Nem jogosult', Scored: 'Pontozva',
  Waitlisted: 'Várólistán', Offered: 'Ajánlat kiadva', Declined: 'Visszautasította',
  Expired: 'Ajánlat lejárt', Accepted: 'Elfogadta', Contracted: 'Szerződött',
  MovedIn: 'Beköltözött', MovedOut: 'Kiköltözött', Withdrawn: 'Visszavonva',
};

const DORM_APP_TONE = {
  Waitlisted: 'bg-amber-50 text-amber-700 border-amber-200',
  Offered:    'bg-blue-50 text-blue-700 border-blue-200',
  Scored:     'bg-slate-50 text-slate-600 border-slate-200',
  Submitted:  'bg-slate-50 text-slate-600 border-slate-200',
  Accepted:   'bg-emerald-50 text-emerald-700 border-emerald-200',
  Expired:    'bg-red-50 text-red-700 border-red-200',
};

const DORM_WAIT_STATES = ['Submitted', 'Scored', 'Waitlisted', 'Offered'];

function DORM_WaitlistPanel({ building, canOffer }) {
  const [apps, setApps]   = useState(null);
  const [people, setPeople] = useState([]);
  const [free, setFree]   = useState([]);
  const [err, setErr]     = useState('');
  const [busy, setBusy]   = useState('');
  const [note, setNote]   = useState('');

  const load = async () => {
    setApps(null);
    const [a, p] = await Promise.all([
      DORM_sel('application', qq => qq.in('status', DORM_WAIT_STATES).order('score', { ascending: false, nullsFirst: false }).limit(500)),
      DORM_sel('person', qq => qq.limit(2000)),
    ]);
    setErr(a.error);
    setApps(a.rows);
    setPeople(p.rows);
    // A szabad helyek listája külön jogosultságot igényel (GONDNOK / KOLI_ADMIN /
    // KOLI_SYSADMIN). Ha nincs, az ajánlattétel gomb egyszerűen nem működik —
    // nem hibaüzenettel, hanem hiányzó gombbal.
    try {
      const fb = await DORM_api.freeBeds({ p_building: building || null, p_limit: 200 });
      setFree(Array.isArray(fb) ? fb : []);
    } catch (e) { setFree([]); }
  };

  useEffect(() => { load(); }, [building]);

  const nameOf = (pid) => {
    const p = people.find(x => x.id === pid);
    return p ? p.display_name : null;
  };

  const makeOffer = async (app) => {
    const bed = free[0];
    if (!bed) { setErr('Nincs kiajánlható szabad férőhely a kiválasztott körben. Előbb szabadítson fel helyet, vagy váltson épületet.'); return; }
    setBusy(app.id); setErr(''); setNote('');
    try {
      const expires = new Date(Date.now() + 7 * 24 * 3600 * 1000).toISOString();
      await DORM_upd('application', app.id, {
        status: 'Offered',
        offered_bed_id: bed.bed_id,
        offer_sent_at: new Date().toISOString(),
        offer_expires_at: expires,
      });
      setNote('Ajánlat kiadva: ' + (bed.room_code || '') + ' / ' + (bed.bed_code || '') + ' — a jelentkezőnek 7 napja van elfogadni.');
      await load();
    } catch (e) { setErr(DORM_msg(e)); }
    setBusy('');
  };

  const expireAll = async () => {
    setBusy('expire'); setErr(''); setNote('');
    try {
      const r = await DORM_api.expireOffers();
      const n = (r && (r.lejartatott || r.count)) != null ? (r.lejartatott != null ? r.lejartatott : r.count) : null;
      setNote(n == null ? 'A lejárt ajánlatok lezárva.' : 'Lejáratott ajánlat: ' + n + '.');
      await load();
    } catch (e) { setErr(DORM_msg(e)); }
    setBusy('');
  };

  if (apps === null) return <DORM_Loading text="Várólista betöltése…" />;

  const waiting = apps.filter(a => a.status === 'Waitlisted' || a.status === 'Scored' || a.status === 'Submitted');
  const offered = apps.filter(a => a.status === 'Offered');

  return (
    <div>
      <DORM_PanelHead
        title="Várólista"
        desc="Várakozó kérelmek pontszám szerint. Az ajánlat mindig lejárattal megy ki — a lejárat nélküli ajánlat beragasztja a férőhelyet."
        right={canOffer && (
          <button onClick={expireAll} disabled={busy === 'expire'} className={U_btnGhost + ' min-h-[44px] w-full sm:w-auto'}>
            <DORM_Ic n="TimerReset" size={15} /> {busy === 'expire' ? 'Fut…' : 'Lejárt ajánlatok lezárása'}
          </button>
        )} />

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-5">
        <DORM_Stat label="Várakozik" value={DORM_num(waiting.length)} icon="Users" tone="amber" hint="pontozva, hely nélkül" />
        <DORM_Stat label="Kiadott ajánlat" value={DORM_num(offered.length)} icon="MailCheck" tone="blue" hint="visszajelzésre vár" />
        <DORM_Stat label="Kiajánlható hely" value={DORM_num(free.length)} icon="BedDouble" tone={free.length ? 'green' : 'red'} hint="dorm_free_beds()" />
        <DORM_Stat label="Legmagasabb pont" value={waiting.length ? DORM_num(waiting[0].score) : '—'} icon="Trophy" hint="a lista élén" />
      </div>

      <DORM_Err msg={err} onClose={() => setErr('')} />
      {note && (
        <div className="mb-4 flex items-start gap-2 bg-emerald-50 border border-emerald-100 text-emerald-800 rounded-2xl px-4 py-3 text-sm font-semibold">
          <DORM_Ic n="CheckCircle2" size={16} className="mt-0.5 flex-none" /><span className="min-w-0 break-words">{note}</span>
        </div>
      )}

      {!apps.length ? (
        <DORM_Empty icon="ListOrdered" title="Nincs várakozó kérelem"
          subtitle="Vagy nincs nyitott jelentkezési időszak, vagy mindenki helyet kapott. A lista pontszám szerint rendeződik, és minden kiosztáskor újraszámolódik." />
      ) : (
        <DORM_Table>
          <thead className="border-b border-slate-100">
            <tr>
              <DORM_Th className="text-right">#</DORM_Th>
              <DORM_Th>Jelentkező</DORM_Th>
              <DORM_Th className="text-right">Pont</DORM_Th>
              <DORM_Th>Időszak</DORM_Th>
              <DORM_Th>Igény</DORM_Th>
              <DORM_Th>Állapot</DORM_Th>
              <DORM_Th>Ajánlat lejár</DORM_Th>
              {canOffer && <DORM_Th className="text-right">Művelet</DORM_Th>}
            </tr>
          </thead>
          <tbody>
            {apps.map((a, i) => {
              const nm = nameOf(a.person_id);
              return (
                <tr key={a.id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                  <DORM_Td className="text-right tabular-nums text-slate-400 font-black">{i + 1}</DORM_Td>
                  <DORM_Td>
                    {nm
                      ? <span className="font-black text-slate-800 break-words">{nm}</span>
                      : <DORM_Hidden label="Jelentkező" reason="A jelentkező neve ehhez a szerepkörhöz nem látható — az adatbázis szűrte ki." />}
                    {a.medical_need && <div className="text-[11px] text-amber-600 font-bold mt-0.5">egészségügyi igény jelezve</div>}
                  </DORM_Td>
                  <DORM_Td className="text-right tabular-nums">
                    <span className="font-black text-slate-800">{a.score == null ? '—' : DORM_num(a.score)}</span>
                    {a.score_breakdown && <div className="text-[11px] text-slate-400 font-bold">bontással</div>}
                  </DORM_Td>
                  <DORM_Td className="text-slate-600 whitespace-nowrap font-semibold">
                    {a.period_kind === 'full_year' ? 'Teljes tanév'
                      : a.period_kind === 'semester_1' ? '1. félév'
                      : a.period_kind === 'semester_2' ? '2. félév' : 'Rövid tartózkodás'}
                  </DORM_Td>
                  <DORM_Td>
                    {a.requires_accessible
                      ? <DORM_Chip icon="Accessibility" cls="bg-blue-50 text-blue-700 border-blue-200">akadálymentes</DORM_Chip>
                      : <span className="text-slate-300">—</span>}
                  </DORM_Td>
                  <DORM_Td>
                    <DORM_Chip cls={DORM_APP_TONE[a.status] || 'bg-slate-50 text-slate-600 border-slate-200'}>
                      {DORM_APP_STATUS[a.status] || a.status}
                    </DORM_Chip>
                  </DORM_Td>
                  <DORM_Td className="text-slate-600 whitespace-nowrap font-semibold">{a.offer_expires_at ? DORM_dt(a.offer_expires_at) : '—'}</DORM_Td>
                  {canOffer && (
                    <DORM_Td className="text-right">
                      {a.status === 'Offered' ? (
                        <span className="text-[11px] font-bold text-slate-400">ajánlat kint</span>
                      ) : (
                        <button onClick={() => makeOffer(a)} disabled={busy === a.id || !free.length}
                          title={free.length ? 'Ajánlat a lista első szabad férőhelyére, 7 napos lejárattal.' : 'Nincs kiajánlható szabad férőhely.'}
                          className={U_btnPrimary + ' !px-3 min-h-[44px]'}>
                          <DORM_Ic n="Send" size={14} /> {busy === a.id ? 'Küldés…' : 'Ajánlat'}
                        </button>
                      )}
                    </DORM_Td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </DORM_Table>
      )}
    </div>
  );
}

/* ---------- 4.6 Bérlemények -----------------------------------------------
   CSAK KÜLSŐS (bérelt) épületekre. Láthatóság: INGATLAN vagy admin.

   A LEJÁRATFIGYELÉS a fül lényege, és NEM a lejáratot mutatja, hanem a
   DÖNTÉSI HATÁRIDŐT (dorm_lease_alerts → decision_due_on): lejárat mínusz
   felmondási idő mínusz előkészítési puffer. Ha a riport a lejáratot mutatná,
   a rendszer "időben szólna", miközben a felmondási idő már lejárt és a
   szerződés automatikusan meghosszabbodott.

   A rezsinél a "saját leolvasással ellenőrizve" jelölés dönti el, van-e mivel
   vitatkozni egy bérbeadói továbbszámlázásnál. Enélkül fizetünk. */
const DORM_UTIL_MODE = {
  SUBMETER:          'Almérő szerint',
  FLAT_RATE:         'Átalány',
  INCLUDED_IN_RENT:  'A bérleti díj tartalmazza',
  DIRECT_CONTRACT:   'Közvetlen közműszerződés',
};

function DORM_LeasesPanel({ buildings, landlords, building }) {
  const [leases, setLeases] = useState(null);
  const [alerts, setAlerts] = useState([]);
  const [bills, setBills]   = useState([]);
  const [err, setErr]       = useState('');
  const [sub, setSub]       = useState('contracts');

  useEffect(() => {
    let alive = true;
    setLeases(null);
    (async () => {
      const [l, u] = await Promise.all([
        DORM_sel('lease', qq => {
          let x = qq.order('decision_due_on', { ascending: true, nullsFirst: false }).limit(300);
          if (building) x = x.eq('building_id', building);
          return x;
        }),
        DORM_sel('utility_bill', qq => {
          let x = qq.order('created_at', { ascending: false }).limit(300);
          if (building) x = x.eq('building_id', building);
          return x;
        }),
      ]);
      let al = [];
      try { al = (await DORM_api.leaseAlerts(365)) || []; } catch (e) { al = []; }
      if (!alive) return;
      setErr(l.error);
      setLeases(l.rows);
      setBills(u.rows);
      setAlerts(Array.isArray(al) ? al : []);
    })();
    return () => { alive = false; };
  }, [building]);

  if (leases === null) return <DORM_Loading text="Bérleti szerződések betöltése…" />;

  const leasedBuildings = (buildings || []).filter(b => DORM_isLeased(b.tenure));
  const urgent = alerts.filter(a => Number(a.days_left) <= 90);

  const subTabs = [
    { id: 'contracts', label: 'Szerződések',  icon: 'FileSignature', count: leases.length },
    { id: 'utilities', label: 'Rezsi',        icon: 'Zap',           count: bills.length },
    { id: 'alerts',    label: 'Lejáratok',    icon: 'BellRing',      count: alerts.length },
    { id: 'landlords', label: 'Bérbeadók',    icon: 'Contact',       count: (landlords || []).length },
  ];

  return (
    <div>
      <DORM_PanelHead
        title="Bérlemények"
        desc="Csak a külsős (bérelt) épületek. A saját tulajdonú épületeknek nincs bérleti szerződésük, ezért itt nem is jelennek meg." />

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-5">
        <DORM_Stat label="Bérelt épület" value={DORM_num(leasedBuildings.length)} icon="Building2" tone="violet" />
        <DORM_Stat label="Élő szerződés" value={DORM_num(leases.filter(l => l.is_active !== false).length)} icon="FileSignature" />
        <DORM_Stat label="Döntés 90 napon belül" value={DORM_num(urgent.length)} icon="BellRing" tone={urgent.length ? 'red' : 'green'} hint="lejárat − felmondási idő − puffer" />
        <DORM_Stat label="Rezsiszámla" value={DORM_num(bills.length)} icon="Zap" hint={DORM_num(bills.filter(b => b.verified_against_own_reading).length) + ' ellenőrizve saját leolvasással'} />
      </div>

      <DORM_Err msg={err} onClose={() => setErr('')} />
      <DORM_Tabs tabs={subTabs} tab={sub} setTab={setSub} />

      {sub === 'contracts' && (!leases.length ? (
        <DORM_Empty icon="FileSignature" title="Nincs rögzített bérleti szerződés"
          subtitle="Ha van bérelt épület, de nincs mögötte szerződés, a lejáratfigyelés vak: nem tud szólni, mielőtt a felmondási idő lejár." />
      ) : (
        <DORM_Table>
          <thead className="border-b border-slate-100">
            <tr>
              <DORM_Th>Épület</DORM_Th>
              <DORM_Th>Iktatószám</DORM_Th>
              <DORM_Th>Tart</DORM_Th>
              <DORM_Th className="text-right">Havi díj</DORM_Th>
              <DORM_Th>Rezsi</DORM_Th>
              <DORM_Th>Döntési határidő</DORM_Th>
              <DORM_Th>Megújulás</DORM_Th>
            </tr>
          </thead>
          <tbody>
            {leases.map(l => {
              const days = l.decision_due_on ? Math.round((new Date(l.decision_due_on) - new Date()) / 86400000) : null;
              return (
                <tr key={l.id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                  <DORM_Td className="text-slate-700 font-semibold max-w-[200px]"><span className="break-words">{DORM_bName(buildings, l.building_id)}</span></DORM_Td>
                  <DORM_Td className="text-slate-600 font-semibold">{l.iktatoszam || '—'}</DORM_Td>
                  <DORM_Td className="text-slate-600 whitespace-nowrap">{DORM_d(l.starts_on)} – {l.ends_on ? DORM_d(l.ends_on) : 'határozatlan'}</DORM_Td>
                  <DORM_Td className="text-right tabular-nums font-black text-slate-800">{DORM_money(l.monthly_rent, l.rent_currency)}</DORM_Td>
                  <DORM_Td className="text-slate-600">{DORM_UTIL_MODE[l.utilities_mode] || l.utilities_mode}</DORM_Td>
                  <DORM_Td>
                    {l.decision_due_on ? (
                      <div className="whitespace-nowrap">
                        <span className={'font-black ' + (days != null && days <= 90 ? 'text-red-600' : 'text-slate-800')}>{DORM_d(l.decision_due_on)}</span>
                        <div className="text-[11px] text-slate-400 font-bold">
                          {days == null ? '' : days < 0 ? Math.abs(days) + ' napja lejárt' : days + ' nap múlva'}
                        </div>
                      </div>
                    ) : <span className="text-slate-300">—</span>}
                  </DORM_Td>
                  <DORM_Td>
                    {l.auto_renew
                      ? <DORM_Chip icon="RefreshCw" cls="bg-amber-50 text-amber-700 border-amber-200">automatikus</DORM_Chip>
                      : <DORM_Chip cls="bg-slate-50 text-slate-600 border-slate-200">nem automatikus</DORM_Chip>}
                  </DORM_Td>
                </tr>
              );
            })}
          </tbody>
        </DORM_Table>
      ))}

      {sub === 'utilities' && (!bills.length ? (
        <DORM_Empty icon="Zap" title="Nincs rögzített rezsiszámla"
          subtitle="A bérbeadói továbbszámlázás akkor ellenőrizhető, ha a saját leolvasásunkkal ütköztetjük. Enélkül fizetünk, mert nincs mivel vitatkozni." />
      ) : (
        <DORM_Table>
          <thead className="border-b border-slate-100">
            <tr>
              <DORM_Th>Épület</DORM_Th>
              <DORM_Th>Közmű</DORM_Th>
              <DORM_Th>Időszak</DORM_Th>
              <DORM_Th>Kiállító</DORM_Th>
              <DORM_Th className="text-right">Összeg</DORM_Th>
              <DORM_Th>Ellenőrizve</DORM_Th>
              <DORM_Th>Fizetve</DORM_Th>
            </tr>
          </thead>
          <tbody>
            {bills.map(b => (
              <tr key={b.id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                <DORM_Td className="text-slate-700 font-semibold max-w-[180px]"><span className="break-words">{DORM_bName(buildings, b.building_id)}</span></DORM_Td>
                <DORM_Td className="text-slate-600 font-semibold">{b.utility_type}</DORM_Td>
                <DORM_Td className="text-slate-600 whitespace-nowrap">{DORM_period(b.period).text}</DORM_Td>
                <DORM_Td className="text-slate-600">{b.issuer === 'LANDLORD' ? 'Bérbeadó' : 'Közműszolgáltató'}</DORM_Td>
                <DORM_Td className="text-right tabular-nums font-black text-slate-800">{DORM_money(b.amount, b.currency)}</DORM_Td>
                <DORM_Td>
                  {b.verified_against_own_reading
                    ? <DORM_Chip icon="ShieldCheck" cls="bg-emerald-50 text-emerald-700 border-emerald-200">saját leolvasással</DORM_Chip>
                    : <DORM_Chip icon="AlertTriangle" cls="bg-amber-50 text-amber-700 border-amber-200">nincs ellenőrizve</DORM_Chip>}
                </DORM_Td>
                <DORM_Td className="text-slate-600 whitespace-nowrap">{b.paid_on ? DORM_d(b.paid_on) : '—'}</DORM_Td>
              </tr>
            ))}
          </tbody>
        </DORM_Table>
      ))}

      {sub === 'alerts' && (!alerts.length ? (
        <DORM_Empty icon="BellRing" title="Nincs közelgő döntési határidő"
          subtitle="A figyelő a döntési határidőt nézi, nem a lejáratot: lejárat − felmondási idő − előkészítési puffer. Egy éven belül nincs ilyen tétel." />
      ) : (
        <DORM_Table>
          <thead className="border-b border-slate-100">
            <tr>
              <DORM_Th>Épület</DORM_Th>
              <DORM_Th>Bérbeadó</DORM_Th>
              <DORM_Th>Iktatószám</DORM_Th>
              <DORM_Th>Lejár</DORM_Th>
              <DORM_Th className="text-right">Felmondás</DORM_Th>
              <DORM_Th>Döntési határidő</DORM_Th>
              <DORM_Th className="text-right">Havi díj</DORM_Th>
            </tr>
          </thead>
          <tbody>
            {alerts.map((a, i) => (
              <tr key={i} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                <DORM_Td>
                  <div className="font-black text-slate-800">{a.building_name}</div>
                  <div className="text-[11px] text-slate-400 font-bold">{a.building_code}</div>
                </DORM_Td>
                <DORM_Td className="text-slate-600 max-w-[180px]"><span className="break-words">{a.landlord_name || '—'}</span></DORM_Td>
                <DORM_Td className="text-slate-600 font-semibold">{a.iktatoszam || '—'}</DORM_Td>
                <DORM_Td className="text-slate-600 whitespace-nowrap">{DORM_d(a.ends_on)}</DORM_Td>
                <DORM_Td className="text-right tabular-nums text-slate-600">{a.notice_months} hó</DORM_Td>
                <DORM_Td className="whitespace-nowrap">
                  <span className={'font-black ' + (Number(a.days_left) <= 90 ? 'text-red-600' : 'text-slate-800')}>{DORM_d(a.decision_due_on)}</span>
                  <div className="text-[11px] text-slate-400 font-bold">
                    {Number(a.days_left) < 0 ? Math.abs(Number(a.days_left)) + ' napja lejárt' : a.days_left + ' nap'}
                    {a.auto_renew ? ' · automatikusan megújul' : ''}
                  </div>
                </DORM_Td>
                <DORM_Td className="text-right tabular-nums font-semibold text-slate-700">{DORM_money(a.monthly_rent)}</DORM_Td>
              </tr>
            ))}
          </tbody>
        </DORM_Table>
      ))}

      {sub === 'landlords' && (!(landlords || []).length ? (
        <DORM_Empty icon="Contact" title="Nincs bérbeadó nyilvántartva"
          subtitle="Egy szombat éjjeli csőtörésnél az ÜGYELETI TELEFONSZÁM az egyetlen adat, ami számít — ezért külön mező, és nem a megjegyzésben lakik." />
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
          {(landlords || []).map(l => (
            <div key={l.id} className="bg-white rounded-2xl border border-slate-100 p-4 min-w-0">
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <div className="font-black text-slate-800 break-words">{l.name}</div>
                  <div className="text-[11px] text-slate-400 font-bold">{l.is_company ? 'Cég' : 'Magánszemély'}{l.tax_number ? ' · ' + l.tax_number : ''}</div>
                </div>
                <DORM_Ic n="Building2" size={18} className="text-violet-500 flex-none" />
              </div>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 mt-3">
                <DORM_KV label="Kapcsolattartó">{l.representative || '—'}</DORM_KV>
                <DORM_KV label="Telefon">{l.phone || '—'}</DORM_KV>
                <DORM_KV label="E-mail"><span className="break-all">{l.email || '—'}</span></DORM_KV>
                <DORM_KV label="Ügyeleti szám">
                  {l.duty_phone
                    ? <span className="text-emerald-700 font-black">{l.duty_phone}</span>
                    : <span className="text-red-600 font-bold">hiányzik</span>}
                </DORM_KV>
              </div>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

/* ---------- 4.7 Szerepkörök -----------------------------------------------
   Láthatóság: KOLI_SYSADMIN vagy admin.

   Két dolog van itt, mert a gyakorlatban együtt jár:
     (a) GRANT KIOSZTÁSA épület-hatókörrel — dorm_role_grant(). A VISSZAVONÁS
         nem sortörlés, hanem expires_at := now(): a jogosultság története
         megmarad, és utólag megválaszolható, ki mit láthatott.
     (b) SZEMÉLY-ÖSSZEKÖTÉS — dorm_person_link(): a kollégiumi lakó (dorm.person)
         és a UniPortal-fiók / jelentkező összekötése. Enélkül a lakó nem látja
         a saját szállását, mert a rendszer nem tudja, hogy ő ő.
   A dorm_person_link_suggestions() e-mail alapján javasol; az EGYERTELMU
   találat egy kattintással köthető, a többszörös nem — ott emberi döntés kell. */
function DORM_RolesPanel({ buildings }) {
  const [grants, setGrants]   = useState(null);
  const [sugg, setSugg]       = useState([]);
  const [err, setErr]         = useState('');
  const [note, setNote]       = useState('');
  const [busy, setBusy]       = useState('');
  const [sub, setSub]         = useState('grant');
  const [g, setG] = useState({ email: '', role: 'GONDNOK', building: '', iktatoszam: '', expires: '' });

  const load = async () => {
    setGrants(null);
    const r = await DORM_sel('role_grant', qq => qq.order('granted_at', { ascending: false }).limit(500));
    setErr(r.error);
    setGrants(r.rows);
    try { const s = await DORM_api.linkSuggest(); setSugg(Array.isArray(s) ? s : []); }
    catch (e) { setSugg([]); }
  };

  useEffect(() => { load(); }, []);

  const grant = async (revoke) => {
    if (!g.email.trim()) { setErr('Az e-mail-cím kötelező — a grant a UniPortal-fiókhoz kötődik.'); return; }
    setBusy('grant'); setErr(''); setNote('');
    try {
      await DORM_api.roleGrant({
        p_email: g.email.trim(),
        p_role: g.role,
        p_building: g.building || null,
        p_expires_at: g.expires ? new Date(g.expires).toISOString() : null,
        p_iktatoszam: g.iktatoszam.trim() || null,
        p_revoke: !!revoke,
      });
      setNote(revoke
        ? 'A jogosultság visszavonva. A sor nem törlődik: a lejárat rögzül, így utólag is megválaszolható, ki mit láthatott.'
        : 'Jogosultság kiosztva. Hatókör: ' + (g.building ? DORM_bName(buildings, g.building) : 'intézményi (minden épület)') + '.');
      setG({ ...g, email: '', iktatoszam: '' });
      await load();
    } catch (e) { setErr(DORM_msg(e)); }
    setBusy('');
  };

  const link = async (s) => {
    setBusy(s.person_id); setErr(''); setNote('');
    try {
      await DORM_api.personLink({
        p_person: s.person_id,
        p_student: s.suggested_student || null,
        p_profile: s.suggested_profile || null,
      });
      setNote('Összekötve: ' + (s.display_name || 'a lakó') + '. Mostantól látja a saját szállását a Szállásom menüpontban.');
      await load();
    } catch (e) { setErr(DORM_msg(e)); }
    setBusy('');
  };

  if (grants === null) return <DORM_Loading text="Jogosultságok betöltése…" />;

  const live = grants.filter(x => !x.expires_at || new Date(x.expires_at) > new Date());
  const subTabs = [
    { id: 'grant',  label: 'Jogosultságok',      icon: 'ShieldCheck', count: live.length },
    { id: 'link',   label: 'Személy-összekötés', icon: 'Link2',       count: sugg.length },
  ];

  return (
    <div>
      <DORM_PanelHead
        title="Szerepkörök"
        desc="A modul saját, hatókörös jogosultsági dimenziója. A profiles.role enumot NEM bővíti: aki itt kap felhatalmazást, az a kollégiumi modulban kapja, épületre szűkítve." />

      <DORM_Err msg={err} onClose={() => setErr('')} />
      {note && (
        <div className="mb-4 flex items-start gap-2 bg-emerald-50 border border-emerald-100 text-emerald-800 rounded-2xl px-4 py-3 text-sm font-semibold">
          <DORM_Ic n="CheckCircle2" size={16} className="mt-0.5 flex-none" /><span className="min-w-0 break-words">{note}</span>
        </div>
      )}

      <DORM_Tabs tabs={subTabs} tab={sub} setTab={setSub} />

      {sub === 'grant' && (
        <>
          <div className="bg-white rounded-2xl border border-slate-100 p-4 sm:p-5 mb-5">
            <div className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-3">Jogosultság kiosztása vagy visszavonása</div>
            <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-4">
              <UField label="E-mail-cím" hint="Jóváhagyott UniPortal-fiók e-mail-címe.">
                <input className={U_input} value={g.email} onChange={e => setG({ ...g, email: e.target.value })} placeholder="gondnok@uni-neumann.hu" />
              </UField>
              <UField label="Szerepkör" hint={DORM_ROLE_HINT[g.role]}>
                <select className={U_input} value={g.role} onChange={e => setG({ ...g, role: e.target.value })}>
                  {DORM_ROLES.map(r => <option key={r} value={r}>{DORM_ROLE_LABEL[r]}</option>)}
                </select>
              </UField>
              <UField label="Hatókör" hint="Üresen: intézményi hatókör, minden épületre.">
                <select className={U_input} value={g.building} onChange={e => setG({ ...g, building: e.target.value })}>
                  <option value="">Intézményi — minden épület</option>
                  {(buildings || []).map(b => <option key={b.id} value={b.id}>{(b.code ? b.code + ' · ' : '') + b.name}</option>)}
                </select>
              </UField>
              <UField label="Iktatószám" hint="A felhatalmazás írásos nyoma."><input className={U_input} value={g.iktatoszam} onChange={e => setG({ ...g, iktatoszam: e.target.value })} /></UField>
              <UField label="Lejárat" hint="Külsős vállalkozónál mindig adjon meg lejáratot.">
                <input type="date" className={U_input} value={g.expires} onChange={e => setG({ ...g, expires: e.target.value })} />
              </UField>
              <div className="flex items-end gap-2">
                <button onClick={() => grant(false)} disabled={busy === 'grant'} className={U_btnPrimary + ' min-h-[44px] flex-1'}>
                  <DORM_Ic n="ShieldCheck" size={15} /> {busy === 'grant' ? 'Mentés…' : 'Kiosztás'}
                </button>
                <button onClick={() => grant(true)} disabled={busy === 'grant'} className={U_btnGhost + ' min-h-[44px]'}>
                  <DORM_Ic n="ShieldX" size={15} /> Visszavonás
                </button>
              </div>
            </div>
          </div>

          {!grants.length ? (
            <DORM_Empty icon="ShieldAlert" title="Nincs kiosztott kollégiumi jogosultság"
              subtitle="Amíg senkinek nincs grantja, a modul nézetei üresek — és ez helyes: a jogosultság nem a profiles.role-ból, hanem innen jön." />
          ) : (
            <DORM_Table>
              <thead className="border-b border-slate-100">
                <tr>
                  <DORM_Th>Szerepkör</DORM_Th>
                  <DORM_Th>Hatókör</DORM_Th>
                  <DORM_Th>Kiosztva</DORM_Th>
                  <DORM_Th>Lejárat</DORM_Th>
                  <DORM_Th>Iktatószám</DORM_Th>
                  <DORM_Th>Állapot</DORM_Th>
                </tr>
              </thead>
              <tbody>
                {grants.map(x => {
                  const dead = x.expires_at && new Date(x.expires_at) <= new Date();
                  return (
                    <tr key={x.id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                      <DORM_Td>
                        <div className="font-black text-slate-800">{DORM_ROLE_LABEL[x.role] || x.role}</div>
                        <div className="text-[11px] text-slate-400 font-bold">{x.role}</div>
                      </DORM_Td>
                      <DORM_Td className="text-slate-600 max-w-[200px]">
                        <span className="break-words">{x.scope_building ? DORM_bName(buildings, x.scope_building) : 'intézményi — minden épület'}</span>
                      </DORM_Td>
                      <DORM_Td className="text-slate-600 whitespace-nowrap">{DORM_dt(x.granted_at)}</DORM_Td>
                      <DORM_Td className="text-slate-600 whitespace-nowrap">{x.expires_at ? DORM_dt(x.expires_at) : 'nincs'}</DORM_Td>
                      <DORM_Td className="text-slate-600 font-semibold">{x.iktatoszam || '—'}</DORM_Td>
                      <DORM_Td>
                        {dead
                          ? <DORM_Chip icon="ShieldX" cls="bg-slate-100 text-slate-500 border-slate-200">visszavonva</DORM_Chip>
                          : <DORM_Chip icon="ShieldCheck" cls="bg-emerald-50 text-emerald-700 border-emerald-200">élő</DORM_Chip>}
                      </DORM_Td>
                    </tr>
                  );
                })}
              </tbody>
            </DORM_Table>
          )}
        </>
      )}

      {sub === 'link' && (!sugg.length ? (
        <DORM_Empty icon="Link2" title="Nincs összekötésre váró lakó"
          subtitle="A javaslatok e-mail-cím alapján készülnek. Ha nincs találat, vagy minden lakó össze van kötve, vagy nincs egyértelmű pár — az utóbbi emberi döntés." />
      ) : (
        <DORM_Table>
          <thead className="border-b border-slate-100">
            <tr>
              <DORM_Th>Lakó</DORM_Th>
              <DORM_Th>E-mail</DORM_Th>
              <DORM_Th>Javasolt jelentkező</DORM_Th>
              <DORM_Th>Javasolt fiók</DORM_Th>
              <DORM_Th>Biztonság</DORM_Th>
              <DORM_Th className="text-right">Művelet</DORM_Th>
            </tr>
          </thead>
          <tbody>
            {sugg.map(s => {
              const sure = s.confidence === 'EGYERTELMU';
              return (
                <tr key={s.person_id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50/60">
                  <DORM_Td className="font-black text-slate-800 break-words max-w-[200px]">{s.display_name}</DORM_Td>
                  <DORM_Td className="text-slate-600 break-all max-w-[220px]">{s.email || '—'}</DORM_Td>
                  <DORM_Td className="text-slate-600 font-semibold">{s.suggested_student || '—'}</DORM_Td>
                  <DORM_Td className="text-slate-600 font-semibold">{s.suggested_profile ? 'van' : '—'}</DORM_Td>
                  <DORM_Td>
                    {sure
                      ? <DORM_Chip icon="CheckCircle2" cls="bg-emerald-50 text-emerald-700 border-emerald-200">egyértelmű</DORM_Chip>
                      : <DORM_Chip icon="HelpCircle" cls="bg-amber-50 text-amber-700 border-amber-200">többszörös vagy nincs</DORM_Chip>}
                  </DORM_Td>
                  <DORM_Td className="text-right">
                    <button onClick={() => link(s)} disabled={!sure || busy === s.person_id}
                      title={sure ? 'Összekötés a javasolt jelentkezővel és fiókkal.' : 'Nem egyértelmű pár — kézi döntés kell.'}
                      className={(sure ? U_btnPrimary : U_btnGhost) + ' !px-3 min-h-[44px]'}>
                      <DORM_Ic n="Link2" size={14} /> {busy === s.person_id ? 'Kötés…' : 'Összekötés'}
                    </button>
                  </DORM_Td>
                </tr>
              );
            })}
          </tbody>
        </DORM_Table>
      ))}
    </div>
  );
}

/* ============================================================
   5. RÉSZ — DORM_OpsView, a "Kollégium" menüpont
   ------------------------------------------------------------
   Az áttekintő tetején négy mérőszám, alatta hét fül. A FÜLEK
   LÁTHATÓSÁGA a dorm_my_roles()-ból jön, nem a profiles.role-ból:
   a menü mindenkinek ugyanaz, a TARTALMA nem. Aki egyetlen grantot
   sem kapott, nem hibaüzenetet lát, hanem azt, hogy mit kell tenni.

   A mérőszámok mind a négy publikus aggregáló RPC-t megszólítják, és
   MINDEGYIK külön try/catch-ben ül: a szabad helyek listája más
   jogosultságot kíván, mint a lejáratfigyelő, és egy jogosultsági hiba
   nem viheti magával a másik három csempét.
   ============================================================ */
function DORM_OpsView({ user }) {
  const roleState = DORM_useRoles(user);
  const R = roleState.data;

  const [tab, setTab]           = useState('buildings');
  const [building, setBuilding] = useState('');
  const [buildings, setBuildings] = useState([]);
  const [sites, setSites]       = useState([]);
  const [landlords, setLandlords] = useState([]);
  const [roomTypes, setRoomTypes] = useState([]);
  const [roomStatuses, setRoomStatuses] = useState([]);
  const [summary, setSummary]   = useState([]);
  const [freeCount, setFreeCount] = useState(null);
  const [issueCount, setIssueCount] = useState(null);
  const [leaseCount, setLeaseCount] = useState(null);
  const [loading, setLoading]   = useState(true);
  const [err, setErr]           = useState('');

  const loadBase = async () => {
    const [b, s, l, rt, rs] = await Promise.all([
      DORM_sel('building', q => q.order('code', { ascending: true }).limit(300)),
      DORM_sel('site', q => q.order('code', { ascending: true }).limit(200)),
      DORM_sel('landlord', q => q.order('name', { ascending: true }).limit(200)),
      DORM_sel('room_type', q => q.order('sort_order', { ascending: true }).limit(100)),
      DORM_sel('room_status', q => q.order('sort_order', { ascending: true }).limit(100)),
    ]);
    // Ha a building tábla nem olvasható, a dorm_my_roles() épületlistája a
    // tartalék: az legalább a hatókört megmutatja.
    setBuildings(b.rows.length ? b.rows : (R.buildings || []));
    setSites(s.rows);
    setLandlords(l.rows);
    setRoomTypes(rt.rows);
    setRoomStatuses(rs.rows);
  };

  const loadMetrics = async () => {
    try { const s = await DORM_api.occupancy(building || null); setSummary(Array.isArray(s) ? s : []); }
    catch (e) { setSummary([]); setErr(DORM_msg(e)); }
    try { const f = await DORM_api.freeBeds({ p_building: building || null, p_limit: 500 }); setFreeCount(Array.isArray(f) ? f.length : null); }
    catch (e) { setFreeCount(null); }
    try { const i = await DORM_api.openIssues(building || null, false); setIssueCount(Array.isArray(i) ? i.length : null); }
    catch (e) { setIssueCount(null); }
    try { const a = await DORM_api.leaseAlerts(180); setLeaseCount(Array.isArray(a) ? a.length : null); }
    catch (e) { setLeaseCount(null); }
  };

  useEffect(() => {
    if (roleState.loading) return;
    let alive = true;
    (async () => {
      setLoading(true);
      await loadBase();
      if (!alive) return;
      await loadMetrics();
      if (alive) setLoading(false);
    })();
    return () => { alive = false; };
  }, [roleState.loading]);

  useEffect(() => {
    if (roleState.loading || loading) return;
    loadMetrics();
  }, [building]);

  if (roleState.loading) return <DORM_Loading text="Kollégiumi jogosultságok betöltése…" />;

  /* --- A fülek láthatósága. Egy hely, hogy ne szóródjon szét. --- */
  const isAdm      = R.admin;
  const anyRole    = isAdm || (R.roles || []).length > 0;
  const canNames   = R.hasAny(['GONDNOK', 'KOLI_ADMIN', 'KOLI_SYSADMIN']);
  const canAllocate= R.hasAny(['KOLI_ADMIN', 'KOLI_SYSADMIN']);
  const canEstate  = isAdm || R.has('INGATLAN');
  const canSysadm  = isAdm || R.has('KOLI_SYSADMIN');
  const canEditBld = isAdm || R.hasAny(['KOLI_ADMIN', 'KOLI_SYSADMIN', 'INGATLAN']);

  const allTabs = [
    { id: 'buildings', label: 'Épületek',       icon: 'Building2',     show: anyRole },
    { id: 'rooms',     label: 'Szobák',         icon: 'DoorClosed',    show: anyRole },
    { id: 'residents', label: 'Lakók',          icon: 'Users',         show: canNames },
    { id: 'movement',  label: 'Be-/Kiköltözés', icon: 'ArrowLeftRight',show: canNames },
    { id: 'waitlist',  label: 'Várólista',      icon: 'ListOrdered',   show: canAllocate },
    { id: 'leases',    label: 'Bérlemények',    icon: 'FileSignature', show: canEstate },
    { id: 'roles',     label: 'Szerepkörök',    icon: 'ShieldCheck',   show: canSysadm },
  ];
  const tabs = allTabs.filter(t => t.show);
  const active = tabs.some(t => t.id === tab) ? tab : (tabs[0] && tabs[0].id);

  /* --- A négy mérőszám. A kihasználtság NEVEZŐJE a KIADHATÓ férőhely: a
         nyilvántartott szám a fenntartóé, az üzemeltetés a kiadhatót ismeri,
         és a kettő különbsége az, amit magyarázni kell. --- */
  const sum = (k) => summary.reduce((a, r) => a + Number(r[k] || 0), 0);
  const lettable = sum('beds_lettable');
  const occupied = sum('beds_occupied');
  const pct = lettable > 0 ? Math.round((occupied / lettable) * 1000) / 10 : null;

  return (
    <div className="p-4 sm:p-6 lg:p-8 max-w-7xl 2xl:max-w-[1600px]" data-echo-noi18n>
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <p className="text-[11px] font-black text-primary uppercase tracking-widest">Kollégium- és ingatlanüzemeltetés</p>
          <h1 className="text-2xl sm:text-3xl font-black text-slate-900 tracking-tight mt-1">Kollégium</h1>
          <p className="text-slate-500 mt-2 max-w-2xl leading-relaxed text-sm sm:text-base">
            Épületek, szobák, lakók, be- és kiköltözés, várólista, bérlemények és jogosultságok.
            A <b>saját</b> és a <b>bérelt</b> épület nem ugyanaz a feladat: bérleménynél a felelős, a
            határidő és a lejárat is a bérleti szerződésből következik.
          </p>
        </div>
        <div className="w-full sm:w-auto flex flex-wrap items-center gap-2">
          {(R.roles || []).length > 0 && (
            <div className="flex flex-wrap gap-1.5">
              {(R.roles || []).map(r => (
                <DORM_Chip key={r} icon="ShieldCheck" cls="bg-primary/10 text-primary border-primary/20">
                  {DORM_ROLE_LABEL[r] || r}
                </DORM_Chip>
              ))}
            </div>
          )}
          {R.everywhere && <DORM_Chip icon="Globe2" cls="bg-slate-100 text-slate-600 border-slate-200">intézményi hatókör</DORM_Chip>}
          <DORM_BuildingPicker buildings={buildings} value={building} onChange={setBuilding} />
        </div>
      </div>

      <DORM_Err msg={err} onClose={() => setErr('')} />

      {!anyRole ? (
        <div className="mt-7">
          <DORM_Empty icon="ShieldAlert" title="Nincs kollégiumi felhatalmazása"
            subtitle="A kollégiumi modul jogosultsága nem a UniPortal-szerepköréből jön, hanem külön, épület-hatókörrel kiosztott felhatalmazásból. Kérje a kollégiumi rendszergazdától — ő a Szerepkörök fülön tudja kiosztani." />
        </div>
      ) : (
        <div className="mt-7">
          {/* Mérőszámok. Kis kijelzőn kettő, nagyobbon négy — a csempék soha nem
              feszítik ki a lapot, mert mindegyik min-w-0. */}
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-6">
            <DORM_Stat label="Kihasználtság" icon="PieChart"
              value={pct == null ? '—' : pct + '%'}
              tone={pct == null ? 'slate' : pct >= 95 ? 'red' : pct >= 80 ? 'amber' : 'green'}
              hint={lettable ? DORM_num(occupied) + ' / ' + DORM_num(lettable) + ' kiadható férőhely' : 'nincs kiadható férőhely'} />
            <DORM_Stat label="Szabad helyek" icon="BedDouble"
              value={freeCount == null ? '—' : DORM_num(freeCount)}
              tone={freeCount ? 'green' : 'slate'}
              hint={freeCount == null ? 'a listához GONDNOK / KOLI_ADMIN jogosultság kell' : 'ma kiosztható'} />
            <DORM_Stat label="Nyitott hibák" icon="AlertTriangle"
              value={issueCount == null ? '—' : DORM_num(issueCount)}
              tone={issueCount ? 'amber' : 'green'}
              hint={issueCount == null ? 'nincs jogosultsága a hibalistához' : 'a Karbantartás menüpontban kezelhető'} />
            <DORM_Stat label="Lejáró szerződések" icon="BellRing"
              value={leaseCount == null ? '—' : DORM_num(leaseCount)}
              tone={leaseCount ? 'red' : 'green'}
              hint={leaseCount == null ? 'INGATLAN / KOLI_ADMIN jogosultság kell' : '180 napon belüli döntési határidő'} />
          </div>

          <DORM_Tabs tabs={tabs} tab={active} setTab={setTab} />

          {loading ? <DORM_Loading text="Adatok betöltése…" /> : (
            <>
              {active === 'buildings' && (
                <DORM_BuildingsPanel buildings={buildings} sites={sites} landlords={landlords}
                  summary={summary} canEdit={canEditBld}
                  onReload={async () => { await loadBase(); await loadMetrics(); }} />
              )}
              {active === 'rooms' && (
                <DORM_RoomsPanel buildings={buildings} building={building}
                  roomTypes={roomTypes} roomStatuses={roomStatuses} />
              )}
              {active === 'residents' && <DORM_ResidentsPanel building={building} canSeeNames={canNames} />}
              {active === 'movement'  && <DORM_MoveInOutPanel buildings={buildings} building={building} canWrite={canNames} />}
              {active === 'waitlist'  && <DORM_WaitlistPanel building={building} canOffer={canAllocate} />}
              {active === 'leases'    && <DORM_LeasesPanel buildings={buildings} landlords={landlords} building={building} />}
              {active === 'roles'     && <DORM_RolesPanel buildings={buildings} />}
            </>
          )}
        </div>
      )}
    </div>
  );
}
