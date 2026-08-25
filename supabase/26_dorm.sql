-- ============================================================================
-- 26_dorm.sql — Kollégium- és ingatlanüzemeltetési modul: adatbázis-réteg
-- Neumann János Egyetem — UniPortal
-- Változat: 2026-08-24, HELYI POSTGRES 16 REPLIKÁN MÉRVE (fresh, 01→25 betöltve)
-- ELŐFELTÉTEL: 11_rbac_additive.sql (is_approved/is_admin/has_role/my_*),
--              25_status_model.sql (log_status_event, katalógus+átmenet minta).
-- ============================================================================
--
-- ---------------------------------------------------------------------------
-- MIÉRT
-- ---------------------------------------------------------------------------
-- A megrendelő szavaival: "melyik létesítményünkben hány szoba van, kik vannak
-- benne, milyen üzemeltetési feladatok vannak az adott szobákban". Ma erre a
-- kérdésre a UniPortal-ban NINCS adat: mérve a public sémában 29 tábla van,
-- egyikben sem szerepel épület, szoba, férőhely vagy hibajegy fogalma.
--
-- A modul EGYSZERRE kezeli a saját kollégiumokat és a bérelt épületeket, mert
-- a lakó szempontjából mindegy, kinek a falai közt nem megy a fűtés, a vezetői
-- riport pedig csak akkor összehasonlítható, ha egy nyilvántartásban van a
-- kettő. A különbséget NEM külön modul, hanem egyetlen jogcím-dimenzió
-- (dorm.building.tenure) és a FELELŐSSÉGI MÁTRIX (dorm.responsibility) viszi.
--
-- ---------------------------------------------------------------------------
-- A HAT SZERKEZETI DÖNTÉS
-- ---------------------------------------------------------------------------
--
--  1. KÜLÖN `dorm` SÉMA, DE — az ECHO-val ELLENTÉTBEN — KITÉVE (Exposed
--     schemas: public, dorm), RLS-sel védve.
--     Indok: a public séma ma 29 táblát tart, a modul 30+ táblát hoz — a
--     prefixelés a Table Editort és a PostgREST felületét használhatatlanná
--     tenné, a séma-szintű `revoke ... from anon` és az `alter default
--     privileges in schema dorm` viszont EGY mondat, és a JÖVŐBENI táblákra
--     is hat. Az ECHO azért zárta ki a sémát a PostgREST elől, mert ott az
--     anonimitás matematikai követelmény, és ezért kellett 31 híd-RPC-t írnia.
--     A kollégiumi adat nem anonim, hanem SZEMÉLYES: a védelem eszköze az RLS,
--     ami a PostgREST-en át pontosan úgy működik, mint a public sémán (mérve:
--     86 rbac_ policy fut 22 táblán). Az üzemeltetés napi munkája szűrés,
--     rendezés, lapozás — erre az RPC-only út minden szűrőnél új szerveroldali
--     függvényt jelentene.
--
--  2. A FÉRŐHELY (bed) ÖNÁLLÓ ENTITÁS, NEM A SZOBA.
--     Egy 3 ágyas szoba két lakóval szobaszinten "foglalt", miközben 1 szabad
--     hely van benne — a megrendelő fájdalma pontosan ez. A szerződés, a
--     kaució, a kulcs, a kárfelelősség és a díj is ágyra szól. A `bed`
--     FÉRŐHELY-ABSZTRAKCIÓ, nem bútor: egy garzon = 1 férőhely, így a
--     kapacitásszámítás saját és bérelt épületre egységes marad.
--
--  3. AZ ELHELYEZÉS IDŐINTERVALLUM, ÉS AZ ÁTFEDÉST AZ ADATBÁZIS TILTJA.
--     dorm.occupancy.period daterange + EXCLUDE USING gist (bed_id =, period &&).
--     A dupla foglalás a rendszer legdrágább hibája; alkalmazáslogikából
--     párhuzamos kiosztásnál nem védhető ki, constraint-ből igen. Mellékhaszon:
--     "mely ágyak szabadok 2027-02-01 és 2027-06-30 közt" egy range-lekérdezés,
--     a februári felszabadulás pedig már novemberben látszik.
--
--  4. A FELELŐSSÉGI MÁTRIX ADAT, NEM DOKUMENTUM — HÁROM SZINTŰ ÖRÖKLÉSSEL.
--     épület-szintű sor → jogcím-szintű alapértelmezés → globális alapértelmezés.
--     Egy új bérelt épületnél így csak az ELTÉRÉSEKET kell rögzíteni (2-4 sor),
--     nem mind a 18 kategóriát. A hibabejelentés pillanatában a rendszer
--     megmondja, kihez megy, mi a határidő és MELYIK SZERZŐDÉSPONT alapján.
--
--  5. NEM BŐVÍTJÜK A profiles.role ENUMOT — hatókörös grant-dimenzió jön.
--     MÉRVE (app.jsx:10578): a menüszűrő utolsó ága `return false`, egy új
--     szerepkör-érték üres oldalsávot kapna. MÉRVE (11_rbac_additive.sql 1.10):
--     a public.is_staff() fehérlistája ('SUPERADMIN','ADMIN','ADMISSIONS',
--     'FINANCE') — erre épül a 08-as storage-policy, a 10-es wa_* policy és a
--     86 rbac_ policy jelentős része. Ezért a modul is az echo.role_grant
--     mintáját követi, azzal a különbséggel, hogy a hatókör NEM szervezeti
--     egység, hanem ÉPÜLET — és ezért NINCS rekurzív CTE.
--
--  6. A LAKÓ SAJÁT ENTITÁS (dorm.person), NEM a students sor.
--     A lakó lehet vendégkutató, Erasmus-hallgató, nyári bérlő vagy alkalmazott
--     — ezeknek soha nem volt és nem is lehet students soruk (a students a
--     JELENTKEZÉS nyilvántartása, nem a SZEMÉLYÉ; a 14-es migráció végén
--     kikommentelve maradt "fiktív jelentkezői sor" blokk jó okkal maradt ott).
--     Kötés: két RÉSZLEGES UNIQUE index (student_id, profile_id) — betűre az
--     echo_teacher_profile_uidx mintája, mert a my_person_id() törzse limit 1,
--     és kötés nélkül CSENDBEN választana.
--
-- ---------------------------------------------------------------------------
-- ADATVÉDELEM — a "ki hol lakik" adat
-- ---------------------------------------------------------------------------
-- A modul legérzékenyebb adata a lakóhely. A karbantartónak NEM kell tudnia,
-- kinek a szobájába megy javítani — csak azt, melyik szobába. Ezért két nézet
-- választja szét a két olvasatot:
--   dorm.v_room_operational — szoba, kapacitás, FOGLALTAK SZÁMA, nyitott hibák
--                             (NÉV NÉLKÜL) → GONDNOK, KARBANTARTO, INGATLAN
--   dorm.v_room_occupancy   — ugyanez + a lakók neve, elérhetősége
--                             → GONDNOK, KOLI_ADMIN (saját épület), is_admin()
-- Mindkét nézet OWNER-jogú (nem security_invoker), és a hatókör-szűrés
-- MAGÁBAN A NÉZETBEN van (dorm.can_see_building / dorm.can_see_residents) —
-- így a szűrés nem felejthető el a hívó oldalon.
--
-- Az olvasás is naplózandó (dorm.access_log), mert itt a JOGOSULATLAN
-- MEGTEKINTÉS a kár, nem a módosítás. A naplóba a szűrőfeltétel és a
-- SORSZÁM kerül, maga a lakólista SOHA — különben a naplótábla lenne a
-- legnagyobb, legkevésbé védett másolat az adatból.
--
-- ---------------------------------------------------------------------------
-- IDEMPOTENS: kétszer lefuttatva ugyanaz az eredmény (mérve, ON_ERROR_STOP=1).
-- EGY TRANZAKCIÓ: begin ... commit, a végén ellenőrző lekérdezésekkel.
-- VISSZAÚT: public.dorm_module_rollback(p_confirm text) — lásd 14. szakasz.
-- A FRONTENDHEZ NEM NYÚL: app.jsx / index.html / app.html / features/*.jsx
-- érintetlen (párhuzamos reszponzív munka folyik rajtuk).
-- ============================================================================

-- MEGJEGYZÉS: itt korábban egy \set ON_ERROR_STOP on sor állt. Az psql
-- meta-parancs, amit a Supabase SQL Editor NEM ismer ('syntax error at or
-- near "\"'). Nincs is rá szükség: az egész migráció EGYETLEN tranzakcióban
-- fut (begin ... commit), tehát bármelyik utasítás hibája a TELJES migrációt
-- visszagörgeti — félkész séma nem maradhat.
-- Parancssorból futtatva a védelmet a psql -v ON_ERROR_STOP=1 kapcsoló adja.

begin;

select set_config('search_path', 'public, extensions, pg_temp', true);


-- ============================================================================
-- 0. SZAKASZ — ELŐFELTÉTELEK
-- ============================================================================
-- Inkább álljunk meg beszédes hibával, mint hogy félkész séma maradjon.
do $pre$
declare v_missing text := '';
begin
  if to_regprocedure('public.is_approved()')      is null then v_missing := v_missing || ' public.is_approved()';      end if;
  if to_regprocedure('public.is_admin()')         is null then v_missing := v_missing || ' public.is_admin()';         end if;
  if to_regprocedure('public.is_staff()')         is null then v_missing := v_missing || ' public.is_staff()';         end if;
  if to_regprocedure('public.my_email()')         is null then v_missing := v_missing || ' public.my_email()';         end if;
  if to_regprocedure('public.my_student_id()')    is null then v_missing := v_missing || ' public.my_student_id()';    end if;
  if to_regprocedure('public.log_status_event(text,text,text)') is null
    then v_missing := v_missing || ' public.log_status_event() (25_status_model.sql)'; end if;
  if to_regclass('public.profiles')  is null then v_missing := v_missing || ' public.profiles';  end if;
  if to_regclass('public.students')  is null then v_missing := v_missing || ' public.students';  end if;
  if v_missing <> '' then
    raise exception 'DORM_PREREQ_MISSING: hianyzik:%. Futtasd elobb a 11-es es a 25-os migraciot.', v_missing;
  end if;
end
$pre$;

-- A btree_gist a férőhely-átfedés tiltásához kell (uuid = + daterange && egy
-- gist indexben). MÉRVE: elérhető (1.7), de nincs telepítve.
do $ext$
begin
  if not exists (select 1 from pg_extension where extname = 'btree_gist') then
    if to_regnamespace('extensions') is not null then
      execute 'create extension btree_gist with schema extensions';
    else
      execute 'create extension btree_gist';
    end if;
  end if;
end
$ext$;


-- ============================================================================
-- 1. SZAKASZ — A SÉMA ÉS A JOGOSULTSÁGI ALAPHELYZET
-- ============================================================================
-- A séma KITETT (Exposed schemas: public, dorm), de az `anon` SOHA nem kap
-- semmit: a kollégiumi adat egyetlen szeletét sem szabad bejelentkezés nélkül
-- elérni. A default privileges a JÖVŐBENI táblákra is hat — ez a fő indoka
-- annak, hogy külön séma és nem `dorm_` prefix (a 19_echo_roles.sql 1. szakasza
-- pont azért kényszerült megismételni a revoke-ot, mert a public sémában a
-- korábbi grant-blokk már lefutott).

create schema if not exists dorm;
comment on schema dorm is
  'Kollégium- és ingatlanüzemeltetés (26_dorm.sql). KITETT séma, RLS-sel védve. anon SOHA nem kap jogot.';

revoke all on schema dorm from public;
revoke usage on schema dorm from anon;
grant  usage on schema dorm to authenticated, service_role;

alter default privileges in schema dorm revoke all on tables    from anon;
alter default privileges in schema dorm revoke all on sequences from anon;
alter default privileges in schema dorm revoke all on functions from anon;
alter default privileges in schema dorm grant select on tables to authenticated;
alter default privileges in schema dorm grant all    on tables to service_role;


-- ============================================================================
-- 2. SZAKASZ — A HATÓKÖRÖS SZEREPKÖR-DIMENZIÓ
-- ============================================================================
-- Szerkezetileg az echo.role_grant mása, EGYETLEN eltéréssel: a hatókör
-- dimenziója nem szervezeti egység, hanem épület. Az ECHO-nál rekurzív CTE
-- kellett (a dékánnak a tanszékeit is látnia kell); itt az épület a legkisebb
-- hatókör-egység, a szint és a szoba alatta van, de grantot nem kap.
-- scope_building is null = intézményi hatókör (minden épület).
--
-- ÖT szerepkör (az ECHO nyolcával szemben — itt kevesebb elég):
--   GONDNOK       — saját épülete(i): szobák, be-/kiköltöztetés, kulcs, leltár,
--                   hibajegy lezárása, LAKÓNÉVVEL                 [épület]
--   KARBANTARTO   — hibajegyek és munkalapok, LAKÓNÉV NÉLKÜL      [épület v. intézményi]
--   KOLI_ADMIN    — férőhelykiosztás, szerződés, várólista, díj    [tipikusan intézményi]
--   INGATLAN      — bérelt épületek: bérleti szerződés, rezsi,
--                   bérbeadói kapcsolat, lejáratfigyelés.
--                   LAKÓI NÉVSORT EGYÁLTALÁN NEM LÁT.             [intézményi]
--   KOLI_SYSADMIN — grantok, katalógusok                          [intézményi]

create table if not exists dorm.role_grant (
  id             uuid primary key default gen_random_uuid(),
  person         uuid not null references public.profiles(id) on delete cascade,
  role           text not null,
  scope_building uuid,                      -- FK a 4. szakaszban (a building még nem létezik)
  granted_by     uuid references public.profiles(id) on delete set null,
  granted_at     timestamptz not null default now(),
  expires_at     timestamptz,               -- visszavonás = expires_at := now(), NEM sortörlés
  iktatoszam     text,
  megjegyzes     text
);

-- CHECK és nem enum: a 19-es indoka szerint az enum bővítése nem vonható
-- vissza tranzakción belül, a CHECK cseréje viszont igen.
do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'dorm_role_grant_role_chk') then
    alter table dorm.role_grant add constraint dorm_role_grant_role_chk
      check (role in ('GONDNOK','KARBANTARTO','KOLI_ADMIN','INGATLAN','KOLI_SYSADMIN'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'dorm_role_grant_iktato_chk') then
    alter table dorm.role_grant add constraint dorm_role_grant_iktato_chk
      check (iktatoszam is null or (length(btrim(iktatoszam)) between 1 and 64));
  end if;
end
$c$;

-- Két RÉSZLEGES egyedi index: a sima UNIQUE a NULL scope-ot nem fogná össze
-- (NULL <> NULL), így ugyanaz az intézményi grant tetszőlegesen sokszor
-- bekerülhetne, és a visszavonás (expires_at) nem lenne egyértelmű.
create unique index if not exists dorm_role_grant_global_uidx
  on dorm.role_grant (person, role) where scope_building is null;
create unique index if not exists dorm_role_grant_scoped_uidx
  on dorm.role_grant (person, role, scope_building) where scope_building is not null;
create index if not exists dorm_role_grant_person_idx on dorm.role_grant (person);
create index if not exists dorm_role_grant_role_idx   on dorm.role_grant (role);

comment on table dorm.role_grant is
  'A modul saját, HATÓKÖRÖS szerepkör-dimenziója. NEM bővíti a profiles.role enumot (lásd 5. szerkezeti döntés). Visszavonás: expires_at := now(), soha nem sortörlés.';


-- --- 2.1 A jogosultsági helperek --------------------------------------------
-- Mind SECURITY DEFINER, RÖGZÍTETT search_path-tal — a public.is_staff() és az
-- echo.has_role() mintájára. A public.is_approved() BEÉPÍTETT feltétel: egyetlen
-- hívó sem felejtheti el, és egy visszavont fiók grantja sem éled újra.
-- DEFINER volta egyben azt is jelenti, hogy a role_grant RLS-e nem okoz
-- rekurziót, amikor a policy-k ezeket a függvényeket hívják.

create or replace function dorm.has_role(p_role text, p_building uuid default null)
returns boolean
language sql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
  select public.is_approved()
     and exists (
       select 1 from dorm.role_grant g
        where g.person = auth.uid()
          and g.role   = p_role
          and (g.expires_at is null or g.expires_at > now())
          and (p_building is null or g.scope_building is null or g.scope_building = p_building)
     )
$$;

create or replace function dorm.has_any_role(p_roles text[], p_building uuid default null)
returns boolean
language sql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
  select public.is_approved()
     and exists (
       select 1 from dorm.role_grant g
        where g.person = auth.uid()
          and g.role   = any (p_roles)
          and (g.expires_at is null or g.expires_at > now())
          and (p_building is null or g.scope_building is null or g.scope_building = p_building)
     )
$$;

-- Tyúk-tojás híd, az echo.can_grant() mintájára: az ELSŐ grantot az is_admin()
-- adja; amint van KOLI_SYSADMIN, ez az ág egy KÉSŐBBI migrációval kivehető.
-- Most nem vesszük ki: enélkül senki nem tudna grantot osztani.
create or replace function dorm.can_grant()
returns boolean language sql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$ select public.is_admin() or dorm.has_role('KOLI_SYSADMIN') $$;

-- Üzemeltetői kör: aki az épület MŰSZAKI adatait láthatja (lakónév nélkül is).
create or replace function dorm.can_see_building(p_building uuid)
returns boolean language sql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
  select public.is_admin()
      or dorm.has_any_role(array['GONDNOK','KARBANTARTO','KOLI_ADMIN','INGATLAN','KOLI_SYSADMIN'], p_building)
$$;

-- A "ki hol lakik" jogosulti köre. SZŰKEBB, mint a can_see_building():
-- a KARBANTARTO és az INGATLAN SZÁNDÉKOSAN kimarad (8.4: a karbantartó a
-- szobát lássa, a lakót ne; az ingatlangazda lakói névsort egyáltalán ne).
create or replace function dorm.can_see_residents(p_building uuid)
returns boolean language sql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
  select public.is_admin()
      or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], p_building)
$$;

-- A kiosztást és a szerződést végző kör (írási jog a lakói oldalon).
create or replace function dorm.can_place(p_building uuid default null)
returns boolean language sql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
  select public.is_admin()
      or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN'], p_building)
      or dorm.has_role('GONDNOK', p_building)
$$;

-- MEGJEGYZÉS: a dorm.my_person_id() és a dorm.my_building_ids() a 11.0
-- szakaszban jön létre, mert a törzsük a dorm.person és a dorm.building
-- táblákra hivatkozik — egy `language sql` függvény törzsét a PostgreSQL már
-- LÉTREHOZÁSKOR feloldja, tehát a tábláknak addigra léteznie kell.


-- ============================================================================
-- 3. SZAKASZ — KATALÓGUSOK
-- ============================================================================
-- Katalógustábla és NEM CHECK constraint / szabad szöveg: ez a 25-ös migráció
-- tanulsága. Új szobastátuszt vagy hibakategóriát egy INSERT-tel fel lehet
-- venni, migráció és táblaátírás nélkül; a felület legördülői ugyanebből a
-- sorrendből és címkékből dolgoznak.

-- --- 3.1 Jogcím (tenure) — a saját/bérelt megkülönböztetés EGYETLEN helye ----
create table if not exists dorm.tenure (
  code            text primary key,
  label_hu        text not null,
  label_en        text not null,
  is_owned        boolean not null,   -- saját tulajdon?
  needs_landlord  boolean not null,   -- kell-e bérbeadó rekord és szerződés?
  counts_capacity boolean not null default true,
  sort_order      integer not null default 100
);

insert into dorm.tenure (code, label_hu, label_en, is_owned, needs_landlord, counts_capacity, sort_order) values
  ('OWNED',               'Saját tulajdon',                    'Owned',                  true,  false, true,  10),
  ('OWNED_OUT_OF_USE',    'Saját, jelenleg nem hasznosított',  'Owned, out of use',      true,  false, false, 20),
  ('LEASED_WHOLE',        'Teljes épület bérlete',             'Whole building leased',  false, true,  true,  30),
  ('LEASED_PARTIAL',      'Részleges bérlet (szint/lakások)',  'Partially leased',       false, true,  true,  40),
  ('CONTRACTED_CAPACITY', 'Szerződött férőhely idegen üzemeltetőnél', 'Contracted capacity', false, true, true, 50),
  ('MANAGED_FOR_OTHER',   'Idegen tulajdon, mi üzemeltetjük',  'Managed for other',      false, true,  true,  60)
on conflict (code) do update
  set label_hu = excluded.label_hu, label_en = excluded.label_en,
      is_owned = excluded.is_owned, needs_landlord = excluded.needs_landlord,
      counts_capacity = excluded.counts_capacity, sort_order = excluded.sort_order;

comment on table dorm.tenure is
  'A jogcím-dimenzió. A CONTRACTED_CAPACITY külön léte azért kell, mert ott a szoba műszaki állapotára NINCS ráhatásunk, a hibajegy egyetlen útja a partner felé megy — miközben a lakóért és a díjért mi felelünk.';

-- --- 3.2 Szobatípus ---------------------------------------------------------
create table if not exists dorm.room_type (
  code        text primary key,
  label_hu    text not null,
  label_en    text not null,
  default_beds integer not null default 1,
  sort_order  integer not null default 100
);

insert into dorm.room_type (code, label_hu, label_en, default_beds, sort_order) values
  ('SINGLE',    'Egyágyas',                'Single room',      1, 10),
  ('DOUBLE',    'Kétágyas',                'Double room',      2, 20),
  ('TRIPLE',    'Háromágyas',              'Triple room',      3, 30),
  ('QUAD',      'Négyágyas',               'Quad room',        4, 40),
  ('APARTMENT', 'Apartman (több szobás)',  'Apartment',        2, 50),
  ('STUDIO',    'Garzon',                  'Studio',           1, 60),
  ('DORMITORY', 'Közös hálóterem',         'Shared dormitory', 8, 70),
  ('COMMON',    'Közös helyiség',          'Common area',      0, 80),
  ('SERVICE',   'Szolgálati helyiség',     'Service room',     0, 90),
  ('TECHNICAL', 'Gépészeti helyiség',      'Technical room',   0, 95)
on conflict (code) do update
  set label_hu = excluded.label_hu, label_en = excluded.label_en,
      default_beds = excluded.default_beds, sort_order = excluded.sort_order;

-- --- 3.3 Szobastátusz — a három kapacitásfogalom forrása --------------------
-- 1. NYILVÁNTARTOTT férőhely = az összes bed sor lakószobában.
-- 2. ÜZEMKÉPES  = nyilvántartott − (maintenance + renovation + decommissioned).
-- 3. KIADHATÓ   = üzemképes − reserved.
-- A KIHASZNÁLTSÁG NEVEZŐJE A KIADHATÓ, nem a nyilvántartott. A kettő tipikusan
-- 10-15%-kal tér el, és a különbség pont az, amit az üzemeltetés nem tud
-- kiadni, de a fenntartó számon kér — ezért mindkettőt meg kell jeleníteni.
create table if not exists dorm.room_status (
  code        text primary key,
  label_hu    text not null,
  label_en    text not null,
  is_operable boolean not null,   -- üzemképes kapacitásba számít?
  is_lettable boolean not null,   -- kiadható kapacitásba számít?
  is_issuable boolean not null,   -- MOST ki lehet-e adni? (cleaning: nem)
  is_terminal boolean not null default false,
  sort_order  integer not null default 100
);

insert into dorm.room_status (code, label_hu, label_en, is_operable, is_lettable, is_issuable, is_terminal, sort_order) values
  ('available',      'Kiadható, üres',        'Available',       true,  true,  true,  false, 10),
  ('allocated',      'Kiosztva',              'Allocated',       true,  true,  false, false, 20),
  ('occupied',       'Lakott',                'Occupied',        true,  true,  false, false, 30),
  ('cleaning',       'Takarítás alatt',       'Cleaning',        true,  true,  false, false, 40),
  ('maintenance',    'Javítás alatt',         'Under maintenance', false, false, false, false, 50),
  ('renovation',     'Felújítás alatt',       'Under renovation',  false, false, false, false, 60),
  ('reserved',       'Fenntartott',           'Reserved',        true,  false, false, false, 70),
  ('decommissioned', 'Kivont',                'Decommissioned',  false, false, false, true,  80)
on conflict (code) do update
  set label_hu = excluded.label_hu, label_en = excluded.label_en,
      is_operable = excluded.is_operable, is_lettable = excluded.is_lettable,
      is_issuable = excluded.is_issuable, is_terminal = excluded.is_terminal,
      sort_order  = excluded.sort_order;

comment on column dorm.room_status.is_issuable is
  'A cleaning státusz külön léte NEM kozmetika: ez a nyári konferencia-hasznosítás szűk keresztmetszete. Ha nem látszik, hány szoba vár takarításra, a "mikor tudok 40 főt fogadni" kérdésre nem lehet válaszolni.';

create table if not exists dorm.room_status_transition (
  from_code  text not null references dorm.room_status(code) on delete cascade,
  to_code    text not null references dorm.room_status(code) on delete cascade,
  label_hu   text,
  primary key (from_code, to_code)
);

insert into dorm.room_status_transition (from_code, to_code, label_hu) values
  ('available','allocated','Kiosztás'),          ('available','reserved','Fenntartás'),
  ('available','maintenance','Hiba miatt kivon'),('available','renovation','Felújítás indul'),
  ('available','cleaning','Takarítás'),          ('available','decommissioned','Végleges kivonás'),
  ('allocated','occupied','Beköltözés'),         ('allocated','available','Kiosztás visszavonva'),
  ('allocated','maintenance','Hiba miatt kivon'),
  ('occupied','cleaning','Kiköltözés utáni takarítás'),
  ('occupied','maintenance','Hiba miatt kivon'), ('occupied','available','Kiköltözés (takarítás nem kell)'),
  ('cleaning','available','Takarítás kész'),     ('cleaning','maintenance','Takarításkor talált hiba'),
  ('cleaning','renovation','Felújítás indul'),
  ('maintenance','available','Javítás kész'),    ('maintenance','renovation','Felújítássá minősítve'),
  ('maintenance','decommissioned','Nem javítható'),
  ('renovation','available','Felújítás kész'),   ('renovation','cleaning','Felújítás után takarítás'),
  ('renovation','decommissioned','Nem hasznosítható'),
  ('reserved','available','Fenntartás feloldva'),('reserved','maintenance','Hiba miatt kivon'),
  ('decommissioned','renovation','Újra használatba vétel')
on conflict (from_code, to_code) do update set label_hu = excluded.label_hu;

-- --- 3.4 Férőhely-státusz ---------------------------------------------------
-- Egy ÁGYAT ki lehet vonni anélkül, hogy a szobát kivonnánk: törött ágykeret,
-- penészes matrac esetén 1 hely esik ki, nem 3. Szobaszintű státusszal vagy 3
-- helyet veszítünk feleslegesen, vagy hazudunk a kapacitásról.
create table if not exists dorm.bed_status (
  code        text primary key,
  label_hu    text not null,
  is_operable boolean not null,
  is_lettable boolean not null,
  sort_order  integer not null default 100
);

insert into dorm.bed_status (code, label_hu, is_operable, is_lettable, sort_order) values
  ('available',            'Kiadható',                       true,  true,  10),
  ('reserved_for_single',  'Egyágyasítás miatt fenntartva',  true,  false, 20),
  ('reserved',             'Fenntartott (vendég, karantén)', true,  false, 30),
  ('out_of_service',       'Üzemképtelen',                   false, false, 40),
  ('decommissioned',       'Kivont',                         false, false, 50)
on conflict (code) do update
  set label_hu = excluded.label_hu, is_operable = excluded.is_operable,
      is_lettable = excluded.is_lettable, sort_order = excluded.sort_order;

-- --- 3.5 Hibakategória ------------------------------------------------------
-- A base_priority és a needs_triage a felelősségi mátrix bemenete.
-- needs_triage: a felelősség csak a HELYSZÍNEN dől el (dugulás: lakói vagy
-- gerincvezeték?). Ilyenkor a jegy először a gondnokhoz megy megállapításra,
-- és a megállapítás UTÁN kerül a végleges útvonalra — a jegyen külön mező
-- őrzi az eredeti és a megállapított felelőst (ez a kártérítési vita bizonyítéka).
create table if not exists dorm.fault_category (
  code          text primary key,
  label_hu      text not null,
  label_en      text not null,
  base_priority text not null default 'P3',
  needs_triage  boolean not null default false,
  sort_order    integer not null default 100
);

insert into dorm.fault_category (code, label_hu, label_en, base_priority, needs_triage, sort_order) values
  ('HEATING',    'Fűtés',                           'Heating',              'P1', false, 10),
  ('HOT_WATER',  'Használati melegvíz',             'Hot water',            'P2', false, 20),
  ('PLUMBING',   'Hidegvíz / csatorna / dugulás',   'Water and drainage',   'P2', true,  30),
  ('ELECTRICAL', 'Villany / elektromos',            'Electrical',           'P1', false, 40),
  ('OPENINGS',   'Nyílászáró (ajtó, ablak, zár)',   'Doors and windows',    'P2', false, 50),
  ('FURNITURE',  'Bútor / berendezés',              'Furniture',            'P3', true,  60),
  ('APPLIANCE',  'Háztartási gép',                  'Home appliance',       'P3', false, 70),
  ('HVAC',       'Gépészet (kazán, szivattyú, szellőzés)', 'Building services', 'P2', false, 80),
  ('LIFT',       'Lift',                            'Lift',                 'P1', false, 90),
  ('ROOF',       'Tetőbeázás / homlokzat',          'Roof and facade',      'P2', false, 100),
  ('PEST',       'Kártevő (rovar, rágcsáló, poloska)', 'Pest control',       'P2', false, 110),
  ('NETWORK',    'Internet / hálózat',              'Network',              'P3', false, 120),
  ('ACCESS',     'Beléptető / kulcs',               'Access control',       'P2', true,  130),
  ('CLEANING',   'Takarítás / higiénia',            'Cleaning',             'P3', false, 140),
  ('FIRE',       'Tűzvédelmi eszköz',               'Fire safety',          'P1', false, 150),
  ('COMMON',     'Közös helyiség',                  'Common area',          'P3', false, 160),
  ('NOISE',      'Zaj / együttélés',                'Noise and conduct',    'P4', false, 170),
  ('OTHER',      'Egyéb',                           'Other',                'P3', true,  180)
on conflict (code) do update
  set label_hu = excluded.label_hu, label_en = excluded.label_en,
      base_priority = excluded.base_priority, needs_triage = excluded.needs_triage,
      sort_order = excluded.sort_order;

-- --- 3.6 Hibajegy-állapotgép ------------------------------------------------
-- A "BÉRBEADÓRA VÁR" állapot külön léte a bérelt épületek kulcsfunkciója: ez
-- teszi MÉRHETŐVÉ, hogy a bérbeadó mennyi idő alatt teljesít, épületenként és
-- kategóriánként. Ez a szám a szerződéshosszabbítási tárgyalás legerősebb
-- érve, és a "helyettesítő javítás" jogalapjának bizonyítéka. Ugyanígy a
-- "LAKÓRA VÁR" állapot védi a karbantartót: az az idő, amíg a lakó nem enged
-- be, nem az ő késése — és az SLA-óra ilyenkor áll (stops_sla).
create table if not exists dorm.issue_status (
  code        text primary key,
  label_hu    text not null,
  label_en    text not null,
  is_open     boolean not null,
  stops_sla   boolean not null default false,
  is_terminal boolean not null default false,
  sort_order  integer not null default 100
);

insert into dorm.issue_status (code, label_hu, label_en, is_open, stops_sla, is_terminal, sort_order) values
  ('NEW',              'Új',                 'New',              true,  false, false, 10),
  ('ACKNOWLEDGED',     'Visszaigazolt',      'Acknowledged',     true,  false, false, 20),
  ('TRIAGE',           'Megállapítás alatt', 'Triage',           true,  false, false, 25),
  ('ASSIGNED',         'Kiosztva',           'Assigned',         true,  false, false, 30),
  ('IN_PROGRESS',      'Folyamatban',        'In progress',      true,  false, false, 40),
  ('WAITING_PARTS',    'Alkatrészre vár',    'Waiting for parts',true,  true,  false, 50),
  ('WAITING_LANDLORD', 'Bérbeadóra vár',     'Waiting for landlord', true, false, false, 60),
  ('WAITING_RESIDENT', 'Lakóra vár',         'Waiting for resident', true, true,  false, 70),
  ('DONE',             'Elvégezve',          'Done',             true,  false, false, 80),
  ('CLOSED',           'Lezárva',            'Closed',           false, false, true,  90),
  ('REJECTED',         'Elutasítva',         'Rejected',         false, false, true,  100)
on conflict (code) do update
  set label_hu = excluded.label_hu, label_en = excluded.label_en,
      is_open = excluded.is_open, stops_sla = excluded.stops_sla,
      is_terminal = excluded.is_terminal, sort_order = excluded.sort_order;

comment on column dorm.issue_status.stops_sla is
  'Az SLA-óra ilyenkor ÁLL. A "Bérbeadóra vár" SZÁNDÉKOSAN nem állítja meg: pont azt akarjuk mérni, mennyi ideig tart a bérbeadónál — ez a szerződéshosszabbítás legerősebb érve.';

create table if not exists dorm.issue_status_transition (
  from_code   text not null references dorm.issue_status(code) on delete cascade,
  to_code     text not null references dorm.issue_status(code) on delete cascade,
  label_hu    text,
  is_backward boolean not null default false,
  primary key (from_code, to_code)
);

insert into dorm.issue_status_transition (from_code, to_code, label_hu, is_backward) values
  ('NEW','ACKNOWLEDGED','Visszaigazolás', false),
  ('NEW','TRIAGE','Helyszíni megállapításra', false),
  ('NEW','REJECTED','Nem hiba / duplikátum', false),
  ('ACKNOWLEDGED','TRIAGE','Helyszíni megállapításra', false),
  ('ACKNOWLEDGED','ASSIGNED','Kiosztás', false),
  ('ACKNOWLEDGED','REJECTED','Nem hiba / duplikátum', false),
  ('TRIAGE','ASSIGNED','Megállapítva, kiosztva', false),
  ('TRIAGE','WAITING_LANDLORD','Megállapítva: bérbeadói felelősség', false),
  ('TRIAGE','REJECTED','Nem hiba / duplikátum', false),
  ('ASSIGNED','IN_PROGRESS','Munka megkezdve', false),
  ('ASSIGNED','WAITING_LANDLORD','Átadva a bérbeadónak', false),
  ('ASSIGNED','WAITING_RESIDENT','Lakói egyeztetésre vár', false),
  ('IN_PROGRESS','WAITING_PARTS','Alkatrészre vár', false),
  ('IN_PROGRESS','WAITING_LANDLORD','Átadva a bérbeadónak', false),
  ('IN_PROGRESS','WAITING_RESIDENT','Lakói egyeztetésre vár', false),
  ('IN_PROGRESS','DONE','Elvégezve', false),
  ('WAITING_PARTS','IN_PROGRESS','Alkatrész megérkezett', false),
  ('WAITING_LANDLORD','IN_PROGRESS','Helyettesítő javítás indul', false),
  ('WAITING_LANDLORD','DONE','A bérbeadó elvégezte', false),
  ('WAITING_RESIDENT','IN_PROGRESS','Lakó beengedett', false),
  ('DONE','CLOSED','Lezárás', false),
  ('DONE','IN_PROGRESS','Nem sikerült, folytatás', true),
  ('CLOSED','IN_PROGRESS','Újranyitva', true),
  ('REJECTED','NEW','Újranyitva', true)
on conflict (from_code, to_code) do update
  set label_hu = excluded.label_hu, is_backward = excluded.is_backward;

-- --- 3.7 Kollégiumi jelentkezés állapotgépe ---------------------------------
create table if not exists dorm.application_status (
  code        text primary key,
  label_hu    text not null,
  label_en    text not null,
  is_terminal boolean not null default false,
  sort_order  integer not null default 100
);

insert into dorm.application_status (code, label_hu, label_en, is_terminal, sort_order) values
  ('Draft',      'Piszkozat',        'Draft',      false, 10),
  ('Submitted',  'Beadva',           'Submitted',  false, 20),
  ('Ineligible', 'Nem jogosult',     'Ineligible', true,  30),
  ('Scored',     'Pontozva',         'Scored',     false, 40),
  ('Waitlisted', 'Várólistán',       'Waitlisted', false, 50),
  ('Offered',    'Ajánlat kiadva',   'Offered',    false, 60),
  ('Declined',   'Visszautasította', 'Declined',   true,  70),
  ('Expired',    'Ajánlat lejárt',   'Offer expired', true, 80),
  ('Accepted',   'Elfogadta',        'Accepted',   false, 90),
  ('Contracted', 'Szerződött',       'Contracted', false, 100),
  ('MovedIn',    'Beköltözött',      'Moved in',   false, 110),
  ('MovedOut',   'Kiköltözött',      'Moved out',  true,  120),
  ('Withdrawn',  'Visszavonva',      'Withdrawn',  true,  130)
on conflict (code) do update
  set label_hu = excluded.label_hu, label_en = excluded.label_en,
      is_terminal = excluded.is_terminal, sort_order = excluded.sort_order;

create table if not exists dorm.application_transition (
  from_code   text not null references dorm.application_status(code) on delete cascade,
  to_code     text not null references dorm.application_status(code) on delete cascade,
  label_hu    text,
  is_backward boolean not null default false,
  primary key (from_code, to_code)
);

insert into dorm.application_transition (from_code, to_code, label_hu, is_backward) values
  ('Draft','Submitted','Beadás', false),
  ('Draft','Withdrawn','Visszavonás', false),
  ('Submitted','Ineligible','Nem jogosult', false),
  ('Submitted','Scored','Pontozás', false),
  ('Submitted','Withdrawn','Visszavonás', false),
  ('Scored','Waitlisted','Várólistára', false),
  ('Scored','Offered','Ajánlat kiadva', false),
  ('Scored','Withdrawn','Visszavonás', false),
  ('Waitlisted','Offered','Felszabadult hely', false),
  ('Waitlisted','Withdrawn','Visszavonás', false),
  ('Offered','Accepted','Elfogadta', false),
  ('Offered','Declined','Visszautasította', false),
  ('Offered','Expired','Határidő lejárt', false),
  ('Offered','Waitlisted','Ajánlat visszavonva', true),
  ('Accepted','Contracted','Szerződés aláírva', false),
  ('Accepted','Withdrawn','Visszavonás', false),
  ('Contracted','MovedIn','Beköltözés', false),
  ('Contracted','Withdrawn','Elállás', false),
  ('MovedIn','MovedOut','Kiköltözés', false)
on conflict (from_code, to_code) do update
  set label_hu = excluded.label_hu, is_backward = excluded.is_backward;


-- ============================================================================
-- 4. SZAKASZ — TÖRZSADAT: telephely → épület → szint → szoba → férőhely
-- ============================================================================

-- --- 4.1 Telephely ----------------------------------------------------------
create table if not exists dorm.site (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  city       text,
  address    text,
  note       text,
  created_at timestamptz not null default now()
);

-- --- 4.2 Bérbeadó -----------------------------------------------------------
-- Az ÜGYELETI TELEFONSZÁM külön mező, és nem a "megjegyzés"-ben lakik:
-- egy szombat éjjeli csőtörésnél ez az egyetlen adat, ami számít.
create table if not exists dorm.landlord (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  is_company    boolean not null default true,
  tax_number    text,
  registry_number text,
  representative text,
  email         text,
  phone         text,
  duty_phone    text,
  billing_address text,
  bank_account  text,
  note          text,
  created_at    timestamptz not null default now()
);
create unique index if not exists dorm_landlord_name_uidx on dorm.landlord (lower(btrim(name)));

comment on column dorm.landlord.duty_phone is
  'Ügyeleti telefonszám hétvégi/éjszakai eseményre. Külön mező, mert a bérelt épület legdrágább órái ezek.';

-- --- 4.3 Épület — ITT dől el: saját vagy bérelt -----------------------------
create table if not exists dorm.building (
  id                uuid primary key default gen_random_uuid(),
  site_id           uuid references dorm.site(id) on delete set null,
  code              text not null unique,
  name              text not null,
  tenure            text not null references dorm.tenure(code),
  address           text,
  landlord_id       uuid references dorm.landlord(id) on delete set null,
  house_manager     text,                 -- gondnok neve (szöveg; a jogosultság a role_grant)
  house_manager_phone text,
  gross_area_sqm    numeric(10,2),
  floors_count      integer,
  has_lift          boolean not null default false,
  is_accessible     boolean not null default false,
  -- Időbeliség: a törzsadat sem statikus. Enélkül a "tavaly februárban hány
  -- férőhelyünk volt" kérdés megválaszolhatatlan, és a fajlagos költség
  -- (Ft/kiadható ágy-nap) nem számolható.
  in_portfolio_from date,
  in_portfolio_to   date,
  is_active         boolean not null default true,
  note              text,
  created_at        timestamptz not null default now()
);
create index if not exists dorm_building_tenure_idx  on dorm.building (tenure);
create index if not exists dorm_building_site_idx    on dorm.building (site_id);

do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'dorm_building_portfolio_chk') then
    alter table dorm.building add constraint dorm_building_portfolio_chk
      check (in_portfolio_to is null or in_portfolio_from is null or in_portfolio_to >= in_portfolio_from);
  end if;
  -- A role_grant FK-ja csak most köthető be: a 2. szakaszban a building még nem létezett.
  if not exists (select 1 from pg_constraint where conname = 'dorm_role_grant_scope_fkey') then
    alter table dorm.role_grant add constraint dorm_role_grant_scope_fkey
      foreign key (scope_building) references dorm.building(id) on delete cascade;
  end if;
end
$c$;

-- --- 4.4 Bérleti szerződés --------------------------------------------------
-- A DÖNTÉSI DÁTUM generált oszlop, nem riportlogika: ha egy szerződés
-- 2027-06-30-án jár le és a felmondási idő 6 hónap, a döntést 2026-12-31-ig
-- meg kell hozni. A puffer azért kell, mert a döntéshez fenntartói jóváhagyás,
-- esetleg beszerzési eljárás és alternatíva-keresés is tartozik. Ha a riport a
-- LEJÁRATOT mutatja, a rendszer "időben szól", de a felmondási idő már lejárt,
-- és a szerződés automatikusan meghosszabbodott.
create table if not exists dorm.lease (
  id                 uuid primary key default gen_random_uuid(),
  building_id        uuid not null references dorm.building(id) on delete cascade,
  landlord_id        uuid references dorm.landlord(id) on delete set null,
  iktatoszam         text,
  starts_on          date not null,
  ends_on            date,
  notice_months      integer not null default 3,
  decision_buffer_days integer not null default 60,
  auto_renew         boolean not null default false,
  indexation_note    text,
  option_right       text,
  monthly_rent       numeric(14,2),
  rent_currency      text not null default 'HUF',
  utilities_mode     text not null default 'SUBMETER'
                     check (utilities_mode in ('SUBMETER','FLAT_RATE','INCLUDED_IN_RENT','DIRECT_CONTRACT')),
  deposit_amount     numeric(14,2),
  deposit_currency   text default 'HUF',
  signed_by          text,
  contract_file      text,
  is_active          boolean not null default true,
  note               text,
  decision_due_on    date generated always as (
    case when ends_on is null then null
         else ends_on - (notice_months * 30) - decision_buffer_days end
  ) stored,
  created_at         timestamptz not null default now()
);
create index if not exists dorm_lease_building_idx on dorm.lease (building_id);
create index if not exists dorm_lease_decision_idx on dorm.lease (decision_due_on) where is_active;

comment on column dorm.lease.decision_due_on is
  'GENERÁLT: lejárat − felmondási idő − előkészítési puffer. A lejáratfigyelő riport EZT mutatja, nem az ends_on-t.';

-- --- 4.5 Szint --------------------------------------------------------------
create table if not exists dorm.floor (
  id          uuid primary key default gen_random_uuid(),
  building_id uuid not null references dorm.building(id) on delete cascade,
  level_no    integer not null,      -- -1 pince, 0 földszint, 1..n
  label       text,
  wing        text,
  is_accessible boolean not null default false,
  note        text
);
-- Kifejezéses egyediség: a szárny nélküli szintnél a NULL nem ütközne magával.
create unique index if not exists dorm_floor_lvl_uidx
  on dorm.floor (building_id, level_no, coalesce(wing, ''));
-- Összetett egyediség a lefelé mutató konzisztencia-FK-hoz (lásd 4.6):
create unique index if not exists dorm_floor_bid_id_uidx on dorm.floor (building_id, id);

-- --- 4.6 Szoba --------------------------------------------------------------
-- A building_id DENORMALIZÁLT, és egy ÖSSZETETT idegen kulcs garantálja, hogy
-- ne kerülhessen el a szint épületétől. Két oka van:
--   (a) az RLS-policy-k így épület-hatókört tudnak szűrni JOIN nélkül —
--       ez a policy-k teljesítményének és olvashatóságának alapja;
--   (b) deklaratív konzisztencia, nem trigger.
create table if not exists dorm.room (
  id            uuid primary key default gen_random_uuid(),
  building_id   uuid not null references dorm.building(id) on delete cascade,
  floor_id      uuid not null,
  unit_code     text,                 -- lakóegység/apartman (bérelt épületben tipikus); NULL, ha nincs
  door_number   text not null,
  full_code     text not null,        -- pl. KOLL-A/3/312
  legacy_code   text,
  room_type     text not null references dorm.room_type(code),
  purpose       text not null default 'RESIDENTIAL'
                check (purpose in ('RESIDENTIAL','COMMON','SERVICE','TECHNICAL')),
  capacity      integer not null default 1 check (capacity >= 0),
  area_sqm      numeric(8,2),
  ceiling_height_m numeric(4,2),
  window_count  integer,
  orientation   text,
  -- felszereltség
  bathroom      text default 'SHARED_FLOOR'
                check (bathroom in ('PRIVATE','SHARED_UNIT','SHARED_FLOOR','NONE')),
  kitchen       text default 'SHARED_FLOOR'
                check (kitchen in ('PRIVATE','KITCHENETTE','SHARED_UNIT','SHARED_FLOOR','NONE')),
  has_fridge    boolean not null default false,
  has_balcony   boolean not null default false,
  has_aircon    boolean not null default false,
  internet      text default 'WIFI' check (internet in ('WIRED','WIFI','BOTH','NONE')),
  furnishing    text,
  -- akadálymentesség: KÉNYSZERFELTÉTEL a kiosztásnál, nem preferencia
  is_accessible          boolean not null default false,
  step_free_shower       boolean not null default false,
  has_grab_rails         boolean not null default false,
  accessible_alarm       boolean not null default false,
  -- korlátok
  gender_restriction text default 'ANY' check (gender_restriction in ('ANY','MALE','FEMALE')),
  smoking_allowed boolean not null default false,
  quiet_room      boolean not null default false,
  pets_allowed    boolean not null default false,
  -- állapot
  status        text not null default 'available' references dorm.room_status(code),
  status_changed_at timestamptz not null default now(),
  note          text,
  created_at    timestamptz not null default now(),
  unique (building_id, full_code),
  foreign key (building_id, floor_id) references dorm.floor (building_id, id) on delete cascade
);
create unique index if not exists dorm_room_bid_id_uidx on dorm.room (building_id, id);
create index if not exists dorm_room_building_idx on dorm.room (building_id);
create index if not exists dorm_room_floor_idx    on dorm.room (floor_id);
create index if not exists dorm_room_status_idx   on dorm.room (status);
create index if not exists dorm_room_purpose_idx  on dorm.room (purpose);

comment on column dorm.room.purpose is
  'A "rendeltetés" mező hiánya tipikus hiba: a mosókonyhában is elromlik a mosógép, a gondnoki irodában is kell tűzoltó készülék. CSAK a RESIDENTIAL számít kapacitásnak — de a többinek is kell hibajegy, szemle és takarítás.';

-- --- 4.7 Férőhely -----------------------------------------------------------
-- A bed FÉRŐHELY-ABSZTRAKCIÓ, nem bútor (2. szerkezeti döntés).
create table if not exists dorm.bed (
  id            uuid primary key default gen_random_uuid(),
  building_id   uuid not null references dorm.building(id) on delete cascade,
  room_id       uuid not null,
  bed_label     text not null,        -- 'A', 'B', '1', ...
  full_code     text not null,
  status        text not null default 'available' references dorm.bed_status(code),
  status_changed_at timestamptz not null default now(),
  qr_token      text not null default replace(gen_random_uuid()::text, '-', ''),
  note          text,
  created_at    timestamptz not null default now(),
  unique (building_id, full_code),
  foreign key (building_id, room_id) references dorm.room (building_id, id) on delete cascade
);
create unique index if not exists dorm_bed_bid_id_uidx  on dorm.bed (building_id, id);
create unique index if not exists dorm_bed_room_lbl_uidx on dorm.bed (room_id, bed_label);
create unique index if not exists dorm_bed_qr_uidx      on dorm.bed (qr_token);
create index if not exists dorm_bed_building_idx on dorm.bed (building_id);
create index if not exists dorm_bed_room_idx     on dorm.bed (room_id);

comment on column dorm.bed.qr_token is
  'A szobaajtóra kerülő QR-kód azonosítója (.../hiba?bed=<token>). A legnagyobb minőségjavulás a legkisebb ráfordításért: megszűnik a "3. emeleti valamelyik fürdőben csöpög" típusú bejelentés.';

-- --- 4.8 Státusztörténet (szoba és férőhely) --------------------------------
-- Ebből bármely MÚLTBELI napra visszaszámolható a kapacitás. Ez a
-- kényelmetlenség egyszer fáj (a migrációnál), és utána minden riportnál megtérül.
create table if not exists dorm.room_status_history (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references dorm.room(id) on delete cascade,
  from_status text,
  to_status   text not null,
  changed_at  timestamptz not null default now(),
  changed_by  uuid references public.profiles(id) on delete set null,
  reason      text
);
create index if not exists dorm_room_hist_room_idx on dorm.room_status_history (room_id, changed_at desc);

create table if not exists dorm.bed_status_history (
  id          uuid primary key default gen_random_uuid(),
  bed_id      uuid not null references dorm.bed(id) on delete cascade,
  from_status text,
  to_status   text not null,
  changed_at  timestamptz not null default now(),
  changed_by  uuid references public.profiles(id) on delete set null,
  reason      text
);
create index if not exists dorm_bed_hist_bed_idx on dorm.bed_status_history (bed_id, changed_at desc);

-- --- 4.9 A szobastátusz guard triggere (a 25-ös mintája) --------------------
create or replace function dorm.room_status_guard()
returns trigger language plpgsql
set search_path = dorm, public, extensions, pg_temp
as $$
begin
  if new.status is distinct from old.status then
    if not exists (select 1 from dorm.room_status_transition t
                    where t.from_code = old.status and t.to_code = new.status) then
      raise exception
        'DORM_ROOM_STATUS_INVALID: a(z) "%" -> "%" atmenet nincs a dorm.room_status_transition tablaban (szoba: %).',
        old.status, new.status, old.full_code
        using hint = 'Megengedett atmenetek: select to_code from dorm.room_status_transition where from_code = ' || quote_literal(old.status);
    end if;
    new.status_changed_at := now();
    insert into dorm.room_status_history (room_id, from_status, to_status, changed_by)
    values (old.id, old.status, new.status, auth.uid());
  end if;
  return new;
end
$$;

drop trigger if exists dorm_room_status_guard_trg on dorm.room;
create trigger dorm_room_status_guard_trg
  before update on dorm.room
  for each row execute function dorm.room_status_guard();

create or replace function dorm.bed_status_guard()
returns trigger language plpgsql
set search_path = dorm, public, extensions, pg_temp
as $$
begin
  if new.status is distinct from old.status then
    new.status_changed_at := now();
    insert into dorm.bed_status_history (bed_id, from_status, to_status, changed_by)
    values (old.id, old.status, new.status, auth.uid());
  end if;
  return new;
end
$$;

drop trigger if exists dorm_bed_status_guard_trg on dorm.bed;
create trigger dorm_bed_status_guard_trg
  before update on dorm.bed
  for each row execute function dorm.bed_status_guard();


-- ============================================================================
-- 5. SZAKASZ — A FELELŐSSÉGI MÁTRIX  (a kért termék)
-- ============================================================================
-- A mátrix ADAT, nem dokumentum — azért, mert épületenként eltér (minden
-- bérleti szerződés máshogy osztja el a felelősséget), és mert csak így tud a
-- rendszer a BEJELENTÉS PILLANATÁBAN dönteni.
--
-- HÁROM SZINTŰ ÖRÖKLÉS:
--   1. épület-szintű sor          (building_id kitöltve)
--   2. jogcím-szintű alapértelmezés (building_id NULL, tenure kitöltve)
--   3. globális alapértelmezés     (mindkettő NULL)
-- Egy új bérelt épület felvételekor tehát csak az ELTÉRÉSEKET kell rögzíteni
-- — tipikusan 2-4 sort, nem mind a 18 kategóriát.
--
-- NAPI HASZON: amikor a lakó bejelent egy hibát és kiválasztja a kategóriát,
-- a rendszer AZONNAL megmondja, kihez megy, mi a határidő és MELYIK
-- SZERZŐDÉSPONT alapján — az ügyintézőnek nem kell a szerződést előkeresnie.
-- Ez naponta többször megspórolt 20-30 perc, és megszünteti azt a helyzetet,
-- hogy kifizetünk valamit, ami szerződés szerint a bérbeadóé.

create table if not exists dorm.responsibility (
  id               uuid primary key default gen_random_uuid(),
  building_id      uuid references dorm.building(id) on delete cascade,
  tenure           text references dorm.tenure(code) on delete cascade,
  category_code    text not null references dorm.fault_category(code) on delete cascade,
  liable_party     text not null check (liable_party in ('UNIVERSITY','LANDLORD','RESIDENT','SERVICE_CONTRACT','INSURANCE')),
  route            text not null check (route in ('INTERNAL_MAINT','LANDLORD_TICKET','EXTERNAL_VENDOR','HOUSE_MANAGER','IT_HELPDESK','DORM_ADMIN')),
  cost_bearer      text not null check (cost_bearer in ('UNIVERSITY','LANDLORD','RESIDENT','INSURANCE')),
  sla_hours        integer,
  escalation_hours integer,
  substitute_repair_allowed boolean not null default false,
  contact_name     text,
  contact_phone    text,
  contract_clause  text,
  note             text,
  updated_at       timestamptz not null default now(),
  -- Pontosan EGY szinten élhet egy sor:
  constraint dorm_responsibility_level_chk check (building_id is null or tenure is null)
);

create unique index if not exists dorm_responsibility_bld_uidx
  on dorm.responsibility (building_id, category_code) where building_id is not null;
create unique index if not exists dorm_responsibility_ten_uidx
  on dorm.responsibility (tenure, category_code) where building_id is null and tenure is not null;
create unique index if not exists dorm_responsibility_glb_uidx
  on dorm.responsibility (category_code) where building_id is null and tenure is null;

comment on table dorm.responsibility is
  'Hibakategória x épület -> felelős + útvonal + költségviselő + határidő + SZERZŐDÉSPONT. Három szintű öröklés: épület -> jogcím -> globális.';

-- A feloldó függvény. STABLE, mert a hibajegy létrehozásakor is hívjuk.
create or replace function dorm.resolve_responsibility(p_building uuid, p_category text)
returns table (
  source           text,
  liable_party     text,
  route            text,
  cost_bearer      text,
  sla_hours        integer,
  escalation_hours integer,
  substitute_repair_allowed boolean,
  contact_name     text,
  contact_phone    text,
  contract_clause  text
)
language sql stable
set search_path = dorm, public, extensions, pg_temp
as $$
  with b as (select id, tenure from dorm.building where id = p_building)
  select
    case when r.building_id is not null then 'BUILDING'
         when r.tenure      is not null then 'TENURE'
         else 'GLOBAL' end as source,
    r.liable_party, r.route, r.cost_bearer, r.sla_hours, r.escalation_hours,
    r.substitute_repair_allowed, r.contact_name, r.contact_phone, r.contract_clause
  from dorm.responsibility r
  left join b on true
  where r.category_code = p_category
    and (
      r.building_id = p_building
      or (r.building_id is null and r.tenure = b.tenure)
      or (r.building_id is null and r.tenure is null)
    )
  order by (r.building_id is not null) desc, (r.tenure is not null) desc
  limit 1
$$;


-- ============================================================================
-- 6. SZAKASZ — LAKÓK: személy, időszak, jelentkezés, kiosztás, szerződés
-- ============================================================================

-- --- 6.1 A lakó saját entitása ----------------------------------------------
-- A students sor a JELENTKEZÉS, nem a SZEMÉLY. Következmény, ami önmagában is
-- haszon: a szerződés, a kaució és a lakhatási előzmény a dorm.person-höz
-- kötődik, nem a students sorhoz — így egy hallgató, aki két félév közt
-- elveszíti a jelentkezői státuszát, NEM veszíti el a kollégiumi történetét.
create table if not exists dorm.person (
  id            uuid primary key default gen_random_uuid(),
  display_name  text not null,
  email         text,
  phone         text,
  kind          text not null default 'OTHER'
                check (kind in ('APPLICANT','STUDENT','GUEST','STAFF','EXTERNAL','OTHER')),
  student_id    text references public.students(id) on delete set null,
  profile_id    uuid references public.profiles(id) on delete set null,
  -- a szállásbejelentőhöz / idegenrendészethez kell, és NEM biztos, hogy van students sor
  birth_date    date,
  birth_place   text,
  citizenship   text,
  gender        text check (gender is null or gender in ('MALE','FEMALE','OTHER','UNDISCLOSED')),
  doc_type      text check (doc_type is null or doc_type in ('passport','id_card','residence_permit','other')),
  doc_number    text,
  emergency_contact jsonb,
  -- 8.7: VÉDETT LAKÓ — bántalmazás áldozata, távoltartási határozat, tanúvédelem.
  -- Ilyenkor a tartózkodási hely csak a saját épület gondnokának és az
  -- intézményi körnek látszik, és a megtekintés riaszt is, nem csak naplóz.
  protected     boolean not null default false,
  is_active     boolean not null default true,
  note          text,
  created_at    timestamptz not null default now()
);

-- Részleges UNIQUE indexek: a dorm.my_person_id() törzse limit 1 — kötés
-- nélkül a függvény CSENDBEN választana. Betűre az echo_teacher_profile_uidx
-- indoka (19_echo_roles.sql, 4. szerkezeti döntés).
create unique index if not exists dorm_person_student_uidx
  on dorm.person (student_id) where student_id is not null;
create unique index if not exists dorm_person_profile_uidx
  on dorm.person (profile_id) where profile_id is not null;
create index if not exists dorm_person_email_idx on dorm.person (lower(email));
create index if not exists dorm_person_name_idx  on dorm.person (lower(display_name));

comment on column dorm.person.emergency_contact is
  'Vészhelyzeti kapcsolattartó. Ezt ma SEHOL nem tartjuk nyilván, és éjszakai rosszullétnél percek alatt kell.';

-- --- 6.2 Időszak (tanév / félév / nyár) -------------------------------------
create table if not exists dorm.term (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  label_hu          text not null,
  kind              text not null default 'SEMESTER'
                    check (kind in ('FULL_YEAR','SEMESTER','SUMMER','SHORT_STAY','ROLLING','CUSTOM')),
  starts_on         date not null,
  ends_on           date not null,
  application_deadline date,
  allocation_on     date,
  movein_from       date,
  movein_to         date,
  is_active         boolean not null default true,
  check (ends_on > starts_on)
);

-- --- 6.3 Kollégiumi igény a FELVÉTELI folyamatból ---------------------------
-- Ez az a pont, amit a tesztelő kollégák maguk vetettek fel: "mi van, ha nem
-- kér kolit / csak 1 félévet fizet". Ma erre nincs hely a rendszerben.
-- NEM új oszlop a students-en: ott a 25-ös óta már három sávmező van, és a
-- tábla mérve blanket policy alatt áll.
create table if not exists dorm.intent (
  id            uuid primary key default gen_random_uuid(),
  student_id    text not null references public.students(id) on delete cascade,
  term_id       uuid references dorm.term(id) on delete set null,
  wants_dorm    boolean not null default false,
  preferred_period text not null default 'undecided'
                check (preferred_period in ('full_year','semester_1','semester_2','undecided')),
  special_needs text,
  preferred_building uuid references dorm.building(id) on delete set null,
  preferred_roommate text,
  source        text not null default 'manual'
                check (source in ('application_form','admission_letter','manual','agent')),
  submitted_at  timestamptz not null default now(),
  updated_by    uuid references public.profiles(id) on delete set null,
  note          text
);
create unique index if not exists dorm_intent_student_term_uidx
  on dorm.intent (student_id, coalesce(term_id, '00000000-0000-0000-0000-000000000000'::uuid));

comment on table dorm.intent is
  'A felvételi levél generátora EBBŐL dönt: legyen-e a levélben kollégiumi díjsor és kaució, és EGY vagy KÉT félévnyi. Ma az app.jsx FEES konstansa mindenkinek ugyanazt írja.';

-- --- 6.4 Kollégiumi jelentkezés --------------------------------------------
create table if not exists dorm.application (
  id             uuid primary key default gen_random_uuid(),
  person_id      uuid not null references dorm.person(id) on delete cascade,
  term_id        uuid not null references dorm.term(id) on delete cascade,
  status         text not null default 'Draft' references dorm.application_status(code),
  status_changed_at timestamptz not null default now(),
  submitted_at   timestamptz,
  -- A várólista NEM sorszám, hanem PONTSZÁM: a rangsort minden kiosztáskor
  -- újraszámoljuk, mert közben új jelentkező is jöhet.
  score          numeric(8,2),
  score_breakdown jsonb,
  quota_category text,
  requires_accessible boolean not null default false,
  medical_need   text,
  preferred_building uuid references dorm.building(id) on delete set null,
  preferred_roommate uuid references dorm.person(id) on delete set null,
  period_kind    text not null default 'full_year'
                 check (period_kind in ('full_year','semester_1','semester_2','short_stay')),
  offered_bed_id uuid,
  offer_sent_at  timestamptz,
  offer_expires_at timestamptz,
  decided_by     uuid references public.profiles(id) on delete set null,
  decision_note  text,
  created_at     timestamptz not null default now(),
  unique (person_id, term_id)
);
create index if not exists dorm_application_status_idx on dorm.application (status);
create index if not exists dorm_application_term_idx   on dorm.application (term_id, status);
create index if not exists dorm_application_score_idx  on dorm.application (term_id, score desc nulls last);

comment on column dorm.application.score_breakdown is
  'Melyik szabály hány pontot adott. Enélkül a "miért kaptam kevesebbet, mint a szobatársam" kérdésre nincs védhető válasz, és a jogorvoslati kérelem kezelhetetlen.';
comment on column dorm.application.offer_expires_at is
  'A lejárat nélküli ajánlat a legnagyobb kapacitásvesztés-forrás: a hely "beragad" egy olyan jelentkezőnél, aki már máshol lakik. Lejáratás: public.dorm_expire_offers() — idempotens, hívhatja ütemező, gomb és külső cron is (a replikán nincs pg_cron — mérve).';

create or replace function dorm.application_status_guard()
returns trigger language plpgsql
set search_path = dorm, public, extensions, pg_temp
as $$
begin
  if new.status is distinct from old.status then
    if not exists (select 1 from dorm.application_transition t
                    where t.from_code = old.status and t.to_code = new.status) then
      raise exception
        'DORM_APPLICATION_STATUS_INVALID: a(z) "%" -> "%" atmenet nem megengedett.',
        old.status, new.status;
    end if;
    new.status_changed_at := now();
  end if;
  return new;
end
$$;

drop trigger if exists dorm_application_status_guard_trg on dorm.application;
create trigger dorm_application_status_guard_trg
  before update on dorm.application
  for each row execute function dorm.application_status_guard();

-- --- 6.5 Pontozási szabály és kvóta ----------------------------------------
-- A pontozás legyen ADATVEZÉRELT, ne beégetett képlet.
create table if not exists dorm.scoring_rule (
  id           uuid primary key default gen_random_uuid(),
  term_id      uuid references dorm.term(id) on delete cascade,
  code         text not null,
  label_hu     text not null,
  category     text,
  source       text,          -- honnan jön a bemenet (tanulmányi rendszer, igazolás, kézi)
  points       numeric(6,2) not null default 0,
  max_points   numeric(6,2),
  sort_order   integer not null default 100,
  valid_from   date,
  valid_to     date,
  is_active    boolean not null default true,
  note         text
);
create unique index if not exists dorm_scoring_rule_uidx
  on dorm.scoring_rule (coalesce(term_id, '00000000-0000-0000-0000-000000000000'::uuid), code);

-- Kvóta: a kiosztás ELŐSZÖR kvótánként fut, majd a maradék a közös rangsorból.
-- Miért kritikus: pontozásban a nemzetközi hallgatók rendszerint rosszul járnak
-- (nincs magyar tanulmányi előzményük, a "lakóhely távolsága" nem értelmezhető
-- rájuk), miközben nekik NINCS itthoni alternatívájuk. Kvóta nélkül kiszorulnak
-- — és ez közvetlenül rontja a felvételi eredményt, amiért a UniPortal létezik.
create table if not exists dorm.quota (
  id           uuid primary key default gen_random_uuid(),
  term_id      uuid not null references dorm.term(id) on delete cascade,
  building_id  uuid references dorm.building(id) on delete cascade,
  category     text not null,
  beds_count   integer,
  beds_percent numeric(5,2),
  note         text,
  check (beds_count is not null or beds_percent is not null)
);
create unique index if not exists dorm_quota_uidx
  on dorm.quota (term_id, coalesce(building_id, '00000000-0000-0000-0000-000000000000'::uuid), category);

-- --- 6.6 Lakói szerződés ----------------------------------------------------
create table if not exists dorm.contract (
  id             uuid primary key default gen_random_uuid(),
  person_id      uuid not null references dorm.person(id) on delete restrict,
  term_id        uuid references dorm.term(id) on delete set null,
  iktatoszam     text,
  contract_kind  text not null default 'SEMESTER'
                 check (contract_kind in ('FULL_YEAR','SEMESTER','SHORT_STAY','SUMMER','ROLLING')),
  starts_on      date not null,
  ends_on        date,
  monthly_fee    numeric(12,2),
  fee_currency   text not null default 'HUF',
  deposit_amount numeric(12,2),
  deposit_currency text default 'HUF',
  house_rules_version text,
  signed_at      timestamptz,
  signature_mode text check (signature_mode is null or signature_mode in ('PAPER_SCANNED','ELECTRONIC')),
  signature_ip   text,
  file_path      text,
  terminated_at  timestamptz,
  termination_reason text,
  created_at     timestamptz not null default now()
);
create index if not exists dorm_contract_person_idx on dorm.contract (person_id);

comment on column dorm.contract.house_rules_version is
  'A házirend MINDENKORI verziója a szerződéshez rögzítve — később vitatéma lehet, melyik házirend volt hatályos.';

-- --- 6.7 AZ ELHELYEZÉS — a modul technikai gerince --------------------------
-- Minden férőhely-foglalás egy sor, daterange-dzsel, és az ÁTFEDÉST AZ
-- ADATBÁZIS TILTJA. Amit ez az egy constraint megold:
--   * egy ágyon nem lehet két ember ugyanabban az időszakban — nem
--     alkalmazáslogikából, hanem az adatbázisból garantálva; PÁRHUZAMOS
--     kiosztásnál sem lehet duplán kiadni egy helyet (a dupla foglalás a
--     rendszer legdrágább hibája);
--   * "mely ágyak szabadok 2027-02-01 és 2027-06-30 között" = egy
--     range-lekérdezés, nem körmönfont join;
--   * jövőbeni kapacitás-előrejelzés: bármely jövőbeni napra pontosan
--     megmondható a szabad hely, mert minden foglalásnak van záró dátuma;
--   * szobacsere = egy sor lezárása + egy új nyitása, előzménnyel;
--   * korai távozás = a period felső határának módosítása, és minden pénzügyi
--     következmény EBBŐL számolódik.
-- A daterange felső határa NYITOTT ('[)'): aki 01-31-én kiköltözik, annak az
-- ágyára 01-31-én már be lehet költözni. Ez a szobacsere alapesete.
create table if not exists dorm.occupancy (
  id            uuid primary key default gen_random_uuid(),
  building_id   uuid not null references dorm.building(id) on delete restrict,
  bed_id        uuid not null,
  person_id     uuid not null references dorm.person(id) on delete restrict,
  contract_id   uuid references dorm.contract(id) on delete set null,
  application_id uuid references dorm.application(id) on delete set null,
  term_id       uuid references dorm.term(id) on delete set null,
  period        daterange not null,
  state         text not null default 'ALLOCATED'
                check (state in ('ALLOCATED','MOVED_IN','MOVED_OUT','CANCELLED')),
  moved_in_at   timestamptz,
  moved_out_at  timestamptz,
  end_reason    text check (end_reason is null or end_reason in
                ('PLANNED','STUDENT_STATUS_ENDED','OWN_REQUEST','DISCIPLINARY',
                 'ROOM_SWAP','DEFERRAL','MEDICAL','DECEASED','OTHER')),
  swap_from_id  uuid references dorm.occupancy(id) on delete set null,
  assigned_by   uuid references public.profiles(id) on delete set null,
  assignment_mode text not null default 'MANUAL' check (assignment_mode in ('MANUAL','SUGGESTED','AUTO')),
  deviation_reason text,
  note          text,
  created_at    timestamptz not null default now(),
  foreign key (building_id, bed_id) references dorm.bed (building_id, id) on delete restrict,
  constraint dorm_occupancy_period_chk check (not isempty(period) and lower(period) is not null)
);

-- A KULCS-CONSTRAINT. Részleges: a visszavont (CANCELLED) kiosztás ne
-- blokkoljon egy új foglalást ugyanarra az ágyra.
do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'dorm_occupancy_no_overlap_excl') then
    alter table dorm.occupancy add constraint dorm_occupancy_no_overlap_excl
      exclude using gist (bed_id with =, period with &&) where (state <> 'CANCELLED');
  end if;
end
$c$;

create index if not exists dorm_occupancy_person_idx   on dorm.occupancy (person_id);
create index if not exists dorm_occupancy_bed_idx      on dorm.occupancy (bed_id);
create index if not exists dorm_occupancy_building_idx on dorm.occupancy (building_id);
create index if not exists dorm_occupancy_period_idx   on dorm.occupancy using gist (period);

comment on constraint dorm_occupancy_no_overlap_excl on dorm.occupancy is
  'Egy ágyon nem lehet két lakó egyidejűleg. Adatbázis-szintű garancia, nem alkalmazáslogika — párhuzamos kiosztásnál is tart.';

-- --- 6.8 Jegyzőkönyv: birtokbaadás és lakói be-/kiköltözés EGY táblában -----
-- Miért egy táblában: a birtokbaadási és a lakói beköltözési jegyzőkönyv
-- STRUKTÚRÁJA ÉS CÉLJA AZONOS — fotós állapotrögzítés egy adott pillanatban,
-- hogy később eldönthető legyen, mi keletkezett közben. A kárvita logikája is
-- azonos. Két külön táblában ugyanaz a kód kétszer.
-- A BÉRLET LEGDRÁGÁBB PILLANATA A VISSZAADÁS: a bérbeadó ilyenkor akar mindent
-- leírni, ami az évek alatt elhasználódott. Az egyetlen védekezés a
-- birtokbaadáskor készült, időbélyeges, fotós jegyzőkönyv — és az, hogy ez
-- ÉVEK MÚLVA is előkereshető legyen.
create table if not exists dorm.handover (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null check (kind in
                ('BUILDING_TAKEOVER','BUILDING_RETURN','ROOM_MOVE_IN','ROOM_MOVE_OUT',
                 'ROOM_SWAP','JOINT_INSPECTION')),
  building_id   uuid references dorm.building(id) on delete cascade,
  room_id       uuid references dorm.room(id) on delete cascade,
  occupancy_id  uuid references dorm.occupancy(id) on delete set null,
  person_id     uuid references dorm.person(id) on delete set null,
  happened_at   timestamptz not null default now(),
  participants  text,
  meter_readings jsonb,
  keys_listed   jsonb,
  photos        jsonb,
  deficiencies  text,
  remarks       text,
  signature_mode text check (signature_mode is null or signature_mode in ('PAPER_SCANNED','ELECTRONIC')),
  file_path     text,
  recorded_by   uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists dorm_handover_building_idx  on dorm.handover (building_id, happened_at desc);
create index if not exists dorm_handover_occupancy_idx on dorm.handover (occupancy_id);


-- ============================================================================
-- 7. SZAKASZ — ÜZEMELTETÉSI FELADATOK
-- ============================================================================

-- --- 7.1 Hibajegy -----------------------------------------------------------
-- A PRIORITÁS SZÁMÍTOTT, NEM VÁLASZTOTT: a lakó jelezheti a sürgősséget, de a
-- prioritást a kategória x hatás mátrix adja. A HATÁRIDŐ FORRÁSA A FELELŐSSÉGI
-- MÁTRIX — így ugyanaz a hiba két épületben más határidőt kaphat, és ez helyes.
create table if not exists dorm.issue (
  id              bigint generated always as identity primary key,
  ticket_no       text not null unique,
  building_id     uuid not null references dorm.building(id) on delete cascade,
  room_id         uuid,
  bed_id          uuid,
  category_code   text not null references dorm.fault_category(code),
  title           text not null,
  description     text,
  photos          jsonb,
  -- bejelentő
  reporter_person uuid references dorm.person(id) on delete set null,
  reporter_profile uuid references public.profiles(id) on delete set null,
  reporter_name   text,
  reporter_phone  text,
  -- A karbantartó felé a bejelentő elérhetősége CSAK akkor látszik, ha a
  -- bejelentő maga engedte. A hibajegy a SZOBÁRA hivatkozik, nem a lakóra.
  contact_ok      boolean not null default false,
  entry_permitted boolean not null default false,   -- belépés a lakó távollétében
  impact          text not null default 'NONE'
                  check (impact in ('NONE','ONE_BED','ROOM_UNUSABLE','MULTI_ROOM','BUILDING','SAFETY')),
  urgency_flag    boolean not null default false,   -- a lakó jelzése, NEM a prioritás
  priority        text not null default 'P3' check (priority in ('P1','P2','P3','P4')),
  -- felelősség: az EREDETI és a MEGÁLLAPÍTOTT külön mezőben (kártérítési vita bizonyítéka)
  liable_party_initial text,
  liable_party_final   text,
  route           text,
  cost_bearer     text,
  contract_clause text,
  responsibility_source text,
  substitute_repair boolean not null default false,
  needs_triage    boolean not null default false,
  triaged_by      uuid references public.profiles(id) on delete set null,
  triaged_at      timestamptz,
  triage_note     text,
  -- állapot és határidő
  status          text not null default 'NEW' references dorm.issue_status(code),
  status_changed_at timestamptz not null default now(),
  due_at          timestamptz,
  escalate_at     timestamptz,
  assigned_to     uuid references public.profiles(id) on delete set null,
  assigned_vendor text,
  landlord_notified_at timestamptz,
  landlord_ticket_ref  text,
  work_started_at timestamptz,
  done_at         timestamptz,
  closed_at       timestamptz,
  work_hours      numeric(6,2),
  materials_note  text,
  cost_amount     numeric(12,2),
  cost_currency   text default 'HUF',
  external_invoice_ref text,
  is_chronic      boolean not null default false,
  source          text not null default 'RESIDENT'
                  check (source in ('RESIDENT','HOUSE_MANAGER','DORM_ADMIN','MAINTENANCE',
                                    'CLEANER','INSPECTION','PM_RUN','METER_ANOMALY','SYSTEM')),
  source_ref      uuid,
  created_at      timestamptz not null default now(),
  foreign key (building_id, room_id) references dorm.room (building_id, id) on delete cascade,
  foreign key (building_id, bed_id)  references dorm.bed  (building_id, id) on delete cascade
);
create index if not exists dorm_issue_building_idx on dorm.issue (building_id, status);
create index if not exists dorm_issue_room_idx     on dorm.issue (room_id);
create index if not exists dorm_issue_status_idx   on dorm.issue (status);
create index if not exists dorm_issue_due_idx      on dorm.issue (due_at) where status not in ('CLOSED','REJECTED');
create index if not exists dorm_issue_cat_idx      on dorm.issue (category_code);
create index if not exists dorm_issue_reporter_idx on dorm.issue (reporter_person);

comment on column dorm.issue.contact_ok is
  'A bejelentő elérhetősége a karbantartó felé CSAK akkor látszik, ha a bejelentő maga engedte. A jegy a SZOBÁRA hivatkozik, nem a lakóra.';
comment on column dorm.issue.substitute_repair is
  'HELYETTESÍTŐ JAVÍTÁS: a bérbeadó nem javított határidőre, mi csináltattuk meg. A pénzügynek tudnia kell, hogy ez a tétel a bérleti díjból BESZÁMÍTANDÓ.';
comment on column dorm.issue.is_chronic is
  'KRÓNIKUS HIBA: ugyanabban a szobában ugyanabban a kategóriában 90 napon belül a 3. jegy. Ez a funkció viszi át az üzemeltetést reaktívból tervezettbe — ötször kiszállunk 20 ezerért ahelyett, hogy egyszer kicserélnénk a szerelvényt 60-ért.';

create table if not exists dorm.issue_event (
  id          bigint generated always as identity primary key,
  issue_id    bigint not null references dorm.issue(id) on delete cascade,
  happened_at timestamptz not null default now(),
  actor       uuid references public.profiles(id) on delete set null,
  event_kind  text not null default 'STATUS'
              check (event_kind in ('STATUS','COMMENT','ASSIGN','COST','PHOTO','ESCALATION','TRIAGE','NOTIFY')),
  from_status text,
  to_status   text,
  body        text,
  payload     jsonb
);
create index if not exists dorm_issue_event_issue_idx on dorm.issue_event (issue_id, happened_at desc);

-- A hibajegy-állapotgép guardja + az SLA-óra kezelése.
create or replace function dorm.issue_status_guard()
returns trigger language plpgsql
set search_path = dorm, public, extensions, pg_temp
as $$
begin
  if new.status is distinct from old.status then
    if not exists (select 1 from dorm.issue_status_transition t
                    where t.from_code = old.status and t.to_code = new.status) then
      raise exception
        'DORM_ISSUE_STATUS_INVALID: a(z) "%" -> "%" atmenet nem megengedett (jegy: %).',
        old.status, new.status, old.ticket_no
        using hint = 'Megengedett atmenetek: select to_code from dorm.issue_status_transition where from_code = ' || quote_literal(old.status);
    end if;
    new.status_changed_at := now();
    if new.status = 'IN_PROGRESS' and new.work_started_at is null then
      new.work_started_at := now();
    end if;
    if new.status = 'DONE'   and new.done_at   is null then new.done_at   := now(); end if;
    if new.status = 'CLOSED' and new.closed_at is null then new.closed_at := now(); end if;
    insert into dorm.issue_event (issue_id, actor, event_kind, from_status, to_status)
    values (old.id, auth.uid(), 'STATUS', old.status, new.status);
  end if;
  return new;
end
$$;

drop trigger if exists dorm_issue_status_guard_trg on dorm.issue;
create trigger dorm_issue_status_guard_trg
  before update on dorm.issue
  for each row execute function dorm.issue_status_guard();

-- --- 7.2 Munkaköltség tételesen --------------------------------------------
create table if not exists dorm.work_cost (
  id            uuid primary key default gen_random_uuid(),
  issue_id      bigint references dorm.issue(id) on delete cascade,
  building_id   uuid references dorm.building(id) on delete cascade,
  kind          text not null check (kind in ('MATERIAL','LABOUR','EXTERNAL_INVOICE','OTHER')),
  description   text,
  quantity      numeric(10,2),
  unit_price    numeric(12,2),
  amount        numeric(12,2) not null,
  currency      text not null default 'HUF',
  charged_to    text not null default 'UNIVERSITY'
                check (charged_to in ('UNIVERSITY','LANDLORD','RESIDENT','INSURANCE')),
  recoverable   boolean not null default false,   -- a bérbeadótól visszakövetelhető
  recovered_at  timestamptz,
  invoice_ref   text,
  recorded_by   uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists dorm_work_cost_issue_idx on dorm.work_cost (issue_id);
create index if not exists dorm_work_cost_recov_idx on dorm.work_cost (building_id) where recoverable and recovered_at is null;

-- --- 7.3 Megelőző karbantartás ---------------------------------------------
-- A modul legerősebb kockázatcsökkentője: ezekhez BIZONYLAT tartozik, amit
-- hatósági ellenőrzéskor elő kell venni, és aminek hiánya bírságot, súlyos
-- esetben a biztosítási helytállás megtagadását jelenti.
-- BÉRELT ÉPÜLETNÉL a feladat nem elmarad, hanem ÁTALAKUL: "bizonylat bekérése
-- a bérbeadótól, határidő X" — mert a lakóért akkor is mi felelünk.
create table if not exists dorm.pm_plan (
  id             uuid primary key default gen_random_uuid(),
  building_id    uuid references dorm.building(id) on delete cascade,
  room_id        uuid references dorm.room(id) on delete cascade,
  asset_id       uuid,
  code           text not null,
  title          text not null,
  category_code  text references dorm.fault_category(code),
  interval_months integer,
  interval_days   integer,
  is_legal_requirement boolean not null default false,
  legal_reference text,
  responsible_party text not null default 'UNIVERSITY'
                  check (responsible_party in ('UNIVERSITY','LANDLORD','SERVICE_CONTRACT','EXTERNAL_VENDOR')),
  vendor_name    text,
  service_contract_ref text,
  certificate_required boolean not null default false,
  last_done_on   date,
  next_due_on    date,
  is_active      boolean not null default true,
  note           text
);
create unique index if not exists dorm_pm_plan_uidx
  on dorm.pm_plan (coalesce(building_id, '00000000-0000-0000-0000-000000000000'::uuid), code);
create index if not exists dorm_pm_plan_due_idx on dorm.pm_plan (next_due_on) where is_active;

create table if not exists dorm.pm_run (
  id            uuid primary key default gen_random_uuid(),
  plan_id       uuid not null references dorm.pm_plan(id) on delete cascade,
  done_on       date not null,
  performed_by  text,
  result        text not null default 'OK' check (result in ('OK','WITH_FINDINGS','FAILED','NOT_ACCESSIBLE')),
  findings      text,
  certificate_file text,
  issue_id      bigint references dorm.issue(id) on delete set null,
  next_due_on   date,
  recorded_by   uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists dorm_pm_run_plan_idx on dorm.pm_run (plan_id, done_on desc);

-- --- 7.4 Takarítási rend ----------------------------------------------------
-- A kiköltözés utáni takarítás BLOKKOLJA az újrakiadást: a szoba 'available'
-- státusza csak a takarítás lezárása után áll vissza. Enélkül a nyári
-- hasznosítás tervezhetetlen, és a februári beköltözés csúszik.
create table if not exists dorm.cleaning_plan (
  id            uuid primary key default gen_random_uuid(),
  building_id   uuid references dorm.building(id) on delete cascade,
  scope_kind    text not null default 'ROOM_PURPOSE'
                check (scope_kind in ('ROOM_PURPOSE','ROOM_TYPE','SPECIFIC_ROOM','BUILDING')),
  scope_value   text,
  room_id       uuid references dorm.room(id) on delete cascade,
  frequency     text not null,
  provider      text not null default 'INTERNAL' check (provider in ('INTERNAL','EXTERNAL')),
  vendor_name   text,
  checklist     jsonb,
  is_active     boolean not null default true
);

create table if not exists dorm.cleaning_run (
  id            uuid primary key default gen_random_uuid(),
  plan_id       uuid references dorm.cleaning_plan(id) on delete set null,
  building_id   uuid references dorm.building(id) on delete cascade,
  room_id       uuid references dorm.room(id) on delete cascade,
  done_at       timestamptz not null default now(),
  performed_by  text,
  checklist_result jsonb,
  verified_by   uuid references public.profiles(id) on delete set null,
  remark        text
);
create index if not exists dorm_cleaning_run_room_idx on dorm.cleaning_run (room_id, done_at desc);

-- --- 7.5 Szemle -------------------------------------------------------------
create table if not exists dorm.inspection (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null check (kind in
                ('MOVE_IN','MOVE_OUT','SEMESTER_ROOM','MONTHLY_WALKTHROUGH','FIRE_SAFETY',
                 'JOINT_WITH_LANDLORD','EXTRAORDINARY')),
  building_id   uuid not null references dorm.building(id) on delete cascade,
  floor_id      uuid references dorm.floor(id) on delete set null,
  planned_at    timestamptz,
  happened_at   timestamptz,
  performed_by  uuid references public.profiles(id) on delete set null,
  participants  text,
  resident_notified_at timestamptz,
  summary       text,
  created_at    timestamptz not null default now()
);
create index if not exists dorm_inspection_building_idx on dorm.inspection (building_id, planned_at desc);

create table if not exists dorm.inspection_item (
  id             uuid primary key default gen_random_uuid(),
  inspection_id  uuid not null references dorm.inspection(id) on delete cascade,
  room_id        uuid references dorm.room(id) on delete cascade,
  checklist_code text,
  checklist_label text not null,
  result         text not null default 'OK'
                 check (result in ('OK','FAULT','IMMEDIATE_ACTION','NOT_ACCESSIBLE','NOT_APPLICABLE')),
  liable_hint    text,
  photo          text,
  remark         text,
  issue_id       bigint references dorm.issue(id) on delete set null
);
create index if not exists dorm_inspection_item_insp_idx on dorm.inspection_item (inspection_id);

-- --- 7.6 Kulcs és beléptetőkártya ------------------------------------------
-- Kiköltözéskor az azonnali deaktiválás a leggyakrabban elmaradó lépés, és
-- biztonsági rés: aktív kártyával hónapokig bejár valaki, aki már nem lakó.
-- Ezért: a kaució addig NEM fizethető vissza, amíg a visszavétel nincs lezárva
-- (dorm.deposit.settlement_blocked_reason). A pénz az egyetlen megbízható
-- kényszerítő erő.
-- KÁRTYANYILVÁNTARTÁS != BELÉPÉSI NAPLÓ. A belépési eseménynapló behozatala
-- külön döntés, külön jogalappal — ezt SZÁNDÉKOSAN nem hozzuk be.
create table if not exists dorm.key (
  id            uuid primary key default gen_random_uuid(),
  building_id   uuid not null references dorm.building(id) on delete cascade,
  identifier    text not null,
  key_type      text not null default 'MECHANICAL'
                check (key_type in ('MECHANICAL','CARD','TAG','CODE')),
  opens_kind    text not null default 'ROOM'
                check (opens_kind in ('ROOM','LOCKER','BUILDING_ENTRANCE','COMMON_ROOM','MASTER')),
  room_id       uuid references dorm.room(id) on delete cascade,
  copies_total  integer not null default 1,
  master_level  integer,
  storage_place text,
  is_active     boolean not null default true,
  note          text,
  unique (building_id, identifier)
);
create index if not exists dorm_key_master_idx on dorm.key (building_id) where master_level is not null;

create table if not exists dorm.key_issue (
  id            uuid primary key default gen_random_uuid(),
  key_id        uuid not null references dorm.key(id) on delete cascade,
  person_id     uuid not null references dorm.person(id) on delete restrict,
  occupancy_id  uuid references dorm.occupancy(id) on delete set null,
  issued_at     timestamptz not null default now(),
  issued_by     uuid references public.profiles(id) on delete set null,
  signature_ref text,
  returned_at   timestamptz,
  returned_to   uuid references public.profiles(id) on delete set null,
  deactivated_at timestamptz,
  lost_at       timestamptz,
  lock_changed  boolean not null default false,
  fee_charged   numeric(12,2),
  note          text
);
create index if not exists dorm_key_issue_person_idx on dorm.key_issue (person_id);
create index if not exists dorm_key_issue_open_idx   on dorm.key_issue (key_id) where returned_at is null;

-- --- 7.7 Leltár és mozgásnapló ---------------------------------------------
-- MŰSZAKI AVULÁS, nem könyvelési amortizáció: a tárgyi eszköz nyilvántartás a
-- gazdasági rendszeré, a modul nem helyettesíti. A leltári szám a KÖZÖS KULCS;
-- a modul a "hol van / milyen állapotban van", a gazdasági rendszer a
-- "mennyit ér" kérdésre válaszol.
create table if not exists dorm.asset (
  id            uuid primary key default gen_random_uuid(),
  inventory_no  text unique,
  asset_type    text not null,
  name          text not null,
  building_id   uuid references dorm.building(id) on delete set null,
  room_id       uuid references dorm.room(id) on delete set null,
  serial_number text,
  acquired_on   date,
  acquired_value numeric(14,2),
  currency      text default 'HUF',
  expected_life_years integer,
  condition_grade integer check (condition_grade is null or condition_grade between 1 and 5),
  warranty_until date,
  is_active     boolean not null default true,
  note          text
);
create index if not exists dorm_asset_room_idx on dorm.asset (room_id);
create index if not exists dorm_asset_life_idx on dorm.asset (acquired_on, expected_life_years) where is_active;

create table if not exists dorm.asset_move (
  id          uuid primary key default gen_random_uuid(),
  asset_id    uuid not null references dorm.asset(id) on delete cascade,
  from_room   uuid references dorm.room(id) on delete set null,
  to_room     uuid references dorm.room(id) on delete set null,
  moved_at    timestamptz not null default now(),
  moved_by    uuid references public.profiles(id) on delete set null,
  reason      text
);
create index if not exists dorm_asset_move_asset_idx on dorm.asset_move (asset_id, moved_at desc);

comment on table dorm.asset_move is
  'A "hova tűnt a hűtő a 312-esből" kérdés hetente előjön. Mozgásnapló nélkül a leltár néhány hónap alatt használhatatlanná válik.';

-- --- 7.8 Kárfelvétel --------------------------------------------------------
-- Eljárási garanciák, amik nélkül ez panaszgyárrá válik: a lakó LÁSSA a
-- kárfelvételt fotóval még a kiköltözés napján; legyen KIFOGÁSOLÁSI HATÁRIDŐ;
-- legyen NEVESÍTETT DÖNTÉSHOZÓ; és az elszámolás legyen ZÁRT LEVEZETÉS:
-- kaució − igazolt kár − elmaradt díj = visszafizetendő.
create table if not exists dorm.damage (
  id             uuid primary key default gen_random_uuid(),
  building_id    uuid not null references dorm.building(id) on delete cascade,
  room_id        uuid references dorm.room(id) on delete set null,
  asset_id       uuid references dorm.asset(id) on delete set null,
  occupancy_id   uuid references dorm.occupancy(id) on delete set null,
  person_id      uuid references dorm.person(id) on delete set null,
  discovered_at  timestamptz not null default now(),
  source         text not null default 'MOVE_OUT'
                 check (source in ('INSPECTION','MOVE_OUT','REPORT','MAINTENANCE','OTHER')),
  description    text not null,
  photos         jsonb,
  estimated_cost numeric(12,2),
  actual_cost    numeric(12,2),
  currency       text not null default 'HUF',
  liability      text not null default 'UNKNOWN'
                 check (liability in ('NAMED_RESIDENT','ROOM_SHARED','COMMUNITY_SHARED','UNKNOWN_UNIVERSITY','FORCE_MAJEURE')),
  disputed       boolean not null default false,
  objection_deadline date,
  objection_text text,
  decision       text,
  decided_by     uuid references public.profiles(id) on delete set null,
  decided_at     timestamptz,
  recovery_mode  text check (recovery_mode is null or recovery_mode in
                 ('FROM_DEPOSIT','INVOICE','INSTALMENTS','WAIVED')),
  issue_id       bigint references dorm.issue(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists dorm_damage_person_idx   on dorm.damage (person_id);
create index if not exists dorm_damage_building_idx on dorm.damage (building_id, discovered_at desc);


-- ============================================================================
-- 8. SZAKASZ — PÉNZÜGY
-- ============================================================================
-- MÉRT KORLÁT, ami miatt a meglévő táblákra önmagában nem lehet kollégiumi
-- díjat építeni (\d public.payments / public.invoices):
--   1. studentName SZÖVEGGEL azonosít, nincs student_id idegen kulcs;
--   2. nincs tételszintű bontás — egy számla = egy összeg, a kollégiumi
--      számlán viszont több sor van (havi díj + késedelmi díj + kár − kedvezmény);
--   3. a dátumok text típusúak, nincs korosítás adatbázis-szinten;
--   4. nincs ismétlődő kötelezettség fogalma.
-- KÖVETKEZTETÉS: a payments/invoices táblákat NEM írjuk át (párhuzamos
-- frontend-munka folyik, és a felvételi pénzügy is rajtuk ül). A dorm.charge a
-- modul belső főkönyve TÉTELSZINTEN; a meglévő felé RPC-n át illeszkedünk
-- (public.dorm_charges_to_invoice). Amikor a UniPortal pénzügye később rendes
-- tételes számlázást kap, a dorm.charge már kész, csak a kimenet cserélődik.

-- --- 8.1 Díjkatalógus — az első és legfontosabb tábla -----------------------
-- EZ JAVÍTJA KI a mért ellentmondást: ma az app.jsx:6628 EUR 450 kauciót, a
-- features/knowledge-base.jsx:40 EUR 750-et mond. A katalógus után EGY helyen
-- van a szám, és onnan olvassa a felvételi levél generátora, az asszisztens
-- tudásbázisa és a számlázás egyaránt.
create table if not exists dorm.fee_schedule (
  id            uuid primary key default gen_random_uuid(),
  code          text not null,
  label_hu      text not null,
  fee_type      text not null check (fee_type in
                ('DORM_FEE_MONTHLY','DORM_FEE_SEMESTER','DEPOSIT','KEY_REPLACEMENT',
                 'LATE_FEE','CLEANING_PENALTY','GUEST_NIGHT','DAMAGE','UTILITY_REBILL')),
  building_id   uuid references dorm.building(id) on delete cascade,
  room_type     text references dorm.room_type(code) on delete cascade,
  target_group  text not null default 'ANY' check (target_group in
                ('ANY','DOMESTIC_SELF_FUNDED','DOMESTIC_STATE_FUNDED','INTERNATIONAL',
                 'STIPENDIUM_HUNGARICUM','PHD','GUEST','SUMMER')),
  amount        numeric(12,2) not null,
  currency      text not null default 'HUF',
  -- Arányosítás PARAMÉTER, nem kód: a hó közben be-/kiköltöző díja. Bármelyik
  -- védhető, de EGYET kell választani és következetesen alkalmazni — a lakók
  -- egymás közt összehasonlítják.
  proration     text not null default 'CALENDAR_DAYS' check (proration in
                ('FULL_MONTH','CALENDAR_DAYS','STARTED_WEEK','STARTED_MONTH','NONE')),
  valid_from    date not null default current_date,
  valid_to      date,
  note          text,
  created_at    timestamptz not null default now()
);
create unique index if not exists dorm_fee_schedule_uidx
  on dorm.fee_schedule (code, coalesce(building_id, '00000000-0000-0000-0000-000000000000'::uuid),
                        coalesce(room_type, '-'), target_group, valid_from);
create index if not exists dorm_fee_schedule_type_idx on dorm.fee_schedule (fee_type, valid_from desc);

-- --- 8.2 Kötelezettségek tételesen -----------------------------------------
-- DEVIZA: a nemzetközi díjak EUR-ban vannak beégetve, a magyar rezsi- és
-- karbantartási számlák HUF-ban jönnek. currency + fx_rate + fx_date nélkül a
-- riportok ÖSSZEADHATATLANOK — ez a leggyakrabban elfelejtett részlet.
-- A 'planned' státusz teszi lehetővé a bevételtervezést: a jövő félévre már ma
-- legenerálhatók a várható tételek a dorm.occupancy időszakaiból.
create table if not exists dorm.charge (
  id             uuid primary key default gen_random_uuid(),
  person_id      uuid not null references dorm.person(id) on delete restrict,
  occupancy_id   uuid references dorm.occupancy(id) on delete set null,
  building_id    uuid references dorm.building(id) on delete set null,
  fee_type       text not null,
  fee_schedule_id uuid references dorm.fee_schedule(id) on delete set null,
  period         daterange,
  amount         numeric(12,2) not null,
  currency       text not null default 'HUF',
  fx_rate        numeric(14,6),
  fx_date        date,
  amount_huf     numeric(14,2) generated always as (
                   case when currency = 'HUF' then amount
                        when fx_rate is not null then round(amount * fx_rate, 2)
                        else null end
                 ) stored,
  due_on         date,
  status         text not null default 'planned' check (status in
                 ('planned','due','invoiced','paid','partially_paid','waived','written_off','refunded')),
  paid_amount    numeric(12,2) not null default 0,
  discount_id    uuid,
  damage_id      uuid references dorm.damage(id) on delete set null,
  utility_bill_id uuid,
  external_invoice_id text,   -- a meglévő public.invoices.id-hez
  note           text,
  created_at     timestamptz not null default now()
);
create index if not exists dorm_charge_person_idx on dorm.charge (person_id, due_on);
create index if not exists dorm_charge_status_idx on dorm.charge (status) where status in ('planned','due','invoiced','partially_paid');
create index if not exists dorm_charge_occ_idx    on dorm.charge (occupancy_id);

-- --- 8.3 Kaució — KÉT IRÁNYBAN ---------------------------------------------
-- Ugyanaz a tábla, direction mezővel, mert az életciklusuk azonos
-- (letét → esemény → elszámolás → visszafizetés), csak a szereplők cserélődnek.
--   PAID_TO_LANDLORD   — mi adtuk a bérbeadónak; a legkönnyebben ELFELEJTETT
--                        pénz: figyelni kell, hogy vissza is jöjjön.
--   HELD_FROM_RESIDENT — a lakó adta nekünk; NEM BEVÉTEL, hanem KÖTELEZETTSÉG.
--                        Ha bevételként kezeljük, a visszafizetéskor lesz baj.
create table if not exists dorm.deposit (
  id             uuid primary key default gen_random_uuid(),
  direction      text not null check (direction in ('PAID_TO_LANDLORD','HELD_FROM_RESIDENT')),
  person_id      uuid references dorm.person(id) on delete set null,
  contract_id    uuid references dorm.contract(id) on delete set null,
  building_id    uuid references dorm.building(id) on delete set null,
  lease_id       uuid references dorm.lease(id) on delete set null,
  amount         numeric(14,2) not null,
  currency       text not null default 'HUF',
  received_on    date,
  due_back_on    date,
  status         text not null default 'HELD' check (status in
                 ('HELD','PARTIALLY_SETTLED','SETTLED','REFUNDED','FORFEITED','OVERDUE')),
  deductions     numeric(14,2) not null default 0,
  deduction_reason text,
  refunded_amount numeric(14,2),
  refunded_on    date,
  refund_account text,
  -- A kaució addig NEM fizethető vissza, amíg ez ki van töltve (kulcs/kártya
  -- vissza nem vétel, hátralék, nyitott kárügy). A pénz az egyetlen megbízható
  -- kényszerítő erő.
  settlement_blocked_reason text,
  note           text,
  created_at     timestamptz not null default now(),
  check (direction = 'PAID_TO_LANDLORD' or person_id is not null)
);
create index if not exists dorm_deposit_person_idx on dorm.deposit (person_id);
create index if not exists dorm_deposit_dir_idx    on dorm.deposit (direction, status);

-- --- 8.4 Kedvezmény ---------------------------------------------------------
-- A modul legnagyobb visszaélési kockázata: ezért minden kedvezmény NEVESÍTETT
-- engedélyezőhöz, indokláshoz és igazoláshoz kötött, és naplózott. Nem
-- gyanúsítás, hanem az engedélyező VÉDELME is: utólag igazolható a döntés.
create table if not exists dorm.discount (
  id            uuid primary key default gen_random_uuid(),
  person_id     uuid not null references dorm.person(id) on delete cascade,
  title         text not null,
  discount_kind text not null check (discount_kind in ('PERCENT','FIXED')),
  value         numeric(12,2) not null,
  currency      text default 'HUF',
  valid_from    date not null,
  valid_to      date,
  approved_by   uuid references public.profiles(id) on delete set null,
  approver_name text,
  reason        text not null,
  evidence_file text,
  review_on     date,
  created_at    timestamptz not null default now()
);
create index if not exists dorm_discount_person_idx  on dorm.discount (person_id);
create index if not exists dorm_discount_approver_idx on dorm.discount (approved_by);

do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'dorm_charge_discount_fkey') then
    alter table dorm.charge add constraint dorm_charge_discount_fkey
      foreign key (discount_id) references dorm.discount(id) on delete set null;
  end if;
end
$c$;

-- --- 8.5 Mérőóra és leolvasás ----------------------------------------------
-- A HITELESÍTÉS LEJÁRATA azért külön mező, mert lejárt hitelesítésű mérőóra
-- állására alapozott elszámolást joggal lehet vitatni — MINDKÉT IRÁNYBAN.
create table if not exists dorm.meter (
  id            uuid primary key default gen_random_uuid(),
  building_id   uuid not null references dorm.building(id) on delete cascade,
  room_id       uuid references dorm.room(id) on delete set null,
  meter_type    text not null check (meter_type in
                ('ELECTRICITY','GAS','HEAT','COLD_WATER','HOT_WATER','SUBMETER')),
  serial_number text not null,
  owner_party   text not null default 'UNIVERSITY'
                check (owner_party in ('UNIVERSITY','LANDLORD','UTILITY')),
  read_by       text not null default 'UNIVERSITY'
                check (read_by in ('UNIVERSITY','LANDLORD','UTILITY')),
  read_frequency text,
  calibration_due_on date,
  standing_charge_bearer text,
  is_active     boolean not null default true,
  note          text,
  unique (building_id, serial_number)
);
create index if not exists dorm_meter_calib_idx on dorm.meter (calibration_due_on) where is_active;

create table if not exists dorm.meter_reading (
  id          uuid primary key default gen_random_uuid(),
  meter_id    uuid not null references dorm.meter(id) on delete cascade,
  read_on     date not null,
  value       numeric(14,3) not null,
  source      text not null default 'OWN_READING'
              check (source in ('OWN_READING','LANDLORD_INVOICE','UTILITY_NOTICE','ESTIMATED')),
  read_by_name text,
  photo       text,
  note        text,
  unique (meter_id, read_on, source)
);
create index if not exists dorm_meter_reading_idx on dorm.meter_reading (meter_id, read_on desc);

-- --- 8.6 Rezsi és továbbszámlázás ------------------------------------------
create table if not exists dorm.utility_bill (
  id            uuid primary key default gen_random_uuid(),
  building_id   uuid not null references dorm.building(id) on delete cascade,
  period        daterange not null,
  utility_type  text not null,
  issuer        text not null default 'UTILITY' check (issuer in ('UTILITY','LANDLORD')),
  invoice_ref   text,
  amount        numeric(14,2) not null,
  currency      text not null default 'HUF',
  consumption   numeric(14,3),
  meter_id      uuid references dorm.meter(id) on delete set null,
  -- A bérbeadói továbbszámlázás ellenőrzése: ha a bérbeadó számláját a SAJÁT
  -- leolvasásunkkal ütköztetjük, a hibás számlázás kiderül. Enélkül fizetünk,
  -- mert nincs mivel vitatkozni.
  verified_against_own_reading boolean not null default false,
  verification_note text,
  allocation_basis text not null default 'BED_NIGHTS'
                check (allocation_basis in ('BED_NIGHTS','FLOOR_AREA','SUBMETER','FLAT_RATE','NONE')),
  paid_on       date,
  created_at    timestamptz not null default now()
);
create index if not exists dorm_utility_bill_bld_idx on dorm.utility_bill (building_id, lower(period) desc);

do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'dorm_charge_utility_fkey') then
    alter table dorm.charge add constraint dorm_charge_utility_fkey
      foreign key (utility_bill_id) references dorm.utility_bill(id) on delete set null;
  end if;
end
$c$;


-- ============================================================================
-- 9. SZAKASZ — HOZZÁFÉRÉSI NAPLÓ
-- ============================================================================
-- Ennél a modulnál a JOGOSULATLAN MEGTEKINTÉS a kár, nem a módosítás — ezért
-- az OLVASÁST is naplózzuk. A meglévő public."auditLogs" erre kevés (mérve:
-- minden oszlopa text, az időbélyeg is; nincs idegen kulcs, nincs indexelhető
-- esemény-tipológia, és nincs "hány sort kapott" fogalom) — de hozzá NEM
-- nyúlunk, mert más folyamatok használják.
--
-- AMIT A NAPLÓBA NEM SZABAD BEÍRNI: magát a lekért lakólistát. Különben a
-- naplótábla lenne a legnagyobb, legkevésbé védett MÁSOLAT az adatból. Elég a
-- szűrőfeltétel és a SOROK SZÁMA.
create table if not exists dorm.access_log (
  id           bigint generated always as identity primary key,
  viewer       uuid references public.profiles(id) on delete set null,
  viewer_email text,
  happened_at  timestamptz not null default now(),
  action       text not null,
  object_kind  text,
  object_id    text,
  building_id  uuid,
  filter_text  text,
  row_count    integer,
  justification text,
  is_alert     boolean not null default false
);
create index if not exists dorm_access_log_viewer_idx on dorm.access_log (viewer, happened_at desc);
create index if not exists dorm_access_log_alert_idx  on dorm.access_log (happened_at desc) where is_alert;

create or replace function dorm.log_access(
  p_action text, p_object_kind text default null, p_object_id text default null,
  p_building uuid default null, p_filter text default null,
  p_rows integer default null, p_alert boolean default false)
returns void language plpgsql security definer
set search_path = dorm, public, extensions, pg_temp
as $$
begin
  insert into dorm.access_log (viewer, viewer_email, action, object_kind, object_id,
                               building_id, filter_text, row_count, is_alert)
  values (auth.uid(), nullif(public.my_email(), ''), p_action, p_object_kind, p_object_id,
          p_building, p_filter, p_rows, p_alert);
exception when others then
  null;   -- a naplózás soha ne buktassa el az üzemeltetési műveletet
end
$$;


-- ============================================================================
-- 10. SZAKASZ — NÉZETEK: a két olvasat szétválasztása
-- ============================================================================
-- A karbantartónak NEM kell tudnia, kinek a szobájába megy javítani — csak
-- azt, melyik szobába. Mindkét nézet OWNER-jogú (NEM security_invoker), és a
-- hatókör-szűrés MAGÁBAN A NÉZETBEN van: így a szűrés nem felejthető el a
-- hívó oldalon, és egy elrontott kliens-lekérdezés sem nyit rést.

drop view if exists dorm.v_room_occupancy;
drop view if exists dorm.v_room_operational;
drop view if exists dorm.v_building_capacity;

create view dorm.v_room_operational as
select
  b.id            as building_id,
  b.code          as building_code,
  b.name          as building_name,
  b.tenure,
  f.level_no,
  f.wing,
  r.id            as room_id,
  r.full_code     as room_code,
  r.door_number,
  r.room_type,
  r.purpose,
  r.status        as room_status,
  r.area_sqm,
  r.is_accessible,
  r.gender_restriction,
  count(bd.id)                                                     as beds_registered,
  count(bd.id) filter (where bs.is_operable and rs.is_operable)     as beds_operable,
  count(bd.id) filter (where bs.is_lettable and rs.is_lettable
                         and bs.is_operable and rs.is_operable)     as beds_lettable,
  -- A LAKÓK SZÁMA, NÉV NÉLKÜL:
  (select count(*) from dorm.occupancy o
     where o.bed_id in (select id from dorm.bed where room_id = r.id)
       and o.state in ('ALLOCATED','MOVED_IN')
       and o.period @> current_date)                               as occupied_now,
  (select count(*) from dorm.issue i
     where i.room_id = r.id
       and i.status in (select code from dorm.issue_status where is_open))  as open_issues,
  -- min(), NEM max(): a P1 a legsúlyosabb, és az ábécésorrendben az a legkisebb.
  (select min(i.priority) from dorm.issue i
     where i.room_id = r.id
       and i.status in (select code from dorm.issue_status where is_open))  as worst_open_priority,
  (select max(pr.done_on) from dorm.pm_run pr
     join dorm.pm_plan pp on pp.id = pr.plan_id
    where pp.room_id = r.id)                                       as last_pm_on
from dorm.room r
join dorm.building b on b.id = r.building_id
join dorm.floor f    on f.id = r.floor_id
join dorm.room_status rs on rs.code = r.status
left join dorm.bed bd    on bd.room_id = r.id
left join dorm.bed_status bs on bs.code = bd.status
where dorm.can_see_building(b.id)
group by b.id, b.code, b.name, b.tenure, f.level_no, f.wing,
         r.id, r.full_code, r.door_number, r.room_type, r.purpose, r.status,
         r.area_sqm, r.is_accessible, r.gender_restriction;

comment on view dorm.v_room_operational is
  'Üzemeltetői olvasat: szoba, kapacitás, FOGLALTAK SZÁMA, nyitott hibák — NÉV NÉLKÜL. GONDNOK, KARBANTARTO, KOLI_ADMIN, INGATLAN (épület-hatókörrel).';

create view dorm.v_room_occupancy as
select
  b.id        as building_id,
  b.code      as building_code,
  b.name      as building_name,
  f.level_no,
  r.id        as room_id,
  r.full_code as room_code,
  bd.id       as bed_id,
  bd.full_code as bed_code,
  bd.status   as bed_status,
  o.id        as occupancy_id,
  o.period,
  o.state,
  p.id        as person_id,
  -- 8.7: a VÉDETT lakó neve és elérhetősége itt is elrejtve, ha a néző nem a
  -- saját épület gondnoka vagy intézményi jogosult.
  case when p.protected and not dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN'])
            and not dorm.has_role('GONDNOK', b.id) and not public.is_admin()
       then 'VÉDETT' else p.display_name end as display_name,
  case when p.protected then null else p.email end as email,
  case when p.protected then null else p.phone end as phone,
  p.protected,
  p.kind,
  p.student_id,
  c.id        as contract_id,
  c.iktatoszam as contract_ref,
  c.ends_on   as contract_ends_on
from dorm.occupancy o
join dorm.bed bd      on bd.id = o.bed_id
join dorm.room r      on r.id = bd.room_id
join dorm.floor f     on f.id = r.floor_id
join dorm.building b  on b.id = r.building_id
join dorm.person p    on p.id = o.person_id
left join dorm.contract c on c.id = o.contract_id
where o.state <> 'CANCELLED'
  and dorm.can_see_residents(b.id);

comment on view dorm.v_room_occupancy is
  'Lakói olvasat: "ki hol lakik". CSAK GONDNOK / KOLI_ADMIN / KOLI_SYSADMIN (épület-hatókörrel) és is_admin(). A KARBANTARTO és az INGATLAN szándékosan NEM látja.';

create view dorm.v_building_capacity as
select
  b.id   as building_id,
  b.code as building_code,
  b.name as building_name,
  b.tenure,
  t.is_owned,
  t.label_hu as tenure_label,
  l.name as landlord_name,
  count(bd.id)                                                 as beds_registered,
  count(bd.id) filter (where bs.is_operable and rs.is_operable) as beds_operable,
  count(bd.id) filter (where bs.is_operable and rs.is_operable
                         and bs.is_lettable and rs.is_lettable) as beds_lettable,
  (select count(*) from dorm.occupancy o
     join dorm.bed b2 on b2.id = o.bed_id
    where b2.building_id = b.id
      and o.state in ('ALLOCATED','MOVED_IN')
      and o.period @> current_date)                            as beds_occupied,
  (select count(*) from dorm.issue i
     where i.building_id = b.id
       and i.status in (select code from dorm.issue_status where is_open)) as open_issues
from dorm.building b
join dorm.tenure t on t.code = b.tenure
left join dorm.landlord l on l.id = b.landlord_id
left join dorm.room r  on r.building_id = b.id and r.purpose = 'RESIDENTIAL'
left join dorm.room_status rs on rs.code = r.status
left join dorm.bed bd  on bd.room_id = r.id
left join dorm.bed_status bs on bs.code = bd.status
where dorm.can_see_building(b.id)
group by b.id, b.code, b.name, b.tenure, t.is_owned, t.label_hu, l.name;


-- ============================================================================
-- 11. SZAKASZ — RLS
-- ============================================================================
-- A projekt konvenciója szerint, `dorm_` policy-előtaggal — hogy elkülönüljön
-- a mért 86 db `rbac_` policy-től, és hogy a modul önellenőrzése (14. szakasz)
-- meg tudja számolni a sajátjait.
--
-- A HÁROM SZINT:
--   KATALÓGUS        — minden bejelentkezett olvashatja (a legördülők ebből
--                      épülnek), írni csak dorm.can_grant() tud.
--   MŰSZAKI TÖRZSADAT— épület-hatókör: dorm.can_see_building(); a lakó a SAJÁT
--                      épületét/szobáját is látja (hibabejelentéshez kell).
--   LAKÓI ADAT       — a lakó a sajátját; a gondnok a SAJÁT ÉPÜLETÉT;
--                      a karbantartó és az ingatlangazda EGYÁLTALÁN NEM.
--
-- A helperek SECURITY DEFINER-ek, ezért a role_grant olvasása a policy-kből
-- NEM okoz rekurziót (a definer a tábla tulajdonosaként fut, és a tulajdonost
-- az RLS nem korlátozza — FORCE ROW LEVEL SECURITY-t SEHOL nem kapcsolunk be).

-- --- 11.0 Segédfüggvények a lakói önkiszolgáláshoz --------------------------
-- A saját lakói sorom. A törzse limit 1 — ezért kell a két részleges UNIQUE
-- index a dorm.person-ön (6. szerkezeti döntés).
create or replace function dorm.my_person_id()
returns uuid language sql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
  select coalesce(
    (select p.id from dorm.person p where p.profile_id = auth.uid() limit 1),
    (select p.id from dorm.person p
      where public.my_student_id() is not null
        and p.student_id = public.my_student_id() limit 1)
  )
$$;

-- A hatókörömbe eső épületek — a policy-kben és az RPC-kben is ezt használjuk.
create or replace function dorm.my_building_ids()
returns uuid[] language sql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
  select case
    when public.is_admin() then (select coalesce(array_agg(b.id), '{}'::uuid[]) from dorm.building b)
    when exists (select 1 from dorm.role_grant g
                  where g.person = auth.uid() and g.scope_building is null
                    and (g.expires_at is null or g.expires_at > now()))
         and public.is_approved()
      then (select coalesce(array_agg(b.id), '{}'::uuid[]) from dorm.building b)
    when public.is_approved()
      then (select coalesce(array_agg(distinct g.scope_building), '{}'::uuid[])
              from dorm.role_grant g
             where g.person = auth.uid() and g.scope_building is not null
               and (g.expires_at is null or g.expires_at > now()))
    else '{}'::uuid[]
  end
$$;


create or replace function dorm.my_current_room_ids()
returns uuid[] language sql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
  select coalesce(array_agg(distinct bd.room_id), '{}'::uuid[])
    from dorm.occupancy o
    join dorm.bed bd on bd.id = o.bed_id
   where o.person_id = dorm.my_person_id()
     and o.state in ('ALLOCATED','MOVED_IN')
     and o.period @> current_date
$$;

create or replace function dorm.my_current_building_ids()
returns uuid[] language sql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
  select coalesce(array_agg(distinct o.building_id), '{}'::uuid[])
    from dorm.occupancy o
   where o.person_id = dorm.my_person_id()
     and o.state in ('ALLOCATED','MOVED_IN')
     and o.period @> current_date
$$;

-- --- 11.1 RLS bekapcsolása MINDEN dorm táblán -------------------------------
-- Egy ciklusban, hogy egy jövőbeni tábla se maradhasson ki véletlenül.
do $rls$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'dorm'
  loop
    execute format('alter table dorm.%I enable row level security', t.tablename);
  end loop;
end
$rls$;

-- --- 11.2 Katalógusok -------------------------------------------------------
do $cat$
declare t text;
begin
  foreach t in array array[
    'tenure','room_type','room_status','room_status_transition','bed_status',
    'fault_category','issue_status','issue_status_transition',
    'application_status','application_transition','fee_schedule']
  loop
    execute format('drop policy if exists %I on dorm.%I', 'dorm_' || t || '_read',  t);
    execute format('drop policy if exists %I on dorm.%I', 'dorm_' || t || '_write', t);
    execute format(
      'create policy %I on dorm.%I for select to authenticated using (public.is_approved())',
      'dorm_' || t || '_read', t);
    execute format(
      'create policy %I on dorm.%I for all to authenticated using (dorm.can_grant()) with check (dorm.can_grant())',
      'dorm_' || t || '_write', t);
  end loop;
end
$cat$;

-- --- 11.3 Szerepkör-grantok -------------------------------------------------
drop policy if exists dorm_role_grant_read  on dorm.role_grant;
drop policy if exists dorm_role_grant_write on dorm.role_grant;
create policy dorm_role_grant_read on dorm.role_grant for select to authenticated
  using (person = auth.uid() or dorm.can_grant());
create policy dorm_role_grant_write on dorm.role_grant for all to authenticated
  using (dorm.can_grant()) with check (dorm.can_grant());

-- --- 11.4 Telephely és bérbeadó --------------------------------------------
drop policy if exists dorm_site_read  on dorm.site;
drop policy if exists dorm_site_write on dorm.site;
create policy dorm_site_read on dorm.site for select to authenticated
  using (public.is_approved());
create policy dorm_site_write on dorm.site for all to authenticated
  using (dorm.can_grant()) with check (dorm.can_grant());

-- A bérbeadó adata (ügyeleti telefon, bankszámla) NEM közadat: csak az
-- INGATLAN szerepkör, a KOLI_SYSADMIN és az intézményi kör látja.
drop policy if exists dorm_landlord_read  on dorm.landlord;
drop policy if exists dorm_landlord_write on dorm.landlord;
create policy dorm_landlord_read on dorm.landlord for select to authenticated
  using (public.is_admin() or dorm.has_any_role(array['INGATLAN','KOLI_ADMIN','KOLI_SYSADMIN','GONDNOK']));
create policy dorm_landlord_write on dorm.landlord for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['INGATLAN','KOLI_SYSADMIN']))
  with check (public.is_admin() or dorm.has_any_role(array['INGATLAN','KOLI_SYSADMIN']));

-- --- 11.5 Épület, szint, szoba, férőhely ------------------------------------
-- A lakó a SAJÁT épületét és szobáját látja (a hibabejelentő űrlaphoz kell),
-- MÁS épületét nem. Ez a "gondnok a saját épületét" követelmény lakói párja.
drop policy if exists dorm_building_read  on dorm.building;
drop policy if exists dorm_building_write on dorm.building;
create policy dorm_building_read on dorm.building for select to authenticated
  using (dorm.can_see_building(id) or id = any (dorm.my_current_building_ids()));
create policy dorm_building_write on dorm.building for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['KOLI_SYSADMIN','INGATLAN']))
  with check (public.is_admin() or dorm.has_any_role(array['KOLI_SYSADMIN','INGATLAN']));

drop policy if exists dorm_floor_read  on dorm.floor;
drop policy if exists dorm_floor_write on dorm.floor;
create policy dorm_floor_read on dorm.floor for select to authenticated
  using (dorm.can_see_building(building_id) or building_id = any (dorm.my_current_building_ids()));
create policy dorm_floor_write on dorm.floor for all to authenticated
  using (dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], building_id) or public.is_admin())
  with check (dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], building_id) or public.is_admin());

drop policy if exists dorm_room_read  on dorm.room;
drop policy if exists dorm_room_write on dorm.room;
create policy dorm_room_read on dorm.room for select to authenticated
  using (dorm.can_see_building(building_id) or id = any (dorm.my_current_room_ids()));
create policy dorm_room_write on dorm.room for all to authenticated
  using (dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], building_id) or public.is_admin())
  with check (dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], building_id) or public.is_admin());

drop policy if exists dorm_bed_read  on dorm.bed;
drop policy if exists dorm_bed_write on dorm.bed;
create policy dorm_bed_read on dorm.bed for select to authenticated
  using (dorm.can_see_building(building_id) or room_id = any (dorm.my_current_room_ids()));
create policy dorm_bed_write on dorm.bed for all to authenticated
  using (dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], building_id) or public.is_admin())
  with check (dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], building_id) or public.is_admin());

-- Státusztörténet: üzemeltetői olvasat, írni csak a trigger (definer) tud.
drop policy if exists dorm_room_status_history_read on dorm.room_status_history;
create policy dorm_room_status_history_read on dorm.room_status_history for select to authenticated
  using (exists (select 1 from dorm.room r where r.id = room_id and dorm.can_see_building(r.building_id)));
drop policy if exists dorm_bed_status_history_read on dorm.bed_status_history;
create policy dorm_bed_status_history_read on dorm.bed_status_history for select to authenticated
  using (exists (select 1 from dorm.bed b where b.id = bed_id and dorm.can_see_building(b.building_id)));

-- --- 11.6 Bérleti szerződés és felelősségi mátrix ---------------------------
drop policy if exists dorm_lease_read  on dorm.lease;
drop policy if exists dorm_lease_write on dorm.lease;
create policy dorm_lease_read on dorm.lease for select to authenticated
  using (public.is_admin() or dorm.has_any_role(array['INGATLAN','KOLI_ADMIN','KOLI_SYSADMIN'], building_id));
create policy dorm_lease_write on dorm.lease for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['INGATLAN','KOLI_SYSADMIN'], building_id))
  with check (public.is_admin() or dorm.has_any_role(array['INGATLAN','KOLI_SYSADMIN'], building_id));

-- A mátrixot MINDENKI olvashatja, aki bejelentkezett: a lakó is lássa, hova
-- megy a bejelentése és mi a határidő. Ez a modul napi haszna.
drop policy if exists dorm_responsibility_read  on dorm.responsibility;
drop policy if exists dorm_responsibility_write on dorm.responsibility;
create policy dorm_responsibility_read on dorm.responsibility for select to authenticated
  using (public.is_approved());
create policy dorm_responsibility_write on dorm.responsibility for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['KOLI_SYSADMIN','INGATLAN','KOLI_ADMIN'], building_id))
  with check (public.is_admin() or dorm.has_any_role(array['KOLI_SYSADMIN','INGATLAN','KOLI_ADMIN'], building_id));

-- --- 11.7 A LAKÓI KÖR — a modul legérzékenyebb adata ------------------------
-- dorm.person: a lakó a sajátját; a gondnok CSAK azokat, akik az Ő épületében
-- laknak; a KARBANTARTO és az INGATLAN EGYÁLTALÁN NEM.
drop policy if exists dorm_person_read  on dorm.person;
drop policy if exists dorm_person_write on dorm.person;
create policy dorm_person_read on dorm.person for select to authenticated
  using (
    id = dorm.my_person_id()
    or public.is_admin()
    or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN'])
    or exists (select 1 from dorm.occupancy o
                where o.person_id = dorm.person.id
                  and o.state <> 'CANCELLED'
                  and dorm.has_role('GONDNOK', o.building_id))
  );
create policy dorm_person_write on dorm.person for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']))
  with check (public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']));

-- dorm.occupancy: a "ki hol lakik" tábla. A LEGSZIGORÚBB policy a modulban.
drop policy if exists dorm_occupancy_read  on dorm.occupancy;
drop policy if exists dorm_occupancy_write on dorm.occupancy;
create policy dorm_occupancy_read on dorm.occupancy for select to authenticated
  using (person_id = dorm.my_person_id() or dorm.can_see_residents(building_id));
create policy dorm_occupancy_write on dorm.occupancy for all to authenticated
  using (dorm.can_place(building_id)) with check (dorm.can_place(building_id));

drop policy if exists dorm_term_read  on dorm.term;
drop policy if exists dorm_term_write on dorm.term;
create policy dorm_term_read on dorm.term for select to authenticated using (public.is_approved());
create policy dorm_term_write on dorm.term for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']))
  with check (public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']));

drop policy if exists dorm_application_read  on dorm.application;
drop policy if exists dorm_application_write on dorm.application;
create policy dorm_application_read on dorm.application for select to authenticated
  using (person_id = dorm.my_person_id()
         or public.is_admin()
         or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']));
create policy dorm_application_write on dorm.application for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']))
  with check (public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']));

-- A felvételi (ADMISSIONS) lássa, KÉR-E kollégiumot — a KIOSZTOTT SZOBÁT NE.
-- Ezért van az intent külön táblában, és ezért NEM oszlop a students-en.
drop policy if exists dorm_intent_read  on dorm.intent;
drop policy if exists dorm_intent_write on dorm.intent;
create policy dorm_intent_read on dorm.intent for select to authenticated
  using (public.is_staff()
         or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN'])
         or student_id = public.my_student_id());
create policy dorm_intent_write on dorm.intent for all to authenticated
  using (public.is_admissions() or public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']))
  with check (public.is_admissions() or public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']));

drop policy if exists dorm_contract_read  on dorm.contract;
drop policy if exists dorm_contract_write on dorm.contract;
create policy dorm_contract_read on dorm.contract for select to authenticated
  using (person_id = dorm.my_person_id()
         or public.is_admin()
         or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN'])
         or exists (select 1 from dorm.occupancy o
                     where o.contract_id = dorm.contract.id
                       and dorm.has_role('GONDNOK', o.building_id)));
create policy dorm_contract_write on dorm.contract for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']))
  with check (public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']));

drop policy if exists dorm_handover_read  on dorm.handover;
drop policy if exists dorm_handover_write on dorm.handover;
create policy dorm_handover_read on dorm.handover for select to authenticated
  using (person_id = dorm.my_person_id()
         or dorm.can_see_residents(building_id)
         or (kind in ('BUILDING_TAKEOVER','BUILDING_RETURN','JOINT_INSPECTION')
             and (public.is_admin() or dorm.has_any_role(array['INGATLAN','KOLI_SYSADMIN'], building_id))));
create policy dorm_handover_write on dorm.handover for all to authenticated
  using (dorm.can_place(building_id) or dorm.has_any_role(array['INGATLAN','KOLI_SYSADMIN'], building_id))
  with check (dorm.can_place(building_id) or dorm.has_any_role(array['INGATLAN','KOLI_SYSADMIN'], building_id));

do $sc$
declare t text;
begin
  foreach t in array array['scoring_rule','quota']
  loop
    execute format('drop policy if exists %I on dorm.%I', 'dorm_' || t || '_read',  t);
    execute format('drop policy if exists %I on dorm.%I', 'dorm_' || t || '_write', t);
    execute format(
      'create policy %I on dorm.%I for select to authenticated using (public.is_approved())',
      'dorm_' || t || '_read', t);
    execute format(
      'create policy %I on dorm.%I for all to authenticated using (public.is_admin() or dorm.has_any_role(array[''KOLI_ADMIN'',''KOLI_SYSADMIN''])) with check (public.is_admin() or dorm.has_any_role(array[''KOLI_ADMIN'',''KOLI_SYSADMIN'']))',
      'dorm_' || t || '_write', t);
  end loop;
end
$sc$;

-- --- 11.8 Üzemeltetési táblák -----------------------------------------------
-- Hibajegy: a lakó a SAJÁT szobájáéit és a sajátjait látja (így nem jelenti be
-- harmadszor ugyanazt); az üzemeltető az épület-hatókörét.
drop policy if exists dorm_issue_read    on dorm.issue;
drop policy if exists dorm_issue_insert  on dorm.issue;
drop policy if exists dorm_issue_update  on dorm.issue;
create policy dorm_issue_read on dorm.issue for select to authenticated
  using (dorm.can_see_building(building_id)
         or reporter_person = dorm.my_person_id()
         or room_id = any (dorm.my_current_room_ids()));
create policy dorm_issue_insert on dorm.issue for insert to authenticated
  with check (dorm.can_see_building(building_id)
              or room_id = any (dorm.my_current_room_ids())
              or building_id = any (dorm.my_current_building_ids()));
create policy dorm_issue_update on dorm.issue for update to authenticated
  using (dorm.has_any_role(array['GONDNOK','KARBANTARTO','KOLI_ADMIN','KOLI_SYSADMIN'], building_id) or public.is_admin())
  with check (dorm.has_any_role(array['GONDNOK','KARBANTARTO','KOLI_ADMIN','KOLI_SYSADMIN'], building_id) or public.is_admin());

drop policy if exists dorm_issue_event_read   on dorm.issue_event;
drop policy if exists dorm_issue_event_insert on dorm.issue_event;
create policy dorm_issue_event_read on dorm.issue_event for select to authenticated
  using (exists (select 1 from dorm.issue i where i.id = issue_id
                  and (dorm.can_see_building(i.building_id)
                       or i.reporter_person = dorm.my_person_id())));
create policy dorm_issue_event_insert on dorm.issue_event for insert to authenticated
  with check (exists (select 1 from dorm.issue i where i.id = issue_id
                       and (dorm.can_see_building(i.building_id)
                            or i.reporter_person = dorm.my_person_id())));

-- A bejelentő elérhetősége: a lakó dönti el, hogy megadja-e. Ha nem, a mezők
-- NEM IS TÁROLÓDNAK — a képernyőn elrejtés nem védelem: ha az adat átment a
-- dróton, kikerült.
create or replace function dorm.issue_contact_mask()
returns trigger language plpgsql
set search_path = dorm, public, extensions, pg_temp
as $$
begin
  if not coalesce(new.contact_ok, false) then
    new.reporter_name  := null;
    new.reporter_phone := null;
  end if;
  return new;
end
$$;

drop trigger if exists dorm_issue_contact_mask_trg on dorm.issue;
create trigger dorm_issue_contact_mask_trg
  before insert or update on dorm.issue
  for each row execute function dorm.issue_contact_mask();

-- Épület-hatókörös üzemeltetési táblák — egységes minta.
do $ops$
declare t text;
begin
  foreach t in array array[
    'work_cost','pm_plan','pm_run','cleaning_plan','cleaning_run',
    'inspection','inspection_item','key','asset','asset_move','meter','meter_reading']
  loop
    execute format('drop policy if exists %I on dorm.%I', 'dorm_' || t || '_read',  t);
    execute format('drop policy if exists %I on dorm.%I', 'dorm_' || t || '_write', t);
  end loop;
end
$ops$;

create policy dorm_work_cost_read on dorm.work_cost for select to authenticated
  using (dorm.can_see_building(building_id)
         or exists (select 1 from dorm.issue i where i.id = issue_id and dorm.can_see_building(i.building_id)));
create policy dorm_work_cost_write on dorm.work_cost for all to authenticated
  using (dorm.has_any_role(array['GONDNOK','KARBANTARTO','KOLI_ADMIN','KOLI_SYSADMIN','INGATLAN'], building_id) or public.is_admin())
  with check (dorm.has_any_role(array['GONDNOK','KARBANTARTO','KOLI_ADMIN','KOLI_SYSADMIN','INGATLAN'], building_id) or public.is_admin());

create policy dorm_pm_plan_read on dorm.pm_plan for select to authenticated
  using (building_id is null or dorm.can_see_building(building_id));
create policy dorm_pm_plan_write on dorm.pm_plan for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN','INGATLAN'], building_id))
  with check (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN','INGATLAN'], building_id));

create policy dorm_pm_run_read on dorm.pm_run for select to authenticated
  using (exists (select 1 from dorm.pm_plan p where p.id = plan_id
                  and (p.building_id is null or dorm.can_see_building(p.building_id))));
create policy dorm_pm_run_write on dorm.pm_run for all to authenticated
  using (exists (select 1 from dorm.pm_plan p where p.id = plan_id
                  and (public.is_admin() or dorm.has_any_role(array['GONDNOK','KARBANTARTO','KOLI_SYSADMIN','INGATLAN'], p.building_id))))
  with check (exists (select 1 from dorm.pm_plan p where p.id = plan_id
                  and (public.is_admin() or dorm.has_any_role(array['GONDNOK','KARBANTARTO','KOLI_SYSADMIN','INGATLAN'], p.building_id))));

create policy dorm_cleaning_plan_read on dorm.cleaning_plan for select to authenticated
  using (building_id is null or dorm.can_see_building(building_id));
create policy dorm_cleaning_plan_write on dorm.cleaning_plan for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN'], building_id))
  with check (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN'], building_id));

create policy dorm_cleaning_run_read on dorm.cleaning_run for select to authenticated
  using (dorm.can_see_building(building_id));
create policy dorm_cleaning_run_write on dorm.cleaning_run for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN'], building_id))
  with check (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN'], building_id));

create policy dorm_inspection_read on dorm.inspection for select to authenticated
  using (dorm.can_see_building(building_id));
create policy dorm_inspection_write on dorm.inspection for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN','INGATLAN'], building_id))
  with check (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN','INGATLAN'], building_id));

create policy dorm_inspection_item_read on dorm.inspection_item for select to authenticated
  using (exists (select 1 from dorm.inspection i where i.id = inspection_id and dorm.can_see_building(i.building_id)));
create policy dorm_inspection_item_write on dorm.inspection_item for all to authenticated
  using (exists (select 1 from dorm.inspection i where i.id = inspection_id
                  and (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN','INGATLAN'], i.building_id))))
  with check (exists (select 1 from dorm.inspection i where i.id = inspection_id
                  and (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN','INGATLAN'], i.building_id))));

-- A MESTERKULCS külön kockázat: ha elvész, az egész zárrendszert érinti.
create policy dorm_key_read on dorm.key for select to authenticated
  using (dorm.can_see_residents(building_id));
create policy dorm_key_write on dorm.key for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN'], building_id))
  with check (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN'], building_id));

create policy dorm_asset_read on dorm.asset for select to authenticated
  using (building_id is null or dorm.can_see_building(building_id));
create policy dorm_asset_write on dorm.asset for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN'], building_id))
  with check (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN'], building_id));

create policy dorm_asset_move_read on dorm.asset_move for select to authenticated
  using (exists (select 1 from dorm.asset a where a.id = asset_id
                  and (a.building_id is null or dorm.can_see_building(a.building_id))));
create policy dorm_asset_move_write on dorm.asset_move for all to authenticated
  using (exists (select 1 from dorm.asset a where a.id = asset_id
                  and (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN'], a.building_id))))
  with check (exists (select 1 from dorm.asset a where a.id = asset_id
                  and (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_SYSADMIN'], a.building_id))));

create policy dorm_meter_read on dorm.meter for select to authenticated
  using (dorm.can_see_building(building_id));
create policy dorm_meter_write on dorm.meter for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['GONDNOK','INGATLAN','KOLI_SYSADMIN'], building_id))
  with check (public.is_admin() or dorm.has_any_role(array['GONDNOK','INGATLAN','KOLI_SYSADMIN'], building_id));

create policy dorm_meter_reading_read on dorm.meter_reading for select to authenticated
  using (exists (select 1 from dorm.meter m where m.id = meter_id and dorm.can_see_building(m.building_id)));
create policy dorm_meter_reading_write on dorm.meter_reading for all to authenticated
  using (exists (select 1 from dorm.meter m where m.id = meter_id
                  and (public.is_admin() or dorm.has_any_role(array['GONDNOK','INGATLAN','KOLI_SYSADMIN'], m.building_id))))
  with check (exists (select 1 from dorm.meter m where m.id = meter_id
                  and (public.is_admin() or dorm.has_any_role(array['GONDNOK','INGATLAN','KOLI_SYSADMIN'], m.building_id))));

-- Kulcskiadás: SZEMÉLYES adat (ki jár be hova) — a can_see_residents kör.
drop policy if exists dorm_key_issue_read  on dorm.key_issue;
drop policy if exists dorm_key_issue_write on dorm.key_issue;
create policy dorm_key_issue_read on dorm.key_issue for select to authenticated
  using (person_id = dorm.my_person_id()
         or exists (select 1 from dorm.key k where k.id = key_id and dorm.can_see_residents(k.building_id)));
create policy dorm_key_issue_write on dorm.key_issue for all to authenticated
  using (exists (select 1 from dorm.key k where k.id = key_id
                  and (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], k.building_id))))
  with check (exists (select 1 from dorm.key k where k.id = key_id
                  and (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], k.building_id))));

-- --- 11.9 Kárügy és pénzügy -------------------------------------------------
-- A FINANCE a díjtételt és az időszakot lássa, a SZOBA SZÁMÁT NE — a
-- számlázáshoz nincs rá szükség. Ezért a dorm.charge-ban nincs szoba-mező,
-- csak building_id (a fajlagos riporthoz), és a lakói név is csak a
-- person_id-n át, RLS mögül érhető el.
drop policy if exists dorm_damage_read  on dorm.damage;
drop policy if exists dorm_damage_write on dorm.damage;
create policy dorm_damage_read on dorm.damage for select to authenticated
  using (person_id = dorm.my_person_id() or dorm.can_see_residents(building_id));
create policy dorm_damage_write on dorm.damage for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], building_id))
  with check (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], building_id));

drop policy if exists dorm_charge_read  on dorm.charge;
drop policy if exists dorm_charge_write on dorm.charge;
create policy dorm_charge_read on dorm.charge for select to authenticated
  using (person_id = dorm.my_person_id()
         or public.is_finance() or public.is_admin()
         or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']));
create policy dorm_charge_write on dorm.charge for all to authenticated
  using (public.is_finance() or public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']))
  with check (public.is_finance() or public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']));

drop policy if exists dorm_deposit_read  on dorm.deposit;
drop policy if exists dorm_deposit_write on dorm.deposit;
create policy dorm_deposit_read on dorm.deposit for select to authenticated
  using ((direction = 'HELD_FROM_RESIDENT' and person_id = dorm.my_person_id())
         or public.is_finance() or public.is_admin()
         or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN'])
         or (direction = 'PAID_TO_LANDLORD' and dorm.has_role('INGATLAN', building_id)));
create policy dorm_deposit_write on dorm.deposit for all to authenticated
  using (public.is_finance() or public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN','INGATLAN']))
  with check (public.is_finance() or public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN','INGATLAN']));

drop policy if exists dorm_discount_read  on dorm.discount;
drop policy if exists dorm_discount_write on dorm.discount;
create policy dorm_discount_read on dorm.discount for select to authenticated
  using (person_id = dorm.my_person_id()
         or public.is_finance() or public.is_admin()
         or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']));
create policy dorm_discount_write on dorm.discount for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']))
  with check (public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']));

drop policy if exists dorm_utility_bill_read  on dorm.utility_bill;
drop policy if exists dorm_utility_bill_write on dorm.utility_bill;
create policy dorm_utility_bill_read on dorm.utility_bill for select to authenticated
  using (public.is_finance() or public.is_admin()
         or dorm.has_any_role(array['INGATLAN','KOLI_ADMIN','KOLI_SYSADMIN','GONDNOK'], building_id));
create policy dorm_utility_bill_write on dorm.utility_bill for all to authenticated
  using (public.is_admin() or dorm.has_any_role(array['INGATLAN','KOLI_SYSADMIN'], building_id))
  with check (public.is_admin() or dorm.has_any_role(array['INGATLAN','KOLI_SYSADMIN'], building_id));

-- --- 11.10 Hozzáférési napló ------------------------------------------------
-- A naplót CSAK az intézményi kör olvashatja, és SENKI nem írhatja közvetlenül
-- (kizárólag a dorm.log_access() definer-függvényen át) — különben a napló
-- meghamisítható lenne.
drop policy if exists dorm_access_log_read on dorm.access_log;
create policy dorm_access_log_read on dorm.access_log for select to authenticated
  using (public.is_admin() or dorm.has_role('KOLI_SYSADMIN'));

-- --- 11.11 Táblaszintű grantok ---------------------------------------------
revoke all on all tables in schema dorm from anon;
grant select on all tables in schema dorm to authenticated;

do $g$
declare t text;
begin
  foreach t in array array[
    'role_grant','site','landlord','building','floor','room','bed','lease','responsibility',
    'person','term','intent','application','scoring_rule','quota','contract','occupancy','handover',
    'issue','issue_event','work_cost','pm_plan','pm_run','cleaning_plan','cleaning_run',
    'inspection','inspection_item','key','key_issue','asset','asset_move','damage',
    'fee_schedule','charge','deposit','discount','meter','meter_reading','utility_bill',
    'tenure','room_type','room_status','room_status_transition','bed_status','fault_category',
    'issue_status','issue_status_transition','application_status','application_transition']
  loop
    execute format('grant insert, update, delete on dorm.%I to authenticated', t);
  end loop;
end
$g$;

-- A napló és a státusztörténet CSAK olvasható kívülről; írni a definer
-- függvények és triggerek írnak.
revoke insert, update, delete on dorm.access_log          from authenticated;
revoke insert, update, delete on dorm.room_status_history from authenticated;
revoke insert, update, delete on dorm.bed_status_history  from authenticated;

grant usage, select on all sequences in schema dorm to authenticated;
revoke all on all sequences in schema dorm from anon;

grant select on dorm.v_room_operational, dorm.v_room_occupancy, dorm.v_building_capacity to authenticated;
revoke all  on dorm.v_room_operational, dorm.v_room_occupancy, dorm.v_building_capacity from anon;


-- ============================================================================
-- 12. SZAKASZ — PUBLIC RPC-K a majdani felülethez
-- ============================================================================
-- Miért a public sémában: az app.jsx `sb.rpc('nev')` hívása a public sémára
-- megy — ez a 31 echo_* RPC bevált útja, és nem kíván kliens-oldali
-- séma-kapcsolgatást. A modul TÁBLÁI viszont közvetlenül is olvashatók a
-- kitett dorm sémából, RLS mögül (3. szerkezeti döntés) — ezek az RPC-k tehát
-- KÉNYELMI és AGGREGÁLÓ függvények, nem az egyetlen út befelé.
--
-- MINDEN RPC SECURITY DEFINER, ezért MINDEGYIK ELVÉGZI A SAJÁT
-- JOGOSULTSÁGVIZSGÁLATÁT — a definer megkerüli az RLS-t, tehát a kaput itt
-- kell megépíteni, nem másutt.

create sequence if not exists dorm.issue_no_seq;

create or replace function dorm.compute_priority(p_base text, p_impact text)
returns text language sql immutable
as $$
  select case
    when p_impact = 'SAFETY'      then 'P1'
    when p_impact = 'BUILDING'    then 'P1'
    when p_impact = 'MULTI_ROOM'  then least(p_base, 'P2')
    when p_impact = 'ROOM_UNUSABLE' then least(p_base, 'P2')
    else p_base
  end
$$;

comment on function dorm.compute_priority(text, text) is
  'A prioritás SZÁMÍTOTT, nem választott: kategória x hatás. A lakó jelezhet sürgősséget (urgency_flag), de a prioritást nem ő állítja.';


-- --- 12.1 dorm_my_roles() — a menüszűréshez ---------------------------------
create or replace function public.dorm_my_roles()
returns jsonb
language sql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
  select jsonb_build_object(
    'szerepkorok', coalesce((
       select jsonb_agg(distinct g.role)
         from dorm.role_grant g
        where g.person = auth.uid()
          and (g.expires_at is null or g.expires_at > now())
          and public.is_approved()), '[]'::jsonb),
    'epuletek', coalesce((
       select jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'name', b.name, 'tenure', b.tenure)
                        order by b.code)
         from dorm.building b
        where b.id = any (dorm.my_building_ids())), '[]'::jsonb),
    'intezmenyi', exists (select 1 from dorm.role_grant g
                           where g.person = auth.uid() and g.scope_building is null
                             and (g.expires_at is null or g.expires_at > now()))
                  and public.is_approved(),
    'lakó', dorm.my_person_id() is not null
  )
$$;


-- --- 12.2 dorm_my_placement() — a lakó SAJÁT elhelyezése --------------------
-- A lakó a sajátját mindig látja; máséhoz semmilyen paraméterrel nem fér hozzá,
-- mert a függvény nem is fogad személy-paramétert.
create or replace function public.dorm_my_placement()
returns jsonb
language plpgsql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare v_person uuid; v_res jsonb;
begin
  if not public.is_approved() then
    raise exception 'DORM_FORBIDDEN: jovahagyott fiok szukseges.';
  end if;
  v_person := dorm.my_person_id();
  if v_person is null then
    return jsonb_build_object('lako', false, 'elhelyezesek', '[]'::jsonb);
  end if;

  select jsonb_build_object(
    'lako', true,
    'person_id', v_person,
    'elhelyezesek', coalesce(jsonb_agg(x order by x->>'tol' desc), '[]'::jsonb))
    into v_res
  from (
    select jsonb_build_object(
      'occupancy_id', o.id,
      'epulet',   b.name,
      'epulet_kod', b.code,
      'jogcim',   b.tenure,
      'szint',    f.level_no,
      'szoba',    r.full_code,
      'ajto',     r.door_number,
      'ferohely', bd.full_code,
      'tol',      lower(o.period),
      'ig',       upper(o.period),
      'allapot',  o.state,
      'szerzodes', c.iktatoszam,
      'nyitott_hibak', (select count(*) from dorm.issue i
                          where i.room_id = r.id
                            and i.status in (select code from dorm.issue_status where is_open))
    ) as x
    from dorm.occupancy o
    join dorm.bed bd     on bd.id = o.bed_id
    join dorm.room r     on r.id = bd.room_id
    join dorm.floor f    on f.id = r.floor_id
    join dorm.building b on b.id = r.building_id
    left join dorm.contract c on c.id = o.contract_id
   where o.person_id = v_person
     and o.state <> 'CANCELLED'
  ) s;

  perform dorm.log_access('MY_PLACEMENT', 'occupancy', v_person::text, null, 'sajat', 1, false);
  return v_res;
end
$$;


-- --- 12.3 dorm_occupancy_summary() — KIHASZNÁLTSÁG --------------------------
-- Mind a HÁROM kapacitásfogalmat visszaadja, mert a fenntartó a nyilvántartott,
-- az üzemeltetés a kiadható számot ismeri, és a kettő különbsége az, amit
-- magyarázni kell. A kihasználtság NEVEZŐJE a KIADHATÓ férőhely.
create or replace function public.dorm_occupancy_summary(
  p_building uuid default null,
  p_on       date default current_date)
returns table (
  building_id      uuid,
  building_code    text,
  building_name    text,
  tenure           text,
  tenure_label     text,
  is_owned         boolean,
  landlord_name    text,
  rooms_total      bigint,
  beds_registered  bigint,
  beds_operable    bigint,
  beds_lettable    bigint,
  beds_occupied    bigint,
  beds_free        bigint,
  occupancy_pct    numeric,
  open_issues      bigint,
  overdue_issues   bigint
)
language plpgsql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
begin
  if not public.is_approved() then
    raise exception 'DORM_FORBIDDEN: jovahagyott fiok szukseges.';
  end if;
  -- Konkrét épületre kérdezve BESZÉDES hibát adunk, nem üres eredményt: az
  -- üres tábla és a "nincs jogod" két különböző dolog, és az üzemeltető
  -- órákig keresné a hibát a rossz helyen.
  if p_building is not null and not (public.is_admin() or dorm.can_see_building(p_building)) then
    raise exception 'DORM_FORBIDDEN: ez az epulet nincs a hatokoreben.';
  end if;

  perform dorm.log_access('OCCUPANCY_SUMMARY', 'building', p_building::text, p_building,
                          'nap=' || p_on::text, null, false);

  return query
  with scope as (
    select b.id, b.code, b.name, b.tenure, t.label_hu as tlabel, t.is_owned, l.name as landlord
      from dorm.building b
      join dorm.tenure t on t.code = b.tenure
      left join dorm.landlord l on l.id = b.landlord_id
     where b.is_active
       and (p_building is null or b.id = p_building)
       and (public.is_admin() or b.id = any (dorm.my_building_ids()))
  ),
  cap as (
    select r.building_id,
           count(distinct r.id)                                        as rooms_total,
           count(bd.id)                                                as registered,
           count(bd.id) filter (where bs.is_operable and rs.is_operable) as operable,
           count(bd.id) filter (where bs.is_operable and rs.is_operable
                                  and bs.is_lettable and rs.is_lettable) as lettable
      from dorm.room r
      join dorm.room_status rs on rs.code = r.status
      left join dorm.bed bd    on bd.room_id = r.id
      left join dorm.bed_status bs on bs.code = bd.status
     where r.purpose = 'RESIDENTIAL'
     group by r.building_id
  ),
  occ as (
    select o.building_id, count(*) as occupied
      from dorm.occupancy o
     where o.state in ('ALLOCATED','MOVED_IN')
       and o.period @> p_on
     group by o.building_id
  ),
  iss as (
    select i.building_id,
           count(*) filter (where st.is_open)                                        as open_cnt,
           count(*) filter (where st.is_open and i.due_at is not null and i.due_at < now()) as overdue_cnt
      from dorm.issue i
      join dorm.issue_status st on st.code = i.status
     group by i.building_id
  )
  select s.id, s.code, s.name, s.tenure, s.tlabel, s.is_owned, s.landlord,
         coalesce(c.rooms_total, 0),
         coalesce(c.registered, 0),
         coalesce(c.operable, 0),
         coalesce(c.lettable, 0),
         coalesce(o.occupied, 0),
         greatest(coalesce(c.lettable, 0) - coalesce(o.occupied, 0), 0),
         case when coalesce(c.lettable, 0) = 0 then null
              else round(100.0 * coalesce(o.occupied, 0) / c.lettable, 1) end,
         coalesce(i.open_cnt, 0),
         coalesce(i.overdue_cnt, 0)
    from scope s
    left join cap c on c.building_id = s.id
    left join occ o on o.building_id = s.id
    left join iss i on i.building_id = s.id
   order by s.code;
end
$$;


-- --- 12.4 dorm_free_beds() — SZABAD HELYEK, LISTAKÉNT -----------------------
-- "Hova tudok most beköltöztetni?" A gondnok a LISTÁT tudja használni, a
-- százalékot nem. Bármely JÖVŐBENI időszakra is működik, mert a foglalás
-- daterange — ez teszi lehetővé, hogy a februári kiosztást novemberben
-- elkezdjük tervezni, pontosan annyi helyre, amennyi valóban felszabadul.
create or replace function public.dorm_free_beds(
  p_from     date default current_date,
  p_to       date default null,
  p_building uuid default null,
  p_accessible_only boolean default false,
  p_gender   text default null,
  p_limit    integer default 200)
returns table (
  building_code text,
  building_name text,
  tenure        text,
  level_no      integer,
  room_code     text,
  room_type     text,
  bed_code      text,
  bed_id        uuid,
  is_accessible boolean,
  gender_restriction text,
  free_from     date,
  free_to       date
)
language plpgsql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare v_period daterange; v_rows integer;
begin
  if not public.is_approved() then
    raise exception 'DORM_FORBIDDEN: jovahagyott fiok szukseges.';
  end if;
  if not (public.is_admin() or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], p_building)) then
    raise exception 'DORM_FORBIDDEN: a szabad helyek listaja GONDNOK / KOLI_ADMIN / KOLI_SYSADMIN jogosultsagot igenyel.';
  end if;

  v_period := daterange(p_from, coalesce(p_to, p_from + 1), '[)');

  return query
  select b.code, b.name, b.tenure, f.level_no, r.full_code, r.room_type,
         bd.full_code, bd.id, r.is_accessible, r.gender_restriction,
         p_from, coalesce(p_to, p_from + 1)
    from dorm.bed bd
    join dorm.bed_status  bs on bs.code = bd.status
    join dorm.room r        on r.id = bd.room_id
    join dorm.room_status rs on rs.code = r.status
    join dorm.floor f       on f.id = r.floor_id
    join dorm.building b    on b.id = r.building_id
   where b.is_active
     and r.purpose = 'RESIDENTIAL'
     and bs.is_operable and bs.is_lettable
     and rs.is_operable and rs.is_lettable and rs.is_issuable
     and (p_building is null or b.id = p_building)
     and (public.is_admin() or b.id = any (dorm.my_building_ids()))
     and (not p_accessible_only or r.is_accessible)
     and (p_gender is null or r.gender_restriction in ('ANY', p_gender))
     and not exists (
           select 1 from dorm.occupancy o
            where o.bed_id = bd.id
              and o.state <> 'CANCELLED'
              and o.period && v_period)
   order by b.code, f.level_no, r.full_code, bd.full_code
   limit greatest(p_limit, 1);

  get diagnostics v_rows = row_count;
  perform dorm.log_access('FREE_BEDS', 'bed', null, p_building,
                          'idoszak=' || v_period::text, v_rows, false);
end
$$;


-- --- 12.5 dorm_open_issues() — NYITOTT HIBÁK korosítással -------------------
-- "Mi ragadt be?" — napi diszpécser-lista. A lakó NEVE nem szerepel benne:
-- a karbantartónak a szoba kell, nem a lakó.
create or replace function public.dorm_open_issues(
  p_building uuid default null,
  p_only_overdue boolean default false,
  p_limit    integer default 200)
returns table (
  ticket_no     text,
  building_code text,
  tenure        text,
  room_code     text,
  category      text,
  category_label text,
  title         text,
  priority      text,
  status        text,
  status_label  text,
  liable_party  text,
  route         text,
  contract_clause text,
  created_at    timestamptz,
  due_at        timestamptz,
  age_hours     numeric,
  is_overdue    boolean,
  age_bucket    text
)
language plpgsql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare v_rows integer;
begin
  if not public.is_approved() then
    raise exception 'DORM_FORBIDDEN: jovahagyott fiok szukseges.';
  end if;
  if not (public.is_admin()
          or dorm.has_any_role(array['GONDNOK','KARBANTARTO','KOLI_ADMIN','KOLI_SYSADMIN','INGATLAN'], p_building)) then
    raise exception 'DORM_FORBIDDEN: uzemeltetoi jogosultsag szukseges.';
  end if;

  return query
  select i.ticket_no, b.code, b.tenure, r.full_code,
         i.category_code, fc.label_hu, i.title, i.priority, i.status, st.label_hu,
         coalesce(i.liable_party_final, i.liable_party_initial), i.route, i.contract_clause,
         i.created_at, i.due_at,
         round(extract(epoch from (now() - i.created_at)) / 3600.0, 1),
         (i.due_at is not null and i.due_at < now()),
         case
           when now() - i.created_at <  interval '24 hours' then '<24 ora'
           when now() - i.created_at <  interval '3 days'   then '1-3 nap'
           when now() - i.created_at <  interval '7 days'   then '4-7 nap'
           when now() - i.created_at <  interval '30 days'  then '8-30 nap'
           else '30+ nap'
         end
    from dorm.issue i
    join dorm.issue_status st on st.code = i.status
    join dorm.building b on b.id = i.building_id
    join dorm.fault_category fc on fc.code = i.category_code
    left join dorm.room r on r.id = i.room_id
   where st.is_open
     and (p_building is null or i.building_id = p_building)
     and (public.is_admin() or i.building_id = any (dorm.my_building_ids()))
     and (not p_only_overdue or (i.due_at is not null and i.due_at < now()))
   order by i.priority, i.created_at
   limit greatest(p_limit, 1);

  get diagnostics v_rows = row_count;
  perform dorm.log_access('OPEN_ISSUES', 'issue', null, p_building, null, v_rows, false);
end
$$;


-- --- 12.6 dorm_issue_report() — HIBABEJELENTÉS rögzítése --------------------
-- Ez a modul napi haszna: a bejelentés pillanatában a rendszer feloldja a
-- felelősségi mátrixot, és megmondja, KIHEZ megy, MI A HATÁRIDŐ és MELYIK
-- SZERZŐDÉSPONT alapján. Az ügyintézőnek nem kell a bérleti szerződést
-- előkeresnie és elolvasnia.
create or replace function public.dorm_issue_report(
  p_category    text,
  p_title       text,
  p_description text default null,
  p_room        uuid default null,
  p_bed_qr      text default null,
  p_building    uuid default null,
  p_impact      text default 'NONE',
  p_urgent      boolean default false,
  p_contact_ok  boolean default false,
  p_contact_name  text default null,
  p_contact_phone text default null,
  p_entry_permitted boolean default false,
  p_photos      jsonb default null)
returns jsonb
language plpgsql security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare
  v_building uuid; v_room uuid; v_bed uuid;
  v_person uuid; v_resp record; v_cat record;
  v_priority text; v_no text; v_id bigint; v_due timestamptz; v_esc timestamptz;
  v_chronic boolean := false;
begin
  if not public.is_approved() then
    raise exception 'DORM_FORBIDDEN: jovahagyott fiok szukseges.';
  end if;

  select * into v_cat from dorm.fault_category where code = p_category;
  if v_cat is null then
    raise exception 'DORM_CATEGORY_UNKNOWN: nincs ilyen hibakategoria: %', p_category
      using hint = 'select code, label_hu from dorm.fault_category order by sort_order';
  end if;

  -- A helyszín feloldása: QR-kód > szoba > épület. A QR a legpontosabb, és a
  -- legkevesebb hibalehetőséggel jár ("3. emeleti valamelyik fürdőben csöpög").
  if p_bed_qr is not null then
    select bd.id, bd.room_id, bd.building_id into v_bed, v_room, v_building
      from dorm.bed bd where bd.qr_token = p_bed_qr;
    if v_bed is null then
      raise exception 'DORM_QR_UNKNOWN: ismeretlen ferohely-azonosito.';
    end if;
  elsif p_room is not null then
    select r.id, r.building_id into v_room, v_building from dorm.room r where r.id = p_room;
    if v_room is null then
      raise exception 'DORM_ROOM_UNKNOWN: nincs ilyen szoba.';
    end if;
  elsif p_building is not null then
    v_building := p_building;
  else
    raise exception 'DORM_LOCATION_REQUIRED: szoba, ferohely-QR vagy epulet megadasa kotelezo.';
  end if;

  v_person := dorm.my_person_id();

  -- Jogosultság: vagy üzemeltető az adott épületben, vagy ott lakik.
  if not (dorm.can_see_building(v_building)
          or v_building = any (dorm.my_current_building_ids())) then
    raise exception 'DORM_FORBIDDEN: nincs jogosultsaga bejelenteni ebben az epuletben.';
  end if;

  select * into v_resp from dorm.resolve_responsibility(v_building, p_category);
  v_priority := dorm.compute_priority(v_cat.base_priority, coalesce(p_impact, 'NONE'));

  if v_resp.sla_hours is not null then
    v_due := now() + make_interval(hours => v_resp.sla_hours);
  end if;
  if v_resp.escalation_hours is not null then
    v_esc := now() + make_interval(hours => v_resp.escalation_hours);
  end if;

  -- ISMÉTLŐDÉS-DETEKTÁLÁS: ugyanaz a szoba + kategória 90 napon belül 3. jegy.
  if v_room is not null then
    select count(*) >= 2 into v_chronic
      from dorm.issue i
     where i.room_id = v_room and i.category_code = p_category
       and i.created_at > now() - interval '90 days';
  end if;

  v_no := 'HIB-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('dorm.issue_no_seq')::text, 6, '0');

  insert into dorm.issue (
    ticket_no, building_id, room_id, bed_id, category_code, title, description, photos,
    reporter_person, reporter_profile, reporter_name, reporter_phone, contact_ok,
    entry_permitted, impact, urgency_flag, priority,
    liable_party_initial, route, cost_bearer, contract_clause, responsibility_source,
    substitute_repair, needs_triage, status, due_at, escalate_at, is_chronic, source)
  values (
    v_no, v_building, v_room, v_bed, p_category, p_title, p_description, p_photos,
    v_person, auth.uid(), p_contact_name, p_contact_phone, coalesce(p_contact_ok, false),
    coalesce(p_entry_permitted, false), coalesce(p_impact, 'NONE'), coalesce(p_urgent, false), v_priority,
    v_resp.liable_party, v_resp.route, v_resp.cost_bearer, v_resp.contract_clause, v_resp.source,
    coalesce(v_resp.substitute_repair_allowed, false), v_cat.needs_triage,
    case when v_cat.needs_triage then 'NEW' else 'NEW' end, v_due, v_esc, v_chronic,
    case when dorm.has_any_role(array['GONDNOK','KOLI_ADMIN'], v_building) then 'HOUSE_MANAGER'
         when dorm.has_role('KARBANTARTO', v_building) then 'MAINTENANCE'
         else 'RESIDENT' end)
  returning id into v_id;

  insert into dorm.issue_event (issue_id, actor, event_kind, to_status, body)
  values (v_id, auth.uid(), 'STATUS', 'NEW', 'Bejelentés rögzítve');

  perform public.log_status_event('DORM_ISSUE_CREATED', 'dorm.issue',
    v_no || ' / ' || p_category || ' / ' || v_priority || ' / felelos=' || coalesce(v_resp.liable_party, '?'));

  return jsonb_build_object(
    'ok', true,
    'ticket_no', v_no,
    'issue_id', v_id,
    'prioritas', v_priority,
    'felelos', v_resp.liable_party,
    'utvonal', v_resp.route,
    'koltsegviselo', v_resp.cost_bearer,
    'hatarido', v_due,
    'eszkalacio', v_esc,
    'szerzodespont', v_resp.contract_clause,
    'matrix_szint', v_resp.source,
    'megallapitas_szukseges', v_cat.needs_triage,
    'kronikus', v_chronic,
    'kapcsolat', case when coalesce(p_contact_ok, false) then 'megadva' else 'nem jarult hozza' end);
end
$$;


-- --- 12.7 dorm_assign() — HELYKIOSZTÁS --------------------------------------
-- A javaslat SOHA nem ír automatikusan: a döntés emberi, a rendszer előkészít.
-- Az átfedést nem ez a függvény ellenőrzi, hanem az EXCLUDE constraint — a
-- függvény csak lefordítja a hibát beszédes üzenetre. Így párhuzamos hívásnál
-- sem lehet duplán kiadni egy helyet.
create or replace function public.dorm_assign(
  p_person   uuid,
  p_bed      uuid,
  p_from     date,
  p_to       date default null,
  p_contract uuid default null,
  p_term     uuid default null,
  p_mode     text default 'MANUAL',
  p_note     text default null)
returns jsonb
language plpgsql security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare
  v_building uuid; v_room uuid; v_id uuid; v_period daterange;
  v_bedcode text; v_roomcode text; v_bldcode text; v_name text;
  v_bed_status text; v_room_status text;
begin
  if not public.is_approved() then
    raise exception 'DORM_FORBIDDEN: jovahagyott fiok szukseges.';
  end if;

  select bd.building_id, bd.room_id, bd.full_code, bd.status, r.full_code, r.status, b.code
    into v_building, v_room, v_bedcode, v_bed_status, v_roomcode, v_room_status, v_bldcode
    from dorm.bed bd
    join dorm.room r on r.id = bd.room_id
    join dorm.building b on b.id = bd.building_id
   where bd.id = p_bed;

  if v_building is null then
    raise exception 'DORM_BED_UNKNOWN: nincs ilyen ferohely.';
  end if;
  if not dorm.can_place(v_building) then
    raise exception 'DORM_FORBIDDEN: helykiosztashoz GONDNOK (sajat epulet), KOLI_ADMIN vagy KOLI_SYSADMIN jogosultsag kell.';
  end if;

  select display_name into v_name from dorm.person where id = p_person;
  if v_name is null then
    raise exception 'DORM_PERSON_UNKNOWN: nincs ilyen lako.';
  end if;

  if not exists (select 1 from dorm.bed_status s where s.code = v_bed_status and s.is_operable and s.is_lettable) then
    raise exception 'DORM_BED_NOT_LETTABLE: a ferohely allapota "%" — nem kiadhato.', v_bed_status;
  end if;
  if not exists (select 1 from dorm.room_status s where s.code = v_room_status and s.is_operable) then
    raise exception 'DORM_ROOM_NOT_OPERABLE: a szoba allapota "%" — nem uzemkepes.', v_room_status;
  end if;

  v_period := daterange(p_from, p_to, '[)');
  if isempty(v_period) then
    raise exception 'DORM_PERIOD_EMPTY: ures idoszak (%, %).', p_from, p_to;
  end if;

  begin
    insert into dorm.occupancy (building_id, bed_id, person_id, contract_id, term_id,
                                period, state, assigned_by, assignment_mode, note)
    values (v_building, p_bed, p_person, p_contract, p_term,
            v_period, 'ALLOCATED', auth.uid(), coalesce(p_mode, 'MANUAL'), p_note)
    returning id into v_id;
  exception when exclusion_violation then
    raise exception
      'DORM_BED_TAKEN: a(z) % ferohely a kert idoszakban (%) mar foglalt.', v_bedcode, v_period
      using hint = 'Szabad helyek: select * from public.dorm_free_beds(' || quote_literal(p_from) || '::date, '
                   || coalesce(quote_literal(p_to) || '::date', 'null') || ');';
  end;

  -- A szoba állapotgépe: available -> allocated (csak ha értelmes az átmenet).
  if v_room_status = 'available' then
    update dorm.room set status = 'allocated' where id = v_room;
  end if;

  perform dorm.log_access('ASSIGN', 'occupancy', v_id::text, v_building,
                          v_bldcode || '/' || v_roomcode || '/' || v_bedcode, 1, false);
  perform public.log_status_event('DORM_ASSIGN', 'dorm.occupancy',
    v_name || ' -> ' || v_bldcode || ' ' || v_roomcode || ' (' || v_bedcode || ') ' || v_period::text);

  return jsonb_build_object('ok', true, 'occupancy_id', v_id, 'epulet', v_bldcode,
                            'szoba', v_roomcode, 'ferohely', v_bedcode, 'idoszak', v_period::text);
end
$$;


-- --- 12.8 dorm_person_link() — a lakói sor és a UniPortal-fiók kötése -------
-- Az ECHO echo_teacher_link() mintája. A részleges UNIQUE indexek ütközését
-- BESZÉDES hibává fordítjuk.
create or replace function public.dorm_person_link(
  p_person  uuid,
  p_student text default null,
  p_profile uuid default null)
returns jsonb
language plpgsql security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare v_name text;
begin
  if not dorm.can_grant() and not dorm.has_any_role(array['KOLI_ADMIN']) then
    raise exception 'DORM_FORBIDDEN: a kotest KOLI_ADMIN / KOLI_SYSADMIN / admin vegezheti.';
  end if;
  select display_name into v_name from dorm.person where id = p_person;
  if v_name is null then raise exception 'DORM_PERSON_UNKNOWN: nincs ilyen lako.'; end if;

  if p_student is not null and exists (
       select 1 from dorm.person where student_id = p_student and id <> p_person) then
    raise exception 'DORM_STUDENT_TAKEN: a(z) % jelentkezoi azonosito mar egy masik lakohoz van kotve.', p_student;
  end if;
  if p_profile is not null and exists (
       select 1 from dorm.person where profile_id = p_profile and id <> p_person) then
    raise exception 'DORM_PROFILE_TAKEN: ez a fiok mar egy masik lakohoz van kotve.';
  end if;

  update dorm.person
     set student_id = coalesce(p_student, student_id),
         profile_id = coalesce(p_profile, profile_id)
   where id = p_person;

  perform public.log_status_event('DORM_PERSON_LINK', 'dorm.person',
    v_name || ' <- student=' || coalesce(p_student, '-') || ' profile=' || coalesce(p_profile::text, '-'));
  return jsonb_build_object('ok', true, 'person_id', p_person);
end
$$;

-- Javaslatlista, NEM automatikus írás. A 14-es migráció logikája, de EMBERI
-- jóváhagyással: éles adaton az e-mail-egyezés 100%-osnak látszik, de nincs
-- kikényszerítve (a students táblán NINCS UNIQUE index az e-mailen — mérve),
-- és egy vak automata ROSSZ EMBERT költöztetne be.
create or replace function public.dorm_person_link_suggestions()
returns table (person_id uuid, display_name text, email text,
               suggested_student text, suggested_profile uuid, confidence text)
language plpgsql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
begin
  if not dorm.can_grant() and not dorm.has_any_role(array['KOLI_ADMIN']) then
    raise exception 'DORM_FORBIDDEN: KOLI_ADMIN / KOLI_SYSADMIN / admin jogosultsag kell.';
  end if;
  return query
  select p.id, p.display_name, p.email,
         (select s.id from public.students s where lower(s.email) = lower(p.email)
           group by s.id having count(*) = 1 limit 1),
         (select pr.id from public.profiles pr where lower(pr.email) = lower(p.email) limit 1),
         case when (select count(*) from public.students s where lower(s.email) = lower(p.email)) = 1
              then 'EGYERTELMU' else 'TOBBSZOROS_VAGY_NINCS' end
    from dorm.person p
   where p.email is not null
     and (p.student_id is null or p.profile_id is null);
end
$$;


-- --- 12.9 dorm_role_grant() — grant kiosztása és visszavonása ---------------
create or replace function public.dorm_role_grant(
  p_email      text,
  p_role       text,
  p_building   uuid default null,
  p_expires_at timestamptz default null,
  p_iktatoszam text default null,
  p_revoke     boolean default false)
returns jsonb
language plpgsql security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare v_person uuid; v_id uuid;
begin
  if not dorm.can_grant() then
    raise exception 'DORM_FORBIDDEN: grantot admin vagy KOLI_SYSADMIN oszthat.';
  end if;
  select id into v_person from public.profiles where lower(email) = lower(btrim(p_email)) limit 1;
  if v_person is null then
    raise exception 'DORM_PROFILE_NOT_FOUND: nincs ilyen e-mailu fiok: %', p_email;
  end if;

  if p_revoke then
    update dorm.role_grant
       set expires_at = now()
     where person = v_person and role = p_role
       and coalesce(scope_building, '00000000-0000-0000-0000-000000000000'::uuid)
           = coalesce(p_building, '00000000-0000-0000-0000-000000000000'::uuid)
       and (expires_at is null or expires_at > now());
    perform public.log_status_event('DORM_ROLE_REVOKE', 'dorm.role_grant', p_email || ' / ' || p_role);
    return jsonb_build_object('ok', true, 'muvelet', 'visszavonva');
  end if;

  insert into dorm.role_grant (person, role, scope_building, granted_by, expires_at, iktatoszam)
  values (v_person, p_role, p_building, auth.uid(), p_expires_at, p_iktatoszam)
  on conflict do nothing
  returning id into v_id;

  if v_id is null then
    update dorm.role_grant
       set expires_at = p_expires_at, granted_by = auth.uid(),
           granted_at = now(), iktatoszam = coalesce(p_iktatoszam, iktatoszam)
     where person = v_person and role = p_role
       and coalesce(scope_building, '00000000-0000-0000-0000-000000000000'::uuid)
           = coalesce(p_building, '00000000-0000-0000-0000-000000000000'::uuid)
     returning id into v_id;
  end if;

  perform public.log_status_event('DORM_ROLE_GRANT', 'dorm.role_grant',
    p_email || ' / ' || p_role || ' / ' || coalesce(p_building::text, 'intezmenyi'));
  return jsonb_build_object('ok', true, 'grant_id', v_id, 'muvelet', 'kiosztva');
end
$$;


-- --- 12.10 Ütemezett feladatok IDEMPOTENS RPC-ként --------------------------
-- A helyi replikán NINCS pg_cron (mérve) — ezért ezek sima RPC-k, amiket
-- ütemező, felületi gomb és külső cron EGYARÁNT hívhat, és a többszöri
-- lefutás sem okoz kárt.
create or replace function public.dorm_expire_offers()
returns integer language plpgsql security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare v_rows integer;
begin
  if not (public.is_admin() or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN'])) then
    raise exception 'DORM_FORBIDDEN: KOLI_ADMIN / KOLI_SYSADMIN jogosultsag kell.';
  end if;
  update dorm.application
     set status = 'Expired'
   where status = 'Offered'
     and offer_expires_at is not null
     and offer_expires_at < now();
  get diagnostics v_rows = row_count;
  if v_rows > 0 then
    perform public.log_status_event('DORM_OFFERS_EXPIRED', 'dorm.application', v_rows || ' ajanlat lejart');
  end if;
  return v_rows;
end
$$;

-- A LEJÁRÓ BÉRLETEK — a DÖNTÉSI dátum szerint, nem a lejárat szerint.
create or replace function public.dorm_lease_alerts(p_days integer default 180)
returns table (
  building_code text, building_name text, landlord_name text,
  iktatoszam text, ends_on date, notice_months integer,
  decision_due_on date, days_left integer, auto_renew boolean, monthly_rent numeric)
language plpgsql stable security definer
set search_path = dorm, public, extensions, pg_temp
as $$
begin
  if not (public.is_admin() or dorm.has_any_role(array['INGATLAN','KOLI_ADMIN','KOLI_SYSADMIN'])) then
    raise exception 'DORM_FORBIDDEN: INGATLAN / KOLI_ADMIN / KOLI_SYSADMIN jogosultsag kell.';
  end if;
  return query
  select b.code, b.name, l.name, le.iktatoszam, le.ends_on, le.notice_months,
         le.decision_due_on, (le.decision_due_on - current_date)::integer,
         le.auto_renew, le.monthly_rent
    from dorm.lease le
    join dorm.building b on b.id = le.building_id
    left join dorm.landlord l on l.id = coalesce(le.landlord_id, b.landlord_id)
   where le.is_active
     and le.decision_due_on is not null
     and le.decision_due_on <= current_date + greatest(p_days, 0)
   order by le.decision_due_on;
end
$$;


-- --- 12.11 Grantok az RPC-kre ----------------------------------------------
do $rpc$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'dorm\_%'
       -- A visszaut SOHA nem kaphat execute jogot authenticated-nek:
       and p.proname <> 'dorm_module_rollback'
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end
$rpc$;


-- ============================================================================
-- 13. SZAKASZ — AZ ALAPMÁTRIX (jogcím-szintű alapértelmezések)
-- ============================================================================
-- FIGYELEM: ez JAVASLAT, nem hatósági hivatkozás. A tényleges felelősséget és
-- SLA-t a VALÓS bérleti szerződésekből kell véglegesíteni, és az eltéréseket
-- ÉPÜLET-SZINTŰ sorként kell rögzíteni (azok felülírják ezeket).
-- Ez az alapmátrix azért kerül a migrációba és nem a demó szakaszba, mert
-- nélküle a dorm_issue_report() nem tudna felelőst rendelni egyetlen jegyhez
-- sem — vagyis a modul fő funkciója nem működne az első naptól.

-- Globális alapértelmezés (harmadik szint): minden az egyetemé, belső karbantartás.
insert into dorm.responsibility (building_id, tenure, category_code, liable_party, route, cost_bearer, sla_hours, escalation_hours, note)
select null, null, fc.code, 'UNIVERSITY', 'INTERNAL_MAINT', 'UNIVERSITY', 120, null,
       'Globalis alapertelmezes (26_dorm.sql). Felulirja a jogcim- es az epulet-szintu sor.'
  from dorm.fault_category fc
on conflict do nothing;

-- OWNED — saját kollégium
insert into dorm.responsibility (tenure, category_code, liable_party, route, cost_bearer, sla_hours, escalation_hours, note) values
  ('OWNED','HEATING',    'UNIVERSITY','INTERNAL_MAINT','UNIVERSITY',   4,  8,  'Futesi idenyben P1.'),
  ('OWNED','HOT_WATER',  'UNIVERSITY','INTERNAL_MAINT','UNIVERSITY',   8, 16,  null),
  ('OWNED','PLUMBING',   'UNIVERSITY','EXTERNAL_VENDOR','UNIVERSITY',  8, 24,  'Lakoi eredetu dugulasnal a koltseg a lakoe — helyszini megallapitas utan.'),
  ('OWNED','ELECTRICAL', 'UNIVERSITY','INTERNAL_MAINT','UNIVERSITY',   4,  8,  null),
  ('OWNED','OPENINGS',   'UNIVERSITY','INTERNAL_MAINT','UNIVERSITY',  72,144,  null),
  ('OWNED','FURNITURE',  'UNIVERSITY','INTERNAL_MAINT','UNIVERSITY', 120,240,  null),
  ('OWNED','APPLIANCE',  'UNIVERSITY','EXTERNAL_VENDOR','UNIVERSITY',120,240,  null),
  ('OWNED','HVAC',       'UNIVERSITY','EXTERNAL_VENDOR','UNIVERSITY',  24, 48,  null),
  ('OWNED','LIFT',       'SERVICE_CONTRACT','EXTERNAL_VENDOR','UNIVERSITY',  4,  8, null),
  ('OWNED','ROOF',       'UNIVERSITY','EXTERNAL_VENDOR','UNIVERSITY',  24, 72,  null),
  ('OWNED','PEST',       'UNIVERSITY','EXTERNAL_VENDOR','UNIVERSITY',  48, 96,  null),
  ('OWNED','NETWORK',    'UNIVERSITY','IT_HELPDESK','UNIVERSITY',      24, 48,  null),
  ('OWNED','ACCESS',     'RESIDENT',  'HOUSE_MANAGER','RESIDENT',      24, 48,  'Kulcsvesztes, zarcsere: a koltseg a lakoe.'),
  ('OWNED','CLEANING',   'UNIVERSITY','HOUSE_MANAGER','UNIVERSITY',    24, 48,  null),
  ('OWNED','FIRE',       'SERVICE_CONTRACT','EXTERNAL_VENDOR','UNIVERSITY', 24, 48, 'Bizonylat kotelezo, hatosagi ellenorzeskor elo kell venni.'),
  ('OWNED','COMMON',     'UNIVERSITY','HOUSE_MANAGER','UNIVERSITY',    72,144,  null),
  ('OWNED','NOISE',      'UNIVERSITY','DORM_ADMIN','UNIVERSITY',      120,240,  null),
  ('OWNED','OTHER',      'UNIVERSITY','HOUSE_MANAGER','UNIVERSITY',   120,240,  null)
on conflict do nothing;

-- LEASED_WHOLE — teljes épület bérlete. AMI MÁS: a szerkezeti hibák a
-- bérbeadóé, a LANDLORD_TICKET útvonalon, ESZKALÁCIÓS határidővel és
-- HELYETTESÍTŐ JAVÍTÁSI joggal. A bútor viszont a MIÉNK, mert mi vittük be.
insert into dorm.responsibility (tenure, category_code, liable_party, route, cost_bearer, sla_hours, escalation_hours, substitute_repair_allowed, contract_clause, note) values
  ('LEASED_WHOLE','HEATING',    'LANDLORD','LANDLORD_TICKET','LANDLORD',   4,  8, true,  'berleti szerz. — futes',        'A "Berbeadora var" allapot merhetove teszi a teljesitest.'),
  ('LEASED_WHOLE','HOT_WATER',  'LANDLORD','LANDLORD_TICKET','LANDLORD',  24, 48, true,  'berleti szerz. — HMV',          null),
  ('LEASED_WHOLE','PLUMBING',   'LANDLORD','LANDLORD_TICKET','LANDLORD',   8, 24, true,  'berleti szerz. — gerincvezetek','Lakoi eredetu dugulas: a koltseg a lakoe. Helyszini megallapitas dont.'),
  ('LEASED_WHOLE','ELECTRICAL', 'LANDLORD','LANDLORD_TICKET','LANDLORD',   4,  8, true,  'berleti szerz. — elektromos',   null),
  ('LEASED_WHOLE','OPENINGS',   'LANDLORD','LANDLORD_TICKET','LANDLORD',  72,144, true,  'berleti szerz. — nyilaszaro',   null),
  ('LEASED_WHOLE','FURNITURE',  'UNIVERSITY','INTERNAL_MAINT','UNIVERSITY',120,240, false, null,                          'A butort MI vittuk be — ez a mienk marad.'),
  ('LEASED_WHOLE','APPLIANCE',  'UNIVERSITY','EXTERNAL_VENDOR','UNIVERSITY',120,240, false, null,                         'SZERZODESFUGGO — epuletenkent rogziteni kell!'),
  ('LEASED_WHOLE','HVAC',       'LANDLORD','LANDLORD_TICKET','LANDLORD',  24, 48, true,  'berleti szerz. — gepeszet',     null),
  ('LEASED_WHOLE','LIFT',       'LANDLORD','LANDLORD_TICKET','LANDLORD',   4,  8, false, 'berleti szerz. — lift',         null),
  ('LEASED_WHOLE','ROOF',       'LANDLORD','LANDLORD_TICKET','LANDLORD',  24, 72, true,  'berleti szerz. — epuletszerkezet', null),
  ('LEASED_WHOLE','PEST',       'LANDLORD','LANDLORD_TICKET','LANDLORD',  48, 96, true,  null,                            'SZERZODESFUGGO — poloska eseten szinte mindig vita.'),
  ('LEASED_WHOLE','NETWORK',    'UNIVERSITY','IT_HELPDESK','UNIVERSITY',  24, 48, false, null,                            'SZERZODESFUGGO.'),
  ('LEASED_WHOLE','ACCESS',     'RESIDENT','HOUSE_MANAGER','RESIDENT',    24, 48, false, null,                            null),
  ('LEASED_WHOLE','CLEANING',   'UNIVERSITY','HOUSE_MANAGER','UNIVERSITY',24, 48, false, null,                            null),
  ('LEASED_WHOLE','FIRE',       'LANDLORD','LANDLORD_TICKET','LANDLORD',  24, 48, true,  'berleti szerz. — tuzvedelem',   'A BIZONYLAT NALUNK kell legyen, meg ha a berbeado szolgaltatja is.'),
  ('LEASED_WHOLE','COMMON',     'LANDLORD','LANDLORD_TICKET','LANDLORD',  72,144, true,  null,                            null),
  ('LEASED_WHOLE','NOISE',      'UNIVERSITY','DORM_ADMIN','UNIVERSITY',  120,240, false, null,                            null),
  ('LEASED_WHOLE','OTHER',      'UNIVERSITY','HOUSE_MANAGER','UNIVERSITY',120,240, false, null,                           null)
on conflict do nothing;

-- LEASED_PARTIAL — a LEASED_WHOLE-lal azonos alap, de a közös helyiség a
-- társasházé (HOUSE_MANAGER = közös képviselő).
insert into dorm.responsibility (tenure, category_code, liable_party, route, cost_bearer, sla_hours, escalation_hours, substitute_repair_allowed, note)
select 'LEASED_PARTIAL', r.category_code, r.liable_party,
       case when r.category_code in ('COMMON','ROOF','LIFT') then 'HOUSE_MANAGER' else r.route end,
       r.cost_bearer, r.sla_hours, r.escalation_hours, r.substitute_repair_allowed,
       'A LEASED_WHOLE alapbol szarmaztatva; a kozos reszek a tarsashaz kozos kepviselojehez mennek.'
  from dorm.responsibility r
 where r.tenure = 'LEASED_WHOLE' and r.building_id is null
on conflict do nothing;

-- CONTRACTED_CAPACITY — a legkellemetlenebb konstrukció: a szoba műszaki
-- állapotára NINCS ráhatásunk, minden a partner felé megy — de a lakóért és a
-- díjért MI felelünk. Ezért van külön jogcím: hogy LÁTSZÓDJON.
insert into dorm.responsibility (tenure, category_code, liable_party, route, cost_bearer, sla_hours, escalation_hours, note)
select 'CONTRACTED_CAPACITY', fc.code, 'LANDLORD', 'LANDLORD_TICKET', 'LANDLORD', 48, 96,
       'Nincs rahatasunk a muszaki allapotra; az egyetlen utvonal a partner fele megy. A lakoert es a dijert megis mi felelunk.'
  from dorm.fault_category fc
on conflict do nothing;

-- MANAGED_FOR_OTHER / OWNED_OUT_OF_USE — az OWNED alapból származtatva.
insert into dorm.responsibility (tenure, category_code, liable_party, route, cost_bearer, sla_hours, escalation_hours, note)
select t.code, r.category_code, r.liable_party, r.route, r.cost_bearer, r.sla_hours, r.escalation_hours,
       'Az OWNED alapbol szarmaztatva.'
  from dorm.tenure t
  cross join dorm.responsibility r
 where t.code in ('MANAGED_FOR_OTHER','OWNED_OUT_OF_USE')
   and r.tenure = 'OWNED' and r.building_id is null
on conflict do nothing;


-- ============================================================================
-- 14. SZAKASZ — VISSZAÚT
-- ============================================================================
-- A status_model_rollback() mintájára, de MEGERŐSÍTÉSSEL: ez a függvény a
-- teljes modult eldobja, adatostul. Ezért kötelező paraméter a pontos szöveg.
-- SOHA nem kap execute jogot authenticated-nek — kizárólag a service_role /
-- postgres futtathatja az SQL Editorból.
create or replace function public.dorm_module_rollback(p_confirm text)
returns text language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_tables integer;
begin
  if p_confirm is distinct from 'IGEN, TOROLD A DORM MODULT' then
    return 'MEGSZAKITVA. A visszaut hivasa: select public.dorm_module_rollback(''IGEN, TOROLD A DORM MODULT'');';
  end if;
  select count(*) into v_tables from pg_tables where schemaname = 'dorm';
  execute 'drop schema if exists dorm cascade';
  perform public.log_status_event('DORM_MODULE_ROLLBACK', 'dorm',
    v_tables || ' tabla eldobva a dorm semaval egyutt');
  return 'A dorm sema eldobva (' || v_tables || ' tabla). A public.dorm_* RPC-k kulon dobandok.';
end
$$;

revoke all on function public.dorm_module_rollback(text) from public, anon, authenticated;


-- ============================================================================
-- 15. SZAKASZ — DEMÓ SEED  (KÜLÖN SZAKASZ, IDEMPOTENS)
-- ============================================================================
-- Mit ad: 2 SAJÁT kollégium + 1 BÉRELT épület, emeletekkel, szobákkal,
-- ágyakkal, lakókkal és nyitott hibákkal — hogy a modul azonnal kipróbálható
-- legyen, és hogy a felelősségi mátrix három szintje MÉRHETŐEN látszódjon
-- (a bérelt épületnél épület-szintű felülírásokkal).
--
-- ÉLESBEN: ez a szakasz TÖRÖLHETŐ vagy kihagyható. A 13. szakasz alapmátrixa
-- viszont NEM demó — az a modul működéséhez kell.
--
-- A demó grantok MEGLÉVŐ profilokra kerülnek (a replikán 5 van, mérve), mert
-- ez a migráció NEM hoz létre auth.users sort. A gondnoki grant szándékosan
-- az AGENT szerepkörű fiókra megy: az AGENT nincs benne a public.is_staff()
-- fehérlistájában, tehát rajta MÉRHETŐ, hogy a hatókörös jogosultság önmagában
-- működik-e — és hogy a MÁSIK épület adata tényleg nem látszik.

do $seed$
declare
  v_site_a uuid; v_site_b uuid; v_site_c uuid;
  v_ll     uuid;
  v_ka uuid; v_kb uuid; v_br uuid;
  v_floor uuid; v_room uuid;
  v_term uuid;
  v_lvl integer; v_i integer; v_j integer;
  v_bcode text; v_rtype text; v_beds integer; v_full text;
  b record; p record; o record;
  v_person uuid; v_bed uuid;
  v_admin uuid; v_adm uuid; v_fin uuid; v_agent uuid; v_stud uuid;
begin
  -- ---- 15.1 Telephely, bérbeadó, épületek ---------------------------------
  insert into dorm.site (code, name, city, address) values
    ('TELEP-HOMOK',   'Homokbányai campus',  'Kecskemét', 'Izsáki út 10.'),
    ('TELEP-IZSAKI',  'Izsáki úti campus',   'Kecskemét', 'Izsáki út 5.'),
    ('TELEP-BELVAROS','Belvárosi telephely', 'Kecskemét', 'Petőfi Sándor utca 12.')
  on conflict (code) do nothing;

  select id into v_site_a from dorm.site where code = 'TELEP-HOMOK';
  select id into v_site_b from dorm.site where code = 'TELEP-IZSAKI';
  select id into v_site_c from dorm.site where code = 'TELEP-BELVAROS';

  insert into dorm.landlord (name, is_company, tax_number, representative, email, phone, duty_phone, billing_address)
  values ('Kecskeméti Ingatlanhasznosító Kft.', true, '12345678-2-03', 'Nagy Béla',
          'iroda@kecskemetingatlan.example', '+36 76 000 000', '+36 30 000 0000',
          '6000 Kecskemét, Petőfi Sándor utca 12.')
  on conflict do nothing;
  select id into v_ll from dorm.landlord where lower(btrim(name)) = lower('Kecskeméti Ingatlanhasznosító Kft.');

  insert into dorm.building (site_id, code, name, tenure, address, landlord_id, house_manager,
                             house_manager_phone, gross_area_sqm, floors_count, has_lift, is_accessible,
                             in_portfolio_from)
  values
    (v_site_a, 'KOLL-A', 'Homokbánya Kollégium',   'OWNED',        '6000 Kecskemét, Izsáki út 10.', null,
     'Kovács István', '+36 30 111 1111', 4200, 4, true,  true,  date '2010-09-01'),
    (v_site_b, 'KOLL-B', 'Izsáki úti Kollégium',   'OWNED',        '6000 Kecskemét, Izsáki út 5.',  null,
     'Tóth Erzsébet', '+36 30 222 2222', 2600, 3, false, false, date '2004-09-01'),
    (v_site_c, 'BER-1',  'Petőfi utcai bérház',    'LEASED_WHOLE', '6000 Kecskemét, Petőfi Sándor utca 12.', v_ll,
     'Szabó Gábor',  '+36 30 333 3333', 1400, 2, false, false, date '2025-09-01')
  on conflict (code) do nothing;

  select id into v_ka from dorm.building where code = 'KOLL-A';
  select id into v_kb from dorm.building where code = 'KOLL-B';
  select id into v_br from dorm.building where code = 'BER-1';

  -- ---- 15.2 Bérleti szerződés a bérelt épületre ---------------------------
  -- 2028-06-30 lejárat, 6 hónap felmondási idő, 60 nap puffer
  --   -> a DÖNTÉSI dátum 2027-11-01 körül van, NEM 2028 nyara.
  insert into dorm.lease (building_id, landlord_id, iktatoszam, starts_on, ends_on, notice_months,
                          auto_renew, monthly_rent, rent_currency, utilities_mode,
                          deposit_amount, deposit_currency, signed_by)
  select v_br, v_ll, 'NJE/BER/2025/017', date '2025-09-01', date '2028-06-30', 6,
         true, 2450000, 'HUF', 'SUBMETER', 4900000, 'HUF', 'kancellár'
  where not exists (select 1 from dorm.lease where iktatoszam = 'NJE/BER/2025/017');

  insert into dorm.deposit (direction, building_id, lease_id, amount, currency, received_on, status, note)
  select 'PAID_TO_LANDLORD', v_br, l.id, 4900000, 'HUF', date '2025-08-25', 'HELD',
         'AMIT MI ADTUNK a bérbeadónak — a legkönnyebben elfelejtett pénz. A bérlet végén, a visszaadási jegyzőkönyv után jár vissza.'
    from dorm.lease l
   where l.iktatoszam = 'NJE/BER/2025/017'
     and not exists (select 1 from dorm.deposit d where d.lease_id = l.id);

  -- ---- 15.3 Épület-szintű felülírások a bérelt épületnél ------------------
  -- Ez mutatja meg a mátrix legfelső szintjét: az adott szerződésben a
  -- háztartási gép, a kártevőirtás és az internet is a bérbeadóé.
  insert into dorm.responsibility (building_id, category_code, liable_party, route, cost_bearer,
                                   sla_hours, escalation_hours, substitute_repair_allowed,
                                   contact_name, contact_phone, contract_clause, note)
  select v_br, x.cat, 'LANDLORD', 'LANDLORD_TICKET', 'LANDLORD', x.sla, x.esc, true,
         'Nagy Béla', '+36 30 000 0000', x.clause, 'ÉPÜLET-SZINTŰ felülírás (demó): a szerződés a bérbeadóra telepíti.'
    from (values
      ('APPLIANCE', 72, 144, 'bérleti szerz. 5.3 § b) pont'),
      ('PEST',      48,  96, 'bérleti szerz. 5.7 § pont'),
      ('NETWORK',   24,  48, 'bérleti szerz. 6.2 § pont')
    ) as x(cat, sla, esc, clause)
  on conflict do nothing;

  -- ---- 15.4 Szintek, szobák, férőhelyek ----------------------------------
  for b in
    select id, code,
           case code when 'KOLL-A' then 3 when 'KOLL-B' then 2 else 2 end as res_floors,
           case code when 'KOLL-A' then 8 when 'KOLL-B' then 6 else 4 end as rooms_per_floor
      from dorm.building where code in ('KOLL-A','KOLL-B','BER-1')
  loop
    -- földszint: közös és szolgálati helyiségek
    insert into dorm.floor (building_id, level_no, label) values (b.id, 0, 'Földszint')
    on conflict do nothing;
    select id into v_floor from dorm.floor where building_id = b.id and level_no = 0 and wing is null;

    for v_i in 1..3 loop
      v_full := b.code || '/0/00' || v_i;
      v_rtype := (array['COMMON','COMMON','SERVICE'])[v_i];
      insert into dorm.room (building_id, floor_id, door_number, full_code, room_type, purpose,
                             capacity, area_sqm, status)
      values (b.id, v_floor, '00' || v_i, v_full, v_rtype,
              case when v_rtype = 'SERVICE' then 'SERVICE' else 'COMMON' end,
              0, 24.0, 'available')
      on conflict (building_id, full_code) do nothing;
    end loop;

    -- lakószintek
    for v_lvl in 1..b.res_floors loop
      insert into dorm.floor (building_id, level_no, label)
      values (b.id, v_lvl, v_lvl || '. emelet')
      on conflict do nothing;
      select id into v_floor from dorm.floor where building_id = b.id and level_no = v_lvl and wing is null;

      for v_i in 1..b.rooms_per_floor loop
        v_full := b.code || '/' || v_lvl || '/' || (v_lvl * 100 + v_i)::text;
        v_rtype := case
                     when b.code = 'BER-1' then (array['DOUBLE','STUDIO','DOUBLE','TRIPLE'])[((v_i - 1) % 4) + 1]
                     when v_i % 4 = 0     then 'DOUBLE'
                     when v_i % 4 = 1     then 'TRIPLE'
                     when v_i % 4 = 2     then 'TRIPLE'
                     else                      'QUAD'
                   end;
        select default_beds into v_beds from dorm.room_type where code = v_rtype;

        insert into dorm.room (building_id, floor_id, door_number, full_code, room_type, purpose,
                               capacity, area_sqm, bathroom, kitchen, internet,
                               is_accessible, step_free_shower, gender_restriction, status,
                               unit_code)
        values (b.id, v_floor, (v_lvl * 100 + v_i)::text, v_full, v_rtype, 'RESIDENTIAL',
                v_beds, 12.0 + v_beds * 4,
                case when b.code = 'BER-1' then 'PRIVATE' else 'SHARED_UNIT' end,
                case when b.code = 'BER-1' then 'KITCHENETTE' else 'SHARED_FLOOR' end,
                'BOTH',
                (b.code = 'KOLL-A' and v_lvl = 1 and v_i = 1),   -- egy akadálymentes szoba
                (b.code = 'KOLL-A' and v_lvl = 1 and v_i = 1),
                case when v_lvl = 2 then 'FEMALE' when v_lvl = 3 then 'MALE' else 'ANY' end,
                'available',
                case when b.code = 'BER-1' then 'L' || v_lvl || '-' || ceil(v_i / 2.0)::int else null end)
        on conflict (building_id, full_code) do nothing;

        select id into v_room from dorm.room where building_id = b.id and full_code = v_full;

        for v_j in 1..v_beds loop
          insert into dorm.bed (building_id, room_id, bed_label, full_code)
          values (b.id, v_room, chr(64 + v_j), v_full || '-' || chr(64 + v_j))
          on conflict (building_id, full_code) do nothing;
        end loop;
      end loop;
    end loop;
  end loop;

  -- Néhány NEM kiadható hely, hogy a három kapacitásfogalom eltérjen egymástól
  -- (ha minden hely kiadható, a riport nem mutatna semmi tanulságosat).
  update dorm.bed set status = 'out_of_service'
   where full_code in ('KOLL-A/2/202-B', 'KOLL-B/1/103-C')
     and status = 'available';
  update dorm.bed set status = 'reserved'
   where full_code = 'KOLL-A/3/301-A' and status = 'available';
  update dorm.room set status = 'renovation'
   where full_code = 'KOLL-B/2/205' and status = 'available';
  update dorm.room set status = 'reserved'
   where full_code = 'KOLL-A/1/108' and status = 'available';

  -- ---- 15.5 Időszak és díjkatalógus ---------------------------------------
  insert into dorm.term (code, label_hu, kind, starts_on, ends_on, application_deadline, allocation_on, movein_from, movein_to)
  values ('2026-27-1', '2026/27 tanév őszi félév', 'SEMESTER',
          date '2026-09-01', date '2027-01-31', date '2026-07-15', date '2026-08-01',
          date '2026-08-25', date '2026-09-10')
  on conflict (code) do nothing;
  select id into v_term from dorm.term where code = '2026-27-1';

  insert into dorm.fee_schedule (code, label_hu, fee_type, target_group, amount, currency, proration, valid_from, note) values
    ('KOLI-HAVI-HU',  'Kollégiumi díj / hó (hazai)',        'DORM_FEE_MONTHLY', 'DOMESTIC_STATE_FUNDED',  22000, 'HUF', 'CALENDAR_DAYS', date '2026-07-01', null),
    ('KOLI-HAVI-INT', 'Kollégiumi díj / hó (nemzetközi)',   'DORM_FEE_MONTHLY', 'INTERNATIONAL',            120, 'EUR', 'CALENDAR_DAYS', date '2026-07-01', null),
    ('KAUCIO-INT',    'Kaució (nemzetközi)',                'DEPOSIT',          'INTERNATIONAL',            450, 'EUR', 'NONE',          date '2026-07-01',
     'EZ AZ EGYETLEN HELY, ahol a kaució összege él. MÉRVE: ma az app.jsx:6628 EUR 450-et, a features/knowledge-base.jsx:40 EUR 750-et mond — a katalógus után egy szám van, és a felvételi levél, az asszisztens és a számlázás EBBŐL olvas.'),
    ('KULCS-POTLAS',  'Kulcspótlás / zárcsere',             'KEY_REPLACEMENT',  'ANY',                     18000, 'HUF', 'NONE',          date '2026-07-01', null),
    ('KESEDELMI',     'Késedelmi díj',                      'LATE_FEE',         'ANY',                      5000, 'HUF', 'NONE',          date '2026-07-01', null)
  on conflict do nothing;

  -- ---- 15.6 Lakók ---------------------------------------------------------
  select id into v_admin from public.profiles where email = 'admin@uni.hu';
  select id into v_adm   from public.profiles where email = 'admissions@uni.hu';
  select id into v_fin   from public.profiles where email = 'finance@uni.hu';
  select id into v_agent from public.profiles where email = 'agent@globalstudy.com';
  select id into v_stud  from public.profiles where email = 'ammar@test.com';

  -- A jelentkezőkből lakó (a students sor a JELENTKEZÉS, a person a SZEMÉLY).
  for p in
    select s.id, s.name, s.email, s.phone, s.country, s."birthDate", s.gender
      from public.students s
     where s.id in ('S1','S4','S6','S8','S0')
  loop
    insert into dorm.person (display_name, email, phone, kind, student_id, citizenship, birth_date,
                             gender, emergency_contact)
    select p.name, p.email, p.phone, 'STUDENT', p.id, p.country,
           nullif(p."birthDate", '')::date,
           case upper(coalesce(p.gender, '')) when 'MALE' then 'MALE' when 'FEMALE' then 'FEMALE' else null end,
           jsonb_build_object('nev', 'megadandó', 'telefon', 'megadandó')
    where not exists (select 1 from dorm.person where student_id = p.id);
  end loop;

  -- Vendégkutató: SOHA nem volt és nem is lehet students sora. Ez a fő indoka
  -- annak, hogy a lakó külön entitás (6. szerkezeti döntés).
  insert into dorm.person (display_name, email, phone, kind, citizenship, note)
  select 'Dr. Marta Nowak', 'marta.nowak@example.org', '+48 500 000 000', 'GUEST', 'Lengyelország',
         'Vendégkutató — NINCS és nem is lehet public.students sora.'
  where not exists (select 1 from dorm.person where email = 'marta.nowak@example.org');

  -- A lakó UniPortal-fiókjának kötése (ez teszi mérhetővé a lakói RLS-t).
  update dorm.person set profile_id = v_stud
   where student_id = 'S1' and profile_id is null and v_stud is not null;

  -- ---- 15.7 Kollégiumi igény a felvételi folyamatból ----------------------
  insert into dorm.intent (student_id, term_id, wants_dorm, preferred_period, source, note)
  select x.sid, v_term, x.wants, x.per, 'admission_letter', x.note
    from (values
      ('S1', true,  'full_year', 'Teljes tanévre kér kollégiumot — a levélben KÉT félévnyi díj és kaució szerepeljen.'),
      ('S4', true,  'semester_1','CSAK az őszi félévre — a levélben EGY félévnyi díj. Ez a tesztelők kérdése.'),
      ('S6', true,  'full_year', null),
      ('S8', false, 'undecided', 'NEM kér kollégiumot — a levélből a kollégiumi díjsor és a kaució MARADJON KI.'),
      ('S0', true,  'semester_2','Tavaszi félévtől.')
    ) as x(sid, wants, per, note)
   where exists (select 1 from public.students s where s.id = x.sid)
  on conflict do nothing;

  -- ---- 15.8 Elhelyezések ---------------------------------------------------
  -- Az időszakok a MAI naphoz képest relatívak, hogy a demó bármikor telepítve
  -- "élő" legyen: legyen aki MOST lakik, és legyen JÖVŐBENI foglalás is —
  -- utóbbi mutatja meg, hogy a daterange-ből a februári kapacitás előre
  -- látszik (ez a modul egyik fő ígérete).
  for o in
    select * from (values
      ('S1', 'KOLL-A/1/101-A', -30, 300, 'MOVED_IN',  'Teljes tanév, MOST lakik.'),
      ('S4', 'KOLL-A/1/101-B', -30, 160, 'MOVED_IN',  'CSAK az őszi félév — a februári "lyuk" ELŐRE látszik.'),
      ('S6', 'KOLL-A/3/302-A', -25, 300, 'MOVED_IN',  'Teljes tanév.'),
      ('S8', 'KOLL-B/1/101-A', -30, 300, 'MOVED_IN',  'Teljes tanév, másik saját kollégium.'),
      ('S0', 'KOLL-B/1/102-A', 160, 300, 'ALLOCATED', 'JÖVŐBENI foglalás: tavaszi félévtől.')
    ) as t(sid, bed_code, d_from, d_to, st, memo)
  loop
    select id into v_person from dorm.person where student_id = o.sid;
    select id into v_bed    from dorm.bed    where full_code  = o.bed_code;
    if v_person is not null and v_bed is not null
       and not exists (select 1 from dorm.occupancy oc where oc.bed_id = v_bed and oc.person_id = v_person) then
      insert into dorm.occupancy (building_id, bed_id, person_id, term_id, period, state,
                                  moved_in_at, assignment_mode, note)
      select bd.building_id, v_bed, v_person, v_term,
             daterange(current_date + o.d_from, current_date + o.d_to, '[)'), o.st,
             case when o.st = 'MOVED_IN' then now() - interval '30 days' end,
             'MANUAL', 'Demó adat — ' || o.memo
        from dorm.bed bd where bd.id = v_bed;
    end if;
  end loop;

  -- A vendégkutató a BÉRELT épületben — rövid tartózkodás, JÖVŐBENI foglalás.
  select id into v_person from dorm.person where email = 'marta.nowak@example.org';
  select id into v_bed    from dorm.bed    where full_code = 'BER-1/1/101-A';
  if v_person is not null and v_bed is not null
     and not exists (select 1 from dorm.occupancy oc where oc.bed_id = v_bed and oc.person_id = v_person) then
    insert into dorm.occupancy (building_id, bed_id, person_id, period, state, assignment_mode, note)
    select bd.building_id, v_bed, v_person,
           daterange(current_date + 37, current_date + 98, '[)'),
           'ALLOCATED', 'MANUAL', 'SHORT_STAY a bérelt épületben (vendégkutató, nincs students sora)'
      from dorm.bed bd where bd.id = v_bed;
  end if;

  -- A lakott szobák státusza kövesse a valóságot (available -> allocated -> occupied).
  for o in
    select distinct r.id, bool_or(oc.state = 'MOVED_IN') as van_bekoltozott
      from dorm.occupancy oc
      join dorm.bed bd on bd.id = oc.bed_id
      join dorm.room r on r.id = bd.room_id
     where oc.state in ('ALLOCATED','MOVED_IN') and r.status = 'available'
     group by r.id
  loop
    update dorm.room set status = 'allocated' where id = o.id;
    if o.van_bekoltozott then
      update dorm.room set status = 'occupied' where id = o.id;
    end if;
  end loop;

  -- ---- 15.9 Kaució és díjtételek a lakóknál -------------------------------
  insert into dorm.deposit (direction, person_id, building_id, amount, currency, received_on, status, note)
  select 'HELD_FROM_RESIDENT', pr.id, oc.building_id, 450, 'EUR', date '2026-08-20', 'HELD',
         'A lakói kaució NEM BEVÉTEL, hanem KÖTELEZETTSÉG — visszajár.'
    from dorm.person pr
    join dorm.occupancy oc on oc.person_id = pr.id
   where pr.student_id in ('S1','S4')
     and not exists (select 1 from dorm.deposit d
                      where d.person_id = pr.id and d.direction = 'HELD_FROM_RESIDENT');

  insert into dorm.charge (person_id, occupancy_id, building_id, fee_type, period, amount, currency,
                           fx_rate, fx_date, due_on, status, note)
  select oc.person_id, oc.id, oc.building_id, 'DORM_FEE_MONTHLY',
         daterange(date_trunc('month', current_date)::date,
                   (date_trunc('month', current_date) + interval '1 month')::date, '[)'),
         120, 'EUR', 395.0, date_trunc('month', current_date)::date,
         (date_trunc('month', current_date) + interval '9 days')::date, 'due', 'Demó: EUR-ban kiírt havi díj, rögzített árfolyammal (enélkül a riportok összeadhatatlanok).'
    from dorm.occupancy oc
    join dorm.person pr on pr.id = oc.person_id
   where pr.student_id in ('S1','S4','S6')
     and not exists (select 1 from dorm.charge c where c.occupancy_id = oc.id and c.fee_type = 'DORM_FEE_MONTHLY');

  -- ---- 15.10 Kulcs, mérőóra, megelőző karbantartás ------------------------
  insert into dorm.key (building_id, identifier, key_type, opens_kind, room_id, copies_total, master_level)
  select r.building_id, 'K-' || r.full_code, 'MECHANICAL', 'ROOM', r.id, 2, null
    from dorm.room r
   where r.purpose = 'RESIDENTIAL' and r.building_id in (v_ka, v_kb, v_br)
  on conflict (building_id, identifier) do nothing;

  insert into dorm.key (building_id, identifier, key_type, opens_kind, copies_total, master_level, storage_place)
  values (v_ka, 'MESTER-KOLL-A', 'MECHANICAL', 'MASTER', 2, 1, 'gondnoki páncélszekrény')
  on conflict (building_id, identifier) do nothing;

  insert into dorm.meter (building_id, meter_type, serial_number, owner_party, read_by,
                          read_frequency, calibration_due_on) values
    (v_ka, 'ELECTRICITY', 'EL-KOLLA-001', 'UNIVERSITY', 'UNIVERSITY', 'havi', date '2028-03-31'),
    (v_ka, 'COLD_WATER',  'VZ-KOLLA-001', 'UNIVERSITY', 'UNIVERSITY', 'havi', date '2027-06-30'),
    (v_kb, 'ELECTRICITY', 'EL-KOLLB-001', 'UNIVERSITY', 'UNIVERSITY', 'havi', date '2027-12-31'),
    (v_br, 'ELECTRICITY', 'EL-BER1-001',  'LANDLORD',   'UNIVERSITY', 'havi', date '2026-11-30'),
    (v_br, 'COLD_WATER',  'VZ-BER1-001',  'LANDLORD',   'UNIVERSITY', 'havi', date '2026-10-31')
  on conflict (building_id, serial_number) do nothing;

  insert into dorm.pm_plan (building_id, code, title, category_code, interval_months,
                            is_legal_requirement, responsible_party, certificate_required, next_due_on) values
    (v_ka, 'PM-TUZOLTO',   'Tűzoltó készülék ellenőrzés',        'FIRE',    3,  true,  'SERVICE_CONTRACT', true,  current_date + 20),
    (v_ka, 'PM-GAZ',       'Gázkészülék felülvizsgálat',         'HVAC',   12,  true,  'SERVICE_CONTRACT', true,  current_date + 75),
    (v_ka, 'PM-LEGIONELLA','Legionella kockázatértékelés + HMV mintavétel', 'HOT_WATER', 12, true, 'EXTERNAL_VENDOR', true, current_date + 15),
    (v_ka, 'PM-LIFT',      'Lift karbantartás',                  'LIFT',    1,  true,  'SERVICE_CONTRACT', true,  current_date + 8),
    (v_kb, 'PM-TUZOLTO',   'Tűzoltó készülék ellenőrzés',        'FIRE',    3,  true,  'SERVICE_CONTRACT', true,  current_date + 45),
    (v_kb, 'PM-ERINTES',   'Érintésvédelmi szabványossági mérés','ELECTRICAL', 36, true, 'EXTERNAL_VENDOR', true, current_date + 200),
    (v_br, 'PM-TUZOLTO',   'Tűzoltó készülék ellenőrzés — BIZONYLAT BEKÉRÉSE a bérbeadótól', 'FIRE', 3, true, 'LANDLORD', true, current_date + 5)
  on conflict do nothing;

  -- ---- 15.11 Nyitott hibák -------------------------------------------------
  -- Fix ticket_no-val, hogy a szakasz idempotens legyen (a sequence nem az).
  for o in
    select * from (values
      ('HIB-DEMO-0001','KOLL-A/1/101','HEATING',   'Nem melegszik a radiátor',        'ROOM_UNUSABLE','NEW'),
      ('HIB-DEMO-0002','KOLL-A/3/302','PLUMBING',  'Dugulás a zuhanyzóban',           'NONE',         'TRIAGE'),
      ('HIB-DEMO-0003','KOLL-A/2/201','ELECTRICAL','Nem működik a konnektor',         'ONE_BED',      'ASSIGNED'),
      ('HIB-DEMO-0004','KOLL-B/1/101','APPLIANCE','Nem hűt a hűtőszekrény',           'NONE',         'IN_PROGRESS'),
      ('HIB-DEMO-0005','KOLL-B/1/103','OPENINGS',  'Az ablak nem záródik',            'NONE',         'NEW'),
      ('HIB-DEMO-0006','BER-1/1/101', 'APPLIANCE', 'Elromlott a mosógép a lakásban',  'NONE',         'WAITING_LANDLORD'),
      ('HIB-DEMO-0007','BER-1/1/102', 'PEST',      'Rágcsáló a konyhában',            'NONE',         'WAITING_LANDLORD'),
      ('HIB-DEMO-0008','BER-1/2/201', 'ROOF',      'Beázás a plafonon',               'ROOM_UNUSABLE','NEW')
    ) as t(tno, rcode, cat, title, impact, st)
  loop
    if not exists (select 1 from dorm.issue where ticket_no = o.tno) then
      insert into dorm.issue (ticket_no, building_id, room_id, category_code, title, description,
                              impact, priority, liable_party_initial, route, cost_bearer,
                              contract_clause, responsibility_source, substitute_repair, needs_triage,
                              status, due_at, escalate_at, source, contact_ok, created_at)
      select o.tno, r.building_id, r.id, o.cat, o.title, 'Demó adat (26_dorm.sql, 15. szakasz).',
             o.impact, dorm.compute_priority(fc.base_priority, o.impact),
             rr.liable_party, rr.route, rr.cost_bearer, rr.contract_clause, rr.source,
             coalesce(rr.substitute_repair_allowed, false), fc.needs_triage,
             'NEW',
             now() - interval '30 hours' + make_interval(hours => coalesce(rr.sla_hours, 120)),
             case when rr.escalation_hours is null then null
                  else now() - interval '30 hours' + make_interval(hours => rr.escalation_hours) end,
             'RESIDENT', false, now() - interval '30 hours'
        from dorm.room r
        join dorm.fault_category fc on fc.code = o.cat
        cross join lateral dorm.resolve_responsibility(r.building_id, o.cat) rr
       where r.full_code = o.rcode;

      -- az állapotot a guard triggeren KERESZTÜL állítjuk be, hogy a
      -- dorm.issue_event előzmény is keletkezzen
      if o.st <> 'NEW' then
        if o.st in ('ASSIGNED','IN_PROGRESS','WAITING_LANDLORD') then
          update dorm.issue set status = 'ACKNOWLEDGED' where ticket_no = o.tno;
          update dorm.issue set status = 'ASSIGNED'     where ticket_no = o.tno;
        end if;
        if o.st in ('IN_PROGRESS','WAITING_LANDLORD') then
          update dorm.issue set status = 'IN_PROGRESS'  where ticket_no = o.tno;
        end if;
        if o.st = 'WAITING_LANDLORD' then
          update dorm.issue set status = 'WAITING_LANDLORD',
                                landlord_notified_at = now() - interval '20 hours'
           where ticket_no = o.tno;
        end if;
        if o.st = 'TRIAGE' then
          update dorm.issue set status = 'TRIAGE' where ticket_no = o.tno;
        end if;
      end if;
    end if;
  end loop;

  -- ---- 15.12 Demó szerepkör-grantok ---------------------------------------
  -- MEGLÉVŐ profilokra. A GONDNOK grant szándékosan az AGENT fiókra megy:
  -- az AGENT nincs a public.is_staff() fehérlistájában, ezért rajta MÉRHETŐ,
  -- hogy a hatókörös jogosultság önmagában, épületre szűkítve működik.
  if v_admin is not null then
    insert into dorm.role_grant (person, role, scope_building, megjegyzes)
    values (v_admin, 'KOLI_SYSADMIN', null, 'Demó grant (26_dorm.sql).')
    on conflict do nothing;
  end if;
  if v_adm is not null then
    insert into dorm.role_grant (person, role, scope_building, megjegyzes)
    values (v_adm, 'KOLI_ADMIN', null, 'Demó grant (26_dorm.sql).')
    on conflict do nothing;
  end if;
  if v_fin is not null then
    insert into dorm.role_grant (person, role, scope_building, megjegyzes)
    values (v_fin, 'INGATLAN', null, 'Demó grant (26_dorm.sql).')
    on conflict do nothing;
  end if;
  if v_agent is not null then
    insert into dorm.role_grant (person, role, scope_building, megjegyzes)
    values (v_agent, 'GONDNOK', v_ka, 'Demó grant: CSAK a KOLL-A épületre (hatókör-teszt).')
    on conflict do nothing;
  end if;
end
$seed$;


-- ============================================================================
-- 16. SZAKASZ — ÖNELLENŐRZÉS: ami HIBÁVAL bukjon, ne csendben
-- ============================================================================
-- A 25-ös migráció mintája: az ellenőrzés ne csak kiírjon, hanem álljon is meg,
-- ha az eredmény nem a várt. Egy félig telepített jogosultsági réteg
-- rosszabb, mint egy le nem futott migráció.
do $chk$
declare
  v_tables integer; v_rls integer; v_pol integer; v_anon integer;
  v_excl integer; v_bld integer; v_bed integer; v_resp integer;
  r record;
begin
  select count(*) into v_tables from pg_tables where schemaname = 'dorm';
  select count(*) into v_rls    from pg_class c join pg_namespace n on n.oid = c.relnamespace
                                where n.nspname = 'dorm' and c.relkind = 'r' and c.relrowsecurity;
  select count(*) into v_pol    from pg_policies where schemaname = 'dorm';

  if v_tables <> v_rls then
    raise exception 'DORM_CHECK_RLS: % tabla van, de csak %-on van bekapcsolva az RLS.', v_tables, v_rls;
  end if;

  -- Minden dorm táblán legyen legalább egy policy: RLS policy nélkül a tábla
  -- néma (mindent tilt), ami csendes funkcióvesztés.
  for r in
    select t.tablename from pg_tables t
     where t.schemaname = 'dorm'
       and not exists (select 1 from pg_policies p
                        where p.schemaname = 'dorm' and p.tablename = t.tablename)
  loop
    raise exception 'DORM_CHECK_POLICY: a dorm.% tablan nincs egyetlen policy sem.', r.tablename;
  end loop;

  -- Az anon SEMMIT nem kaphat.
  select count(*) into v_anon
    from information_schema.role_table_grants
   where table_schema = 'dorm' and grantee = 'anon';
  if v_anon > 0 then
    raise exception 'DORM_CHECK_ANON: az anon szerepnek % tabla-jogosultsaga van a dorm semaban.', v_anon;
  end if;
  if has_schema_privilege('anon', 'dorm', 'usage') then
    raise exception 'DORM_CHECK_ANON_SCHEMA: az anon szerepnek USAGE joga van a dorm seman.';
  end if;

  -- A férőhely-átfedést tiltó constraint MEGLÉTE — ez a modul gerince.
  select count(*) into v_excl from pg_constraint
   where conname = 'dorm_occupancy_no_overlap_excl' and contype = 'x';
  if v_excl <> 1 then
    raise exception 'DORM_CHECK_EXCLUDE: hianyzik a dorm_occupancy_no_overlap_excl exclusion constraint.';
  end if;

  -- Legyen minden hibakategóriára feloldható felelős MINDEN épületre.
  for r in select b.id, b.code, fc.code as cat from dorm.building b cross join dorm.fault_category fc
  loop
    if not exists (select 1 from dorm.resolve_responsibility(r.id, r.cat)) then
      raise exception 'DORM_CHECK_MATRIX: a(z) % epuletben a(z) % kategoriara nincs felelos.', r.code, r.cat;
    end if;
  end loop;

  -- A demó seed értelmes állapotban van-e.
  select count(*) into v_bld from dorm.building;
  select count(*) into v_bed from dorm.bed;
  select count(*) into v_resp from dorm.responsibility;
  if v_bld < 3 then raise exception 'DORM_CHECK_SEED: kevesebb mint 3 epulet (%).', v_bld; end if;
  if v_bed  < 50 then raise exception 'DORM_CHECK_SEED: kevesebb mint 50 ferohely (%).', v_bed; end if;
end
$chk$;

commit;


-- ============================================================================
-- 17. SZAKASZ — ELLENŐRZŐ LEKÉRDEZÉSEK  (EGYETLEN eredménytábla)
-- ============================================================================
with t as (select count(*)::text v from pg_tables where schemaname = 'dorm'),
     rl as (select count(*)::text v from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'dorm' and c.relkind = 'r' and c.relrowsecurity),
     po as (select count(*)::text v from pg_policies where schemaname = 'dorm'),
     an as (select count(*)::text v from information_schema.role_table_grants
             where table_schema = 'dorm' and grantee = 'anon'),
     rp as (select count(*)::text v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname like 'dorm\_%'),
     bl as (select string_agg(x, ' · ' order by x) v from (
              select tenure || '=' || count(*)::text as x from dorm.building group by tenure) s),
     st as (select count(*)::text v from dorm.floor),
     ro as (select count(*)::text v from dorm.room),
     be as (select count(*)::text v from dorm.bed),
     cap as (
       select count(bd.id) reg,
              count(bd.id) filter (where bs.is_operable and rs.is_operable) opr,
              count(bd.id) filter (where bs.is_operable and rs.is_operable and bs.is_lettable and rs.is_lettable) let
         from dorm.room r
         join dorm.room_status rs on rs.code = r.status
         left join dorm.bed bd on bd.room_id = r.id
         left join dorm.bed_status bs on bs.code = bd.status
        where r.purpose = 'RESIDENTIAL'),
     oc as (select count(*)::text v from dorm.occupancy where state in ('ALLOCATED','MOVED_IN')),
     pe as (select count(*)::text v from dorm.person),
     lk as (select count(*)::text v from dorm.person where profile_id is not null or student_id is not null),
     mx as (select string_agg(x, ' · ' order by x) v from (
              select lvl || '=' || count(*)::text as x
                from (select case when building_id is not null then '1-epulet'
                                  when tenure is not null then '2-jogcim'
                                  else '3-globalis' end as lvl
                        from dorm.responsibility) z
               group by lvl) s),
     m1 as (select liable_party || '/' || route || '/' || source as v
              from dorm.resolve_responsibility((select id from dorm.building where code = 'BER-1'), 'APPLIANCE')),
     m2 as (select liable_party || '/' || route || '/' || source as v
              from dorm.resolve_responsibility((select id from dorm.building where code = 'KOLL-A'), 'APPLIANCE')),
     m3 as (select liable_party || '/' || route || '/' || source as v
              from dorm.resolve_responsibility((select id from dorm.building where code = 'BER-1'), 'FURNITURE')),
     iss as (select string_agg(x, ' · ' order by x) v from (
               select b.code || '=' || count(*)::text as x
                 from dorm.issue i join dorm.building b on b.id = i.building_id
                 join dorm.issue_status s on s.code = i.status
                where s.is_open group by b.code) q),
     ovd as (select count(*)::text v from dorm.issue i join dorm.issue_status s on s.code = i.status
              where s.is_open and i.due_at < now()),
     le as (select b.code || ': lejarat=' || l.ends_on::text || ' -> DONTESI DATUM=' || l.decision_due_on::text as v
              from dorm.lease l join dorm.building b on b.id = l.building_id where l.is_active limit 1),
     dp as (select string_agg(direction || '=' || cnt::text, ' · ' order by direction) v
              from (select direction, count(*) cnt from dorm.deposit group by direction) s),
     pm as (select count(*)::text v from dorm.pm_plan where is_legal_requirement)
select * from (
  values
   ( 1, 'dorm sema — tablak szama',                 (select v from t),  'strukturalis')
  ,( 2, 'RLS bekapcsolva (tabla)',                  (select v from rl), 'jogosultsag')
  ,( 3, 'dorm policy-k szama',                      (select v from po), 'jogosultsag')
  ,( 4, 'anon tabla-jogosultsag a dorm semaban',    (select v from an), 'jogosultsag — 0 a helyes')
  ,( 5, 'public.dorm_* RPC-k szama',                (select v from rp), 'felulet')
  ,( 6, 'Epuletek jogcim szerint',                  (select v from bl), 'torzsadat — sajat ES berelt')
  ,( 7, 'Szintek / szobak / ferohelyek',            (select v from st) || ' / ' || (select v from ro) || ' / ' || (select v from be), 'torzsadat')
  ,( 8, 'Kapacitas: nyilvantartott / uzemkepes / kiadhato',
        (select reg::text || ' / ' || opr::text || ' / ' || let::text from cap), 'a harom kapacitasfogalom')
  ,( 9, 'Elhelyezesek (aktiv)',                     (select v from oc), 'lakok')
  ,(10, 'Lakok / ebbol kotott (student vagy profil)', (select v from pe) || ' / ' || (select v from lk), 'szemelyazonossag')
  ,(11, 'Felelossegi matrix sorai szintenkent',     (select v from mx), 'a kert termek')
  ,(12, 'Matrix-feloldas: BER-1 + haztartasi gep',  (select v from m1), 'EPULET-szintu felulirasnak kell lennie')
  ,(13, 'Matrix-feloldas: KOLL-A + haztartasi gep', (select v from m2), 'JOGCIM-szintu alapertelmezes')
  ,(14, 'Matrix-feloldas: BER-1 + butor',           (select v from m3), 'a butor a MIENK a berelt epuletben is')
  ,(15, 'Nyitott hibak epuletenkent',               (select v from iss),'uzemeltetes')
  ,(16, 'Ebbol hataridon tuli',                     (select v from ovd),'uzemeltetes')
  ,(17, 'Berleti szerzodes dontesi datuma',         (select v from le), 'a lejarat NEM eleg — a dontesi datum kell')
  ,(18, 'Kauciok irany szerint',                    (select v from dp), 'ket iranyban')
  ,(19, 'Jogszabalyi kotelezettsegu PM-tervek',     (select v from pm), 'bizonylat-kockazat')
) as x(sorszam, ellenorzes, eredmeny, megjegyzes)
order by sorszam;


-- ============================================================================
-- 18. SZAKASZ — A HELYI REPLIKÁN MÉRT EREDMÉNY  (dokumentáció)
-- ============================================================================
-- Környezet: PGHOST=/tmp/upg2 PGPORT=55432 PGUSER=postgres, `fresh` adatbázis,
-- 01→25 migráció betöltve, Supabase-utánzattal (auth séma, auth.uid()/role()/
-- email() a request.jwt.claims-ből, anon/authenticated/service_role).
--
-- KÉTSZERI FUTÁS (psql -v ON_ERROR_STOP=1 -f 26_dorm.sql):
--   1. futás exit=0, 2. futás exit=0, a 17. szakasz eredménytáblája BETŰRE AZONOS.
--   52 dorm tábla · 52-n RLS · 102 dorm_ policy · 13 public.dorm_* RPC ·
--   anon jogosultság a dorm sémán: 0 (sem tábla, sem USAGE).
--   Regresszió nincs: a public séma továbbra is 29 tábla, a 86 rbac_ policy és
--   az echo séma 25 táblája érintetlen.
--
-- MÉRÉS 1 — ÁTFEDŐ FOGLALÁS UGYANARRA AZ ÁGYRA (KOLL-A/1/101-A):
--   1/a közvetlen INSERT (az RPC megkerülésével):
--       ERROR: conflicting key value violates exclusion constraint
--              "dorm_occupancy_no_overlap_excl"                      -> BUKOTT (helyes)
--   1/b ugyanez a public.dorm_assign() RPC-n át, KOLI_ADMIN jogosultsággal:
--       ERROR: DORM_BED_TAKEN: a(z) KOLL-A/1/101-A ferohely a kert
--              idoszakban mar foglalt. + HINT a szabad helyek lekérdezésére
--                                                                    -> BUKOTT (helyes)
--   1/c NEM átfedő időszak ugyanarra az ágyra: ok=true                -> ÁTMENT (helyes)
--
-- MÉRÉS 2 — LAKÓKÉNT MÁS SZOBÁJÁNAK LAKÓI (ammar@test.com, S1, KOLL-A/1/101-A):
--   dorm.occupancy látható sorok: 1 (ebből saját: 1)
--   MÁS szoba (KOLL-B/1/101) lakói, KÖZVETLEN room_id-vel:            0
--   dorm.person látható sorok: 1 · v_room_occupancy sorok: 0
--   a SAJÁT szobatárs (KOLL-A/1/101-B lakója) neve:                   (nincs)
--   public.dorm_my_placement(): KOLL-A/1/101                          -> a sajátját LÁTJA
--   public.dorm_free_beds():    DORM_FORBIDDEN                        -> BUKOTT (helyes)
--   public.dorm_issue_report() a SAJÁT szobájára: ok=true, P2,
--       felelős=UNIVERSITY, útvonal=EXTERNAL_VENDOR, mátrix_szint=TENURE
--   public.dorm_issue_report() MÁS épület szobájára:
--       DORM_FORBIDDEN: nincs jogosultsaga bejelenteni ebben az epuletben
--                                                                     -> BUKOTT (helyes)
--
-- MÉRÉS 3 — GONDNOKKÉNT A MÁSIK ÉPÜLET (agent@globalstudy.com, GONDNOK @ KOLL-A):
--   is_staff()=false, is_admin()=false — tehát TISZTÁN a hatókörös grant hat.
--   can_see_building: KOLL-A=true / KOLL-B=false
--   látható épületek: KOLL-A                (a KOLL-B és a BER-1 nem)
--   KOLL-B szobái / férőhelyei / lakói / hibajegyei / kulcsai, KÖZVETLEN
--     building_id-vel kérdezve:                                       0 / 0 / 0 / 0 / 0
--   saját (KOLL-A) lakói: 3 · v_room_occupancy: KOLL-A=3
--   dorm_occupancy_summary(KOLL-B): DORM_FORBIDDEN                    -> BUKOTT (helyes)
--   dorm_open_issues(KOLL-B):       DORM_FORBIDDEN                    -> BUKOTT (helyes)
--   dorm_free_beds(KOLL-B):         DORM_FORBIDDEN                    -> BUKOTT (helyes)
--   dorm_assign() a KOLL-B egyik ágyára: DORM_FORBIDDEN               -> BUKOTT (helyes)
--   dorm_free_beds(KOLL-A): 62 szabad férőhely                        -> ÁTMENT (helyes)
--
-- MÉRÉS 4 — KARBANTARTÓ (KARBANTARTO @ KOLL-A): a szobát igen, a lakót nem
--   v_room_operational (név nélküli nézet): 27 sor, ebből KOLL-B: 0
--   v_room_occupancy (ki hol lakik):         0
--   dorm.occupancy / dorm.person / dorm.key: 0 / 0 / 0
--   KOLL-A hibajegyei: 3 · KOLL-B hibajegyei: 0
--   -> a karbantartó pontosan azt látja, amire a munkájához szüksége van:
--      melyik szoba, milyen hiba — de NEM azt, hogy kinek a szobája.
--
-- EGY MÉRT ÉSZREVÉTEL A TESZTELÉSHEZ: a hatókör-mérést KÖZVETLEN UUID-vel kell
-- végezni. Egy `(select id from dorm.building where code='KOLL-B')` alkérdés a
-- korlátozott fiók alatt NULL-t ad (az RLS elrejti a sort), a NULL paraméter
-- pedig az RPC-kben "minden hatókörömbe eső épület" jelentésű — így a mérés
-- csendben a HELYES eredményt adná a ROSSZ okból.
-- ============================================================================
