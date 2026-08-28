-- ============================================================================
-- RUN_ALL_45_46.sql — UniPortal
--
--   45_audience_preview.sql    a célközönség becslése MENTÉS ELŐTT, és a
--                              mentés mostantól újra is építi az alkalmasságot
--   46_readonly_rpc_fix.sql    "cannot execute INSERT in a read-only transaction"
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--   + a végén MINDKÉT MODUL ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a RUN_ALL_44.sql már lefutott.
-- Idempotens. Adatot nem módosít.
--
-- MIT JAVÍT:
--   1. A kampányszerkesztőben a "hány hallgató kapja meg" szám mostantól
--      választás közben frissül, nem csak mentés és visszanyitás után.
--   2. A célközönség mentése azonnal újraépíti az alkalmasságot, így a kampány
--      "Jogosult hallgató" száma is rögtön a valóságot mutatja.
--   3. Az ECHO kampánykezelés oldalán jelentkező
--      "cannot execute INSERT in a read-only transaction" hiba.
-- ============================================================================


-- ============================================================================
--  45_audience_preview.sql — UniPortal / ECHO
--  A CÉLKÖZÖNSÉG BECSLÉSE MENTÉS ELŐTT
-- ============================================================================
--
--  MI A BAJ A MOSTANIVAL
--  Az echo_campaign_audience() a MENTETT sorokból számol, ezért a szerkesztőben
--  a "legfeljebb X kurzus · Y hallgató" csak mentés és visszanyitás után
--  frissült. Aki épp kijelöl egy csoportot, pont akkor nem látja, hány embert
--  érint — vagyis a szám akkor hiányzik, amikor a döntés születik.
--
--  MIÉRT ÚJ FÜGGVÉNY, ÉS NEM PARAMÉTER A RÉGIN
--  Az echo_campaign_audience() egy paraméterrel bővítve ÚJ függvényt hozna
--  létre a régi mellett (a plpgsql nem cseréli le eltérő szignatúrán), és a
--  PostgREST a névre illesztve nem tudná eldönteni, melyiket hívja. Ugyanez a
--  csapda ütött a 44-esben az echo_course_students()-nél.
--
--  A SZÁM ITT IS FELSŐ KORLÁT: a kizárási szabályok (létszám, órarendi info,
--  vizsgakurzus, oktatói óraarány) csak az alkalmasság újraépítésekor futnak.
--
--  ELŐFELTÉTEL: a RUN_ALL_42.sql már lefutott. Idempotens, csak olvas.
-- ============================================================================

create or replace function public.echo_audience_preview(p_campaign uuid, p_items jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c          echo.campaign%rowtype;
  v_courses  uuid[];
  v_groups   text[];
  v_users    uuid[];
  v_who      uuid[];
  v_has_c    boolean;
  v_has_w    boolean;
  v_kurzus   int;
  v_hallgato int;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  select * into c from echo.campaign where id = p_campaign;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;
  if p_items is not null and jsonb_typeof(p_items) <> 'array' then
    raise exception 'ECHO_BAD_INPUT: a p_items tomb kell legyen.';
  end if;

  -- HÁROM KÜLÖN lekérdezés, nem egy 'filter'-es aggregátum. A csoport
  -- azonosítója szöveg ('GRP...'), a kurzusé és a felhasználóé uuid: egyetlen
  -- SELECT-ben a ::uuid kasztolás a csoportsorokon is lefuthatna a FILTER
  -- előtt, és elhasalna. A sima WHERE viszont a sorokat AZ aggregátum
  -- kiértékelése előtt szűri ki.
  select coalesce(array_agg((x->>'id')::uuid), '{}'::uuid[]) into v_courses
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
   where x->>'kind' = 'course' and coalesce(x->>'id','') <> '';

  select coalesce(array_agg(x->>'id'), '{}'::text[]) into v_groups
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
   where x->>'kind' = 'group' and coalesce(x->>'id','') <> '';

  select coalesce(array_agg((x->>'id')::uuid), '{}'::uuid[]) into v_users
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
   where x->>'kind' = 'user' and coalesce(x->>'id','') <> '';

  v_has_c := coalesce(array_length(v_courses, 1), 0) > 0;
  v_has_w := coalesce(array_length(v_groups, 1), 0) > 0
             or coalesce(array_length(v_users, 1), 0) > 0;

  -- A 'KI' halmaz ugyanúgy áll össze, mint az echo.audience_profiles()-ban,
  -- csak a mentett sorok helyett a javasolt listából. Kézi csoportnál tagsági
  -- sor, szabály alapúnál a szabály illeszkedése.
  select coalesce(array_agg(distinct s.id), '{}'::uuid[]) into v_who
    from (
      select m.profile_id as id
        from public.user_group_member m
       where m.group_id = any(v_groups)
      union
      select p.id
        from public.profiles p
        join public.user_group g on g.id = any(v_groups) and g.tipus = 'szabaly'
       where public.group_rule_matches(g.szabaly, p.id)
      union
      select u from unnest(v_users) u
    ) s
   where s.id is not null;

  with cel as (
    select k.id from echo.course k
     where (    (v_has_c and k.id = any(v_courses))
            or (not v_has_c and k.term = c.term))
  )
  select count(*) into v_kurzus from cel;

  with cel as (
    select k.id from echo.course k
     where (    (v_has_c and k.id = any(v_courses))
            or (not v_has_c and k.term = c.term))
  )
  select count(distinct e.student_key) into v_hallgato
    from echo.enrollment e join cel on cel.id = e.course_id
   where e.status = 'active'
     and (not v_has_w or e.student_key = any(v_who));

  return jsonb_build_object(
    'campaign_id', p_campaign, 'term', c.term,
    'kurzus_szukitve', v_has_c,
    'hallgato_szukitve', v_has_w,
    'legfeljebb_kurzus', v_kurzus,
    'legfeljebb_hallgato', v_hallgato,
    -- A feloldott létszám külön is: egy szabály alapú csoportnál ez mondja meg,
    -- hogy egyáltalán hány emberre illeszkedik a szabály — akkor is, ha közülük
    -- senki nincs beiratkozva a célzott kurzusokra. A kettő eltérése magyaráz.
    'celzott_szemely', coalesce(array_length(v_who, 1), 0),
    'megjegyzes', 'FELSO KORLAT: a kizarasi szabalyok csak az alkalmassag '
               || 'ujraepitesekor futnak le.');
end $$;

do $jog$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'echo_audience_preview'
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon',   f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end
$jog$;



-- ------------------------------------------------------------
--  A célközönség mentése ÉPÍTSE ÚJRA az alkalmasságot
-- ------------------------------------------------------------
-- A törzs a 42_campaign_editor.sql-ből származik; a változás a végén az
-- eligibility_rebuild() hívása.

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

  -- AZONNAL ujraepitjuk az alkalmassagot. Enelkul a kampany "Jogosult par" es
  -- "Jogosult hallgato" szamai a MENTES UTAN IS a regi celkozonseget mutatjak,
  -- mert azok az echo.eligibility / echo.participation tablakbol jonnek, azokat
  -- pedig kizarolag az eligibility_rebuild() irja. A felhasznalo joggal hiszi,
  -- hogy nem tortent semmi.
  -- Biztonsagos: ez a fuggveny csak 'draft' allapotban fut le (lasd fent),
  -- tehat nincs meg kiadott jegy, amit ervenytelenithetne.
  perform echo.eligibility_rebuild(p_campaign);

  return public.echo_campaign_audience(p_campaign);
end $$;




-- ============================================================================
--  46_readonly_rpc_fix.sql — UniPortal
--  "cannot execute INSERT in a read-only transaction"
-- ============================================================================
--
--  A TÜNET
--  Az ECHO kampánykezelés oldalán egy kampányra kattintva a rendszer ezt írta
--  ki: "cannot execute INSERT in a read-only transaction".
--
--  AZ OK
--  A PostgREST a STABLE és IMMUTABLE függvényeket CSAK OLVASHATÓ tranzakcióban
--  futtatja — ez a deklarált volatilitás értelme. Öt függvény viszont
--  STABLE-nek van jelölve, KÖZBEN hozzáférés-naplót ír (echo.log_access /
--  dorm.log_access, ami INSERT). A naplózás nem "olvasás", tehát a
--  volatilitás-jelölés volt hibás, nem a naplózás.
--
--  Ez RÉGI hiba (a 18a és a 26-os migrációból), nem most keletkezett. Eddig
--  azért nem tűnt fel, mert nem minden PostgREST-verzió kényszeríti ki a
--  csak-olvasható tranzakciót ugyanúgy.
--
--  A JAVÍTÁS
--  A törzsükhöz nem nyúlunk — csak a volatilitást írjuk át VOLATILE-ra. Ez
--  soha nem ronthat el semmit: a VOLATILE a legkevesebbet feltételező jelölés,
--  a tervező csak kevesebb rövidítést enged meg magának. A hívás módja nem
--  változik (a kliens POST-tal hív, nem GET-tel).
--
--  MIÉRT NEM A NAPLÓZÁST VESSZÜK KI: a hozzáférés-napló pont arra való, hogy
--  a LEKÉRDEZÉS is nyomot hagyjon. Egy kampány adatlapjának megnyitása
--  személyes adatokhoz való hozzáférés — ennek látszania kell.
--
--  Idempotens. Csak metaadatot módosít.
-- ============================================================================

do $fix$
declare f record; n int := 0;
begin
  for f in
    select p.oid, p.oid::regprocedure as sig, n.nspname||'.'||p.proname as nev
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('echo_campaign_get', 'dorm_free_beds', 'dorm_my_placement',
                         'dorm_occupancy_summary', 'dorm_open_issues')
       and p.provolatile in ('s', 'i')
  loop
    execute format('alter function %s volatile', f.sig);
    raise notice 'ECHO 46: % -> volatile', f.nev;
    n := n + 1;
  end loop;
  if n = 0 then
    raise notice 'ECHO 46: nem volt mit javitani (mar mind volatile).';
  end if;
end
$fix$;



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
--  ELLENŐRZÉS
-- ============================================================================
select 'echo_audience_preview letezik' as mit_ellenorzunk,
       count(*)::text||' valtozat' as ertek,
       case when count(*) = 1 then 'OK' else 'HIBA' end as allapot
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_audience_preview'
union all
select 'csak authenticated hivhatja',
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon is' else 'csak authenticated' end,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_audience_preview'
union all
select 'a celkozonseg mentese ujraepiti az alkalmassagot',
       case when prosrc like '%eligibility_rebuild(p_campaign)%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%eligibility_rebuild(p_campaign)%' then 'OK'
            else 'HIBA — a Jogosult hallgato szam nem frissulne' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_campaign_audience_set'
union all
select 'stable (nem ir)',
       case when p.provolatile = 's' then 'stable' else 'volatile' end,
       case when p.provolatile = 's' then 'OK' else 'HIBA — irhatna' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_audience_preview';


-- ============================================================================
--  ELLENŐRZÉS — futtasd le, és küldd vissza a táblát
-- ============================================================================
select 'javitott fuggveny: '||p.proname as mit_ellenorzunk,
       case p.provolatile when 'v' then 'volatile'
                          when 's' then 'stable' else 'immutable' end as ertek,
       case when p.provolatile = 'v' then 'OK' else 'HIBA — meg mindig read-only' end as allapot
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public'
   and p.proname in ('echo_campaign_get','dorm_free_beds','dorm_my_placement',
                     'dorm_occupancy_summary','dorm_open_issues')
union all
select 'maradt-e IRO stable/immutable fuggveny barhol',
       count(*)::text||' db',
       case when count(*) = 0 then 'OK' else 'HIBA — lasd a nevet a kovetkezo sorokban' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where p.provolatile in ('s','i')
   and n.nspname not in ('pg_catalog','information_schema','extensions','graphql','pgbouncer')
   and exists (select 1 from unnest(string_to_array(p.prosrc, e'\n')) l
                where (l ~* '\mlog_access\M' or l ~* '\minsert into\M'
                       or l ~* '\mdelete from\M' or l ~* '^\s*update\s+\w')
                  and l !~ '^\s*--')
union all
select 'meg iro stable fuggveny: '||n.nspname||'.'||p.proname,
       case p.provolatile when 's' then 'stable' else 'immutable' end,
       'HIBA'
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where p.provolatile in ('s','i')
   and n.nspname not in ('pg_catalog','information_schema','extensions','graphql','pgbouncer')
   and exists (select 1 from unnest(string_to_array(p.prosrc, e'\n')) l
                where (l ~* '\mlog_access\M' or l ~* '\minsert into\M'
                       or l ~* '\mdelete from\M' or l ~* '^\s*update\s+\w')
                  and l !~ '^\s*--');
