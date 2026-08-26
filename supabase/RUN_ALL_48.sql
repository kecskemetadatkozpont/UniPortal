-- ============================================================================
-- RUN_ALL_48.sql — UniPortal
--
--   48_campaign_form.sql       a kampány kérdőívének megtekintése adminként
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--   + a végén a MODUL SAJÁT ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a RUN_ALL_47.sql már lefutott.
-- Idempotens. Egyetlen olvasó függvényt ad hozzá, meglévőt nem módosít.
--
-- MIT JAVÍT: a kampány "Kérdőív" gombja eddig ezt írta ki — "nincs admin RPC:
-- az echo_get_form() a hívó saját részvételére szűr". Az üzenet igaz volt, a
-- hiány valódi. Ez a migráció megadja a hiányzó admin végpontot; a HALLGATÓI
-- kaput (echo_get_form) szándékosan nem lazítja fel.
-- ============================================================================


-- ============================================================================
--  48_campaign_form.sql — UniPortal / ECHO
--  A KAMPÁNY KÉRDŐÍVÉNEK MEGTEKINTÉSE ADMINKÉNT
-- ============================================================================
--
--  A TÜNET
--  A kampány "Kérdőív" gombja ezt írta ki: "a 15_echo_core.sql-ben nincs admin
--  RPC: az echo_get_form() a hívó saját részvételére szűr. Ehhez a kampányhoz
--  nincs saját véleményezhető kurzusod, ezért a kérdőív most nem jeleníthető
--  meg." Az üzenet igaz volt — a hiány viszont valódi.
--
--  AZ OK
--  Az echo_get_form() HALLGATÓI végpont: a saját echo.participation sorra szűr,
--  és ECHO_NOT_ELIGIBLE-t dob, ha nincs ilyen. Egy adminisztrátor nincs
--  beiratkozva a kurzusokra, tehát a saját kérdőívét sem tudta megnézni.
--
--  A MEGOLDÁS
--  Külön, admin oldali RPC. NEM az echo_get_form() lazítása: az a hallgatói
--  kapu, és annak szigorúnak kell maradnia. Ez a függvény hallgatói adatot
--  EGYÁLTALÁN nem ad — se célokat, se részvételt, se választ. Csak a kampány
--  sablonverziójának lefordított kérdőívét, vagyis pontosan azt, ami a
--  kérdőívszerkesztőben is látszik.
--
--  ELŐFELTÉTEL: a RUN_ALL_47.sql már lefutott. Idempotens, csak olvas.
-- ============================================================================

create or replace function public.echo_campaign_form(p_campaign uuid)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c      echo.campaign%rowtype;
  v_out  jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  select * into c from echo.campaign where id = p_campaign;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;

  -- A vazkampanynak nincs meg kerdoive (42_campaign_editor.sql). Ezt kimondjuk,
  -- nem ures kepernyovel valaszolunk.
  if c.template_version_id is null then
    raise exception 'ECHO_NO_TEMPLATE: ehhez a kampanyhoz meg nincs kerdoiv rendelve. '
                    'Valassz sablonverziot a kampanyszerkesztoben.';
  end if;

  select jsonb_build_object(
    'campaign', jsonb_build_object(
       'id', c.id, 'code', c.code, 'name', c.name_hu, 'name_en', c.name_en,
       'term', c.term, 'state', c.state,
       'opens_at', c.opens_at, 'closes_at', c.closes_at,
       'is_open', echo.is_open(c.id), 'is_goals_open', echo.is_goals_open(c.id)),
    'template', jsonb_build_object(
       'version_id', tv.id, 'version', tv.version, 'state', tv.state,
       'name_hu', t.name_hu, 'name_en', t.name_en,
       'approved_at', tv.approved_at),
    -- Ez az, amit a felulet megjelenit: ugyanaz a 'compiled', amibol az
    -- echo_get_form() is dolgozik. Hallgatoi adat NINCS benne.
    'form', tv.compiled,
    'template_version_id', c.template_version_id
  ) into v_out
  from echo.template_version tv
  join echo.template t on t.id = tv.template_id
 where tv.id = c.template_version_id;

  perform echo.log_access('echo_campaign_form', p_campaign, null, null, 'campaign');
  return v_out;
end $$;

-- VOLATILE, nem STABLE: a fuggveny hozzaferes-naplot ir (log_access = INSERT),
-- a PostgREST pedig a STABLE fuggvenyeket csak olvashato tranzakcioban futtatja.
-- Pontosan ez okozta a "cannot execute INSERT in a read-only transaction" hibat
-- a 46-os migracio elott — ne essunk bele ujra.
alter function public.echo_campaign_form(uuid) volatile;

do $jog$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'echo_campaign_form'
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


-- ============================================================================
--  ELLENŐRZÉS — futtasd le, és küldd vissza a táblát
-- ============================================================================
select 'echo_campaign_form letezik' as mit_ellenorzunk,
       count(*)::text||' valtozat' as ertek,
       case when count(*) = 1 then 'OK' else 'HIBA' end as allapot
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_campaign_form'
union all
select 'csak authenticated hivhatja',
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon is' else 'csak authenticated' end,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_campaign_form'
union all
select 'VOLATILE (naploz, tehat nem lehet stable)',
       case p.provolatile when 'v' then 'volatile' when 's' then 'stable' else 'immutable' end,
       case when p.provolatile = 'v' then 'OK'
            else 'HIBA — read-only tranzakcioban elhasalna' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_campaign_form'
union all
select 'hallgatoi adatot NEM ad vissza',
       case when prosrc ~* 'student_goal|participation|response' then 'ad' else 'nem ad' end,
       case when prosrc ~* 'student_goal|participation|response' then 'HIBA' else 'OK' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_campaign_form'
union all
select 'az echo_get_form (hallgatoi kapu) erintetlen',
       case when prosrc like '%ECHO_NOT_ELIGIBLE%' then 'szigoru maradt' else 'MEGVALTOZOTT' end,
       case when prosrc like '%ECHO_NOT_ELIGIBLE%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_get_form';
