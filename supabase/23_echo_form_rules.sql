-- ============================================================
-- UniPortal Pro — ECHO: kitöltési szabályok szerveroldali kikényszerítése
-- ------------------------------------------------------------
-- Neumann János Egyetem — OMHV, 28/2023. (VIII.31.) szenátusi határozat
--
-- FUTTATÁSI SORREND: a 15..20 UTÁN. A 21_echo_harden_submit.sql MINDIG az
-- utolsó legyen — ez a fájl ÚJRAÍRJA az echo_submit()-et, tehát a futtatás
-- után a 21-et ÚJRA LE KELL FUTTATNI, különben a platform alapértelmezett
-- jogosztása visszaadhatja az 'authenticated' végrehajtási jogot, és az
-- anonimitás egyik tartóoszlopa csendben elvész.
--
--     ... 20_echo_report_fix.sql
--     23_echo_form_rules.sql      <- ez a fájl
--     21_echo_harden_submit.sql   <- ÚJRA
--
-- MIÉRT VAN EZ A FÁJL — KÉT MÉRT HIÁNY
-- ------------------------------------
-- (1.2) "LEGALÁBB EGY CÉL KÖTELEZŐ". MÉRVE a helyi 'fresh' replikán:
--       select public.echo_save_goals(<kampany>,<kurzus>,'[]','[]')
--         -> {"ok": true, "goals": 0, "expectations": 0}
--       Vagyis a célmeghatározás ÜRESEN is elmenthető volt. Ez nem elméleti
--       gond: cél nélkül a félév végi kitöltőből a "Célok teljesülése" szakasz
--       teljes egészében kiesik (features/echo.jsx, ECHO_buildSteps — "HA A
--       HALLGATÓNAK NINCS CÉLJA, a szakasz KIESIK"), tehát az üres
--       célmeghatározás egy látszatlépés, aminek a félév végén nincs nyoma.
--
-- (1.3) AZ "EGYÉB" MELLÉ KÖTELEZŐ SZÖVEG. MÉRVE ugyanott:
--       echo_submit(<jegy>, {"course":{"course_strengths_p":["Egyéb"]}, ...})
--         -> {"ok": true, "rows": 1}
--       Vagyis a nyers API-n át bemehetett egy csupasz "Egyéb" válasz. Abból
--       annyi derül ki, hogy "valami más volt", az viszont nem, hogy mi —
--       az oktatói eredménynézetben ez egy értelmezhetetlen sor.
--       A felület mostantól nem enged tovább nélküle (ECHO_otherMissing),
--       de a frontend jóhiszemű fél, nem védvonal.
--
-- MIT VÁLTOZTAT
--   1. echo.student_goal + 'intro' jsonb oszlop — a célmeghatározó két
--      BEVEZETŐ kérdésének válasza.
--   2. echo_save_goals(): +p_intro paraméter, normalizálás, és a
--      "legalább egy cél" szabály kikényszerítése.
--   3. echo_get_form(): a 'goals' objektum visszaadja az 'intro'-t is,
--      hogy a célmeghatározó vissza tudja tölteni a korábbi válaszokat.
--   4. echo_submit(): az "Egyéb" melletti szöveg kikényszerítése.
--
-- ================== ADATVÉDELMI HATÁR — OLVASD EL ==================
-- A két bevezető kérdés válasza az echo.student_goal sorba megy, ami a
-- hallgatóhoz VAN kötve (student_key), és a félév eleji célokkal együtt él.
-- Ez tudatos: ugyanaz az adatkör, ugyanaz a jogalap, ugyanaz a láthatóság.
--
-- A NÉVTELEN VÁLASZHALMAZBA (echo.response) EZ NEM MEHET ÁT. Az ok ugyanaz,
-- amiért a célok szövege és darabszáma sem megy át (15_echo_core.sql 1099.
-- sor környéke): az echo.student_goal a hallgatóhoz kötött, tehát bármi, ami
-- onnan a névtelen sorra átkerül, összekötési pontot ad. Az echo_submit()
-- 4. lépése ezért az 'intro' kulcsot is levágja — ugyanabban a listában,
-- ahol a 'goals' és a 'goal_count' áll.
--
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Az 'intro' oszlop
-- ------------------------------------------------------------
alter table echo.student_goal
  add column if not exists intro jsonb not null default '{}'::jsonb;

comment on column echo.student_goal.intro is
  'A celmeghatarozo (part1) BEVEZETO kerdeseinek valaszai: {"<kerdes_id>": <ertek>}. '
  'A hallgatohoz kotott sorban el, a nevtelen echo.response-ba SOHA nem kerul at '
  '(az echo_submit() 4. lepese nev szerint levagja).';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'echo_student_goal_intro_obj_chk') then
    alter table echo.student_goal
      add constraint echo_student_goal_intro_obj_chk
      check (jsonb_typeof(intro) = 'object');
  end if;
end $$;

-- ------------------------------------------------------------
-- 2. Segéd: egy kérdőív-verzió part1 kérdései
-- ------------------------------------------------------------
-- A bevezető kérdések a compiled JSONB part1 szakaszaiban élnek. A validáláshoz
-- tudnunk kell, melyik kérdés kötelező és milyen értékeket vehet fel — ezt
-- innen olvassuk, NEM beégetett listából: ha a kérdőív új verziót kap, a
-- szabály magától követi.
create or replace function echo.part1_questions(p_version uuid)
returns table (qid text, required boolean, qtype text, opts text[])
language sql stable
set search_path = echo, public, pg_temp
as $$
  select q->>'id',
         coalesce((q->>'required')::boolean, false),
         coalesce(q->>'type', 'single'),
         (select coalesce(array_agg(coalesce(o->>'value', o->>'hu', o #>> '{}')), '{}')
            from jsonb_array_elements(case when jsonb_typeof(q->'options') = 'array'
                                           then q->'options' else '[]'::jsonb end) o)
    from echo.template_version tv,
         jsonb_array_elements(case when jsonb_typeof(tv.compiled->'sections') = 'array'
                                   then tv.compiled->'sections' else '[]'::jsonb end) s,
         jsonb_array_elements(case when jsonb_typeof(s->'questions') = 'array'
                                   then s->'questions' else '[]'::jsonb end) q
   where tv.id = p_version
     and s->>'part' = 'part1'
     and coalesce(q->>'id','') <> ''
$$;

-- A part1 kérdés-ID-k listája. Az echo_submit() ezeket NÉV SZERINT levágja a
-- névtelen válaszsorról — lásd az ottani 4) lépést és az indoklást a fejlécben.
create or replace function echo.part1_question_ids(p_version uuid)
returns text[]
language sql stable
set search_path = echo, public, pg_temp
as $$
  select coalesce(array_agg(qid), '{}') from echo.part1_questions(p_version)
$$;

-- ------------------------------------------------------------
-- 3. echo_save_goals — +p_intro, +"legalább egy cél"
-- ------------------------------------------------------------
-- A régi, 4 paraméteres alakot EL KELL DOBNI: az új alak 5. paramétere
-- alapértelmezett értékű, tehát a kettő együtt LÉTEZVE a 4 argumentumos hívás
-- kétértelmű lenne ("function is not unique"). Ha a 15_echo_core.sql-t
-- valaha újrafuttatod, ez a fájl is futtatandó utána.
drop function if exists public.echo_save_goals(uuid, uuid, jsonb, jsonb);

create or replace function public.echo_save_goals(p_campaign uuid, p_course uuid,
                                                  p_goals jsonb, p_expectations jsonb,
                                                  p_intro jsonb default '{}'::jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_me    uuid := auth.uid();
  v_ver   uuid;
  v_g     jsonb;
  v_x     jsonb;
  v_intro jsonb := '{}'::jsonb;
  r       record;
  v_val   text;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;
  if not exists (select 1 from echo.participation
                  where campaign_id = p_campaign and course_id = p_course
                    and student_key = v_me and eligible) then
    raise exception 'ECHO_NOT_ELIGIBLE';
  end if;
  if not echo.is_goals_open(p_campaign) then raise exception 'ECHO_GOALS_CLOSED'; end if;

  if jsonb_typeof(p_goals) <> 'array' or jsonb_typeof(p_expectations) <> 'array' then
    raise exception 'ECHO_BAD_PAYLOAD';
  end if;
  if p_intro is not null and jsonb_typeof(p_intro) <> 'object' then
    raise exception 'ECHO_BAD_INTRO: a bevezeto valaszok csak objektumkent adhatok meg.';
  end if;

  -- NORMALIZÁLÁS a hosszellenőrzés ELŐTT. Enélkül három darab whitespace-cél
  -- "3 cél"-nak számítana a korlátnál, a tárolt sorban viszont üres marad,
  -- és a félév végi kitöltő (ECHO_goalItems is trimmel) egyet sem mutatna:
  -- a hallgató úgy tudná, van célja, a rendszer szerint meg nincs.
  select coalesce(jsonb_agg(t), '[]'::jsonb) into v_g
    from (select distinct on (btrim(e #>> '{}')) btrim(e #>> '{}') as t
            from jsonb_array_elements(p_goals) e
           where btrim(coalesce(e #>> '{}', '')) <> '') z;
  select coalesce(jsonb_agg(t), '[]'::jsonb) into v_x
    from (select distinct on (btrim(e #>> '{}')) btrim(e #>> '{}') as t
            from jsonb_array_elements(p_expectations) e
           where btrim(coalesce(e #>> '{}', '')) <> '') z;

  if jsonb_array_length(v_g) > 3 or jsonb_array_length(v_x) > 3 then
    raise exception 'ECHO_TOO_MANY_GOALS';
  end if;

  -- LEGALÁBB EGY CÉL. Az elvárás (p_expectations) NEM helyettesíti: a félév
  -- végi "Célok teljesülése" szakasz mindkettőt felsorolja, de a szabály a
  -- CÉLRÓL szól — a hallgató saját, félév végén eldönthető vállalásáról.
  if jsonb_array_length(v_g) = 0 then
    raise exception 'ECHO_GOALS_REQUIRED';
  end if;

  -- A BEVEZETŐ VÁLASZOK ellenőrzése a kampány kérdőív-verziója szerint.
  select c.template_version_id into v_ver from echo.campaign c where c.id = p_campaign;

  for r in select * from echo.part1_questions(v_ver) loop
    v_val := nullif(btrim(coalesce(p_intro ->> r.qid, '')), '');
    if v_val is null then
      if r.required then
        raise exception 'ECHO_INTRO_REQUIRED: valaszolatlan bevezeto kerdes (%).', r.qid;
      end if;
      continue;
    end if;
    -- Zárt listás kérdésnél csak a felkínált érték mehet be. Enélkül a nyers
    -- API-n át tetszőleges szöveg landolhatna a bevezető válaszban.
    if array_length(r.opts, 1) is not null and not (v_val = any (r.opts)) then
      raise exception 'ECHO_BAD_INTRO: a(z) "%" kerdesre adott valasz nincs a felkinalt opciok kozott.', r.qid;
    end if;
    v_intro := v_intro || jsonb_build_object(r.qid, v_val);
  end loop;

  -- FIGYELEM: a v_intro-ba CSAK a kérdőívben szereplő part1 kérdés-ID-k
  -- kerülnek be. Ami nem onnan való, azt eldobjuk — így a mező nem válhat
  -- szabad tárhellyé a kliens kezében.

  insert into echo.student_goal (campaign_id, course_id, student_key, goals, expectations, intro)
  values (p_campaign, p_course, v_me, v_g, v_x, v_intro)
  on conflict (campaign_id, course_id, student_key)
  do update set goals = excluded.goals,
                expectations = excluded.expectations,
                intro = excluded.intro,
                updated_at = now();

  return jsonb_build_object('ok', true,
                            'goals', jsonb_array_length(v_g),
                            'expectations', jsonb_array_length(v_x),
                            'intro', v_intro);
end $$;

-- ------------------------------------------------------------
-- 4. echo_get_form — az 'intro' visszaadása
-- ------------------------------------------------------------
-- Csak a 'goals' objektum bővül. Minden más mező betű szerint a
-- 15_echo_core.sql 9.2 szakaszából való.
create or replace function public.echo_get_form(p_campaign uuid, p_course uuid)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_me uuid := auth.uid(); v_p echo.participation%rowtype; v_c echo.campaign%rowtype; v_out jsonb;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;

  select * into v_p from echo.participation
   where campaign_id = p_campaign and course_id = p_course and student_key = v_me;
  if not found or not v_p.eligible then raise exception 'ECHO_NOT_ELIGIBLE'; end if;

  select * into v_c from echo.campaign where id = p_campaign;
  if v_c.state = 'draft' then raise exception 'ECHO_CAMPAIGN_NOT_READY'; end if;

  select jsonb_build_object(
           'campaign', jsonb_build_object(
              'id', v_c.id, 'code', v_c.code, 'name', v_c.name_hu, 'term', v_c.term,
              'state', v_c.state, 'opens_at', v_c.opens_at, 'closes_at', v_c.closes_at,
              'is_open', echo.is_open(v_c.id), 'is_goals_open', echo.is_goals_open(v_c.id)),
           -- A 'lang' MÁR ITT VOLT: a kurzus képzési nyelve. A kitöltő ezt
           -- használja a kérdőív nyelvének eldöntésére (3. § (1)) — NEM a
           -- fejléc nyelvválasztóját. Lásd features/echo.jsx, ECHO_formLang.
           'course', (select jsonb_build_object(
                        'id', k.id, 'code', k.code, 'name', k.name_hu,
                        'name_en', k.name_en, 'lang', k.lang, 'term', k.term)
                        from echo.course k where k.id = p_course),
           'teachers', (select coalesce(jsonb_agg(jsonb_build_object(
                          'id', t.id, 'name', t.name, 'title', t.title,
                          'share_pct', el.share_pct) order by t.name), '[]'::jsonb)
                          from echo.eligibility el
                          join echo.teacher t on t.id = el.teacher_id
                         where el.campaign_id = p_campaign and el.course_id = p_course),
           'form', (select tv.compiled from echo.template_version tv
                     where tv.id = v_c.template_version_id),
           'template_version_id', v_c.template_version_id,
           -- A SAJÁT célok, elvárások ÉS bevezető válaszok (azonosított hívás,
           -- ezért szabad). Ezekből SEMMI nem megy át a névtelen válaszsorra.
           'goals', coalesce((select jsonb_build_object('goals', g.goals,
                                       'expectations', g.expectations,
                                       'intro', coalesce(g.intro, '{}'::jsonb))
                                from echo.student_goal g
                               where g.campaign_id = p_campaign and g.course_id = p_course
                                 and g.student_key = v_me),
                             jsonb_build_object('goals','[]'::jsonb,'expectations','[]'::jsonb,
                                                'intro','{}'::jsonb)),
           'participation', jsonb_build_object(
              'attempted', v_p.attempted, 'submitted', v_p.submitted)
         )
    into v_out;
  return v_out;
end $$;

-- ------------------------------------------------------------
-- 5. Segéd: az "Egyéb"-hiányos többes választások egy válaszhalmazban
-- ------------------------------------------------------------
-- Visszaadja azoknak a kérdéseknek az ID-ját, ahol a beküldő bejelölte az
-- "Egyéb" opciót, de nem írt mellé saját szöveget.
--
-- AZ "EGYÉB" AZONOSÍTÁSA a compiled adatából megy:
--   elsődlegesen az opció "other": true jelzője, másodlagosan a value/hu/en
--   szövege ('Egyéb' / 'Egyeb' / 'Other'). A második ág azért kell, mert a MA
--   ÉLŐ 2. verzióban nincs "other" jelző (mérve) — e nélkül a szabály a
--   jelenlegi kérdőíven nem fogna semmit.
-- A SAJÁT SZÖVEG definíció szerint az, ami NINCS benne az opciólistában —
-- pontosan úgy, ahogy a felület is számolja (ECHO_QMulti `extras`).
create or replace function echo.other_text_gaps(p_version uuid, p_answers jsonb, p_scope text)
returns text[]
language plpgsql stable
set search_path = echo, public, pg_temp
as $$
declare
  q        jsonb;
  v_qid    text;
  v_vals   text[];
  v_opts   text[];
  v_others text[];
  v_extra  int;
  v_out    text[] := '{}';
begin
  if p_answers is null or jsonb_typeof(p_answers) <> 'object' then return v_out; end if;

  for q in
    select qq
      from echo.template_version tv,
           jsonb_array_elements(case when jsonb_typeof(tv.compiled->'sections') = 'array'
                                     then tv.compiled->'sections' else '[]'::jsonb end) s,
           jsonb_array_elements(case when jsonb_typeof(s->'questions') = 'array'
                                     then s->'questions' else '[]'::jsonb end) qq
     where tv.id = p_version
       and qq->>'type' = 'multi'
       -- A part1 (celmeghatarozas) kerdesei SOHA nem kerulnek a nevtelen
       -- valaszhalmazba, tehat itt nincs mit ellenorizni rajtuk.
       and coalesce(s->>'part', 'part2') <> 'part1'
       -- 'course' hatokorben a nem ismetlodo es a celonkenti kerdesek, 'teacher'
       -- hatokorben az oktatonkentiek. Igy egy oktatoi valaszhalmazon nem
       -- keresunk kurzusszintu kerdest es forditva.
       and ((p_scope = 'teacher' and qq->>'repeat' = 'teacher')
         or (p_scope = 'course'  and coalesce(qq->>'repeat','') is distinct from 'teacher'))
  loop
    v_qid := q->>'id';
    if coalesce(v_qid,'') = '' then continue; end if;
    if jsonb_typeof(p_answers -> v_qid) <> 'array' then continue; end if;

    select coalesce(array_agg(e #>> '{}'), '{}') into v_vals
      from jsonb_array_elements(p_answers -> v_qid) e;
    if array_length(v_vals, 1) is null then continue; end if;

    -- az osszes felkinalt ertek
    select coalesce(array_agg(coalesce(o->>'value', o->>'hu', o #>> '{}')), '{}') into v_opts
      from jsonb_array_elements(case when jsonb_typeof(q->'options') = 'array'
                                     then q->'options' else '[]'::jsonb end) o;
    -- ezek kozul az "Egyeb"-ek
    select coalesce(array_agg(coalesce(o->>'value', o->>'hu', o #>> '{}')), '{}') into v_others
      from jsonb_array_elements(case when jsonb_typeof(q->'options') = 'array'
                                     then q->'options' else '[]'::jsonb end) o
     where coalesce((o->>'other')::boolean, false)
        or lower(btrim(coalesce(o->>'value', ''))) in ('egyéb','egyeb','other')
        or lower(btrim(coalesce(o->>'hu',    ''))) in ('egyéb','egyeb','other')
        or lower(btrim(coalesce(o->>'en',    ''))) in ('egyéb','egyeb','other');

    if array_length(v_others, 1) is null then continue; end if;
    if not (v_vals && v_others) then continue; end if;      -- nincs "Egyeb" bejelolve

    -- van-e olyan bekuldott ertek, ami NINCS az opciolistaban
    select count(*) into v_extra
      from unnest(v_vals) v
     where btrim(coalesce(v,'')) <> '' and not (v = any (v_opts));

    if v_extra = 0 then v_out := v_out || v_qid; end if;
  end loop;

  return v_out;
end $$;

-- ------------------------------------------------------------
-- 6. echo_submit — az "Egyéb" melletti szöveg kikényszerítése
-- ------------------------------------------------------------
-- A 15_echo_core.sql 9.5 szakaszának változata. AMI VÁLTOZOTT:
--   • a 4) TISZTÍTÁS levágja az 'intro' kulcsot is (a bevezető válaszok a
--     hallgatóhoz kötött sorban élnek, a névtelen sorra nem jöhetnek át);
--   • új 4/b) lépés: az "Egyéb" melletti szöveg ellenőrzése kurzus- és
--     oktatószintű válaszhalmazon egyaránt.
-- Minden más betű szerint az eredeti.
create or replace function public.echo_submit(p_ticket text, p_payload jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_t         jsonb;
  v_campaign  uuid; v_course uuid; v_ver uuid; v_nonce uuid; v_exp bigint;
  v_att       text;
  v_course_a  jsonb;
  v_teachers  jsonb;
  v_item      jsonb;
  v_tid       uuid;
  v_n         integer := 0;
  v_goals_met text;
  v_gaps      text[];
  v_tans      jsonb;
  v_p1        text[];
  v_key       text;
begin
  -- 1) a jegy hitelessége
  v_t := echo.ticket_open(p_ticket);
  v_campaign := (v_t->>'c')::uuid;
  v_course   := (v_t->>'k')::uuid;
  v_ver      := (v_t->>'v')::uuid;
  v_nonce    := (v_t->>'n')::uuid;
  v_exp      := (v_t->>'e')::bigint;

  if to_timestamp(v_exp) < now() then raise exception 'ECHO_TICKET_EXPIRED'; end if;
  if not echo.is_open(v_campaign) then raise exception 'ECHO_CAMPAIGN_CLOSED'; end if;

  -- 2) a nonce elköltése ELSŐKÉNT
  begin
    insert into echo.spent_nonce (nonce, expires_at)
    values (v_nonce, date_trunc('day', to_timestamp(v_exp)) + interval '2 days');
  exception when unique_violation then
    raise exception 'ECHO_TICKET_SPENT';
  end;

  -- 3) a payload alakja és mérete
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'ECHO_BAD_PAYLOAD';
  end if;
  if pg_column_size(p_payload) > 65536 then raise exception 'ECHO_PAYLOAD_TOO_LARGE'; end if;

  v_att      := nullif(p_payload->>'attendance', '');
  v_course_a := coalesce(p_payload->'course', '{}'::jsonb);
  v_teachers := coalesce(p_payload->'teachers', '[]'::jsonb);
  if jsonb_typeof(v_course_a) <> 'object' or jsonb_typeof(v_teachers) <> 'array' then
    raise exception 'ECHO_BAD_PAYLOAD';
  end if;

  -- 4) TISZTÍTÁS. Ami azonosíthat, azt itt vágjuk le — nem a frontendben.
  v_goals_met := v_course_a->>'goals_met';
  if v_goals_met is not null
     and v_goals_met not in ('nem_teljesult','reszben','teljesult','tulteljesult') then
    raise exception 'ECHO_BAD_GOALS_MET';
  end if;
  v_course_a := v_course_a
    - 'goals' - 'goal_texts' - 'goals_text' - 'goal_count' - 'goals_count'
    - 'expectations' - 'expectation_texts' - 'student' - 'student_key'
    -- 'intro': a celmeghatarozo bevezeto valaszai. Az echo.student_goal
    -- sorban elnek, ami a hallgatohoz VAN kotve — a nevtelen valaszsorra
    -- atemelve osszekotesi pontot adnanak. Lasd 23_echo_form_rules.sql fejlec.
    - 'intro'
    - 'email' - 'name' - 'neptun' - 'user_id' - 'uid'
    - 'created_at' - 'submitted_at' - 'timestamp' - 'ts';

  -- 4/a) A PART1 (CÉLMEGHATÁROZÁS) KÉRDÉSEINEK LEVÁGÁSA.
  --      MÉRVE: az 'intro' kulcs levágása ÖNMAGÁBAN KEVÉS volt. Egy kliens a
  --      part1 kérdéseket a SAJÁT ID-JÜKÖN is beírhatta a course objektumba
  --      ("goals_discussed", "req_clear"), és azok bementek a névtelen sorra.
  --      Ez ugyanaz a szivárgás, amiért a célok darabszáma sem mehet át: a
  --      part1 válasz az AZONOSÍTOTT echo.student_goal sorban is ott áll, tehát
  --      a két oldal összevethető, és a 4x4 lehetséges válaszpár erősen
  --      leszűkíti a szóba jöhető kitöltők körét.
  --      A lista a kérdőívből jön, nem beégetve: ha a part1 új kérdést kap,
  --      a levágás magától követi.
  v_p1 := echo.part1_question_ids(v_ver);
  if array_length(v_p1, 1) is not null then
    foreach v_key in array v_p1 loop
      v_course_a := v_course_a - v_key;
    end loop;
  end if;

  -- 4/b) AZ "EGYÉB" MELLÉ KÖTELEZŐ A SZÖVEG.
  --      A felület már nem enged tovább nélküle, de a frontend jóhiszemű fél,
  --      nem védvonal: a nyers API-n át enélkül bemehetne egy csupasz "Egyéb",
  --      amiből az oktatói eredménynézetben egy értelmezhetetlen sor lenne.
  v_gaps := echo.other_text_gaps(v_ver, v_course_a, 'course');
  if array_length(v_gaps, 1) is not null then
    raise exception 'ECHO_OTHER_TEXT_REQUIRED: az "Egyeb" valasz melle szoveget is meg kell adni (%).',
                    array_to_string(v_gaps, ', ');
  end if;

  -- 5) kurzusszintű válaszsor
  insert into echo.response (campaign_id, course_id, teacher_id, template_version_id,
                             scope, attendance_band, answers)
  values (v_campaign, v_course, null, v_ver, 'course', v_att, v_course_a);
  v_n := v_n + 1;

  -- 6) oktatószintű válaszsorok
  for v_item in select * from jsonb_array_elements(v_teachers) loop
    v_tid := nullif(v_item->>'teacher','')::uuid;
    if v_tid is null then continue; end if;
    if not exists (select 1 from echo.eligibility
                    where campaign_id = v_campaign and course_id = v_course
                      and teacher_id = v_tid) then
      raise exception 'ECHO_TEACHER_NOT_ELIGIBLE';
    end if;

    v_tans := (coalesce(v_item->'answers','{}'::jsonb)
                - 'student' - 'student_key' - 'email' - 'name' - 'neptun' - 'user_id' - 'uid'
                - 'intro'
                - 'created_at' - 'submitted_at' - 'timestamp' - 'ts');
    -- ugyanaz a levagas, mint a kurzusszintu halmazon (4/a)
    if array_length(v_p1, 1) is not null then
      foreach v_key in array v_p1 loop
        v_tans := v_tans - v_key;
      end loop;
    end if;

    v_gaps := echo.other_text_gaps(v_ver, v_tans, 'teacher');
    if array_length(v_gaps, 1) is not null then
      raise exception 'ECHO_OTHER_TEXT_REQUIRED: az "Egyeb" valasz melle szoveget is meg kell adni (%).',
                      array_to_string(v_gaps, ', ');
    end if;

    insert into echo.response (campaign_id, course_id, teacher_id, template_version_id,
                               scope, attendance_band, answers)
    -- attendance_band SZANDEKOSAN null: lasd 15_echo_core.sql 6.2.
    values (v_campaign, v_course, v_tid, v_ver, 'teacher', null,
            v_tans || jsonb_build_object(
              'skipped', coalesce(v_item->'skipped','false'::jsonb),
              'skip_reason', coalesce(v_item->'skip_reason','null'::jsonb)));
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'rows', v_n);
end $$;

-- ------------------------------------------------------------
-- 7. GRANTOK
-- ------------------------------------------------------------
-- Postgresben minden ÚJ függvény EXECUTE jogot ad a PUBLIC-nak, ezért előbb
-- mindenkitől elvesszük, majd célzottan adjuk oda. Az echo_submit itt
-- SZÁNDÉKOSAN csak anon-t kap — a 21_echo_harden_submit.sql ezt zárja le
-- véglegesen, és azt EZUTÁN kell futtatni.
do $$
declare
  fn text;
  has_anon bool := exists (select 1 from pg_roles where rolname='anon');
  has_auth bool := exists (select 1 from pg_roles where rolname='authenticated');
  has_svc  bool := exists (select 1 from pg_roles where rolname='service_role');
begin
  -- az echo semas segedek zarva maradnak
  for fn in select p.oid::regprocedure::text
              from pg_proc p join pg_namespace n on n.oid=p.pronamespace
             where n.nspname='echo' and p.proname in ('part1_questions','part1_question_ids','other_text_gaps')
  loop
    execute format('revoke all on function %s from public', fn);
    if has_anon then execute format('revoke all on function %s from anon', fn); end if;
    if has_auth then execute format('revoke all on function %s from authenticated', fn); end if;
    if has_svc  then execute format('revoke all on function %s from service_role', fn); end if;
  end loop;

  for fn in select p.oid::regprocedure::text
              from pg_proc p join pg_namespace n on n.oid=p.pronamespace
             where n.nspname='public' and p.proname in ('echo_save_goals','echo_get_form','echo_submit')
  loop
    execute format('revoke all on function %s from public', fn);
    if has_anon then execute format('revoke all on function %s from anon', fn); end if;
    if has_auth then execute format('revoke all on function %s from authenticated', fn); end if;
    if has_svc  then execute format('revoke all on function %s from service_role', fn); end if;
  end loop;

  if has_auth then
    grant execute on function public.echo_get_form(uuid,uuid)                       to authenticated;
    grant execute on function public.echo_save_goals(uuid,uuid,jsonb,jsonb,jsonb)   to authenticated;
  end if;
  if has_anon then
    grant execute on function public.echo_submit(text,jsonb) to anon;
  end if;
end $$;

-- ------------------------------------------------------------
-- 8. ELLENŐRZÉS
-- ------------------------------------------------------------
select 'echo.student_goal.intro' as mit,
       (select count(*)::text from information_schema.columns
         where table_schema='echo' and table_name='student_goal' and column_name='intro') as ertek
union all
select 'echo_save_goals argumentumai',
       (select pg_get_function_identity_arguments(p.oid) from pg_proc p
          join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='echo_save_goals')
union all
select 'echo_save_goals darab (1 legyen)',
       (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='echo_save_goals')
union all
select 'echo_submit acl',
       (select coalesce(array_to_string(p.proacl,' '),'(alapertelmezett)') from pg_proc p
          join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='echo_submit');
