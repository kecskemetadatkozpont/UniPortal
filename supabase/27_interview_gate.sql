-- ============================================================================
-- 27_interview_gate.sql — Interjú-foglalási kapu: csak 'Documents checked'
-- ============================================================================
--
-- MIÉRT
-- ---------------------------------------------------------------------------
-- Ma BÁRKI foglalhat interjú-idősávot. MÉRVE a 'fresh' replikán, a migráció
-- ELŐTT, a hallgatói fiókkal (ammar@test.com → students.S1, státusz
-- 'Accepted', tehát NEM 'Documents checked'):
--
--     update public."interviewSlots" set status='Booked', "studentId"='S1',
--            "studentName"='Al-Farabi Ammar' where id='S1';
--     → UPDATE 1        (sikerült)
--
-- A felvételi rend szerint az interjú a dokumentum-ellenőrzés UTÁN következik:
-- addig nincs mit megbeszélni, és a foglalt idősáv elveszett kapacitás. A
-- felület gombja önmagában nem elég kapu — a jelentkező böngészőjéből a
-- PostgREST végpont közvetlenül is hívható, ezért a kényszer ide, az
-- adatbázisba kell.
--
-- MIT CSINÁL
-- ---------------------------------------------------------------------------
-- Egy BEFORE UPDATE trigger az "interviewSlots" táblán, amely FOGLALÁSKOR
-- (status → 'Booked') megnézi a foglalás alanyának a students.status értékét,
-- és csak a 25_status_model.sql katalógusából a 'Documents checked' kódot
-- engedi át. Minden más esetben 42501 (insufficient_privilege) hibával áll
-- meg, BESZÉDES üzenettel — a felület ezt szó szerint meg is jeleníti.
--
-- ÚJ STÁTUSZT NEM VEZET BE: a 25-ös katalógus 7 kódjából használ egyet, és
-- indulásnál ellenőrzi is, hogy a kód létezik.
--
-- KIRE VONATKOZIK
-- ---------------------------------------------------------------------------
-- MINDENKIRE, az ügyintézőre is. A szabály a JELENTKEZŐ tulajdonsága, nem a
-- hívóé: ha az ügyintéző is megkerülhetné, a kapu csak egy kattintással
-- odébb lenne. Ha az ügyintéző mégis foglalni akar, előbb a státuszt kell
-- 'Documents checked'-re állítania — azt a 25-ös állapotgép engedi
-- (Submitted → Documents checked).
--
-- A 11-es migráció triggerével való EGYÜTTMŰKÖDÉS
-- ---------------------------------------------------------------------------
-- Ugyanezen a táblán már fut az interviewslots_force_owner_trg (11.10.2),
-- ami a nem-ügyintéző hívónál felülírja a "studentId"/"studentName" mezőt a
-- hívó SAJÁT adatára. A PostgreSQL az azonos időzítésű triggereket NÉV
-- SZERINT, ábécésorrendben futtatja: 'interviewslots_force_owner_trg' <
-- 'interviewslots_gate_trg', tehát a kapu MÁR a felülírt (valódi) studentId
-- értéket látja. A név megválasztása ezért nem esetleges.
--
-- VISSZAFORDÍTHATÓSÁG
-- ---------------------------------------------------------------------------
--     select public.interview_gate_rollback();   -- eldobja a triggert
-- A függvények bent maradnak, a trigger újra felhúzható a fájl újrafuttatásával.
--
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. ELŐFELTÉTEL — a 25-ös státuszkatalógus és a students tábla
-- ---------------------------------------------------------------------------
-- Ha a katalógus hiányzik, a kapu vakon hivatkozna egy kódra. Inkább álljunk meg.
do $$
begin
  if to_regclass('public.students') is null then
    raise exception 'MEGTAGADVA: a public.students tábla hiányzik (01_schema_and_seed.sql).';
  end if;
  if to_regclass('public.student_status') is null then
    raise exception 'MEGTAGADVA: a public.student_status katalógus hiányzik. Futtasd előbb a 25_status_model.sql-t.';
  end if;
  if not exists (select 1 from public.student_status where code = 'Documents checked') then
    raise exception 'MEGTAGADVA: a student_status katalógusban nincs ''Documents checked'' kód — a 25_status_model.sql nem futott le teljesen.';
  end if;
  raise notice 'Előfeltétel rendben: students + student_status katalógus megvan.';
end $$;

-- ---------------------------------------------------------------------------
-- 1. A KAPU KÖVETELT STÁTUSZA — egyetlen helyen
-- ---------------------------------------------------------------------------
-- Külön függvény, hogy a szöveg NE szóródjon szét a trigger törzsében és a
-- diagnosztikai lekérdezésekben. Ha a folyamat egyszer változik, itt egy sort
-- kell átírni.
create or replace function public.interview_gate_required_status()
returns text language sql immutable set search_path = public as $$
  select 'Documents checked'::text
$$;

comment on function public.interview_gate_required_status() is
  'Az a students.status kód (25_status_model.sql katalógusából), amellyel interjú-idősáv foglalható.';

-- ---------------------------------------------------------------------------
-- 2. A FOGLALÁS ALANYÁNAK STÁTUSZA
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER: a triggerben a students táblán is érvényesülne az RLS, és
-- egy hallgató a SAJÁT során kívül nem lát semmit — a kapu így hamis 'nincs
-- ilyen jelentkező' hibát adna. A függvény CSAK a státuszt adja vissza,
-- semmilyen más mezőt, tehát nem nyit adatszivárgást.
create or replace function public.student_status_of(p_student_id text)
returns text language sql stable security definer set search_path = public as $$
  select s.status from public.students s where s.id = nullif(p_student_id, '')
$$;

comment on function public.student_status_of(text) is
  'A megadott students sor státusza, RLS-től függetlenül. A 27-es interjú-kapu használja.';

grant execute on function public.interview_gate_required_status() to authenticated, anon;
grant execute on function public.student_status_of(text)          to authenticated;

-- ---------------------------------------------------------------------------
-- 3. A KAPU
-- ---------------------------------------------------------------------------
-- Csak a FOGLALÁS pillanata érdekel: amikor a sor 'Booked' állapotba kerül,
-- vagy amikor egy már foglalt sáv MÁS jelentkezőre íródik át. A lemondás
-- ('Booked' → 'Available'), az interjúztató cseréje, a teamsMeetingUrl
-- frissítése és minden egyéb mező érintetlen marad — a kapu nem akadályozhatja
-- a napi ügyintézést, csak a foglalást.
create or replace function public.interviewslots_booking_gate()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_student_id text;
  v_status     text;
  v_required   text := public.interview_gate_required_status();
  v_label      text;
begin
  if coalesce(new."status", '') <> 'Booked' then
    return new;                                    -- nem foglalás
  end if;
  if coalesce(old."status", '') = 'Booked'
     and coalesce(old."studentId", '') = coalesce(new."studentId", '') then
    return new;                                    -- már foglalt, ugyanannak
  end if;

  v_student_id := nullif(new."studentId", '');

  -- (a) nincs alany: a 11.10.2 trigger a be nem kötött hallgatói fióknál NULL
  --     studentId-t ír. Névtelen foglalást nem engedünk — ez ma is hibás sor
  --     lenne, csak eddig némán átment.
  if v_student_id is null then
    raise exception
      'Az interjú-foglaláshoz be kell kötni a fiókot egy jelentkezői sorhoz (profiles."studentId" → students.id). Kérjük, forduljon a Külügyi Irodához.'
      using errcode = '42501';
  end if;

  v_status := public.student_status_of(v_student_id);

  -- (b) nincs ilyen jelentkező
  if v_status is null then
    raise exception
      'Az interjú-foglalás alanya (%) nem szerepel a jelentkezők között.', v_student_id
      using errcode = '42501';
  end if;

  -- (c) a tényleges kapu
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
$$;

-- A név SZÁNDÉKOSAN 'gate': ábécében a 11-es 'force_owner' UTÁN fut, tehát a
-- kapu a felülírt, valódi "studentId" értéket látja. Lásd a fejlécet.
drop trigger if exists interviewslots_gate_trg on public."interviewSlots";
create trigger interviewslots_gate_trg
  before update on public."interviewSlots"
  for each row execute function public.interviewslots_booking_gate();

-- ============================================================================
-- 4. KIEGÉSZÍTÉS — a BESZÚRÁSSAL VALÓ MEGKERÜLÉS ZÁRÁSA (II/1.2)
-- ============================================================================
--
-- MÉRVE az ig27 replikán (01–26 + a fenti 3. szakasz), a hallgatói fiókkal
-- (ammar@test.com → profiles."studentId" = 'S1', students.status = 'Accepted',
-- tehát NEM 'Documents checked'):
--
--   begin;
--   set local request.jwt.claims='{"sub":"b55ea801-…","role":"authenticated",
--                                  "email":"ammar@test.com"}';
--   set local role authenticated;
--   insert into public."interviewSlots"(id,"startTime","endTime",
--          "interviewerName",status,"studentId","studentName")
--   values ('HACK1', now(), now()+interval '30 min', 'X', 'Booked',
--           'S1', 'Al-Farabi Ammar');
--   → INSERT 0 1     (ÁTMENT — a sor 'Booked' állapotban, 'S1'-re szólt)
--
-- A 3. szakasz triggere BEFORE UPDATE, tehát a foglalás UPDATE útját zárja.
-- A jelentkező böngészőjéből azonban a PostgREST POST végpont is elérhető, és
-- az insert-tel eleve 'Booked' állapotú sor születik — UPDATE nélkül. A kapu
-- így egy sorral odébb megkerülhető volt.
--
-- A javítás: ugyanaz a kapufüggvény BESZÚRÁSKOR is fut. Az OLD rekordra
-- INSERT alatt nem szabad hivatkozni (PL/pgSQL: „record old is not assigned
-- yet”), ezért a TG_OP dönti el, van-e mihez képest vizsgálni.
--
-- FIGYELEM a triggerek sorrendjére: a 11.10.2 interviewslots_force_owner_trg
-- CSAK UPDATE-re van felhúzva. Beszúráskor tehát nincs, ami felülírja a
-- "studentId"-t — a kapu a HÍVÓ ÁLTAL MEGADOTT alanyt vizsgálja, és pontosan
-- ezt is akarjuk: aki nem jutott túl a dokumentum-ellenőrzésen, arra nem
-- születhet foglalt sáv, akárhogyan is kéri.
--
-- Idempotens: a függvény cseréje és a trigger újrahúzása biztonságos.
-- ============================================================================

create or replace function public.interviewslots_booking_gate()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_student_id text;
  v_status     text;
  v_required   text := public.interview_gate_required_status();
  v_label      text;
  v_was_booked boolean;
  v_old_sid    text;
begin
  -- Csak a FOGLALÁS pillanata érdekel.
  if coalesce(new."status", '') <> 'Booked' then
    return new;
  end if;

  -- Az OLD rekord INSERT alatt nincs hozzárendelve — a TG_OP dönt.
  if tg_op = 'UPDATE' then
    v_was_booked := (coalesce(old."status", '') = 'Booked');
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
$$;

comment on function public.interviewslots_booking_gate() is
  'Interjú-foglalási kapu: foglalni (status → Booked) csak ''Documents checked'' státuszú jelentkezőre lehet. BEFORE INSERT OR UPDATE.';

drop trigger if exists interviewslots_gate_trg on public."interviewSlots";
create trigger interviewslots_gate_trg
  before insert or update on public."interviewSlots"
  for each row execute function public.interviewslots_booking_gate();

-- ============================================================================
-- 5. VISSZAFORDÍTHATÓSÁG — a fejlécben ígért, de hiányzó függvény
-- ============================================================================
-- A fájl fejléce (49–52. sor) a `select public.interview_gate_rollback();`
-- hívást ígéri. MÉRVE: a függvény nem létezett —
--
--   select proname from pg_proc where proname = 'interview_gate_rollback';
--   → (0 rows)
--
-- így a dokumentált visszaút egy „function does not exist” hibába futott
-- volna, épp abban a helyzetben, amikor a legkevésbé kell (éles zavar,
-- gyors kapu-kikapcsolás). Pótoljuk.
--
-- A függvény CSAK a triggert dobja el; a kapufüggvény és a segédfüggvények
-- bent maradnak, tehát a fájl újrafuttatásával a kapu egy lépésben
-- visszahúzható.
create or replace function public.interview_gate_rollback()
returns text language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public."interviewSlots"'::regclass
       and tgname  = 'interviewslots_gate_trg'
       and not tgisinternal
  ) then
    return 'Az interjú-foglalási kapu már ki van kapcsolva (nincs interviewslots_gate_trg).';
  end if;
  drop trigger interviewslots_gate_trg on public."interviewSlots";
  return 'Az interjú-foglalási kapu KIKAPCSOLVA. Visszakapcsolás: futtasd újra a 27_interview_gate.sql-t.';
end
$$;

comment on function public.interview_gate_rollback() is
  'Eldobja az interviewslots_gate_trg triggert (27_interview_gate.sql). A függvények megmaradnak.';

revoke all on function public.interview_gate_rollback() from public, anon, authenticated;
grant execute on function public.interview_gate_rollback() to service_role;

-- ---------------------------------------------------------------------------
-- 6. ÖNELLENŐRZÉS — a fájl végén álljon ott, mi jött létre
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
begin
  select pg_get_triggerdef(t.oid) into v_def
    from pg_trigger t
   where t.tgrelid = 'public."interviewSlots"'::regclass
     and t.tgname  = 'interviewslots_gate_trg'
     and not t.tgisinternal;
  if v_def is null then
    raise exception 'MEGTAGADVA: az interviewslots_gate_trg nem jött létre.';
  end if;
  if position('INSERT OR UPDATE' in upper(v_def)) = 0 then
    raise exception 'MEGTAGADVA: a kapu nem fut beszúrásra — a trigger: %', v_def;
  end if;
  raise notice 'Interjú-foglalási kapu aktív (INSERT és UPDATE): %', v_def;
  raise notice 'Követelt státusz: %', public.interview_gate_required_status();
end $$;
