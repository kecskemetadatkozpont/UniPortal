-- ============================================================================
-- RUN_ALL_39.sql — UniPortal
--
--   39_role_admin.sql          a szerepkörök szerkeszthetővé tétele
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--   + a végén a MODUL SAJÁT ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a RUN_ALL_38.sql már lefutott.
-- A KIINDULÁS BITRE A MAI ÁLLAPOT: a migráció önmagában egyetlen felhasználó
-- láthatóságán sem változtat, csak szerkeszthetővé teszi.
-- ============================================================================


-- ===========================================================================
-- >>> 39_role_admin.sql
-- ===========================================================================
-- ============================================================================
-- 39_role_admin.sql — a szerepkörök szerkeszthetővé tétele
-- ----------------------------------------------------------------------------
-- MI VOLT EDDIG
--   A szerepkör -> menüpont leképezés BEÉGETVE élt az app.jsx-ben:
--       if (currentUser.role === 'ADMISSIONS') return [ ... ].includes(item.id)
--   Egy szerepkör átalakításához kódot kellett módosítani és újra deployolni.
--
-- MI LESZ
--   A leképezés adatbázisba kerül, és a Regisztrációk alól szerkeszthető.
--   A KIINDULÁS BITRE AZONOS a mai beégetett listákkal — a migráció önmagában
--   egyetlen felhasználó láthatóságán sem változtat.
--
-- A SZUPERADMIN HOZZÁFÉRÉSE NEM SZERKESZTHETŐ
--   Ez nem kényelmi döntés. Ha a szuperadmin el tudná venni a saját jogát,
--   ki tudná zárni magát abból a képernyőből is, amivel a hibát javítaná —
--   és nem maradna út vissza. A menüszűrő ezért a szuperadminnál a táblát
--   MEG SEM NÉZI, és a SUPERADMIN sor nem törölhető, nem üríthető.
--
-- IDEMPOTENS. Visszavonás: select public.role_admin_rollback();
-- ============================================================================

begin;

create table if not exists public.role_definition (
  kod        text primary key,
  nev        text not null,
  leiras     text,
  szin       text,
  sorrend    integer not null default 100,
  beepitett  boolean not null default false,
  aktiv      boolean not null default true,
  updated_at timestamptz not null default now(),
  constraint role_definition_kod_ck check (kod ~ '^[A-Z][A-Z0-9_]{1,30}$')
);

create table if not exists public.role_permission (
  role_kod   text not null references public.role_definition(kod) on delete cascade,
  permission text not null,
  granted_by uuid,
  granted_at timestamptz not null default now(),
  primary key (role_kod, permission),
  constraint role_permission_shape_ck check (permission ~ '^[a-z0-9_]{2,40}$')
);

comment on table public.role_definition is
  'Szerepkörök. A beepitett sorokat nem lehet törölni; a SUPERADMIN '
  'hozzáférését a menüszűrő eleve nem innen veszi.';

-- ---------------------------------------------------------------------------
-- A mai állapot rögzítése — ugyanaz, ami eddig a kódban volt
-- ---------------------------------------------------------------------------
insert into public.role_definition (kod, nev, leiras, sorrend, beepitett) values
  ('SUPERADMIN', 'Superadmin', 'Teljes hozzáférés. A jogosultsága szándékosan nem szerkeszthető.', 10, true),
  ('ADMIN',      'Admin',      'Teljes hozzáférés a napi működéshez.',                              20, true),
  ('ADMISSIONS', 'Felvételi',  'A felvételi folyamat és a jelentkezők kezelése.',                   30, true),
  ('FINANCE',    'Pénzügy',    'Díjak, számlák, pénzügyi riportok.',                                40, true),
  ('AGENT',      'Ügynök',     'Külsős partner: a saját jelentkezőit kezeli.',                      50, true),
  ('STUDENT',    'Hallgató',   'Jelentkező és beiratkozott hallgató.',                              60, true)
on conflict (kod) do nothing;

do $$
declare
  v_szerep text;
  v_lista  text[];
  v_p      text;
begin
  -- Pontosan a beégetett listák, hogy a migráció ne mozdítson el semmit.
  for v_szerep, v_lista in
    select * from (values
      ('AGENT',      array['feed','programs','assistant','agent_portal','interviews']),
      ('FINANCE',    array['feed','assistant','finance','agent_portal','interviews','reports']),
      ('ADMISSIONS', array['feed','assistant','admissions_core','evaluation','engagement_crm',
                           'immigration','interviews','marketing_leads','reports','intelligence']),
      ('STUDENT',    array['feed','programs','assistant','student_portal'])
    ) t(sz, l)
  loop
    foreach v_p in array v_lista loop
      insert into public.role_permission(role_kod, permission)
      values (v_szerep, v_p) on conflict do nothing;
    end loop;
  end loop;

  -- Az ADMIN és a SUPERADMIN eddig MINDENT látott. Az ADMIN-nak ezt kiírjuk,
  -- hogy szerkeszthető legyen; a SUPERADMIN-t szándékosan NEM — az ő
  -- hozzáférése nem a táblából jön.
  foreach v_p in array array[
    'feed','programs','trainings','assistant','agent_portal','admissions_core',
    'engagement_crm','finance','immigration','evaluation','system_admin','interviews',
    'student_portal','marketing_leads','reports','intelligence','registrations',
    'echo_student','echo_admin','echo_teacher','dorm_ops','dorm_maintenance','dorm_student'
  ] loop
    insert into public.role_permission(role_kod, permission)
    values ('ADMIN', v_p) on conflict do nothing;
  end loop;

  raise notice 'Szerepkör-jogosultságok rögzítve a mai állapot szerint.';
end $$;

commit;

begin;

-- ---------------------------------------------------------------------------
-- A hívó szerepkörének menüpontjai. A felület ezt kéri le bejelentkezéskor.
-- SUPERADMIN esetén NULL-t ad: neki a szűrő meg sem nézi a táblát.
-- ---------------------------------------------------------------------------
create or replace function public.my_role_permissions()
returns text[]
language sql stable security definer set search_path = public
as $$
  select case
    when public.my_role() = 'SUPERADMIN' then null
    else (select array_agg(rp.permission order by rp.permission)
            from public.role_permission rp
            join public.role_definition rd on rd.kod = rp.role_kod and rd.aktiv
           where rp.role_kod = public.my_role())
  end
$$;

-- ---------------------------------------------------------------------------
-- Szerepkör mentése
-- ---------------------------------------------------------------------------
create or replace function public.role_save(
  p_kod     text,
  p_nev     text default null,
  p_leiras  text default null,
  p_szin    text default null,
  p_sorrend integer default null,
  p_aktiv   boolean default null)
returns public.role_definition
language plpgsql security definer set search_path = public
as $$
declare v_r public.role_definition;
begin
  if not public.is_superadmin() then
    raise exception 'Szerepkört csak szuperadmin szerkeszthet.' using errcode = '42501';
  end if;

  select * into v_r from public.role_definition where kod = p_kod;

  if v_r.kod is null then
    if nullif(btrim(coalesce(p_nev, '')), '') is null then
      raise exception 'Az új szerepkörnek kell megnevezés.' using errcode = '22023';
    end if;
    insert into public.role_definition(kod, nev, leiras, szin, sorrend, beepitett)
    values (upper(btrim(p_kod)), btrim(p_nev), p_leiras, p_szin,
            coalesce(p_sorrend, 100), false)
    returning * into v_r;
    return v_r;
  end if;

  -- A SUPERADMIN sort nem lehet kikapcsolni: enélkül nem maradna, aki javít.
  if v_r.kod = 'SUPERADMIN' and coalesce(p_aktiv, true) = false then
    raise exception 'A SUPERADMIN szerepkör nem kapcsolható ki.' using errcode = '42501';
  end if;

  update public.role_definition
     set nev     = coalesce(btrim(p_nev), nev),
         leiras  = coalesce(p_leiras, leiras),
         szin    = coalesce(p_szin, szin),
         sorrend = coalesce(p_sorrend, sorrend),
         aktiv   = coalesce(p_aktiv, aktiv),
         updated_at = now()
   where kod = p_kod
  returning * into v_r;
  return v_r;
end $$;

-- ---------------------------------------------------------------------------
-- Egy menüpont be- vagy kikapcsolása egy szerepkörön
-- ---------------------------------------------------------------------------
create or replace function public.role_permission_set(
  p_kod text, p_permission text, p_ad boolean)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'Jogosultságot csak szuperadmin állíthat.' using errcode = '42501';
  end if;
  -- A szuperadmin hozzáférése nem a táblából jön, ezért itt sem állítjuk:
  -- egy félrekattintás nem zárhatja ki azt, aki a hibát javítaná.
  if p_kod = 'SUPERADMIN' then
    raise exception
      'A SUPERADMIN hozzáférése szándékosan nem szerkeszthető — enélkül ki '
      'lehetne zárni magadat abból a képernyőből is, amivel visszaállítanád.'
      using errcode = '42501';
  end if;
  if p_ad then
    insert into public.role_permission(role_kod, permission, granted_by)
    values (p_kod, p_permission, auth.uid()) on conflict do nothing;
  else
    delete from public.role_permission where role_kod = p_kod and permission = p_permission;
  end if;
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- Szerepkör törlése — csak sajátot, és csak ha senki nem viseli
-- ---------------------------------------------------------------------------
create or replace function public.role_delete(p_kod text)
returns text
language plpgsql security definer set search_path = public
as $$
declare v_n integer; v_b boolean;
begin
  if not public.is_superadmin() then
    raise exception 'Szerepkört csak szuperadmin törölhet.' using errcode = '42501';
  end if;
  select beepitett into v_b from public.role_definition where kod = p_kod;
  if v_b is null then raise exception 'Nincs ilyen szerepkör: %', p_kod using errcode='02000'; end if;
  if v_b then
    raise exception 'A(z) "%" beépített szerepkör, nem törölhető. Ki lehet kapcsolni.', p_kod
      using errcode = '42501';
  end if;
  select count(*) into v_n from public.profiles where role = p_kod;
  if v_n > 0 then
    raise exception 'Ezt a szerepkört % fiók viseli — előbb át kell sorolni őket.', v_n
      using errcode = '42501';
  end if;
  delete from public.role_definition where kod = p_kod;
  return 'Törölve: ' || p_kod;
end $$;

commit;

begin;

-- ---------------------------------------------------------------------------
-- Sorszintű biztonság és jogosultságok
--   Olvasni minden jóváhagyott fiók tudja: a felület ebből tölti a
--   szerepkör-címkéket. Írni csak RPC-n át, szuperadminként.
-- ---------------------------------------------------------------------------
alter table public.role_definition enable row level security;
alter table public.role_permission enable row level security;

drop policy if exists rd_select on public.role_definition;
create policy rd_select on public.role_definition for select using (public.is_approved());
drop policy if exists rd_write on public.role_definition;
create policy rd_write on public.role_definition for all
  using (public.is_superadmin()) with check (public.is_superadmin());

drop policy if exists rp_select on public.role_permission;
create policy rp_select on public.role_permission for select using (public.is_approved());
drop policy if exists rp_write on public.role_permission;
create policy rp_write on public.role_permission for all
  using (public.is_superadmin()) with check (public.is_superadmin());

grant select on public.role_definition, public.role_permission to authenticated;

revoke all on function public.my_role_permissions()                              from public, anon;
revoke all on function public.role_save(text, text, text, text, integer, boolean) from public, anon;
revoke all on function public.role_permission_set(text, text, boolean)            from public, anon;
revoke all on function public.role_delete(text)                                   from public, anon;

grant execute on function public.my_role_permissions()                              to authenticated;
grant execute on function public.role_save(text, text, text, text, integer, boolean) to authenticated;
grant execute on function public.role_permission_set(text, text, boolean)            to authenticated;
grant execute on function public.role_delete(text)                                   to authenticated;

create or replace function public.role_admin_rollback()
returns text language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'Csak szuperadmin vonhatja vissza.' using errcode = '42501';
  end if;
  drop function if exists public.my_role_permissions();
  drop function if exists public.role_save(text, text, text, text, integer, boolean);
  drop function if exists public.role_permission_set(text, text, boolean);
  drop function if exists public.role_delete(text);
  drop table if exists public.role_permission cascade;
  drop table if exists public.role_definition cascade;
  -- A felület ilyenkor visszaesik a kódba égetett listákra, tehát a
  -- visszavonás után is mindenki pontosan azt látja, amit ma.
  return 'A 39-es visszavonva. A menü visszaáll a kódba égetett listákra.';
end $$;

revoke all on function public.role_admin_rollback() from public, anon;
grant execute on function public.role_admin_rollback() to authenticated;

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
-- 39 ellenőrzés: szerepkör-szerkesztés + a kizárás elleni védelem.
with o(s,mit,nev,t) as (values
  (1,'Szerepkör-tábla','role_definition','tab'),
  (2,'Szerepkör-jogosultság','role_permission','tab'),
  (3,'Saját menüpontjaim','my_role_permissions','fn'),
  (4,'Szerepkör mentése','role_save','fn'),
  (5,'Jogosultság állítása','role_permission_set','fn'),
  (6,'Szerepkör törlése','role_delete','fn'),
  (7,'Visszavonó','role_admin_rollback','fn')
),
letezik as (
  select o.s,o.mit,o.nev, case when case o.t
      when 'tab' then exists (select 1 from pg_tables where schemaname='public' and tablename=o.nev)
      when 'fn'  then exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                               where n.nspname='public' and p.proname=o.nev)
    end then 'OK' else '!! HIÁNYZIK' end from o
),
allapot as (
  select 20+row_number() over (order by rd.sorrend), 'Szerepkör: '||rd.nev, rd.kod,
         count(rp.permission)::text || ' menüpont' ||
         case when rd.kod='SUPERADMIN' then '  (nem a táblából — mindent lát)' else '' end
    from public.role_definition rd
    left join public.role_permission rp on rp.role_kod = rd.kod
   group by rd.kod, rd.nev, rd.sorrend
),
vedelem as (
  select 60,'A SUPERADMIN jogát nem lehet elvenni','role_permission_set',
         case when exists (select 1 from public.role_permission where role_kod='SUPERADMIN')
              then '!! van sora a táblában' else 'OK — nincs, és a szűrő sem nézi' end
),
anon_echo as (
  select 70,'ECHO anonimitás (21 utoljára futott?)','echo_submit',
         string_agg(distinct grantee,', ' order by grantee) ||
         case when bool_or(grantee='authenticated') then '   !! FUTTASD ÚJRA a 21-est' else '   OK' end
    from information_schema.routine_privileges where routine_name='echo_submit'
)
select mit as "mit ellenőrzünk", nev as "objektum", allapot as "állapot"
  from (select * from letezik union all select * from allapot
        union all select * from vedelem union all select * from anon_echo) x(s,mit,nev,allapot)
 order by s;
