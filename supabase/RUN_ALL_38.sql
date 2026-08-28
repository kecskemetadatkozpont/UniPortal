-- ============================================================================
-- RUN_ALL_38.sql  —  UniPortal
-- EGYBEN BEILLESZTHETŐ a Supabase SQL Editorba.
--
--   38_student_groups.sql      hallgatói besorolás, csoportok, jogosultság
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--   + a végén a MODUL SAJÁT ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a RUN_ALL_37.sql már lefutott.
-- Idempotens.
--
-- EZ CSAK A SÉMÁT HOZZA LÉTRE. A teszt-hallgatók besorolását a
-- teszt_jellemzok.sql tölti fel — azt EZUTÁN futtasd.
-- ============================================================================


-- ===========================================================================
-- >>> 38_student_groups.sql
-- ===========================================================================
-- ============================================================================
-- 38_student_groups.sql — hallgatói jellemzők, csoportok és csoport-jogosultság
-- ----------------------------------------------------------------------------
-- MIT AD
--   1. Hallgatói jellemzők (tagozat, képzési szint, szak, kar) — a Neptun-
--      kivonatból, hogy a Regisztrációk alatt látszódjanak és lehessen
--      szűrni/csoportosítani rájuk.
--   2. Csoportok: kézzel összeállított VAGY szabály alapján automatikus
--      (pl. "minden nappali tagozatos mérnökinformatikus").
--   3. Csoport-jogosultság: melyik felületeket lássa a csoport.
--
-- MIÉRT KÜLÖN TÁBLA A JELLEMZŐKNEK
--   A public.profiles táblát EGY MÁSIK ALKALMAZÁS IS HASZNÁLJA ebben a
--   Supabase projektben (lásd app.jsx: "profiles.status belongs to a different
--   app"). Új oszlopokat odatenni ütközést kockáztatna, ezért a jellemzők
--   saját táblába kerülnek, a profilra hivatkozva.
--
-- A JOGOSULTSÁG CSAK ADHAT, SOSEM VEHET EL
--   A menüszűrő utolsó ága ma `return false`. A csoport-jogosultság ELŐTTE
--   fut le, tehát legfeljebb megnyit egy felületet — elvenni nem tud semmit.
--   Így egy elrontott csoportszabály nem zárhat ki senkit a saját munkájából.
--
-- IDEMPOTENS. Visszavonás: select public.student_groups_rollback();
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) Hallgatói jellemzők
-- ---------------------------------------------------------------------------
create table if not exists public.student_attributes (
  profile_id    uuid primary key references public.profiles(id) on delete cascade,
  neptun        text,
  tagozat       text,
  kepzesi_szint text,
  szak          text,
  kar           text,
  szak_kod      text,
  nyelv         text,
  telephely     text,
  forras        text not null default 'neptun',
  updated_at    timestamptz not null default now()
);

create index if not exists student_attributes_tagozat_idx on public.student_attributes (tagozat);
create index if not exists student_attributes_szint_idx   on public.student_attributes (kepzesi_szint);
create index if not exists student_attributes_szak_idx    on public.student_attributes (szak);
create index if not exists student_attributes_kar_idx     on public.student_attributes (kar);

comment on table public.student_attributes is
  'Hallgatói besorolás a Neptun-kivonatból. Külön táblában, mert a profiles '
  'táblát egy másik alkalmazás is használja ebben a projektben.';

comment on column public.student_attributes.szak is
  'A képzés neve. A k-küszöb alatti szakok "egyéb képzés" néven vannak '
  'összevonva: egy egyfős szak a tagozattal és a szinttel együtt egyetlen '
  'valódi személyt azonosítana.';

-- ---------------------------------------------------------------------------
-- 2) Csoportok
-- ---------------------------------------------------------------------------
create table if not exists public.user_group (
  id          text primary key
                default left('GRP' || replace(gen_random_uuid()::text, '-', ''), 22),
  nev         text not null,
  leiras      text,
  tipus       text not null default 'kezi',
  szabaly     jsonb,
  szin        text,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint user_group_nev_uniq unique (nev),
  constraint user_group_tipus_ck check (tipus in ('kezi', 'szabaly')),
  -- Szabály alapú csoporthoz KELL szabály, kézihez nem lehet.
  constraint user_group_szabaly_ck check (
    (tipus = 'szabaly' and szabaly is not null) or
    (tipus = 'kezi'    and szabaly is null))
);

create table if not exists public.user_group_member (
  group_id   text not null references public.user_group(id) on delete cascade,
  profile_id uuid not null references public.profiles(id)   on delete cascade,
  added_by   uuid,
  added_at   timestamptz not null default now(),
  primary key (group_id, profile_id)
);

create index if not exists user_group_member_profile_idx
  on public.user_group_member (profile_id);

-- ---------------------------------------------------------------------------
-- 3) Csoport-jogosultság
--    A jogosultság egy MENÜPONT azonosítója (AppView), pl. 'echo_student'.
--    Szabad szöveg, mert a menü bővül — egy ismeretlen érték egyszerűen
--    nem illeszkedik semmire, tehát nem okoz kárt.
-- ---------------------------------------------------------------------------
create table if not exists public.group_permission (
  group_id   text not null references public.user_group(id) on delete cascade,
  permission text not null,
  granted_by uuid,
  granted_at timestamptz not null default now(),
  primary key (group_id, permission),
  constraint group_permission_shape_ck check (permission ~ '^[a-z0-9_]{2,40}$')
);

commit;

begin;

-- ---------------------------------------------------------------------------
-- 4) Szabály alapú csoport kiértékelése
--
--    A szabály egy egyszerű JSON, MEZŐ -> ÉRTÉKLISTA alakban:
--      {"tagozat": ["Nappali"], "szak": ["mérnökinformatikus", "gépészmérnöki"]}
--    A mezők ÉS kapcsolatban, a listán belüli értékek VAGY kapcsolatban állnak.
--
--    Szándékosan NEM szabad SQL-t fogadunk el: egy felületről beírt szabály
--    soha ne tudjon tetszőleges lekérdezést futtatni. A megengedett mezők
--    listája alább zárt.
-- ---------------------------------------------------------------------------
create or replace function public.group_rule_matches(p_rule jsonb, p_profile uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_a     public.student_attributes;
  v_mezo  text;
  v_ertek jsonb;
  v_van   text;
begin
  if p_rule is null or jsonb_typeof(p_rule) <> 'object' then return false; end if;
  select * into v_a from public.student_attributes where profile_id = p_profile;
  if v_a.profile_id is null then return false; end if;

  for v_mezo, v_ertek in select key, value from jsonb_each(p_rule)
  loop
    -- ZÁRT MEZŐLISTA. Ismeretlen mezőre a szabály NEM illeszkedik — így egy
    -- elgépelt mezőnév nem nyit meg véletlenül mindenkinek mindent.
    v_van := case v_mezo
      when 'tagozat'       then v_a.tagozat
      when 'kepzesi_szint' then v_a.kepzesi_szint
      when 'szak'          then v_a.szak
      when 'kar'           then v_a.kar
      when 'nyelv'         then v_a.nyelv
      when 'telephely'     then v_a.telephely
      else null
    end;
    if v_van is null then return false; end if;

    if jsonb_typeof(v_ertek) = 'array' then
      if not exists (
        select 1 from jsonb_array_elements_text(v_ertek) x where x = v_van
      ) then return false; end if;
    else
      if v_ertek #>> '{}' is distinct from v_van then return false; end if;
    end if;
  end loop;

  return true;
end $$;

-- ---------------------------------------------------------------------------
-- 5) Egy profil csoportjai — kézi tagság ÉS illeszkedő szabály
-- ---------------------------------------------------------------------------
create or replace function public.groups_of(p_profile uuid)
returns setof public.user_group
language sql
stable
security definer
set search_path = public
as $$
  select g.* from public.user_group g
   where g.tipus = 'kezi'
     and exists (select 1 from public.user_group_member m
                  where m.group_id = g.id and m.profile_id = p_profile)
  union
  select g.* from public.user_group g
   where g.tipus = 'szabaly'
     and public.group_rule_matches(g.szabaly, p_profile)
$$;

-- ---------------------------------------------------------------------------
-- 6) A saját jogosultságaim — ezt hívja a felület bejelentkezéskor
-- ---------------------------------------------------------------------------
create or replace function public.my_group_permissions()
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct gp.permission), '{}')
    from public.groups_of(auth.uid()) g
    join public.group_permission gp on gp.group_id = g.id
$$;

-- ---------------------------------------------------------------------------
-- 7) Egy csoport tagjai (a felület mutatja a létszámot és a listát)
-- ---------------------------------------------------------------------------
create or replace function public.group_members(p_group text)
returns table (profile_id uuid, email text, nev text, tagozat text,
               kepzesi_szint text, szak text, kar text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_g public.user_group;
begin
  if not public.is_staff() then
    raise exception 'Csoporttagságot csak ügyintéző nézhet.' using errcode = '42501';
  end if;
  select * into v_g from public.user_group where id = p_group;
  if v_g.id is null then raise exception 'Nincs ilyen csoport: %', p_group using errcode='02000'; end if;

  if v_g.tipus = 'kezi' then
    return query
      select p.id, p.email, p.name, a.tagozat, a.kepzesi_szint, a.szak, a.kar
        from public.user_group_member m
        join public.profiles p on p.id = m.profile_id
        left join public.student_attributes a on a.profile_id = p.id
       where m.group_id = p_group
       order by p.name;
  else
    return query
      select p.id, p.email, p.name, a.tagozat, a.kepzesi_szint, a.szak, a.kar
        from public.profiles p
        join public.student_attributes a on a.profile_id = p.id
       where public.group_rule_matches(v_g.szabaly, p.id)
       order by p.name;
  end if;
end $$;

commit;

begin;

-- ---------------------------------------------------------------------------
-- 8) Csoport létrehozása / módosítása
-- ---------------------------------------------------------------------------
create or replace function public.group_save(
  p_id      text default null,
  p_nev     text default null,
  p_leiras  text default null,
  p_tipus   text default 'kezi',
  p_szabaly jsonb default null,
  p_szin    text default null)
returns public.user_group
language plpgsql security definer set search_path = public
as $$
declare v_g public.user_group;
begin
  if not public.is_admin() and not public.is_superadmin() then
    raise exception 'Csoportot csak admin kezelhet.' using errcode = '42501';
  end if;
  if p_tipus not in ('kezi', 'szabaly') then
    raise exception 'Ismeretlen csoporttípus: %', p_tipus using errcode = '22023';
  end if;
  if p_tipus = 'szabaly' and p_szabaly is null then
    raise exception 'Szabály alapú csoporthoz szabály is kell.' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.user_group(nev, leiras, tipus, szabaly, szin, created_by)
    values (btrim(p_nev), p_leiras, p_tipus,
            case when p_tipus = 'szabaly' then p_szabaly else null end,
            p_szin, auth.uid())
    returning * into v_g;
  else
    update public.user_group
       set nev     = coalesce(btrim(p_nev), nev),
           leiras  = coalesce(p_leiras, leiras),
           tipus   = coalesce(p_tipus, tipus),
           szabaly = case when coalesce(p_tipus, tipus) = 'szabaly'
                          then coalesce(p_szabaly, szabaly) else null end,
           szin    = coalesce(p_szin, szin),
           updated_at = now()
     where id = p_id
    returning * into v_g;
    if v_g.id is null then raise exception 'Nincs ilyen csoport: %', p_id using errcode='02000'; end if;
  end if;
  return v_g;
end $$;

-- ---------------------------------------------------------------------------
-- 9) Tagság és jogosultság állítása
-- ---------------------------------------------------------------------------
create or replace function public.group_member_set(
  p_group text, p_profile uuid, p_tag boolean)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() and not public.is_superadmin() then
    raise exception 'Csoporttagságot csak admin állíthat.' using errcode = '42501';
  end if;
  if exists (select 1 from public.user_group where id = p_group and tipus = 'szabaly') then
    raise exception
      'Ez szabály alapú csoport — a tagság a szabályból következik, kézzel nem állítható.'
      using errcode = '42501';
  end if;
  if p_tag then
    insert into public.user_group_member(group_id, profile_id, added_by)
    values (p_group, p_profile, auth.uid())
    on conflict do nothing;
  else
    delete from public.user_group_member where group_id = p_group and profile_id = p_profile;
  end if;
  return true;
end $$;

create or replace function public.group_permission_set(
  p_group text, p_permission text, p_ad boolean)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'Jogosultságot csak szuperadmin adhat.' using errcode = '42501';
  end if;
  if p_ad then
    insert into public.group_permission(group_id, permission, granted_by)
    values (p_group, p_permission, auth.uid())
    on conflict do nothing;
  else
    delete from public.group_permission where group_id = p_group and permission = p_permission;
  end if;
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- 10) A felület nézete: profil + jellemzők + csoportok egy sorban
-- ---------------------------------------------------------------------------
create or replace view public.registration_directory as
  select
    p.id, p.email, p.name, p.role, p.approval_status, p.created_at,
    a.neptun, a.tagozat, a.kepzesi_szint, a.szak, a.kar, a.nyelv, a.telephely,
    coalesce((
      select array_agg(g.nev order by g.nev) from public.groups_of(p.id) g
    ), '{}') as csoportok
  from public.profiles p
  left join public.student_attributes a on a.profile_id = p.id;

grant select on public.registration_directory to authenticated;

commit;

begin;

-- ---------------------------------------------------------------------------
-- 11) Sorszintű biztonság
--     A jellemzőket az ügyintéző látja, a hallgató a sajátját. A csoportokat
--     minden jóváhagyott fiók OLVASHATJA — a felület ebből tudja eldönteni,
--     mit mutasson —, de írni csak admin tud, méghozzá RPC-n át.
-- ---------------------------------------------------------------------------
alter table public.student_attributes enable row level security;
alter table public.user_group          enable row level security;
alter table public.user_group_member   enable row level security;
alter table public.group_permission    enable row level security;

drop policy if exists sa_select on public.student_attributes;
create policy sa_select on public.student_attributes for select
  using (public.is_staff() or profile_id = auth.uid());

drop policy if exists sa_write on public.student_attributes;
create policy sa_write on public.student_attributes for all
  using (public.is_admin() or public.is_superadmin())
  with check (public.is_admin() or public.is_superadmin());

drop policy if exists ug_select on public.user_group;
create policy ug_select on public.user_group for select using (public.is_approved());
drop policy if exists ug_write on public.user_group;
create policy ug_write on public.user_group for all
  using (public.is_admin() or public.is_superadmin())
  with check (public.is_admin() or public.is_superadmin());

drop policy if exists ugm_select on public.user_group_member;
create policy ugm_select on public.user_group_member for select
  using (public.is_staff() or profile_id = auth.uid());
drop policy if exists ugm_write on public.user_group_member;
create policy ugm_write on public.user_group_member for all
  using (public.is_admin() or public.is_superadmin())
  with check (public.is_admin() or public.is_superadmin());

drop policy if exists gp_select on public.group_permission;
create policy gp_select on public.group_permission for select using (public.is_approved());
drop policy if exists gp_write on public.group_permission;
create policy gp_write on public.group_permission for all
  using (public.is_superadmin()) with check (public.is_superadmin());

grant select on public.student_attributes, public.user_group,
                public.user_group_member, public.group_permission to authenticated;

revoke all on function public.group_save(text, text, text, text, jsonb, text) from public, anon;
revoke all on function public.group_member_set(text, uuid, boolean)           from public, anon;
revoke all on function public.group_permission_set(text, text, boolean)       from public, anon;
revoke all on function public.group_members(text)                             from public, anon;
revoke all on function public.my_group_permissions()                          from public, anon;
revoke all on function public.groups_of(uuid)                                 from public, anon;

grant execute on function public.group_save(text, text, text, text, jsonb, text) to authenticated;
grant execute on function public.group_member_set(text, uuid, boolean)           to authenticated;
grant execute on function public.group_permission_set(text, text, boolean)       to authenticated;
grant execute on function public.group_members(text)                             to authenticated;
grant execute on function public.my_group_permissions()                          to authenticated;
grant execute on function public.groups_of(uuid)                                 to authenticated;

-- ---------------------------------------------------------------------------
-- 12) Visszavonás
-- ---------------------------------------------------------------------------
create or replace function public.student_groups_rollback()
returns text language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'Csak szuperadmin vonhatja vissza.' using errcode = '42501';
  end if;
  drop view if exists public.registration_directory;
  drop function if exists public.group_save(text, text, text, text, jsonb, text);
  drop function if exists public.group_member_set(text, uuid, boolean);
  drop function if exists public.group_permission_set(text, text, boolean);
  drop function if exists public.group_members(text);
  drop function if exists public.my_group_permissions();
  drop function if exists public.groups_of(uuid);
  drop function if exists public.group_rule_matches(jsonb, uuid);
  drop table if exists public.group_permission  cascade;
  drop table if exists public.user_group_member cascade;
  drop table if exists public.user_group        cascade;
  drop table if exists public.student_attributes cascade;
  return 'A 38-as visszavonva. A profiles táblához nem nyúltunk.';
end $$;

revoke all on function public.student_groups_rollback() from public, anon;
grant execute on function public.student_groups_rollback() to authenticated;

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
-- 38 ellenőrzés: hallgatói besorolás, csoportok, jogosultság — egy táblában.
with o(s,mit,nev,t) as (values
  (1,'Jellemzők táblája','student_attributes','tab'),
  (2,'Csoportok','user_group','tab'),
  (3,'Csoporttagság','user_group_member','tab'),
  (4,'Csoport-jogosultság','group_permission','tab'),
  (5,'Szabály-kiértékelő','group_rule_matches','fn'),
  (6,'Egy profil csoportjai','groups_of','fn'),
  (7,'Saját jogosultságaim','my_group_permissions','fn'),
  (8,'Csoport tagjai','group_members','fn'),
  (9,'Csoport mentése','group_save','fn'),
  (10,'Tagság állítása','group_member_set','fn'),
  (11,'Jogosultság állítása','group_permission_set','fn'),
  (12,'Visszavonó','student_groups_rollback','fn'),
  (13,'Regisztrációs nézet','registration_directory','view')
),
letezik as (
  select o.s,o.mit,o.nev,
    case when case o.t
      when 'tab'  then exists (select 1 from pg_tables where schemaname='public' and tablename=o.nev)
      when 'fn'   then exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                                where n.nspname='public' and p.proname=o.nev)
      when 'view' then exists (select 1 from pg_views where schemaname='public' and viewname=o.nev)
    end then 'OK' else '!! HIÁNYZIK' end
  from o
),
-- ÉLŐ PRÓBA: egy elgépelt mezőnevű szabály senkire illeszkedjen, ne mindenkire.
zart as (
  select 40, 'Élő próba: elgépelt szabály-mező', 'group_rule_matches',
         case when public.group_rule_matches('{"tagozatt":["Nappali"]}'::jsonb,
                (select profile_id from public.student_attributes limit 1)) is not true
              then 'OK — senkire nem illeszkedik'
              else '!! VESZÉLY: ismeretlen mező átengedi' end
),
-- Ellenpróba: a helyes mezőnév viszont illeszkedjen (különben a próba vak).
nemvak as (
  select 41, 'Ellenpróba: helyes mezőnév', 'group_rule_matches',
         coalesce((select case when public.group_rule_matches(
                    jsonb_build_object('tagozat', jsonb_build_array(a.tagozat)), a.profile_id)
                  then 'OK — illeszkedik, a próba nem vak'
                  else '!! nem illeszkedik' end
              from public.student_attributes a where a.tagozat is not null limit 1),
              'nincs adat a próbához')
),
adat as (
  select 50,'Besorolt hallgató','student_attributes', count(*)::text from public.student_attributes
  union all select 51,'Csoport','user_group', count(*)::text from public.user_group
  union all select 52,'Kiosztott jogosultság','group_permission', count(*)::text from public.group_permission
),
kuszob as (
  select 60,'Legkisebb besorolási cella','szak × tagozat × szint',
         coalesce(min(n)::text,'—') ||
         case when min(n) is null then '' when min(n) >= 5 then '  OK' else '  !! k-küszöb alatt' end
    from (select count(*) n from public.student_attributes
           where szak is not null group by szak, tagozat, kepzesi_szint) t
),
anon_echo as (
  select 70,'ECHO anonimitás (21 utoljára futott?)','echo_submit',
         string_agg(distinct grantee,', ' order by grantee) ||
         case when bool_or(grantee='authenticated') then '   !! FUTTASD ÚJRA a 21-est' else '   OK' end
    from information_schema.routine_privileges where routine_name='echo_submit'
)
select mit as "mit ellenőrzünk", nev as "objektum", allapot as "állapot"
  from (select * from letezik union all select * from zart union all select * from nemvak
        union all select * from adat union all select * from kuszob
        union all select * from anon_echo) x(s,mit,nev,allapot)
 order by s;


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
