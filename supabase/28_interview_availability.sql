-- ============================================================================
-- 28_interview_availability.sql — Interjú-elérhetőség, idősáv-hossz, kizárások
-- Neumann János Egyetem — UniPortal
-- Változat: 2026-08-25, HELYI POSTGRES REPLIKÁN MÉRVE (fresh, 01→26 betöltve)
-- ELŐFELTÉTEL: 11_rbac_additive.sql (is_admin/is_approved/has_role/my_*),
--              01_schema_and_seed.sql (public."interviewSlots").
-- IDEMPOTENS: kétszer lefuttatva ugyanazt az állapotot adja (mérve).
-- ============================================================================
--
-- ---------------------------------------------------------------------------
-- MIÉRT
-- ---------------------------------------------------------------------------
-- A tesztelő kollégák három dolgot kifogásoltak az interjú-foglalásban:
--
--   (1) "Az idősáv 30 perc, nekünk 15 kell." — MÉRVE: a sávhossz sehol nincs
--       kiszámolva, a public."interviewSlots" HÁROM beégetett magvetett sora
--       hordozza (01_schema_and_seed.sql 166–169: 09:00–09:30, 10:00–10:30,
--       15:00–15:30), a jelentkezői útvonalon pedig egy statikus JS tömb
--       (app.jsx SLOTS, 5 elem, nap+óra szöveggel). Nincs se generátor, se
--       hossz-fogalom. Ezért a hosszt nem "átírni" kell, hanem BEVEZETNI —
--       és mivel a megrendelő szerint ez a szám változni fog (15 → 20 → 10),
--       BEÁLLÍTÁSBÓL jön, nem konstansból.
--
--   (2) "Ma bárki foglalhat 8-tól 4-ig." — MÉRVE: valójában még ennyi sincs;
--       a foglalható sávok halmaza egy magvetett lista, amit senki nem tud
--       szerkeszteni. Az interjúztatónak NINCS elérhetőségi naptára. Ezért
--       jön a heti ismétlődő elérhetőség (interview_availability), és a
--       foglalható sávok EBBŐL generálódnak.
--
--   (3) "Ebédszünetre és szabadságra is lehet foglalni." — MÉRVE: a foglalás
--       útja ma egyetlen UPDATE (app.jsx:666 → sbUpdate('interviewSlots', …,
--       {status:'Booked'})), amire a 11_rbac_additive.sql 10.2 triggere csak
--       a foglaló SZEMÉLYAZONOSSÁGÁT kényszeríti rá — az IDŐPONTOT semmi nem
--       ellenőrzi. A kizárás ezért NEM lehet felületi szűrés: trigger + RPC.
--
-- ---------------------------------------------------------------------------
-- AZ ÖT SZERKEZETI DÖNTÉS
-- ---------------------------------------------------------------------------
--
--  1. A `public` SÉMÁBAN MARADUNK, `interview_` ELŐTAGGAL — nem új séma.
--     A 26_dorm.sql azért kapott saját sémát, mert 30+ táblát hozott; ez a
--     modul ÖTÖT. Új séma új Supabase-beállítást (Exposed schemas) igényelne,
--     és a modul lelke — a public."interviewSlots" — amúgy is a publicban van.
--
--  2. A SÁVOK NEM ANYAGIASULNAK ELŐRE. A foglalható idősávot a
--     public.interview_free_slots() SZÁMOLJA az elérhetőségből, a kizárásokból
--     és a már lefoglalt sorokból. Ha előre legyártanánk őket, a sávhossz
--     megváltoztatása vagy egy utólag felvett szabadság több ezer sort tenne
--     hazuggá. Sor csak a FOGLALÁS pillanatában keletkezik.
--
--  3. A MEGLÉVŐ FOGLALÁSOK SÉRTHETETLENEK. A régi (magvetett) sorok
--     "interviewerKey"-e NULL marad, és minden új ellenőrzés — trigger,
--     átfedés-tiltás — CSAK a nem-NULL kulcsú sorokra hat. A modul így nem
--     borítja fel a már kiadott időpontokat, se a demó adatot.
--
--  4. NEM BŐVÍTJÜK A profiles.role ENUMOT. MÉRVE (app.jsx filteredMenuItems):
--     az utolsó ág `return false`, egy ismeretlen szerepkör NULLA menüpontot
--     kapna. Az "interjúztató" ezért NÉVSOR (interview_interviewer), az
--     echo.role_grant / dorm.role_grant mintájára: az admin felveszi rá a
--     kollégát, és onnantól az illető a SAJÁT naptárát szerkeszti.
--
--  5. AZ IDŐZÓNA IS BEÁLLÍTÁS. Az elérhetőség helyi időben értelmes ("kedd
--     10:00"), a foglalás timestamptz. A kettő közti átváltás egyetlen
--     helyen, a `timezone` beállításból történik (alapértelmezés:
--     Europe/Budapest), különben a szerver TimeZone-ja szivárogna be az
--     üzleti szabályba.
--
-- ---------------------------------------------------------------------------
-- AMIT A MODUL NEM CSINÁL
-- ---------------------------------------------------------------------------
-- Nem naptár-szinkron (Teams/Outlook): a felület ma is csak jelzi, hogy erre
-- elő van készítve. Nem kezel több telephelyet és nem foglal termet — az
-- interjú online. Nem küld e-mailt: az értesítés a meglévő üzenet-rétegé.
--
-- ---------------------------------------------------------------------------
-- MI VAN A FÁJLBAN
-- ---------------------------------------------------------------------------
--   1. beállítások (interview_setting) + interview_slot_minutes() / _tz()
--   2. interjúztató-névsor (interview_interviewer) + interview_name()
--   3. heti elérhetőség (interview_availability)
--   4. kizárások: interview_break (ismétlődő) és interview_absence (eseti)
--   5. "interviewSlots"."interviewerKey" — az új sorok kulcsa
--   6. jogosultság: interview_is_interviewer() / interview_can_edit()
--   7. RLS mind az öt táblán
--   8. interview_free_slots() — a szabad sávok SZÁMÍTÁSA
--   9. interview_slot_blocked_reason() + interviewslots_availability_trg
--  10. a 27-es státuszkapu kiterjesztése az INSERT útra
--  11. interview_book() — a foglalás egyetlen belépési pontja
--  12-14. felület-RPC-k (kontextus, naptár, szerkesztés, névsor, beállítás)
--  15. induló adat (ebédszünet, névsor, munkarend) — csak üres táblára
--
-- ---------------------------------------------------------------------------
-- MÉRVE (helyi replika, 01→26 + 27 + 28, kétszer lefuttatva)
-- ---------------------------------------------------------------------------
--   kedd 10:00–14:00 elérhetőség + globális ebédszünet 12:00–13:00
--     → interview_free_slots(): 12 sáv, 10:00–12:00 és 13:00–14:00 között,
--       15 perces bontásban. A 12:00–13:00 KIESIK.
--   csütörtökre bejelentett szabadság → aznap 0 szabad sáv.
--   jelentkezői foglalás 12:15-re  → ERROR: „A kért időpont kizárt idősávra
--       esik: Ebédszünet.”                                       (42501)
--   jelentkezői foglalás a szabadság idejére → ERROR: „Az interjúztató a kért
--       időpontban nem elérhető (bejelentett távollét)."          (42501)
--   jelentkezői foglalás 08:00-ra → ERROR: „…kívül esik az interjúztató
--       elérhetőségén."                                           (42501)
--   ügyintéző KÖZVETLEN INSERT-je 12:30-ra (az RPC megkerülésével)
--       → ugyanaz a hiba, a triggerből.
--   slot_minutes 15 → 30: a generált sávok 30 percesek lesznek, a MÁR KIADOTT
--       10:30–10:45 foglalás hossza változatlan.
--   nem-admin slot_minutes írása → ERROR (42501).
--   interjúztató MÁS naptárának írása → ERROR (42501).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. BEÁLLÍTÁSOK — public.interview_setting
-- ---------------------------------------------------------------------------
-- Kulcs–érték tábla, mert a négy beállítás közül három szám, egy szöveg, és
-- a megrendelő mindegyiket menet közben akarja állítani. A típusolvasást a
-- két segédfüggvény (…_int / …_text) végzi, hibás értéknél az ALAPÉRTELMEZÉS
-- nyer — egy elgépelt beállítás nem állíthatja meg a foglalást.

create table if not exists public.interview_setting (
  key         text primary key,
  value       text        not null,
  label       text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

comment on table public.interview_setting is
  'Interjú-foglalás beállításai (sávhossz, időzóna, előfoglalási ablak).';

insert into public.interview_setting (key, value, label) values
  ('slot_minutes',         '15',               'Idősáv hossza (perc)'),
  ('timezone',             'Europe/Budapest',  'Időzóna'),
  ('booking_horizon_days', '30',               'Előre foglalható napok száma'),
  ('lead_time_hours',      '2',                'Legkorábbi foglalás mostantól (óra)')
on conflict (key) do nothing;

create or replace function public.interview_setting_text(p_key text, p_default text)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce(nullif(trim((select s.value from public.interview_setting s where s.key = p_key)), ''), p_default);
$fn$;

create or replace function public.interview_setting_int(p_key text, p_default integer)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v text;
  n integer;
begin
  select s.value into v from public.interview_setting s where s.key = p_key;
  if v is null then return p_default; end if;
  begin
    n := trim(v)::integer;
  exception when others then
    return p_default;                    -- elgépelt beállítás: az alapérték nyer
  end;
  if n is null or n <= 0 then return p_default; end if;
  return n;
end;
$fn$;

-- A sávhossz EGYETLEN forrása az egész rendszerben (SQL és felület egyaránt
-- innen kérdezi). 5 és 240 perc közé szorítva: ennél rövidebb sáv nem interjú,
-- ennél hosszabbnál a napi generálás értelmetlen.
create or replace function public.interview_slot_minutes()
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select least(greatest(public.interview_setting_int('slot_minutes', 15), 5), 240);
$fn$;

create or replace function public.interview_tz()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select public.interview_setting_text('timezone', 'Europe/Budapest');
$fn$;

-- ---------------------------------------------------------------------------
-- 2. INTERJÚZTATÓ-NÉVSOR — public.interview_interviewer
-- ---------------------------------------------------------------------------
-- Nem szerepkör, hanem NÉVSOR (4. szerkezeti döntés). Aki rajta van és aktív,
-- annak (a) megjelenhetnek a sávjai a jelentkezőnél, (b) szerkesztheti a saját
-- naptárát. A `display_name` csak felülbírálás: alapból a profiles.name jön,
-- de a felvételi levélen ma is "Dr. Kovács István" formátum szerepel, és ezt
-- a névsorban lehet igazítani anélkül, hogy a profilt átírnánk.

create table if not exists public.interview_interviewer (
  interviewer   uuid primary key references public.profiles(id) on delete cascade,
  active        boolean     not null default true,
  display_name  text,
  note          text,
  created_at    timestamptz not null default now(),
  created_by    uuid
);

comment on table public.interview_interviewer is
  'Kik interjúztatnak. NEM profiles.role — hatókörös névsor (lásd 4. döntés).';

create index if not exists interview_interviewer_active_idx
  on public.interview_interviewer (active);

-- A megjelenítendő név egy helyen dől el, hogy a generált sáv, a foglalás és
-- a lista ne mondjon háromfélét.
create or replace function public.interview_name(p_interviewer uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce(
           nullif(trim((select i.display_name from public.interview_interviewer i
                         where i.interviewer = p_interviewer)), ''),
           nullif(trim((select p.name from public.profiles p where p.id = p_interviewer)), ''),
           (select p.email from public.profiles p where p.id = p_interviewer),
           'Interjúztató');
$fn$;

-- ---------------------------------------------------------------------------
-- 3. HETI ISMÉTLŐDŐ ELÉRHETŐSÉG — public.interview_availability
-- ---------------------------------------------------------------------------
-- "kedd 10:00–12:00, csütörtök 14:00–16:00". A hétköznap ISO szerint 1=hétfő
-- … 7=vasárnap (extract(isodow) ezt adja, és a JS getDay()-ből egyetlen
-- `d===0?7:d` a váltás — ezt a felület is így csinálja).
-- A valid_from/valid_to azért kell, mert a félév elején és végén más a naptár:
-- a régi sávot nem törölni kell (a múltbeli foglalás magyarázata odavész),
-- hanem LEZÁRNI.

create table if not exists public.interview_availability (
  id          uuid        primary key default gen_random_uuid(),
  interviewer uuid        not null references public.profiles(id) on delete cascade,
  weekday     smallint    not null,
  start_time  time        not null,
  end_time    time        not null,
  valid_from  date,
  valid_to    date,
  active      boolean     not null default true,
  note        text,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  constraint interview_availability_weekday_ck check (weekday between 1 and 7),
  constraint interview_availability_span_ck    check (end_time > start_time),
  constraint interview_availability_valid_ck   check (valid_to is null or valid_from is null or valid_to >= valid_from)
);

comment on table public.interview_availability is
  'Heti ismétlődő elérhetőségi sávok interjúztatónként (1=hétfő … 7=vasárnap).';

create index if not exists interview_availability_lookup_idx
  on public.interview_availability (interviewer, weekday) where active;

-- ---------------------------------------------------------------------------
-- 4. KIZÁRÁSOK — public.interview_break (ismétlődő) és
--    public.interview_absence (eseti)
-- ---------------------------------------------------------------------------
-- KÉT TÁBLA, NEM EGY, mert a két fogalom élettartama és jogosultsága más:
-- az ebédszünet intézményi szabály (globális sor, interviewer IS NULL),
-- évekig él és nincs indoklása; a szabadság személyes, dátumhoz kötött és
-- INDOKLÁSA van, ami érzékeny adat (lásd a 7. pont RLS-ét: az indoklást csak
-- az érintett és az admin látja, a jelentkező soha).
--
-- interview_break.interviewer IS NULL = mindenkire vonatkozik.
-- interview_break.weekday     IS NULL = a hét minden napján.

create table if not exists public.interview_break (
  id          uuid        primary key default gen_random_uuid(),
  interviewer uuid        references public.profiles(id) on delete cascade,
  weekday     smallint,
  start_time  time        not null,
  end_time    time        not null,
  label       text,
  active      boolean     not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  constraint interview_break_weekday_ck check (weekday is null or weekday between 1 and 7),
  constraint interview_break_span_ck    check (end_time > start_time)
);

comment on table public.interview_break is
  'Ismétlődő kizárás (pl. ebédszünet). interviewer IS NULL = mindenkire, weekday IS NULL = minden nap.';

create index if not exists interview_break_lookup_idx
  on public.interview_break (interviewer, weekday) where active;

create table if not exists public.interview_absence (
  id          uuid        primary key default gen_random_uuid(),
  interviewer uuid        not null references public.profiles(id) on delete cascade,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  reason      text,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  constraint interview_absence_span_ck check (ends_at > starts_at)
);

comment on table public.interview_absence is
  'Eseti kizárás (szabadság, kiküldetés) dátumtartománnyal és indoklással.';

create index if not exists interview_absence_lookup_idx
  on public.interview_absence (interviewer, starts_at, ends_at);

-- ---------------------------------------------------------------------------
-- 5. A public."interviewSlots" BŐVÍTÉSE — "interviewerKey"
-- ---------------------------------------------------------------------------
-- MÉRVE: a meglévő "interviewerId" oszlop TEXT, és a magvetett sorokban 'U1' /
-- 'U2' áll — a régi, Supabase előtti users tábla kulcsa. Ezt NEM írjuk át
-- uuid-ra: a demó adat és a már kiadott időpontok hivatkoznak rá, és a
-- konverzió minden 'U1' sort elveszejtene.
--
-- Helyette egy ÚJ, nullable oszlop jön, ami a profiles(id)-re mutat. A
-- 3. szerkezeti döntés ezen áll: minden új ellenőrzés CSAK a nem-NULL kulcsú
-- sorokra hat, tehát a három magvetett sor változatlanul foglalható marad,
-- a modul mégis szigorú mindenre, amit ő maga hozott létre.

do $$
begin
  if to_regclass('public."interviewSlots"') is null then
    raise exception 'MEGTAGADVA: a public."interviewSlots" tábla hiányzik (01_schema_and_seed.sql).';
  end if;
end $$;

alter table public."interviewSlots"
  add column if not exists "interviewerKey" uuid references public.profiles(id) on delete set null;

comment on column public."interviewSlots"."interviewerKey" is
  'Az interjúztató profiles.id-ja. NULL a 01-es magvetett soroknál — azokra a 28-as ellenőrzések nem hatnak.';

create index if not exists interviewslots_interviewerkey_idx
  on public."interviewSlots" ("interviewerKey", "startTime")
  where "interviewerKey" is not null;

-- ---------------------------------------------------------------------------
-- 6. JOGOSULTSÁG — ki szerkesztheti kinek a naptárát
-- ---------------------------------------------------------------------------
-- Egyetlen szabály, három helyen használva (RLS, RPC, felület), ezért
-- függvényben: az ADMIN bárkiét, az interjúztató CSAK a sajátját.

create or replace function public.interview_is_interviewer()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select exists (
    select 1 from public.interview_interviewer i
     where i.interviewer = auth.uid() and i.active
  );
$fn$;

comment on function public.interview_is_interviewer() is
  'Rajta van-e a hívó az aktív interjúztató-névsoron.';

create or replace function public.interview_can_edit(p_interviewer uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce(public.is_admin(), false)
      or (auth.uid() is not null and auth.uid() = p_interviewer and public.interview_is_interviewer());
$fn$;

comment on function public.interview_can_edit(uuid) is
  'Az admin bárkinek, az aktív interjúztató kizárólag a SAJÁT naptárát szerkesztheti.';

grant execute on function public.interview_is_interviewer()  to authenticated;
grant execute on function public.interview_can_edit(uuid)    to authenticated;
grant execute on function public.interview_setting_text(text, text) to authenticated;
grant execute on function public.interview_setting_int(text, integer) to authenticated;
grant execute on function public.interview_slot_minutes()    to authenticated, anon;
grant execute on function public.interview_tz()              to authenticated, anon;
grant execute on function public.interview_name(uuid)        to authenticated;

-- ---------------------------------------------------------------------------
-- 7. RLS — ki lát és ki ír
-- ---------------------------------------------------------------------------
-- A négy új tábla mind RLS alatt van. A FOGLALÁSI útvonal ezt NEM kerüli meg
-- általa: a szabad sávokat SECURITY DEFINER függvény számolja, a jelentkezőnek
-- tehát nem kell olvasnia se az elérhetőséget, se a kizárásokat. Ez szándékos —
-- a szabadság INDOKLÁSA ("betegszabadság") érzékeny adat, és a jelentkezőnek
-- semmi köze hozzá.

alter table public.interview_setting      enable row level security;
alter table public.interview_interviewer  enable row level security;
alter table public.interview_availability enable row level security;
alter table public.interview_break        enable row level security;
alter table public.interview_absence      enable row level security;

-- (a) BEÁLLÍTÁSOK: mindenki jóváhagyott olvassa (a felület a sávhosszt
--     megjeleníti), írni csak az admin ír.
drop policy if exists interview_setting_read  on public.interview_setting;
create policy interview_setting_read on public.interview_setting
  for select to authenticated using (public.is_approved());

drop policy if exists interview_setting_write on public.interview_setting;
create policy interview_setting_write on public.interview_setting
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- (b) NÉVSOR: olvasható (a foglalásnál az interjúztató nevét ki kell írni),
--     írható csak adminnak.
drop policy if exists interview_interviewer_read  on public.interview_interviewer;
create policy interview_interviewer_read on public.interview_interviewer
  for select to authenticated using (public.is_approved());

drop policy if exists interview_interviewer_write on public.interview_interviewer;
create policy interview_interviewer_write on public.interview_interviewer
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- (c) ELÉRHETŐSÉG: az érintett és az admin lát és ír. Az ügyintéző is LÁT
--     (a felvételi iroda telefonon is egyeztet), de nem ír bele — a naptár
--     az interjúztatóé.
drop policy if exists interview_availability_read  on public.interview_availability;
create policy interview_availability_read on public.interview_availability
  for select to authenticated
  using (public.is_staff() or interviewer = auth.uid());

drop policy if exists interview_availability_write on public.interview_availability;
create policy interview_availability_write on public.interview_availability
  for all to authenticated
  using (public.interview_can_edit(interviewer))
  with check (public.interview_can_edit(interviewer));

-- (d) ISMÉTLŐDŐ KIZÁRÁS: a GLOBÁLIS sor (interviewer IS NULL, pl. az ebédszünet)
--     mindenki ügyintézőnek látszik, de csak az admin írja — intézményi szabály.
--     A személyes sor az érintetté.
drop policy if exists interview_break_read  on public.interview_break;
create policy interview_break_read on public.interview_break
  for select to authenticated
  using (public.is_staff() or interviewer is null or interviewer = auth.uid());

drop policy if exists interview_break_write on public.interview_break;
create policy interview_break_write on public.interview_break
  for all to authenticated
  using (case when interviewer is null then public.is_admin()
              else public.interview_can_edit(interviewer) end)
  with check (case when interviewer is null then public.is_admin()
                   else public.interview_can_edit(interviewer) end);

-- (e) SZABADSÁG: az INDOKLÁS miatt SZŰKEBB kör, mint a többinél — csak az
--     érintett és az admin. Az ügyintéző itt SEM lát: a szabad sávok listája
--     amúgy is megmondja neki, mikor nem lehet foglalni, az OKOT nem kell
--     tudnia. (Ez a modul egyetlen helye, ahol az is_staff() nem elég.)
drop policy if exists interview_absence_read  on public.interview_absence;
create policy interview_absence_read on public.interview_absence
  for select to authenticated
  using (public.is_admin() or interviewer = auth.uid());

drop policy if exists interview_absence_write on public.interview_absence;
create policy interview_absence_write on public.interview_absence
  for all to authenticated
  using (public.interview_can_edit(interviewer))
  with check (public.interview_can_edit(interviewer));

grant select on public.interview_setting, public.interview_interviewer to authenticated;
grant select, insert, update, delete
  on public.interview_setting, public.interview_interviewer,
     public.interview_availability, public.interview_break, public.interview_absence
  to authenticated;

-- ---------------------------------------------------------------------------
-- 8. A SZABAD SÁVOK — public.interview_free_slots()
-- ---------------------------------------------------------------------------
-- A 2. szerkezeti döntés magja: a foglalható idősáv nem tárolt sor, hanem
-- SZÁMÍTÁS. Négy dolgot von ki az elérhetőségből:
--   (1) a sávhosszra fel nem osztható maradékot (a generate_series az utolsó
--       teljes sávnál megáll — 10:00–11:10 és 15 perc esetén az utolsó sáv
--       10:45–11:00, a maradék 10 perc nem foglalható),
--   (2) az ismétlődő kizárásokat (ebédszünet),
--   (3) az eseti kizárásokat (szabadság),
--   (4) a már kiadott időpontokat.
-- Plusz a `lead_time_hours`: a mostantól számított néhány órán belüli sáv
-- nem jelenik meg, mert az interjúztatónak fel kell készülnie.
--
-- A KIMENŐ OSZLOPOK NEVE SZÁNDÉKOSAN `iv_` / `slot_` ELŐTAGOS: a RETURNS TABLE
-- oszlopnevei plpgsql-ben VÁLTOZÓK, és egy `interviewer` nevű kimenet
-- kétértelművé tenné a lekérdezés minden `interviewer` oszlopát.

create or replace function public.interview_free_slots(
  p_from        date default null,
  p_to          date default null,
  p_interviewer uuid default null
)
returns table (
  iv_id      uuid,
  iv_name    text,
  slot_start timestamptz,
  slot_end   timestamptz,
  slot_day   date,
  slot_label text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_tz       text    := public.interview_tz();
  v_min      integer := public.interview_slot_minutes();
  v_horizon  integer := public.interview_setting_int('booking_horizon_days', 30);
  v_lead     integer := public.interview_setting_int('lead_time_hours', 2);
  v_from     date;
  v_to       date;
  v_earliest timestamptz := now() + make_interval(hours => v_lead);
begin
  v_from := coalesce(p_from, (now() at time zone v_tz)::date);
  v_to   := coalesce(p_to,   v_from + v_horizon);
  if v_to < v_from then v_to := v_from; end if;
  -- A horizont FELSŐ korlát, nem javaslat: a felület kérhet két évet, nem kap.
  if v_to > v_from + v_horizon then v_to := v_from + v_horizon; end if;

  return query
  with days as (
    select d::date as day, extract(isodow from d)::smallint as dow
      from generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') d
  ),
  av as (
    select a.interviewer as ikey, a.weekday, a.start_time, a.end_time,
           a.valid_from, a.valid_to
      from public.interview_availability a
      join public.interview_interviewer i
        on i.interviewer = a.interviewer and i.active
     where a.active
       and (p_interviewer is null or a.interviewer = p_interviewer)
  ),
  cand as (
    select av.ikey,
           d.day,
           d.dow,
           gs                                   as local_start,
           gs + make_interval(mins => v_min)    as local_end
      from days d
      join av
        on av.weekday = d.dow
       and (av.valid_from is null or d.day >= av.valid_from)
       and (av.valid_to   is null or d.day <= av.valid_to)
      cross join lateral generate_series(
             d.day + av.start_time,
             d.day + av.end_time - make_interval(mins => v_min),
             make_interval(mins => v_min)) as gs
  ),
  cand_tz as (
    select c.ikey, c.day, c.dow, c.local_start, c.local_end,
           (c.local_start at time zone v_tz) as st,
           (c.local_end   at time zone v_tz) as en
      from cand c
  )
  select distinct
         c.ikey,
         public.interview_name(c.ikey),
         c.st,
         c.en,
         c.day,
         to_char(c.local_start, 'HH24:MI') || '–' || to_char(c.local_end, 'HH24:MI')
    from cand_tz c
   where c.st >= v_earliest
     and not exists (
           select 1 from public.interview_break b
            where b.active
              and (b.interviewer is null or b.interviewer = c.ikey)
              and (b.weekday is null or b.weekday = c.dow)
              and c.local_start < (c.day + b.end_time)
              and c.local_end   > (c.day + b.start_time))
     and not exists (
           select 1 from public.interview_absence ab
            where ab.interviewer = c.ikey
              and c.st < ab.ends_at and c.en > ab.starts_at)
     and not exists (
           select 1 from public."interviewSlots" s
            where s."interviewerKey" = c.ikey
              and coalesce(s.status, '') <> 'Cancelled'
              and c.st < s."endTime" and c.en > s."startTime")
   order by 3, 2;
end;
$fn$;

comment on function public.interview_free_slots(date, date, uuid) is
  'A ténylegesen foglalható idősávok: elérhetőség mínusz ebédszünet, szabadság és a már kiadott időpontok.';

grant execute on function public.interview_free_slots(date, date, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. A KIZÁRÁS KIKÉNYSZERÍTÉSE — nem felületi szűrés, hanem trigger
-- ---------------------------------------------------------------------------
-- A felület csak a szabad sávokat kínálja fel, de a foglalás útja a
-- PostgREST-en át közvetlenül is járható (a jelentkező böngészőjéből, a saját
-- JWT-jével). Ezért ugyanaz a szabály ITT is ott áll, az adatbázisban.
--
-- A függvény SZÖVEGET ad vissza, nem logikai értéket: a felület ugyanezt a
-- mondatot mutatja meg, és így az ok is kiderül ("ebédszünet", "szabadság",
-- "ütközik egy már kiadott időponttal") — nem csak az, hogy nem lehet.

create or replace function public.interview_slot_blocked_reason(
  p_interviewer  uuid,
  p_start        timestamptz,
  p_end          timestamptz,
  p_exclude_slot text default null
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_tz    text := public.interview_tz();
  v_ls    timestamp;
  v_le    timestamp;
  v_day   date;
  v_dow   smallint;
  v_label text;
begin
  -- A 3. szerkezeti döntés: kulcs nélküli (magvetett) sorra nem szólunk bele.
  if p_interviewer is null then return null; end if;
  if p_start is null or p_end is null then
    return 'Az idősáv kezdete és vége is kötelező.';
  end if;
  if p_end <= p_start then
    return 'Az idősáv vége nem lehet a kezdete előtt.';
  end if;

  v_ls  := (p_start at time zone v_tz);
  v_le  := (p_end   at time zone v_tz);
  v_day := v_ls::date;
  v_dow := extract(isodow from v_day)::smallint;

  if not exists (select 1 from public.interview_interviewer i
                  where i.interviewer = p_interviewer and i.active) then
    return 'A választott interjúztató nem szerepel az aktív interjúztatók között.';
  end if;

  -- (a) benne van-e EGÉSZÉBEN egy elérhetőségi sávban
  if not exists (
       select 1 from public.interview_availability a
        where a.interviewer = p_interviewer
          and a.active
          and a.weekday = v_dow
          and (a.valid_from is null or v_day >= a.valid_from)
          and (a.valid_to   is null or v_day <= a.valid_to)
          and v_ls >= (v_day + a.start_time)
          and v_le <= (v_day + a.end_time)) then
    return 'A kért időpont kívül esik az interjúztató elérhetőségén.';
  end if;

  -- (b) ismétlődő kizárás — ebédszünet
  select coalesce(nullif(trim(b.label), ''), 'kizárt idősáv') into v_label
    from public.interview_break b
   where b.active
     and (b.interviewer is null or b.interviewer = p_interviewer)
     and (b.weekday is null or b.weekday = v_dow)
     and v_ls < (v_day + b.end_time)
     and v_le > (v_day + b.start_time)
   limit 1;
  if v_label is not null then
    return 'A kért időpont kizárt idősávra esik: ' || v_label || '.';
  end if;

  -- (c) eseti kizárás — szabadság. Az INDOKLÁST nem írjuk ki: a hibaüzenetet a
  --     jelentkező is látja, az ok pedig személyes adat (lásd a 7/e pontot).
  if exists (
       select 1 from public.interview_absence ab
        where ab.interviewer = p_interviewer
          and p_start < ab.ends_at
          and p_end   > ab.starts_at) then
    return 'Az interjúztató a kért időpontban nem elérhető (bejelentett távollét).';
  end if;

  -- (d) ütközés egy már kiadott sávval
  if exists (
       select 1 from public."interviewSlots" s
        where s."interviewerKey" = p_interviewer
          and (p_exclude_slot is null or s.id <> p_exclude_slot)
          and coalesce(s.status, '') <> 'Cancelled'
          and p_start < s."endTime"
          and p_end   > s."startTime") then
    return 'A kért időpont ütközik egy már kiadott interjú-időponttal.';
  end if;

  return null;
end;
$fn$;

comment on function public.interview_slot_blocked_reason(uuid, timestamptz, timestamptz, text) is
  'NULL, ha az idősáv foglalható; egyébként a magyar nyelvű indok. A trigger és a felület ugyanezt használja.';

grant execute on function public.interview_slot_blocked_reason(uuid, timestamptz, timestamptz, text) to authenticated;

-- A TRIGGER. Akkor ellenőriz, ha (i) új sor születik, (ii) az időpont vagy az
-- interjúztató változik, vagy (iii) a sor MOST kerül 'Booked' állapotba. Ez a
-- harmadik eset azért kell, mert egy már kiírt, szabad sávot utólag is
-- lefedhet egy bejelentett szabadság — a foglalásnak ilyenkor is el kell buknia.
-- A lemondás, a Teams-link írása és minden egyéb mező érintetlen marad.
create or replace function public.interviewslots_availability_gate()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_reason  text;
  v_recheck boolean := true;
begin
  if new."interviewerKey" is null then
    return new;                       -- 3. döntés: a magvetett sorok érintetlenek
  end if;

  if tg_op = 'UPDATE' then
    v_recheck := (old."interviewerKey" is distinct from new."interviewerKey")
              or (old."startTime"      is distinct from new."startTime")
              or (old."endTime"        is distinct from new."endTime")
              or (coalesce(new.status, '') = 'Booked' and coalesce(old.status, '') <> 'Booked');
  end if;
  if not v_recheck then return new; end if;

  v_reason := public.interview_slot_blocked_reason(
                new."interviewerKey", new."startTime", new."endTime", new.id);
  if v_reason is not null then
    raise exception '%', v_reason
      using errcode = '42501',
            hint    = 'Az elérhetőséget, az ebédszünetet és a szabadságot az Interjú Foglalás → Elérhetőség fülön lehet szerkeszteni.';
  end if;
  return new;
end;
$fn$;

-- A NÉV ábécében az 'interviewslots_force_owner_trg' ELŐTT áll, tehát ez fut
-- először. Nem baj: ez a kapu az IDŐPONTOT nézi, nem a foglaló személyét.
drop trigger if exists interviewslots_availability_trg on public."interviewSlots";
create trigger interviewslots_availability_trg
  before insert or update on public."interviewSlots"
  for each row execute function public.interviewslots_availability_gate();

-- ---------------------------------------------------------------------------
-- 10. A 27-ES KAPU KITERJESZTÉSE AZ INSERT-RE
-- ---------------------------------------------------------------------------
-- MÉRVE: a 27_interview_gate.sql triggere `before update` — mert akkor a
-- foglalás egy meglévő, magvetett sor ÁTÍRÁSA volt. A 2. szerkezeti döntés
-- után viszont a foglalás ÚJ SORT hoz létre, és az INSERT-re a 27-es kapu nem
-- fut le. A lyukat itt zárjuk be, a 27-es fájl érintése nélkül: külön trigger,
-- ugyanazokra a 27-es függvényekre támaszkodva — ha azok megvannak.
-- Ha a 27-es migráció nem futott le, ez a rész CSENDBEN kimarad, és a modul
-- attól még működik (csak a státusz-kapu nélkül).

create or replace function public.interviewslots_gate_on_insert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_required text;
  v_status   text;
  v_label    text;
begin
  if coalesce(new.status, '') <> 'Booked' then return new; end if;
  if to_regprocedure('public.interview_gate_required_status()') is null
     or to_regprocedure('public.student_status_of(text)') is null then
    return new;                                   -- a 27-es migráció nem futott le
  end if;

  execute 'select public.interview_gate_required_status()' into v_required;

  if nullif(new."studentId", '') is null then
    raise exception
      'Az interjú-foglaláshoz be kell kötni a fiókot egy jelentkezői sorhoz (profiles."studentId" → students.id). Kérjük, forduljon a Külügyi Irodához.'
      using errcode = '42501';
  end if;

  execute 'select public.student_status_of($1)' into v_status using new."studentId";
  if v_status is null then
    raise exception 'Az interjú-foglalás alanya (%) nem szerepel a jelentkezők között.', new."studentId"
      using errcode = '42501';
  end if;
  if v_status <> v_required then
    select coalesce(ss.label_hu, v_status) into v_label
      from public.student_status ss where ss.code = v_status;
    raise exception
      'Interjú-időpontot csak a dokumentum-ellenőrzésen túljutott jelentkező foglalhat. A jelentkező jelenlegi státusza: "%" (%), a foglaláshoz szükséges: "%".',
      coalesce(v_label, v_status), v_status, v_required
      using errcode = '42501';
  end if;
  return new;
end;
$fn$;

drop trigger if exists interviewslots_gate_ins_trg on public."interviewSlots";
create trigger interviewslots_gate_ins_trg
  before insert on public."interviewSlots"
  for each row execute function public.interviewslots_gate_on_insert();

-- ---------------------------------------------------------------------------
-- 11. FOGLALÁS — public.interview_book()
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER, mert a jelentkezőnek a 11-es RLS szerint NINCS INSERT joga
-- a public."interviewSlots"-ra (`rbac_interviewslots_insert … is_staff()`), a
-- 2. döntés óta viszont a foglalás új sort ír. A definer-jog NEM nyit kaput: a
-- két trigger (idő- és státusz-kapu) az INSERT-en így is lefut, és a függvény
-- maga is ellenőrzi az időpontot, mielőtt írna.

create or replace function public.interview_book(
  p_interviewer uuid,
  p_start       timestamptz,
  p_student_id  text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_min     integer := public.interview_slot_minutes();
  v_end     timestamptz;
  v_sid     text;
  v_sname   text;
  v_reason  text;
  v_lead    integer := public.interview_setting_int('lead_time_hours', 2);
  v_id      text;
begin
  if not public.is_approved() then
    raise exception 'Jóváhagyásra váró fiókkal nem lehet interjút foglalni.' using errcode = '42501';
  end if;
  if p_interviewer is null or p_start is null then
    raise exception 'Hiányzó interjúztató vagy időpont.' using errcode = '22023';
  end if;

  v_end := p_start + make_interval(mins => v_min);

  -- Kit foglalunk be? Az ügyintéző megadhatja, a jelentkező NEM: neki a saját
  -- bekötött jelentkezői sora jön (ugyanaz a szabály, mint a 11.10.2-ben).
  if public.is_staff() and nullif(p_student_id, '') is not null then
    v_sid := p_student_id;
  else
    v_sid := public.my_student_id();
  end if;
  if nullif(v_sid, '') is null then
    raise exception
      'Az interjú-foglaláshoz be kell kötni a fiókot egy jelentkezői sorhoz (profiles."studentId" → students.id). Kérjük, forduljon a Külügyi Irodához.'
      using errcode = '42501';
  end if;
  select s.name into v_sname from public.students s where s.id = v_sid;

  if p_start < now() + make_interval(hours => v_lead) then
    raise exception 'Ez az időpont már túl közeli — legalább % órával előbb kell foglalni.', v_lead
      using errcode = '42501';
  end if;

  v_reason := public.interview_slot_blocked_reason(p_interviewer, p_start, v_end, null);
  if v_reason is not null then
    raise exception '%', v_reason using errcode = '42501';
  end if;

  v_id := left('IV' || replace(gen_random_uuid()::text, '-', ''), 22);

  insert into public."interviewSlots"
    (id, "startTime", "endTime", status, "interviewerId", "interviewerName",
     "interviewerKey", "studentId", "studentName", "teamsMeetingUrl")
  values
    (v_id, p_start, v_end, 'Booked', p_interviewer::text, public.interview_name(p_interviewer),
     p_interviewer, v_sid, coalesce(v_sname, public.my_display_name()),
     'https://teams.microsoft.com/l/meetup-join/19%3ameeting_' || left(replace(v_id, 'IV', ''), 12));

  return jsonb_build_object(
    'id', v_id,
    'startTime', p_start,
    'endTime', v_end,
    'interviewer', p_interviewer,
    'interviewerName', public.interview_name(p_interviewer),
    'studentId', v_sid,
    'slotMinutes', v_min);
end;
$fn$;

comment on function public.interview_book(uuid, timestamptz, text) is
  'Interjú-időpont foglalása a generált szabad sávok egyikére. A kizárásokat és a 27-es státusz-kaput is végigfuttatja.';

grant execute on function public.interview_book(uuid, timestamptz, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 12. A FELÜLET RPC-I
-- ---------------------------------------------------------------------------
-- A felület EGY hívásból tudja meg, mit szabad neki és mivel dolgozik
-- (sávhossz, időzóna, névsor) — ugyanaz a minta, mint az echo_my_roles() és a
-- dorm_my_roles(): ha az RPC nincs meg (a migráció nem futott le), a felület
-- üresen marad, és a régi viselkedés érintetlen.

create or replace function public.interview_my_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin boolean := coalesce(public.is_admin(), false);
  v_staff boolean := coalesce(public.is_staff(), false);
  v_iv    boolean := public.interview_is_interviewer();
begin
  return jsonb_build_object(
    'admin',          v_admin,
    'staff',          v_staff,
    'interviewer',    v_iv,
    'interviewer_id', case when v_iv then auth.uid() else null end,
    'my_name',        case when v_iv then public.interview_name(auth.uid()) else null end,
    'slot_minutes',   public.interview_slot_minutes(),
    'timezone',       public.interview_tz(),
    'horizon_days',   public.interview_setting_int('booking_horizon_days', 30),
    'lead_hours',     public.interview_setting_int('lead_time_hours', 2),
    -- A névsort mindenki látja, aki foglalhat: a jelentkezőnek is ki kell
    -- írni, kivel lesz az interjúja. A `note` mező viszont belső, kimarad.
    'interviewers',   coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', i.interviewer,
                 'name', public.interview_name(i.interviewer),
                 'email', p.email,
                 'active', i.active) order by public.interview_name(i.interviewer))
          from public.interview_interviewer i
          left join public.profiles p on p.id = i.interviewer
         where i.active or v_admin), '[]'::jsonb),
    -- Csak az adminnak: kit lehet még felvenni a névsorra.
    'candidates',     case when v_admin then coalesce((
        select jsonb_agg(jsonb_build_object('id', p.id, 'name', coalesce(nullif(trim(p.name), ''), p.email), 'email', p.email, 'role', p.role)
                         order by coalesce(nullif(trim(p.name), ''), p.email))
          from public.profiles p
         where p.approval_status = 'approved'
           and p.role in ('ADMIN', 'ADMISSIONS')
           and not exists (select 1 from public.interview_interviewer i where i.interviewer = p.id)),
        '[]'::jsonb) else '[]'::jsonb end,
    'settings',       case when v_admin then coalesce((
        select jsonb_agg(jsonb_build_object('key', s.key, 'value', s.value, 'label', s.label) order by s.key)
          from public.interview_setting s), '[]'::jsonb) else '[]'::jsonb end
  );
end;
$fn$;

grant execute on function public.interview_my_context() to authenticated;

-- A NAPTÁR — egy interjúztató három listája egyben. Külön RPC, mert három
-- táblából jön, és a felületnek egyben kell.
create or replace function public.interview_calendar(p_interviewer uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_key uuid := coalesce(p_interviewer, auth.uid());
begin
  if not (coalesce(public.is_admin(), false) or v_key = auth.uid() or coalesce(public.is_staff(), false)) then
    raise exception 'Nincs jogosultság ennek a naptárnak a megtekintéséhez.' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'interviewer', v_key,
    'name',        public.interview_name(v_key),
    'can_edit',    public.interview_can_edit(v_key),
    'availability', coalesce((
       select jsonb_agg(jsonb_build_object(
                'id', a.id, 'weekday', a.weekday,
                'start_time', to_char(a.start_time, 'HH24:MI'),
                'end_time',   to_char(a.end_time,   'HH24:MI'),
                'valid_from', a.valid_from, 'valid_to', a.valid_to,
                'active', a.active, 'note', a.note)
              order by a.weekday, a.start_time)
         from public.interview_availability a where a.interviewer = v_key), '[]'::jsonb),
    -- A globális (mindenkire vonatkozó) ismétlődő kizárás IS bejön, külön
    -- jelöléssel: az interjúztatónak látnia kell, mi vág bele a napjába,
    -- akkor is, ha nem ő vette fel.
    'breaks', coalesce((
       select jsonb_agg(jsonb_build_object(
                'id', b.id, 'weekday', b.weekday,
                'start_time', to_char(b.start_time, 'HH24:MI'),
                'end_time',   to_char(b.end_time,   'HH24:MI'),
                'label', b.label, 'active', b.active,
                'global', (b.interviewer is null),
                'can_edit', case when b.interviewer is null then coalesce(public.is_admin(), false)
                                 else public.interview_can_edit(b.interviewer) end)
              order by (b.interviewer is not null), b.weekday nulls first, b.start_time)
         from public.interview_break b
        where b.interviewer is null or b.interviewer = v_key), '[]'::jsonb),
    'absences', coalesce((
       select jsonb_agg(jsonb_build_object(
                'id', ab.id, 'starts_at', ab.starts_at, 'ends_at', ab.ends_at,
                'reason', case when coalesce(public.is_admin(), false) or v_key = auth.uid()
                               then ab.reason else null end)
              order by ab.starts_at desc)
         from public.interview_absence ab where ab.interviewer = v_key), '[]'::jsonb)
  );
end;
$fn$;

grant execute on function public.interview_calendar(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 13. SZERKESZTŐ RPC-K
-- ---------------------------------------------------------------------------
-- Mind SECURITY DEFINER + BENNE a jogosultság-ellenőrzés. Miért nem hagyjuk az
-- RLS-re? Mert az RLS egy tiltott írásnál ÜRES eredményt ad, nem hibát, és a
-- felhasználó azt látná, hogy "elmentve", pedig nem történt semmi. Így viszont
-- beszédes magyar hibaüzenetet kap.

create or replace function public.interview_availability_save(
  p_id          uuid,
  p_interviewer uuid,
  p_weekday     smallint,
  p_start       time,
  p_end         time,
  p_valid_from  date    default null,
  p_valid_to    date    default null,
  p_active      boolean default true,
  p_note        text    default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_key uuid := coalesce(p_interviewer, auth.uid());
  v_id  uuid;
begin
  if not public.interview_can_edit(v_key) then
    raise exception 'Csak a saját elérhetőségedet szerkesztheted (az admin bárkiét).' using errcode = '42501';
  end if;
  if p_weekday is null or p_weekday < 1 or p_weekday > 7 then
    raise exception 'Érvénytelen nap — 1 (hétfő) és 7 (vasárnap) között kell lennie.' using errcode = '22023';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception 'A sáv vége legyen későbbi, mint a kezdete.' using errcode = '22023';
  end if;
  if (extract(epoch from (p_end - p_start)) / 60) < public.interview_slot_minutes() then
    raise exception 'A sáv rövidebb, mint egy idősáv (% perc) — így egyetlen időpont sem generálódna belőle.',
      public.interview_slot_minutes() using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.interview_availability
      (interviewer, weekday, start_time, end_time, valid_from, valid_to, active, note, created_by)
    values (v_key, p_weekday, p_start, p_end, p_valid_from, p_valid_to, coalesce(p_active, true), p_note, auth.uid())
    returning id into v_id;
  else
    update public.interview_availability
       set weekday = p_weekday, start_time = p_start, end_time = p_end,
           valid_from = p_valid_from, valid_to = p_valid_to,
           active = coalesce(p_active, true), note = p_note
     where id = p_id and interviewer = v_key
     returning id into v_id;
    if v_id is null then
      raise exception 'A módosítandó elérhetőségi sáv nem található.' using errcode = '42501';
    end if;
  end if;
  return v_id;
end;
$fn$;

create or replace function public.interview_availability_delete(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_owner uuid;
begin
  select a.interviewer into v_owner from public.interview_availability a where a.id = p_id;
  if v_owner is null then return false; end if;
  if not public.interview_can_edit(v_owner) then
    raise exception 'Csak a saját elérhetőségedet törölheted.' using errcode = '42501';
  end if;
  delete from public.interview_availability where id = p_id;
  return true;
end;
$fn$;

-- ISMÉTLŐDŐ KIZÁRÁS. p_interviewer IS NULL = GLOBÁLIS sor (ebédszünet
-- mindenkinek) — ezt csak az admin veheti fel, mert intézményi szabály.
create or replace function public.interview_break_save(
  p_id          uuid,
  p_interviewer uuid,
  p_weekday     smallint,
  p_start       time,
  p_end         time,
  p_label       text    default null,
  p_active      boolean default true,
  p_global      boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_key uuid := case when coalesce(p_global, false) then null else coalesce(p_interviewer, auth.uid()) end;
  v_id  uuid;
begin
  if v_key is null then
    if not coalesce(public.is_admin(), false) then
      raise exception 'Mindenkire vonatkozó kizárást (pl. ebédszünet) csak rendszergazda vehet fel.' using errcode = '42501';
    end if;
  elsif not public.interview_can_edit(v_key) then
    raise exception 'Csak a saját kizárásaidat szerkesztheted.' using errcode = '42501';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception 'A kizárás vége legyen későbbi, mint a kezdete.' using errcode = '22023';
  end if;
  if p_weekday is not null and (p_weekday < 1 or p_weekday > 7) then
    raise exception 'Érvénytelen nap — 1 (hétfő) és 7 (vasárnap) között, vagy üres (minden nap).' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.interview_break (interviewer, weekday, start_time, end_time, label, active, created_by)
    values (v_key, p_weekday, p_start, p_end, p_label, coalesce(p_active, true), auth.uid())
    returning id into v_id;
  else
    update public.interview_break
       set weekday = p_weekday, start_time = p_start, end_time = p_end,
           label = p_label, active = coalesce(p_active, true)
     where id = p_id and interviewer is not distinct from v_key
     returning id into v_id;
    if v_id is null then
      raise exception 'A módosítandó kizárás nem található.' using errcode = '42501';
    end if;
  end if;
  return v_id;
end;
$fn$;

create or replace function public.interview_break_delete(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_owner uuid; v_found boolean;
begin
  select b.interviewer, true into v_owner, v_found from public.interview_break b where b.id = p_id;
  if not coalesce(v_found, false) then return false; end if;
  if v_owner is null then
    if not coalesce(public.is_admin(), false) then
      raise exception 'A mindenkire vonatkozó kizárást csak rendszergazda törölheti.' using errcode = '42501';
    end if;
  elsif not public.interview_can_edit(v_owner) then
    raise exception 'Csak a saját kizárásaidat törölheted.' using errcode = '42501';
  end if;
  delete from public.interview_break where id = p_id;
  return true;
end;
$fn$;

-- ESETI KIZÁRÁS (szabadság). Dátumtartomány + indoklás.
create or replace function public.interview_absence_save(
  p_id          uuid,
  p_interviewer uuid,
  p_starts_at   timestamptz,
  p_ends_at     timestamptz,
  p_reason      text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_key uuid := coalesce(p_interviewer, auth.uid());
  v_id  uuid;
begin
  if not public.interview_can_edit(v_key) then
    raise exception 'Csak a saját távollétedet rögzítheted (az admin bárkiét).' using errcode = '42501';
  end if;
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'A távollét vége legyen későbbi, mint a kezdete.' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.interview_absence (interviewer, starts_at, ends_at, reason, created_by)
    values (v_key, p_starts_at, p_ends_at, nullif(trim(coalesce(p_reason, '')), ''), auth.uid())
    returning id into v_id;
  else
    update public.interview_absence
       set starts_at = p_starts_at, ends_at = p_ends_at,
           reason = nullif(trim(coalesce(p_reason, '')), '')
     where id = p_id and interviewer = v_key
     returning id into v_id;
    if v_id is null then
      raise exception 'A módosítandó távollét nem található.' using errcode = '42501';
    end if;
  end if;
  return v_id;
end;
$fn$;

create or replace function public.interview_absence_delete(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_owner uuid;
begin
  select ab.interviewer into v_owner from public.interview_absence ab where ab.id = p_id;
  if v_owner is null then return false; end if;
  if not public.interview_can_edit(v_owner) then
    raise exception 'Csak a saját távollétedet törölheted.' using errcode = '42501';
  end if;
  delete from public.interview_absence where id = p_id;
  return true;
end;
$fn$;

grant execute on function public.interview_availability_save(uuid, uuid, smallint, time, time, date, date, boolean, text) to authenticated;
grant execute on function public.interview_availability_delete(uuid) to authenticated;
grant execute on function public.interview_break_save(uuid, uuid, smallint, time, time, text, boolean, boolean) to authenticated;
grant execute on function public.interview_break_delete(uuid) to authenticated;
grant execute on function public.interview_absence_save(uuid, uuid, timestamptz, timestamptz, text) to authenticated;
grant execute on function public.interview_absence_delete(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 14. ADMIN RPC-K — névsor és beállítások
-- ---------------------------------------------------------------------------

create or replace function public.interview_roster_save(
  p_interviewer  uuid,
  p_active       boolean default true,
  p_display_name text default null,
  p_note         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Az interjúztató-névsort csak rendszergazda szerkesztheti.' using errcode = '42501';
  end if;
  if p_interviewer is null then
    raise exception 'Hiányzó munkatárs.' using errcode = '22023';
  end if;
  insert into public.interview_interviewer (interviewer, active, display_name, note, created_by)
  values (p_interviewer, coalesce(p_active, true), nullif(trim(coalesce(p_display_name, '')), ''), p_note, auth.uid())
  on conflict (interviewer) do update
    set active       = coalesce(p_active, true),
        display_name = nullif(trim(coalesce(p_display_name, '')), ''),
        note         = coalesce(p_note, public.interview_interviewer.note);
  return p_interviewer;
end;
$fn$;

-- A SÁVHOSSZ ÁTÁLLÍTÁSA. Ez az a művelet, ami miatt a beállítás-tábla létezik:
-- a 15 perc holnap 20 lehet, és ehhez NEM szabad se migrációt, se telepítést
-- kérni. A már kiadott időpontokat NEM érinti: a "interviewSlots" sorok saját
-- kezdet–vég párt hordoznak, a hossz csak az EZUTÁN generált sávokra hat.
create or replace function public.interview_setting_save(p_key text, p_value text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_n integer;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'A foglalási beállításokat csak rendszergazda módosíthatja.' using errcode = '42501';
  end if;
  if p_key not in ('slot_minutes', 'timezone', 'booking_horizon_days', 'lead_time_hours') then
    raise exception 'Ismeretlen beállítás: %', p_key using errcode = '22023';
  end if;

  if p_key = 'timezone' then
    -- Elgépelt időzóna esetén a now() at time zone azonnal hibát dobna a
    -- foglalásnál — inkább itt álljunk meg, mentéskor.
    begin
      perform now() at time zone p_value;
    exception when others then
      raise exception 'Ismeretlen időzóna: % (pl. Europe/Budapest).', p_value using errcode = '22023';
    end;
  else
    begin
      v_n := trim(p_value)::integer;
    exception when others then
      raise exception 'A(z) "%" beállítás értéke szám kell legyen.', p_key using errcode = '22023';
    end;
    if p_key = 'slot_minutes' and (v_n < 5 or v_n > 240) then
      raise exception 'Az idősáv hossza 5 és 240 perc között lehet.' using errcode = '22023';
    end if;
    if v_n < 0 then
      raise exception 'A(z) "%" beállítás nem lehet negatív.', p_key using errcode = '22023';
    end if;
  end if;

  update public.interview_setting
     set value = trim(p_value), updated_at = now(), updated_by = auth.uid()
   where key = p_key;
  if not found then
    raise exception 'Ismeretlen beállítás: %', p_key using errcode = '22023';
  end if;

  return jsonb_build_object('key', p_key, 'value', trim(p_value),
                            'slot_minutes', public.interview_slot_minutes());
end;
$fn$;

grant execute on function public.interview_roster_save(uuid, boolean, text, text) to authenticated;
grant execute on function public.interview_setting_save(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 15. INDULÓ ADAT — ebédszünet, névsor, munkarend
-- ---------------------------------------------------------------------------
-- MINDHÁROM CSAK AKKOR FUT LE, HA A TÁBLA ÜRES. Ez teszi a fájlt idempotenssé
-- és egyben óvatossá: aki már szerkesztette a naptárát, annak a második
-- futtatás nem ír felül semmit.

-- (a) Az ebédszünet — a megrendelő szó szerinti kérése: "minden nap
--     12:00–13:00, szerkeszthető". Globális sor (interviewer IS NULL), tehát
--     mindenkire vonatkozik, és az admin bármikor átállíthatja vagy kikapcsolhatja.
insert into public.interview_break (interviewer, weekday, start_time, end_time, label, active)
select null, null, time '12:00', time '13:00', 'Ebédszünet', true
where not exists (select 1 from public.interview_break);

-- (b) A névsor. A demóban látszania kell valaminek, ezért az első futáskor a
--     felvételis és rendszergazda munkatársak felkerülnek rá. Éles rendszerben
--     az admin a felületen veszi le, akinek nem kell — a sor `active=false`
--     lesz, nem törlődik, így a régi foglalások magyarázata megmarad.
insert into public.interview_interviewer (interviewer, active)
select p.id, true
  from public.profiles p
 where p.role in ('ADMIN', 'ADMISSIONS')
   and p.approval_status = 'approved'
   and not exists (select 1 from public.interview_interviewer)
on conflict (interviewer) do nothing;

-- (c) Munkarend: hétfőtől péntekig 09:00–16:00. Az ebédszünet ebből vágja ki a
--     12:00–13:00-t — így már az induló adaton is LÁTSZIK, hogy a kizárás
--     működik, nem kell hozzá külön beállítás.
insert into public.interview_availability (interviewer, weekday, start_time, end_time, active, note)
select i.interviewer, d.wd, time '09:00', time '16:00', true, 'Alapértelmezett munkarend'
  from public.interview_interviewer i
  cross join (values (1), (2), (3), (4), (5)) as d(wd)
 where not exists (select 1 from public.interview_availability);

-- ---------------------------------------------------------------------------
-- 16. ZÁRÓ ELLENŐRZÉS
-- ---------------------------------------------------------------------------
do $$
declare
  v_min  integer;
  v_free integer;
begin
  select public.interview_slot_minutes() into v_min;
  select count(*) into v_free from public.interview_free_slots();
  raise notice '28_interview_availability.sql kész. Idősáv: % perc. Elérhetőségi sáv: %, kizárás: %, távollét: %. Foglalható sáv a következő % napban: %.',
    v_min,
    (select count(*) from public.interview_availability),
    (select count(*) from public.interview_break),
    (select count(*) from public.interview_absence),
    public.interview_setting_int('booking_horizon_days', 30),
    v_free;
end $$;
