-- ============================================================================
-- RUN_ALL_42.sql — UniPortal
--
--   42_campaign_editor.sql     vázkampány + kampányszerkesztő + célközönség
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--   + a végén a MODUL SAJÁT ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a RUN_ALL_41.sql már lefutott. Ha még nem, FUTTASD ELŐSZÖR AZT —
-- e nélkül az "ECHO_TERM_BUSY" hiba is megmarad.
-- Idempotens. Meglévő kampányt nem módosít: célközönség-sor nélkül minden
-- kampány pontosan úgy viselkedik, mint eddig.
--
-- MIT AD:
--   1. Kampány létrehozható kérdőív és időablak nélkül is (vázkampány).
--      Elindulni viszont nem tud, amíg nincs kérdőíve, ablaka és kitöltője.
--   2. echo_campaign_update()        — a metaadatok szerkesztése
--      echo_campaign_audience_set()  — KI kapja meg: kurzus / csoport / személy
--      echo_campaign_audience()      — a jelenlegi célközönség + felső becslés
--      echo_audience_options()       — választható tételek a szerkesztőnek
-- ============================================================================


-- ============================================================================
--  42_campaign_editor.sql — UniPortal / ECHO
--  VÁZKAMPÁNY + KAMPÁNYSZERKESZTŐ + CÉLKÖZÖNSÉG
-- ============================================================================
--
--  MIT OLD MEG
--  (1) Kampányt kérdőív nélkül is létre lehet hozni. A sablonverzió és a
--      kitöltési ablak utólag is megadható. Elindulni viszont NEM lehet
--      kérdőív és ablak nélkül — ezt az állapotgép előfeltétele őrzi.
--  (2) A kampánynak van szerkesztője: a metaadatok módosíthatók, és meg
--      lehet adni, KI kapja meg a kérdőívet — kurzus, csoport vagy egyedi
--      felhasználó szintjén.
--
--  HOGYAN CÉLOZ
--  A célközönség két FÜGGETLEN kérdésre válaszol:
--    MIT értékelnek  -> 'course' sorok. Ha van ilyen, a kampány PONTOSAN
--                       ezeket a kurzusokat célozza. Ha nincs, marad a
--                       korábbi viselkedés: a félév minden kurzusa.
--    KI értékel      -> 'group' és 'user' sorok. Ha van ilyen, csak az így
--                       kijelölt hallgatók kapják meg. Ha nincs, mindenki,
--                       aki a kurzusra aktívan be van iratkozva.
--  A kettő szabadon kombinálható. Célközönség-sor nélkül a kampány pontosan
--  úgy viselkedik, mint eddig — a meglévő kampányok tehát nem változnak.
--
--  MIÉRT NEM EGY MEZŐ
--  Kísértés lett volna egyetlen 'hatókör' oszlopot tenni a kampányra. Azért
--  nem jó, mert a valódi kérdés kettő: egy kar kurzusait értékeltetni CSAK a
--  levelezős hallgatókkal két különböző szűrő, nem egy. Külön sorokban ez
--  természetes; egy mezőben kombinatorikus robbanás lenne.
--
--  ELŐFELTÉTEL: a RUN_ALL_41.sql már lefutott.
--  Idempotens.
-- ============================================================================


-- ============================================================================
--  42_campaign_editor.sql — UniPortal / ECHO
--  VÁZKAMPÁNY + KAMPÁNYSZERKESZTŐ + CÉLKÖZÖNSÉG
-- ============================================================================
--
--  MIT OLD MEG
--  (1) Kampányt kérdőív nélkül is létre lehet hozni. A sablonverzió és a
--      kitöltési ablak utólag is megadható. Elindulni viszont NEM lehet
--      kérdőív és ablak nélkül — ezt az állapotgép előfeltétele őrzi.
--  (2) A kampánynak van szerkesztője: a metaadatok módosíthatók, és meg
--      lehet adni, KI kapja meg a kérdőívet — kurzus, csoport vagy egyedi
--      felhasználó szintjén.
--
--  HOGYAN CÉLOZ
--  A célközönség két FÜGGETLEN kérdésre válaszol:
--    MIT értékelnek  -> 'course' sorok. Ha van ilyen, a kampány PONTOSAN
--                       ezeket a kurzusokat célozza. Ha nincs, marad a
--                       korábbi viselkedés: a félév minden kurzusa.
--    KI értékel      -> 'group' és 'user' sorok. Ha van ilyen, csak az így
--                       kijelölt hallgatók kapják meg. Ha nincs, mindenki,
--                       aki a kurzusra aktívan be van iratkozva.
--  A kettő szabadon kombinálható. Célközönség-sor nélkül a kampány pontosan
--  úgy viselkedik, mint eddig — a meglévő kampányok tehát nem változnak.
--
--  MIÉRT NEM EGY MEZŐ
--  Kísértés lett volna egyetlen 'hatókör' oszlopot tenni a kampányra. Azért
--  nem jó, mert a valódi kérdés kettő: egy kar kurzusait értékeltetni CSAK a
--  levelezős hallgatókkal két különböző szűrő, nem egy. Külön sorokban ez
--  természetes; egy mezőben kombinatorikus robbanás lenne.
--
--  ELŐFELTÉTEL: a RUN_ALL_41.sql már lefutott.
--  Idempotens.
-- ============================================================================


-- ------------------------------------------------------------
-- 1. A vázkampány: a sablonverzió és az ablak opcionális
-- ------------------------------------------------------------
alter table echo.campaign alter column template_version_id drop not null;
alter table echo.campaign alter column opens_at            drop not null;
alter table echo.campaign alter column closes_at           drop not null;

-- Fél ablak nincs. A meglévő echo_campaign_window_chk (closes_at > opens_at)
-- NULL-lal NEM bukik el (a NULL-eredmény átmegy a CHECK-en), tehát az
-- 'opens_at kitöltve, closes_at üres' állapot csendben megmaradna, és csak
-- a megnyitásnál derülne ki. Kimondjuk itt.
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'echo_campaign_window_both_ck'
                    and conrelid = 'echo.campaign'::regclass) then
    alter table echo.campaign add constraint echo_campaign_window_both_ck
      check ((opens_at is null) = (closes_at is null));
  end if;
end $$;


-- ------------------------------------------------------------
-- 2. A célközönség tábla
-- ------------------------------------------------------------
create table if not exists echo.campaign_audience (
  id          uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references echo.campaign(id) on delete cascade,
  kind        text not null check (kind in ('course','group','user')),
  -- Pontosan egy hivatkozás van kitöltve, a kind szerint. Külön oszlopok és
  -- nem egy szabad szöveges 'ref', hogy az idegen kulcs valódi legyen: egy
  -- törölt kurzus vagy csoport ne hagyjon maga után hivatkozást.
  course_id   uuid references echo.course(id)        on delete cascade,
  group_id    text references public.user_group(id)  on delete cascade,
  profile_id  uuid references public.profiles(id)    on delete cascade,
  added_by    uuid,
  added_at    timestamptz not null default now(),
  constraint campaign_audience_ref_ck check (
    (kind = 'course' and course_id  is not null and group_id is null and profile_id is null) or
    (kind = 'group'  and group_id   is not null and course_id is null and profile_id is null) or
    (kind = 'user'   and profile_id is not null and course_id is null and group_id is null))
);

create unique index if not exists campaign_audience_course_uidx
  on echo.campaign_audience (campaign_id, course_id)  where kind = 'course';
create unique index if not exists campaign_audience_group_uidx
  on echo.campaign_audience (campaign_id, group_id)   where kind = 'group';
create unique index if not exists campaign_audience_user_uidx
  on echo.campaign_audience (campaign_id, profile_id) where kind = 'user';
create index if not exists campaign_audience_campaign_idx
  on echo.campaign_audience (campaign_id);

-- RLS policy nélkül: a kliens az 'echo' sémát nem éri el, minden hozzáférés
-- SECURITY DEFINER RPC-n megy. Ez a második védvonal.
alter table echo.campaign_audience enable row level security;


-- ------------------------------------------------------------
-- 3. A célközönség feloldása hallgatókra
-- ------------------------------------------------------------
-- A 'group' sorokat itt oldjuk fel tagokra. NEM a public.group_members()-t
-- hívjuk, mert annak is_staff() kapuja van: az alkalmasság újraépítése
-- SECURITY DEFINER kontextusban fut, és nem akarunk a hívó szerepkörétől
-- függő eredményt. A logika ugyanaz, mint a groups_of()-ban, csak fordítva:
-- kézi csoportnál tagsági sor, szabály alapúnál a szabály illeszkedése.
create or replace function echo.audience_profiles(p_campaign uuid)
returns setof uuid
language sql stable
set search_path = echo, public, pg_temp
as $$
  select m.profile_id
    from public.user_group_member m
    join echo.campaign_audience a on a.group_id = m.group_id
   where a.campaign_id = p_campaign and a.kind = 'group'
  union
  select p.id
    from public.profiles p
    join echo.campaign_audience a
      on a.campaign_id = p_campaign and a.kind = 'group'
    join public.user_group g
      on g.id = a.group_id and g.tipus = 'szabaly'
   where public.group_rule_matches(g.szabaly, p.id)
  union
  select a.profile_id
    from echo.campaign_audience a
   where a.campaign_id = p_campaign and a.kind = 'user'
$$;


-- ------------------------------------------------------------
-- 3b. A napló irány-értékkészlete
-- ------------------------------------------------------------
-- A szerkesztés és a célközönség módosítása nem állapotváltás: sem előre, sem
-- vissza nem visz. Naplózni viszont KELL — pont ez az, amit egy auditor keres
-- ("ki cserélte ki a kérdőívet a kampány alatt"). A felület csak a 'vissza'
-- értéket vizsgálja külön, az új értékek ártalmatlanul átesnek rajta.
alter table echo.campaign_log drop constraint if exists echo_campaign_log_irany_chk;
alter table echo.campaign_log add constraint echo_campaign_log_irany_chk
  check (irany in ('elore','vissza','letrehozas','szerkesztes','celkozonseg'));


-- ------------------------------------------------------------
-- 4. Az alkalmassagi motor celkozonseg-tudatosan
-- ------------------------------------------------------------
-- A torzs a 15_echo_core.sql-bol szarmazik; a valtozas a v_has_course /
-- v_has_who ket agban van. Celkozonseg-sor nelkul a viselkedes valtozatlan.

create or replace function echo.eligibility_rebuild(p_campaign uuid)
returns table (
  eligible_pairs  integer,
  eligible_courses integer,
  excluded_courses integer,
  excluded_pairs   integer
)
language plpgsql
set search_path = echo, public, pg_temp
as $$
declare
  v_term      text;
  v_state     text;
  v_min_head  integer := (select value::integer from echo.setting where key = 'min_headcount');
  v_min_share numeric := (select value::numeric from echo.setting where key = 'min_share_pct');
  -- Celkozonseg: kulon a 'MIT' (kurzus) es a 'KI' (csoport/felhasznalo).
  v_has_course boolean;
  v_has_who    boolean;
begin
  select c.term, c.state into v_term, v_state from echo.campaign c where c.id = p_campaign;
  if v_term is null then
    raise exception 'ECHO: nincs ilyen kampany: %', p_campaign;
  end if;
  select exists (select 1 from echo.campaign_audience
                  where campaign_id = p_campaign and kind = 'course'),
         exists (select 1 from echo.campaign_audience
                  where campaign_id = p_campaign and kind in ('group','user'))
    into v_has_course, v_has_who;

  if v_state in ('sealed','published') then
    raise exception 'ECHO: lepecsetelt/kozzetett kampany alkalmassaga nem epitheto ujra (%).', v_state;
  end if;
  if v_state = 'open' then
    raise warning 'ECHO: NYITOTT kampany alkalmassagat epited ujra. A mar kiadott jegyek '
                  'kozul azok, amelyek kikerulo kurzusra szoltak, ervenytelenne valnak.';
  end if;

  delete from echo.eligibility   where campaign_id = p_campaign;
  delete from echo.exclusion_log where campaign_id = p_campaign;

  -- A kampány félévéhez tartozó kurzusok, a tényleges létszámmal.
  -- Ugyanabban a tranzakcioban ketszer hivva a temp tabla mar letezne.
  drop table if exists _echo_c;
  drop table if exists _echo_ok;
  drop table if exists _echo_who;
  create temporary table _echo_c on commit drop as
  select c.id                                   as course_id,
         coalesce(c.letszam, cnt.n, 0)          as headcount,
         c.van_orarendi_info,
         c.vizsgakurzus,
         coalesce(tc.n, 0)                      as teacher_count
    from echo.course c
    left join lateral (
      select count(*)::integer as n from echo.enrollment e
       where e.course_id = c.id and e.status = 'active') cnt on true
    left join lateral (
      select count(*)::integer as n from echo.course_teacher ct
       where ct.course_id = c.id) tc on true
   -- MIT ertekelnek. Kurzussor nelkul a felev minden kurzusa (a regi
   -- viselkedes); kurzussorral PONTOSAN a kijelolt kurzusok. A felev
   -- ilyenkor szandekosan nem szur tovabb: ha az admin nevesitette a
   -- kurzust, akkor azt akarja, nem a felev metszetet.
   where (    (v_has_course and c.id in (select a.course_id from echo.campaign_audience a
                                          where a.campaign_id = p_campaign and a.kind = 'course'))
          or (not v_has_course and c.term = v_term));

  -- --- kurzusszintű kizárások ---
  insert into echo.exclusion_log (campaign_id, course_id, teacher_id, rule_code, detail)
  select p_campaign, course_id, null, 'LETSZAM_ALATT',
         jsonb_build_object('letszam', headcount, 'kuszob', v_min_head)
    from _echo_c where headcount < v_min_head;

  insert into echo.exclusion_log (campaign_id, course_id, teacher_id, rule_code, detail)
  select p_campaign, course_id, null, 'NINCS_ORARENDI_INFO', '{}'::jsonb
    from _echo_c where van_orarendi_info = false;

  insert into echo.exclusion_log (campaign_id, course_id, teacher_id, rule_code, detail)
  select p_campaign, course_id, null, 'VIZSGAKURZUS', '{}'::jsonb
    from _echo_c where vizsgakurzus = true;

  insert into echo.exclusion_log (campaign_id, course_id, teacher_id, rule_code, detail)
  select p_campaign, course_id, null, 'NINCS_OKTATO', '{}'::jsonb
    from _echo_c where teacher_count = 0;

  -- KI ertekel. A tabla akkor is letrejon, ha ures — a lenti lekerdesek
  -- hivatkoznak ra, es a v_has_who feltetel nem garantaltan rovidzaras.
  create temporary table _echo_who on commit drop as
  select profile_id from echo.audience_profiles(p_campaign) as t(profile_id);
  create index on _echo_who (profile_id);

  -- --- a túlélő kurzusok ---
  create temporary table _echo_ok on commit drop as
  select course_id from _echo_c
   where headcount >= v_min_head
     and van_orarendi_info = true
     and vizsgakurzus = false
     and teacher_count > 0;

  -- --- pár szintű kizárás: oktatói óraarány ---
  insert into echo.exclusion_log (campaign_id, course_id, teacher_id, rule_code, detail)
  select p_campaign, ct.course_id, ct.teacher_id, 'OKTATOI_ARANY_ALATT',
         jsonb_build_object('share_pct', ct.share_pct, 'kuszob', v_min_share)
    from echo.course_teacher ct
    join _echo_ok o on o.course_id = ct.course_id
   where ct.share_pct < v_min_share;

  -- --- a véleményezhető párok ---
  insert into echo.eligibility (campaign_id, course_id, teacher_id, share_pct)
  select p_campaign, ct.course_id, ct.teacher_id, ct.share_pct
    from echo.course_teacher ct
    join _echo_ok o on o.course_id = ct.course_id
   where ct.share_pct >= v_min_share
  on conflict (campaign_id, course_id, teacher_id) do nothing;

  -- --- a részvételi napló vázának előállítása/frissítése ---
  -- Csak az 'eligible' jelzőt állítja; az attempted/submitted mezőkhöz nem nyúl,
  -- hogy egy újraépítés ne törölje a már megtörtént kitöltés nyomát.
  insert into echo.participation (campaign_id, course_id, student_key, eligible)
  select p_campaign, e.course_id, e.student_key, true
    from echo.enrollment e
    join echo.eligibility el on el.campaign_id = p_campaign and el.course_id = e.course_id
   where e.status = 'active'
     and (not v_has_who
          or exists (select 1 from _echo_who w where w.profile_id = e.student_key))
   group by e.course_id, e.student_key
  on conflict (campaign_id, course_id, student_key) do update set eligible = true;

  -- Ket okbol veszti el valaki a jogosultsagat: kikerult a kurzus, VAGY
  -- kikerult O maga a celkozonsegbol. A masodik nelkul egy szukitett
  -- ujraepites utan a regi cimzettek tovabbra is kitolthetnek.
  update echo.participation p set eligible = false
   where p.campaign_id = p_campaign
     and (    not exists (select 1 from echo.eligibility el
                           where el.campaign_id = p_campaign and el.course_id = p.course_id)
          or (v_has_who and not exists (select 1 from _echo_who w
                                         where w.profile_id = p.student_key)));

  return query
  select (select count(*)::integer from echo.eligibility where campaign_id = p_campaign),
         (select count(distinct course_id)::integer from echo.eligibility where campaign_id = p_campaign),
         (select count(distinct course_id)::integer from echo.exclusion_log
           where campaign_id = p_campaign and teacher_id is null),
         (select count(*)::integer from echo.exclusion_log
           where campaign_id = p_campaign and teacher_id is not null);
end $$;


-- ------------------------------------------------------------
-- 5. Az allapotgep elofeltetele: kerdoiv es ablak nelkul nincs indulas
-- ------------------------------------------------------------

create or replace function echo.campaign_precheck(p_campaign uuid, p_to text)
returns jsonb
language plpgsql stable
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c        echo.campaign%rowtype;
  r_from   int;
  r_to     int;
  v_tvst   text;
  v_elig   int;
  v_pend   int;
  v_part   int;
begin
  select * into c from echo.campaign where id = p_campaign;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;

  r_from := echo.campaign_state_rank(c.state);
  r_to   := echo.campaign_state_rank(p_to);

  if r_to < 0 then
    return jsonb_build_object('ok', false, 'kod', 'ECHO_BAD_STATE', 'forcolhato', false,
      'uzenet', format('ismeretlen celallapot: "%s".', p_to));
  end if;
  if r_to = r_from then
    return jsonb_build_object('ok', false, 'kod', 'ECHO_SAME_STATE', 'forcolhato', false,
      'uzenet', format('a kampany mar "%s" allapotban van.', c.state));
  end if;

  -- --- visszalépés ---
  if r_to < r_from then
    if r_from >= 4 then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_SEAL_IRREVERSIBLE', 'forcolhato', false,
        'uzenet', format('a kampany allapota "%s": a pecsetelés utan visszalepni nem lehet.', c.state));
    end if;
    if r_to < r_from - 1 then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_STATE_SKIP', 'forcolhato', false,
        'uzenet', format('visszafele is csak EGY lepes engedelyezett: "%s" utan "%s" kovetkezne.',
                         c.state, case r_from when 1 then 'draft' when 2 then 'open' else 'closed' end));
    end if;
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', format('visszalepes "%s" -> "%s" (naplozva).', c.state, p_to));
  end if;

  -- --- előrelépés: csak egy lépés ---
  if r_to > r_from + 1 then
    return jsonb_build_object('ok', false, 'kod', 'ECHO_STATE_SKIP', 'forcolhato', false,
      'uzenet', format('az allapotgep nem ugorhato at: "%s" utan "%s" kovetkezik, nem "%s".',
        c.state,
        case r_from when 0 then 'open' when 1 then 'closed' when 2 then 'processing'
                    when 3 then 'sealed' when 4 then 'published' else '-' end,
        p_to));
  end if;

  if p_to = 'open' then
    -- A VAZKAMPANY hatara. Kerdoiv nelkul es ablak nelkul letre lehet hozni
    -- a kampanyt (42_campaign_editor.sql), elinditani viszont nem. Egyik sem
    -- forcolhato: kerdoiv nelkul nincs mit kitolteni, ablak nelkul pedig az
    -- echo.is_open() sosem adna igazat, tehat a kampany 'open' allapotban is
    -- zarva maradna — a legrosszabb fajta hiba, mert nem latszik.
    if c.template_version_id is null then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_NO_TEMPLATE', 'forcolhato', false,
        'uzenet', 'a kampanyhoz nincs kerdoiv rendelve. Valassz sablonverziot a '
                  'kampanyszerkesztoben (echo_campaign_update), utana indithato.');
    end if;
    if c.opens_at is null or c.closes_at is null then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_NO_WINDOW', 'forcolhato', false,
        'uzenet', 'a kampanynak nincs kitoltesi ablaka. Ablak nelkul az echo.is_open() '
                  'sosem ad igazat, tehat a kampany "open" allapotban is zarva maradna.');
    end if;
    select tv.state into v_tvst from echo.template_version tv where tv.id = c.template_version_id;
    if coalesce(v_tvst, '') <> 'live' then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_TEMPLATE_NOT_LIVE', 'forcolhato', false,
        'uzenet', format('a kampany sablonverzioja "%s" allapotu; megnyitni csak "live" '
                         'verzioval lehet (echo_template_transition).', coalesce(v_tvst,'nincs')));
    end if;
    select count(*) into v_elig from echo.eligibility where campaign_id = p_campaign;
    if v_elig = 0 then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_NO_ELIGIBILITY', 'forcolhato', false,
        'uzenet', 'nincs egyetlen jogosultsagi sor sem: futtasd le eloszor az '
                  'echo_rebuild_eligibility()-t. Jogosultsagi lista nelkul a kampanyt '
                  'senki nem tudna kitolteni, es a kizarasi naplo is ures maradna.');
    end if;
    select count(*) into v_part from echo.participation
     where campaign_id = p_campaign and eligible;
    if v_part = 0 then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_NO_PARTICIPANT', 'forcolhato', false,
        'uzenet', 'nincs egyetlen jogosult hallgato sem. A jogosultsagi lista a '
                  'kurzus/oktato parokrol szol, a reszvetel viszont emberekrol: ha a '
                  'celkozonsegbe olyan csoport kerult, aminek nincs tagja, a kampany '
                  'megnyilna ugy, hogy senki nem tudna kitolteni.');
    end if;
    if now() >= c.closes_at then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_WINDOW_ELAPSED', 'forcolhato', true,
        'uzenet', format('a zarasi idopont (%s) mar elmult: a kampany megnyitasa utan '
                         'azonnal zarhato lenne. Kenyszeritessel megis megnyithato.', c.closes_at));
    end if;
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', format('%s jogosultsagi par, %s jogosult hallgato, eles sablonverzio.',
                       v_elig, v_part));
  end if;

  if p_to = 'closed' then
    if now() < c.closes_at then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_WINDOW_OPEN', 'forcolhato', true,
        'uzenet', format('a kitoltesi ablak %s-ig tart. Korai zaras csak kenyszeritessel '
                         '(p_force), mert a mar kiadott, el nem koltott jegyek ervenyuket vesztik.',
                         c.closes_at));
    end if;
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', 'a kitoltesi ablak lejart.');
  end if;

  if p_to = 'processing' then
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', 'a moderalasi sor feltoltese es a reszvetel lezarasa ekkor indul.');
  end if;

  if p_to = 'sealed' then
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', 'FIGYELEM: a pecsetelés VISSZAFORDITHATATLAN. Lefut az '
                'echo.shuffle_responses(), a valaszok fizikai sorrendje elbomlik.');
  end if;

  if p_to = 'published' then
    select count(*) into v_pend
      from echo.moderation m
      join echo.response r on r.id = m.response_id
     where r.campaign_id = p_campaign and m.allapot = 'pending';
    if v_pend > 0 then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_MODERATION_PENDING', 'forcolhato', true,
        'uzenet', format('%s moderalatlan szoveges valasz van meg a sorban. A kozzetetellel '
                         'ezek az oktatokhoz is eljutnanak. Kenyszeritessel megis kozzeteheto.', v_pend));
    end if;
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', 'a moderalasi sor ures: az eredmeny megnyithato a jogosulti kornek.');
  end if;

  return jsonb_build_object('ok', false, 'kod', 'ECHO_BAD_STATE', 'forcolhato', false,
    'uzenet', format('kezeletlen celallapot: "%s".', p_to));
end $$;


-- ------------------------------------------------------------
-- 6. echo_campaign_create — a kerdoiv es az ablak opcionalis
-- ------------------------------------------------------------

create or replace function public.echo_campaign_create(
  p_nev              text,
  p_term             text,
  p_template_version uuid        default null,
  p_opens_at         timestamptz default null,
  p_closes_at        timestamptz default null
) returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_nev    text := nullif(btrim(coalesce(p_nev, '')), '');
  v_term   text := nullif(btrim(coalesce(p_term, '')), '');
  v_tvst   text;
  v_tpl    text;
  v_code   text;
  v_base   text;
  v_n      int := 1;
  v_id     uuid;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  if v_nev is null then
    raise exception 'ECHO_NAME_EMPTY: a kampany neve nem lehet ures.';
  end if;
  if length(v_nev) > 160 then
    raise exception 'ECHO_NAME_TOO_LONG: a kampany neve legfeljebb 160 karakter.';
  end if;
  if v_term is null then
    raise exception 'ECHO_TERM_EMPTY: a felev jelolese nem lehet ures (pl. 2025/26/2).';
  end if;
  -- Az ablak mar nem kotelezo (vazkampany), de ha van, ervenyesnek kell lennie.
  if p_opens_at is not null and p_closes_at <= p_opens_at then
    raise exception 'ECHO_WINDOW_INVALID: a zaras (%) nem lehet a nyitas (%) elott vagy azzal egyido.',
      p_closes_at, p_opens_at;
  end if;

  -- A sablonverzió: 'live' vagy 'approved'.
  -- MIÉRT ENGEDJÜK AZ 'approved'-ot IS: a kampány létrehozása előkészítő
  -- művelet, a jóváhagyott verzió élesítése önálló, naplózott lépés
  -- (echo_template_transition). A MEGNYITÁS viszont már 'live'-ot követel —
  -- lásd echo.campaign_precheck(): ECHO_TEMPLATE_NOT_LIVE.
  -- A kerdoiv OPCIONALIS: vazkampany is letrehozhato, es a sablonverzio
  -- utolag is megadhato (echo_campaign_update). Amit nem engedunk, az a
  -- rossz sablon: ha kaptunk egyet, annak most is ervenyesnek kell lennie.
  -- Elinditani ugyis csak kerdoivvel lehet — azt a campaign_precheck orzi.
  if p_template_version is not null then
    select tv.state, t.name_hu into v_tvst, v_tpl
      from echo.template_version tv
      join echo.template t on t.id = tv.template_id
     where tv.id = p_template_version;
    if v_tvst is null then raise exception 'ECHO_VERSION_NOT_FOUND'; end if;
    if v_tvst not in ('live','approved') then
      raise exception 'ECHO_TEMPLATE_NOT_READY: a valasztott sablonverzio allapota "%", '
                      'kampanyhoz csak "approved" vagy "live" verzio hasznalhato.', v_tvst;
    end if;
  end if;

  -- Fel ablak nincs: vagy mindketto, vagy egyik sem.
  if (p_opens_at is null) <> (p_closes_at is null) then
    raise exception 'ECHO_HALF_WINDOW: a nyitasi es a zarasi idopontot egyutt kell megadni, '
                    'vagy egyiket sem. Ablak nelkul a kampany vazkent jon letre.';
  end if;


  -- Kód: emberi olvasásra, egyedi. Az echo.slug() a magyar ékezeteket is kezeli.
  -- A kereses+beszuras nem atomi: ket egyidejű letrehozas ugyanazt a kodot
  -- talalhatna szabadnak, es a masodik az echo_campaign_code_uidx-en hasalna
  -- el. Eddig ezt a felev-index takarta el (a masodik kampany ugyis elbukott);
  -- most, hogy egy felevre tobb kampany lehet, ez a verseny valodiva valt.
  -- Tranzakcio vegeig tarto tanacsado zar: a kampanyletrehozas ritka, a
  -- sorositas ara elhanyagolhato.
  perform pg_advisory_xact_lock(hashtextextended('echo_campaign_create', 0));
  v_base := 'OMHV-' || echo.slug(v_term);
  v_code := v_base;
  while exists (select 1 from echo.campaign where code = v_code) loop
    v_n := v_n + 1;
    v_code := v_base || '-' || v_n::text;
  end loop;

  insert into echo.campaign (code, name_hu, term, template_version_id, opens_at, closes_at, state)
  values (v_code, v_nev, v_term, p_template_version, p_opens_at, p_closes_at, 'draft')
  returning id into v_id;

  insert into echo.campaign_log (campaign_id, from_state, to_state, irany, actor_key, actor_email, detail)
  values (v_id, null, 'draft', 'letrehozas', auth.uid(),
          (select email from public.profiles where id = auth.uid()),
          jsonb_build_object('code', v_code, 'term', v_term,
                             'template_version_id', p_template_version,
                             'template', v_tpl, 'template_state', v_tvst));

  perform echo.log_access('echo_campaign_create', v_id, null, null, 'campaign');

  return jsonb_build_object(
    'id', v_id, 'code', v_code, 'name', v_nev, 'term', v_term, 'state', 'draft',
    'opens_at', p_opens_at, 'closes_at', p_closes_at,
    'template_version_id', p_template_version, 'template_state', v_tvst,
    'kovetkezo_lepes', 'echo_rebuild_eligibility() a jogosultsagi listahoz, majd megnyitas.');
end $$;

revoke all on function public.echo_campaign_create(text,text,uuid,timestamptz,timestamptz) from public;
grant execute on function public.echo_campaign_create(text,text,uuid,timestamptz,timestamptz) to authenticated;


-- ------------------------------------------------------------
-- 7. echo_campaign_update — a kampány metaadatainak szerkesztése
-- ------------------------------------------------------------
-- A NULL azt jelenti, hogy "hagyd békén" — nem azt, hogy "üresítsd". Üríteni
-- a p_clear tömbbel lehet ('template', 'window', 'goals', 'name_en'). Ugyanez
-- a minta, mint a student_attributes_save()-nél: enélkül nem lehetne
-- megkülönböztetni a "nem küldtem el" és a "töröld" esetet.
--
-- MIT LEHET MIKOR: 'draft' állapotban mindent. Futó kampányon (open/closed/
-- processing) CSAK a nevet — a kérdőív, a félév vagy az ablak menet közbeni
-- átírása a már beérkezett válaszokat értelmezhetetlenné tenné, mert az
-- echo.results_build() a KAMPÁNY sablonverziójából veszi a kérdéslistát,
-- a válaszsor viszont a sajátját őrzi. Lepecsételt kampányon semmit.
create or replace function public.echo_campaign_update(
  p_campaign         uuid,
  p_nev              text        default null,
  p_name_en          text        default null,
  p_term             text        default null,
  p_template_version uuid        default null,
  p_opens_at         timestamptz default null,
  p_closes_at        timestamptz default null,
  p_goals_open_at    timestamptz default null,
  p_goals_close_at   timestamptz default null,
  p_clear            text[]      default null
) returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c        echo.campaign%rowtype;
  v_clear  text[] := coalesce(p_clear, '{}'::text[]);
  v_tvst   text;
  v_teljes boolean;
  v_op     timestamptz;
  v_cl     timestamptz;
  v_go     timestamptz;
  v_gc     timestamptz;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  select * into c from echo.campaign where id = p_campaign for update;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;

  if c.state in ('sealed','published') then
    raise exception 'ECHO_SEAL_IRREVERSIBLE: lepecsetelt kampany adatai nem modosithatok.';
  end if;
  v_teljes := (c.state = 'draft');

  if not v_teljes and (p_term is not null or p_template_version is not null
                       or p_opens_at is not null or p_closes_at is not null
                       or p_goals_open_at is not null or p_goals_close_at is not null
                       or v_clear && array['template','window','goals']) then
    raise exception 'ECHO_CAMPAIGN_RUNNING: a kampany allapota "%", ilyenkor csak a NEVE '
                    'modosithato. A kerdoiv, a felev vagy az ablak menet kozbeni atirasa a '
                    'mar beerkezett valaszokat ertelmezhetetlenne tenne.', c.state;
  end if;

  -- --- az új értékek kiszámítása (null = marad, p_clear = ürül) ---
  v_op := case when 'window' = any(v_clear) then null else coalesce(p_opens_at,  c.opens_at)  end;
  v_cl := case when 'window' = any(v_clear) then null else coalesce(p_closes_at, c.closes_at) end;
  v_go := case when 'goals'  = any(v_clear) then null else coalesce(p_goals_open_at,  c.goals_open_at)  end;
  v_gc := case when 'goals'  = any(v_clear) then null else coalesce(p_goals_close_at, c.goals_close_at) end;

  if (v_op is null) <> (v_cl is null) then
    raise exception 'ECHO_HALF_WINDOW: a nyitasi es a zarasi idopontot egyutt kell megadni, '
                    'vagy egyiket sem.';
  end if;
  if v_op is not null and v_cl <= v_op then
    raise exception 'ECHO_WINDOW_INVALID: a zaras (%) nem lehet a nyitas (%) elott vagy azzal egyido.',
                    v_cl, v_op;
  end if;
  if (v_go is null) <> (v_gc is null) then
    raise exception 'ECHO_HALF_WINDOW: a celmeghatarozasi ablak ket vegpontja is kell, vagy egyik sem.';
  end if;
  if v_go is not null and v_gc <= v_go then
    raise exception 'ECHO_WINDOW_INVALID: a celmeghatarozasi ablak zarasa nem lehet a nyitas elott.';
  end if;

  -- A kérdőív: ha kapunk verziót, annak most is érvényesnek kell lennie.
  -- Élesítettséget NEM követelünk — azt az indításnál kéri a precheck, hogy
  -- a szerkesztő ne akadjon el egy még jóváhagyás alatt lévő verzión.
  if p_template_version is not null then
    select tv.state into v_tvst from echo.template_version tv where tv.id = p_template_version;
    if v_tvst is null then raise exception 'ECHO_VERSION_NOT_FOUND'; end if;
    if v_tvst not in ('live','approved') then
      raise exception 'ECHO_TEMPLATE_NOT_READY: a valasztott sablonverzio allapota "%", '
                      'kampanyhoz csak "approved" vagy "live" verzio hasznalhato.', v_tvst;
    end if;
  end if;

  update echo.campaign
     set name_hu             = coalesce(nullif(btrim(coalesce(p_nev,'')),''), name_hu),
         name_en             = case when 'name_en' = any(v_clear) then null
                                    else coalesce(nullif(btrim(coalesce(p_name_en,'')),''), name_en) end,
         term                = coalesce(nullif(btrim(coalesce(p_term,'')),''), term),
         template_version_id = case when 'template' = any(v_clear) then null
                                    else coalesce(p_template_version, template_version_id) end,
         opens_at            = v_op,
         closes_at           = v_cl,
         goals_open_at       = v_go,
         goals_close_at      = v_gc
   where id = p_campaign;

  insert into echo.campaign_log (campaign_id, from_state, to_state, irany, actor_key, actor_email, detail)
  values (p_campaign, c.state, c.state, 'szerkesztes', auth.uid(),
          (select email from public.profiles where id = auth.uid()),
          jsonb_build_object('clear', to_jsonb(v_clear),
                             'nev', p_nev, 'term', p_term,
                             'template_version_id', p_template_version,
                             'opens_at', p_opens_at, 'closes_at', p_closes_at));

  perform echo.log_access('echo_campaign_update', p_campaign, null, null, 'campaign');

  select * into c from echo.campaign where id = p_campaign;
  return jsonb_build_object(
    'id', c.id, 'code', c.code, 'name', c.name_hu, 'name_en', c.name_en,
    'term', c.term, 'state', c.state,
    'template_version_id', c.template_version_id,
    'opens_at', c.opens_at, 'closes_at', c.closes_at,
    'goals_open_at', c.goals_open_at, 'goals_close_at', c.goals_close_at,
    'indithato', (echo.campaign_precheck(p_campaign, 'open')->>'ok')::boolean,
    'indulas_akadalya', echo.campaign_precheck(p_campaign, 'open')->>'uzenet',
    'ok', true);
end $$;

revoke all on function public.echo_campaign_update(uuid,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,text[]) from public;
grant execute on function public.echo_campaign_update(uuid,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,text[]) to authenticated;


-- ------------------------------------------------------------
-- 8. A célközönség olvasása — a szerkesztő ebből dolgozik
-- ------------------------------------------------------------
-- A becslés FELSŐ KORLÁT. A kizárási szabályok (létszám alatt, nincs órarendi
-- info, vizsgakurzus, nincs oktató, oktatói óraarány) csak az alkalmasság
-- újraépítésekor futnak le — itt szándékosan nem futtatjuk, mert a szerkesztő
-- minden gépelésre hívná. Ezért a mező neve 'legfeljebb', nem 'pontosan'.
create or replace function public.echo_campaign_audience(p_campaign uuid)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c          echo.campaign%rowtype;
  v_sorok    jsonb;
  v_has_c    boolean;
  v_has_w    boolean;
  v_kurzus   int;
  v_hallgato int;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  select * into c from echo.campaign where id = p_campaign;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;

  select coalesce(jsonb_agg(x order by x->>'kind', x->>'cimke'), '[]'::jsonb) into v_sorok
  from (
    select jsonb_build_object(
             'id', a.id, 'kind', a.kind,
             'ref', coalesce(a.course_id::text, a.group_id, a.profile_id::text),
             'cimke', case a.kind
                        when 'course' then k.code || ' · ' || k.name_hu
                        when 'group'  then g.nev
                        else coalesce(pr.name, pr.email) end,
             'reszlet', case a.kind
                          when 'course' then k.term
                          when 'group'  then g.tipus
                          else pr.email end) as x
      from echo.campaign_audience a
      left join echo.course       k  on k.id  = a.course_id
      left join public.user_group g  on g.id  = a.group_id
      left join public.profiles   pr on pr.id = a.profile_id
     where a.campaign_id = p_campaign
  ) s;

  v_has_c := exists (select 1 from echo.campaign_audience
                      where campaign_id = p_campaign and kind = 'course');
  v_has_w := exists (select 1 from echo.campaign_audience
                      where campaign_id = p_campaign and kind in ('group','user'));

  -- Felső korlát: hány kurzus és hány ember esne bele a kizárási szabályok előtt.
  with cel as (
    select k.id from echo.course k
     where (    (v_has_c and k.id in (select course_id from echo.campaign_audience
                                       where campaign_id = p_campaign and kind = 'course'))
            or (not v_has_c and k.term = c.term))
  )
  select count(*) into v_kurzus from cel;

  with cel as (
    select k.id from echo.course k
     where (    (v_has_c and k.id in (select course_id from echo.campaign_audience
                                       where campaign_id = p_campaign and kind = 'course'))
            or (not v_has_c and k.term = c.term))
  )
  select count(distinct e.student_key) into v_hallgato
    from echo.enrollment e join cel on cel.id = e.course_id
   where e.status = 'active'
     and (not v_has_w or e.student_key in (select echo.audience_profiles(p_campaign)));

  return jsonb_build_object(
    'campaign_id', p_campaign, 'state', c.state, 'term', c.term,
    -- A szerkesztheto mezok EGYBEN. A szerkeszto igy egyetlen hivasbol
    -- felepul: az echo_campaigns() nem ad name_en-t, az echo_campaign_get()
    -- pedig a celmeghatarozasi ablakot nem adja vissza. Ket forrasbol
    -- osszerakni egy urlapot annyit jelent, hogy a ket forras el is tud
    -- csuszni egymastol.
    'kampany', jsonb_build_object(
      'id', c.id, 'code', c.code, 'name', c.name_hu, 'name_en', c.name_en,
      'term', c.term, 'state', c.state,
      'template_version_id', c.template_version_id,
      'opens_at', c.opens_at, 'closes_at', c.closes_at,
      'goals_open_at', c.goals_open_at, 'goals_close_at', c.goals_close_at),
    'sorok', v_sorok,
    'kurzus_szukitve', v_has_c,
    'hallgato_szukitve', v_has_w,
    'legfeljebb_kurzus', v_kurzus,
    'legfeljebb_hallgato', v_hallgato,
    'megjegyzes', 'A szamok FELSO KORLATOT jelentenek: a kizarasi szabalyok '
               || '(letszam, orarendi info, vizsgakurzus, oktatoi oraarany) csak az '
               || 'alkalmassag ujraepitesekor futnak le.');
end $$;


-- ------------------------------------------------------------
-- 9. A célközönség beállítása
-- ------------------------------------------------------------
-- CSAK 'draft' állapotban. Futó kampányon a célközönség átírása a már kiadott
-- jegyeket tenné érvénytelenné: aki tegnap még jogosult volt és elkezdte
-- kitölteni, ma nem tudná befejezni. Ez nem elméleti — az echo_issue_ticket()
-- a participation sorra támaszkodik.
--
-- A p_items alakja: [{"kind":"course","id":"<uuid>"}, {"kind":"group","id":"GRP..."},
--                    {"kind":"user","id":"<uuid>"}]
-- A hívás CSERÉL, nem hozzáad: ami nincs a listában, az kikerül.
create or replace function public.echo_campaign_audience_set(p_campaign uuid, p_items jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c      echo.campaign%rowtype;
  v_it   jsonb;
  v_kind text;
  v_id   text;
  v_n    int := 0;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  select * into c from echo.campaign where id = p_campaign for update;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;
  if c.state <> 'draft' then
    raise exception 'ECHO_CAMPAIGN_RUNNING: a celkozonseg csak "draft" allapotban '
                    'modosithato (a kampany most "%"). Futo kampanyon a mar kiadott '
                    'jegyek valnanak ervenytelenne.', c.state;
  end if;
  if p_items is not null and jsonb_typeof(p_items) <> 'array' then
    raise exception 'ECHO_BAD_INPUT: a p_items tomb kell legyen.';
  end if;

  delete from echo.campaign_audience where campaign_id = p_campaign;

  for v_it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_kind := v_it->>'kind';
    v_id   := v_it->>'id';
    if coalesce(v_id, '') = '' then
      raise exception 'ECHO_BAD_INPUT: hianyzo azonosito a "%s" tetelnel.', v_kind;
    end if;

    if v_kind = 'course' then
      if not exists (select 1 from echo.course where id = v_id::uuid) then
        raise exception 'ECHO_COURSE_NOT_FOUND: %', v_id;
      end if;
      insert into echo.campaign_audience (campaign_id, kind, course_id, added_by)
      values (p_campaign, 'course', v_id::uuid, auth.uid())
      on conflict do nothing;

    elsif v_kind = 'group' then
      if not exists (select 1 from public.user_group where id = v_id) then
        raise exception 'ECHO_GROUP_NOT_FOUND: %', v_id;
      end if;
      insert into echo.campaign_audience (campaign_id, kind, group_id, added_by)
      values (p_campaign, 'group', v_id, auth.uid())
      on conflict do nothing;

    elsif v_kind = 'user' then
      if not exists (select 1 from public.profiles where id = v_id::uuid) then
        raise exception 'ECHO_PROFILE_NOT_FOUND: %', v_id;
      end if;
      insert into echo.campaign_audience (campaign_id, kind, profile_id, added_by)
      values (p_campaign, 'user', v_id::uuid, auth.uid())
      on conflict do nothing;

    else
      raise exception 'ECHO_BAD_INPUT: ismeretlen celkozonseg-tipus: "%". '
                      'Ervenyes: course, group, user.', coalesce(v_kind, '(null)');
    end if;
    v_n := v_n + 1;
  end loop;

  insert into echo.campaign_log (campaign_id, from_state, to_state, irany, actor_key, actor_email, detail)
  values (p_campaign, c.state, c.state, 'celkozonseg', auth.uid(),
          (select email from public.profiles where id = auth.uid()),
          jsonb_build_object('tetel', v_n, 'items', coalesce(p_items, '[]'::jsonb)));

  perform echo.log_access('echo_campaign_audience_set', p_campaign, null, null, 'campaign');
  return public.echo_campaign_audience(p_campaign);
end $$;


-- ------------------------------------------------------------
-- 10. Választható tételek a szerkesztőnek
-- ------------------------------------------------------------
create or replace function public.echo_audience_options(
  p_campaign uuid,
  p_kind     text,
  p_q        text default null,
  p_limit    int  default 50
) returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c     echo.campaign%rowtype;
  v_q   text := nullif(btrim(coalesce(p_q, '')), '');
  v_lim int  := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_out jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  select * into c from echo.campaign where id = p_campaign;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;

  if p_kind = 'course' then
    -- Alapból a kampány félévének kurzusai. Keresésnél a félévtől eltekintünk:
    -- ha az admin rákeres, akkor tudja, mit keres.
    select coalesce(jsonb_agg(x order by x->>'cimke'), '[]'::jsonb) into v_out
    from (
      select jsonb_build_object('id', k.id, 'cimke', k.code || ' · ' || k.name_hu,
                                'reszlet', k.term || ' · ' ||
                                  (select count(*) from echo.enrollment e
                                    where e.course_id = k.id and e.status='active')::text || ' fo') as x
        from echo.course k
       where (v_q is null and k.term = c.term)
          or (v_q is not null and (k.code ilike '%'||v_q||'%' or k.name_hu ilike '%'||v_q||'%'))
       order by k.code
       limit v_lim
    ) s;

  elsif p_kind = 'group' then
    select coalesce(jsonb_agg(x order by x->>'cimke'), '[]'::jsonb) into v_out
    from (
      select jsonb_build_object('id', g.id, 'cimke', g.nev,
                                'reszlet', g.tipus || ' · ' ||
                                  (select count(*) from public.profiles p
                                    where (g.tipus='kezi' and exists (
                                             select 1 from public.user_group_member m
                                              where m.group_id=g.id and m.profile_id=p.id))
                                       or (g.tipus='szabaly' and public.group_rule_matches(g.szabaly, p.id))
                                  )::text || ' fo') as x
        from public.user_group g
       where v_q is null or g.nev ilike '%'||v_q||'%'
       order by g.nev
       limit v_lim
    ) s;

  elsif p_kind = 'user' then
    select coalesce(jsonb_agg(x order by x->>'cimke'), '[]'::jsonb) into v_out
    from (
      select jsonb_build_object('id', p.id, 'cimke', coalesce(p.name, p.email),
                                'reszlet', p.email) as x
        from public.profiles p
       where p.role = 'STUDENT'
         and (v_q is null or p.email ilike '%'||v_q||'%' or coalesce(p.name,'') ilike '%'||v_q||'%')
       order by coalesce(p.name, p.email)
       limit v_lim
    ) s;

  else
    raise exception 'ECHO_BAD_INPUT: ismeretlen tipus: "%". Ervenyes: course, group, user.',
                    coalesce(p_kind, '(null)');
  end if;

  return v_out;
end $$;

revoke all on function public.echo_campaign_audience(uuid) from public;
revoke all on function public.echo_campaign_audience_set(uuid,jsonb) from public;
revoke all on function public.echo_audience_options(uuid,text,text,int) from public;
grant execute on function public.echo_campaign_audience(uuid)              to authenticated;
grant execute on function public.echo_campaign_audience_set(uuid,jsonb)    to authenticated;
grant execute on function public.echo_audience_options(uuid,text,text,int) to authenticated;




-- ------------------------------------------------------------
-- 11. Jogosultságok — nevesítve, nem a PUBLIC-on keresztül
-- ------------------------------------------------------------
-- MIÉRT KÜLÖN BLOKK: a Supabase alapértelmezett jogosultsága (alter default
-- privileges ... grant execute on functions to anon) minden ÚJ public sémabeli
-- függvényre ad EXECUTE-ot az 'anon' szerepnek. A 'revoke ... from public' ezt
-- NEM veszi el, mert az anon jog KÜLÖN bejegyzés, nem a PUBLIC-on keresztül
-- öröklődik. Mérés mutatta meg: a fenti revoke/grant párok után az anon
-- továbbra is hívhatta mind a négyet. Ezek a függvények belül is admin-kaput
-- kérnek, tehát az anon hívás úgyis elbukna — de a jog és a felület határát
-- egy helyen tartjuk, nem két rétegben.
do $jog$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('echo_campaign_create','echo_campaign_update',
                         'echo_campaign_audience','echo_campaign_audience_set',
                         'echo_audience_options')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon',   f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end
$jog$;



-- ===========================================================================
-- >>> 21_echo_harden_submit.sql
-- ===========================================================================
-- ============================================================
-- UniPortal Pro — ECHO: az anonim beküldés jogosultságának lezárása
-- ------------------------------------------------------------
-- MIÉRT KELL:
--   Az ECHO anonimitásának egyik tartóoszlopa, hogy a beküldés NEM a hallgató
--   munkamenetével fut: az echo_submit() kizárólag 'anon' joggal hívható, így
--   egy JWT-t hordozó kérés jogosultsági hibával elhasal, és a hallgató
--   azonosítója nem kerül a tranzakciós naplóba és a platform edge-logjába.
--
--   A 15_echo_core.sql ezt CSAK azzal éri el, hogy megadja a jogot az anon-nak
--   (1712. sor) — de SOHA NEM VONJA VISSZA az authenticated-tól. A Supabase
--   alapértelmezett jogosztása (alter default privileges … grant execute on
--   functions to anon, authenticated, service_role) viszont MINDEN új publikus
--   függvényre ad authenticated végrehajtási jogot. Ha ez a projekten él, akkor
--   az echo_submit bejelentkezve is hívható, és a garancia csendben elveszik.
--
--   MÉRVE: egy tiszta adatbázison, ahol a migrációk UTÁN lefutott egy tömeges
--   'grant all on all functions in schema public to anon, authenticated' —
--   ami pontosan azt utánozza, amit a platform tesz —, az echo_submit
--   jogosultsága 'anon=X authenticated=X service_role=X' lett.
--
-- MIT CSINÁL:
--   Visszavonja a végrehajtási jogot mindenkitől, majd kizárólag az anon-nak adja
--   vissza. Beállítja az alapértelmezett jogosztást is, hogy egy jövőbeli
--   platform-művelet ne nyissa vissza. A végén ellenőriz.
--
-- FUTTATÁSI SORREND: ez az UTOLSÓ migráció. Minden alkalommal futtasd újra,
-- amikor bármilyen új ECHO-migráció felment.
--
-- Idempotens — biztonságosan újrafuttatható, és futtatandó MINDEN olyan
-- alkalommal, amikor új ECHO-migráció ment fel.
-- ============================================================

-- ---------- 1. a beküldő függvény lezárása ----------
do $$
declare fn text;
begin
  for fn in
    select p.oid::regprocedure::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'echo_submit'
  loop
    execute format('revoke all on function %s from public, authenticated, service_role', fn);
    execute format('grant execute on function %s to anon', fn);
    raise notice 'Lezarva es anon-ra szukitve: %', fn;
  end loop;
end $$;

-- ---------- 2. a jegykiadó marad authenticated ----------
-- Ez SZÁNDÉKOSAN azonosított: itt még nincs válasz, tehát nincs mit korrelálni.
do $$
declare fn text;
begin
  for fn in
    select p.oid::regprocedure::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'echo_issue_ticket'
  loop
    execute format('revoke all on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end $$;

-- ---------- 3. ellenőrzés ----------
with a as (
  select p.proname,
         coalesce(array_to_string(p.proacl, ' '), '(alapertelmezett)') as acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('echo_submit', 'echo_issue_ticket')
)
select proname as fuggveny, acl,
       case
         when proname = 'echo_submit'
           then case when acl like '%anon=X%' and acl not like '%authenticated=X%'
                     then 'OK — csak anon' else '*** BAJ: bejelentkezve is hivhato ***' end
         when proname = 'echo_issue_ticket'
           then case when acl like '%authenticated=X%' and acl not like '%anon=X%'
                     then 'OK — csak authenticated' else '*** BAJ ***' end
       end as allapot
from a order by proname;






-- ===========================================================================
-- A POSTGREST SÉMA-GYORSÍTÓTÁRÁNAK FRISSÍTÉSE
-- ===========================================================================
-- A PostgREST gyorsítótárazza, milyen függvények léteznek, és rendszerint
-- magától frissíti DDL után — de ez késhet vagy kimaradhat. Ilyenkor a
-- felület "Could not find the function ... in the schema cache" (PGRST202)
-- hibát ad egy olyan függvényre, ami VALÓJÁBAN létezik. Egy valós
-- bejelentésnél pontosan ez történt az echo_my_enrollments()-szel.
-- Ártalmatlan akkor is, ha nem volt rá szükség.
notify pgrst, 'reload schema';


-- ============================================================================
--  ELLENŐRZÉS — futtasd le, és küldd vissza a táblát
-- ============================================================================
select 'a kerdoiv opcionalis lett' as mit_ellenorzunk,
       case when is_nullable='YES' then 'nullable' else 'NOT NULL' end as ertek,
       case when is_nullable='YES' then 'OK' else 'HIBA' end as allapot
  from information_schema.columns
 where table_schema='echo' and table_name='campaign' and column_name='template_version_id'
union all
select 'az ablak opcionalis lett',
       case when count(*) filter (where is_nullable='YES') = 2 then 'mindketto nullable'
            else 'meg NOT NULL' end,
       case when count(*) filter (where is_nullable='YES') = 2 then 'OK' else 'HIBA' end
  from information_schema.columns
 where table_schema='echo' and table_name='campaign' and column_name in ('opens_at','closes_at')
union all
select 'fel ablak nem lehet',
       coalesce((select 'megvan' from pg_constraint
                  where conname='echo_campaign_window_both_ck'), '(nincs)'),
       case when exists (select 1 from pg_constraint where conname='echo_campaign_window_both_ck')
            then 'OK' else 'HIBA' end
union all
select 'celkozonseg tabla',
       coalesce((select 'megvan, '||count(*)::text||' sor' from echo.campaign_audience), '(nincs)'),
       case when exists (select 1 from information_schema.tables
                          where table_schema='echo' and table_name='campaign_audience')
            then 'OK' else 'HIBA' end
union all
select 'RLS a celkozonseg tablan',
       case when relrowsecurity then 'be' else 'ki' end,
       case when relrowsecurity then 'OK' else 'HIBA' end
  from pg_class where oid='echo.campaign_audience'::regclass
union all
select 'inditas kerdoiv nelkul tiltva',
       case when prosrc like '%ECHO_NO_TEMPLATE%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%ECHO_NO_TEMPLATE%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='echo' and p.proname='campaign_precheck'
union all
select 'inditas kitolto nelkul tiltva',
       case when prosrc like '%ECHO_NO_PARTICIPANT%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%ECHO_NO_PARTICIPANT%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='echo' and p.proname='campaign_precheck'
union all
select 'az alkalmassag celkozonseg-tudatos',
       case when prosrc like '%v_has_who%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%v_has_who%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='echo' and p.proname='eligibility_rebuild'
union all
select 'uj RPC: '||p.proname,
       coalesce(array_to_string(p.proacl,' '), '(nincs kulon jog)'),
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'OK — csak authenticated'
            when has_function_privilege('anon', p.oid, 'EXECUTE') then 'HIBA — anon is hivhatja'
            else 'HIBA — authenticated nem hivhatja' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public'
   and p.proname in ('echo_campaign_update','echo_campaign_audience',
                     'echo_campaign_audience_set','echo_audience_options')
union all
select 'naplo iranyertekek',
       (select string_agg(x,',') from unnest(string_to_array(
          replace(replace(pg_get_constraintdef(oid),'CHECK ((irany = ANY (ARRAY[',''),
          ']::text[])))',''), ',')) x
        where x like '%szerkesztes%' or x like '%celkozonseg%'),
       case when pg_get_constraintdef(oid) like '%szerkesztes%'
             and pg_get_constraintdef(oid) like '%celkozonseg%' then 'OK' else 'HIBA' end
  from pg_constraint where conname='echo_campaign_log_irany_chk';
