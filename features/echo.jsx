/* ============================================================
   UniPortal Pro — ECHO (OMHV) 1. + 2. szelet
   Oktatói munka hallgatói véleményezése — Neumann János Egyetem,
   28/2023. szenátusi határozat.

   (az app.jsx moduljába fűzve — NINCS import és NINCS export;
    React, hookok, Lucide, window.sb, valamint a data-layer.jsx
    UI-atomjai (UBadge, UModal, UEmpty, UField, U_input, U_btnPrimary,
    U_btnGhost, UToast) és az app.jsx töltő-komponensei
    (SkeletonBar, SkeletonRows, RefreshingBadge) a scope-ban vannak.)

   MIT CSINÁL EZ A FÁJL
     • ECHO_api            — vékony réteg a public sémás ECHO RPC-k fölé
     • ECHO_StudentView    — hallgatói kurzuslista + célmeghatározó + kitöltő varázsló
     • ECHO_AdminView      — MIR/admin, HÁROM FÜLLEL:
         – ECHO_CampaignsPanel  kampányok, kitöltési arány, kizárási napló (1. szelet)
         – ECHO_Editor          kérdőívszerkesztő: sablon/verzió, állapotgép,
                                szakasz- és kérdés-CRUD, élő előnézet, ellenőrző lista
         – ECHO_ModerationView  moderálási sor a 3. § (10) indok-katalógusával
     • ECHO_TeacherView    — oktatói eredménynézet: arány, kérdésenkénti eredmény,
                             k-küszöbök melletti ŐSZINTE üres állapotok

   AMIT NEM CSINÁL (tudatosan, a következő körre marad)
     • ECHO saját szerepkör-dimenzió (ECHO_MIR / ECHO_DEKAN / OKTATO): ma minden
       admin oldali RPC public.is_admin()-hoz kötött, és echo.teacher.profile_id
       minden soron NULL — mérve a helyi replikán
     • kari szűkítés ("csak a saját kar"): az echo.org_unit fa megvan, a
       where-feltétel nincs

   A KÉRDÉSEK NEM ITT VANNAK. A varázsló a template_version.compiled JSONB-ből
   generálódik, amit az echo_get_form() változatlanul ad vissza. Ha ide bármikor
   bekerülne egy kérdésszöveg, az azt jelentené, hogy a felület és a szenátus
   által jóváhagyott kérdőív szétcsúszhat — pontosan ezt kerüljük.
   ============================================================ */

/* ------------------------------------------------------------
   0. Nyelv és adat-eredetű szöveg
   ------------------------------------------------------------ */

// A fejléc nyelvváltója ezt a kulcsot írja (app.jsx setupI18n).
function ECHO_lang() {
  try { return (localStorage.getItem('nje_lang') || 'hu') === 'en' ? 'en' : 'hu'; }
  catch (e) { return 'hu'; }
}

// hu/en mezőpár feloldása egy compiled-objektumon.
function ECHO_txt(o, lang) {
  if (!o) return '';
  if (lang === 'en' && o.en) return o.en;
  return o.hu || o.en || '';
}

/* ADATBÓL JÖVŐ SZÖVEG BURKA.
   Az app.jsx-ben futó HU→EN fordító EN módban a DOM szövegcsomópontjait írja
   át reguláris kifejezésekkel. A kérdőív kérdés- és opciószövegei adatból
   jönnek és a szenátus hagyta jóvá — ezeket gépi átírás nem érintheti, mert
   az már nem a jóváhagyott kérdőív lenne. Minden ilyen szöveg ebbe a burokba
   kerül; a fordító acceptNode/SKIP ága a [data-echo-noi18n] részfát elutasítja. */
const ECHO_Src = ({ children, className = '' }) => (
  <span data-echo-noi18n className={className}>{children}</span>
);

/* ------------------------------------------------------------
   1. ECHO_api — vékony réteg a public sémás RPC-k fölé
   ------------------------------------------------------------
   A szignatúrák a 15_echo_core.sql 9. szakaszából valók, betű szerint:
     public.echo_my_courses()
     public.echo_get_form(p_campaign uuid, p_course uuid)
     public.echo_save_goals(p_campaign uuid, p_course uuid, p_goals jsonb, p_expectations jsonb)
     public.echo_issue_ticket(p_campaign uuid, p_course uuid)
     public.echo_submit(p_ticket text, p_payload jsonb)      -- CSAK anon joggal
     public.echo_campaigns()
     public.echo_rate(p_campaign uuid)
     public.echo_rebuild_eligibility(p_campaign uuid)
   A kliens az 'echo' sémát SOHA nem éri el közvetlenül: nincs rá USAGE joga.
   ------------------------------------------------------------ */

// A szerver oldali hibakódok emberi szövege. Ami nincs a listán, azt
// nyersen mutatjuk — jobb egy ismeretlen kód, mint egy hazug üzenet.
const ECHO_ERR = {
  ECHO_NOT_AUTHENTICATED:  'Nincs bejelentkezve.',
  ECHO_NOT_APPROVED:       'A fiókod még nincs jóváhagyva.',
  ECHO_NOT_ELIGIBLE:       'Ez a kurzus nem véleményezhető ezzel a fiókkal.',
  ECHO_CAMPAIGN_NOT_READY: 'A kampány még nem indult el.',
  ECHO_CAMPAIGN_CLOSED:    'A kitöltési ablak zárva van.',
  ECHO_GOALS_CLOSED:       'A célmeghatározási ablak zárva van.',
  ECHO_TOO_MANY_GOALS:     'Legfeljebb 3 cél és 3 elvárás adható meg.',
  ECHO_BAD_PAYLOAD:        'A beküldött adat szerkezete hibás.',
  ECHO_BAD_GOALS_MET:      'A célteljesülés értéke érvénytelen.',
  ECHO_PAYLOAD_TOO_LARGE:  'A kitöltés túl hosszú — kérjük, rövidítsd a szöveges válaszokat.',
  ECHO_ALREADY_SUBMITTED:  'Ezt a kurzust már értékelted.',
  ECHO_TICKET_EXPIRED:     'A kitöltési jegy lejárt. Kezdd elölről — a válaszaid megmaradtak.',
  ECHO_TICKET_SPENT:       'Ezt a jegyet már felhasználtuk. Az értékelés valószínűleg beérkezett.',
  ECHO_TICKET_BADSIG:      'A kitöltési jegy érvénytelen.',
  ECHO_TICKET_INVALID:     'A kitöltési jegy sérült vagy hiányos. Kérjük, kezdd elölről.',
  ECHO_TICKET_LIMIT:       'Ehhez a kurzushoz már nem kérhető újabb kitöltési jegy.',
  ECHO_TEACHER_NOT_ELIGIBLE: 'Az egyik oktató nem véleményezhető ebben a kampányban.',

  /* --- 16_echo_reports.sql (2. szelet) hibakódjai --- */
  // A results_gate() dobja. A teljes üzenet felsorolja az engedett állapotokat,
  // ezért a nyers szöveget IS megmutatjuk mellette (lásd ECHO_msg alább).
  ECHO_RESULTS_NOT_READY:  'A kampány jelenlegi állapotában nem jeleníthető meg eredmény.',
  ECHO_CAMPAIGN_NOT_FOUND: 'A kampány nem található.',
  ECHO_TEMPLATE_MISSING:   'A kampányhoz nincs kérdőív-verzió rendelve.',
  ECHO_RESPONSE_NOT_FOUND: 'A válasz nem található.',
  ECHO_BAD_REASON:         'Ismeretlen érvénytelenségi indok-kód.',
  ECHO_REASON_REQUIRED:    'Érvénytelenné nyilvánításhoz indokot kell választani (3. § (10)).',
  ECHO_VERSION_NOT_FOUND:  'A kérdőív-verzió nem található.',
  ECHO_SOURCE_NOT_FOUND:   'A klónozás forrásverziója nem található.',
  ECHO_NAME_REQUIRED:      'A sablon/verzió nevét meg kell adni.',
  ECHO_NOT_DRAFT:          'Csak piszkozat állapotban lehet menteni. Készíts új verziót.',
  ECHO_BAD_COMPILED:       'A kérdőív szerkezete hibás (nem JSON objektum).',
  ECHO_VALIDATION_FAILED:  'Az élesítés előtti ellenőrzés hibát talált — élesítés nem engedélyezett.',
  ECHO_BAD_STATE:          'Ismeretlen célállapot.',

  ECHO_FORBIDDEN:          'Ehhez nincs jogosultságod.',
};

// Néhány szerverhiba a KÓDON TÚL is hordoz információt (melyik állapotban
// lenne látható az eredmény, hány ellenőrzési hiba van). Ezeknél a nyers
// szöveget is kiírjuk — az emberi mondat önmagában kevesebbet mondana.
const ECHO_ERR_VERBOSE = ['ECHO_RESULTS_NOT_READY', 'ECHO_VALIDATION_FAILED', 'ECHO_NOT_DRAFT'];

function ECHO_msg(e) {
  const raw = (e && (e.message || e.error_description || e.hint)) || '';
  const code = Object.keys(ECHO_ERR).find(k => raw.indexOf(k) >= 0);
  if (code) {
    if (ECHO_ERR_VERBOSE.indexOf(code) >= 0) {
      // A ': ' utáni rész a szerver saját, számított magyarázata.
      const tail = raw.slice(raw.indexOf(code) + code.length).replace(/^\s*:\s*/, '').trim();
      return tail ? ECHO_ERR[code] + ' ' + tail : ECHO_ERR[code];
    }
    return ECHO_ERR[code];
  }
  if (/function .*echo_/i.test(raw) || /schema cache/i.test(raw)) {
    return 'Az ECHO adatbázis-rész még nincs telepítve (15_echo_core.sql).';
  }
  return raw || 'Ismeretlen hiba.';
}

// Az azonosított hívások a szokásos, bejelentkezett klienssel mennek.
async function ECHO_rpc(fn, args) {
  if (!window.sb) throw new Error('Nincs kapcsolat a háttérrendszerrel.');
  const { data, error } = await window.sb.rpc(fn, args || {});
  if (error) throw error;
  return data;
}

/* AZ ANONIM KLIENS — ez a fájl legfontosabb néhány sora.

   Miért nem a window.sb-vel küldjük be a kitöltést:
   a window.sb minden kérésre ráteszi a bejelentkezett hallgató JWT-jét az
   Authorization fejlécbe. Az echo_submit SECURITY DEFINER, tehát a JWT-t nem
   HASZNÁLJA — de a kérés akkor is átvinné a hallgató azonosítóját ugyanabban a
   HTTP-kérésben, amelyben a válaszai utaznak. Ettől kezdve a kettő összekötése
   már csak naplózás kérdése (edge proxy log, WAF, hibakövető), és a rendszer
   anonimitása nem az adatmodellen, hanem az üzemeltető jóindulatán múlna.
   Ezért a beküldés SAJÁT, munkamenet nélküli klienssel megy: persistSession és
   autoRefreshToken kikapcsolva, hogy a supabase-js semmilyen körülmények között
   ne emeljen be tokent a háttérből. A 15_echo_core.sql ugyanezt kényszeríti ki
   a másik oldalról: az echo_submit EXECUTE joga KIZÁRÓLAG az 'anon' szerepköré,
   az 'authenticated' nem is hívhatja.

   Ha az anon kliens bármiért nem hozható létre, NEM esünk vissza a window.sb-re.
   Az a "működik, csak épp deanonimizál" eset — inkább hibázzon látványosan. */
let ECHO__anonClient = null;
function ECHO_anonClient() {
  if (ECHO__anonClient) return ECHO__anonClient;
  const g = window.supabase;   // a @supabase/supabase-js UMD globálisa (app.html / index.html)
  if (!g || typeof g.createClient !== 'function' || !window.SUPABASE_URL || !window.SUPABASE_ANON_KEY) {
    return null;
  }
  ECHO__anonClient = g.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  return ECHO__anonClient;
}

const ECHO_api = {
  myCourses:   ()               => ECHO_rpc('echo_my_courses'),
  getForm:     (campaign, course) => ECHO_rpc('echo_get_form', { p_campaign: campaign, p_course: course }),
  saveGoals:   (campaign, course, goals, expectations) =>
                 ECHO_rpc('echo_save_goals', {
                   p_campaign: campaign, p_course: course,
                   p_goals: goals, p_expectations: expectations,
                 }),
  issueTicket: (campaign, course) => ECHO_rpc('echo_issue_ticket', { p_campaign: campaign, p_course: course }),

  // ANONIM ÚT. Lásd az ECHO_anonClient fölötti indoklást.
  submit: async (ticket, payload) => {
    const anon = ECHO_anonClient();
    if (!anon) throw new Error('A névtelen beküldő kliens nem hozható létre — a kitöltés nem küldhető be biztonságosan.');
    const { data, error } = await anon.rpc('echo_submit', { p_ticket: ticket, p_payload: payload });
    if (error) throw error;
    return data;
  },

  campaigns:  ()          => ECHO_rpc('echo_campaigns'),
  rate:       (campaign)  => ECHO_rpc('echo_rate', { p_campaign: campaign }),
  rebuildEligibility: (campaign) => ECHO_rpc('echo_rebuild_eligibility', { p_campaign: campaign }),

  /* ---- 2. szelet: 16_echo_reports.sql 8. szakasz, betű szerinti szignatúrák ----
       public.echo_teacher_results(p_campaign uuid, p_course uuid, p_teacher uuid default null)
       public.echo_course_results(p_campaign uuid, p_course uuid)
       public.echo_moderation_queue(p_campaign uuid)
       public.echo_moderate(p_response uuid, p_question text, p_allapot text,
                            p_indok text default null, p_megjegyzes text default null)
       public.echo_templates()
       public.echo_template_get(p_version uuid)
       public.echo_template_create(p_name text, p_from uuid default null)
       public.echo_template_save(p_version uuid, p_compiled jsonb)
       public.echo_template_validate(p_version uuid)
       public.echo_template_transition(p_version uuid, p_to text)
     Mind 'authenticated' granttal; a tényleges szűrés a függvény TÖRZSÉBEN van
     (is_admin(), illetve az echo.teacher.profile_id szerinti oktatói kötés). */
  teacherResults: (campaign, course, teacher) =>
    ECHO_rpc('echo_teacher_results', { p_campaign: campaign, p_course: course, p_teacher: teacher || null }),
  courseResults:  (campaign, course) =>
    ECHO_rpc('echo_course_results', { p_campaign: campaign, p_course: course }),

  moderationQueue: (campaign) => ECHO_rpc('echo_moderation_queue', { p_campaign: campaign }),
  moderate: (response, question, allapot, indok, megjegyzes) =>
    ECHO_rpc('echo_moderate', {
      p_response: response, p_question: question, p_allapot: allapot,
      p_indok: indok || null, p_megjegyzes: megjegyzes || null,
    }),

  templates:          ()               => ECHO_rpc('echo_templates'),
  templateGet:        (version)        => ECHO_rpc('echo_template_get', { p_version: version }),
  templateCreate:     (name, from)     => ECHO_rpc('echo_template_create', { p_name: name, p_from: from || null }),
  templateSave:       (version, compiled) => ECHO_rpc('echo_template_save', { p_version: version, p_compiled: compiled }),
  templateValidate:   (version)        => ECHO_rpc('echo_template_validate', { p_version: version }),
  templateTransition: (version, to)    => ECHO_rpc('echo_template_transition', { p_version: version, p_to: to }),
};

/* ------------------------------------------------------------
   2. Segédfüggvények a compiled JSONB értelmezéséhez
   ------------------------------------------------------------ */

// A compiled options tömbje kétféle: ["szöveg", …] vagy [{value,hu,en}, …].
// A kettő egységesítése — a beküldött érték MINDIG a `value`.
function ECHO_options(q, lang) {
  const raw = Array.isArray(q && q.options) ? q.options : [];
  return raw.map((o, i) => {
    if (o && typeof o === 'object') {
      return { value: o.value != null ? o.value : (o.hu || String(i)), label: ECHO_txt(o, lang) || String(o.value || '') };
    }
    return { value: String(o), label: String(o) };
  });
}

// Determinisztikus keverés: a "randomize": true kérdéseknél a sorrend
// kitöltésenként más, de EGY kitöltésen belül nem ugrál (a lépések között
// oda-vissza lehet lépkedni). A mag a kitöltés indításakor születik.
function ECHO_shuffle(list, seedStr) {
  let h = 2166136261;
  for (let i = 0; i < seedStr.length; i++) { h ^= seedStr.charCodeAt(i); h = Math.imul(h, 16777619); }
  const out = list.slice();
  for (let i = out.length - 1; i > 0; i--) {
    h = (Math.imul(h, 48271) + 11) >>> 0;
    const j = h % (i + 1);
    const t = out[i]; out[i] = out[j]; out[j] = t;
  }
  return out;
}

/* A compiled `cond` mezőjének kiértékelése.
   A jelenlegi kérdőívben két alak fordul elő:
     {"has_goals": true}   — csak akkor, ha a hallgató mentett félév eleji célt
     {"teacher_skip": null} — csak akkor, ha az oktatót NEM hagyta ki
   Az értelmezés általános, hogy egy jövőbeli verzió új feltétele se törje el
   a felületet: kulcsonként vagy a has_goals kapcsolóra, vagy az adott kérdés
   aktuális válaszára illesztünk. */
function ECHO_condOk(cond, ctx) {
  if (!cond || typeof cond !== 'object') return true;
  return Object.keys(cond).every((k) => {
    const want = cond[k];
    if (k === 'has_goals') return !!ctx.hasGoals === !!want;
    const have = ctx.answers ? ctx.answers[k] : undefined;
    const empty = (have === undefined || have === null || have === '' ||
                   (Array.isArray(have) && have.length === 0));
    if (want === null) return empty;
    if (Array.isArray(want)) return want.indexOf(have) >= 0;
    return have === want;
  });
}

// Ki van-e töltve egy kötelező kérdés.
function ECHO_answered(q, v) {
  if (q.type === 'multi') return Array.isArray(v) && v.length > 0;
  if (q.type === 'scale') return typeof v === 'number';
  return v !== undefined && v !== null && String(v).trim() !== '';
}

// A compiled → lépéslista. A repeat:"teacher" kérdéseket tartalmazó szakaszból
// oktatónként EGY lépés lesz.
function ECHO_buildSteps(form, teachers) {
  const sections = (form && Array.isArray(form.sections)) ? form.sections : [];
  const steps = [];
  sections.forEach((sec) => {
    if (sec.part && sec.part !== 'part2') return;   // a part1 a célmeghatározó, nem itt van
    const qs = Array.isArray(sec.questions) ? sec.questions : [];
    const perTeacher = qs.some(q => q.repeat === 'teacher');
    if (perTeacher) {
      (teachers || []).forEach((t) => steps.push({ kind: 'teacher', section: sec, teacher: t }));
    } else {
      steps.push({ kind: 'section', section: sec });
    }
  });
  steps.push({ kind: 'review', section: null });
  return steps;
}

/* ------------------------------------------------------------
   3. Kérdés-atomok (mobilbarát: nagy érintési célpontok)
   ------------------------------------------------------------ */

const ECHO_choiceBase =
  'w-full text-left flex items-start gap-3 rounded-2xl border-2 px-4 py-4 min-h-[56px] ' +
  'transition-all active:scale-[0.99] text-sm font-bold';
const ECHO_choiceOff = ' border-slate-100 bg-white text-slate-700 hover:border-slate-200 hover:bg-slate-50';
const ECHO_choiceOn  = ' border-primary bg-primary/5 text-primary';
const ECHO_choiceDis = ' border-slate-100 bg-slate-50 text-slate-300 pointer-events-none';

function ECHO_QSingle({ q, opts, value, onChange }) {
  return (
    <div className="space-y-2.5">
      {opts.map(o => (
        <button key={o.value} type="button"
          onClick={() => onChange(value === o.value ? null : o.value)}
          className={ECHO_choiceBase + (value === o.value ? ECHO_choiceOn : ECHO_choiceOff)}>
          <span className={'mt-0.5 w-5 h-5 flex-none rounded-full border-2 flex items-center justify-center ' +
                           (value === o.value ? 'border-primary' : 'border-slate-300')}>
            {value === o.value && <span className="w-2.5 h-2.5 rounded-full bg-primary" />}
          </span>
          <ECHO_Src>{o.label}</ECHO_Src>
        </button>
      ))}
    </div>
  );
}

function ECHO_QMulti({ q, opts, value, onChange }) {
  const arr = Array.isArray(value) ? value : [];
  const max = Number(q.max) > 0 ? Number(q.max) : opts.length;
  const full = arr.length >= max;
  const [other, setOther] = useState('');

  const toggle = (v) => {
    if (arr.indexOf(v) >= 0) onChange(arr.filter(x => x !== v));
    else if (!full) onChange(arr.concat([v]));
  };
  const addOther = () => {
    const t = other.trim();
    if (!t || full || arr.indexOf(t) >= 0) return;
    onChange(arr.concat([t]));
    setOther('');
  };
  // Az „Egyéb"-ként beírt, tehát a listában nem szereplő értékek.
  const extras = arr.filter(v => !opts.some(o => o.value === v));

  return (
    <div className="space-y-2.5">
      {/* Élő számláló — a korlát nem meglepetés, hanem visszajelzés. */}
      <div className="flex items-center justify-between text-[11px] font-black uppercase tracking-wider mb-1">
        <span className={full ? 'text-primary' : 'text-slate-400'}>
          kiválasztva {arr.length}/{max}
        </span>
        {full && <span className="text-slate-400 normal-case tracking-normal font-bold">a keret betelt — vegyél le egyet a cseréhez</span>}
      </div>

      {opts.map(o => {
        const on = arr.indexOf(o.value) >= 0;
        const dis = !on && full;
        return (
          <button key={o.value} type="button" onClick={() => toggle(o.value)}
            className={ECHO_choiceBase + (on ? ECHO_choiceOn : (dis ? ECHO_choiceDis : ECHO_choiceOff))}>
            <span className={'mt-0.5 w-5 h-5 flex-none rounded-md border-2 flex items-center justify-center ' +
                             (on ? 'border-primary bg-primary text-white' : 'border-slate-300')}>
              {on && <Lucide.Check size={13} strokeWidth={4} />}
            </span>
            <ECHO_Src>{o.label}</ECHO_Src>
          </button>
        );
      })}

      {extras.map(v => (
        <button key={'x_' + v} type="button" onClick={() => toggle(v)}
          className={ECHO_choiceBase + ECHO_choiceOn}>
          <span className="mt-0.5 w-5 h-5 flex-none rounded-md border-2 border-primary bg-primary text-white flex items-center justify-center">
            <Lucide.Check size={13} strokeWidth={4} />
          </span>
          <ECHO_Src>{v}</ECHO_Src>
        </button>
      ))}

      {q.allowOther && (
        <div className="flex gap-2 pt-1">
          <input className={U_input} value={other} disabled={full}
            onChange={e => setOther(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); addOther(); } }}
            placeholder="Egyéb — saját szöveg" maxLength={120} />
          <button type="button" onClick={addOther} disabled={full || !other.trim()}
            className={U_btnGhost + ' flex-none'}><Lucide.Plus size={16} /></button>
        </div>
      )}
    </div>
  );
}

function ECHO_QScale({ q, value, onChange, lang }) {
  const sc = q.scale || { min: 1, max: 7 };
  const min = Number(sc.min) || 1, max = Number(sc.max) || 7;
  const nums = [];
  for (let i = min; i <= max; i++) nums.push(i);
  const lo = lang === 'en' ? (sc.min_en || sc.min_hu) : (sc.min_hu || sc.min_en);
  const hi = lang === 'en' ? (sc.max_en || sc.max_hu) : (sc.max_hu || sc.max_en);
  return (
    <div>
      <div className="flex gap-1.5 sm:gap-2">
        {nums.map(n => (
          <button key={n} type="button" onClick={() => onChange(value === n ? null : n)}
            className={'flex-1 min-w-[40px] h-14 rounded-2xl border-2 font-black text-base transition-all active:scale-95 ' +
                       (value === n ? 'border-primary bg-primary text-white shadow-lg shadow-primary/20'
                                    : 'border-slate-100 bg-white text-slate-600 hover:border-slate-200')}>
            {n}
          </button>
        ))}
      </div>
      <div className="flex justify-between mt-2 text-[11px] font-bold text-slate-400">
        <ECHO_Src>{lo || ''}</ECHO_Src>
        <ECHO_Src>{hi || ''}</ECHO_Src>
      </div>
    </div>
  );
}

function ECHO_QLong({ q, value, onChange }) {
  const max = Number(q.max) > 0 ? Number(q.max) : 1500;
  const v = value || '';
  return (
    <div>
      <textarea className={U_input + ' min-h-[140px] resize-y'} value={v} maxLength={max}
        onChange={e => onChange(e.target.value)}
        placeholder="Írd le a saját szavaiddal…" />
      <div className="flex items-center justify-between mt-1.5">
        <span className="text-[11px] text-slate-400 font-bold">{v.length}/{max}</span>
        {q.moderated && (
          <span className="inline-flex items-center gap-1 text-[11px] text-slate-400 font-bold">
            <Lucide.ShieldCheck size={12} /> moderált mező
          </span>
        )}
      </div>
    </div>
  );
}

/* A "skip" típus: nem kérdés, hanem KAPU. Alapból nincs bejelölve semmi
   (= értékelem az oktatót); ha a hallgató kihagyja, indokot választ. */
function ECHO_QSkip({ q, opts, value, onChange }) {
  const on = value !== undefined && value !== null && value !== '';
  const listed = opts.some(o => o.value === value);
  const [other, setOther] = useState(on && !listed ? String(value) : '');
  return (
    <div className="space-y-3">
      <button type="button" onClick={() => onChange(on ? null : (opts[0] ? opts[0].value : 'Nem tudom értékelni'))}
        className={ECHO_choiceBase + (on ? ' border-amber-300 bg-amber-50 text-amber-700' : ECHO_choiceOff)}>
        <span className={'mt-0.5 w-5 h-5 flex-none rounded-md border-2 flex items-center justify-center ' +
                         (on ? 'border-amber-500 bg-amber-500 text-white' : 'border-slate-300')}>
          {on && <Lucide.Check size={13} strokeWidth={4} />}
        </span>
        Ezt az oktatót nem tudom értékelni
      </button>
      {on && (
        <div className="pl-2 border-l-2 border-amber-200 space-y-2.5">
          <p className="text-[11px] font-black uppercase tracking-wider text-slate-400">A kihagyás oka</p>
          {opts.map(o => (
            <button key={o.value} type="button" onClick={() => onChange(o.value)}
              className={ECHO_choiceBase + (value === o.value ? ECHO_choiceOn : ECHO_choiceOff)}>
              <span className={'mt-0.5 w-5 h-5 flex-none rounded-full border-2 flex items-center justify-center ' +
                               (value === o.value ? 'border-primary' : 'border-slate-300')}>
                {value === o.value && <span className="w-2.5 h-2.5 rounded-full bg-primary" />}
              </span>
              <ECHO_Src>{o.label}</ECHO_Src>
            </button>
          ))}
          {q.allowOther && (
            <input className={U_input} value={other} maxLength={200}
              onChange={e => { setOther(e.target.value); if (e.target.value.trim()) onChange(e.target.value.trim()); }}
              placeholder="Egyéb ok — saját szöveg" />
          )}
        </div>
      )}
    </div>
  );
}

// Egy kérdés kerete: sorszám, szöveg, súgó, majd a típusnak megfelelő atom.
function ECHO_Question({ q, index, value, onChange, lang, seed }) {
  const opts = ECHO_options(q, lang);
  const shown = q.randomize ? ECHO_shuffle(opts, seed + '|' + q.id) : opts;
  return (
    <div className="py-6 border-b border-slate-50 last:border-0">
      <div className="flex items-start gap-3 mb-4">
        <span className="flex-none w-7 h-7 rounded-xl bg-slate-100 text-slate-500 text-xs font-black flex items-center justify-center mt-0.5">
          {index}
        </span>
        <div className="min-w-0">
          <h4 className="text-[15px] sm:text-base font-black text-slate-900 leading-snug">
            <ECHO_Src>{ECHO_txt(q, lang)}</ECHO_Src>
            {q.required && <span className="text-primary ml-1">*</span>}
          </h4>
          {q.help && (
            <p className="text-xs text-slate-400 font-medium mt-1.5 leading-relaxed">
              <ECHO_Src>{q.help}</ECHO_Src>
            </p>
          )}
        </div>
      </div>
      <div className="sm:pl-10">
        {q.type === 'single'   && <ECHO_QSingle q={q} opts={shown} value={value} onChange={onChange} />}
        {q.type === 'multi'    && <ECHO_QMulti  q={q} opts={shown} value={value} onChange={onChange} />}
        {q.type === 'scale'    && <ECHO_QScale  q={q} value={value} onChange={onChange} lang={lang} />}
        {q.type === 'longtext' && <ECHO_QLong   q={q} value={value} onChange={onChange} />}
        {q.type === 'skip'     && <ECHO_QSkip   q={q} opts={shown} value={value} onChange={onChange} />}
        {['single','multi','scale','longtext','skip'].indexOf(q.type) < 0 && (
          <div className="text-xs text-amber-600 font-bold bg-amber-50 rounded-xl px-4 py-3">
            Ismeretlen kérdéstípus: <ECHO_Src>{String(q.type)}</ECHO_Src> — a felület frissítésre szorul.
          </div>
        )}
      </div>
    </div>
  );
}

/* ------------------------------------------------------------
   4. Állapotjelzők
   ------------------------------------------------------------ */

// Az echo_my_courses 'allapot' mezője → felületi címke.
const ECHO_STATE = {
  kitoltve:    { label: 'Kész',          tone: 'green',   icon: 'CheckCircle2', hint: 'Az értékelésed beérkezett.' },
  // FIGYELEM: nincs piszkozat-tarolas, ezert ez az allapot NEM 'elkezdte'-t
  // jelent. A naplo 'attempted' jelzojet a jegykiadas teszi fel, azt viszont a
  // varazslo CSAK a bekuldes pillanataban hivja — vagyis ez azt jelenti, hogy
  // egy korabbi bekuldes elindult, de nem fejezodott be.
  folyamatban: { label: 'Sikertelen beküldés', tone: 'amber', icon: 'AlertTriangle', hint: 'Egy korábbi beküldés nem fejeződött be. Kérjük, töltsd ki újra.' },
  kitoltheto:  { label: 'Nem kezdett',   tone: 'primary', icon: 'Circle',       hint: 'A kitöltési ablak nyitva.' },
  celkituzes:  { label: 'Célkitűzés',    tone: 'blue',    icon: 'Target',       hint: 'A félév eleji célok adhatók meg.' },
  lezart:      { label: 'Lezárt',        tone: 'slate',   icon: 'Lock',         hint: 'A kitöltési ablak bezárt.' },
  nem_nyitott: { label: 'Még nem nyílt', tone: 'slate',   icon: 'Clock',        hint: 'A kampány még nem indult.' },
};

function ECHO_StateBadge({ allapot }) {
  const s = ECHO_STATE[allapot] || ECHO_STATE.nem_nyitott;
  const Icon = Lucide[s.icon] || Lucide.Circle;
  return <UBadge tone={s.tone}><Icon size={11} /> {s.label}</UBadge>;
}

const ECHO_CAMPAIGN_STATE = {
  draft:      { label: 'Előkészítés', tone: 'slate' },
  open:       { label: 'Nyitva',      tone: 'green' },
  closed:     { label: 'Lezárva',     tone: 'amber' },
  processing: { label: 'Feldolgozás', tone: 'blue' },
  sealed:     { label: 'Zárolt',      tone: 'violet' },
  published:  { label: 'Közzétéve',   tone: 'primary' },
};

function ECHO_date(s) {
  if (!s) return '—';
  try { return new Date(s).toLocaleDateString('hu-HU', { year: 'numeric', month: '2-digit', day: '2-digit' }); }
  catch (e) { return String(s).slice(0, 10); }
}
function ECHO_dateTime(s) {
  if (!s) return '—';
  try { return new Date(s).toLocaleString('hu-HU', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }); }
  catch (e) { return String(s).slice(0, 16); }
}

/* ------------------------------------------------------------
   5. Félév eleji CÉLMEGHATÁROZÓ (Part 1)
   ------------------------------------------------------------
   1–3 cél és 1–3 oktatói elvárás. A szerver ugyanezt a korlátot
   kikényszeríti (ECHO_TOO_MANY_GOALS), ez itt csak a kényelem.
   FONTOS: a célok SZÖVEGE és SZÁMOSSÁGA soha nem kerül át a beküldött
   értékelésbe — a kettő közt egyedül a "célteljesülés" összegzés megy át.
   ------------------------------------------------------------ */

function ECHO_ListEditor({ title, hint, items, setItems, max = 3, placeholder }) {
  const setAt = (i, v) => { const a = items.slice(); a[i] = v; setItems(a); };
  const del   = (i)     => setItems(items.filter((_, k) => k !== i));
  return (
    <div>
      <div className="flex items-baseline justify-between mb-2">
        <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest">{title}</span>
        <span className="text-[11px] font-bold text-slate-400">{items.length}/{max}</span>
      </div>
      {hint && <p className="text-xs text-slate-400 font-medium mb-3">{hint}</p>}
      <div className="space-y-2">
        {items.map((v, i) => (
          <div key={i} className="flex gap-2">
            <span className="flex-none w-9 h-[46px] rounded-xl bg-slate-100 text-slate-500 text-xs font-black flex items-center justify-center">{i + 1}</span>
            <input className={U_input} value={v} maxLength={240} placeholder={placeholder}
              onChange={e => setAt(i, e.target.value)} />
            <button type="button" onClick={() => del(i)}
              className="flex-none w-11 h-[46px] rounded-xl text-slate-300 hover:text-red-500 hover:bg-red-50 flex items-center justify-center transition-colors">
              <Lucide.Trash2 size={16} />
            </button>
          </div>
        ))}
      </div>
      {items.length < max && (
        <button type="button" onClick={() => setItems(items.concat(['']))}
          className="mt-2 inline-flex items-center gap-2 text-sm font-bold text-primary hover:bg-primary/5 rounded-xl px-3 py-2.5 transition-colors">
          <Lucide.Plus size={16} /> Hozzáadás
        </button>
      )}
    </div>
  );
}

function ECHO_GoalsView({ course, onBack, onSaved }) {
  const [form, setForm] = useState(null);
  const [goals, setGoals] = useState([]);
  const [exps, setExps] = useState([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [toast, setToast] = useState('');
  const lang = ECHO_lang();

  useEffect(() => {
    let dead = false;
    (async () => {
      try {
        const f = await ECHO_api.getForm(course.campaign_id, course.course_id);
        if (dead) return;
        setForm(f);
        const g = (f && f.goals) || {};
        setGoals(Array.isArray(g.goals) && g.goals.length ? g.goals.map(String) : ['']);
        setExps(Array.isArray(g.expectations) && g.expectations.length ? g.expectations.map(String) : ['']);
      } catch (e) { if (!dead) { setForm(false); setErr(ECHO_msg(e)); } }
    })();
    return () => { dead = true; };
  }, [course.campaign_id, course.course_id]);

  const save = async () => {
    const g = goals.map(s => String(s).trim()).filter(Boolean).slice(0, 3);
    const x = exps.map(s => String(s).trim()).filter(Boolean).slice(0, 3);
    setBusy(true); setErr('');
    try {
      await ECHO_api.saveGoals(course.campaign_id, course.course_id, g, x);
      setToast('A célok elmentve.');
      onSaved && onSaved();
    } catch (e) { setErr(ECHO_msg(e)); }
    finally { setBusy(false); }
  };

  if (form === null) {
    return (
      <div className="p-6 sm:p-8 max-w-3xl mx-auto space-y-4">
        <SkeletonBar w="180px" h={14} />
        <div className="bg-white rounded-3xl border border-slate-100 p-6 space-y-4">
          <SkeletonBar w="60%" h={18} /><SkeletonBar w="90%" /><SkeletonBar w="80%" /><SkeletonBar w="70%" />
        </div>
      </div>
    );
  }

  // Hibaag — a testverkomponens (ECHO_Wizard) mintajara. Enelkul a betoltes
  // elhasalasa utan (form === false) egy mukodokepesnek LATSZO, ures
  // celszerkeszto jelenne meg, amiben a mentes egy masodik hibat adna.
  if (form === false) {
    return (
      <div className="p-8 max-w-3xl mx-auto">
        <UEmpty icon={<Lucide.AlertCircle size={28} />}
          title="A célmeghatározás nem tölthető be" subtitle={err}
          action={<button onClick={onBack} className={U_btnGhost}>Vissza</button>} />
      </div>
    );
  }

  const part1 = form && form.form && Array.isArray(form.form.parts)
    ? form.form.parts.find(p => p.id === 'part1') : null;

  return (
    <div className="p-4 sm:p-8 max-w-3xl mx-auto">
      <UToast msg={toast} onDone={() => setToast('')} />
      <button onClick={onBack} className="inline-flex items-center gap-2 text-sm font-bold text-slate-400 hover:text-primary mb-5 transition-colors">
        <Lucide.ArrowLeft size={16} /> Vissza a kurzusokhoz
      </button>

      <div className="bg-white rounded-3xl border border-slate-100 p-6 sm:p-8">
        <div className="flex items-start gap-3 mb-6">
          <div className="w-12 h-12 rounded-2xl bg-primary/10 text-primary flex items-center justify-center flex-none">
            <Lucide.Target size={22} />
          </div>
          <div className="min-w-0">
            <h2 className="text-xl font-black text-slate-900 tracking-tight">
              {part1 ? <ECHO_Src>{ECHO_txt(part1, lang)}</ECHO_Src> : 'Célmeghatározás'}
            </h2>
            <p className="text-sm text-slate-400 font-medium mt-0.5">
              <ECHO_Src>{course.course_code} · {course.course_name}</ECHO_Src>
            </p>
          </div>
        </div>

        <div className="bg-sky-50/60 border border-sky-100 rounded-2xl px-4 py-3 mb-7 flex gap-2.5">
          <Lucide.Info size={16} className="text-sky-500 flex-none mt-0.5" />
          <p className="text-xs text-sky-900/70 font-medium leading-relaxed">
            A félév elején kitűzött célok csak a Tiéd — az oktató nem látja őket, és a
            félév végi értékelésbe sem kerülnek át. Egyedül azt visszük tovább, hogy a
            céljaid mennyiben teljesültek.
          </p>
        </div>

        <div className="space-y-8">
          <ECHO_ListEditor title="Céljaim ezen a kurzuson" max={3} items={goals} setItems={setGoals}
            placeholder="Pl. magabiztosan írjak SQL lekérdezést"
            hint="Legfeljebb 3 cél. Konkrét, félév végén eldönthető megfogalmazás segít a legtöbbet." />
          <ECHO_ListEditor title="Elvárásaim az oktatótól" max={3} items={exps} setItems={setExps}
            placeholder="Pl. kapjak érdemi visszajelzést a beadandóra"
            hint="Legfeljebb 3 elvárás." />
        </div>

        {err && (
          <div className="mt-6 bg-red-50 border border-red-100 rounded-2xl px-4 py-3 text-sm font-bold text-red-600 flex gap-2">
            <Lucide.AlertCircle size={16} className="flex-none mt-0.5" /> {err}
          </div>
        )}

        <div className="mt-8 flex flex-col sm:flex-row gap-3">
          <button onClick={save} disabled={busy} className={U_btnPrimary + ' flex-1'}>
            {busy ? <Lucide.Loader2 size={16} className="animate-spin" /> : <Lucide.Save size={16} />}
            {busy ? 'Mentés…' : 'Célok mentése'}
          </button>
          <button onClick={onBack} className={U_btnGhost}>Bezárás</button>
        </div>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------
   6. Félév végi KITÖLTŐ VARÁZSLÓ
   ------------------------------------------------------------ */

/* A beküldött payload összeállítása. Az alakot az echo_submit fejléce írja elő:
     { attendance, course:{…}, teachers:[{teacher, skipped, skip_reason, answers:{…}}] }
   Modulszintű (nem a varázsló closure-jében), hogy önmagában is tesztelhető
   legyen a valódi compiled JSONB-vel.
   A szerver ezen felül még LEVÁGJA az azonosító mezőket — a frontend nem
   védvonal, csak jóhiszemű fél. Ide szándékosan nem kerül semmilyen
   időbélyeg, sorszám vagy hallgatói azonosító. */
function ECHO_buildPayload(compiled, teachers, ans, tans, hasGoals) {
  const sections = (compiled && compiled.sections) || [];
  const courseAns = {};
  let attendance = null;

  sections.forEach((sec) => {
    if (sec.part && sec.part !== 'part2') return;
    (sec.questions || []).forEach((q) => {
      if (q.repeat) return;
      if (!ECHO_condOk(q.cond, { answers: ans, hasGoals })) return;
      const v = ans[q.id];
      if (v === undefined || v === null || v === '' || (Array.isArray(v) && !v.length)) return;
      // Az óralátogatás az echo_submit szerint a payload GYÖKERÉBE megy
      // (v_att := p_payload->>'attendance'), nem a course objektumba.
      if (q.id === 'attendance') { attendance = String(v); return; }
      courseAns[q.id] = v;
    });
  });

  // A kihagyás-kérdés (type:"skip", repeat:"teacher") — ez nem válasz, hanem
  // a skipped/skip_reason mezőpár forrása, ezért az answers közé nem kerül be.
  const skipQ = sections
    .reduce((acc, s) => acc.concat((s.questions || []).filter(q => q.type === 'skip' && q.repeat === 'teacher')), [])[0];

  const tArr = (teachers || []).map((t) => {
    const bag = (tans && tans[t.id]) || {};
    const skipVal = skipQ ? bag[skipQ.id] : undefined;
    const skipped = !!(skipVal !== undefined && skipVal !== null && skipVal !== '');
    const answers = {};
    if (!skipped) {
      Object.keys(bag).forEach((k) => {
        if (skipQ && k === skipQ.id) return;
        const v = bag[k];
        if (v === undefined || v === null || v === '' || (Array.isArray(v) && !v.length)) return;
        answers[k] = v;
      });
    }
    return { teacher: t.id, skipped, skip_reason: skipped ? String(skipVal) : null, answers };
  });

  return { attendance, course: courseAns, teachers: tArr };
}

function ECHO_Wizard({ course, onBack, onSubmitted }) {
  const [form, setForm] = useState(null);
  const [err, setErr] = useState('');
  const [step, setStep] = useState(0);
  const [ans, setAns] = useState({});     // kurzusszintű: kérdés_id -> érték
  const [tans, setTans] = useState({});   // oktató_id -> { kérdés_id -> érték }
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [touched, setTouched] = useState(false);
  // A kiadott, de meg el nem koltott jegy. Csak a memoriaban el (nem
  // localStorage-ban): a jegy egy alairt, ervenyes bekuldesi jogosultsag,
  // amit nem teszunk a hallgato gepere. Lasd a submit() magyarazatat.
  const ticketRef = useRef(null);
  const lang = ECHO_lang();
  // A "randomize" kérdések keverési magja — kitöltésenként egyszer születik.
  const [seed] = useState(() => String(Date.now()) + ':' + Math.random().toString(36).slice(2));

  useEffect(() => {
    let dead = false;
    (async () => {
      try {
        const f = await ECHO_api.getForm(course.campaign_id, course.course_id);
        if (!dead) setForm(f);
      } catch (e) { if (!dead) { setForm(false); setErr(ECHO_msg(e)); } }
    })();
    return () => { dead = true; };
  }, [course.campaign_id, course.course_id]);

  useEffect(() => { window.scrollTo({ top: 0, behavior: 'smooth' }); }, [step]);

  if (form === null) {
    return (
      <div className="p-4 sm:p-8 max-w-3xl mx-auto space-y-4">
        <SkeletonBar w="180px" h={14} />
        <div className="bg-white rounded-3xl border border-slate-100 p-6 space-y-5">
          <SkeletonBar w="55%" h={20} />
          <SkeletonBar w="100%" h={48} /><SkeletonBar w="100%" h={48} /><SkeletonBar w="100%" h={48} />
        </div>
      </div>
    );
  }
  if (form === false) {
    return (
      <div className="p-8 max-w-3xl mx-auto">
        <UEmpty icon={<Lucide.AlertCircle size={28} />} title="A kérdőív nem tölthető be" subtitle={err}
          action={<button onClick={onBack} className={U_btnGhost}>Vissza</button>} />
      </div>
    );
  }

  const compiled = form.form || {};
  const teachers = Array.isArray(form.teachers) ? form.teachers : [];
  const hasGoals = !!(form.goals && Array.isArray(form.goals.goals) && form.goals.goals.length > 0);
  const steps = ECHO_buildSteps(compiled, teachers);
  const cur = steps[Math.min(step, steps.length - 1)];

  // Az aktuális lépés látható kérdései (a cond kiértékelése után).
  const visibleQs = (() => {
    if (!cur || !cur.section) return [];
    const qs = Array.isArray(cur.section.questions) ? cur.section.questions : [];
    if (cur.kind === 'teacher') {
      const bag = tans[cur.teacher.id] || {};
      return qs.filter(q => q.repeat === 'teacher' && ECHO_condOk(q.cond, { answers: bag, hasGoals }));
    }
    return qs.filter(q => !q.repeat && ECHO_condOk(q.cond, { answers: ans, hasGoals }));
  })();

  const getV = (q) => (cur.kind === 'teacher' ? (tans[cur.teacher.id] || {})[q.id] : ans[q.id]);
  const setV = (q, v) => {
    if (cur.kind === 'teacher') {
      const id = cur.teacher.id;
      setTans(prev => ({ ...prev, [id]: { ...(prev[id] || {}), [q.id]: v } }));
    } else {
      setAns(prev => ({ ...prev, [q.id]: v }));
    }
    setTouched(false);
  };

  const missing = visibleQs.filter(q => q.required && !ECHO_answered(q, getV(q)));
  const isLast = cur && cur.kind === 'review';

  const submit = async () => {
    setBusy(true); setErr('');
    try {
      // 1) AZONOSÍTOTT lépés: a részvételi napló megjelöli, hogy próbálkoztunk.
      //    A jegyről a szerver semmit nem tárol — csak aláírja.
      //
      //    JEGY-ÚJRAHASZNOSÍTÁS: ha egy korábbi próbálkozás a 2) lépésnél bukott
      //    el (pl. hálózati hiba), a jegy NINCS elköltve — az elköltést jelző
      //    nonce ugyanabban a tranzakcióban íródik, mint a válasz, tehát együtt
      //    is szállnak el. Ilyenkor ÚJ jegyet kérni két bajt okozna:
      //      • a hallgató elfogyasztaná a max_tickets_per_course keretét, és a
      //        második hiba után ECHO_TICKET_LIMIT-tel kizárná magát;
      //      • az elpazarolt jegy miatt a kurzuson a kiadott jegyek száma
      //        tartósan meghaladná a válaszokét, és az echo.mark_submitted()
      //        — ami jegyalapon számol — SOHA nem tudná lezártnak jelölni.
      //    Ezért a memóriában tartjuk, és amíg érvényes, újra ezt küldjük.
      const now = Date.now();
      if (!ticketRef.current || ticketRef.current.expMs <= now) {
        const t = await ECHO_api.issueTicket(course.campaign_id, course.course_id);
        // Biztonsagi ratartas: a szerveroldali TTL-nel 60 masodperccel korabban
        // tekintjuk lejartnak, hogy a halozati ido ne fusson bele a lejaratba.
        const ttlMs = (Number(t.ttl_minutes) || 0) * 60000;
        ticketRef.current = { ticket: t.ticket, expMs: now + Math.max(ttlMs - 60000, 0) };
      }
      // 2) ANONIM lépés: külön, munkamenet nélküli klienssel. A JWT nem megy ki.
      await ECHO_api.submit(ticketRef.current.ticket,
                            ECHO_buildPayload(compiled, teachers, ans, tans, hasGoals));
      ticketRef.current = null;   // elkoltottuk, tobbe nem hasznalhato
      setDone(true);
      onSubmitted && onSubmitted(course);
    } catch (e) {
      // A mar elkoltott vagy lejart jegyet dobjuk el, hogy az ujraprobalkozas
      // frisset kerjen; minden mas hibanal megtartjuk (lasd fent).
      const raw = (e && (e.message || e.error_description || e.hint)) || '';
      if (raw.indexOf('ECHO_TICKET_SPENT') >= 0 || raw.indexOf('ECHO_TICKET_EXPIRED') >= 0
          || raw.indexOf('ECHO_TICKET_BADSIG') >= 0) ticketRef.current = null;
      setErr(ECHO_msg(e));
    }
    finally { setBusy(false); }
  };

  if (done) {
    return (
      <div className="p-4 sm:p-8 max-w-2xl mx-auto">
        <div className="bg-white rounded-3xl border border-slate-100 p-8 sm:p-10 text-center">
          <div className="w-20 h-20 rounded-3xl bg-emerald-50 text-emerald-500 flex items-center justify-center mx-auto mb-5">
            <Lucide.CheckCircle2 size={38} />
          </div>
          <h2 className="text-2xl font-black text-slate-900 tracking-tight">Köszönjük az értékelést</h2>
          <p className="text-sm text-slate-500 font-medium mt-3 leading-relaxed max-w-md mx-auto">
            A válaszaid névtelenül érkeztek be. A rendszer azt tartja nyilván, hogy
            ezt a kurzust értékelted, de azt nem, hogy mit írtál — a kettő külön
            táblában él, közös kulcs nélkül.
          </p>
          <button onClick={onBack} className={U_btnPrimary + ' mt-7'}>
            <Lucide.ArrowLeft size={16} /> Vissza a kurzusokhoz
          </button>
        </div>
      </div>
    );
  }

  const pct = Math.round(((step + 1) / steps.length) * 100);
  const title = cur.kind === 'review'
    ? 'Összegzés és beküldés'
    : ECHO_txt(cur.section, lang);

  return (
    <div className="p-4 sm:p-8 max-w-3xl mx-auto pb-32">
      <button onClick={onBack} className="inline-flex items-center gap-2 text-sm font-bold text-slate-400 hover:text-primary mb-4 transition-colors">
        <Lucide.ArrowLeft size={16} /> Kilépés — a válaszaid nem mentődnek
      </button>

      {/* fejléc + lépésjelző */}
      <div className="bg-white rounded-3xl border border-slate-100 p-5 sm:p-6 mb-4">
        <p className="text-xs font-bold text-slate-400 mb-1">
          <ECHO_Src>{course.course_code} · {course.course_name}</ECHO_Src>
        </p>
        <h2 className="text-xl sm:text-2xl font-black text-slate-900 tracking-tight">
          {cur.kind === 'review' ? title : <ECHO_Src>{title}</ECHO_Src>}
        </h2>
        {cur.kind === 'teacher' && (
          <p className="text-sm font-bold text-primary mt-1">
            <ECHO_Src>{cur.teacher.name}{cur.teacher.title ? ' · ' + cur.teacher.title : ''}</ECHO_Src>
          </p>
        )}
        <div className="mt-4">
          <div className="flex items-center justify-between text-[11px] font-black uppercase tracking-wider text-slate-400 mb-1.5">
            <span>{step + 1}. lépés / {steps.length}</span><span>{pct}%</span>
          </div>
          <div className="h-2 bg-slate-100 rounded-full overflow-hidden">
            <div className="h-full bg-primary rounded-full transition-all duration-300" style={{ width: pct + '%' }} />
          </div>
        </div>
      </div>

      {/* a lépés tartalma */}
      <div className="bg-white rounded-3xl border border-slate-100 px-5 sm:px-8 py-2">
        {cur.kind === 'review' ? (
          <ECHO_Review compiled={compiled} teachers={teachers} ans={ans} tans={tans}
            hasGoals={hasGoals} lang={lang} onJump={setStep} steps={steps} />
        ) : visibleQs.length === 0 ? (
          <div className="py-10 text-center text-sm text-slate-400 font-bold">
            Ebben a szakaszban most nincs megválaszolandó kérdés.
          </div>
        ) : (
          visibleQs.map((q, i) => (
            <ECHO_Question key={(cur.teacher ? cur.teacher.id : cur.section.id) + '|' + q.id}
              q={q} index={i + 1} lang={lang} seed={seed + '|' + (cur.teacher ? cur.teacher.id : cur.section.id)}
              value={getV(q)} onChange={(v) => setV(q, v)} />
          ))
        )}
      </div>

      {touched && missing.length > 0 && (
        <div className="mt-3 bg-amber-50 border border-amber-100 rounded-2xl px-4 py-3 text-sm font-bold text-amber-700 flex gap-2">
          <Lucide.AlertTriangle size={16} className="flex-none mt-0.5" />
          Még {missing.length} kötelező kérdés vár válaszra ezen a lépésen.
        </div>
      )}
      {err && (
        <div className="mt-3 bg-red-50 border border-red-100 rounded-2xl px-4 py-3 text-sm font-bold text-red-600 flex gap-2">
          <Lucide.AlertCircle size={16} className="flex-none mt-0.5" /> {err}
        </div>
      )}

      {/* navigáció — mobilon a hüvelykujj közelében ragad meg */}
      <div className="fixed bottom-0 left-72 right-0 bg-white/95 backdrop-blur border-t border-slate-100 px-4 sm:px-8 py-3 z-40">
        <div className="max-w-3xl mx-auto flex gap-3">
          <button onClick={() => { setTouched(false); setStep(s => Math.max(0, s - 1)); }}
            disabled={step === 0} className={U_btnGhost + ' flex-none'}>
            <Lucide.ChevronLeft size={16} /> Vissza
          </button>
          {isLast ? (
            <button onClick={submit} disabled={busy} className={U_btnPrimary + ' flex-1'}>
              {busy ? <Lucide.Loader2 size={16} className="animate-spin" /> : <Lucide.Send size={16} />}
              {busy ? 'Beküldés…' : 'Névtelen beküldés'}
            </button>
          ) : (
            <button
              onClick={() => { if (missing.length) { setTouched(true); return; } setTouched(false); setStep(s => s + 1); }}
              className={U_btnPrimary + ' flex-1'}>
              Tovább <Lucide.ChevronRight size={16} />
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

// Az összegző lépés: mit fogunk beküldeni. Szándékosan nincs benne
// semmi, ami a kitöltőt azonosítaná.
function ECHO_Review({ compiled, teachers, ans, tans, hasGoals, lang, onJump, steps }) {
  const label = (q) => ECHO_txt(q, lang);
  const show = (v) => Array.isArray(v) ? v.join(' · ') : (typeof v === 'number' ? String(v) : String(v || '—'));

  const courseRows = [];
  (compiled.sections || []).forEach((sec) => {
    if (sec.part && sec.part !== 'part2') return;
    (sec.questions || []).forEach((q) => {
      if (q.repeat) return;
      if (!ECHO_condOk(q.cond, { answers: ans, hasGoals })) return;
      courseRows.push({ q, v: ans[q.id] });
    });
  });

  const skipQ = (compiled.sections || [])
    .reduce((acc, s) => acc.concat((s.questions || []).filter(q => q.type === 'skip' && q.repeat === 'teacher')), [])[0];

  return (
    <div className="py-6 space-y-7">
      <div className="bg-emerald-50/60 border border-emerald-100 rounded-2xl px-4 py-3 flex gap-2.5">
        <Lucide.Lock size={16} className="text-emerald-600 flex-none mt-0.5" />
        <p className="text-xs text-emerald-900/70 font-medium leading-relaxed">
          A beküldés külön, bejelentkezés nélküli csatornán megy: a válaszaid mellé
          nem kerül sem a fiókod azonosítója, sem időbélyeg. A rendszer csak azt
          jegyzi fel — külön táblában —, hogy ezt a kurzust értékelted.
        </p>
      </div>

      <div>
        <h4 className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-3">A kurzusra adott válaszaid</h4>
        <div className="space-y-2.5">
          {courseRows.map(({ q, v }) => (
            <div key={q.id} className="flex items-start gap-3 text-sm">
              <span className="flex-1 text-slate-400 font-medium"><ECHO_Src>{label(q)}</ECHO_Src></span>
              <span className="flex-1 text-slate-800 font-bold text-right"><ECHO_Src>{show(v)}</ECHO_Src></span>
            </div>
          ))}
        </div>
      </div>

      <div>
        <h4 className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-3">Az oktatók értékelése</h4>
        <div className="space-y-2">
          {teachers.map((t, i) => {
            const bag = tans[t.id] || {};
            const sv = skipQ ? bag[skipQ.id] : undefined;
            const skipped = !!(sv !== undefined && sv !== null && sv !== '');
            const idx = steps.findIndex(s => s.kind === 'teacher' && s.teacher.id === t.id);
            return (
              <button key={t.id} onClick={() => idx >= 0 && onJump(idx)}
                className="w-full flex items-center gap-3 rounded-2xl border border-slate-100 px-4 py-3 hover:border-slate-200 hover:bg-slate-50 transition-all text-left">
                <div className="w-9 h-9 rounded-xl bg-slate-100 text-slate-500 flex items-center justify-center flex-none">
                  <Lucide.User size={16} />
                </div>
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-black text-slate-800 truncate"><ECHO_Src>{t.name}</ECHO_Src></p>
                  <p className="text-[11px] text-slate-400 font-bold truncate">
                    {skipped ? <ECHO_Src>{'kihagyva — ' + String(sv)}</ECHO_Src> : 'értékelve'}
                  </p>
                </div>
                {skipped ? <UBadge tone="amber">kihagyva</UBadge> : <UBadge tone="green">kész</UBadge>}
              </button>
            );
          })}
          {teachers.length === 0 && (
            <p className="text-sm text-slate-400 font-bold">Ebben a kurzusban nincs véleményezhető oktató.</p>
          )}
        </div>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------
   7. ECHO_StudentView — a hallgatói belépőpont
   ------------------------------------------------------------ */

function ECHO_StudentView({ user }) {
  const [rows, setRows] = useState(null);
  const [err, setErr] = useState('');
  const [refreshing, setRefreshing] = useState(false);
  const [mode, setMode] = useState(null);     // { kind:'goals'|'fill', course }
  const [localDone, setLocalDone] = useState({});  // campaign|course -> true

  const load = async (background) => {
    if (background) setRefreshing(true);
    setErr('');
    try {
      const d = await ECHO_api.myCourses();
      setRows(Array.isArray(d) ? d : []);
    } catch (e) {
      setRows([]);
      setErr(ECHO_msg(e));
    } finally { setRefreshing(false); }
  };
  useEffect(() => { load(false); }, []);

  const key = (c) => c.campaign_id + '|' + c.course_id;

  if (mode && mode.kind === 'goals') {
    return <ECHO_GoalsView course={mode.course} onBack={() => { setMode(null); load(true); }} onSaved={() => load(true)} />;
  }
  if (mode && mode.kind === 'fill') {
    return (
      <ECHO_Wizard course={mode.course}
        onBack={() => { setMode(null); load(true); }}
        onSubmitted={(c) => setLocalDone(p => ({ ...p, [key(c)]: true }))} />
    );
  }

  if (rows === null) {
    return (
      <div className="p-4 sm:p-8 max-w-5xl mx-auto">
        <SkeletonBar w="220px" h={22} className="mb-2" />
        <SkeletonBar w="340px" h={13} className="mb-7" />
        <div className="bg-white rounded-3xl border border-slate-100 overflow-hidden">
          <table className="w-full"><tbody><SkeletonRows rows={4} cols={['45%', '20%', '25%', '60px']} /></tbody></table>
        </div>
      </div>
    );
  }

  const open   = rows.filter(c => !localDone[key(c)] && (c.allapot === 'kitoltheto' || c.allapot === 'folyamatban'));
  const goals  = rows.filter(c => c.allapot === 'celkituzes');
  const rest   = rows.filter(c => open.indexOf(c) < 0 && goals.indexOf(c) < 0);

  const Card = ({ c }) => {
    const doneNow = !!localDone[key(c)];
    const allapot = doneNow ? 'kitoltve' : c.allapot;
    const canFill = !doneNow && c.is_open && (c.allapot === 'kitoltheto' || c.allapot === 'folyamatban');
    const canGoals = c.is_goals_open;
    return (
      <div className="bg-white rounded-3xl border border-slate-100 p-5 hover:border-slate-200 transition-all">
        <div className="flex items-start justify-between gap-3 mb-3">
          <div className="min-w-0">
            <p className="text-[11px] font-black text-slate-400 tracking-wider"><ECHO_Src>{c.course_code}</ECHO_Src></p>
            <h3 className="font-black text-slate-900 leading-snug mt-0.5"><ECHO_Src>{c.course_name}</ECHO_Src></h3>
          </div>
          <ECHO_StateBadge allapot={allapot} />
        </div>
        <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] font-bold text-slate-400 mb-4">
          <span className="inline-flex items-center gap-1"><Lucide.CalendarDays size={12} /> <ECHO_Src>{c.term}</ECHO_Src></span>
          <span className="inline-flex items-center gap-1"><Lucide.Users size={12} /> {c.teacher_count} oktató</span>
          {c.closes_at && <span className="inline-flex items-center gap-1"><Lucide.Clock size={12} /> {ECHO_date(c.closes_at)}-ig</span>}
          {c.goals_saved && <span className="inline-flex items-center gap-1 text-primary"><Lucide.Target size={12} /> célok megadva</span>}
        </div>
        <div className="flex flex-col sm:flex-row gap-2">
          {canFill && (
            <button onClick={() => setMode({ kind: 'fill', course: c })} className={U_btnPrimary + ' flex-1 py-3.5'}>
              <Lucide.ClipboardList size={16} />
              {/* Nincs piszkozat-mentes: minden belepes ures urlappal indul, ezert
                  'folytatas' helyett 'ujrakezdes'. Lasd az ECHO_STATE megjegyzeset. */}
              {c.allapot === 'folyamatban' ? 'Értékelés újrakezdése' : 'Értékelés kitöltése'}
            </button>
          )}
          {canGoals && (
            <button onClick={() => setMode({ kind: 'goals', course: c })}
              className={(canFill ? U_btnGhost : U_btnPrimary) + ' flex-1 py-3.5'}>
              <Lucide.Target size={16} /> {c.goals_saved ? 'Célok szerkesztése' : 'Célok megadása'}
            </button>
          )}
          {!canFill && !canGoals && (
            <div className="flex-1 text-xs font-bold text-slate-400 py-3">
              {(ECHO_STATE[allapot] || ECHO_STATE.nem_nyitott).hint}
            </div>
          )}
        </div>
      </div>
    );
  };

  const Group = ({ title, subtitle, items, icon }) => {
    if (!items.length) return null;
    const Icon = Lucide[icon] || Lucide.Circle;
    return (
      <section className="mb-8">
        <div className="flex items-center gap-2 mb-3">
          <Icon size={15} className="text-slate-400" />
          <h2 className="text-sm font-black text-slate-700 tracking-tight">{title}</h2>
          <span className="text-[11px] font-black text-slate-300">{items.length}</span>
        </div>
        {subtitle && <p className="text-xs text-slate-400 font-medium -mt-2 mb-3">{subtitle}</p>}
        <div className="grid gap-3 sm:grid-cols-2">
          {items.map(c => <Card key={key(c)} c={c} />)}
        </div>
      </section>
    );
  };

  return (
    <div className="p-4 sm:p-8 max-w-5xl mx-auto">
      <div className="flex items-start justify-between gap-4 mb-7">
        <div>
          <h1 className="text-2xl sm:text-3xl font-black text-slate-900 tracking-tight">Kurzusértékelés</h1>
          <p className="text-sm text-slate-400 font-medium mt-1">
            Oktatói munka hallgatói véleményezése · 28/2023. szenátusi határozat
          </p>
        </div>
        <div className="flex items-center gap-3 flex-none pt-2">
          <RefreshingBadge on={refreshing} />
          <button onClick={() => load(true)} className="w-10 h-10 rounded-xl hover:bg-slate-100 text-slate-400 flex items-center justify-center transition-colors" title="Frissítés">
            <Lucide.RefreshCw size={16} />
          </button>
        </div>
      </div>

      {err && (
        <div className="mb-6 bg-red-50 border border-red-100 rounded-2xl px-4 py-3 text-sm font-bold text-red-600 flex gap-2">
          <Lucide.AlertCircle size={16} className="flex-none mt-0.5" /> {err}
        </div>
      )}

      {rows.length === 0 && !err && (
        <UEmpty icon={<Lucide.ClipboardList size={28} />} title="Most nincs értékelhető kurzusod"
          subtitle="Amikor egy kampány megnyílik, a véleményezhető kurzusaid itt jelennek meg." />
      )}

      <Group title="Kitölthető most" icon="ClipboardList" items={open}
        subtitle="A félév végi értékelés. Névtelen — a válaszaid nem köthetők vissza hozzád." />
      <Group title="Félév eleji célmeghatározás" icon="Target" items={goals}
        subtitle="1–3 saját cél és 1–3 oktatói elvárás. Csak Te látod." />
      <Group title="Lezárt és kész kurzusok" icon="Archive" items={rest} />
    </div>
  );
}

/* ------------------------------------------------------------
   8. ECHO_CampaignsPanel — MIR / admin, kampányfül
   ------------------------------------------------------------
   FONTOS: ez a PANEL SEMMILYEN válasz-TARTALMAT nem mutat, mert az
   echo_campaigns() és az echo_rate() szándékosan csak darabszámot ad
   vissza. Az eredmény a 2. szelet RPC-in (echo_course_results /
   echo_teacher_results) át jön, külön nézetben (ECHO_TeacherView), a
   k-anonimitási küszöbökkel — lásd 16_echo_reports.sql 4–5. szakasz.
   Az ECHO_AdminView (13. szakasz) ezt a panelt fűzi fülre a szerkesztővel
   és a moderálással.
   ------------------------------------------------------------ */

/* A kizárási szabályok katalógusa — az echo.exclusion_rule seed sorai.
   Felületi HIVATKOZÁSI szöveg, nem adatforrás: a tényleges naplósorokat az
   adatbázis tartja. A §-hivatkozások az SQL-ben is BECSLÉSSEL szerepelnek
   (a 28/2023. határozat szövege nem állt rendelkezésre) — ezért látszik itt
   is a "pontosítandó" jelölés. */
const ECHO_EXCLUSION_RULES = [
  { code: 'LETSZAM_ALATT',       name: 'Létszám a küszöb alatt',            scope: 'kurzus', why: 'A kis csoportban a válasz tartalma önmagában azonosítaná a kitöltőt.' },
  { code: 'NINCS_ORARENDI_INFO', name: 'Nincs órarendi információ',         scope: 'kurzus', why: 'Nincs kontaktóra, így nincs mit véleményezni.' },
  { code: 'VIZSGAKURZUS',        name: 'Vizsgakurzus',                      scope: 'kurzus', why: 'Nincs oktatási tevékenység, csak számonkérés.' },
  { code: 'NINCS_OKTATO',        name: 'Nincs rögzített oktató',            scope: 'kurzus', why: 'Oktatói értékelés nem képezhető.' },
  { code: 'OKTATOI_ARANY_ALATT', name: 'Oktatói óraarány a küszöb alatt',   scope: 'oktatói pár', why: 'A hallgatónak nincs elegendő tapasztalata az oktató munkájáról.' },
];

function ECHO_Meter({ value, max, tone = 'primary' }) {
  const pct = max > 0 ? Math.min(100, Math.round((value / max) * 100)) : 0;
  const bar = { primary: 'bg-primary', green: 'bg-emerald-500', amber: 'bg-amber-500' }[tone] || 'bg-primary';
  return (
    <div className="h-2 bg-slate-100 rounded-full overflow-hidden">
      <div className={'h-full rounded-full transition-all ' + bar} style={{ width: pct + '%' }} />
    </div>
  );
}

function ECHO_CampaignsPanel({ user }) {
  const [rows, setRows] = useState(null);
  const [err, setErr] = useState('');
  const [refreshing, setRefreshing] = useState(false);
  const [sel, setSel] = useState(null);        // kiválasztott kampány
  const [rate, setRate] = useState(null);      // echo_rate eredménye
  const [rateBusy, setRateBusy] = useState(false);
  const [formOpen, setFormOpen] = useState(false);
  const [preview, setPreview] = useState(null); // { form } | { error }
  const [rebuild, setRebuild] = useState(null); // echo_rebuild_eligibility eredménye
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState('');
  const lang = ECHO_lang();

  const load = async (background) => {
    if (background) setRefreshing(true);
    setErr('');
    try {
      const d = await ECHO_api.campaigns();
      const arr = Array.isArray(d) ? d : [];
      setRows(arr);
      setSel(prev => (prev ? arr.find(c => c.id === prev.id) || arr[0] || null : arr[0] || null));
    } catch (e) { setRows([]); setErr(ECHO_msg(e)); }
    finally { setRefreshing(false); }
  };
  useEffect(() => { load(false); }, []);

  useEffect(() => {
    if (!sel) { setRate(null); return; }
    let dead = false;
    setRateBusy(true);
    ECHO_api.rate(sel.id)
      .then(d => { if (!dead) setRate(d); })
      .catch(e => { if (!dead) { setRate(null); setErr(ECHO_msg(e)); } })
      .finally(() => { if (!dead) setRateBusy(false); });
    return () => { dead = true; };
  }, [sel && sel.id]);

  /* A kérdőív megtekintése.
     A 15_echo_core.sql NEM tartalmaz admin oldali "add vissza a template
     compiled JSONB-jét" RPC-t — az echo_get_form() a HÍVÓ saját részvételére
     szűr (ECHO_NOT_ELIGIBLE). Ezért a megtekintéshez a saját, e kampányban
     véleményezhető kurzusunkat használjuk; ha ilyen nincs, ezt kimondjuk,
     nem találunk ki nem létező végpontot. */
  const openForm = async () => {
    setFormOpen(true); setPreview(null);
    try {
      const mine = await ECHO_api.myCourses();
      const hit = (Array.isArray(mine) ? mine : []).find(c => c.campaign_id === sel.id);
      if (!hit) {
        setPreview({ error: 'A kérdőív előnézetéhez a 15_echo_core.sql-ben nincs admin RPC: az echo_get_form() a hívó saját részvételére szűr. Ehhez a kampányhoz nincs saját véleményezhető kurzusod, ezért a kérdőív most nem jeleníthető meg.' });
        return;
      }
      const f = await ECHO_api.getForm(hit.campaign_id, hit.course_id);
      setPreview({ form: (f && f.form) || null });
    } catch (e) { setPreview({ error: ECHO_msg(e) }); }
  };

  const doRebuild = async () => {
    if (!sel) return;
    if (!window.confirm('Újraépíted a(z) ' + sel.code + ' kampány alkalmassági listáját?\n\nNyitott kampánynál a már kiadott jegyek egy része érvénytelenné válhat.')) return;
    setBusy(true); setErr('');
    try {
      const r = await ECHO_api.rebuildEligibility(sel.id);
      setRebuild(r);
      setToast('Az alkalmassági lista újraépült.');
      await load(true);
    } catch (e) { setErr(ECHO_msg(e)); }
    finally { setBusy(false); }
  };

  if (rows === null) {
    return (
      <div className="p-4 sm:p-8 max-w-6xl mx-auto">
        <SkeletonBar w="240px" h={22} className="mb-2" />
        <SkeletonBar w="380px" h={13} className="mb-7" />
        <div className="bg-white rounded-3xl border border-slate-100 overflow-hidden">
          <table className="w-full"><tbody><SkeletonRows rows={5} cols={['30%', '15%', '20%', '20%', '15%']} /></tbody></table>
        </div>
      </div>
    );
  }

  const isAdminRole = user && (user.role === 'SUPERADMIN' || user.role === 'ADMIN');

  return (
    <div className="p-4 sm:p-8 max-w-6xl mx-auto">
      <UToast msg={toast} onDone={() => setToast('')} />

      <div className="flex items-start justify-between gap-4 mb-7">
        <div>
          <h1 className="text-2xl sm:text-3xl font-black text-slate-900 tracking-tight">ECHO — kampánykezelés</h1>
          <p className="text-sm text-slate-400 font-medium mt-1">
            Oktatói munka hallgatói véleményezése · kitöltési arány és kizárási napló
          </p>
        </div>
        <div className="flex items-center gap-3 flex-none pt-2">
          <RefreshingBadge on={refreshing} />
          <button onClick={() => load(true)} className="w-10 h-10 rounded-xl hover:bg-slate-100 text-slate-400 flex items-center justify-center transition-colors" title="Frissítés">
            <Lucide.RefreshCw size={16} />
          </button>
        </div>
      </div>

      {err && (
        <div className="mb-6 bg-red-50 border border-red-100 rounded-2xl px-4 py-3 text-sm font-bold text-red-600 flex gap-2">
          <Lucide.AlertCircle size={16} className="flex-none mt-0.5" /> {err}
        </div>
      )}

      {rows.length === 0 && !err && (
        <UEmpty icon={<Lucide.Megaphone size={28} />} title="Nincs kampány"
          subtitle="Futtasd le a 15_echo_core.sql-t — a demó seed létrehoz egy nyitott kampányt." />
      )}

      {/* kampánylista */}
      {rows.length > 0 && (
        <div className="bg-white rounded-3xl border border-slate-100 overflow-hidden mb-6">
          <div className="overflow-x-auto">
            <table className="w-full min-w-[760px]">
              <thead>
                <tr className="border-b border-slate-100 text-left">
                  {['Kampány', 'Állapot', 'Ablak', 'Kitöltési arány', 'Kizárva'].map(h => (
                    <th key={h} className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest">{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.map(c => {
                  const st = ECHO_CAMPAIGN_STATE[c.state] || { label: c.state, tone: 'slate' };
                  const arany = c.kitoltesi_arany == null ? 0 : Number(c.kitoltesi_arany);
                  const on = sel && sel.id === c.id;
                  return (
                    <tr key={c.id} onClick={() => setSel(c)}
                      className={'border-b border-slate-50 last:border-0 cursor-pointer transition-colors ' + (on ? 'bg-primary/5' : 'hover:bg-slate-50')}>
                      <td className="px-6 py-4">
                        <p className="font-black text-slate-900 text-sm"><ECHO_Src>{c.name}</ECHO_Src></p>
                        <p className="text-[11px] font-bold text-slate-400 mt-0.5"><ECHO_Src>{c.code} · {c.term}</ECHO_Src></p>
                      </td>
                      <td className="px-6 py-4"><UBadge tone={st.tone}>{st.label}</UBadge></td>
                      <td className="px-6 py-4 text-xs font-bold text-slate-500 whitespace-nowrap">
                        {ECHO_date(c.opens_at)} — {ECHO_date(c.closes_at)}
                      </td>
                      <td className="px-6 py-4 min-w-[180px]">
                        <div className="flex items-center gap-2 mb-1.5">
                          <span className="text-sm font-black text-slate-900">{arany.toFixed(1)}%</span>
                          <span className="text-[11px] font-bold text-slate-400">{c.responses} / {c.eligible_students}</span>
                        </div>
                        <ECHO_Meter value={c.responses} max={c.eligible_students} tone={arany >= 50 ? 'green' : (arany >= 20 ? 'primary' : 'amber')} />
                      </td>
                      <td className="px-6 py-4 text-sm font-black text-slate-500">{c.excluded_courses}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {sel && (
        <div className="grid gap-6 lg:grid-cols-3">
          {/* bal: számok + kurzusonkénti arány */}
          <div className="lg:col-span-2 space-y-6">
            <div className="bg-white rounded-3xl border border-slate-100 p-6">
              <div className="flex items-start justify-between gap-3 mb-5">
                <div>
                  <h3 className="font-black text-slate-900"><ECHO_Src>{sel.name}</ECHO_Src></h3>
                  <p className="text-xs text-slate-400 font-bold mt-0.5">
                    {ECHO_dateTime(sel.opens_at)} — {ECHO_dateTime(sel.closes_at)}
                  </p>
                </div>
                <button onClick={openForm} className={U_btnGhost + ' py-2.5 px-4 text-sm flex-none'}>
                  <Lucide.FileText size={15} /> Kérdőív
                </button>
              </div>

              <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
                {[
                  { k: 'Jogosult pár', v: sel.eligible_pairs, i: 'Link2' },
                  { k: 'Jogosult hallgató', v: sel.eligible_students, i: 'Users' },
                  { k: 'Elkezdte', v: sel.attempted, i: 'PlayCircle' },
                  { k: 'Beérkezett', v: sel.responses, i: 'Inbox' },
                ].map(x => {
                  const Ic = Lucide[x.i] || Lucide.Circle;
                  return (
                    <div key={x.k} className="bg-slate-50 rounded-2xl p-4">
                      <Ic size={16} className="text-slate-400 mb-2" />
                      <p className="text-xl font-black text-slate-900">{x.v}</p>
                      <p className="text-[10px] font-black text-slate-400 uppercase tracking-wider mt-0.5">{x.k}</p>
                    </div>
                  );
                })}
              </div>

              <div className="flex items-center gap-2 mb-3">
                <h4 className="text-[10px] font-black text-slate-400 uppercase tracking-widest">Kurzusonkénti kitöltés</h4>
                <RefreshingBadge on={rateBusy} />
              </div>
              {rate && Array.isArray(rate.kurzusonkent) && rate.kurzusonkent.length > 0 ? (
                <div className="space-y-3">
                  {rate.kurzusonkent.map(k => (
                    <div key={k.course_id}>
                      <div className="flex items-baseline justify-between gap-3 mb-1.5">
                        <span className="text-sm font-bold text-slate-700 truncate">
                          <ECHO_Src>{k.course_code} · {k.course_name}</ECHO_Src>
                        </span>
                        <span className="text-[11px] font-black text-slate-400 flex-none">
                          {k.valaszok} / {k.eligible} · elkezdte {k.attempted}
                        </span>
                      </div>
                      <ECHO_Meter value={k.valaszok} max={k.eligible} />
                    </div>
                  ))}
                </div>
              ) : rateBusy ? (
                <div className="space-y-3"><SkeletonBar /><SkeletonBar w="80%" /><SkeletonBar w="90%" /></div>
              ) : (
                <p className="text-sm text-slate-400 font-bold">Ehhez a kampányhoz nincs véleményezhető kurzus.</p>
              )}
            </div>
          </div>

          {/* jobb: kizárási napló */}
          <div className="space-y-6">
            <div className="bg-white rounded-3xl border border-slate-100 p-6">
              <div className="flex items-center gap-2 mb-1">
                <Lucide.FileWarning size={16} className="text-slate-400" />
                <h3 className="font-black text-slate-900 text-sm">Kizárási napló</h3>
              </div>
              <p className="text-xs text-slate-400 font-medium mb-5">
                Minden kizárás okkal és §-hivatkozással rögzül az adatbázisban
                (echo.exclusion_log). Ha egy oktató megkérdezi, miért nem kapott
                visszajelzést, erre kell tudni mutatni.
              </p>

              <div className="grid grid-cols-2 gap-3 mb-5">
                <div className="bg-amber-50 rounded-2xl p-4">
                  <p className="text-xl font-black text-amber-700">{sel.excluded_courses}</p>
                  <p className="text-[10px] font-black text-amber-600/70 uppercase tracking-wider mt-0.5">kizárt kurzus</p>
                </div>
                <div className="bg-slate-50 rounded-2xl p-4">
                  <p className="text-xl font-black text-slate-700">{rebuild ? rebuild.excluded_pairs : '—'}</p>
                  <p className="text-[10px] font-black text-slate-400 uppercase tracking-wider mt-0.5">kizárt oktatói pár</p>
                </div>
              </div>

              <div className="space-y-2 mb-5">
                {ECHO_EXCLUSION_RULES.map(r => (
                  <div key={r.code} className="border border-slate-100 rounded-2xl px-4 py-3">
                    <div className="flex items-center justify-between gap-2">
                      <span className="text-xs font-black text-slate-700">{r.name}</span>
                      <UBadge tone={r.scope === 'kurzus' ? 'slate' : 'violet'}>{r.scope}</UBadge>
                    </div>
                    <p className="text-[11px] text-slate-400 font-medium mt-1 leading-relaxed">{r.why}</p>
                    <p className="text-[10px] text-slate-300 font-black tracking-wider mt-1.5">
                      {r.code} · 28/2023. § — pontosítandó
                    </p>
                  </div>
                ))}
              </div>

              {/* Kimondjuk, ami hiányzik: a soronkénti naplóhoz nincs RPC. */}
              <div className="bg-slate-50 rounded-2xl px-4 py-3 flex gap-2.5 mb-4">
                <Lucide.Info size={15} className="text-slate-400 flex-none mt-0.5" />
                <p className="text-[11px] text-slate-500 font-medium leading-relaxed">
                  A SORONKÉNTI napló (melyik kurzus, melyik szabály, milyen adattal)
                  még nem jeleníthető meg: a 15_echo_core.sql nem tartalmaz hozzá
                  public RPC-t, az echo sémára pedig a kliensnek nincs joga. Itt
                  most a kampányszintű darabszámok és a szabálykatalógus látszik.
                </p>
              </div>

              {isAdminRole && (
                <button onClick={doRebuild} disabled={busy} className={U_btnGhost + ' w-full'}>
                  {busy ? <Lucide.Loader2 size={16} className="animate-spin" /> : <Lucide.RefreshCcw size={16} />}
                  Alkalmasság újraépítése
                </button>
              )}
              {rebuild && (
                <p className="text-[11px] font-bold text-slate-400 mt-3 text-center">
                  {rebuild.eligible_pairs} jogosult pár · {rebuild.eligible_courses} kurzus ·
                  {' '}{rebuild.excluded_courses} kurzus és {rebuild.excluded_pairs} pár kizárva
                </p>
              )}
            </div>

            <div className="bg-white rounded-3xl border border-slate-100 p-6">
              <div className="flex items-center gap-2 mb-1">
                <Lucide.EyeOff size={16} className="text-slate-400" />
                <h3 className="font-black text-slate-900 text-sm">Eredmény: külön nézetben</h3>
              </div>
              <p className="text-xs text-slate-400 font-medium leading-relaxed">
                Ez a fül szándékosan semmilyen válasz-tartalmat nem mutat, csak
                darabszámot és arányt. Az eredményt az „Oktatói eredmények” menüpont
                adja (echo_course_results / echo_teacher_results), k-anonimitási
                küszöbökkel. NYITOTT kampány alatt ott sem látszik eredmény, csak
                arány: az echo.results_gate() adminnak a closed / processing / sealed /
                published, oktatónak a sealed / published állapotot engedi — mérve.
              </p>
            </div>
          </div>
        </div>
      )}

      {/* kérdőív-előnézet — CSAK olvasás, szerkesztő a következő körben */}
      <UModal open={formOpen} onClose={() => setFormOpen(false)} max="max-w-3xl"
        icon={<Lucide.FileText size={20} />} title="A kampány kérdőíve"
        subtitle="Csak megtekintés — az élő verzió compiled mezője az adatbázisban immutábilis">
        {preview === null ? (
          <div className="space-y-3"><SkeletonBar w="60%" h={16} /><SkeletonBar /><SkeletonBar w="85%" /><SkeletonBar w="70%" /></div>
        ) : preview.error ? (
          <div className="bg-amber-50 border border-amber-100 rounded-2xl px-4 py-3 text-sm font-bold text-amber-700 flex gap-2">
            <Lucide.AlertTriangle size={16} className="flex-none mt-0.5" /> {preview.error}
          </div>
        ) : !preview.form ? (
          <UEmpty icon={<Lucide.FileQuestion size={28} />} title="A kérdőív üres" />
        ) : (
          <ECHO_FormPreview form={preview.form} lang={lang} />
        )}
      </UModal>
    </div>
  );
}

// A compiled JSONB olvasható kirajzolása. Ugyanabból az adatból, mint a
// kitöltő — így ami itt látszik, azt kapja a hallgató is.
function ECHO_FormPreview({ form, lang }) {
  const meta = form.meta || {};
  return (
    <div className="space-y-6">
      <div className="bg-slate-50 rounded-2xl p-4">
        <h4 className="font-black text-slate-900"><ECHO_Src>{ECHO_txt({ hu: meta.title_hu, en: meta.title_en }, lang)}</ECHO_Src></h4>
        <p className="text-xs text-slate-400 font-bold mt-1">
          <ECHO_Src>{meta.code} · v{meta.version}{meta.legal_hu ? ' · ' + meta.legal_hu : ''}</ECHO_Src>
        </p>
        {meta.forras_megjegyzes && (
          <p className="text-[11px] text-amber-700 font-medium mt-2 leading-relaxed">
            <ECHO_Src>{meta.forras_megjegyzes}</ECHO_Src>
          </p>
        )}
      </div>
      {(form.sections || []).map(sec => (
        <div key={sec.id}>
          <div className="flex items-center gap-2 mb-3">
            <h5 className="text-sm font-black text-slate-800"><ECHO_Src>{ECHO_txt(sec, lang)}</ECHO_Src></h5>
            <UBadge tone={sec.part === 'part1' ? 'blue' : 'slate'}>
              <ECHO_Src>{sec.part}</ECHO_Src>
            </UBadge>
          </div>
          <div className="space-y-2">
            {(sec.questions || []).map(q => (
              <div key={q.id} className="border border-slate-100 rounded-2xl px-4 py-3">
                <div className="flex items-start justify-between gap-3">
                  <p className="text-sm font-bold text-slate-700 leading-snug">
                    <ECHO_Src>{ECHO_txt(q, lang)}</ECHO_Src>
                    {q.required && <span className="text-primary ml-1">*</span>}
                  </p>
                  <span className="text-[10px] font-black text-slate-300 uppercase tracking-wider flex-none">{q.type}</span>
                </div>
                {Array.isArray(q.options) && q.options.length > 0 && (
                  <div className="flex flex-wrap gap-1.5 mt-2">
                    {ECHO_options(q, lang).map(o => (
                      <span key={o.value} className="text-[11px] font-bold text-slate-500 bg-slate-50 rounded-lg px-2 py-1">
                        <ECHO_Src>{o.label}</ECHO_Src>
                      </span>
                    ))}
                  </div>
                )}
                <div className="flex flex-wrap gap-3 mt-2 text-[10px] font-black text-slate-300 uppercase tracking-wider">
                  {q.max > 1 && <span>max {q.max}</span>}
                  {q.repeat && <span>ismétlés: {q.repeat}</span>}
                  {q.randomize && <span>kevert</span>}
                  {q.moderated && <span>moderált</span>}
                  {q.cond && <span>feltételes</span>}
                </div>
              </div>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

/* ============================================================
   ECHO — 2. SZELET
   Kérdőívszerkesztő, oktatói eredménynézet, moderálási sor.
   A szignatúrák és a visszaadott JSON alakja a 16_echo_reports.sql-ből
   valók, és a helyi Postgres 16 replikán MÉRVE lettek (verify adatbázis,
   DEMO-2025-26-2 kampány, 42 válasz).

   AMIT A SZERVER AD, ÉS AMIT EZ A RÉTEG NEM ÍR FELÜL
     • a k-küszöbök (k_numeric=5, k_dist=10, k_text=10, k_slice=5, k_low=5 —
       mérve az echo.setting-ből) kizárólag a szerveren érvényesülnek; itt
       CSAK megjelenítjük, amit visszakaptunk, és kimondjuk, mi hiányzik
     • az eredmény időzítését az echo.results_gate() dönti el: a mérés szerint
       'open' állapotú kampányra ECHO_RESULTS_NOT_READY jön, adminnak
       closed/processing/sealed/published, oktatónak sealed/published enged
     • a compiled szerkezeti helyességét az echo_template_validate() mondja
       meg, nem ez a fájl — a szerkesztő csak MUTATJA a listát
   ============================================================ */

/* ------------------------------------------------------------
   9. Riport-atomok
   ------------------------------------------------------------ */

// Egy eloszlás-cella sávja. A `rejtve` cellának SZÁNDÉKOSAN nincs sávja és
// nincs száma — a komplementer-elnyomás (echo.suppress_cells) pont azért
// rejt el egy másodikat is, hogy kivonással se lehessen visszaszámolni.
function ECHO_CellBar({ cell, n }) {
  const rejtve = cell && cell.rejtve;
  const db = rejtve ? null : Number(cell.db || 0);
  const pct = (!rejtve && n > 0) ? Math.round((db / n) * 100) : 0;
  return (
    <div className="mb-2.5 last:mb-0">
      <div className="flex items-baseline justify-between gap-3 mb-1">
        <span className="text-xs font-bold text-slate-600 truncate">
          <ECHO_Src>{String(cell.cimke != null ? cell.cimke : cell.ertek)}</ECHO_Src>
        </span>
        {rejtve ? (
          <span className="text-[10px] font-black text-slate-300 uppercase tracking-wider flex-none flex items-center gap-1">
            <Lucide.EyeOff size={11} /> elrejtve
          </span>
        ) : (
          <span className="text-[11px] font-black text-slate-400 flex-none">{db} · {pct}%</span>
        )}
      </div>
      {rejtve
        ? <div className="h-2 rounded-full bg-[repeating-linear-gradient(45deg,#e2e8f0,#e2e8f0_4px,#f8fafc_4px,#f8fafc_8px)]" />
        : <ECHO_Meter value={db} max={n} />}
    </div>
  );
}

// ŐSZINTE ÜRESSÉG. Ahol a küszöb elrejt, ott nem üres helyet mutatunk, hanem
// azt, hogy MIÉRT nincs adat, és MENNYI válasz kellene hozzá.
function ECHO_Hidden({ title, message, need, tone = 'slate' }) {
  const box = tone === 'amber'
    ? 'bg-amber-50 border-amber-100 text-amber-700'
    : 'bg-slate-50 border-slate-100 text-slate-500';
  return (
    <div className={'rounded-2xl border px-4 py-3 flex gap-2.5 ' + box}>
      <Lucide.EyeOff size={15} className="flex-none mt-0.5 opacity-60" />
      <div className="min-w-0">
        <p className="text-xs font-black">{title}</p>
        {message && <p className="text-[11px] font-medium mt-1 leading-relaxed opacity-80"><ECHO_Src>{message}</ECHO_Src></p>}
        {need > 0 && (
          <p className="text-[11px] font-black mt-1.5">
            Még {need} válasz kellene ahhoz, hogy ez a rész megjelenjen.
          </p>
        )}
      </div>
    </div>
  );
}

// Egy kérdés eredménye. Minden ág a szerver által visszaadott mezőkre épül:
// rejtve / rejtes_oka / uzenet / atlag / szoras / eloszlas / szovegek / szoveg_*.
function ECHO_ResultQuestion({ q, kuszob, lang }) {
  const k = kuszob || {};
  const n = Number(q.n || 0);
  const szoveges = q.type === 'longtext' || q.type === 'text' || q.type === 'long';

  return (
    <div className="border border-slate-100 rounded-2xl p-4 sm:p-5">
      <div className="flex items-start justify-between gap-3 mb-3">
        <p className="text-sm font-black text-slate-800 leading-snug min-w-0">
          <ECHO_Src>{ECHO_txt(q, lang)}</ECHO_Src>
        </p>
        <div className="flex items-center gap-2 flex-none">
          {q.moderalatlan > 0 && <UBadge tone="amber"><Lucide.Flag size={10} /> {q.moderalatlan} moderálatlan</UBadge>}
          <UBadge tone="slate">{q.type}</UBadge>
        </div>
      </div>

      <p className="text-[11px] font-black text-slate-400 uppercase tracking-wider mb-3">
        {n} válasz
      </p>

      {q.rejtve ? (
        <ECHO_Hidden
          title="Ez a kérdés nem jeleníthető meg"
          message={q.uzenet}
          need={Math.max(0, Number(k.k_numeric || 0) - n)} />
      ) : (
        <>
          {q.atlag != null && (
            <div className="flex items-baseline gap-3 mb-4">
              <span className="text-3xl font-black text-slate-900">{Number(q.atlag).toFixed(2)}</span>
              <span className="text-[11px] font-black text-slate-400 uppercase tracking-wider">
                átlag{q.szoras != null ? ' · szórás ' + Number(q.szoras).toFixed(2) : ''}
              </span>
            </div>
          )}

          {Array.isArray(q.eloszlas) && q.eloszlas.length > 0 && (
            <div className="mb-3">
              {q.eloszlas.map((c, i) => <ECHO_CellBar key={i} cell={c} n={n} />)}
              {q.eloszlas.some(c => c && c.rejtve) && (
                <p className="text-[10px] text-slate-400 font-bold mt-2 leading-relaxed">
                  Az elrejtett cellákban {k.k_slice}-nél kevesebb válasz van. Ha csak egy
                  ilyen lenne, kivonással visszaszámolható volna — ezért rejt el a szerver
                  mindig legalább kettőt (komplementer-elnyomás).
                </p>
              )}
            </div>
          )}

          {!q.eloszlas && !szoveges && q.rejtes_oka === 'kis_elemszam_nincs_eloszlas' && (
            <ECHO_Hidden
              title="Eloszlás nélkül"
              message={q.uzenet}
              need={Math.max(0, Number(k.k_dist || 0) - n)} />
          )}

          {szoveges && (
            q.szoveg_rejtve ? (
              <ECHO_Hidden
                title="A szöveges válaszok nem jeleníthetők meg"
                message={q.szoveg_uzenet}
                need={Math.max(0, Number(k.k_text || 0) - Number(q.szoveg_db || 0))} />
            ) : (
              <div className="space-y-2">
                <p className="text-[10px] font-black text-slate-400 uppercase tracking-wider">
                  {q.szoveg_db} moderált, érvényes szöveg
                </p>
                {(q.szovegek || []).map((s, i) => (
                  <div key={i} className="bg-slate-50 rounded-2xl px-4 py-3 text-sm text-slate-700 font-medium leading-relaxed">
                    <ECHO_Src>{String(s)}</ECHO_Src>
                  </div>
                ))}
              </div>
            )
          )}
        </>
      )}
    </div>
  );
}

// Egy teljes bontás (kurzusszintű vagy egy oktató). A `tajekoztato` a
// 33% alatti óralátogatású blokkot jelöli.
function ECHO_ResultBlock({ r, lang, cim, ikon, tajekoztato }) {
  if (!r) return null;
  const k = r.kuszobok || {};
  const v = r.valaszadas || {};
  const Ikon = Lucide[ikon] || Lucide.BarChart2;

  return (
    <div className={'rounded-3xl border p-5 sm:p-6 ' + (tajekoztato ? 'bg-amber-50/40 border-amber-100' : 'bg-white border-slate-100')}>
      <div className="flex items-start justify-between gap-3 mb-5">
        <div className="flex items-center gap-2.5 min-w-0">
          <Ikon size={18} className={tajekoztato ? 'text-amber-500' : 'text-slate-400'} />
          <h3 className="font-black text-slate-900 truncate">{cim}</h3>
        </div>
        {tajekoztato && <UBadge tone="amber"><Lucide.Info size={10} /> tájékoztató jellegű</UBadge>}
      </div>

      {tajekoztato && (
        <div className="bg-white/70 border border-amber-100 rounded-2xl px-4 py-3 mb-5">
          <p className="text-[11px] text-amber-800 font-medium leading-relaxed">
            <ECHO_Src>{r.megjegyzes || ''}</ECHO_Src>
          </p>
        </div>
      )}

      {!tajekoztato && (
        <div className="grid grid-cols-3 gap-3 mb-5">
          <div className="bg-primary/5 rounded-2xl p-4 col-span-3 sm:col-span-1">
            <p className="text-3xl font-black text-primary">
              {v.arany == null ? '—' : Number(v.arany).toFixed(1) + '%'}
            </p>
            <p className="text-[10px] font-black text-primary/60 uppercase tracking-wider mt-0.5">válaszadási arány</p>
          </div>
          <div className="bg-slate-50 rounded-2xl p-4">
            <p className="text-xl font-black text-slate-900">{v.valaszok}</p>
            <p className="text-[10px] font-black text-slate-400 uppercase tracking-wider mt-0.5">válasz</p>
          </div>
          <div className="bg-slate-50 rounded-2xl p-4">
            <p className="text-xl font-black text-slate-900">{v.jogosult}</p>
            <p className="text-[10px] font-black text-slate-400 uppercase tracking-wider mt-0.5">jogosult</p>
          </div>
        </div>
      )}

      {r.rejtve ? (
        <ECHO_Hidden
          title="Ez a bontás egészben elrejtve"
          message={r.uzenet}
          need={Math.max(0, Number(k.k_numeric || 0) - Number((r.valaszadas || {}).valaszok || 0))}
          tone="amber" />
      ) : (r.kerdesek || []).length === 0 ? (
        <p className="text-sm text-slate-400 font-bold">Ehhez a bontáshoz nincs kérdés.</p>
      ) : (
        <div className="space-y-3">
          {(r.kerdesek || []).map((q, i) => (
            <ECHO_ResultQuestion key={q.id || i} q={q} kuszob={k} lang={lang} />
          ))}
        </div>
      )}
    </div>
  );
}

/* ------------------------------------------------------------
   10. ECHO_TeacherView — oktatói eredménynézet
   ------------------------------------------------------------
   MIT MÉRTÜNK A REPLIKÁN, ÉS MI KÖVETKEZIK BELŐLE:
     • echo_campaigns() és echo_rate() törzse is_admin()-t követel. Oktatói
       kurzuslistát adó RPC a 16_echo_reports.sql-ben NINCS. Ezért a
       kampány- és kurzusválasztó ma CSAK adminnak tölthető fel — ezt a
       felület kimondja, nem találunk ki nem létező végpontot.
     • echo.teacher.profile_id ma minden soron NULL (a Neptun-szinkron tölti
       majd), tehát echo.my_teacher_id() NULL-t ad: oktatóként belépve
       ECHO_FORBIDDEN jön. Ez a biztonságos alapállapot, nem hiba.
     • Nyitott ('open') kampányra a szerver ECHO_RESULTS_NOT_READY-t dob —
       ilyenkor CSAK az arányt mutatjuk, és kimondjuk, miért.
   ------------------------------------------------------------ */

function ECHO_TeacherView({ user }) {
  const [camps, setCamps] = useState(null);
  const [cid, setCid] = useState('');
  const [rate, setRate] = useState(null);
  const [courseId, setCourseId] = useState('');
  const [cres, setCres] = useState(null);   // echo_course_results
  const [tres, setTres] = useState(null);   // echo_teacher_results
  const [gate, setGate] = useState('');     // ECHO_RESULTS_NOT_READY üzenete
  const [listErr, setListErr] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const lang = ECHO_lang();

  useEffect(() => {
    let dead = false;
    ECHO_api.campaigns()
      .then(d => { if (dead) return; const a = Array.isArray(d) ? d : []; setCamps(a); if (a[0]) setCid(a[0].id); })
      .catch(e => { if (!dead) { setCamps([]); setListErr(ECHO_msg(e)); } });
    return () => { dead = true; };
  }, []);

  useEffect(() => {
    if (!cid) { setRate(null); return; }
    let dead = false;
    setCourseId(''); setCres(null); setTres(null); setGate(''); setErr('');
    ECHO_api.rate(cid)
      .then(d => {
        if (dead) return;
        setRate(d);
        const ks = (d && d.kurzusonkent) || [];
        if (ks[0]) setCourseId(ks[0].course_id);
      })
      .catch(e => { if (!dead) { setRate(null); setListErr(ECHO_msg(e)); } });
    return () => { dead = true; };
  }, [cid]);

  useEffect(() => {
    if (!cid || !courseId) { setCres(null); setTres(null); return; }
    let dead = false;
    setBusy(true); setErr(''); setGate('');
    Promise.all([
      ECHO_api.courseResults(cid, courseId).catch(e => ({ __err: e })),
      ECHO_api.teacherResults(cid, courseId, null).catch(e => ({ __err: e })),
    ]).then(([c, t]) => {
      if (dead) return;
      const bad = (c && c.__err) || (t && t.__err);
      if (bad) {
        const raw = (bad.message || '') + '';
        if (raw.indexOf('ECHO_RESULTS_NOT_READY') >= 0) { setGate(ECHO_msg(bad)); }
        else setErr(ECHO_msg(bad));
      }
      setCres(c && c.__err ? null : c);
      setTres(t && t.__err ? null : t);
    }).finally(() => { if (!dead) setBusy(false); });
    return () => { dead = true; };
  }, [cid, courseId]);

  const camp = (camps || []).find(c => c.id === cid) || null;
  const courses = (rate && rate.kurzusonkent) || [];
  const course = courses.find(k => k.course_id === courseId) || null;
  const campState = camp ? (ECHO_CAMPAIGN_STATE[camp.state] || { label: camp.state, tone: 'slate' }) : null;

  return (
    <div className="p-4 sm:p-8 max-w-6xl mx-auto">
      <div className="mb-7">
        <h1 className="text-2xl sm:text-3xl font-black text-slate-900 tracking-tight">Oktatói eredmények</h1>
        <p className="text-sm text-slate-400 font-medium mt-1">
          Kérdésenkénti visszacsatolás · k-anonimitási küszöbökkel · 28/2023. szenátusi határozat
        </p>
      </div>

      {listErr && (
        <div className="mb-6 bg-amber-50 border border-amber-100 rounded-2xl px-4 py-3 flex gap-2.5">
          <Lucide.AlertTriangle size={16} className="flex-none mt-0.5 text-amber-600" />
          <div>
            <p className="text-sm font-bold text-amber-700">{listErr}</p>
            <p className="text-[11px] text-amber-700/80 font-medium mt-1 leading-relaxed">
              A kampány- és kurzuslistát az echo_campaigns() és az echo_rate() adja, és
              MINDKETTŐ törzse public.is_admin()-t követel. Oktatói kurzuslistát adó RPC a
              16_echo_reports.sql-ben nincs — az ECHO saját szerepkör-dimenziójával
              (ECHO_MIR / ECHO_DEKAN / OKTATO) jön majd. Addig ez a nézet adminnal használható.
            </p>
          </div>
        </div>
      )}

      {camps === null ? (
        <div className="space-y-3"><SkeletonBar w="50%" h={16} /><SkeletonBar /><SkeletonBar w="80%" /></div>
      ) : camps.length === 0 && !listErr ? (
        <UEmpty icon={<Lucide.BarChart2 size={28} />} title="Nincs kampány" />
      ) : camps.length > 0 && (
        <div className="bg-white rounded-3xl border border-slate-100 p-5 mb-6">
          <div className="grid gap-4 sm:grid-cols-2">
            <UField label="Kampány">
              <select className={U_input} value={cid} onChange={e => setCid(e.target.value)}>
                {camps.map(c => <option key={c.id} value={c.id}>{c.code} — {c.name}</option>)}
              </select>
            </UField>
            <UField label="Kurzus" hint={courses.length === 0 ? 'Ehhez a kampányhoz nincs véleményezhető kurzus.' : ''}>
              <select className={U_input} value={courseId} onChange={e => setCourseId(e.target.value)} disabled={courses.length === 0}>
                {courses.map(k => <option key={k.course_id} value={k.course_id}>{k.course_code} — {k.course_name}</option>)}
              </select>
            </UField>
          </div>
          {camp && (
            <div className="flex flex-wrap items-center gap-2 mt-4">
              <UBadge tone={campState.tone}>{campState.label}</UBadge>
              <span className="text-[11px] font-bold text-slate-400">
                {ECHO_date(camp.opens_at)} — {ECHO_date(camp.closes_at)}
              </span>
            </div>
          )}
        </div>
      )}

      {/* AZ ARÁNY MINDIG LÁTSZIK — akkor is, amikor az eredmény nem. */}
      {course && (
        <div className="bg-white rounded-3xl border border-slate-100 p-5 sm:p-6 mb-6">
          <div className="flex items-center gap-2 mb-4">
            <Lucide.Gauge size={16} className="text-slate-400" />
            <h3 className="font-black text-slate-900 text-sm">Válaszadási arány</h3>
          </div>
          <div className="flex items-baseline gap-3 mb-2">
            <span className="text-4xl font-black text-slate-900">
              {course.eligible > 0 ? ((course.valaszok / course.eligible) * 100).toFixed(1) : '0.0'}%
            </span>
            <span className="text-xs font-black text-slate-400 uppercase tracking-wider">
              {course.valaszok} / {course.eligible} · elkezdte {course.attempted}
            </span>
          </div>
          <ECHO_Meter value={course.valaszok} max={course.eligible} />
        </div>
      )}

      {/* A NYITOTT KAMPÁNY ALATT NINCS EREDMÉNY — ezt a felület kimondja. */}
      {gate && (
        <div className="bg-slate-900 text-white rounded-3xl p-5 sm:p-6 mb-6">
          <div className="flex items-start gap-3">
            <Lucide.Lock size={18} className="flex-none mt-0.5 text-slate-400" />
            <div>
              <h3 className="font-black">Eredmény most nem látszik — csak az arány</h3>
              <p className="text-sm text-slate-300 font-medium mt-2 leading-relaxed">{gate}</p>
              <p className="text-[11px] text-slate-400 font-medium mt-3 leading-relaxed">
                Ez szándékos: a nyitott kitöltési ablak alatt látható átlag visszahatna a még
                kitöltetlen kérdőívekre. A kaput az echo.results_gate() zárja, a küszöbök
                (echo.setting) fölött. Az arány közben végig látszik, mert abból egyetlen
                kitöltő válasza sem olvasható ki.
              </p>
            </div>
          </div>
        </div>
      )}

      {err && (
        <div className="mb-6 bg-red-50 border border-red-100 rounded-2xl px-4 py-3 text-sm font-bold text-red-600 flex gap-2">
          <Lucide.AlertCircle size={16} className="flex-none mt-0.5" /> {err}
        </div>
      )}

      {busy && <div className="space-y-3 mb-6"><SkeletonBar w="40%" h={16} /><SkeletonBar /><SkeletonBar w="70%" /></div>}

      {!busy && cres && (
        <div className="space-y-6">
          <ECHO_ResultBlock
            r={cres} lang={lang} ikon="BookOpen"
            cim={'Kurzusszintű eredmény — ' + (cres.course_name || '')} />

          {/* A 33% ALATTI ÓRALÁTOGATÁSÚ VÁLASZOK — KÜLÖN BLOKK, jelöléssel.
              3. § (9): ezek nem számítanak a jegyzőkönyvi statisztikába. Saját
              küszöbük van (k_low), és szöveget innen a szerver SOHA nem ad vissza. */}
          {cres.alacsony_oralatogatas && (
            (!cres.alacsony_oralatogatas.rejtve && (cres.alacsony_oralatogatas.kerdesek || []).length > 0) ? (
              <ECHO_ResultBlock
                r={Object.assign({}, cres.alacsony_oralatogatas, { kuszobok: cres.kuszobok })}
                lang={lang} ikon="Info" tajekoztato
                cim={'33% alatti óralátogatás — ' + cres.alacsony_oralatogatas.n + ' válasz'} />
            ) : (
              <div className="bg-amber-50/40 border border-amber-100 rounded-3xl p-5">
                <div className="flex items-center justify-between gap-3 mb-2">
                  <div className="flex items-center gap-2">
                    <Lucide.Info size={16} className="text-amber-500" />
                    <h3 className="font-black text-slate-900 text-sm">
                      33% alatti óralátogatás — {cres.alacsony_oralatogatas.n || 0} válasz
                    </h3>
                  </div>
                  <UBadge tone="amber"><Lucide.EyeOff size={10} /> nem jelenik meg</UBadge>
                </div>
                <p className="text-[11px] text-amber-800 font-black mb-1.5">
                  {Number(cres.alacsony_oralatogatas.n || 0) === 0
                    ? 'Ebben a blokkban nincs válasz.'
                    : 'Még ' + Math.max(0, Number(cres.alacsony_oralatogatas.k_low || 0) - Number(cres.alacsony_oralatogatas.n || 0)) +
                      ' válasz kellene (k_low=' + cres.alacsony_oralatogatas.k_low + '), hogy ez a blokk megjelenjen.'}
                </p>
                <p className="text-[11px] text-amber-800/80 font-medium leading-relaxed">
                  <ECHO_Src>{cres.alacsony_oralatogatas.megjegyzes || ''}</ECHO_Src>
                </p>
              </div>
            )
          )}

          {tres && Array.isArray(tres.oktatok) && tres.oktatok.map((o, i) => (
            <div key={o.teacher_id || i}>
              <ECHO_ResultBlock r={o} lang={lang} ikon="UserCog"
                cim={'Oktatói bontás — ' + (o.teacher_name || o.teacher_id)} />
              {/* Az oktatói bontásban az óralátogatási blokk MINDIG üres — nem
                  hiba, hanem két követelmény ütközése. A szerver saját szavaival. */}
              {o.alacsony_oralatogatas && (
                <div className="mt-2 bg-slate-50 rounded-2xl px-4 py-3 flex gap-2.5">
                  <Lucide.Info size={14} className="text-slate-400 flex-none mt-0.5" />
                  <p className="text-[11px] text-slate-500 font-medium leading-relaxed">
                    <ECHO_Src>{o.alacsony_oralatogatas.megjegyzes || ''}</ECHO_Src>
                  </p>
                </div>
              )}
            </div>
          ))}

          {tres && Array.isArray(tres.oktatok) && tres.oktatok.length === 0 && (
            <div className="bg-white rounded-3xl border border-slate-100 p-5">
              <p className="text-sm font-bold text-slate-500">
                Ehhez a kurzushoz nincs oktatói bontás (az echo.course_teacher táblában nincs sor).
              </p>
            </div>
          )}
        </div>
      )}

      {/* Ami a naplóból következik — kimondva. */}
      {cres && (
        <div className="mt-6 bg-slate-50 rounded-2xl px-4 py-3 flex gap-2.5">
          <Lucide.Info size={15} className="text-slate-400 flex-none mt-0.5" />
          <p className="text-[11px] text-slate-500 font-medium leading-relaxed">
            Minden itt megjelenített bontás EGY sort ír az echo.access_log-ba (6. § (4)) —
            akkor is, ha a bontás elrejtve tér vissza. A napló semmilyen válasz-tartalmat és
            elemszámot nem tárol, különben maga lenne a második csatorna. A megtagadott hívás
            viszont NEM naplózódik: a tranzakció visszagördül, és vele a naplósor is.
          </p>
        </div>
      )}
    </div>
  );
}

/* ------------------------------------------------------------
   11. ECHO_ModerationView — moderálási sor (MIR / admin)
   ------------------------------------------------------------
   A SZÖVEG NEM TÖRLŐDIK. Az 'invalid' annyit tesz, hogy a szöveg kikerül a
   visszacsatolásból (az echo.results_build csak 'valid' sorokat olvas) — az
   eredeti az echo.response.answers-ben marad, hogy a döntés felülvizsgálható
   legyen. A felület ezt kimondja, mert a moderátor különben törlésnek hinné.
   ------------------------------------------------------------ */

function ECHO_ModerationView({ user }) {
  const [camps, setCamps] = useState(null);
  const [cid, setCid] = useState('');
  const [queue, setQueue] = useState(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState('');
  const [done, setDone] = useState(0);
  const [rej, setRej] = useState(null);      // { item } — az elutasító párbeszéd
  const [reason, setReason] = useState('');
  const [note, setNote] = useState('');
  const lang = ECHO_lang();

  useEffect(() => {
    let dead = false;
    ECHO_api.campaigns()
      .then(d => { if (dead) return; const a = Array.isArray(d) ? d : []; setCamps(a); if (a[0]) setCid(a[0].id); })
      .catch(e => { if (!dead) { setCamps([]); setErr(ECHO_msg(e)); } });
    return () => { dead = true; };
  }, []);

  const load = async (id) => {
    if (!id) return;
    setBusy(true); setErr('');
    try { setQueue(await ECHO_api.moderationQueue(id)); }
    catch (e) { setQueue(null); setErr(ECHO_msg(e)); }
    finally { setBusy(false); }
  };
  useEffect(() => { if (cid) load(cid); }, [cid]);

  const decide = async (item, allapot, indok, megjegyzes) => {
    setBusy(true); setErr('');
    try {
      await ECHO_api.moderate(item.response_id, item.question_id, allapot, indok, megjegyzes);
      setQueue(q => q ? Object.assign({}, q, {
        tetelek: (q.tetelek || []).filter(x => !(x.response_id === item.response_id && x.question_id === item.question_id)),
        varakozik: Math.max(0, Number(q.varakozik || 0) - 1),
      }) : q);
      setDone(d => d + 1);
      setToast(allapot === 'valid' ? 'Érvényesnek jelölve.' : 'Érvénytelennek jelölve — a szöveg megmarad.');
      setRej(null); setReason(''); setNote('');
    } catch (e) { setErr(ECHO_msg(e)); }
    finally { setBusy(false); }
  };

  const items = (queue && queue.tetelek) || [];
  const okok = (queue && queue.okok) || [];

  return (
    <div>
      <UToast msg={toast} onDone={() => setToast('')} />

      <div className="flex flex-wrap items-end gap-4 mb-6">
        <div className="min-w-[240px]">
          <UField label="Kampány">
            <select className={U_input} value={cid} onChange={e => setCid(e.target.value)}>
              {(camps || []).map(c => <option key={c.id} value={c.id}>{c.code} — {c.name}</option>)}
            </select>
          </UField>
        </div>
        <button onClick={() => load(cid)} disabled={busy} className={U_btnGhost + ' py-3'}>
          {busy ? <Lucide.Loader2 size={16} className="animate-spin" /> : <Lucide.RefreshCw size={16} />}
          Sor frissítése
        </button>
      </div>

      {err && (
        <div className="mb-6 bg-red-50 border border-red-100 rounded-2xl px-4 py-3 text-sm font-bold text-red-600 flex gap-2">
          <Lucide.AlertCircle size={16} className="flex-none mt-0.5" /> {err}
        </div>
      )}

      {queue && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
          {[
            { k: 'Várakozik', v: queue.varakozik, i: 'Flag' },
            { k: 'Új sor most', v: queue.uj_sorok, i: 'Plus' },
            { k: 'Elintézve most', v: done, i: 'CheckCircle2' },
            { k: 'Indok-katalógus', v: okok.length, i: 'ListChecks' },
          ].map(x => {
            const Ic = Lucide[x.i] || Lucide.Circle;
            return (
              <div key={x.k} className="bg-slate-50 rounded-2xl p-4">
                <Ic size={16} className="text-slate-400 mb-2" />
                <p className="text-xl font-black text-slate-900">{x.v}</p>
                <p className="text-[10px] font-black text-slate-400 uppercase tracking-wider mt-0.5">{x.k}</p>
              </div>
            );
          })}
        </div>
      )}

      <div className="bg-slate-50 rounded-2xl px-4 py-3 flex gap-2.5 mb-6">
        <Lucide.Info size={15} className="text-slate-400 flex-none mt-0.5" />
        <p className="text-[11px] text-slate-500 font-medium leading-relaxed">
          A sor sorrendje md5(response_id ‖ question_id) szerinti, NEM beérkezési sorrend —
          különben ez a képernyő adná vissza azt az érkezési sorrendet, amit az adatmodell
          szándékosan lebontott. Az oktató neve nem látszik: a moderálásnak nem kell tudnia,
          kiről szól a szöveg. Az „érvénytelen” döntés a szöveget NEM törli, csak kiveszi a
          visszacsatolásból, indokkal és moderátor-azonosítóval (echo.moderation).
        </p>
      </div>

      {busy && !queue && <div className="space-y-3"><SkeletonBar /><SkeletonBar w="80%" /><SkeletonBar w="60%" /></div>}

      {queue && items.length === 0 && (
        <UEmpty icon={<Lucide.CheckCircle2 size={28} />} title="A moderálási sor üres"
          subtitle="Ebben a kampányban most nincs moderálásra váró szöveges válasz." />
      )}

      <div className="space-y-3">
        {items.map(it => (
          <div key={it.response_id + '|' + it.question_id} className="bg-white rounded-3xl border border-slate-100 p-5">
            <div className="flex flex-wrap items-center gap-2 mb-3">
              <UBadge tone="slate"><Lucide.BookOpen size={10} /> <ECHO_Src>{it.course_name}</ECHO_Src></UBadge>
              <UBadge tone={it.scope === 'teacher' ? 'violet' : 'blue'}>{it.scope === 'teacher' ? 'oktatói' : 'kurzusszintű'}</UBadge>
            </div>
            <p className="text-xs font-black text-slate-400 uppercase tracking-wider mb-2">
              <ECHO_Src>{ECHO_txt({ hu: it.kerdes_hu, en: it.kerdes_en }, lang) || it.question_id}</ECHO_Src>
            </p>
            <div className="bg-slate-50 rounded-2xl px-4 py-3 text-sm text-slate-800 font-medium leading-relaxed mb-4 whitespace-pre-wrap">
              <ECHO_Src>{it.szoveg || ''}</ECHO_Src>
            </div>
            <div className="flex flex-wrap gap-2">
              <button onClick={() => decide(it, 'valid', null, null)} disabled={busy}
                className={U_btnGhost + ' py-2.5 px-4 text-sm text-emerald-700 bg-emerald-50 hover:bg-emerald-100'}>
                <Lucide.CheckCircle2 size={15} /> Érvényes
              </button>
              <button onClick={() => { setRej(it); setReason(okok[0] ? okok[0].code : ''); setNote(''); }} disabled={busy}
                className={U_btnGhost + ' py-2.5 px-4 text-sm text-red-600 bg-red-50 hover:bg-red-100'}>
                <Lucide.XCircle size={15} /> Érvénytelen
              </button>
            </div>
          </div>
        ))}
      </div>

      <UModal open={!!rej} onClose={() => setRej(null)} max="max-w-lg"
        icon={<Lucide.XCircle size={20} />} title="Érvénytelenné nyilvánítás"
        subtitle="Indok nélkül a szerver elutasítja (ECHO_REASON_REQUIRED)">
        <div className="space-y-4">
          <div className="bg-amber-50 border border-amber-100 rounded-2xl px-4 py-3">
            <p className="text-[11px] text-amber-800 font-medium leading-relaxed">
              A szöveg NEM törlődik. Kikerül a visszacsatolásból, de az eredeti megmarad az
              echo.response.answers-ben — enélkül utólag nem lehetne eldönteni, jogos volt-e a
              döntés. A döntés naplózódik: ki, mikor, milyen indokkal.
            </p>
          </div>
          <UField label="Indok (3. § (10))">
            <select className={U_input} value={reason} onChange={e => setReason(e.target.value)}>
              {okok.map(o => (
                <option key={o.code} value={o.code}>
                  {ECHO_txt({ hu: o.name_hu, en: o.name_en }, lang)}{o.paragraph ? ' — ' + o.paragraph : ''}
                </option>
              ))}
            </select>
          </UField>
          <UField label="Megjegyzés (nem kötelező)" hint="Audit-nyom: a döntés indoklása emberi szavakkal.">
            <textarea className={U_input + ' min-h-[90px] resize-y'} value={note} onChange={e => setNote(e.target.value)} />
          </UField>
          <div className="flex gap-2 justify-end">
            <button onClick={() => setRej(null)} className={U_btnGhost}>Mégsem</button>
            <button disabled={!reason || busy} onClick={() => decide(rej, 'invalid', reason, note)}
              className={U_btnPrimary}>
              {busy ? <Lucide.Loader2 size={16} className="animate-spin" /> : <Lucide.XCircle size={16} />}
              Érvénytelen
            </button>
          </div>
        </div>
      </UModal>
    </div>
  );
}

/* ------------------------------------------------------------
   12. ECHO_Editor — kérdőívszerkesztő
   ------------------------------------------------------------
   A prototípus legmélyebb modulja. A MUNKAMEGOSZTÁS (16_echo_reports.sql
   7. szakasz): a szerver vállalja a klónozást ÚJ kérdés-ID-kkal, a mentés
   draft-hoz kötését, a SZÁMÍTOTT élesítés-előtti ellenőrzéseket és az
   állapotgépet (triggerrel is védve). A kliens csinálja a szerkesztő
   felületet, az élő előnézetet és az opció-átrendezést.

   Az ellenőrző lista SOHA nem itt keletkezik: az echo_template_validate()
   adja, és mentés után frissül. Ha a kliens számolná, a felület és a
   szerver külön véleményen lehetne arról, mi élesíthető.
   ------------------------------------------------------------ */

const ECHO_TPL_STATE = {
  draft:    { label: 'Piszkozat',    tone: 'slate',   icon: 'Pencil' },
  review:   { label: 'Véleményezés', tone: 'blue',    icon: 'MessageSquare' },
  approved: { label: 'Jóváhagyva',   tone: 'violet',  icon: 'CheckCircle2' },
  live:     { label: 'Élesítve',     tone: 'green',   icon: 'Rocket' },
  closed:   { label: 'Archív',       tone: 'amber',   icon: 'Lock' },
};

/* A megengedett átmenetek — betű szerint az echo.template_version_freeze()
   triggerből (16_echo_reports.sql 7.3). Ha itt több lenne, a gomb csak
   szerverhibát tudna előállítani. */
const ECHO_TPL_NEXT = {
  draft:    [{ to: 'review',   label: 'Véleményezésre',   icon: 'ArrowRight' },
             { to: 'closed',   label: 'Archiválás',       icon: 'Ban' }],
  review:   [{ to: 'approved', label: 'Jóváhagyás',       icon: 'CheckCircle2' },
             { to: 'draft',    label: 'Vissza javításra', icon: 'Undo2' },
             { to: 'closed',   label: 'Archiválás',       icon: 'Ban' }],
  approved: [{ to: 'live',     label: 'Élesítés',         icon: 'Rocket', clean: true },
             { to: 'review',   label: 'Újranyitás',       icon: 'Undo2' },
             { to: 'closed',   label: 'Archiválás',       icon: 'Ban' }],
  live:     [{ to: 'closed',   label: 'Lezárás',          icon: 'Lock' }],
  closed:   [],
};

// A szerkeszthető kérdéstípusok. CSAK az az öt, amit az ECHO_Question ki is
// tud rajzolni — egy hatodik felvétele itt a kitöltőben "Ismeretlen
// kérdéstípus" dobozt eredményezne, azaz a szerkesztő olyat ígérne, amit a
// hallgató nem lát.
const ECHO_QTYPES = [
  { v: 'single',   label: 'Egyválasztós',  icon: 'Circle',   hint: 'Egy opció választható.' },
  { v: 'multi',    label: 'Többválasztós', icon: 'ListChecks', hint: 'Több opció; a max korlátoz.' },
  { v: 'scale',    label: 'Skála',         icon: 'SlidersHorizontal', hint: 'Számskála min/max felirattal.' },
  { v: 'longtext', label: 'Szöveges',      icon: 'Type',     hint: 'Szabad szöveg — moderálásra kerül.' },
  { v: 'skip',     label: 'Kihagyás-kapu', icon: 'CornerDownRight', hint: 'Nem kérdés, hanem kapu: „nem tudom értékelni”.' },
];

const ECHO_REPEATS = [
  { v: '',        label: 'Nincs (egyszer)' },
  { v: 'teacher', label: 'Oktatónként' },
  { v: 'goal',    label: 'Célonként' },
];

// A cond-ban használható KÖRNYEZETI kulcsok. Az echo.setting
// 'cond_context_keys' sorából mérve: has_goals, attendance_band, lang.
const ECHO_COND_CTX = ['has_goals', 'attendance_band', 'lang'];

// ELŐNÉZETI TOKENEK. A kérdőívszövegek helykitöltőket tartalmazhatnak, amiket
// a kitöltéskor a konkrét oktató/kurzus neve tölt ki. Az előnézetben minta
// értéket teszünk a helyükre, hogy a szerkesztő azt lássa, amit a hallgató.
const ECHO_TOKENS = {
  '[Oktató neve]':  'Dr. Példa Anna',
  '[oktató neve]':  'Dr. Példa Anna',
  '[Teacher name]': 'Dr. Anna Példa',
  '[Kurzus neve]':  'Bevezetés a szoftverfejlesztésbe',
  '[Course name]':  'Introduction to Software Engineering',
  '[Cél]':          'a félév eleji célod',
  '[Goal]':         'your goal for the term',
};
function ECHO_tok(s) {
  if (s == null) return s;
  let out = String(s);
  Object.keys(ECHO_TOKENS).forEach(k => { out = out.split(k).join(ECHO_TOKENS[k]); });
  return out;
}

// Egy szerkesztett kérdés ELŐNÉZETI alakja: a help {hu,en} párja feloldva
// (az ECHO_Question sztringet vár, objektumot nem tudna kirajzolni), és
// minden szövegen tokenbehelyettesítés.
function ECHO_previewQuestion(q, lang) {
  const help = (q.help && typeof q.help === 'object') ? ECHO_txt(q.help, lang) : (q.help || '');
  const opts = Array.isArray(q.options) ? q.options.map(o => (
    (o && typeof o === 'object')
      ? Object.assign({}, o, { hu: ECHO_tok(o.hu), en: ECHO_tok(o.en) })
      : ECHO_tok(o)
  )) : q.options;
  return Object.assign({}, q, {
    hu: ECHO_tok(q.hu), en: ECHO_tok(q.en), help: ECHO_tok(help), options: opts,
  });
}

const ECHO_clone = (o) => JSON.parse(JSON.stringify(o));
function ECHO_uid(n) {
  let s = '';
  const abc = 'abcdefghijklmnopqrstuvwxyz0123456789';
  for (let i = 0; i < (n || 8); i++) s += abc[Math.floor(Math.random() * abc.length)];
  return s;
}
// Az opciók kétféle alakja ("szöveg" vagy {value,hu,en}) — a szerkesztő
// mindig objektummá normalizál, a `value` VÁLTOZATLAN megtartásával.
// Ez fontos: a beküldött érték a value, tehát ha az elmozdulna, a korábbi
// verziók válaszai más kulcsra mutatnának, mint az újak.
function ECHO_normOpts(list) {
  return (Array.isArray(list) ? list : []).map((o, i) => (
    (o && typeof o === 'object')
      ? { value: o.value != null ? o.value : (o.hu || String(i)), hu: o.hu || '', en: o.en || '' }
      : { value: String(o), hu: String(o), en: '' }
  ));
}
const ECHO_asArr = (a) => (Array.isArray(a) ? a : (a == null || a === '' ? [] : [a]));

// Az érték-mező parse-olása a megjelenítési feltételhez.
function ECHO_parseVal(s) {
  const t = String(s == null ? '' : s).trim();
  if (t === '') return null;
  if (t === 'true') return true;
  if (t === 'false') return false;
  if (t === 'null') return null;
  if (/^-?\d+(\.\d+)?$/.test(t)) return Number(t);
  return t;
}

/* ---- opció-szerkesztő ---- */
function ECHO_OptionEditor({ q, ro, onChange }) {
  const opts = ECHO_normOpts(q.options);
  const set = (arr) => onChange(arr);
  const move = (i, d) => {
    const j = i + d; if (j < 0 || j >= opts.length) return;
    const a = opts.slice(); const t = a[i]; a[i] = a[j]; a[j] = t; set(a);
  };
  return (
    <div>
      <div className="flex items-center justify-between mb-2">
        <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest">Válaszopciók ({opts.length})</span>
        {!ro && (
          <button onClick={() => set(opts.concat([{ value: 'opt_' + ECHO_uid(5), hu: '', en: '' }]))}
            className="text-[11px] font-black text-primary hover:underline flex items-center gap-1">
            <Lucide.Plus size={12} /> Opció
          </button>
        )}
      </div>
      {opts.length === 0 && (
        <p className="text-[11px] text-slate-400 font-bold mb-2">Nincs opció — választós kérdésnél ez ellenőrzési hiba.</p>
      )}
      <div className="space-y-2">
        {opts.map((o, i) => (
          <div key={i} className="border border-slate-100 rounded-2xl p-3">
            <div className="flex items-center gap-1.5 mb-2">
              <span className="text-[10px] font-black text-slate-300 w-5">{i + 1}.</span>
              <input className={U_input + ' py-1.5 text-xs font-mono'} value={o.value} disabled={ro}
                onChange={e => { const a = opts.slice(); a[i] = Object.assign({}, o, { value: e.target.value }); set(a); }}
                placeholder="tárolt érték (value)" />
              {!ro && (
                <>
                  <button onClick={() => move(i, -1)} className="w-7 h-7 rounded-lg hover:bg-slate-100 text-slate-400 flex items-center justify-center flex-none"><Lucide.ChevronUp size={14} /></button>
                  <button onClick={() => move(i, 1)} className="w-7 h-7 rounded-lg hover:bg-slate-100 text-slate-400 flex items-center justify-center flex-none"><Lucide.ChevronDown size={14} /></button>
                  <button onClick={() => set(opts.filter((_, k) => k !== i))} className="w-7 h-7 rounded-lg hover:bg-red-50 text-red-400 flex items-center justify-center flex-none"><Lucide.Trash2 size={14} /></button>
                </>
              )}
            </div>
            <div className="grid grid-cols-2 gap-2">
              <input className={U_input + ' py-1.5 text-xs'} value={o.hu} disabled={ro} placeholder="magyar"
                onChange={e => { const a = opts.slice(); a[i] = Object.assign({}, o, { hu: e.target.value }); set(a); }} />
              <input className={U_input + ' py-1.5 text-xs ' + (o.en ? '' : 'border-amber-200 bg-amber-50/50')} value={o.en} disabled={ro} placeholder="angol (kötelező az élesítéshez)"
                onChange={e => { const a = opts.slice(); a[i] = Object.assign({}, o, { en: e.target.value }); set(a); }} />
            </div>
          </div>
        ))}
      </div>
      <p className="text-[10px] text-slate-400 font-medium mt-2 leading-relaxed">
        A tárolt érték (value) a válaszba kerülő kulcs. Ha megváltoztatod, a korábbi
        válaszok más kulcsra mutatnak, mint az újak — ezért csak új kérdésnél írd át.
      </p>
    </div>
  );
}

/* ---- egy kapcsoló ---- */
function ECHO_Toggle({ label, hint, on, ro, onChange }) {
  return (
    <button type="button" disabled={ro} onClick={() => onChange(!on)}
      className={'w-full text-left rounded-2xl border-2 px-3.5 py-3 transition-all ' +
        (on ? 'border-primary bg-primary/5' : 'border-slate-100 bg-white hover:border-slate-200') +
        (ro ? ' opacity-60 pointer-events-none' : '')}>
      <div className="flex items-center gap-2">
        <span className={'w-4 h-4 rounded-md border-2 flex items-center justify-center flex-none ' + (on ? 'border-primary bg-primary' : 'border-slate-200')}>
          {on && <Lucide.Check size={11} className="text-white" />}
        </span>
        <span className={'text-xs font-black ' + (on ? 'text-primary' : 'text-slate-600')}>{label}</span>
      </div>
      {hint && <p className="text-[10px] text-slate-400 font-medium mt-1 leading-relaxed pl-6">{hint}</p>}
    </button>
  );
}

/* ---- kérdés-szerkesztő panel ---- */
function ECHO_QuestionPanel({ q, allIds, ro, onPatch, lang }) {
  if (!q) {
    return (
      <div className="bg-white rounded-3xl border border-slate-100 p-8 text-center">
        <Lucide.MousePointerClick size={22} className="text-slate-300 mx-auto mb-2" />
        <p className="text-sm font-bold text-slate-400">Válassz egy kérdést a szerkezetből.</p>
      </div>
    );
  }
  const help = (q.help && typeof q.help === 'object') ? q.help : { hu: q.help || '', en: '' };
  const sc = q.scale || {};
  const scMin = Number(sc.min != null ? sc.min : 1);
  const scMax = Number(sc.max != null ? sc.max : 7);
  /* A cond kétféle alakja, amit az echo.template_validate() is elfogad:
       {"has_goals": true}            — kulcs→érték leképezés (a seed ezt használja)
       {"qid": "teacher_skip", ...}   — nevesített hivatkozás
     A szerkesztő MINDIG a leképezés-alakot írja vissza, de a nevesítettet is
     be tudja olvasni — különben egy kézzel írt feltételt csendben eldobna. */
  const condIsNamed = !!(q.cond && typeof q.cond === 'object' && q.cond.qid);
  const condKey = condIsNamed ? String(q.cond.qid)
    : (q.cond && typeof q.cond === 'object' ? (Object.keys(q.cond)[0] || '') : '');
  const condVal = condIsNamed ? (q.cond.val !== undefined ? q.cond.val : true)
    : (condKey ? q.cond[condKey] : '');
  const aud = ECHO_asArr(q.audience);

  const setScale = (patch) => onPatch({ scale: Object.assign({ min: scMin, max: scMax }, sc, patch) });

  return (
    <div className="bg-white rounded-3xl border border-slate-100 p-5 space-y-5">
      <div className="flex items-center justify-between gap-3">
        <span className="text-[10px] font-black text-slate-300 uppercase tracking-widest font-mono truncate">{q.id}</span>
        {ro && <UBadge tone="slate"><Lucide.Lock size={10} /> olvasó mód</UBadge>}
      </div>

      {/* típus */}
      <div>
        <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Kérdéstípus</span>
        <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
          {ECHO_QTYPES.map(t => {
            const Ic = Lucide[t.icon] || Lucide.Circle;
            const on = q.type === t.v;
            return (
              <button key={t.v} type="button" disabled={ro} onClick={() => onPatch({ type: t.v })}
                title={t.hint}
                className={'rounded-2xl border-2 px-3 py-2.5 text-left transition-all ' +
                  (on ? 'border-primary bg-primary/5 text-primary' : 'border-slate-100 bg-white text-slate-600 hover:border-slate-200') +
                  (ro ? ' opacity-60 pointer-events-none' : '')}>
                <Ic size={14} className="mb-1" />
                <p className="text-[11px] font-black">{t.label}</p>
              </button>
            );
          })}
        </div>
      </div>

      {/* kétnyelvű szöveg */}
      <div className="grid gap-3 sm:grid-cols-2">
        <UField label="Kérdés (magyar)">
          <textarea className={U_input + ' min-h-[70px] resize-y'} value={q.hu || ''} disabled={ro}
            onChange={e => onPatch({ hu: e.target.value })} />
        </UField>
        <UField label="Kérdés (angol)" hint={q.en ? '' : 'Hiánya élesítés-blokkoló hiba.'}>
          <textarea className={U_input + ' min-h-[70px] resize-y ' + (q.en ? '' : 'border-amber-200 bg-amber-50/50')}
            value={q.en || ''} disabled={ro} onChange={e => onPatch({ en: e.target.value })} />
        </UField>
        <UField label="Súgó (magyar)">
          <input className={U_input} value={help.hu || ''} disabled={ro}
            onChange={e => onPatch({ help: { hu: e.target.value, en: help.en || '' } })} />
        </UField>
        <UField label="Súgó (angol)">
          <input className={U_input} value={help.en || ''} disabled={ro}
            onChange={e => onPatch({ help: { hu: help.hu || '', en: e.target.value } })} />
        </UField>
      </div>

      {/* opciók */}
      {['single', 'multi', 'skip'].indexOf(q.type) >= 0 && (
        <ECHO_OptionEditor q={q} ro={ro} onChange={arr => onPatch({ options: arr })} />
      )}

      {/* skála */}
      {q.type === 'scale' && (
        <div>
          <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Skálabeállítás</span>
          <div className="grid grid-cols-2 gap-3 mb-3">
            <UField label="Min érték">
              <input type="number" className={U_input} value={scMin} disabled={ro}
                onChange={e => setScale({ min: Number(e.target.value), points: Math.max(0, scMax - Number(e.target.value) + 1) })} />
            </UField>
            <UField label="Max érték">
              <input type="number" className={U_input} value={scMax} disabled={ro}
                onChange={e => setScale({ max: Number(e.target.value), points: Math.max(0, Number(e.target.value) - scMin + 1) })} />
            </UField>
          </div>
          <div className="grid grid-cols-2 gap-3 mb-3">
            <UField label="Alsó felirat (hu)">
              <input className={U_input} value={sc.min_hu || ''} disabled={ro} onChange={e => setScale({ min_hu: e.target.value })} />
            </UField>
            <UField label="Felső felirat (hu)">
              <input className={U_input} value={sc.max_hu || ''} disabled={ro} onChange={e => setScale({ max_hu: e.target.value })} />
            </UField>
            <UField label="Alsó felirat (en)">
              <input className={U_input} value={sc.min_en || ''} disabled={ro} onChange={e => setScale({ min_en: e.target.value })} />
            </UField>
            <UField label="Felső felirat (en)">
              <input className={U_input} value={sc.max_en || ''} disabled={ro} onChange={e => setScale({ max_en: e.target.value })} />
            </UField>
          </div>
          <p className="text-[11px] font-black text-slate-500">
            Fokozatszám: {Math.max(0, scMax - scMin + 1)}
            <span className="text-slate-400 font-medium"> — a kitöltő ennyi gombot lát. A min/max különbségéből számítjuk; a
            kitöltő komponens (ECHO_QScale) is ebből dolgozik, a `points` mező csak feljegyzés.</span>
          </p>
          {scMin >= scMax && (
            <p className="text-[11px] font-black text-red-500 mt-1.5">A min nem kisebb a maxnál — ez élesítés-blokkoló hiba.</p>
          )}
        </div>
      )}

      {/* kapcsolók */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
        <ECHO_Toggle label="Kötelező" on={!!q.required} ro={ro} onChange={v => onPatch({ required: v })}
          hint="Feltétel mögötti kötelező kérdés élesítés-blokkoló hiba." />
        <ECHO_Toggle label="Moderált" on={!!q.moderated} ro={ro} onChange={v => onPatch({ moderated: v })}
          hint="A szöveg csak moderálás után kerül vissza az oktatóhoz." />
        <ECHO_Toggle label="Kevert sorrend" on={!!q.randomize} ro={ro} onChange={v => onPatch({ randomize: v })}
          hint="Az opciók sorrendje kitöltésenként más — a sorrendhatás ellen." />
        <ECHO_Toggle label="„Egyéb” engedése" on={!!q.allowOther} ro={ro} onChange={v => onPatch({ allowOther: v })}
          hint="Az egyéb szövegét az eredmény SOHA nem adja vissza, csak a darabszámot." />
      </div>

      {/* max + ismétlődés */}
      <div className="grid grid-cols-2 gap-3">
        <UField label="Max-limit"
          hint={q.type === 'multi' ? 'Többválasztósnál a max ≥ opciószám nem korlátoz — hiba.' : 'Szövegesnél a karakterkorlát.'}>
          <input type="number" className={U_input} value={q.max == null ? '' : q.max} disabled={ro}
            onChange={e => onPatch({ max: e.target.value === '' ? null : Number(e.target.value) })} />
        </UField>
        <UField label="Ismétlődés">
          <select className={U_input} value={q.repeat || ''} disabled={ro} onChange={e => onPatch({ repeat: e.target.value || null })}>
            {ECHO_REPEATS.map(r => <option key={r.v} value={r.v}>{r.label}</option>)}
          </select>
        </UField>
      </div>

      {/* megjelenítési feltétel */}
      <div>
        <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Megjelenítési feltétel</span>
        <div className="grid grid-cols-2 gap-3">
          <select className={U_input} value={condKey} disabled={ro}
            onChange={e => onPatch({ cond: e.target.value ? { [e.target.value]: condVal === '' ? true : condVal } : null })}>
            <option value="">— nincs feltétel —</option>
            <optgroup label="Környezeti kulcs">
              {ECHO_COND_CTX.map(k => <option key={k} value={k}>{k}</option>)}
            </optgroup>
            <optgroup label="Kérdés">
              {allIds.filter(id => id !== q.id).map(id => <option key={id} value={id}>{id}</option>)}
            </optgroup>
          </select>
          <input className={U_input + ' font-mono text-xs'} disabled={ro || !condKey}
            value={condVal === null ? 'null' : String(condVal)}
            onChange={e => onPatch({ cond: { [condKey]: ECHO_parseVal(e.target.value) } })}
            placeholder="true / null / érték" />
        </div>
        <p className="text-[10px] text-slate-400 font-medium mt-1.5 leading-relaxed">
          A `null` érték azt jelenti: „akkor jelenjen meg, ha az a kérdés ÜRESEN maradt”.
          Nem létező kérdésre hivatkozó feltétel élesítés-blokkoló hiba.
        </p>
      </div>

      {/* célközönség */}
      <div>
        <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Célközönség-címkék</span>
        <div className="flex flex-wrap gap-1.5 mb-2">
          {aud.length === 0 && <span className="text-[11px] font-bold text-slate-400">Nincs szűkítés — mindenki látja.</span>}
          {aud.map((a, i) => (
            <span key={i} className="inline-flex items-center gap-1 bg-slate-100 text-slate-600 rounded-full px-2.5 py-1 text-[10px] font-black uppercase tracking-wider">
              {a}
              {!ro && <button onClick={() => onPatch({ audience: aud.filter((_, k) => k !== i) })} className="text-slate-400 hover:text-red-500"><Lucide.X size={11} /></button>}
            </span>
          ))}
        </div>
        {!ro && (
          <div className="flex flex-wrap gap-1.5">
            {['student', 'teacher', 'phd', 'part_time', 'international'].filter(t => aud.indexOf(t) < 0).map(t => (
              <button key={t} onClick={() => onPatch({ audience: aud.concat([t]) })}
                className="text-[10px] font-black uppercase tracking-wider text-primary bg-primary/5 hover:bg-primary/10 rounded-full px-2.5 py-1 flex items-center gap-1">
                <Lucide.Plus size={10} /> {t}
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

/* ---- a szerkesztő ---- */
function ECHO_Editor({ user }) {
  const [list, setList] = useState(null);     // echo_templates()
  const [vid, setVid] = useState('');
  const [doc, setDoc] = useState(null);       // echo_template_get()
  const [draft, setDraft] = useState(null);   // a szerkesztett compiled
  const [checks, setChecks] = useState([]);   // echo_template_validate()
  const [dirty, setDirty] = useState(false);
  const [si, setSi] = useState(0);
  const [qi, setQi] = useState(null);
  const [pv, setPv] = useState(null);         // előnézeti válaszérték
  const [pvMode, setPvMode] = useState('q');  // q | sec | all
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [toast, setToast] = useState('');
  const [newOpen, setNewOpen] = useState(false);
  const [newName, setNewName] = useState('');
  const [newFrom, setNewFrom] = useState('');
  const lang = ECHO_lang();

  const loadList = async () => {
    setErr('');
    try { const d = await ECHO_api.templates(); setList(Array.isArray(d) ? d : []); }
    catch (e) { setList([]); setErr(ECHO_msg(e)); }
  };
  useEffect(() => { loadList(); }, []);

  const openVersion = async (id) => {
    if (!id) return;
    setBusy(true); setErr('');
    try {
      const d = await ECHO_api.templateGet(id);
      setVid(id); setDoc(d); setDraft(ECHO_clone(d.compiled || { sections: [] }));
      setChecks(Array.isArray(d.ellenorzes) ? d.ellenorzes : []);
      setDirty(false); setSi(0); setQi(null); setPv(null);
    } catch (e) { setErr(ECHO_msg(e)); }
    finally { setBusy(false); }
  };

  const save = async () => {
    if (!vid || !draft) return;
    setBusy(true); setErr('');
    try {
      const r = await ECHO_api.templateSave(vid, draft);
      setChecks(Array.isArray(r.ellenorzes) ? r.ellenorzes : []);
      setDirty(false); setToast('Mentve. Az ellenőrző lista frissült.');
    } catch (e) { setErr(ECHO_msg(e)); }
    finally { setBusy(false); }
  };

  const transition = async (to) => {
    if (!vid) return;
    if (dirty && !window.confirm('Mentetlen módosításaid vannak — az állapotváltás a MENTETT tartalommal dolgozik. Folytatod?')) return;
    setBusy(true); setErr('');
    try {
      const r = await ECHO_api.templateTransition(vid, to);
      setToast('Állapot: ' + r.from + ' → ' + r.to + (r.lezart_korabbi_live ? ' (' + r.lezart_korabbi_live + ' korábbi élő verzió lezárva)' : ''));
      await loadList(); await openVersion(vid);
    } catch (e) { setErr(ECHO_msg(e)); }
    finally { setBusy(false); }
  };

  const create = async () => {
    setBusy(true); setErr('');
    try {
      const r = await ECHO_api.templateCreate(newName, newFrom || null);
      setNewOpen(false); setNewName(''); setNewFrom('');
      await loadList(); await openVersion(r.id);
      setToast('Új verzió (v' + r.version + ') létrehozva piszkozatként.');
    } catch (e) { setErr(ECHO_msg(e)); }
    finally { setBusy(false); }
  };

  /* ---- a compiled mutálása ---- */
  const mut = (fn) => {
    if (!draft) return;
    const d = ECHO_clone(draft);
    if (!Array.isArray(d.sections)) d.sections = [];
    fn(d);
    setDraft(d); setDirty(true);
  };

  const sections = (draft && Array.isArray(draft.sections)) ? draft.sections : [];
  const sec = sections[si] || null;
  const q = (sec && Array.isArray(sec.questions)) ? (sec.questions[qi] || null) : null;
  const ro = !(doc && doc.szerkesztheto);
  const allIds = [];
  sections.forEach(s => (s.questions || []).forEach(x => allIds.push(x.id)));

  const addSection = () => mut(d => {
    d.sections.push({ id: 's_' + ECHO_uid(8), hu: 'Új szakasz', en: '', part: 'part2', audience: [], questions: [] });
    setSi(d.sections.length - 1); setQi(null);
  });
  const delSection = (i) => {
    if (!window.confirm('Törlöd a szakaszt a benne lévő kérdésekkel együtt?')) return;
    mut(d => { d.sections.splice(i, 1); setSi(Math.max(0, i - 1)); setQi(null); });
  };
  const moveSection = (i, dd) => mut(d => {
    const j = i + dd; if (j < 0 || j >= d.sections.length) return;
    const t = d.sections[i]; d.sections[i] = d.sections[j]; d.sections[j] = t; setSi(j);
  });
  const patchSection = (i, patch) => mut(d => { d.sections[i] = Object.assign({}, d.sections[i], patch); });

  const addQuestion = (i, type) => mut(d => {
    const s = d.sections[i]; if (!s.questions) s.questions = [];
    s.questions.push({
      id: 'q_' + ECHO_uid(8), hu: 'Új kérdés', en: '', help: { hu: '', en: '' },
      type: type || 'single', options: type === 'scale' || type === 'longtext' ? [] : [],
      required: false, moderated: type === 'longtext', randomize: false, allowOther: false,
      max: null, repeat: null, cond: null,
      scale: type === 'scale' ? { min: 1, max: 7, points: 7, min_hu: '', max_hu: '', min_en: '', max_en: '' } : null,
      audience: [],
    });
    setQi(s.questions.length - 1); setPv(null);
  });
  const delQuestion = (i, k) => mut(d => { d.sections[i].questions.splice(k, 1); setQi(null); });
  const moveQuestion = (i, k, dd) => mut(d => {
    const qs = d.sections[i].questions; const j = k + dd;
    if (j < 0 || j >= qs.length) return;
    const t = qs[k]; qs[k] = qs[j]; qs[j] = t; setQi(j);
  });
  const moveQToSection = (i, k, target) => mut(d => {
    if (target === i) return;
    const item = d.sections[i].questions.splice(k, 1)[0];
    if (!d.sections[target].questions) d.sections[target].questions = [];
    d.sections[target].questions.push(item);
    setSi(target); setQi(d.sections[target].questions.length - 1);
  });
  const patchQuestion = (patch) => mut(d => {
    const qs = d.sections[si].questions;
    qs[qi] = Object.assign({}, qs[qi], patch);
    setPv(null);
  });

  // Az ellenőrzési találat → ugrás a helyére.
  const jumpTo = (c) => {
    const i = sections.findIndex(s => s.id === c.szakasz);
    if (i < 0) return;
    setSi(i);
    const k = (sections[i].questions || []).findIndex(x => x.id === c.kerdes);
    setQi(k >= 0 ? k : null);
  };

  const cleanCheck = checks.length === 0 && !dirty;

  /* ---- kirajzolás ---- */
  if (list === null) {
    return <div className="space-y-3"><SkeletonBar w="40%" h={16} /><SkeletonBar /><SkeletonBar w="70%" /></div>;
  }

  return (
    <div>
      <UToast msg={toast} onDone={() => setToast('')} />

      {err && (
        <div className="mb-5 bg-red-50 border border-red-100 rounded-2xl px-4 py-3 text-sm font-bold text-red-600 flex gap-2">
          <Lucide.AlertCircle size={16} className="flex-none mt-0.5" /> {err}
        </div>
      )}

      {/* sablon- és verziólista */}
      <div className="bg-white rounded-3xl border border-slate-100 p-5 mb-6">
        <div className="flex items-center justify-between gap-3 mb-4">
          <div className="flex items-center gap-2">
            <Lucide.Layers size={16} className="text-slate-400" />
            <h3 className="font-black text-slate-900 text-sm">Sablonok és verziók</h3>
          </div>
          <button onClick={() => { setNewOpen(true); setNewFrom(''); setNewName(''); }} className={U_btnGhost + ' py-2.5 px-4 text-sm'}>
            <Lucide.FilePlus2 size={15} /> Új verzió
          </button>
        </div>

        {list.length === 0 ? (
          <p className="text-sm text-slate-400 font-bold">Nincs sablon. Indíts egyet üresen.</p>
        ) : (
          <div className="space-y-4">
            {list.map(t => (
              <div key={t.id}>
                <p className="text-xs font-black text-slate-700 mb-2">
                  <ECHO_Src>{t.name_hu}</ECHO_Src>
                  <span className="text-slate-300 font-mono ml-2">{t.code}</span>
                </p>
                <div className="overflow-x-auto">
                  <table className="w-full min-w-[680px]">
                    <thead>
                      <tr className="text-left">
                        {['Verzió', 'Állapot', 'Szakasz / kérdés', 'Kampány', 'Ellenőrzés', ''].map((h, i) => (
                          <th key={i} className="px-3 py-2 text-[10px] font-black text-slate-400 uppercase tracking-widest">{h}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {(t.verziok || []).map(v => {
                        const st = ECHO_TPL_STATE[v.state] || { label: v.state, tone: 'slate' };
                        const on = vid === v.id;
                        return (
                          <tr key={v.id} onClick={() => openVersion(v.id)}
                            className={'border-t border-slate-50 cursor-pointer transition-colors ' + (on ? 'bg-primary/5' : 'hover:bg-slate-50')}>
                            <td className="px-3 py-2.5 text-sm font-black text-slate-900">v{v.version}</td>
                            <td className="px-3 py-2.5"><UBadge tone={st.tone}>{st.label}</UBadge></td>
                            <td className="px-3 py-2.5 text-xs font-bold text-slate-500">{v.szakaszok} / {v.kerdesek}</td>
                            <td className="px-3 py-2.5 text-xs font-bold text-slate-500">{v.kampanyok}</td>
                            <td className="px-3 py-2.5">
                              {v.ellenorzes_hibak > 0
                                ? <UBadge tone="amber"><Lucide.AlertTriangle size={10} /> {v.ellenorzes_hibak}</UBadge>
                                : <UBadge tone="green"><Lucide.CheckCircle2 size={10} /> tiszta</UBadge>}
                            </td>
                            <td className="px-3 py-2.5 text-right">
                              <Lucide.ChevronRight size={15} className="text-slate-300 inline" />
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {!doc ? (
        <UEmpty icon={<Lucide.FileText size={28} />} title="Válassz egy verziót"
          subtitle="A szerkesztés csak piszkozat (draft) állapotban engedett; minden más állapotnál olvasó mód." />
      ) : (
        <>
          {/* verzió-fejléc + állapotgomb-sor */}
          <div className="bg-white rounded-3xl border border-slate-100 p-5 mb-6">
            <div className="flex flex-wrap items-start justify-between gap-4 mb-4">
              <div className="min-w-0">
                <h3 className="font-black text-slate-900">
                  <ECHO_Src>{doc.name_hu}</ECHO_Src> <span className="text-slate-300">· v{doc.version}</span>
                </h3>
                <div className="flex flex-wrap items-center gap-2 mt-1.5">
                  <UBadge tone={(ECHO_TPL_STATE[doc.state] || {}).tone || 'slate'}>
                    {(ECHO_TPL_STATE[doc.state] || {}).label || doc.state}
                  </UBadge>
                  {doc.kampanyok > 0 && <UBadge tone="blue">{doc.kampanyok} kampány használja</UBadge>}
                  {dirty && <UBadge tone="amber"><Lucide.Pencil size={10} /> mentetlen</UBadge>}
                  {doc.approved_by && (
                    <span className="text-[11px] font-bold text-slate-400">
                      jóváhagyta: <ECHO_Src>{doc.approved_by}</ECHO_Src> · {ECHO_dateTime(doc.approved_at)}
                    </span>
                  )}
                </div>
              </div>
              <div className="flex flex-wrap gap-2">
                {!ro && (
                  <button onClick={save} disabled={busy || !dirty} className={U_btnPrimary + ' py-2.5 px-4 text-sm'}>
                    {busy ? <Lucide.Loader2 size={15} className="animate-spin" /> : <Lucide.Save size={15} />} Mentés
                  </button>
                )}
                {(ECHO_TPL_NEXT[doc.state] || []).map(a => {
                  const Ic = Lucide[a.icon] || Lucide.ArrowRight;
                  const blocked = a.clean && !cleanCheck;
                  return (
                    <button key={a.to} onClick={() => transition(a.to)} disabled={busy || blocked}
                      title={blocked ? 'Élesítés csak üres ellenőrző listával, mentett állapotban.' : ''}
                      className={(a.to === 'live' ? U_btnPrimary : U_btnGhost) + ' py-2.5 px-4 text-sm'}>
                      <Ic size={15} /> {a.label}
                    </button>
                  );
                })}
              </div>
            </div>

            {ro && (
              <div className="bg-slate-50 rounded-2xl px-4 py-3 flex gap-2.5">
                <Lucide.Lock size={15} className="text-slate-400 flex-none mt-0.5" />
                <p className="text-[11px] text-slate-500 font-medium leading-relaxed">
                  Ez a verzió <strong>{(ECHO_TPL_STATE[doc.state] || {}).label || doc.state}</strong> állapotban van, ezért
                  OLVASÓ MÓD. A compiled mezőt nem csak az RPC védi: az echo.template_version_freeze()
                  trigger a jóváhagyott / élesített / archív verzió tartalmát a Dashboard SQL Editorból
                  írt UPDATE ellen is megvédi. Ha módosítanál, készíts új verziót.
                </p>
              </div>
            )}
          </div>

          <div className="grid gap-6 xl:grid-cols-12">
            {/* SZERKEZET */}
            <div className="xl:col-span-3 space-y-3">
              <div className="flex items-center justify-between">
                <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest">Szerkezet</span>
                {!ro && (
                  <button onClick={addSection} className="text-[11px] font-black text-primary hover:underline flex items-center gap-1">
                    <Lucide.Plus size={12} /> Szakasz
                  </button>
                )}
              </div>
              {sections.length === 0 && (
                <p className="text-[11px] font-bold text-slate-400">Nincs szakasz. Az üres kérdőív nem „majdnem kész”, hanem hibás.</p>
              )}
              {sections.map((s, i) => (
                <div key={s.id || i} className={'rounded-2xl border ' + (si === i ? 'border-primary/30 bg-primary/5' : 'border-slate-100 bg-white')}>
                  <div className="p-3">
                    <div className="flex items-start gap-1.5">
                      <button onClick={() => { setSi(i); setQi(null); }} className="min-w-0 text-left flex-1">
                        <p className="text-xs font-black text-slate-800 truncate"><ECHO_Src>{s.hu || '(névtelen)'}</ECHO_Src></p>
                        <p className="text-[10px] font-bold text-slate-400 truncate">{s.part || 'part2'} · {(s.questions || []).length} kérdés</p>
                      </button>
                      {!ro && (
                        <div className="flex flex-none">
                          <button onClick={() => moveSection(i, -1)} className="w-6 h-6 rounded-md hover:bg-slate-100 text-slate-400 flex items-center justify-center"><Lucide.ChevronUp size={13} /></button>
                          <button onClick={() => moveSection(i, 1)} className="w-6 h-6 rounded-md hover:bg-slate-100 text-slate-400 flex items-center justify-center"><Lucide.ChevronDown size={13} /></button>
                          <button onClick={() => delSection(i)} className="w-6 h-6 rounded-md hover:bg-red-50 text-red-400 flex items-center justify-center"><Lucide.Trash2 size={13} /></button>
                        </div>
                      )}
                    </div>

                    {si === i && (
                      <div className="mt-3 space-y-2">
                        <input className={U_input + ' py-1.5 text-xs'} value={s.hu || ''} disabled={ro}
                          onChange={e => patchSection(i, { hu: e.target.value })} placeholder="szakaszcím (magyar)" />
                        <input className={U_input + ' py-1.5 text-xs ' + (s.en ? '' : 'border-amber-200 bg-amber-50/50')} value={s.en || ''} disabled={ro}
                          onChange={e => patchSection(i, { en: e.target.value })} placeholder="szakaszcím (angol) — kötelező" />
                        <select className={U_input + ' py-1.5 text-xs'} value={s.part || 'part2'} disabled={ro}
                          onChange={e => patchSection(i, { part: e.target.value })}>
                          <option value="part1">part1 — félév eleji célmeghatározó</option>
                          <option value="part2">part2 — félév végi értékelés</option>
                        </select>
                      </div>
                    )}
                  </div>

                  {si === i && (
                    <div className="border-t border-slate-100 p-2 space-y-1">
                      {(s.questions || []).map((x, k) => (
                        <div key={x.id || k} className={'flex items-center gap-1 rounded-xl px-2 py-1.5 ' + (qi === k ? 'bg-white ring-1 ring-primary/30' : 'hover:bg-white/60')}>
                          <button onClick={() => { setQi(k); setPv(null); }} className="min-w-0 text-left flex-1">
                            <p className="text-[11px] font-bold text-slate-700 truncate"><ECHO_Src>{x.hu || x.id}</ECHO_Src></p>
                            <p className="text-[9px] font-black text-slate-300 uppercase tracking-wider">{x.type}{x.required ? ' · kötelező' : ''}{x.cond ? ' · feltételes' : ''}</p>
                          </button>
                          {!ro && (
                            <div className="flex flex-none">
                              <button onClick={() => moveQuestion(i, k, -1)} className="w-5 h-5 rounded hover:bg-slate-100 text-slate-400 flex items-center justify-center"><Lucide.ChevronUp size={12} /></button>
                              <button onClick={() => moveQuestion(i, k, 1)} className="w-5 h-5 rounded hover:bg-slate-100 text-slate-400 flex items-center justify-center"><Lucide.ChevronDown size={12} /></button>
                              <button onClick={() => delQuestion(i, k)} className="w-5 h-5 rounded hover:bg-red-50 text-red-400 flex items-center justify-center"><Lucide.Trash2 size={12} /></button>
                            </div>
                          )}
                        </div>
                      ))}
                      {!ro && (
                        <div className="flex flex-wrap gap-1 pt-1">
                          {ECHO_QTYPES.map(t => (
                            <button key={t.v} onClick={() => addQuestion(i, t.v)} title={t.hint}
                              className="text-[9px] font-black uppercase tracking-wider text-primary bg-primary/5 hover:bg-primary/10 rounded-lg px-2 py-1 flex items-center gap-1">
                              <Lucide.Plus size={9} /> {t.label}
                            </button>
                          ))}
                        </div>
                      )}
                    </div>
                  )}
                </div>
              ))}
            </div>

            {/* KÉRDÉS-SZERKESZTŐ */}
            <div className="xl:col-span-5">
              {q && !ro && sections.length > 1 && (
                <div className="mb-3">
                  <UField label="Áthelyezés másik szakaszba">
                    <select className={U_input + ' py-2 text-xs'} value={si}
                      onChange={e => moveQToSection(si, qi, Number(e.target.value))}>
                      {sections.map((s, i) => <option key={s.id || i} value={i}>{s.hu || '(névtelen)'}</option>)}
                    </select>
                  </UField>
                </div>
              )}
              <ECHO_QuestionPanel q={q} allIds={allIds} ro={ro} onPatch={patchQuestion} lang={lang} />
            </div>

            {/* ELŐNÉZET + ELLENŐRZÉS */}
            <div className="xl:col-span-4 space-y-6">
              <div className="bg-white rounded-3xl border border-slate-100 p-5">
                <div className="flex items-center justify-between gap-2 mb-4">
                  <div className="flex items-center gap-2">
                    <Lucide.Eye size={16} className="text-slate-400" />
                    <h3 className="font-black text-slate-900 text-sm">Élő előnézet</h3>
                  </div>
                  <div className="flex gap-1">
                    {[{ v: 'q', l: 'Kérdés' }, { v: 'sec', l: 'Szakasz' }, { v: 'all', l: 'Teljes' }].map(m => (
                      <button key={m.v} onClick={() => setPvMode(m.v)}
                        className={'text-[10px] font-black uppercase tracking-wider rounded-lg px-2 py-1 ' +
                          (pvMode === m.v ? 'bg-primary/10 text-primary' : 'text-slate-400 hover:bg-slate-100')}>
                        {m.l}
                      </button>
                    ))}
                  </div>
                </div>

                <p className="text-[10px] text-slate-400 font-medium mb-4 leading-relaxed">
                  Ugyanazokkal a komponensekkel rajzoljuk, amikkel a hallgató kitölt
                  (ECHO_Question). A helykitöltők ki vannak töltve mintaértékkel —
                  pl. [Oktató neve] → {ECHO_TOKENS['[Oktató neve]']}.
                </p>

                <div className="rounded-2xl border border-slate-100 p-3">
                  {pvMode === 'q' && (q
                    ? <ECHO_Question q={ECHO_previewQuestion(q, lang)} index={(qi || 0) + 1}
                        value={pv} onChange={setPv} lang={lang} seed="preview" />
                    : <p className="text-xs font-bold text-slate-400 py-6 text-center">Nincs kiválasztott kérdés.</p>)}

                  {pvMode === 'sec' && (sec
                    ? <div>
                        <h4 className="text-sm font-black text-slate-800 mb-1"><ECHO_Src>{ECHO_txt(sec, lang)}</ECHO_Src></h4>
                        {(sec.questions || []).map((x, k) => (
                          <ECHO_Question key={x.id || k} q={ECHO_previewQuestion(x, lang)} index={k + 1}
                            value={undefined} onChange={() => {}} lang={lang} seed="preview" />
                        ))}
                      </div>
                    : <p className="text-xs font-bold text-slate-400 py-6 text-center">Nincs kiválasztott szakasz.</p>)}

                  {pvMode === 'all' && draft && <ECHO_FormPreview form={draft} lang={lang} />}
                </div>
              </div>

              {/* ÉLESÍTÉS ELŐTTI ELLENŐRZÉS */}
              <div className="bg-white rounded-3xl border border-slate-100 p-5">
                <div className="flex items-center justify-between gap-2 mb-3">
                  <div className="flex items-center gap-2">
                    <Lucide.ShieldCheck size={16} className={checks.length ? 'text-amber-500' : 'text-emerald-500'} />
                    <h3 className="font-black text-slate-900 text-sm">Élesítés előtti ellenőrzés</h3>
                  </div>
                  {!ro && (
                    <button onClick={async () => {
                      setBusy(true);
                      try { setChecks(await ECHO_api.templateValidate(vid) || []); }
                      catch (e) { setErr(ECHO_msg(e)); } finally { setBusy(false); }
                    }} className="text-[11px] font-black text-primary hover:underline">Újrafuttatás</button>
                  )}
                </div>

                {dirty && (
                  <div className="bg-amber-50 border border-amber-100 rounded-2xl px-4 py-2.5 mb-3">
                    <p className="text-[11px] font-bold text-amber-700">
                      A lista a MENTETT tartalomra vonatkozik. Mentés után frissül.
                    </p>
                  </div>
                )}

                {checks.length === 0 ? (
                  <div className="bg-emerald-50 border border-emerald-100 rounded-2xl px-4 py-3">
                    <p className="text-xs font-black text-emerald-700">Nincs hiba — a verzió élesíthető.</p>
                    <p className="text-[10px] text-emerald-700/70 font-medium mt-1 leading-relaxed">
                      Az élesítést a szerver is újraellenőrzi (echo_template_transition): ha közben
                      bármi elromlott, ECHO_VALIDATION_FAILED-del elutasítja.
                    </p>
                  </div>
                ) : (
                  <div className="space-y-2 max-h-[420px] overflow-y-auto pr-1">
                    <p className="text-[11px] font-black text-amber-600 mb-1">{checks.length} találat — élesítés blokkolva</p>
                    {checks.map((c, i) => (
                      <button key={i} onClick={() => jumpTo(c)}
                        className="w-full text-left border border-slate-100 rounded-2xl px-3.5 py-2.5 hover:border-primary/30 hover:bg-primary/5 transition-colors">
                        <div className="flex items-center gap-2 mb-1">
                          <UBadge tone={c.sulyossag === 'hiba' ? 'red' : 'amber'}>{c.sulyossag}</UBadge>
                          <span className="text-[10px] font-black text-slate-400 uppercase tracking-wider font-mono truncate">{c.kod}</span>
                        </div>
                        <p className="text-[11px] font-medium text-slate-600 leading-relaxed"><ECHO_Src>{c.uzenet}</ECHO_Src></p>
                        {(c.szakasz || c.kerdes) && (
                          <p className="text-[10px] font-black text-slate-300 mt-1 font-mono">
                            {c.szakasz || '—'}{c.kerdes ? ' / ' + c.kerdes : ''}
                          </p>
                        )}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            </div>
          </div>
        </>
      )}

      {/* ÚJ VERZIÓ — üresen vagy mély klónnal */}
      <UModal open={newOpen} onClose={() => setNewOpen(false)} max="max-w-lg"
        icon={<Lucide.FilePlus2 size={20} />} title="Új kérdőív-verzió"
        subtitle="Meglévőből mély klónnal, ÚJ kérdés-ID-kkal — vagy üresen">
        <div className="space-y-4">
          <UField label="Név / cím">
            <input className={U_input} value={newName} onChange={e => setNewName(e.target.value)}
              placeholder="pl. OMHV alapkérdőív 2026/27/1" />
          </UField>
          <UField label="Kiindulás">
            <select className={U_input} value={newFrom} onChange={e => setNewFrom(e.target.value)}>
              <option value="">— üresen (új sablon, 1. verzió) —</option>
              {(list || []).map(t => (
                <optgroup key={t.id} label={t.name_hu}>
                  {(t.verziok || []).map(v => (
                    <option key={v.id} value={v.id}>
                      v{v.version} · {(ECHO_TPL_STATE[v.state] || {}).label || v.state} · {v.kerdesek} kérdés
                    </option>
                  ))}
                </optgroup>
              ))}
            </select>
          </UField>
          <div className="bg-slate-50 rounded-2xl px-4 py-3">
            <p className="text-[11px] text-slate-500 font-medium leading-relaxed">
              A klónozás MINDEN kérdés-ID-t kicserél, és a megjelenítési feltételek
              hivatkozásait együtt írja át. Ha az ID-k megmaradnának, két különböző
              megfogalmazású kérdés válaszai ugyanabba a kulcsba folynának, és egy
              hosszmetszeti riport összeadná őket. Az új verzió mindig piszkozat.
            </p>
          </div>
          <div className="flex gap-2 justify-end">
            <button onClick={() => setNewOpen(false)} className={U_btnGhost}>Mégsem</button>
            <button onClick={create} disabled={busy || !newName.trim()} className={U_btnPrimary}>
              {busy ? <Lucide.Loader2 size={16} className="animate-spin" /> : <Lucide.Plus size={16} />} Létrehozás
            </button>
          </div>
        </div>
      </UModal>
    </div>
  );
}

/* ------------------------------------------------------------
   13. ECHO_AdminView — MIR / admin, FÜLEKKEL
   ------------------------------------------------------------
   A kampánykezelés, a kérdőívszerkesztő és a moderálás egy menüpont alatt
   marad: mindhárom ugyanahhoz a jogosultsághoz (public.is_admin()) kötött,
   és a bal oldali menü 17 meglévő eleméhez nem akarunk továbbiakat tenni.
   ------------------------------------------------------------ */

const ECHO_ADMIN_TABS = [
  { id: 'campaigns',  label: 'Kampányok',        icon: 'Megaphone' },
  { id: 'editor',     label: 'Kérdőívszerkesztő', icon: 'FileText' },
  { id: 'moderation', label: 'Moderálás',        icon: 'Flag' },
];

function ECHO_AdminView({ user }) {
  const [tab, setTab] = useState('campaigns');

  if (tab === 'campaigns') {
    return (
      <div>
        <div className="px-4 sm:px-8 pt-4 sm:pt-8 max-w-6xl mx-auto">
          <ECHO_AdminTabs tab={tab} setTab={setTab} />
        </div>
        <ECHO_CampaignsPanel user={user} />
      </div>
    );
  }

  return (
    <div className="p-4 sm:p-8 max-w-6xl mx-auto">
      <ECHO_AdminTabs tab={tab} setTab={setTab} />
      <div className="mb-7">
        <h1 className="text-2xl sm:text-3xl font-black text-slate-900 tracking-tight">
          {tab === 'editor' ? 'Kérdőívszerkesztő' : 'Moderálási sor'}
        </h1>
        <p className="text-sm text-slate-400 font-medium mt-1">
          {tab === 'editor'
            ? 'Sablonok, verziók, állapotgép · a szerkesztés csak piszkozatban engedett'
            : 'Szöveges válaszok érvényessége · 3. § (10) · a szöveg nem törlődik'}
        </p>
      </div>
      {tab === 'editor'     && <ECHO_Editor user={user} />}
      {tab === 'moderation' && <ECHO_ModerationView user={user} />}
    </div>
  );
}

function ECHO_AdminTabs({ tab, setTab }) {
  return (
    <div className="flex flex-wrap gap-2 mb-6">
      {ECHO_ADMIN_TABS.map(t => {
        const Ic = Lucide[t.icon] || Lucide.Circle;
        const on = tab === t.id;
        return (
          <button key={t.id} onClick={() => setTab(t.id)}
            className={'inline-flex items-center gap-2 rounded-2xl px-4 py-2.5 text-sm font-black transition-all ' +
              (on ? 'bg-primary text-white shadow-lg shadow-primary/10' : 'bg-white border border-slate-100 text-slate-500 hover:text-slate-800 hover:border-slate-200')}>
            <Ic size={15} /> {t.label}
          </button>
        );
      })}
    </div>
  );
}
