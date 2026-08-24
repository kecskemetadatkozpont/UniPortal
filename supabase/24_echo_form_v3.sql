-- ============================================================
-- UniPortal Pro — ECHO: a célmeghatározó két BEVEZETŐ kérdése (3. verzió)
-- ------------------------------------------------------------
-- Neumann János Egyetem — OMHV, 28/2023. (VIII.31.) szenátusi határozat
--
-- FUTTATÁSI SORREND: a 23_echo_form_rules.sql UTÁN, a 21_echo_harden_submit.sql
-- ELŐTT (a 21 mindig az utolsó):
--     ... 20_echo_report_fix.sql
--     23_echo_form_rules.sql
--     24_echo_form_v3.sql        <- ez a fájl
--     21_echo_harden_submit.sql  <- MINDIG az utolsó
--
-- FIGYELEM — A 20_echo_report_fix.sql NEM FUTHAT EZUTÁN. Ez a fájl az
-- echo.results_build() függvényt írja felül (a 20-as változata + egy új
-- feltétel), tehát a 20 újrafuttatása CSENDBEN visszavenné a part1-kizárást,
-- és a célmeghatározás két bevezető kérdése n=0-val megjelenne az oktatói
-- eredménynézetben. Ha a 20-at bármiért újra kell futtatni, futtasd utána
-- ezt a fájlt is (idempotens: a kérdőív-verziót nem hozza létre másodszor,
-- csak a függvényt állítja helyre).
--
-- MIÉRT VAN EZ A FÁJL
-- -------------------
-- A célmeghatározás (part1) a prototípus szerint KÉT BEVEZETŐ KÉRDÉSSEL indul:
--   • beszélt-e a hallgató az oktatóval a kurzus céljairól,
--   • világosak-e a teljesítési követelmények.
-- MÉRVE a helyi 'fresh' replikán: a MA ÉLŐ 2. verzió compiled JSONB-jében
-- 0 db part1 szakasz van (mind a 6 szakasz part2), tehát ez a két kérdés
-- sehol nem szerepel. A célmeghatározó felület emiatt csak a két
-- listaszerkesztőt (célok / elvárások) mutatja.
--
-- MIÉRT A COMPILED JSONB-BE ÉS NEM A FELÜLETRE
-- --------------------------------------------
-- A features/echo.jsx fejlécének szabálya: "A KÉRDÉSEK NEM ITT VANNAK... Ha ide
-- bármikor bekerülne egy kérdésszöveg, az azt jelentené, hogy a felület és a
-- szenátus által jóváhagyott kérdőív szétcsúszhat." A két bevezető kérdés
-- VALÓDI kérdőívkérdés, tehát a kérdőív-verzióban a helye — akkor is, ha a
-- válasza nem a névtelen halmazba megy.
--
-- ================== FORRÁSHŰSÉG — OLVASD EL ==================
-- A megadott forrásfájl (forras/ECHO Prototipus.dc.html) EBBEN A MUNKAMÁSOLATBAN
-- NEM TALÁLHATÓ — kerestem, nincs meg. Az alábbi két kérdés szövege ezért NEM
-- szó szerinti átvétel, hanem a feladatleírás alapján, a 18b_echo_form_seed.sql
-- meglévő kérdéseinek stílusában megfogalmazott REKONSTRUKCIÓ. Ez ugyanaz a
-- helyzet, ami az 1. verziónál állt fenn ("Az 1. verzió szövegei
-- rekonstrukciók voltak"), és ugyanúgy MIR-jóváhagyást igényel.
-- A meta.forras_megjegyzes mező ezt a verzióban is kimondja, hogy a
-- szerkesztőben is látszódjon.
--
-- MIT VÁLTOZTAT
--   1. echo.results_build(): a part1 szakaszok kérdései kimaradnak a
--      riportból. (A 20_echo_report_fix.sql változatának betű szerinti
--      másolata EGYETLEN új feltétellel — lásd a megjegyzést a ciklusnál.)
--   2. Létrejön a 3. kérdőív-verzió: a mai ÉLŐ verzió másolata
--        + egy part1 szakasz a két bevezető kérdéssel,
--        + az "Egyéb" opciókon "other": true jelző.
--      A verzió 'draft' állapotban marad — az élesítés TUDATOS, kézi döntés.
--
-- MIT NEM TESZ MEG — SZÁNDÉKOSAN
--   • NEM élesíti a 3. verziót és NEM köti át a futó kampányt. A 18c fájl
--     tapasztalata szerint ez lepecsételi a futó kampányt és lezárja az előző
--     kérdőív-verziót — mindkettő VISSZAFORDÍTHATATLAN. Az élesítés lépéseit
--     a fájl végén, kikommentelve adom meg.
--   • NEM töröl és NEM módosít egyetlen meglévő verziót sem: az élő verzió
--     compiled mezőjét az echo.template_version_guard() amúgy sem engedné.
--
-- MIÉRT KELL AZ "other": true JELZŐ
--   Az "Egyéb melletti kötelező szöveg" szabálya (23_echo_form_rules.sql) ma
--   szövegegyezéssel ismeri fel az "Egyéb"/"Other" opciót, mert a 2. verzióban
--   nincs jelző. A szövegegyezés törékeny: egy jövőbeli "Egyéb (kérjük írd le)"
--   címke már nem illeszkedne. A 3. verzió ezért expliciten megjelöli az
--   opciót; a szövegalapú felismerés visszaesési ágként megmarad.
--
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

set search_path = echo, public, extensions, pg_temp;

-- ------------------------------------------------------------
-- 1. echo.results_build — a part1 kérdések kizárása a riportból
-- ------------------------------------------------------------
create or replace function echo.results_build(
  p_campaign uuid, p_course uuid, p_teacher uuid, p_scope text, p_admin boolean)
returns jsonb
language plpgsql volatile
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_c        echo.campaign%rowtype;
  v_compiled jsonb;
  v_fo   uuid[];
  v_lo   uuid[];
  v_kn   int := echo.k('k_numeric');
  v_kt   int := echo.k('k_text');
  v_klow int := echo.k('k_low');
  q      jsonb;
  v_qid  text;
  v_vals jsonb;
  v_one  jsonb;
  v_txt  jsonb;
  v_txtn int;
  v_fo_q   jsonb := '[]'::jsonb;
  v_lo_q   jsonb := '[]'::jsonb;
  v_jog  int;
  v_pend int := 0;
  v_out  jsonb;
begin
  select * into v_c from echo.campaign where id = p_campaign;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;
  select compiled into v_compiled from echo.template_version where id = v_c.template_version_id;
  if v_compiled is null then raise exception 'ECHO_TEMPLATE_MISSING'; end if;

  -- A válaszhalmaz kettéosztása. A NULL attendance_band a FŐ halmazba megy:
  -- a hiányzó adatból nem következtetünk alacsony óralátogatásra.
  if p_scope = 'teacher' then
    select coalesce(array_agg(r.id), '{}') into v_fo
      from echo.response r
     where r.campaign_id = p_campaign and r.course_id = p_course
       and r.scope = 'teacher' and r.teacher_id = p_teacher;
    v_lo := '{}';
  else
    select coalesce(array_agg(r.id) filter (where not echo.attendance_low(r.attendance_band)), '{}'),
           coalesce(array_agg(r.id) filter (where     echo.attendance_low(r.attendance_band)), '{}')
      into v_fo, v_lo
      from echo.response r
     where r.campaign_id = p_campaign and r.course_id = p_course and r.scope = 'course';
  end if;

  select count(*) into v_jog
    from echo.participation p
   where p.campaign_id = p_campaign and p.course_id = p_course and p.eligible;

  -- GLOBÁLIS KÜSZÖB: ha a teljes halmaz k_numeric alatt van, a riport
  -- egészben elrejtődik. Kérdésenkénti kiértékelésre el sem jutunk — így
  -- még a "mely kérdésre hányan válaszoltak" mintázat sem szivárog ki.
  if coalesce(array_length(v_fo,1),0) < v_kn then
    return jsonb_build_object(
      'campaign_id', p_campaign, 'course_id', p_course, 'teacher_id', p_teacher,
      'scope', p_scope,
      'kuszobok', jsonb_build_object('k_numeric', v_kn, 'k_dist', echo.k('k_dist'),
                                     'k_text', v_kt, 'k_slice', echo.k('k_slice'),
                                     'k_low', v_klow,
                                     'attendance_min_pct', echo.k('attendance_min_pct')),
      'valaszadas', jsonb_build_object('jogosult', v_jog,
                                       'valaszok', coalesce(array_length(v_fo,1),0),
                                       'arany', null),
      'rejtve', true, 'rejtes_oka', 'keves_valasz',
      'uzenet', 'Keves valasz (' || coalesce(array_length(v_fo,1),0) || ' < k_numeric=' || v_kn ||
                '): ez a bontas nem jelenitheto meg.',
      'kerdesek', '[]'::jsonb,
      -- AZ 'n' ITT NULL. Mert ha a blokk rejtve van, akkor a k_low alatti
      -- ELEMSZAM MAGA a kozles: merve, 10 fos fo halmaz mellett 1 alacsony
      -- oralatogatasu valasznal a regi valtozat {"n":1,"rejtve":true}-t adott,
      -- vagyis a megtekinto pontosan megtudta, hogy egy ember vallott be 33%
      -- alatti oralatogatast. Egy k_low alatti, erzekeny attributumra vonatkozo
      -- PONTOS darabszam — pont az, amit a k_low tiltana.
      'alacsony_oralatogatas', jsonb_build_object('n', null, 'k_low', v_klow,
                                                  'rejtve', true, 'kerdesek', '[]'::jsonb));
  end if;

  -- Kérdésenkénti kiértékelés
  --
  -- AZ 'attendance' KÉRDÉS KIMARAD — ÉS EZ NEM ADATVESZTÉS, HANEM HIBAJAVÍTÁS.
  -- MÉRT PROBLÉMA (13 valódi beküldésen): az óralátogatás a jegyzőkönyvben
  -- MINDIG n=0-val és "Keves valasz (0 < k_numeric=5)" üzenettel jelent meg,
  -- pedig mind a 13 válaszadó kitöltötte. Az ok szerkezeti: az echo_submit()
  -- az óralátogatást a payload GYÖKERÉBŐL a KÜLÖN echo.response.attendance_band
  -- OSZLOPBA teszi (15_echo_core.sql, 5. lépés), az answers-be soha nem kerül
  -- bele — ez a ciklus viszont az r.answers -> v_qid kifejezéssel keresi.
  -- Vagyis a keresés helye és a tárolás helye sosem esett egybe.
  -- Az adat nem veszett el: az óralátogatás a 3. § (9) szerinti FŐ/ALACSONY
  -- kettéosztást vezérli (lásd fent, echo.attendance_low), és az
  -- 'alacsony_oralatogatas' blokk közli, amennyit a k_low enged. A hamis
  -- "kevés válasz" sor viszont félrevezette a jegyzőkönyv olvasóját, ezért
  -- itt kihagyjuk a kérdéslistából.
  -- MIÉRT ID SZERINT ÉS NEM TÍPUS SZERINT: a 18b seed a prototípus
  -- type:'attendance' mezőjét 'single'-re fordítja (a renderelő öt típust
  -- ismer), tehát típusra szűrni nem lehet — mérve.
  -- HA VALAHA KELL AZ ELOSZLÁS: azt az attendance_band OSZLOPBÓL kell
  -- aggregálni (echo.suppress_cells-lel, k_dist küszöbbel), nem az answers-ből.
  for q in
    select qq.value
      from jsonb_array_elements(echo.jarr(v_compiled->'sections')) s
      cross join jsonb_array_elements(echo.jarr(s.value->'questions')) qq
     where case when p_scope = 'teacher'
                then coalesce(qq.value->>'repeat','') = 'teacher'
                else coalesce(qq.value->>'repeat','') <> 'teacher' end
       and coalesce(qq.value->>'id','') <> 'attendance'
       -- AZ EGYETLEN VALTOZAS a 20_echo_report_fix.sql valtozatahoz kepest:
       -- a part1 (celmeghatarozas) szakaszok kerdesei KIMARADNAK. Ezek a
       -- felev ELEJEN, azonositva, az echo.student_goal sorba valaszolodnak,
       -- es SOHA nem kerulnek at a nevtelen echo.response-ba. Enelkul minden
       -- part1 kerdes n=0-val jelenne meg az oktatoi eredmenynezetben:
       -- olyan kerdesek, amikre ebben a halmazban nem is lehet valasz.
       and coalesce(s.value->>'part', 'part2') <> 'part1'
  loop
    v_qid := q->>'id';

    -- FŐ halmaz
    select coalesce(jsonb_agg(r.answers -> v_qid), '[]'::jsonb) into v_vals
      from echo.response r
     where r.id = any(v_fo)
       and jsonb_exists(r.answers, v_qid)
       and jsonb_typeof(r.answers -> v_qid) <> 'null';
    v_one := echo.agg_one(q, v_vals);

    -- Szöveges kérdés: CSAK moderált ÉS érvényes válaszokból, k_text fölött.
    if coalesce(q->>'type','') in ('longtext','text','long') then
      select count(*), coalesce(jsonb_agg(r.answers ->> v_qid order by md5(r.id::text)), '[]'::jsonb)
        into v_txtn, v_txt
        from echo.response r
        join echo.moderation m on m.response_id = r.id and m.question_id = v_qid
       where r.id = any(v_fo) and m.allapot = 'valid';

      if v_txtn < v_kt then
        v_one := v_one || jsonb_build_object(
          'szovegek', null, 'szoveg_db', v_txtn, 'szoveg_rejtve', true,
          'szoveg_oka', 'keves_ervenyes_szoveg',
          'szoveg_uzenet', 'Moderalt, ervenyes szoveges valasz: ' || v_txtn ||
                           ' < k_text=' || v_kt || '. Egyetlen szoveg sem jelenitheto meg.');
      else
        v_one := v_one || jsonb_build_object(
          'szovegek', v_txt, 'szoveg_db', v_txtn, 'szoveg_rejtve', false, 'szoveg_oka', null);
      end if;

      -- A moderálásra váró darabszám CSAK adminnak megy vissza: az oktatónak
      -- ebbol arra lehetne kovetkeztetni, hany szoveg van meg "fuggoben" rola.
      if p_admin then
        select count(*) into v_pend
          from echo.moderation m
         where m.response_id = any(v_fo) and m.question_id = v_qid and m.allapot = 'pending';
        v_one := v_one || jsonb_build_object('moderalatlan', v_pend);
      end if;
    end if;

    v_fo_q := v_fo_q || jsonb_build_array(v_one);

    -- ALACSONY ÓRALÁTOGATÁSÚ BLOKK — saját küszöbbel (k_low), és a fő
    -- statisztikába NEM számít bele (3. § (9)). Szöveget innen SOHA nem
    -- adunk vissza: a halmaz eleve kicsi, egy szöveg itt azonosítana.
    if coalesce(array_length(v_lo,1),0) >= v_klow then
      select coalesce(jsonb_agg(r.answers -> v_qid), '[]'::jsonb) into v_vals
        from echo.response r
       where r.id = any(v_lo)
         and jsonb_exists(r.answers, v_qid)
         and jsonb_typeof(r.answers -> v_qid) <> 'null';
      v_lo_q := v_lo_q || jsonb_build_array(
        echo.agg_one(q, v_vals) || jsonb_build_object('szovegek', null, 'szoveg_rejtve', true));
    end if;
  end loop;

  v_out := jsonb_build_object(
    'campaign_id',   p_campaign,
    'campaign_code', v_c.code,
    'campaign_state',v_c.state,
    'course_id',     p_course,
    'course_name',   (select name_hu from echo.course where id = p_course),
    'teacher_id',    p_teacher,
    'teacher_name',  (select name from echo.teacher where id = p_teacher),
    'scope',         p_scope,
    'kuszobok', jsonb_build_object('k_numeric', v_kn, 'k_dist', echo.k('k_dist'),
                                   'k_text', v_kt, 'k_slice', echo.k('k_slice'),
                                   'k_low', v_klow,
                                   'attendance_min_pct', echo.k('attendance_min_pct')),
    'valaszadas', jsonb_build_object(
      'jogosult', v_jog,
      'valaszok', coalesce(array_length(v_fo,1),0),
      'arany',    round(coalesce(array_length(v_fo,1),0)::numeric / nullif(v_jog,0) * 100, 1)),
    'rejtve', false,
    'kerdesek', v_fo_q,
    'alacsony_oralatogatas', jsonb_build_object(
      -- Ugyanaz a javitas: az elemszam CSAK akkor megy vissza, ha a blokk
      -- egyaltalan megjelenik (n >= k_low). Alatta null, nem 0 es nem a
      -- valodi szam — kulonben a k_low semmit nem vedene.
      'n', case when coalesce(array_length(v_lo,1),0) >= v_klow
                then coalesce(array_length(v_lo,1),0) else null end,
      'k_low', v_klow,
      'rejtve', coalesce(array_length(v_lo,1),0) < v_klow,
      'kerdesek', v_lo_q,
      'megjegyzes', case
        when p_scope = 'teacher'
          then 'Oktatoi bontasban ez a blokk MINDIG ures: az oralatogatasi sav kizarolag '
               'a kurzusszintu valaszsoron all, es a kurzusszintu meg az oktatoi sor kozott '
               'szandekosan nincs kozos kulcs (15_echo_core.sql, 6.2). Lasd a fajl fejlecet.'
        else '3. § (9): ezek a valaszok NEM szamitanak a jegyzokonyvi statisztikaba. '
             'Szoveges valasz innen soha nem kerul vissza.' end));

  return v_out;
end $$;

-- ------------------------------------------------------------
-- 2. A 3. kérdőív-verzió
-- ------------------------------------------------------------
do $mig$
declare
  v_tpl      uuid;
  v_live     uuid;
  v_src      jsonb;
  v_new      jsonb;
  v_secs     jsonb;
  v_part1    jsonb;
  v_ver      integer;
  v_id       uuid;
  v_state    text;
  v_hits     jsonb;
begin
  select id into v_tpl from echo.template where code = 'OMHV-ALAP';
  if v_tpl is null then
    raise exception '24: nincs meg az OMHV-ALAP sablon. Eloszor a 15_echo_core.sql fusson.';
  end if;

  -- A FORRAS a jelenleg ELO verzio. Ha nincs elo, a legmagasabb sorszamu.
  select id, compiled into v_live, v_src
    from echo.template_version
   where template_id = v_tpl
   order by (state = 'live') desc, version desc
   limit 1;
  if v_live is null then
    raise exception '24: az OMHV-ALAP sablonnak nincs egyetlen verzioja sem.';
  end if;

  -- Mar letezik a bevezeto kerdeseket tartalmazo verzio? Akkor nem csinalunk ujat.
  select id, state into v_id, v_state
    from echo.template_version
   where template_id = v_tpl
     and exists (select 1
                   from jsonb_array_elements(echo.jarr(compiled->'sections')) s
                  where s.value->>'part' = 'part1'
                    and jsonb_array_length(echo.jarr(s.value->'questions')) > 0)
   order by version desc
   limit 1;
  if v_id is not null then
    raise notice '24: mar letezik part1 kerdeseket tartalmazo verzio (%, allapot=%). A fajl nem csinal ujat.', v_id, v_state;
    return;
  end if;

  -- ---- a ket bevezeto kerdes ----
  v_part1 := $json$
{
  "id": "s0", "part": "part1", "audience": [],
  "hu": "Mielőtt célt tűzöl ki", "en": "Before you set your goals",
  "lead_hu": "Két rövid kérdés a félév indulásáról. A válaszod csak a Tiéd — az oktató nem látja.",
  "lead_en": "Two short questions about the start of the term. Your answer stays yours — the teacher does not see it.",
  "questions": [
    { "id": "goals_discussed", "type": "single",
      "hu": "Beszéltetek az oktatóval a kurzus céljairól a félév elején?",
      "en": "Did you discuss the aims of the course with the teacher at the start of the term?",
      "help": { "hu": "A válaszod a saját célmeghatározásodhoz tartozik, a félév végi névtelen értékelésbe nem kerül át.",
                "en": "Your answer belongs to your own goal setting; it is not carried over to the anonymous end-of-term evaluation." },
      "options": [
        { "value": "reszletesen",  "hu": "Igen, részletesen",   "en": "Yes, in detail" },
        { "value": "roviden",      "hu": "Igen, röviden",       "en": "Yes, briefly" },
        { "value": "nem",          "hu": "Nem",                 "en": "No" },
        { "value": "nem_emlekszem","hu": "Nem emlékszem",       "en": "I do not remember" }
      ],
      "required": true, "moderated": false, "randomize": false, "allowOther": false,
      "max": 1, "repeat": null, "cond": null, "scale": null,
      "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
    { "id": "req_clear", "type": "single",
      "hu": "Világosak számodra a kurzus teljesítési követelményei?",
      "en": "Are the course requirements clear to you?",
      "help": { "hu": "A félév végén ugyanerről még egyszer kérdezünk — akkor arról, hogy változtak-e.",
                "en": "We ask about this again at the end of the term — then about whether they changed." },
      "options": [
        { "value": "teljesen",   "hu": "Teljesen világosak",      "en": "Completely clear" },
        { "value": "nagyreszt",  "hu": "Nagyrészt világosak",     "en": "Mostly clear" },
        { "value": "reszben",    "hu": "Részben világosak",       "en": "Partly clear" },
        { "value": "egyaltalan", "hu": "Egyáltalán nem világosak","en": "Not clear at all" }
      ],
      "required": true, "moderated": false, "randomize": false, "allowOther": false,
      "max": 1, "repeat": null, "cond": null, "scale": null,
      "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
  ]
}
  $json$::jsonb;

  -- ---- a part1 szakasz a lista ELEJERE ----
  v_secs := jsonb_build_array(v_part1) || echo.jarr(v_src->'sections');

  -- ---- az "Egyeb" opciok megjelolese other:true jelzovel ----
  select jsonb_agg(
           case when jsonb_typeof(s.value->'questions') = 'array'
                then jsonb_set(s.value, '{questions}', (
                       select coalesce(jsonb_agg(
                         case when jsonb_typeof(q.value->'options') = 'array'
                              then jsonb_set(q.value, '{options}', (
                                     select coalesce(jsonb_agg(
                                       case when lower(btrim(coalesce(o.value->>'value',''))) in ('egyéb','egyeb','other')
                                              or lower(btrim(coalesce(o.value->>'hu',   ''))) in ('egyéb','egyeb','other')
                                              or lower(btrim(coalesce(o.value->>'en',   ''))) in ('egyéb','egyeb','other')
                                            then o.value || '{"other": true}'::jsonb
                                            else o.value end
                                       order by o.ordinality), '[]'::jsonb)
                                       from jsonb_array_elements(q.value->'options') with ordinality o))
                              else q.value end
                         order by q.ordinality), '[]'::jsonb)
                         from jsonb_array_elements(s.value->'questions') with ordinality q))
                else s.value end
           order by s.ordinality)
    into v_secs
    from jsonb_array_elements(v_secs) with ordinality s;

  -- ---- a verzio sorszama es meta mezoi ----
  select coalesce(max(version), 0) + 1 into v_ver
    from echo.template_version where template_id = v_tpl;

  v_new := jsonb_set(v_src, '{sections}', v_secs);
  v_new := jsonb_set(v_new, '{meta,version}', to_jsonb(v_ver));
  v_new := jsonb_set(v_new, '{meta,elozmeny}', to_jsonb(
    'A ' || v_ver || '. verzio a ' || coalesce((v_src->'meta'->>'version'),'?') ||
    '. verzio masolata, kiegeszitve a celmeghatarozas (part1) ket bevezeto '
    'kerdesevel, es az "Egyeb" opciok other:true jelzojevel. A korabbi verziok '
    'NEM torolhetok: a hozzajuk kotott valaszok rajuk hivatkoznak.'));
  v_new := jsonb_set(v_new, '{meta,forras_megjegyzes}', to_jsonb(
    'A ket bevezeto kerdes (goals_discussed, req_clear) szovege REKONSTRUKCIO: '
    'a prototipus forrasfajlja a munkamasolatban nem volt elerheto. MIR-jovahagyast '
    'igenyel az elesites elott.'::text));

  v_id := gen_random_uuid();
  insert into echo.template_version (id, template_id, version, state, compiled, notes)
  values (v_id, v_tpl, v_ver, 'draft', v_new,
          'A celmeghatarozas ket bevezeto kerdese + "Egyeb" jelzok (24_echo_form_v3.sql). '
          'A ket kerdes szovege rekonstrukcio, MIR-jovahagyasra var.');

  v_hits := echo.template_validate(v_new);
  raise notice '24: letrejott a %. verzio (draft), id=%. Validator talalatok: %',
               v_ver, v_id, jsonb_array_length(v_hits);
  if jsonb_array_length(v_hits) > 0 then
    raise notice '24: a validator reszletei: %', v_hits;
  end if;
end $mig$;

-- ------------------------------------------------------------
-- 3. ELLENŐRZÉS
-- ------------------------------------------------------------
select tv.version,
       tv.state,
       (select count(*) from jsonb_array_elements(echo.jarr(tv.compiled->'sections')) s
         where s.value->>'part' = 'part1')                                as part1_szakasz,
       (select count(*) from jsonb_array_elements(echo.jarr(tv.compiled->'sections')) s,
                             jsonb_array_elements(echo.jarr(s.value->'questions')) q
         where s.value->>'part' = 'part1')                                as part1_kerdes,
       (select count(*) from jsonb_array_elements(echo.jarr(tv.compiled->'sections')) s,
                             jsonb_array_elements(echo.jarr(s.value->'questions')) q,
                             jsonb_array_elements(echo.jarr(q.value->'options')) o
         where coalesce((o.value->>'other')::boolean, false))             as egyeb_jelzo,
       jsonb_array_length(echo.template_validate(tv.compiled))            as validator_talalat
  from echo.template_version tv
  join echo.template t on t.id = tv.template_id
 where t.code = 'OMHV-ALAP'
 order by tv.version;

-- Elvárt: 'IGEN' — a futó definícióban benne van a part1-kizárás is.
select case when pg_get_functiondef(p.oid) like '%<> ''part1''%'
            then 'IGEN' else 'NEM' end as part1_kizarva_a_riportbol
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'echo' and p.proname = 'results_build';

-- ============================================================
-- KÉZI LÉPÉSEK — EZEKET A FÁJL SZÁNDÉKOSAN NEM TESZI MEG
-- ============================================================
-- 1) ÁTNÉZÉS A SZERKESZTŐBEN: ECHO -> Kérdőívek -> OMHV alapkerdoiv ->
--    a most létrejött piszkozat. A két bevezető kérdés szövege
--    REKONSTRUKCIÓ (lásd a fájl fejlécét) — MIR-jóváhagyás kell rá.
--
-- 2) ÉLESÍTÉS. Admin munkamenetben, egyesével (a draft->approved ugrást a
--    echo.template_version_freeze() trigger tiltja):
--      -- select public.echo_template_validate('<uj_verzio_id>');
--      -- select public.echo_template_transition('<uj_verzio_id>', 'review');
--      -- select public.echo_template_transition('<uj_verzio_id>', 'approved');
--      -- select public.echo_template_transition('<uj_verzio_id>', 'live');
--
-- 3) A KAMPÁNY. Egy kampány = egy kérdőív-verzió (lásd 18c fejléce): a futó
--    kampányt NE kösd át, mert a régi válaszokat a régi verzió kérdés-ID-jeivel
--    keresné a riport. ÚJ kampány kell az új verzióval — a félév futó kampányát
--    előbb le kell zárni és lepecsételni. Mindkettő VISSZAFORDÍTHATATLAN.
--
-- 4) AZ ELŐZŐ VERZIÓ automatikusan 'closed' lesz az élesítéskor (egy sablonnak
--    egy élő verziója lehet). Ez végleges, de a rá hivatkozó válaszok
--    értelmezhetők maradnak: a response tábla a saját verzióját őrzi.
-- ============================================================
