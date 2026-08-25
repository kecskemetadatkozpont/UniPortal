-- ============================================================================
-- 31_interview_integrity.sql
-- Interjú-foglalás: adatbázis-szintű ütközésvédelem
-- ----------------------------------------------------------------------------
-- MIÉRT KELL:
--   A 28-as migráció foglalási kapuja (interview_slot_blocked_reason) ELŐSZÖR
--   OLVAS, majd feltétel nélkül BESZÚR. READ COMMITTED izoláció alatt két
--   egyszerre induló foglalás nem látja egymás még nem véglegesített sorát,
--   így MINDKETTŐ szabadnak látja a sávot, és MINDKETTŐ beszúr.
--
--   Mérés a teljes 01-29 sémán, két párhuzamos tranzakcióval:
--       ellenorzes(A): SZABAD
--       ellenorzes(B): SZABAD
--       => 2 foglalás ugyanazon a 10:00-as sávon: DIAK-A + DIAK-B
--
--   Ezt alkalmazásszintű ellenőrzéssel NEM lehet megszüntetni; csak az
--   adatbázis tud két egyidejű tranzakciót egymáshoz mérni. Innen a
--   kizárási megszorítás (exclusion constraint).
--
-- MIT CSINÁL:
--   1) Feloldja a MÁR MEGLÉVŐ ütközéseket (a korábbi foglalás nyer).
--   2) Kizárási megszorítás: egy interjúztatónak nem lehet két átfedő sávja.
--   3) Egyedi index: egy jelentkezőnek egyszerre egy élő foglalása lehet.
--   4) interview_book: nyers Postgres-hiba helyett magyar üzenet.
--
-- IDEMPOTENS: többször is lefuttatható.
-- VISSZAVONÁS: select public.interview_integrity_rollback();
-- ============================================================================

begin;

create extension if not exists btree_gist;

-- ---------------------------------------------------------------------------
-- 1) Meglévő ütközések feloldása — a KORÁBBAN rögzített foglalás marad
-- ---------------------------------------------------------------------------
do $$
declare
  v_row   record;
  v_count integer := 0;
begin
  for v_row in
    with elo as (
      select id, "startTime", "endTime", "studentId", ctid,
             coalesce("interviewerKey"::text, "interviewerId") as iv
        from public."interviewSlots"
       where coalesce(status, '') <> 'Cancelled'
         and "startTime" is not null and "endTime" is not null
    )
    select b.id, b."startTime", b."studentId", a.id as nyertes
      from elo a
      join elo b
        on a.iv = b.iv
       and a.ctid < b.ctid
       and tstzrange(a."startTime", a."endTime", '[)')
        && tstzrange(b."startTime", b."endTime", '[)')
  loop
    update public."interviewSlots" set status = 'Cancelled' where id = v_row.id;
    v_count := v_count + 1;
    raise notice 'Ütköző foglalás lemondva: % (jelentkező: %, időpont: %) — megmarad: %',
      v_row.id, coalesce(v_row."studentId", '-'), v_row."startTime", v_row.nyertes;
  end loop;

  if v_count = 0 then
    raise notice 'Nem volt feloldandó ütközés.';
  else
    raise notice 'Összesen % ütköző foglalás lett lemondva.', v_count;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1b) Jelentkezőnkénti többes foglalás feloldása — a LEGKORÁBBI marad
--     (a 3) pont egyedi indexe enélkül nem jönne létre a meglévő adaton)
-- ---------------------------------------------------------------------------
do $$
declare
  v_row   record;
  v_count integer := 0;
begin
  for v_row in
    select id, "studentId", "startTime"
      from (
        select id, "studentId", "startTime",
               row_number() over (
                 partition by "studentId"
                 order by "startTime" asc, id asc
               ) as rn
          from public."interviewSlots"
         where "studentId" is not null
           and coalesce(status, '') not in ('Cancelled', 'Completed')
      ) t
     where rn > 1
  loop
    update public."interviewSlots" set status = 'Cancelled' where id = v_row.id;
    v_count := v_count + 1;
    raise notice 'Többes foglalás lemondva: % (jelentkező: %, időpont: %)',
      v_row.id, v_row."studentId", v_row."startTime";
  end loop;

  if v_count = 0 then
    raise notice 'Nem volt feloldandó többes foglalás.';
  else
    raise notice 'Összesen % többes foglalás lett lemondva.', v_count;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2) Kizárási megszorítás: egy interjúztató, átfedő idő => tilos
--    A feltétel SZÁNDÉKOSAN azonos az interview_slot_blocked_reason
--    szűrésével (status <> 'Cancelled'), hogy a kapu és a megszorítás
--    soha ne mondhasson ellent egymásnak.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'interviewslots_no_overlap'
  ) then
    alter table public."interviewSlots"
      add constraint interviewslots_no_overlap
      exclude using gist (
        (coalesce("interviewerKey"::text, "interviewerId")) with =,
        tstzrange("startTime", "endTime", '[)') with &&
      )
      where (coalesce(status, '') <> 'Cancelled');
    raise notice 'Létrehozva: interviewslots_no_overlap';
  else
    raise notice 'Már létezik: interviewslots_no_overlap';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3) Egy jelentkezőnek egyszerre egy élő interjúja lehet.
--    A 'Completed' KIVÉTEL: a lezajlott interjú után újra foglalható
--    (pl. ismételt interjú), a jövőbeli sávok halmozása viszont tilos.
-- ---------------------------------------------------------------------------
create unique index if not exists interviewslots_one_live_per_student
  on public."interviewSlots" ("studentId")
  where "studentId" is not null
    and coalesce(status, '') not in ('Cancelled', 'Completed');

-- ---------------------------------------------------------------------------
-- 4) Sorosítás: a KAPU fogja meg az ütközést, ne a megszorítás
--
--    A puszta kizárási megszorítás helyes adatot ad, de csúnya élményt:
--    két egyszerre induló foglalásnál a mérés "deadlock detected"-et adott
--    vissza, mert mindkét tranzakció beszúrt, majd egymás indexbejegyzésére
--    várt. Az adat így is helyes maradt, de a felhasználó nyers Postgres-
--    hibát látott.
--
--    Megoldás: a beszúrás ELŐTT tranzakció-élettartamú tanácsadó zárat
--    veszünk az (interjúztató, kezdőidőpont) párra. Így a második foglalás
--    megvárja az elsőt, és mire sorra kerül, a kapu ellenőrzése MÁR LÁTJA a
--    véglegesített sort -> a jelentkező a rendes magyar üzenetet kapja.
--    A kizárási megszorítás végső védőhálóként megmarad.
--
--    A név "a_" előtaggal kezdődik: a triggerek ábécésorrendben futnak, ez
--    tehát biztosan megelőzi a "z_...gate..." kapukat.
-- ---------------------------------------------------------------------------
create or replace function public.interviewslots_serialize()
returns trigger
language plpgsql
as $$
begin
  if new."startTime" is not null then
    -- Egyetlen bigint kulcs: a pg_advisory_xact_lock kétparaméteres alakja
    -- (int, int) - a hash nem férne bele, ezért az interjúztatót és a
    -- percre kerekített kezdőidőpontot EGY szövegbe fűzve hasheljük.
    perform pg_advisory_xact_lock(
      hashtextextended(
        coalesce(new."interviewerKey"::text, new."interviewerId", '')
          || '@' ||
        to_char(date_trunc('minute', new."startTime" at time zone 'UTC'),
                'YYYY-MM-DD HH24:MI'),
        0)
    );
  end if;
  return new;
end $$;

drop trigger if exists a_interviewslots_serialize_trg on public."interviewSlots";
create trigger a_interviewslots_serialize_trg
  before insert or update of "startTime", "interviewerKey", "interviewerId"
  on public."interviewSlots"
  for each row execute function public.interviewslots_serialize();

comment on constraint interviewslots_no_overlap on public."interviewSlots" is
  'Egy interjúztatónak nem lehet két átfedő, le nem mondott sávja. '
  'Ez zárja le a foglalási kapu ellenőrzés-és-beszúrás közti versenyhelyzetét.';

-- ---------------------------------------------------------------------------
-- 5) Visszavonás
-- ---------------------------------------------------------------------------
create or replace function public.interview_integrity_rollback()
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'Csak szuperadmin vonhatja vissza.' using errcode = '42501';
  end if;
  drop trigger if exists a_interviewslots_serialize_trg on public."interviewSlots";
  alter table public."interviewSlots" drop constraint if exists interviewslots_no_overlap;
  drop index if exists public.interviewslots_one_live_per_student;
  return 'A 30-as migráció ütközésvédelme visszavonva.';
end $$;

revoke all on function public.interview_integrity_rollback() from public, anon, authenticated;
grant execute on function public.interview_integrity_rollback() to authenticated;

commit;
