-- ============================================================================
-- 30_interview_gate_hardening.sql — a 27/28-as interjú-kapu két rése
-- ============================================================================
--
-- MIÉRT
-- ---------------------------------------------------------------------------
-- A 27_interview_gate.sql és a 28_interview_availability.sql kapuja MŰKÖDIK,
-- de az ellenőrzés két ponton megkerülhető a NYERS API-ról (PostgREST). Mind
-- a kettőt MÉRTÜK a 'fresh' replikán, a 27–29 betöltése UTÁN.
--
-- (1) BETŰMÉRET-ÉRZÉKENY ŐRSZEM
--     Mindkét kapufüggvény első sora így szűr:
--         if coalesce(new.status,'') <> 'Booked' then return new; end if;
--     Az "interviewSlots".status szabad szöveg — nincs rajta CHECK megszorítás.
--     Aki kisbetűvel ír, annak a kapu meg sem szólal:
--
--       insert into "interviewSlots"(id,...,status,"studentId",...)
--         values('TEST-C',...,'booked','S2',...);   -- S2 = 'Submitted'
--       → INSERT 0 1        (átment, pedig 'Booked'-kal 42501-et kapott volna)
--
-- (2) A TULAJDONOS-KÉNYSZER CSAK MÓDOSÍTÁSRA FUT
--     Az interviewslots_force_owner_trg (11/12-es migráció) BEFORE UPDATE.
--     A 27/28-as kapu viszont abból indul ki, hogy a new."studentId" a HÍVÓ
--     saját jelentkezői sora — beszúrásnál ezt semmi nem kényszeríti ki:
--
--       -- ammar@test.com (profiles."studentId" = 'S1') fiókjával:
--       insert into "interviewSlots"(...,status,"studentId","studentName")
--         values('HACK-1',...,'Booked','S2','Chen Wei');
--       → INSERT 0 1   → a sor: studentId='S2', studentName='Chen Wei'
--
--     Vagyis az egyik jelentkező LEFOGLALHATTA a másik nevében az idősávot.
--     (A rés a 11-es migráció óta megvan — a base26 replikán is reprodukáltuk
--     'HACK-0' néven —, de a 27/28-as kapu ÉRTELME múlik rajta, ezért itt
--     zárjuk be, a 15–26 fájlok érintése nélkül.)
--
-- MIT CSINÁL
-- ---------------------------------------------------------------------------
-- 1. Normalizálja a meglévő "interviewSlots".status értékeket, és CHECK
--    megszorítással a három ismert kódra szorítja: Available/Booked/Cancelled.
-- 2. A két kapufüggvény őrszemét kisbetűre hozott összehasonlításra cseréli,
--    hogy a megszorítás mellett is öv-és-nadrágtartó legyen a védelem.
-- 3. Az interviewslots_force_owner_trg triggert BEFORE INSERT OR UPDATE-re
--    cseréli, így beszúrásnál is a hívó saját sorára áll a foglalás.
--
-- ÚJ TÁBLÁT, ÚJ STÁTUSZT, ÚJ SZEREPKÖRT NEM VEZET BE. Idempotens: kétszer
-- lefuttatva ugyanaz az eredmény.
--
-- FUTTATÁS
-- ---------------------------------------------------------------------------
-- A 27, 28 és 29 UTÁN. Supabase SQL Editor: az egész fájl egy blokként
-- beilleszthető — psql meta-parancs (\set, \i, \echo) NINCS benne. A védelmet
-- a begin ... commit adja: bármelyik utasítás hibája mindent visszagörget.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. ELŐFELTÉTELEK — a 27 és a 28 lefutott-e
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.interviewslots_booking_gate()') is null then
    raise exception 'MEGTAGADVA: előbb a 27_interview_gate.sql-t kell lefuttatni.';
  end if;
  if to_regprocedure('public.interviewslots_gate_on_insert()') is null then
    raise exception 'MEGTAGADVA: előbb a 28_interview_availability.sql-t kell lefuttatni.';
  end if;
  if to_regprocedure('public.my_student_id()') is null then
    raise exception 'MEGTAGADVA: hiányzik a my_student_id() (11-es migráció).';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. STÁTUSZ-NORMALIZÁLÁS + CHECK megszorítás
-- ---------------------------------------------------------------------------
-- Előbb a meglévő sorokat hozzuk kanonikus alakra (a mérés szerint a replikán
-- csak 'Available' szerepel, de a megszorítás nem bukhat el éles adaton sem),
-- utána tesszük fel a megszorítást. A NULL-t 'Available'-re visszük: a tábla
-- eredeti értelmezése szerint a státusz nélküli sáv szabad.
update public."interviewSlots"
   set status = case lower(btrim(coalesce(status, '')))
                  when 'booked'    then 'Booked'
                  when 'cancelled' then 'Cancelled'
                  when 'canceled'  then 'Cancelled'
                  when 'available' then 'Available'
                  when ''          then 'Available'
                  else 'Available'      -- ismeretlen kód: szabad sávnak vesszük
                end
 where status is distinct from case lower(btrim(coalesce(status, '')))
                  when 'booked'    then 'Booked'
                  when 'cancelled' then 'Cancelled'
                  when 'canceled'  then 'Cancelled'
                  when 'available' then 'Available'
                  when ''          then 'Available'
                  else 'Available'
                end;

alter table public."interviewSlots" drop constraint if exists "interviewSlots_status_check";
alter table public."interviewSlots"
  add constraint "interviewSlots_status_check"
  check (status in ('Available', 'Booked', 'Cancelled'));

-- ---------------------------------------------------------------------------
-- 3. A KÉT KAPUFÜGGVÉNY ŐRSZEME — kisbetűre hozott összehasonlítás
-- ---------------------------------------------------------------------------
-- A törzs egyébként szó szerint a 27/28-as, csak a 'Booked' vizsgálat lett
-- lower(btrim(...)) alapú. A CHECK megszorítás mellett ez már redundáns, de
-- ha valaki később feloldaná a megszorítást, a kapu akkor is zárva marad.
create or replace function public.interviewslots_booking_gate()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_student_id text;
  v_status     text;
  v_required   text := public.interview_gate_required_status();
  v_label      text;
  v_was_booked boolean;
  v_old_sid    text;
begin
  -- Csak a FOGLALÁS pillanata érdekel. A betűméret nem számít: a nyers API-n
  -- a 'booked' korábban átcsúszott a kapun.
  if lower(btrim(coalesce(new."status", ''))) <> 'booked' then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    v_was_booked := (lower(btrim(coalesce(old."status", ''))) = 'booked');
    v_old_sid    := coalesce(old."studentId", '');
  else
    v_was_booked := false;
    v_old_sid    := null;
  end if;

  -- Már foglalt sáv, ugyanannak a jelentkezőnek: nem új foglalás, átengedjük
  -- (teamsMeetingUrl frissítése, interjúztató cseréje stb. ne akadjon el).
  if v_was_booked and v_old_sid = coalesce(new."studentId", '') then
    return new;
  end if;

  v_student_id := nullif(new."studentId", '');

  if v_student_id is null then
    raise exception
      'Az interjú-foglaláshoz be kell kötni a fiókot egy jelentkezői sorhoz (profiles."studentId" → students.id). Kérjük, forduljon a Külügyi Irodához.'
      using errcode = '42501';
  end if;

  v_status := public.student_status_of(v_student_id);

  if v_status is null then
    raise exception
      'Az interjú-foglalás alanya (%) nem szerepel a jelentkezők között.', v_student_id
      using errcode = '42501';
  end if;

  if v_status <> v_required then
    select coalesce(ss.label_hu, v_status) into v_label
      from public.student_status ss where ss.code = v_status;
    raise exception
      'Interjú-időpontot csak a dokumentum-ellenőrzésen túljutott jelentkező foglalhat. A jelentkező jelenlegi státusza: "%" (%), a foglaláshoz szükséges: "%".',
      coalesce(v_label, v_status), v_status, v_required
      using errcode = '42501',
            hint = 'Az ügyintéző a felvételi státuszt a Jelentkezők nézetben állíthatja "Dokumentumok ellenőrizve" értékre.';
  end if;

  return new;
end
$fn$;

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
  if lower(btrim(coalesce(new.status, ''))) <> 'booked' then return new; end if;
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
end
$fn$;

-- ---------------------------------------------------------------------------
-- 4. TULAJDONOS-KÉNYSZER BESZÚRÁSRA IS
-- ---------------------------------------------------------------------------
-- A 11-es migráció interviewslots_force_owner() függvényét NEM írjuk át és a
-- BEFORE UPDATE triggerét sem bántjuk — a beszúrásra külön függvény való,
-- mert ott más a helyes viselkedés:
--
--   ügyintéző (is_staff)      → átengedjük, ő bárkinek foglalhat
--   rendszer (auth.uid() null)→ átengedjük (psql, service_role, magvetés)
--   jelentkező (is_student)   → a SAJÁT sorára írjuk át a foglalást
--   bárki más (pl. ÜGYNÖK)    → beszédes 42501, nem néma adatcsere
--
-- Az utolsó ág azért külön eset, mert a force_owner() ott csak NULL-ra írná a
-- "studentId"-t, és a hívó a félrevezető „kösse be a fiókját" üzenetet kapná.
-- A felület egyébként SOHA nem szúr be idősávot (a bookInterviewSlot() az
-- app.jsx:673-ban sbUpdate, tehát UPDATE) — a sávokat az ügyintéző generálja.
create or replace function public.interviewslots_insert_owner()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if public.is_staff() or auth.uid() is null then
    return new;
  end if;

  if public.is_student() then
    new."studentId"   := public.my_student_id();
    new."studentName" := public.my_display_name();
    return new;
  end if;

  raise exception
    'Interjú-idősávot csak a Külügyi Iroda hozhat létre. A jelentkező a MÁR MEGHIRDETETT szabad sávok közül foglalhat.'
    using errcode = '42501',
          hint = 'Az idősávokat az Interjú Foglalás → Elérhetőség fülön lehet generálni.';
end
$fn$;

drop trigger if exists interviewslots_insert_owner_trg on public."interviewSlots";
create trigger interviewslots_insert_owner_trg
  before insert on public."interviewSlots"
  for each row execute function public.interviewslots_insert_owner();

-- FONTOS a triggerek ÁBÉCÉ szerinti sorrendje ugyanazon az eseményen:
--   interviewslots_availability_trg < interviewslots_gate_ins_trg
--   < interviewslots_gate_trg       < interviewslots_insert_owner_trg
-- A tulajdonos-kényszer így a két kapu UTÁN futna, ami rossz: a kapuk még a
-- HAMIS "studentId"-t látnák. Ezért a két kaput újra kell kötni, hogy az
-- ábécében a tulajdonos-kényszer MÖGÉ kerüljenek — az egyszerű megoldás, hogy
-- a kapu-triggerek nevét 'z' előtaggal hátrasoroljuk.
drop trigger if exists interviewslots_gate_ins_trg on public."interviewSlots";
drop trigger if exists interviewslots_gate_trg     on public."interviewSlots";
drop trigger if exists z_interviewslots_gate_ins_trg on public."interviewSlots";
drop trigger if exists z_interviewslots_gate_trg     on public."interviewSlots";
create trigger z_interviewslots_gate_ins_trg
  before insert on public."interviewSlots"
  for each row execute function public.interviewslots_gate_on_insert();
create trigger z_interviewslots_gate_trg
  before insert or update on public."interviewSlots"
  for each row execute function public.interviewslots_booking_gate();

-- ---------------------------------------------------------------------------
-- 5. VISSZAGÖRGETÉS — ha a kapu mégis útban lenne
-- ---------------------------------------------------------------------------
create or replace function public.interview_gate_hardening_rollback()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  alter table public."interviewSlots" drop constraint if exists "interviewSlots_status_check";
  drop trigger if exists interviewslots_insert_owner_trg on public."interviewSlots";
  drop trigger if exists z_interviewslots_gate_ins_trg   on public."interviewSlots";
  drop trigger if exists z_interviewslots_gate_trg       on public."interviewSlots";
  create trigger interviewslots_gate_ins_trg
    before insert on public."interviewSlots"
    for each row execute function public.interviewslots_gate_on_insert();
  create trigger interviewslots_gate_trg
    before insert or update on public."interviewSlots"
    for each row execute function public.interviewslots_booking_gate();
  return 'A 30-as keményítés visszagörgetve: a status CHECK megszorítás törölve, '
      || 'a beszúrási tulajdonos-kényszer megszüntetve, a kapu-triggerek eredeti '
      || 'nevükön. A kapufüggvények kisbetű-tűrése bent maradt (az nem korlátoz semmit).';
end
$fn$;

revoke all on function public.interview_gate_hardening_rollback() from public, anon, authenticated;
grant execute on function public.interview_gate_hardening_rollback() to service_role;

commit;

-- ---------------------------------------------------------------------------
-- 6. ÖNELLENŐRZÉS — a fájl végén álljon ott, mi jött létre
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text;
  v_check text;
begin
  select string_agg(t.tgname, ', ' order by t.tgname) into v_names
    from pg_trigger t
   where t.tgrelid = 'public."interviewSlots"'::regclass
     and not t.tgisinternal;

  if to_regprocedure('public.interviewslots_insert_owner()') is null then
    raise exception 'MEGTAGADVA: az interviewslots_insert_owner() nem jött létre.';
  end if;
  if position('interviewslots_insert_owner_trg' in coalesce(v_names, '')) = 0 then
    raise exception 'MEGTAGADVA: a beszúrási tulajdonos-kényszer triggere hiányzik. Triggerek: %', v_names;
  end if;
  if position('z_interviewslots_gate_trg' in coalesce(v_names, '')) = 0 then
    raise exception 'MEGTAGADVA: a kapu-trigger nem került a tulajdonos-kényszer mögé. Triggerek: %', v_names;
  end if;

  select pg_get_constraintdef(c.oid) into v_check
    from pg_constraint c
   where c.conrelid = 'public."interviewSlots"'::regclass
     and c.conname  = 'interviewSlots_status_check';
  if v_check is null then
    raise exception 'MEGTAGADVA: az "interviewSlots".status CHECK megszorítása nem jött létre.';
  end if;

  raise notice 'Triggerek FUTÁSI (ábécé) sorrendben: %', v_names;
  raise notice 'Státusz-megszorítás: %', v_check;
  raise notice 'A tulajdonos-kényszer beszúrásra is fut, és MEGELŐZI a két kaput.';
  raise notice 'Kapufüggvények kisbetű-tűrők (a nyers API-n a "booked" sem csúszik át).';
end $$;
