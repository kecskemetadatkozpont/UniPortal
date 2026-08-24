-- ============================================================
-- 20_echo_report_fix.sql — AZ ÓRALÁTOGATÁS HAMIS "KEVÉS VÁLASZ" SORA
-- ============================================================
-- Neumann János Egyetem — ECHO (OMHV), 28/2023. (VIII.31.) szenátusi határozat
--
-- MIÉRT VAN EZ A FÁJL
-- -------------------
-- MÉRT HIBA (13 valódi beküldésen, a helyi replikán): az 'attendance'
-- (óralátogatás) kérdés a kurzusjegyzőkönyvben MINDIG így jelent meg:
--     { "id": "attendance", "n": 0,
--       "uzenet": "Keves valasz (0 < k_numeric=5): errol a kerdesrol nem
--                  adhato ki bontas" }
-- pedig mind a 13 válaszadó kitöltötte: az echo.response.attendance_band
-- mind a 13 kurzusszintű soron '85–100%' volt, ugyanakkor
-- (answers ? 'attendance') mind a 13 soron hamis.
--
-- AZ OK SZERKEZETI, NEM ADATVESZTÉS. Az echo_submit() (15_echo_core.sql,
-- 5. lépés) az óralátogatást a payload gyökeréből a KÜLÖN attendance_band
-- OSZLOPBA teszi — szándékosan, mert a sáv a 3. § (9) szerinti FŐ/ALACSONY
-- kettéosztás bemenete, és mert az oktatói soron NULL-nak kell maradnia
-- (különben az azonos érték egy beküldés sorait egymáshoz kötné).
-- Az echo.results_build() kérdésenkénti ciklusa viszont a compiled
-- kérdéslistáját járja be, és az r.answers -> v_qid kifejezéssel keres —
-- ott az óralátogatás soha nincs ott. A keresés helye és a tárolás helye
-- sosem esett egybe.
--
-- MIT VÁLTOZTAT
--   Az echo.results_build() kérdésciklusa kihagyja az 'attendance' id-jű
--   kérdést. Egyetlen sor a WHERE-ben:
--       and coalesce(qq.value->>'id','') <> 'attendance'
--   Minden más SORRÓL SORRA azonos a 16_echo_reports.sql-beli változattal.
--
-- MIÉRT ID SZERINT ÉS NEM TÍPUS SZERINT: a 18b seed a prototípus
-- type:'attendance' mezőjét 'single'-re fordítja (a renderelő öt típust
-- ismer: single, multi, scale, longtext, skip) — típusra szűrni tehát nem
-- lehet. Mérve.
--
-- MI NEM VÁLTOZIK
--   • az óralátogatás továbbra is vezérli a FŐ/ALACSONY kettéosztást
--     (echo.attendance_low), tehát a 3. § (9) szerinti szűrés érintetlen;
--   • az 'alacsony_oralatogatas' blokk változatlanul közli az elemszámot,
--     amennyit a k_low enged (alatta null, nem 0);
--   • egyetlen k-küszöb sem mozdul.
--
-- HA VALAHA KELL A SÁVOK ELOSZLÁSA a jegyzőkönyvbe: azt az attendance_band
-- OSZLOPBÓL kell aggregálni, echo.suppress_cells()-lel, k_dist küszöbbel —
-- nem az answers-ből. Ez a fájl ezt SZÁNDÉKOSAN nem teszi meg: új
-- közlési felület, amit előbb el kell dönteni, nem mellékesen bevezetni.
--
-- FÜGG: 16_echo_reports.sql (annak kell lefutnia előbb).
-- ÉRINT: echo.results_build() — ezt hívja a public.echo_course_results()
--        és a public.echo_teacher_results() is.
-- IDEMPOTENS: tiszta create or replace, akárhányszor futtatható.
-- FUTTATÁS: Supabase SQL Editor, egyetlen blokként bemásolva.
-- ============================================================

set search_path = echo, public, extensions, pg_temp;

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
-- ELLENŐRZÉS — ez a lekérdezés fut le a migráció végén
-- ------------------------------------------------------------
-- Elvárt: 'IGEN' — a futó definícióban benne van a kizárás.
select case when pg_get_functiondef(p.oid) like '%<> ''attendance''%'
            then 'IGEN' else 'NEM' end                       as attendance_kizarva,
       (select count(*) from echo.response r
         where r.scope = 'course' and r.attendance_band is not null) as savval_rendelkezo_valasz
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'echo' and p.proname = 'results_build';
