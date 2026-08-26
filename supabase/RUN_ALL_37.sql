-- ============================================================================
-- RUN_ALL_37.sql  —  UniPortal
-- EGYBEN BEILLESZTHETŐ a Supabase SQL Editorba.
--
--   37_merge_application_flows.sql  a két jelentkezési folyamat összevonása
--   21_echo_harden_submit.sql       ÚJRA — minden új migráció után kötelező
--   + a végén a MODUL SAJÁT ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a RUN_ALL_35_36.sql már lefutott.
-- Idempotens.
--
-- MIT OLD MEG: a kollégák bejelentése szerint a hallgató által feltöltött
-- dokumentumok nem jelentek meg az admin oldalon, ezért a felvételi folyamat
-- megállt — és külön kérdésként azt is jelezték, miért van dupla lista.
-- A kettő UGYANAZ a probléma: két külön jelentkezési folyamat élt egymás
-- mellett. Ez a migráció egyesíti őket.
--
-- A program_applications tábla ÉRINTETLEN marad, tehát a lépés
-- visszafordítható: select public.merge_flows_rollback();
-- ============================================================================


-- ===========================================================================
-- >>> 37_merge_application_flows.sql
-- ===========================================================================
-- ============================================================================
-- 37_merge_application_flows.sql — a két jelentkezési folyamat összevonása
-- ----------------------------------------------------------------------------
-- A HIBA, AMIT MEGOLD
--   A kollégák bejelentése szerint a hallgató által feltöltött dokumentumok
--   nem jelennek meg az admin oldalon, ezért a felvételi folyamat megáll.
--   Ugyanők kérdezték, miért van dupla lista — "nem hibaként" jelölve.
--
--   A kettő UGYANAZ a probléma. Ma két külön jelentkezési folyamat él:
--
--     hallgatói jelentkezés  ->  program_applications   (features/programs.jsx)
--     ügyintézői ellenőrzés  ->  admission_processes    (app.jsx, STEP_DEFS)
--
--   A hallgató a képzés oldaláról jelentkezik, az ügyintéző a felvételi
--   folyamatokat nézi. Nincs átjárás, ezért a jelentkezés meg sem jelenik ott,
--   ahol dolgozni kellene vele. A jogosultság NEM szűk keresztmetszet:
--   az admission_processes RLS-e engedi az ügyintézőnek mások sorait is —
--   a sor egyszerűen létre sem jön.
--
-- A MEGOLDÁS: EGY SOR, KÉT SZAKASZ
--   Nem összekötjük a két modellt, hanem EGYESÍTJÜK. Az admission_processes
--   lesz az egyetlen tábla, és a sor két szakaszon megy át:
--
--     stage = 'student'  a jelentkező tölti          (student_step számláló)
--     stage = 'office'   az iroda dolgozik vele      (step számláló)
--
--   A két lépéssor nem ütközik, hanem kiegészíti egymást:
--     hallgató: personal -> documents -> language -> motivation -> fee -> review
--     iroda:                             check -> interview -> math -> letter
--
--   A beadás átfordítja a sort a 'check' lépésre — pontosan oda, ahol a
--   27/30-as migráció interjúkapuja nyílik.
--
--   A dupla lista így magától megszűnik: az ügyintézői lista már ma is
--   MINDEN admission_processes sort mutat.
--
-- IDEMPOTENS. Visszavonás: select public.merge_flows_rollback();
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) Az egyesített tábla új mezői
-- ---------------------------------------------------------------------------
alter table public.admission_processes
  add column if not exists program_id     text,
  add column if not exists applicant_name text,
  add column if not exists stage          text not null default 'office',
  add column if not exists student_step   integer not null default 0,
  add column if not exists submitted_at   timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'admission_processes_stage_ck') then
    alter table public.admission_processes
      add constraint admission_processes_stage_ck check (stage in ('student', 'office'));
  end if;
  -- A program_id SZÁNDÉKOSAN nem idegenkulcs: az irodai úton indított
  -- folyamatnak nincs programja, a hallgatói úton pedig a programs katalógus
  -- utólag is bővülhet. A hivatkozás épségét a felület tartja.
end $$;

create index if not exists admission_processes_stage_idx
  on public.admission_processes (stage, updated_at desc);
create index if not exists admission_processes_program_idx
  on public.admission_processes (program_id);

comment on column public.admission_processes.stage is
  'student = a jelentkező tölti (student_step a számláló); '
  'office = az iroda dolgozik vele (step a számláló). A beadás fordítja át.';

-- ---------------------------------------------------------------------------
-- 2) A listanézet újraépítése az új mezőkkel
--    A dataUrl kiszűrése MEGMARAD: a lista soha ne hordozzon fájlbájtokat.
-- ---------------------------------------------------------------------------
drop view if exists public.admission_process_list;
create view public.admission_process_list as
  select
    p.id,
    p.owner_email,
    p.step,
    p.max_reached,
    p.done,
    p.created_at,
    p.updated_at,
    p.program_id,
    p.applicant_name,
    p.stage,
    p.student_step,
    p.submitted_at,
    coalesce(p.data, '{}'::jsonb) || jsonb_build_object(
      'docs',
      coalesce((
        select jsonb_object_agg(d.key, d.value - 'dataUrl')
          from jsonb_each(coalesce(p.data -> 'docs', '{}'::jsonb)) d(key, value)
      ), '{}'::jsonb)
    ) as data
  from public.admission_processes p;

grant select on public.admission_process_list to authenticated;

commit;

begin;

-- ---------------------------------------------------------------------------
-- 3) A meglévő hallgatói jelentkezések átemelése
--
--    A program_applications táblát NEM töröljük: az átemelés után is
--    érintetlenül megmarad, tehát a lépés visszafordítható. A felület
--    viszont onnantól az admission_processes-t írja.
-- ---------------------------------------------------------------------------
do $$
declare
  v_van    boolean;
  v_uj     integer := 0;
  v_meglevo integer := 0;
begin
  select exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'program_applications')
    into v_van;

  if not v_van then
    raise notice 'Nincs program_applications tábla — nincs mit átemelni.';
    return;
  end if;

  -- A jelentkezés azonosítóját megőrizzük az új sor data-jában, hogy az
  -- átemelés utólag is visszakereshető legyen.
  insert into public.admission_processes (
    id, owner_email, applicant_name, program_id,
    stage, student_step, step, max_reached, done,
    data, created_at, updated_at, submitted_at)
  select
    'APP-' || pa.id,
    lower(btrim(pa.applicant_email)),
    pa.applicant_name,
    pa.program_id,
    case when lower(coalesce(pa.status, '')) in ('submitted', 'beadva')
         then 'office' else 'student' end,
    coalesce(pa.step_index, 0),
    -- Beadott jelentkezés az irodai sor ELEJÉRE kerül: a 'check' lépés a
    -- STEP_IDS_V2-ben a 3. elem (programs, documents, check) -> index 2.
    case when lower(coalesce(pa.status, '')) in ('submitted', 'beadva') then 2 else 0 end,
    case when lower(coalesce(pa.status, '')) in ('submitted', 'beadva') then 2 else 0 end,
    false,
    coalesce(pa.data, '{}'::jsonb)
      || jsonb_build_object('_from_program_application', pa.id),
    coalesce(pa.created_at, now()::text),
    coalesce(pa.updated_at, now()),
    case when lower(coalesce(pa.status, '')) in ('submitted', 'beadva')
         then coalesce(pa.updated_at, now()) else null end
  from public.program_applications pa
  where not exists (
    select 1 from public.admission_processes ap where ap.id = 'APP-' || pa.id
  );
  get diagnostics v_uj = row_count;

  select count(*) into v_meglevo from public.program_applications;

  raise notice 'Átemelve: % új felvételi folyamat (a program_applications % sora érintetlen).',
    v_uj, v_meglevo;
  if v_uj > 0 then
    raise notice 'Az átemelt sorok azonosítója "APP-" előtaggal kezdődik.';
  end if;
end $$;

commit;

begin;

-- ---------------------------------------------------------------------------
-- 4) A beadás — ez fordítja át a sort a hallgatóból az irodai szakaszba
--
--    Miért RPC és nem sima UPDATE a felületről: a szakaszváltás egyirányú
--    és jogilag számít (innen indul az ügyintézés). Egy elgépelt UPDATE
--    ne tudja visszatolni a sort a hallgatóhoz.
-- ---------------------------------------------------------------------------
create or replace function public.application_submit(p_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.admission_processes;
  v_me  text := public.my_email();
begin
  if auth.uid() is null then
    raise exception 'Bejelentkezés szükséges.' using errcode = '42501';
  end if;
  if not public.is_approved() then
    raise exception 'Jóváhagyásra váró fiókkal nem lehet jelentkezést beadni.'
      using errcode = '42501';
  end if;

  select * into v_row from public.admission_processes where id = p_id;
  if v_row.id is null then
    raise exception 'Nincs ilyen jelentkezés: %', p_id using errcode = '02000';
  end if;

  -- A jelentkező a SAJÁTJÁT adhatja be; az ügyintéző bármelyiket.
  if not public.is_staff() and lower(coalesce(v_row.owner_email, '')) is distinct from v_me then
    raise exception 'Csak a saját jelentkezését adhatja be.' using errcode = '42501';
  end if;

  if v_row.stage = 'office' then
    return jsonb_build_object('id', v_row.id, 'stage', 'office',
                              'mar_beadva', true, 'beadva', v_row.submitted_at);
  end if;

  update public.admission_processes
     set stage        = 'office',
         -- A 'check' a STEP_IDS_V2-ben a 3. elem (programs, documents, check).
         step         = greatest(coalesce(step, 0), 2),
         max_reached  = greatest(coalesce(max_reached, 0), 2),
         submitted_at = now(),
         updated_at   = now()
   where id = p_id
  returning * into v_row;

  return jsonb_build_object(
    'id', v_row.id, 'stage', v_row.stage, 'step', v_row.step,
    'mar_beadva', false, 'beadva', v_row.submitted_at);
end $$;

revoke all on function public.application_submit(text) from public, anon;
grant execute on function public.application_submit(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) Visszavonás
--    Az ÁTEMELT sorokat töröljük (azok az "APP-" előtagról felismerhetők),
--    az irodai úton indított folyamatokhoz NEM nyúlunk. A program_applications
--    érintetlen maradt, tehát a régi felület azonnal újra használható.
-- ---------------------------------------------------------------------------
create or replace function public.merge_flows_rollback()
returns text
language plpgsql security definer set search_path = public
as $$
declare v_n integer;
begin
  if not public.is_superadmin() then
    raise exception 'Csak szuperadmin vonhatja vissza.' using errcode = '42501';
  end if;
  delete from public.admission_processes
   where id like 'APP-%' and data ? '_from_program_application';
  get diagnostics v_n = row_count;
  drop function if exists public.application_submit(text);
  alter table public.admission_processes drop constraint if exists admission_processes_stage_ck;
  return 'A 37-es összevonás visszavonva. Törölt átemelt sor: ' || v_n ||
         '. A program_applications tábla végig érintetlen volt.';
end $$;

revoke all on function public.merge_flows_rollback() from public, anon;
grant execute on function public.merge_flows_rollback() to authenticated;

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


-- ===========================================================================
-- >>> ELLENŐRZÉS — ez az utolsó eredmény, ezt fogod látni
-- ===========================================================================
-- 37 ellenőrzés: az összevont jelentkezési folyamat + anonimitás, egy táblában.
with o(s, mit, nev, t) as (values
  (1,'stage oszlop (szakasz)','stage','col'),
  (2,'student_step oszlop','student_step','col'),
  (3,'program_id oszlop','program_id','col'),
  (4,'applicant_name oszlop','applicant_name','col'),
  (5,'submitted_at oszlop','submitted_at','col'),
  (6,'Beadás RPC','application_submit','fn'),
  (7,'Visszavonó','merge_flows_rollback','fn'),
  (8,'Listanézet','admission_process_list','view')
),
letezik as (
  select o.s, o.mit, o.nev,
    case when case o.t
      when 'col'  then exists (select 1 from information_schema.columns
                                where table_name='admission_processes' and column_name=o.nev)
      when 'fn'   then exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                                where n.nspname='public' and p.proname=o.nev)
      when 'view' then exists (select 1 from pg_views where schemaname='public' and viewname=o.nev)
    end then 'OK' else '!! HIÁNYZIK' end as allapot
  from o
),
-- A LÉNYEG: a listanézet átadja-e az új mezőket?
nezet as (
  select 40 as s, 'A listanézet viszi az új mezőket' as mit, 'admission_process_list' as nev,
    case when (select count(*) from information_schema.columns
                where table_name='admission_process_list'
                  and column_name in ('stage','student_step','program_id','applicant_name')) = 4
         then 'OK — mind a 4' else '!! hiányos' end as allapot
),
adat as (
  select 50 as s, 'Felvételi folyamatok' as mit,
         'hallgatói / irodai szakasz' as nev,
         (count(*) filter (where stage='student'))::text || ' / ' ||
         (count(*) filter (where stage='office'))::text as allapot
    from public.admission_processes
  union all
  select 51, 'Átemelt hallgatói jelentkezés', 'APP- előtaggal',
         count(*)::text from public.admission_processes where id like 'APP-%'
  union all
  select 52, 'A régi tábla érintetlen', 'program_applications',
         case when exists (select 1 from information_schema.tables
                            where table_schema='public' and table_name='program_applications')
              then (select count(*)::text || ' sor — megvan, visszafordítható'
                      from public.program_applications)
              else 'nincs ilyen tábla' end
),
anonimitas as (
  select 70 as s, 'ECHO anonimitás (21 utoljára futott?)' as mit, 'echo_submit' as nev,
         string_agg(distinct grantee, ', ' order by grantee) ||
         case when bool_or(grantee='authenticated') then '   !! FUTTASD ÚJRA a 21-est' else '   OK' end
    from information_schema.routine_privileges where routine_name='echo_submit'
)
select mit as "mit ellenőrzünk", nev as "objektum", allapot as "állapot"
  from (select * from letezik union all select * from nezet
        union all select * from adat union all select * from anonimitas) x
 order by s;
