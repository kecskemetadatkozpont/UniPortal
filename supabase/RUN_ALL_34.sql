-- ============================================================================
-- RUN_ALL_34.sql  —  UniPortal
-- EGYBEN BEILLESZTHETŐ a Supabase SQL Editorba.
--
--   34_echo_export.sql         ECHO export k-küszöb-őrrel és export-naplóval
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--
-- ELŐFELTÉTEL: a RUN_ALL_33.sql már lefutott.
-- Idempotens: többször is beilleszthető.
--
-- FIGYELEM: az "echo" séma REJTETT marad (Data API → Exposed schemas).
-- Az export a public.echo_export_results() burkolón át érhető el, ahogy
-- minden más ECHO-funkció. Ne tedd láthatóvá az echo sémát.
-- ============================================================================


-- ===========================================================================
-- >>> 34_echo_export.sql
-- ===========================================================================
-- ============================================================================
-- 34_echo_export.sql — ECHO: export k-küszöb-őrrel és export-naplóval  (III/2)
-- ----------------------------------------------------------------------------
-- MIÉRT
--   A kampányciklus lezárásához exportálni kell tudni az eredményeket. Ez az
--   a pont, ahol a k-anonimitás a legkönnyebben elfolyik: elég egyetlen
--   "kényelmi" lekérdezés az echo.response táblára, és minden védelem, amit a
--   results_build felépít, megkerülhető.
--
-- A MEGOLDÁS SZERKEZETI, NEM ELLENŐRZÉS-ALAPÚ
--   Az echo.export_rows() bemenete a MÁR ELNYOMOTT riport-JSON, amit a
--   results_build ad vissza. A függvény nem olvas semmilyen táblát — nincs
--   honnan kiszivárogtatnia. Amit a képernyőn elrejtettünk, azt az export
--   nem tudja megmutatni, mert hozzá sem fér.
--
--   Ezért az export SOHA nem kap saját adatutat. Aki később gyorsítani
--   akarna rajta egy közvetlen lekérdezéssel, az a védelmet szedi szét.
--
-- MIT AD
--   1) echo.export_log        ki, mit, mikor vitt ki — és mennyi maradt rejtve
--   2) echo.export_rows()     a riport lapítása, minden rejtés-jelzőt tisztelve
--   3) public.echo_export_results()  a publikus kapu (a séma rejtett)
--   4) public.echo_export_log()      a napló olvasása, adminnak
--
-- IDEMPOTENS. Visszavonás: select public.echo_export_rollback();
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) Export-napló
--    Az access_log a MEGTEKINTÉST rögzíti. Az export erősebb esemény: az adat
--    elhagyja a rendszert, és onnantól nem tudjuk követni. Külön napló jár
--    neki, a rejtett cellák számával együtt — utólag ez mutatja meg, hogy egy
--    kivitt állomány mennyire volt szűrve.
-- ---------------------------------------------------------------------------
create table if not exists echo.export_log (
  id             uuid primary key default gen_random_uuid(),
  exporter_key   uuid,
  exporter_role  text,
  campaign_id    uuid,
  course_id      uuid,
  teacher_id     uuid,
  scope          text,
  format         text,
  row_count      integer not null default 0,
  hidden_count   integer not null default 0,
  fully_hidden   boolean not null default false,
  at             timestamptz not null default now()
);

create index if not exists export_log_campaign_idx
  on echo.export_log (campaign_id, at desc);

comment on table echo.export_log is
  'Export-események. Az access_log a megtekintést rögzíti, ez a KIVITELT: '
  'az exportált adat elhagyja a rendszert. A hidden_count megmutatja, hány '
  'cellát nyomott el a k-küszöb az adott állományban.';

-- ---------------------------------------------------------------------------
-- 2) A riport lapítása sorokká
--
--    BEMENET: a results_build() kimenete — vagyis MÁR elnyomott adat.
--    A függvény szándékosan IMMUTABLE és nem olvas táblát: nincs mit
--    kiszivárogtatnia. Minden rejtés-jelzőt tiszteletben tart:
--      rejtve                    -> a kérdés egésze kimarad
--      atlag_rejtve              -> az átlag nem kerül ki
--      eloszlas_nem_kozolheto    -> az eloszlás nem kerül ki
--      szoveg_rejtve             -> a szöveges válaszok nem kerülnek ki
-- ---------------------------------------------------------------------------
create or replace function echo.export_rows(p_result jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_rows   jsonb := '[]'::jsonb;
  v_hidden integer := 0;
  v_q      jsonb;
  v_blokk  text;
  v_lista  jsonb;
begin
  -- Ha az EGÉSZ riport rejtve van, egyetlen sor sem megy ki.
  if coalesce((p_result->>'rejtve')::boolean, false) then
    return jsonb_build_object(
      'sorok', '[]'::jsonb,
      'rejtett_cellak', 0,
      'teljesen_rejtve', true,
      'ok', p_result->>'rejtes_oka');
  end if;

  foreach v_blokk in array array['kerdesek', 'alacsony_oralatogatas']
  loop
    if v_blokk = 'kerdesek' then
      v_lista := coalesce(p_result->'kerdesek', '[]'::jsonb);
    else
      -- Az alacsony óralátogatású blokk maga is elrejthető.
      if coalesce((p_result->'alacsony_oralatogatas'->>'rejtve')::boolean, false) then
        v_hidden := v_hidden + 1;
        continue;
      end if;
      v_lista := coalesce(p_result->'alacsony_oralatogatas'->'kerdesek', '[]'::jsonb);
    end if;

    for v_q in select * from jsonb_array_elements(v_lista)
    loop
      -- Elrejtett kérdés: NEM megy ki, csak a ténye számolódik.
      if coalesce((v_q->>'rejtve')::boolean, false) then
        v_hidden := v_hidden + 1;
        continue;
      end if;

      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
        'blokk',      case when v_blokk = 'kerdesek' then 'fo' else 'alacsony_oralatogatas' end,
        'kerdes_id',  v_q->>'id',
        'kerdes',     coalesce(v_q->>'hu', v_q->>'cimke', v_q->>'id'),
        'tipus',      v_q->>'type',
        'n',          v_q->'n',
        -- Minden érzékeny mező CSAK akkor kerül ki, ha a riport is mutatja.
        'atlag',      case when coalesce((v_q->>'atlag_rejtve')::boolean, false)
                           then null else v_q->'atlag' end,
        'eloszlas',   case when coalesce((v_q->>'eloszlas_nem_kozolheto')::boolean, false)
                           then null else v_q->'eloszlas' end,
        'szovegek',   case when coalesce((v_q->>'szoveg_rejtve')::boolean, false)
                           then null else v_q->'szovegek' end,
        'szoveg_db',  v_q->'szoveg_db'
      ));

      -- A részlegesen elrejtett mezőket is számoljuk: így a napló hűen
      -- mutatja, mennyi maradt ki egy látszólag teljes állományból.
      if coalesce((v_q->>'atlag_rejtve')::boolean, false)             then v_hidden := v_hidden + 1; end if;
      if coalesce((v_q->>'eloszlas_nem_kozolheto')::boolean, false)   then v_hidden := v_hidden + 1; end if;
      if coalesce((v_q->>'szoveg_rejtve')::boolean, false)            then v_hidden := v_hidden + 1; end if;
    end loop;
  end loop;

  return jsonb_build_object(
    'sorok',           v_rows,
    'rejtett_cellak',  v_hidden,
    'teljesen_rejtve', false,
    'ok',              null);
end $$;

commit;

begin;

-- ---------------------------------------------------------------------------
-- 3) A publikus kapu
--    A jogosultság-ellenőrzés SZÓ SZERINT ugyanaz, mint az echo_course_results
--    és az echo_teacher_results esetében: aki a képernyőn nem láthatja, az
--    nem is exportálhatja. Ez nem külön szabályrendszer — ha az egyik változik,
--    a másik is vele kell változzon.
-- ---------------------------------------------------------------------------
create or replace function public.echo_export_results(
  p_campaign uuid,
  p_course   uuid,
  p_teacher  uuid  default null,
  p_scope    text  default 'course',
  p_format   text  default 'csv')
returns jsonb
language plpgsql
security definer
set search_path = public, echo
as $$
declare
  v_me     uuid := auth.uid();
  v_admin  boolean;
  v_mine   uuid;
  v_report jsonb;
  v_flat   jsonb;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;

  if p_scope not in ('course', 'teacher') then
    raise exception 'ECHO_BAD_SCOPE: "%" — csak "course" vagy "teacher".', p_scope;
  end if;
  if p_format not in ('csv', 'json') then
    raise exception 'ECHO_BAD_FORMAT: "%" — csak "csv" vagy "json".', p_format;
  end if;

  v_admin := public.is_admin();
  v_mine  := echo.my_teacher_id();

  if not v_admin then
    if v_mine is null then
      raise exception 'ECHO_FORBIDDEN: a fiok nincs oktatoi sorhoz kotve, es nem admin.';
    end if;
    if not exists (select 1 from echo.course_teacher ct
                    where ct.course_id = p_course and ct.teacher_id = v_mine) then
      raise exception 'ECHO_FORBIDDEN: nem oktatod ezt a kurzust.';
    end if;
    -- Oktató SAJÁT magáról exportálhat, másról nem.
    if p_scope = 'teacher' and coalesce(p_teacher, v_mine) is distinct from v_mine then
      raise exception 'ECHO_FORBIDDEN: mas oktato eredmenyet nem exportalhatod.';
    end if;
  end if;

  -- A kampány állapota ugyanúgy kapu, mint a képernyőn.
  perform echo.results_gate(p_campaign, v_admin);

  -- AZ EGYETLEN ADATÚT. Ide bármi mást beírni = a k-védelem megkerülése.
  v_report := echo.results_build(
    p_campaign, p_course,
    case when p_scope = 'teacher' then coalesce(p_teacher, v_mine) else null end,
    p_scope, v_admin);

  v_flat := echo.export_rows(v_report);

  perform echo.log_access('echo_export_results', p_campaign, p_course,
                          case when p_scope = 'teacher' then coalesce(p_teacher, v_mine) else null end,
                          p_scope);

  insert into echo.export_log(
    exporter_key, exporter_role, campaign_id, course_id, teacher_id,
    scope, format, row_count, hidden_count, fully_hidden)
  values (
    v_me,
    case when v_admin then 'admin' else 'teacher' end,
    p_campaign, p_course,
    case when p_scope = 'teacher' then coalesce(p_teacher, v_mine) else null end,
    p_scope, p_format,
    coalesce(jsonb_array_length(v_flat->'sorok'), 0),
    coalesce((v_flat->>'rejtett_cellak')::integer, 0),
    coalesce((v_flat->>'teljesen_rejtve')::boolean, false));

  return v_flat
      || jsonb_build_object(
           'kampany',   p_campaign,
           'kurzus',    p_course,
           'hatokor',   p_scope,
           'formatum',  p_format,
           'kuszobok',  v_report->'kuszobok',
           'valaszadas', v_report->'valaszadas',
           'kurzus_nev', v_report->>'course_name',
           'oktato_nev', v_report->>'teacher_name');
end $$;

-- ---------------------------------------------------------------------------
-- 4) Az export-napló olvasása — csak adminnak
-- ---------------------------------------------------------------------------
create or replace function public.echo_export_log(p_campaign uuid default null)
returns setof echo.export_log
language plpgsql
security definer
set search_path = public, echo
as $$
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then
    raise exception 'ECHO_FORBIDDEN: az export-naplot csak admin olvashatja.';
  end if;
  return query
    select * from echo.export_log
     where p_campaign is null or campaign_id = p_campaign
     order by at desc
     limit 500;
end $$;

-- ---------------------------------------------------------------------------
-- 5) Jogosultságok
--    anon SEHOL nem kap jogot: az export bejelentkezett, jóváhagyott fiókhoz
--    kötött esemény.
-- ---------------------------------------------------------------------------
revoke all on function public.echo_export_results(uuid, uuid, uuid, text, text) from public, anon;
revoke all on function public.echo_export_log(uuid) from public, anon;
grant execute on function public.echo_export_results(uuid, uuid, uuid, text, text) to authenticated;
grant execute on function public.echo_export_log(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6) Visszavonás
-- ---------------------------------------------------------------------------
create or replace function public.echo_export_rollback()
returns text language plpgsql security definer set search_path = public, echo
as $$
begin
  if not public.is_superadmin() then
    raise exception 'Csak szuperadmin vonhatja vissza.' using errcode = '42501';
  end if;
  drop function if exists public.echo_export_results(uuid, uuid, uuid, text, text);
  drop function if exists public.echo_export_log(uuid);
  drop function if exists echo.export_rows(jsonb);
  -- A naplót SZÁNDÉKOSAN nem töröljük: a megtörtént exportok ténye
  -- auditnyom, nem a modul tartozéka.
  return 'A 34-es export visszavonva. Az echo.export_log megmaradt (auditnyom).';
end $$;

revoke all on function public.echo_export_rollback() from public, anon;
grant execute on function public.echo_export_rollback() to authenticated;

commit;


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

