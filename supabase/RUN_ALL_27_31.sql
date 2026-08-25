-- ============================================================================
-- RUN_ALL_27_31.sql  —  UniPortal
-- EGYBEN BEILLESZTHETŐ CSOMAG a Supabase SQL Editorba.
--
-- Tartalom (ebben a sorrendben):
--   27_interview_gate.sql             interjú-kapu: csak "Documents checked" után
--   28_interview_availability.sql     elérhetőség, ebédszünet, szabadság, sávok
--   29_agency.sql                     ügynökségi portál, jutalék, számla
--   30_interview_gate_hardening.sql   a kapu két API-szintű résének lezárása
--   31_interview_integrity.sql        ütközésvédelem (versenyhelyzet lezárása)
--   21_echo_harden_submit.sql         ÚJRA — minden új migráció után kötelező
--
-- MIÉRT VAN A 21-ES A VÉGÉN:
--   A Supabase alapértelmezett jogosztása minden új migráció után
--   visszaadhatja az echo_submit futtatási jogát az "authenticated"
--   szerepnek. Az anonimitás csak akkor marad meg, ha ez a fájl fut UTOLSÓNAK.
--   Ellenőrzés futtatás után: az echo_submit-nál CSAK "anon" szerepelhet.
--
-- Mind az öt migráció idempotens: többször is lefuttatható.
-- ============================================================================


-- ===========================================================================
-- >>> 27_interview_gate.sql
-- ===========================================================================
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


-- ===========================================================================
-- >>> 28_interview_availability.sql
-- ===========================================================================
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


-- ===========================================================================
-- >>> 29_agency.sql
-- ===========================================================================
-- ============================================================
-- UniPortal Pro — Ügynökségi portál (II/3)
-- Változat: 2026-08-25, HELYI POSTGRES-REPLIKÁN MÉRVE
--
-- MIT OLD MEG (a tesztelői visszajelzések sorrendjében):
--   0. A TÖRÖTT ADATKAPCSOLAT. A students."agentId" 'A1','A2','A3'
--      értékeket tárolt, az agencies.id viszont 'AG1','AG2','AG3' —
--      a két oldal SOHA nem talált össze. A frontend ráadásul egy
--      NEM LÉTEZŐ students."agencyId" mezőre szűrt, ami a Supabase-ből
--      jövő sorokon mindig undefined, tehát a szűrés semmit nem szűrt:
--      MÉRVE, hogy az AG1 ügynök mind a 11 diákot látta (ebből 6 másé).
--      Innentől a KANONIKUS kapcsolat: students."agentId" -> agencies.id,
--      idegenkulccsal. A régi érték a "agentId_legacy" oszlopban marad.
--   1./7. Ügynökségi önregisztráció. A handle_new_user eddig CSAK profilt
--      hozott létre AGENT szerepkörrel, ügynökség-sort nem — ezért az
--      önregisztrált ügynökségek sehol nem jelentek meg. Innentől
--      függőben lévő agencies sor is születik, és az admin dönt róla
--      (agency_decide), indoklással, az auditLogs-ba naplózva.
--   2. Ügynökségi elszigetelés RLS-szinten. RESTRICTIVE policy-vel, hogy
--      a 07-es migráció "approved_all" permisszív policy-je se tudja
--      megkerülni (a permisszívek VAGY-olódnak, a restrictive AND-elődik).
--   3. Kifizetés helyett SZÁMLÁZÁS: az admin számlát IGÉNYEL, az ügynökség
--      számlát CSATOL (documents bucket), a pénzügy jóváhagy vagy elutasít.
--   4. Jutalék CSAK a beiratkozás lezárása után. Új: students."enrolled_at"
--      (a beiratkozás ténye) + agency_commission_period (a beiratkozási
--      időszak nyit/zár állapota). Év közben (open időszak) az igénylés
--      kivételt dob. A listát az ADMIN állítja össze és küldi ki.
--   5. Ügynökségi dokumentumok (szerződés, meghatalmazás) a meglévő
--      'documents' bucketre építve.
--   6. Két új adatlap-mező: country_of_origin (egy) és
--      countries_of_recruitment (több).
--
-- FUTTATÁS: Supabase dashboard -> SQL Editor -> New query -> beilleszt -> Run
-- IDEMPOTENS — kétszer lefuttatva ugyanaz az eredmény (mérve).
-- FÜGG: 01, 07, 08, 11, 25.
-- ============================================================

-- ============================================================
-- 1. SZAKASZ — A TÖRÖTT ADATKAPCSOLAT JAVÍTÁSA
-- ============================================================

-- 1.1 A régi érték megőrzése, hogy a leképezés visszakövethető legyen.
alter table public."students" add column if not exists "agentId_legacy" text;

update public."students"
   set "agentId_legacy" = "agentId"
 where "agentId_legacy" is null
   and "agentId" is not null;

-- 1.2 Leképezés: 'A<n>' -> 'AG<n>', de CSAK ha a céloldal tényleg létezik.
--     Mérve a replikán: agentId A1=5, A2=3, A3=2, NULL=1 sor;
--     agencies.id = AG1, AG2, AG3.
do $mig29_map$
declare
  n integer;
begin
  update public."students" s
     set "agentId" = 'AG' || substring(s."agentId" from '^A([0-9]+)$')
   where s."agentId" ~ '^A[0-9]+$'
     and exists (
       select 1 from public."agencies" a
        where a.id = 'AG' || substring(s."agentId" from '^A([0-9]+)$')
     );
  get diagnostics n = row_count;
  raise notice '29: % students sor kapott kanonikus agencies.id-t.', n;
end
$mig29_map$;

-- 1.3 Ami így sem talál ügynökséget, az egyéni jelentkező (NULL). A régi
--     érték nem vész el: az "agentId_legacy" megőrizte.
update public."students" s
   set "agentId" = null
 where s."agentId" is not null
   and not exists (select 1 from public."agencies" a where a.id = s."agentId");

-- 1.4 Idegenkulcs — innentől az adatbázis őrzi, hogy a lánc ép marad.
do $mig29_fk$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'students_agentid_fkey'
       and conrelid = 'public.students'::regclass
  ) then
    alter table public."students"
      add constraint students_agentid_fkey
      foreign key ("agentId") references public."agencies"(id) on delete set null;
  end if;
end
$mig29_fk$;

create index if not exists students_agentid_idx on public."students" ("agentId");

-- ============================================================
-- 2. SZAKASZ — AZ ÜGYNÖKSÉG ADATLAPJA (6. tétel) ÉS ÉLETCIKLUSA (1./7.)
-- ============================================================

-- 2.1 Két új adatlap-mező.
--     country_of_origin      : EGY érték (az ügynökség székhelye)
--     countries_of_recruitment: TÖBB érték (ahonnan toboroz)
alter table public."agencies" add column if not exists "country_of_origin" text;
alter table public."agencies" add column if not exists "countries_of_recruitment" text[] not null default '{}';

-- 2.2 Elfogadás/elutasítás — az önregisztrált ügynökség itt kap döntést.
alter table public."agencies" add column if not exists "approval_status" text not null default 'pending';
alter table public."agencies" add column if not exists "requested_by"    uuid;
alter table public."agencies" add column if not exists "requested_at"    timestamptz not null default now();
alter table public."agencies" add column if not exists "decided_by"      text;
alter table public."agencies" add column if not exists "decided_at"      timestamptz;
alter table public."agencies" add column if not exists "rejected_reason" text;
alter table public."agencies" add column if not exists "self_registered" boolean not null default false;

do $mig29_agchk$
begin
  if not exists (select 1 from pg_constraint where conname = 'agencies_approval_status_check') then
    alter table public."agencies"
      add constraint agencies_approval_status_check
      check ("approval_status" in ('pending', 'approved', 'rejected'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'agencies_requested_by_fkey') then
    alter table public."agencies"
      add constraint agencies_requested_by_fkey
      foreign key ("requested_by") references public."profiles"(id) on delete set null;
  end if;
end
$mig29_agchk$;

-- 2.3 A már meglévő (seed) ügynökségek visszamenőleg jóváhagyottak: ezekkel
--     eddig is dolgoztak a kollégák, nem tehetjük őket függővé.
update public."agencies"
   set "approval_status" = 'approved',
       "decided_at"      = coalesce("decided_at", now()),
       "decided_by"      = coalesce("decided_by", 'migration 29')
 where "approval_status" = 'pending'
   and "self_registered" = false;

create index if not exists agencies_approval_status_idx on public."agencies" ("approval_status");

-- ============================================================
-- 3. SZAKASZ — A BEIRATKOZÁS TÉNYE (4. tétel alapja)
-- ============================================================
--
-- A 25_status_model.sql fő lánca a 'Accepted' státusszal ér véget: az a
-- FELVÉTEL, nem a BEIRATKOZÁS. A jutalék viszont a ténylegesen beiratkozott
-- hallgató után jár, ezért kell egy külön, egyértelmű jelzés.
alter table public."students" add column if not exists "enrolled_at" date;

create index if not exists students_enrolled_at_idx on public."students" ("enrolled_at");

-- 3.1 Őrtrigger: a beiratkozás tényét csak ügyintéző írhatja, és csak
--     'Accepted' fő státusz mellett (a 25-ös állapotgép végállapota).
create or replace function public.students_enrollment_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE'
     and new."enrolled_at" is distinct from old."enrolled_at"
     and not public.is_staff()
     and auth.uid() is not null then
    -- Nem hibát dobunk, hanem visszaírjuk: ugyanaz a minta, mint a
    -- 11-es migráció students_protect_identity triggerénél.
    new."enrolled_at" := old."enrolled_at";
    return new;
  end if;

  if new."enrolled_at" is not null and coalesce(new."status", '') <> 'Accepted' then
    raise exception
      'A beiratkozás csak "Accepted" (Felvéve) fő státusz mellett rögzíthető (a jelenlegi: "%").',
      coalesce(new."status", '(nincs)')
      using errcode = 'check_violation';
  end if;
  return new;
end
$$;

drop trigger if exists students_enrollment_guard_trg on public."students";
create trigger students_enrollment_guard_trg
  before insert or update on public."students"
  for each row execute function public.students_enrollment_guard();

-- ============================================================
-- 4. SZAKASZ — ÚJ TÁBLÁK
-- ============================================================

-- 4.1 Ügynökségi dokumentumtár (5. tétel).
--     A fájl a MEGLÉVŐ 'documents' bucketben él (08_documents_storage.sql),
--     itt csak az elérési út és a metaadat marad. Az útvonal-konvenció
--     a 08-as policy-k miatt KÖTÖTT:  <auth.uid()>/agency/<agencyId>/<fájl>
create table if not exists public.agency_document (
  id           text primary key,
  agency_id    text not null references public."agencies"(id) on delete cascade,
  kind         text not null default 'other',
  title        text not null,
  path         text not null,
  file_name    text,
  file_size    bigint,
  valid_from   date,
  valid_until  date,
  note         text,
  uploaded_by  uuid references public."profiles"(id) on delete set null,
  uploaded_at  timestamptz not null default now()
);

do $mig29_doc$
begin
  if not exists (select 1 from pg_constraint where conname = 'agency_document_kind_check') then
    alter table public.agency_document
      add constraint agency_document_kind_check
      check (kind in ('contract', 'power_of_attorney', 'certificate', 'invoice', 'other'));
  end if;
end
$mig29_doc$;

create index if not exists agency_document_agency_idx on public.agency_document (agency_id);
create unique index if not exists agency_document_path_key on public.agency_document (path);

-- 4.2 Beiratkozási időszak (4. tétel).
--     Amíg 'open', jutalékot IGÉNYELNI SEM LEHET. A zárás admin művelete.
create table if not exists public.agency_commission_period (
  id         text primary key,
  label      text not null,
  term       text,
  opens_on   date,
  closes_on  date,
  state      text not null default 'open',
  closed_at  timestamptz,
  closed_by  text,
  created_at timestamptz not null default now()
);

do $mig29_per$
begin
  if not exists (select 1 from pg_constraint where conname = 'agency_commission_period_state_check') then
    alter table public.agency_commission_period
      add constraint agency_commission_period_state_check
      check (state in ('open', 'closed'));
  end if;
end
$mig29_per$;

-- Egy induló időszak, hogy a felület ne üres listával nyíljon.
insert into public.agency_commission_period (id, label, term, opens_on, closes_on, state)
values ('PER-2024-25-1', '2024/25 őszi beiratkozás', '2024/25/1',
        date '2024-08-01', date '2024-10-15', 'open')
on conflict (id) do nothing;

-- 4.3 Ügynökségi számla (3. + 4. tétel).
--     Az ÉLETCIKLUS SZÁNDÉKOSAN az adminnál kezdődik:
--       requested  — az admin számlát kért (a jutaléklistával együtt)
--       submitted  — az ügynökség csatolta a saját számláját
--       approved   — a pénzügy elfogadta
--       rejected   — a pénzügy visszaküldte (indoklással, újracsatolható)
--       paid       — kifizetve
--     Az ügynökség SEHOL nem tud 'requested' sort létrehozni: a jutalékot
--     nem ő igényli, hanem az admin küldi ki.
create table if not exists public.agency_invoice (
  id             text primary key,
  agency_id      text not null references public."agencies"(id) on delete cascade,
  period_id      text references public.agency_commission_period(id) on delete set null,
  status         text not null default 'requested',
  amount         numeric not null default 0,
  currency       text not null default 'EUR',
  student_count  integer not null default 0,
  requested_at   timestamptz not null default now(),
  requested_by   text,
  due_on         date,
  note           text,
  invoice_number text,
  issued_on      date,
  document_id    text references public.agency_document(id) on delete set null,
  submitted_at   timestamptz,
  submitted_by   text,
  decided_at     timestamptz,
  decided_by     text,
  reject_reason  text,
  paid_at        timestamptz
);

do $mig29_inv$
begin
  if not exists (select 1 from pg_constraint where conname = 'agency_invoice_status_check') then
    alter table public.agency_invoice
      add constraint agency_invoice_status_check
      check (status in ('requested', 'submitted', 'approved', 'rejected', 'paid'));
  end if;
end
$mig29_inv$;

create index if not exists agency_invoice_agency_idx on public.agency_invoice (agency_id);
create index if not exists agency_invoice_status_idx on public.agency_invoice (status);

-- 4.4 A számla jutalék-tételei: PILLANATKÉP a kiküldés idejéből.
--     Ha a tandíj vagy a jutalékkulcs később változik, a kiküldött számla
--     nem mozdul el alóla.
create table if not exists public.agency_commission_item (
  id           text primary key,
  invoice_id   text not null references public.agency_invoice(id) on delete cascade,
  student_id   text,
  student_name text,
  program      text,
  tuition_fee  numeric not null default 0,
  rate         numeric not null default 0,
  amount       numeric not null default 0,
  enrolled_on  date
);

create index if not exists agency_commission_item_invoice_idx on public.agency_commission_item (invoice_id);
create unique index if not exists agency_commission_item_uniq on public.agency_commission_item (invoice_id, student_id);

-- ============================================================
-- 5. SZAKASZ — RLS: AZ ÜGYNÖKSÉGI ELSZIGETELÉS (2. tétel)
-- ============================================================
--
-- MIÉRT RESTRICTIVE: a Postgres a PERMISSZÍV policy-ket VAGY-olja, tehát
-- amíg a 07-es migráció "approved_all" policy-je él (mérve: ÉL a students
-- és az agencies táblán), addig hiába szűkít a rbac_students_select — az
-- approved_all úgyis átengedi mind a 11 sort. A RESTRICTIVE policy viszont
-- AND-elődik MINDEN permisszívvel, tehát akkor is zár, ha az approved_all
-- ott marad. Mérve: az AG1 ügynök 11 -> 5 sorra esik, más ügynökség diákja 0.

drop policy if exists "agency_isolation_students" on public."students";
create policy "agency_isolation_students" on public."students"
  as restrictive for all to authenticated
  using (
    not public.is_agent()
    or (public.my_agency() is not null and "agentId" = public.my_agency())
  )
  with check (
    not public.is_agent()
    or (public.my_agency() is not null and "agentId" = public.my_agency())
  );

drop policy if exists "agency_isolation_agencies" on public."agencies";
create policy "agency_isolation_agencies" on public."agencies"
  as restrictive for all to authenticated
  using (
    not public.is_agent()
    or (public.my_agency() is not null and id = public.my_agency())
  )
  with check (
    not public.is_agent()
    or (public.my_agency() is not null and id = public.my_agency())
  );

-- 5.1 Az új táblák saját policy-készlete (a 11-es migráció "rbac_" mintája).
alter table public.agency_document          enable row level security;
alter table public.agency_commission_period enable row level security;
alter table public.agency_invoice           enable row level security;
alter table public.agency_commission_item   enable row level security;

-- agency_document
drop policy if exists "rbac_agency_document_select" on public.agency_document;
create policy "rbac_agency_document_select" on public.agency_document
  for select to authenticated
  using (public.is_staff() or (public.is_agent() and agency_id = public.my_agency()));

drop policy if exists "rbac_agency_document_insert" on public.agency_document;
create policy "rbac_agency_document_insert" on public.agency_document
  for insert to authenticated
  with check (public.is_staff() or (public.is_agent() and agency_id = public.my_agency()));

drop policy if exists "rbac_agency_document_update" on public.agency_document;
create policy "rbac_agency_document_update" on public.agency_document
  for update to authenticated
  using (public.is_staff() or (public.is_agent() and agency_id = public.my_agency()))
  with check (public.is_staff() or (public.is_agent() and agency_id = public.my_agency()));

drop policy if exists "rbac_agency_document_delete" on public.agency_document;
create policy "rbac_agency_document_delete" on public.agency_document
  for delete to authenticated
  using (public.is_staff() or (public.is_agent() and agency_id = public.my_agency() and uploaded_by = auth.uid()));

-- agency_commission_period — mindenki OLVASSA (az ügynök is lássa, hogy
-- nyitva van-e még az időszak), de csak az admin írja.
drop policy if exists "rbac_agency_period_select" on public.agency_commission_period;
create policy "rbac_agency_period_select" on public.agency_commission_period
  for select to authenticated using (public.is_approved());

drop policy if exists "rbac_agency_period_write" on public.agency_commission_period;
create policy "rbac_agency_period_write" on public.agency_commission_period
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- agency_invoice — az ügynökség LÁTJA a sajátját, de nem ír rá közvetlenül:
-- a csatolás a SECURITY DEFINER agency_invoice_attach() RPC-n megy át.
drop policy if exists "rbac_agency_invoice_select" on public.agency_invoice;
create policy "rbac_agency_invoice_select" on public.agency_invoice
  for select to authenticated
  using (public.is_staff() or (public.is_agent() and agency_id = public.my_agency()));

drop policy if exists "rbac_agency_invoice_insert" on public.agency_invoice;
create policy "rbac_agency_invoice_insert" on public.agency_invoice
  for insert to authenticated
  with check (public.is_admin() or public.is_finance());

drop policy if exists "rbac_agency_invoice_update" on public.agency_invoice;
create policy "rbac_agency_invoice_update" on public.agency_invoice
  for update to authenticated
  using (public.is_admin() or public.is_finance())
  with check (public.is_admin() or public.is_finance());

drop policy if exists "rbac_agency_invoice_delete" on public.agency_invoice;
create policy "rbac_agency_invoice_delete" on public.agency_invoice
  for delete to authenticated using (public.is_admin());

-- agency_commission_item
drop policy if exists "rbac_agency_item_select" on public.agency_commission_item;
create policy "rbac_agency_item_select" on public.agency_commission_item
  for select to authenticated
  using (
    public.is_staff()
    or exists (
      select 1 from public.agency_invoice i
       where i.id = invoice_id
         and public.is_agent()
         and i.agency_id = public.my_agency()
    )
  );

drop policy if exists "rbac_agency_item_write" on public.agency_commission_item;
create policy "rbac_agency_item_write" on public.agency_commission_item
  for all to authenticated
  using (public.is_admin() or public.is_finance())
  with check (public.is_admin() or public.is_finance());

-- 5.2 Storage: az ügynökségi dokumentumot az ügynökség MINDEN tagja lássa,
--     ne csak a feltöltő. A 08-as "documents_read" policy csak a saját
--     mappát engedi; ezt bővítjük az agency_document-ben regisztrált utakkal.
do $mig29_stor$
begin
  begin
    execute $p$drop policy if exists "documents_read" on storage.objects$p$;
    execute $p$create policy "documents_read" on storage.objects
              for select to authenticated
              using (
                bucket_id = 'documents'
                and (
                  (storage.foldername(name))[1] = auth.uid()::text
                  or public.is_staff()
                  or exists (
                    select 1 from public.agency_document d
                     where d.path = storage.objects.name
                       and public.is_agent()
                       and d.agency_id = public.my_agency()
                  )
                )
              )$p$;
  exception when others then
    raise notice '29: storage policy kihagyva (%). Allitsd be kezzel: Storage -> documents -> Policies.', sqlerrm;
  end;
end
$mig29_stor$;

-- ============================================================
-- 6. SZAKASZ — ÖNREGISZTRÁCIÓ: ÜGYNÖKSÉG-SOR IS SZÜLESSEN (1./7. tétel)
-- ============================================================
--
-- A 07-es migráció handle_new_user() függvénye eddig CSAK profiles sort
-- hozott létre AGENT szerepkörrel. Ügynökség-sor nélkül az admin
-- "Ügynökségek" listája nem tudott róla — ezért panaszkodtak a tesztelők,
-- hogy az önregisztrált ügynökségek "eltűnnek". Innentől a trigger
-- FÜGGŐBEN LÉVŐ agencies sort is létrehoz, és a profilt hozzáköti.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  wanted_role text;
  is_super    boolean;
  ag_id       text;
  ag_name     text;
  ag_countries text[];
begin
  is_super    := lower(new.email) = public.superadmin_email();
  wanted_role := upper(coalesce(new.raw_user_meta_data->>'role', 'STUDENT'));
  ag_id       := nullif(new.raw_user_meta_data->>'agencyId', '');

  -- Önregisztráló ügynök, aki NEM egy meglévő ügynökséghez csatlakozik:
  -- neki nyitunk egy függőben lévő ügynökség-sort.
  if wanted_role = 'AGENT' and not is_super and ag_id is null then
    ag_name := nullif(trim(coalesce(new.raw_user_meta_data->>'agencyName', '')), '');
    if ag_name is null then
      ag_name := coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1));
    end if;

    -- 'countries_of_recruitment': tömb vagy vesszős lista is jöhet.
    begin
      if jsonb_typeof(new.raw_user_meta_data->'agencyCountries') = 'array' then
        select coalesce(array_agg(trim(v)), '{}')
          into ag_countries
          from jsonb_array_elements_text(new.raw_user_meta_data->'agencyCountries') v
         where trim(v) <> '';
      else
        select coalesce(array_agg(trim(v)), '{}')
          into ag_countries
          from unnest(string_to_array(coalesce(new.raw_user_meta_data->>'agencyCountries', ''), ',')) v
         where trim(v) <> '';
      end if;
    exception when others then
      ag_countries := '{}';
    end;

    ag_id := 'AG-' || substr(md5(new.id::text), 1, 10);
  end if;

  -- A SORREND KÖTÖTT, és mérésből tanultuk meg: az agencies."requested_by"
  -- a profiles(id)-ra mutat, tehát a PROFIL SORNAK ELŐBB kell megszületnie.
  -- Fordított sorrendben az idegenkulcs azonnal eldobja az egész
  -- önregisztrációt ("agencies_requested_by_fkey"), és az ügynök egyáltalán
  -- nem tud regisztrálni. A profiles."agencyId" nem idegenkulcs, ezért
  -- előre beírható a még nem létező ügynökség azonosítója.
  insert into public.profiles (id, email, name, role, requested_role, "agencyId", approval_status, approved_at)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
    case when is_super then 'SUPERADMIN' else wanted_role end,
    wanted_role,
    ag_id,
    case when is_super then 'approved' else 'pending' end,
    case when is_super then now() else null end
  )
  on conflict (id) do nothing;

  -- Most már van mire hivatkoznia a requested_by-nak.
  if ag_name is not null then
    insert into public."agencies"
      (id, name, "commissionRate", "contactPerson", email, status,
       "country_of_origin", "countries_of_recruitment",
       "approval_status", "requested_by", "requested_at", "self_registered")
    values
      (ag_id, ag_name, 0,
       coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
       new.email, 'Pending',
       nullif(trim(coalesce(new.raw_user_meta_data->>'agencyCountry', '')), ''),
       coalesce(ag_countries, '{}'),
       'pending', new.id, now(), true)
    on conflict (id) do nothing;
  end if;

  return new;
end $$;

-- ============================================================
-- 7. SZAKASZ — MŰVELETEK (RPC)
-- ============================================================

-- 7.1 Az admin döntése az ügynökségi regisztrációról (1./7. tétel).
--     A döntés az auditLogs-ba kerül (log_status_event), és a jóváhagyás
--     az ügynökség felhasználói fiókjait is aktiválja — különben az admin
--     két helyen kattintana ugyanarról.
create or replace function public.agency_decide(
  p_agency   text,
  p_decision text,
  p_reason   text default null,
  p_rate     numeric default null
) returns public."agencies"
language plpgsql security definer set search_path = public as $$
declare
  ag public."agencies";
  who       text;
  jwt_saved text;
begin
  if not public.is_admin() and auth.uid() is not null then
    raise exception 'Csak SUPERADMIN vagy ADMIN dönthet ügynökségi regisztrációról.'
      using errcode = 'insufficient_privilege';
  end if;
  -- A döntéshozó nevét MOST rögzítjük: lentebb a JWT-t átmenetileg kiütjük,
  -- és utána a my_email() már nem tudná megmondani, ki döntött.
  who := coalesce(nullif(public.my_email(), ''), 'system (SQL)');
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Ismeretlen döntés: % (approved vagy rejected lehet).', p_decision
      using errcode = 'check_violation';
  end if;
  if p_decision = 'rejected' and coalesce(trim(p_reason), '') = '' then
    raise exception 'Az elutasításhoz indoklás kell.' using errcode = 'check_violation';
  end if;

  update public."agencies" a
     set "approval_status" = p_decision,
         "status"          = case when p_decision = 'approved' then 'Active' else 'Rejected' end,
         "commissionRate"  = case when p_decision = 'approved' and p_rate is not null
                                  then p_rate else a."commissionRate" end,
         "rejected_reason" = case when p_decision = 'rejected' then trim(p_reason) else null end,
         "decided_at"      = now(),
         "decided_by"      = who
   where a.id = p_agency
  returning * into ag;

  if ag.id is null then
    raise exception 'Nincs ilyen ügynökség: %', p_agency using errcode = 'no_data_found';
  end if;

  -- A hozzá tartozó fiókok együtt mozognak az ügynökséggel.
  --
  -- MÉRVE, ÉS EZÉRT NÉZ KI ÍGY: a 11-es migráció profiles_protect_privileges
  -- triggere NÉMÁN visszaírja az approval_status-t mindenkinek, aki nem
  -- SUPERADMIN és van JWT-je (nem hibát dob — egyszerűen nem történik semmi).
  -- Egy sima ADMIN döntése tehát nyom nélkül elveszett: az ügynökség
  -- jóváhagyottá vált, a hozzá tartozó fiók viszont 'pending' maradt, és a
  -- kolléga hiába próbált belépni.
  --
  -- A trigger a JWT NÉLKÜLI hívót (migráció, SQL Editor, service_role)
  -- megbízhatónak tekinti. Ez a függvény SECURITY DEFINER, a jogosultságot
  -- pedig már fent ellenőriztük, tehát erre az EGY utasításra jogosan
  -- lépünk be ezen az ajtón: a claimeket tranzakció-lokálisan kiütjük,
  -- majd visszaállítjuk. A 11-es migrációhoz nem nyúlunk.
  -- ÜRES SZTRING NEM JÓ IDE, és ezt is méréssel tanultuk meg: az auth.uid()
  -- a claimeket JSON-ként olvassa, az '' pedig érvénytelen JSON — az egész
  -- hívás elszállt volna. Az ÜRES JSON OBJEKTUM viszont mindkét oldalon
  -- (helyi replika és Supabase) szabályosan NULL azonosítót ad.
  jwt_saved := coalesce(current_setting('request.jwt.claims', true), '{}');
  perform set_config('request.jwt.claims', '{}', true);

  update public.profiles
     set approval_status = case when p_decision = 'approved' then 'approved' else 'rejected' end,
         rejected_reason = case when p_decision = 'rejected' then trim(p_reason) else null end
   where "agencyId" = p_agency
     and role = 'AGENT'
     and approval_status = 'pending';

  -- A trigger a státuszváltáskor 'sql-editor'-t ír az approved_by-ba (mert
  -- épp nincs JWT). Egy külön, státuszt NEM mozgató utasítással írjuk vissza
  -- a valódi döntéshozót — ezt a trigger már békén hagyja.
  update public.profiles
     set approved_by = who
   where "agencyId" = p_agency
     and role = 'AGENT'
     and approved_by = 'sql-editor';

  perform set_config('request.jwt.claims', coalesce(nullif(jwt_saved, ''), '{}'), true);

  perform public.log_status_event(
    'agency.' || p_decision,
    'agencies/' || ag.id,
    ag.name || ' -> ' || p_decision || coalesce(' (' || nullif(trim(p_reason), '') || ')', '')
  );
  return ag;
end
$$;

-- 7.2 A beiratkozás tényének rögzítése (ügyintéző).
create or replace function public.student_set_enrolled(
  p_student text,
  p_on      date default current_date
) returns public."students"
language plpgsql security definer set search_path = public as $$
declare st public."students";
begin
  if not public.is_staff() and auth.uid() is not null then
    raise exception 'A beiratkozást csak ügyintéző rögzítheti.' using errcode = 'insufficient_privilege';
  end if;
  update public."students" set "enrolled_at" = p_on where id = p_student returning * into st;
  if st.id is null then
    raise exception 'Nincs ilyen jelentkező: %', p_student using errcode = 'no_data_found';
  end if;
  perform public.log_status_event('student.enrolled', 'students/' || st.id,
    coalesce(st.name, st.id) || ' beiratkozott: ' || coalesce(p_on::text, '(törölve)'));
  return st;
end
$$;

-- 7.3 Beiratkozási időszak zárása / újranyitása (admin).
create or replace function public.agency_period_set_state(
  p_period text,
  p_state  text
) returns public.agency_commission_period
language plpgsql security definer set search_path = public as $$
declare pr public.agency_commission_period;
begin
  if not public.is_admin() and auth.uid() is not null then
    raise exception 'A beiratkozási időszakot csak ADMIN zárhatja vagy nyithatja.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_state not in ('open', 'closed') then
    raise exception 'Ismeretlen állapot: %', p_state using errcode = 'check_violation';
  end if;
  update public.agency_commission_period
     set state     = p_state,
         closed_at = case when p_state = 'closed' then now() else null end,
         closed_by = case when p_state = 'closed'
                          then coalesce(nullif(public.my_email(), ''), 'system (SQL)') else null end
   where id = p_period
  returning * into pr;
  if pr.id is null then
    raise exception 'Nincs ilyen időszak: %', p_period using errcode = 'no_data_found';
  end if;
  perform public.log_status_event('agency.period.' || p_state, 'agency_commission_period/' || pr.id, pr.label);
  return pr;
end
$$;

-- 7.4 Jutalék-előnézet: MELY hallgatók után jár jutalék az időszakban?
--     A lista a TÉNYLEGESEN BEIRATKOZOTT hallgatókból áll (enrolled_at),
--     nem a felvett vagy fizetett jelentkezőkből.
create or replace function public.agency_commission_preview(
  p_period text,
  p_agency text default null
) returns table (
  agency_id    text,
  agency_name  text,
  student_id   text,
  student_name text,
  program      text,
  tuition_fee  numeric,
  rate         numeric,
  amount       numeric,
  enrolled_on  date,
  already_invoiced boolean
)
language sql stable security definer set search_path = public as $$
  select a.id,
         a.name,
         s.id,
         s.name,
         s.program,
         coalesce(s."tuitionFee", 0),
         coalesce(a."commissionRate", 0),
         round(coalesce(s."tuitionFee", 0) * coalesce(a."commissionRate", 0) / 100.0, 2),
         s."enrolled_at",
         exists (
           select 1
             from public.agency_commission_item ci
             join public.agency_invoice i on i.id = ci.invoice_id
            where ci.student_id = s.id
              and i.period_id = p_period
              and i.status <> 'rejected'
         )
    from public."students" s
    join public."agencies" a on a.id = s."agentId"
    join public.agency_commission_period pr on pr.id = p_period
   where s."enrolled_at" is not null
     and s."status" = 'Accepted'
     and a."approval_status" = 'approved'
     and (pr.opens_on  is null or s."enrolled_at" >= pr.opens_on)
     and (pr.closes_on is null or s."enrolled_at" <= pr.closes_on)
     and (p_agency is null or a.id = p_agency)
     and (
       -- A rendszer-hívó (nincs JWT: psql, service_role) ugyanúgy lát, mint
       -- a többi függvényben — enélkül az admin SQL-ből hívva üres listát kap,
       -- és az agency_commission_issue tévesen "nincs elszámolható hallgató"-t jelent.
       auth.uid() is null
       or public.is_staff()
       or (public.is_agent() and a.id = public.my_agency())
     )
   order by a.name, s.name
$$;

-- 7.5 A jutalék KIKÜLDÉSE — ADMIN művelet, és CSAK LEZÁRT időszakra.
--     Ez a 4. tétel lényege: év közben (open időszak) a hívás elbukik,
--     és az ügynöknek egyáltalán nincs hívási joga.
create or replace function public.agency_commission_issue(
  p_period text,
  p_agency text,
  p_due_on date default null,
  p_note   text default null
) returns public.agency_invoice
language plpgsql security definer set search_path = public as $$
declare
  pr  public.agency_commission_period;
  ag  public."agencies";
  inv public.agency_invoice;
  n   integer := 0;
  tot numeric := 0;
begin
  if not public.is_admin() and auth.uid() is not null then
    raise exception 'A jutalék-számlaigénylést csak ADMIN küldheti ki (az ügynökség nem igényli).'
      using errcode = 'insufficient_privilege';
  end if;

  select * into pr from public.agency_commission_period where id = p_period;
  if pr.id is null then
    raise exception 'Nincs ilyen beiratkozási időszak: %', p_period using errcode = 'no_data_found';
  end if;
  if pr.state <> 'closed' then
    raise exception
      'A jutalék csak a beiratkozás LEZÁRÁSA után igényelhető. A(z) "%" időszak még nyitva van.',
      pr.label using errcode = 'check_violation';
  end if;

  select * into ag from public."agencies" where id = p_agency;
  if ag.id is null then
    raise exception 'Nincs ilyen ügynökség: %', p_agency using errcode = 'no_data_found';
  end if;
  if ag."approval_status" <> 'approved' then
    raise exception 'A(z) "%" ügynökség még nincs jóváhagyva.', ag.name using errcode = 'check_violation';
  end if;

  insert into public.agency_invoice
    (id, agency_id, period_id, status, amount, currency, student_count,
     requested_at, requested_by, due_on, note)
  values
    ('AGI-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12),
     ag.id, pr.id, 'requested', 0, 'EUR', 0,
     now(), coalesce(nullif(public.my_email(), ''), 'system (SQL)'),
     coalesce(p_due_on, (current_date + 30)), p_note)
  returning * into inv;

  insert into public.agency_commission_item
    (id, invoice_id, student_id, student_name, program, tuition_fee, rate, amount, enrolled_on)
  select 'AGC-' || substr(md5(inv.id || v.student_id), 1, 14),
         inv.id, v.student_id, v.student_name, v.program,
         v.tuition_fee, v.rate, v.amount, v.enrolled_on
    from public.agency_commission_preview(p_period, p_agency) v
   where v.already_invoiced = false
  on conflict (invoice_id, student_id) do nothing;

  select count(*), coalesce(sum(amount), 0) into n, tot
    from public.agency_commission_item where invoice_id = inv.id;

  if n = 0 then
    delete from public.agency_invoice where id = inv.id;
    raise exception
      'A(z) "%" ügynökséghez nincs elszámolható beiratkozott hallgató a(z) "%" időszakban.',
      ag.name, pr.label using errcode = 'no_data_found';
  end if;

  update public.agency_invoice
     set student_count = n, amount = tot
   where id = inv.id
  returning * into inv;

  perform public.log_status_event('agency.commission.issued', 'agency_invoice/' || inv.id,
    ag.name || ' · ' || pr.label || ' · ' || n || ' hallgató · ' || tot || ' EUR');
  return inv;
end
$$;

-- 7.6 Az ügynökség CSATOLJA a saját számláját (3. tétel).
--     A fájl a documents bucketben van; itt a dokumentum-sort kötjük rá.
create or replace function public.agency_invoice_attach(
  p_invoice   text,
  p_number    text,
  p_issued_on date,
  p_path      text,
  p_title     text default null,
  p_file_name text default null,
  p_file_size bigint default null,
  p_note      text default null
) returns public.agency_invoice
language plpgsql security definer set search_path = public as $$
declare
  inv public.agency_invoice;
  doc public.agency_document;
begin
  select * into inv from public.agency_invoice where id = p_invoice;
  if inv.id is null then
    raise exception 'Nincs ilyen számlaigénylés: %', p_invoice using errcode = 'no_data_found';
  end if;
  if auth.uid() is not null
     and not public.is_staff()
     and not (public.is_agent() and inv.agency_id = public.my_agency()) then
    raise exception 'Ehhez a számlaigényléshez nincs jogosultsága.' using errcode = 'insufficient_privilege';
  end if;
  if inv.status not in ('requested', 'rejected', 'submitted') then
    raise exception 'A(z) "%" állapotú számlához már nem csatolható új dokumentum.', inv.status
      using errcode = 'check_violation';
  end if;
  if coalesce(trim(p_number), '') = '' then
    raise exception 'A számlaszám kötelező.' using errcode = 'check_violation';
  end if;
  if coalesce(trim(p_path), '') = '' then
    raise exception 'A számla fájlját fel kell tölteni.' using errcode = 'check_violation';
  end if;

  insert into public.agency_document
    (id, agency_id, kind, title, path, file_name, file_size, note, uploaded_by, uploaded_at)
  values
    ('AGD-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12),
     inv.agency_id, 'invoice',
     coalesce(nullif(trim(p_title), ''), 'Számla ' || trim(p_number)),
     trim(p_path), p_file_name, p_file_size, p_note, auth.uid(), now())
  on conflict (path) do update
     set title = excluded.title, file_name = excluded.file_name, file_size = excluded.file_size
  returning * into doc;

  update public.agency_invoice
     set status         = 'submitted',
         invoice_number = trim(p_number),
         issued_on      = p_issued_on,
         document_id    = doc.id,
         submitted_at   = now(),
         submitted_by   = coalesce(nullif(public.my_email(), ''), 'system (SQL)'),
         reject_reason  = null,
         note           = coalesce(p_note, note)
   where id = inv.id
  returning * into inv;

  perform public.log_status_event('agency.invoice.submitted', 'agency_invoice/' || inv.id,
    'Számlaszám: ' || trim(p_number));
  return inv;
end
$$;

-- 7.7 A pénzügy / admin döntése a beérkezett számláról (3. tétel).
create or replace function public.agency_invoice_decide(
  p_invoice  text,
  p_decision text,
  p_reason   text default null
) returns public.agency_invoice
language plpgsql security definer set search_path = public as $$
declare inv public.agency_invoice;
begin
  if auth.uid() is not null and not (public.is_admin() or public.is_finance()) then
    raise exception 'A számláról csak ADMIN vagy PÉNZÜGY dönthet.' using errcode = 'insufficient_privilege';
  end if;
  if p_decision not in ('approved', 'rejected', 'paid') then
    raise exception 'Ismeretlen döntés: % (approved, rejected vagy paid).', p_decision
      using errcode = 'check_violation';
  end if;
  if p_decision = 'rejected' and coalesce(trim(p_reason), '') = '' then
    raise exception 'A visszaküldéshez indoklás kell.' using errcode = 'check_violation';
  end if;

  update public.agency_invoice
     set status        = p_decision,
         reject_reason = case when p_decision = 'rejected' then trim(p_reason) else null end,
         decided_at    = now(),
         decided_by    = coalesce(nullif(public.my_email(), ''), 'system (SQL)'),
         paid_at       = case when p_decision = 'paid' then now() else paid_at end
   where id = p_invoice
  returning * into inv;

  if inv.id is null then
    raise exception 'Nincs ilyen számla: %', p_invoice using errcode = 'no_data_found';
  end if;
  perform public.log_status_event('agency.invoice.' || p_decision, 'agency_invoice/' || inv.id,
    coalesce(inv.invoice_number, inv.id) || coalesce(' — ' || nullif(trim(p_reason), ''), ''));
  return inv;
end
$$;

-- ============================================================
-- 8. SZAKASZ — JOGOSULTSÁGOK
-- ============================================================
grant select, insert, update, delete on public.agency_document          to authenticated;
grant select, insert, update, delete on public.agency_invoice           to authenticated;
grant select, insert, update, delete on public.agency_commission_item   to authenticated;
grant select, insert, update, delete on public.agency_commission_period to authenticated;

grant execute on function public.agency_decide(text, text, text, numeric)                        to authenticated;
grant execute on function public.student_set_enrolled(text, date)                                to authenticated;
grant execute on function public.agency_period_set_state(text, text)                             to authenticated;
grant execute on function public.agency_commission_preview(text, text)                           to authenticated;
grant execute on function public.agency_commission_issue(text, text, date, text)                 to authenticated;
grant execute on function public.agency_invoice_attach(text, text, date, text, text, text, bigint, text) to authenticated;
grant execute on function public.agency_invoice_decide(text, text, text)                         to authenticated;
grant execute on function public.students_enrollment_guard()                                     to authenticated;

-- ============================================================
-- 9. SZAKASZ — VISSZAÁLLÍTÁS (ha valami félremegy)
-- ============================================================
create or replace function public.agency_module_rollback(p_confirm text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if p_confirm <> 'IGEN, TOROLD' then
    return 'Nem történt semmi. Hívás: select public.agency_module_rollback(''IGEN, TOROLD'');';
  end if;
  drop policy if exists "agency_isolation_students" on public."students";
  drop policy if exists "agency_isolation_agencies" on public."agencies";
  drop trigger if exists students_enrollment_guard_trg on public."students";
  drop table if exists public.agency_commission_item cascade;
  drop table if exists public.agency_invoice cascade;
  drop table if exists public.agency_commission_period cascade;
  drop table if exists public.agency_document cascade;
  -- Az adatátvezetés visszafordítása: a régi 'A<n>' érték visszaírása.
  alter table public."students" drop constraint if exists students_agentid_fkey;
  update public."students" set "agentId" = "agentId_legacy" where "agentId_legacy" is not null;
  return 'Az ügynökségi modul (29) visszaállítva. Az agencies új oszlopai megmaradtak.';
end
$$;

-- ============================================================
-- 10. SZAKASZ — ELLENŐRZÉS
-- ============================================================
select 'students.agentId -> agencies.id kotes' as mit,
       count(*) filter (where "agentId" is not null) as kotott,
       count(*) filter (where "agentId" is null)     as egyeni,
       count(*)                                      as osszes
  from public."students";

select 'agencies allapot' as mit, "approval_status", count(*)
  from public."agencies" group by 2 order by 2;

select 'uj tablak' as mit, table_name
  from information_schema.tables
 where table_schema = 'public'
   and table_name in ('agency_document', 'agency_invoice',
                      'agency_commission_period', 'agency_commission_item')
 order by 2;

select 'restrictive policy-k (2 kell)' as mit, count(*)
  from pg_policies
 where schemaname = 'public'
   and policyname in ('agency_isolation_students', 'agency_isolation_agencies');

select 'uj RPC-k (7 kell)' as mit, count(*)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('agency_decide', 'student_set_enrolled', 'agency_period_set_state',
                     'agency_commission_preview', 'agency_commission_issue',
                     'agency_invoice_attach', 'agency_invoice_decide');


-- ===========================================================================
-- >>> 30_interview_gate_hardening.sql
-- ===========================================================================
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


-- ===========================================================================
-- >>> 31_interview_integrity.sql
-- ===========================================================================
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

