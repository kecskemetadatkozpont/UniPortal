-- ============================================================================
-- RUN_ALL_107_110.sql — a négy hátralévő migráció EGY futásban
-- ============================================================================
-- Ez a szkript a 107-et, a 108-at, a 109-et és a 110-et is telepíti, a végén a szokásos
-- 21_echo_harden_submit.sql újrafuttatással. A három szkriptet külön már nem
-- kell lefuttatni.
--
-- Egy tranzakció, egy másolás-beillesztés a Supabase SQL Editorba. Ha bármi
-- elhasal, a teljes szkript visszaáll, és semmi nem települ félig.
--
--   107 — VÍZUM: az iroda vízum-bejegyzését (data.visa_iroda) a jelentkező
--         közvetlen írása nem törölheti. MÉRVE: nélküle a hallgatói mentés
--         KITÖRLI az irodai bejegyzést, vele érintetlenül hagyja.
--   108 — ÜGYNÖKSÉGI PORTÁL: az ügynök–diák hozzárendelés a jelentkezés során
--         (agency_id), jelentkeztetés a diák nevében, marketinganyagok,
--         ügynökségi üzenetek. MÉRVE: a másik ügynökség 0 sort lát és nem ír.
--   109 — NEM MINDEN DOKUMENTUM KÖTELEZŐ: a képzésnél megjelölhető, melyik
--         kért dokumentum opcionális (külügyi iroda, 2026-09-30).
--   110 — AZ ÜGYNÖKSÉGI TESZT HIBÁI: szigorúbb duplikátum-védelem (ékezetes
--         cím elutasítva, másik ügynökség sorát nem veszi át), és a
--         marketinganyagok letölthetők az ügynöknek (tároló-szabály).
--
-- MINDHÁROM FELÜLET MŰKÖDIK A MIGRÁCIÓ NÉLKÜL IS — csak az adott funkció
-- marad kikapcsolva, és ezt a felület kimondja.
--
-- IDEMPOTENS: kétszer lefuttatva ugyanaz az eredmény.
-- ============================================================================

-- ####################################################################
-- ### 107_vizum_iroda_kulcs.sql
-- ####################################################################

-- ============================================================
-- 107_vizum_iroda_kulcs.sql
-- A VÍZUM-NYILVÁNTARTÁS IRODAI BEJEGYZÉSÉNEK VÉDELME
-- ============================================================
-- MIÉRT: a felvett hallgatónak vízumot kell szereznie a beutazáshoz. A
-- felület két külön bejegyzést tart nyilván a jelentkezés data mezőjében:
--
--   data.visa        — a HALLGATÓ bejelentése („beadtam", „megkaptam")
--   data.visa_iroda  — az IRODA nyilvántartása (ő látta a vízumot)
--
-- A kettő nem ugyanaz: az egyik önbevallás, a másik igazolás. Ha a hallgató
-- felül tudná írni az irodai bejegyzést, az ügyintéző egy olyan „igazolást"
-- látna, amit nem ő adott — épp azt veszítenénk el, amiért a két mező külön
-- van. A 60-as migráció védelme (admission_processes_protect_office_keys)
-- pontosan ezt tudja: a felsorolt FELSŐ SZINTŰ kulcsokat a közvetlen
-- (PostgREST) írás nem módosíthatja, csak az iroda és a SECURITY DEFINER
-- RPC-k. Ez a szkript kiegészíti a kulcslistát.
--
-- A FELÜLET ENÉLKÜL IS MŰKÖDIK: ha ez a szkript nem fut le, a vízum-jelölés
-- ugyanúgy használható, csak a hallgatói oldalról elvileg felülírható.
--
-- MIT VÁRJ A FUTÁS VÉGÉN: egyetlen sor, három kulccsal:
--   {decision,interview,visa_iroda}
-- ============================================================

create or replace function public.admission_office_keys()
returns text[] language sql immutable as $fn$
  select array['decision', 'interview', 'visa_iroda']::text[]
$fn$;

revoke all on function public.admission_office_keys() from public, anon;
grant execute on function public.admission_office_keys() to authenticated;

comment on function public.admission_office_keys() is
  'A jelentkezés data mezőjének IRODAI kulcsai: ezeket a jelentkező közvetlen írása nem módosíthatja (60-as trigger). visa_iroda: a vízum irodai nyilvántartása (107).';

-- ---------------------------------------------------------------------------
-- Záró ellenőrzés
-- ---------------------------------------------------------------------------
do $$
declare
  v text[];
begin
  select public.admission_office_keys() into v;
  if not ('visa_iroda' = any(v)) then
    raise exception 'A visa_iroda kulcs nem került be a vedett listaba: %', v;
  end if;
  raise notice 'Rendben: 107 — vedett irodai kulcsok: %', v;
end $$;

select public.admission_office_keys() as vedett_irodai_kulcsok;


-- ####################################################################
-- ### 108_agency_portal.sql
-- ####################################################################

-- ============================================================
-- 108_agency_portal.sql — ÜGYNÖKSÉGI PORTÁL: jelentkeztetés, diáklista,
-- marketinganyagok, üzenetek
-- ============================================================
-- MIÉRT: az ügynökségi felület eddig a DEMO `students` táblára épült, a
-- valódi jelentkezés viszont az `admission_processes` sorokban él. Az ügynök
-- így nem tudott jelentkezést indítani, és a diákjai valódi állapotát
-- (hiányzó dokumentum, hol tart a folyamat) sem látta.
--
-- A LEGFONTOSABB, AMIT EZ MEGOLD: az ÜGYNÖK–DIÁK HOZZÁRENDELÉS. Eddig csak
-- közvetett kapcsolat volt (students."agentId" + e-mail-egyezés), ami az
-- e-mail elgépelésénél vagy megváltozásánál elszakad — és utólag nem lehet
-- eldönteni, ki hozta a diákot. Mostantól a jelentkezés SORA hordozza az
-- ügynökséget (admission_processes.agency_id), idegenkulccsal.
--
-- MIT TELEPÍT
--   1. admission_processes.agency_id + index + visszatöltés a students-ből
--   2. a nézet (admission_process_list) kiegészítése az oszloppal
--   3. RLS: az ügynök a SAJÁT ügynöksége jelentkezéseit látja és szerkeszti
--   4. agency_application_start() — jelentkezés indítása a diák nevében
--   5. agency_asset — letölthető marketinganyagok (iroda tölti, ügynök tölti le)
--   6. agency_message (+ olvasás-jelölés) — koordinátori körlevél, hiánypótlás,
--      döntésértesítő, és ezek olvasottsága ügynökönként
--
-- IDEMPOTENS — kétszer lefuttatva ugyanaz az eredmény.
-- FÜGG: 01, 09, 11, 29.
-- ============================================================

-- ============================================================
-- 1. AZ ÜGYNÖK–DIÁK HOZZÁRENDELÉS A JELENTKEZÉS SORÁN
-- ============================================================
alter table public.admission_processes
  add column if not exists agency_id text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'admission_processes_agency_fk'
  ) then
    alter table public.admission_processes
      add constraint admission_processes_agency_fk
      foreign key (agency_id) references public.agencies(id) on delete set null;
  end if;
end $$;

create index if not exists admission_processes_agency_idx
  on public.admission_processes (agency_id, updated_at desc);

comment on column public.admission_processes.agency_id is
  'Melyik ügynökség hozta ezt a jelentkezőt. A sor HORDOZZA a kapcsolatot: az e-mail-egyezésre épülő korábbi út elszakadt, ha a diák e-mailt váltott (108).';

-- Visszatöltés: ami a students táblából egyértelműen kiderül.
-- Csak ÜRES agency_id-t tölt ki — meglévő hozzárendelést nem ír át.
update public.admission_processes p
   set agency_id = s."agentId"
  from public.students s
 where p.agency_id is null
   and s."agentId" is not null
   and lower(s.email) = lower(p.owner_email)
   and exists (select 1 from public.agencies a where a.id = s."agentId");

-- ============================================================
-- 2. A LISTA-NÉZET IS VIGYE AZ OSZLOPOT
--    (a nézet security_invoker, tehát a hívó RLS-e érvényesül rajta)
-- ============================================================
drop view if exists public.admission_process_list;
create view public.admission_process_list
with (security_invoker = on) as
select
  id, ref_no, owner_email, step, max_reached, done, created_at, updated_at,
  program_id, applicant_name, stage, student_step, submitted_at, agency_id,
  coalesce(data, '{}'::jsonb) || jsonb_build_object(
    'docs',
    coalesce((select jsonb_object_agg(d.key, d.value - 'dataUrl')
                from jsonb_each(coalesce(p.data -> 'docs', '{}'::jsonb)) d), '{}'::jsonb)
  ) as data
from public.admission_processes p;

grant select on public.admission_process_list to authenticated;

-- ============================================================
-- 3. RLS — AZ ÜGYNÖK A SAJÁT ÜGYNÖKSÉGE JELENTKEZÉSEIT KEZELI
--    A 11-es migráció policy-jeit írjuk újra, egy ággal bővítve.
-- ============================================================
drop policy if exists "rbac_admission_processes_select" on public.admission_processes;
create policy "rbac_admission_processes_select" on public.admission_processes
  for select to authenticated
  using (
    public.is_staff()
    or lower(owner_email) = public.my_email()
    or public.is_my_agency_student_email(owner_email)
    or (agency_id is not null and agency_id = public.my_agency())
  );

drop policy if exists "rbac_admission_processes_insert" on public.admission_processes;
create policy "rbac_admission_processes_insert" on public.admission_processes
  for insert to authenticated
  with check (
    public.is_staff()
    or lower(owner_email) = public.my_email()
    -- Az ügynök CSAK a saját ügynökségéhez kötve szúrhat be.
    or (agency_id is not null and agency_id = public.my_agency())
  );

drop policy if exists "rbac_admission_processes_update" on public.admission_processes;
create policy "rbac_admission_processes_update" on public.admission_processes
  for update to authenticated
  using (
    public.is_staff()
    or lower(owner_email) = public.my_email()
    or (agency_id is not null and agency_id = public.my_agency())
  )
  with check (
    public.is_staff()
    or lower(owner_email) = public.my_email()
    or (agency_id is not null and agency_id = public.my_agency())
  );

-- A TÖRLÉS SZÁNDÉKOSAN NEM BŐVÜL: az ügynök nem törölhet jelentkezést.
-- Visszavonni a hallgató (vagy az iroda) tud, és az is csak megjelöli.

-- ============================================================
-- 4. JELENTKEZÉS INDÍTÁSA A DIÁK NEVÉBEN
-- ============================================================
create or replace function public.agency_application_start(
  p_name text,
  p_email text,
  p_country text default null,
  p_program_ids jsonb default '[]'::jsonb,
  p_term text default null
) returns public.admission_processes
language plpgsql security definer set search_path = public
as $fn$
declare
  v_agency text := public.my_agency();
  v_email  text := lower(nullif(btrim(p_email), ''));
  v_id     text;
  v_student text;
  v_sor    public.admission_processes;
begin
  if v_agency is null and not public.is_staff() then
    raise exception 'AGENCY_REQUIRED: csak ügynökségi fiók indíthat így jelentkezést.';
  end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'EMAIL_INVALID: érvényes e-mail-cím kell a jelentkezőhöz.';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'NAME_REQUIRED: a jelentkező neve kötelező.';
  end if;

  -- Ugyanarra az e-mailre NE szülessen második, párhuzamos piszkozat.
  select * into v_sor
    from public.admission_processes
   where lower(owner_email) = v_email
     and stage = 'student'
     and coalesce(data->>'_cancelled', 'false') <> 'true'
   order by updated_at desc
   limit 1;
  if found then
    -- Meglévő piszkozat: az ügynökséghez kötjük, ha még nincs kötve.
    if v_sor.agency_id is null and v_agency is not null then
      update public.admission_processes set agency_id = v_agency, updated_at = now()
       where id = v_sor.id returning * into v_sor;
    end if;
    return v_sor;
  end if;

  -- A students sor a jutalékelszámolás alapja (29-es migráció), ezért itt is
  -- létrehozzuk/kötjük — de a jelentkezés kapcsolatát már az agency_id adja.
  select id into v_student from public.students where lower(email) = v_email limit 1;
  if v_student is null then
    v_student := 'S-' || substr(md5(v_email || clock_timestamp()::text), 1, 10);
    /* A státusz ÉRTÉKKÉSZLETE KÖTÖTT (students_status_insert_guard): új
       jelentkezőnél 'Draft' az egyetlen helyes kezdőérték — MÉRVE, az
       'Applied' kivételt dobott. A státuszt innentől a felvételi folyamat
       lépteti, nem az ügynök. */
    insert into public.students (id, name, email, "agentId", status, "appliedAt", country)
    values (v_student, btrim(p_name), v_email, v_agency, 'Draft',
            to_char(now(), 'YYYY-MM-DD'), nullif(btrim(coalesce(p_country, '')), ''))
    on conflict (id) do nothing;
  elsif v_agency is not null then
    update public.students
       set "agentId" = coalesce("agentId", v_agency),
           name = coalesce(nullif(btrim(name), ''), btrim(p_name)),
           country = coalesce(country, nullif(btrim(coalesce(p_country, '')), ''))
     where id = v_student;
  end if;

  v_id := 'APP-' || substr(md5(v_email || clock_timestamp()::text), 1, 12);
  insert into public.admission_processes
    (id, owner_email, applicant_name, stage, student_step, step, max_reached, done,
     agency_id, created_at, updated_at, program_id, data)
  values
    (v_id, v_email, btrim(p_name), 'student', 0, 0, 0, false,
     v_agency, to_char(now(), 'YYYY-MM-DD'), now(),
     nullif(p_program_ids->>0, ''),
     jsonb_build_object(
       'program_ids', coalesce(p_program_ids, '[]'::jsonb),
       'term', nullif(btrim(coalesce(p_term, '')), ''),
       'personal', jsonb_build_object('name', btrim(p_name), 'email', v_email,
                                      'country', nullif(btrim(coalesce(p_country, '')), '')),
       'docs', '{}'::jsonb,
       '_agency_started', jsonb_build_object('agency_id', v_agency, 'at', to_char(now(), 'YYYY-MM-DD'))
     ))
  returning * into v_sor;

  return v_sor;
end
$fn$;

revoke all on function public.agency_application_start(text, text, text, jsonb, text) from public, anon;
grant execute on function public.agency_application_start(text, text, text, jsonb, text) to authenticated;

-- ============================================================
-- 5. LETÖLTHETŐ MARKETINGANYAGOK
-- ============================================================
create table if not exists public.agency_asset (
  id          text primary key,
  title       text not null,
  description text,
  kind        text not null default 'other',   -- brochure | logo | photo | presentation | other
  path        text,                            -- documents bucket
  link        text,                            -- vagy külső hivatkozás
  file_name   text,
  file_size   bigint,
  lang        text default 'hu',
  is_active   boolean not null default true,
  uploaded_by text,
  uploaded_at timestamptz not null default now()
);
create index if not exists agency_asset_active_idx on public.agency_asset (is_active, uploaded_at desc);
comment on table public.agency_asset is
  'Letölthető marketinganyagok az ügynökségeknek (brosúra, logó, fotó). Az iroda tölti fel, MINDEN jóváhagyott ügynökség látja (108).';

alter table public.agency_asset enable row level security;

drop policy if exists "agency_asset_select" on public.agency_asset;
create policy "agency_asset_select" on public.agency_asset
  for select to authenticated
  using (public.is_staff() or (is_active and public.my_agency() is not null));

drop policy if exists "agency_asset_write" on public.agency_asset;
create policy "agency_asset_write" on public.agency_asset
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

grant select on public.agency_asset to authenticated;
grant insert, update, delete on public.agency_asset to authenticated;

-- ============================================================
-- 6. ÜZENETEK AZ ÜGYNÖKSÉGEKNEK
--    Körlevél (minden ügynökségnek) vagy címzett üzenet; a hiánypótlási
--    felszólítás és a döntésértesítő a jelentkezésre is hivatkozhat.
-- ============================================================
create table if not exists public.agency_message (
  id          text primary key,
  agency_id   text references public.agencies(id) on delete cascade,  -- NULL = körlevél mindenkinek
  process_id  text references public.admission_processes(id) on delete set null,
  kind        text not null default 'notice',  -- notice | circular | missing_docs | decision
  subject     text not null,
  body        text not null,
  sent_by     text,
  sent_at     timestamptz not null default now()
);
create index if not exists agency_message_agency_idx on public.agency_message (agency_id, sent_at desc);
comment on table public.agency_message is
  'Az irodától az ügynökségeknek: körlevél, hiánypótlási felszólítás, döntésértesítő (108). agency_id IS NULL = mindenkinek szóló körlevél.';

create table if not exists public.agency_message_read (
  message_id text not null references public.agency_message(id) on delete cascade,
  profile_id uuid not null,
  read_at    timestamptz not null default now(),
  primary key (message_id, profile_id)
);

alter table public.agency_message enable row level security;
alter table public.agency_message_read enable row level security;

drop policy if exists "agency_message_select" on public.agency_message;
create policy "agency_message_select" on public.agency_message
  for select to authenticated
  using (
    public.is_staff()
    or (public.my_agency() is not null and (agency_id is null or agency_id = public.my_agency()))
  );

drop policy if exists "agency_message_write" on public.agency_message;
create policy "agency_message_write" on public.agency_message
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists "agency_message_read_own" on public.agency_message_read;
create policy "agency_message_read_own" on public.agency_message_read
  for all to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

grant select on public.agency_message to authenticated;
grant insert, update, delete on public.agency_message to authenticated;
grant select, insert, delete on public.agency_message_read to authenticated;

-- Küldés (iroda)
create or replace function public.agency_message_send(
  p_agency text, p_subject text, p_body text,
  p_kind text default 'notice', p_process text default null
) returns public.agency_message
language plpgsql security definer set search_path = public
as $fn$
declare v_sor public.agency_message;
begin
  if not coalesce(public.is_staff(), false) then
    raise exception 'STAFF_ONLY: üzenetet csak ügyintéző küldhet az ügynökségeknek.';
  end if;
  if nullif(btrim(coalesce(p_subject, '')), '') is null
     or nullif(btrim(coalesce(p_body, '')), '') is null then
    raise exception 'EMPTY: a tárgy és az üzenet sem lehet üres.';
  end if;
  insert into public.agency_message (id, agency_id, process_id, kind, subject, body, sent_by)
  values ('AMSG-' || substr(md5(clock_timestamp()::text || coalesce(p_subject, '')), 1, 12),
          nullif(btrim(coalesce(p_agency, '')), ''), nullif(btrim(coalesce(p_process, '')), ''),
          coalesce(nullif(btrim(coalesce(p_kind, '')), ''), 'notice'),
          btrim(p_subject), btrim(p_body),
          coalesce((select name from public.profiles where id = auth.uid()), public.my_email()))
  returning * into v_sor;
  return v_sor;
end
$fn$;

revoke all on function public.agency_message_send(text, text, text, text, text) from public, anon;
grant execute on function public.agency_message_send(text, text, text, text, text) to authenticated;

-- A saját üzeneteim, olvasottsággal
create or replace function public.agency_messages()
returns table (
  id text, agency_id text, process_id text, kind text, subject text, body text,
  sent_by text, sent_at timestamptz, olvasott boolean
)
language sql stable security definer set search_path = public
as $fn$
  select m.id, m.agency_id, m.process_id, m.kind, m.subject, m.body, m.sent_by, m.sent_at,
         exists (select 1 from public.agency_message_read r
                  where r.message_id = m.id and r.profile_id = auth.uid()) as olvasott
    from public.agency_message m
   where public.is_staff()
      or (public.my_agency() is not null
          and (m.agency_id is null or m.agency_id = public.my_agency()))
   order by m.sent_at desc
   limit 200
$fn$;

revoke all on function public.agency_messages() from public, anon;
grant execute on function public.agency_messages() to authenticated;

create or replace function public.agency_message_mark_read(p_id text)
returns boolean language plpgsql security definer set search_path = public
as $fn$
begin
  if auth.uid() is null then return false; end if;
  insert into public.agency_message_read (message_id, profile_id)
  values (p_id, auth.uid())
  on conflict (message_id, profile_id) do nothing;
  return true;
end
$fn$;

revoke all on function public.agency_message_mark_read(text) from public, anon;
grant execute on function public.agency_message_mark_read(text) to authenticated;

-- ============================================================
-- 7. ZÁRÓ ELLENŐRZÉS
-- ============================================================
do $$
declare
  v_kotott integer;
begin
  if not exists (select 1 from information_schema.columns
                  where table_name = 'admission_processes' and column_name = 'agency_id') then
    raise exception 'Hiányzik az admission_processes.agency_id oszlop.';
  end if;
  select count(*) into v_kotott from public.admission_processes where agency_id is not null;
  raise notice 'Rendben: 108 — ügynökségi portál telepítve. Ügynökséghez kötött jelentkezés: %', v_kotott;
end $$;

select
  (select count(*) from public.admission_processes where agency_id is not null) as ugynokseghez_kotott_jelentkezes,
  (select count(*) from public.agency_asset)   as marketinganyag,
  (select count(*) from public.agency_message) as ugynoksegi_uzenet;


-- ####################################################################
-- ### 109_program_optional_docs.sql
-- ####################################################################

-- ============================================================
-- 109_program_optional_docs.sql — NEM MINDEN DOKUMENTUM KÖTELEZŐ
-- ============================================================
-- MIÉRT (külügyi iroda, 2026-09-30): a képzésnél felsorolt dokumentumok MIND
-- kötelezők voltak, a jelentkezés csak akkor lépett tovább, ha a jelentkező
-- mindet feltöltötte. Így egy alapképzésre jelentkezőtől is kutatási tervet
-- (research proposal) kért a rendszer, holott az csak doktori szinten kell.
--
-- A megoldás nem az, hogy kivesszük a listából: a dokumentum KÉRHETŐ marad,
-- csak nem AKADÁLY. Aki be tudja adni, adja be — akinek nincs, továbbléphet.
--
-- MIT TELEPÍT: egy oszlop a programs táblán, azoknak a dokumentumkulcsoknak,
-- amelyek a required_docs listában szerepelnek, de NEM kötelezők.
--
-- A FELÜLET ENÉLKÜL IS MŰKÖDIK: amíg ez nem fut le, a szerkesztő nem küldi el
-- a mezőt (ugyanaz a minta, mint a 85-ös célközönség-oszlopnál), és minden
-- dokumentum kötelező marad — vagyis a mai viselkedés.
--
-- IDEMPOTENS. FÜGG: 01/05 (programs), 58 (dokumentumtípusok).
-- ============================================================

alter table public.programs
  add column if not exists optional_docs jsonb not null default '[]'::jsonb;

comment on column public.programs.optional_docs is
  'A required_docs közül azok a kulcsok, amelyek KÉRHETŐK, de nem kötelezők: hiányukban is tovább lehet lépni (109).';

-- Biztonsági háló: csak tömb kerülhet bele.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'programs_optional_docs_ck') then
    alter table public.programs
      add constraint programs_optional_docs_ck
      check (jsonb_typeof(optional_docs) = 'array');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Záró ellenőrzés
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_name = 'programs' and column_name = 'optional_docs') then
    raise exception 'Hianyzik a programs.optional_docs oszlop.';
  end if;
  raise notice 'Rendben: 109 — a kepzesnel megjelolheto, mely dokumentum nem kotelezo.';
end $$;

select id, name, required_docs, optional_docs from public.programs order by name limit 20;


-- ####################################################################
-- ### 110_agency_fixes.sql
-- ####################################################################

-- ============================================================
-- 110_agency_fixes.sql — az ügynökségi portál teszthibái
-- (tesztmérnöki jegyzőkönyv, 2026-09-30)
-- ============================================================
-- MIT JAVÍT
--   1. DUPLIKÁTUM-VÉDELEM. Mérve: ugyanarra a jelentkezőre két folyamat
--      született (FV-01626 és FV-01627), mert az e-mail-cím ékezetben tért el.
--      Ráadásul ha a MÁSIK ügynökség adta hozzá ugyanazt a címet, a felület
--      szó nélkül továbblépett a jelentkezési folyamatra — olyan sorra,
--      amelyet az az ügynök nem is lát. Mostantól:
--        · ékezetes (nem ASCII) e-mail-címet nem fogadunk el — a gyakorlatban
--          ez elgépelés, és pont ez okozta a duplikálást;
--        · ha az élő jelentkezés MÁSIK ügynökséghez tartozik, a hívás HIBÁT
--          dob, nem adja vissza a sort.
--   2. MARKETINGANYAGOK LETÖLTÉSE. Mérve: az ügynök nem tudta letölteni
--      („A fájl most nem érhető el"), mert a documents tároló olvasási
--      szabálya csak a SAJÁT mappát engedi (első útvonalszegmens = auth.uid()),
--      a marketinganyagot pedig az iroda tölti fel. Új szabály: a
--      'marketing/' előtagú fájlokat MINDEN ügynökségi fiók olvashatja,
--      írni csak ügyintéző tud.
--
-- IDEMPOTENS. FÜGG: 08 (documents tároló), 29, 108.
-- ============================================================

-- ============================================================
-- 1. SZIGORÚBB JELENTKEZTETÉS
-- ============================================================
create or replace function public.agency_application_start(
  p_name text,
  p_email text,
  p_country text default null,
  p_program_ids jsonb default '[]'::jsonb,
  p_term text default null
) returns public.admission_processes
language plpgsql security definer set search_path = public
as $fn$
declare
  v_agency text := public.my_agency();
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_id     text;
  v_student text;
  v_sor    public.admission_processes;
begin
  if v_agency is null and not public.is_staff() then
    raise exception 'AGENCY_REQUIRED: csak ügynökségi fiók indíthat így jelentkezést.';
  end if;
  if v_email = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'EMAIL_INVALID: érvényes e-mail-cím kell a jelentkezőhöz.';
  end if;
  /* ÉKEZETES E-MAIL-CÍM: a gyakorlatban elgépelés (test.béla@… a test.bela@…
     helyett), és pont ez hozott létre két jelentkezést ugyanarra a diákra.
     Inkább megállunk, mint hogy duplikátum szülessen. */
  if v_email ~ '[^\x20-\x7E]' then
    raise exception 'EMAIL_NOT_ASCII: az e-mail-cím nem tartalmazhat ékezetes betűt — ellenőrizd az elgépelést.';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'NAME_REQUIRED: a jelentkező neve kötelező.';
  end if;

  -- Van-e már ÉLŐ (nem megszakított) folyamat erre a címre?
  select * into v_sor
    from public.admission_processes
   where lower(owner_email) = v_email
     and coalesce(data->>'_cancelled', 'false') <> 'true'
   order by (stage = 'student') desc, updated_at desc
   limit 1;

  if found then
    -- MÁSIK ÜGYNÖKSÉG diákja: ne lépjünk tovább egy nem látható sorra.
    if v_sor.agency_id is not null and v_agency is not null and v_sor.agency_id <> v_agency then
      raise exception 'EMAIL_TAKEN_BY_OTHER_AGENCY: erre az e-mail-címre már van jelentkezés, amelyet egy másik ügynökség indított. Egyeztess a felvételi irodával.';
    end if;
    -- Saját (vagy még ügynökséghez nem kötött) sor: kössük és adjuk vissza.
    if v_sor.agency_id is null and v_agency is not null then
      update public.admission_processes set agency_id = v_agency, updated_at = now()
       where id = v_sor.id returning * into v_sor;
    end if;
    return v_sor;
  end if;

  select id into v_student from public.students where lower(email) = v_email limit 1;
  if v_student is null then
    v_student := 'S-' || substr(md5(v_email || clock_timestamp()::text), 1, 10);
    insert into public.students (id, name, email, "agentId", status, "appliedAt", country)
    values (v_student, btrim(p_name), v_email, v_agency, 'Draft',
            to_char(now(), 'YYYY-MM-DD'), nullif(btrim(coalesce(p_country, '')), ''))
    on conflict (id) do nothing;
  elsif v_agency is not null then
    update public.students
       set "agentId" = coalesce("agentId", v_agency),
           name = coalesce(nullif(btrim(name), ''), btrim(p_name)),
           country = coalesce(country, nullif(btrim(coalesce(p_country, '')), ''))
     where id = v_student;
  end if;

  v_id := 'APP-' || substr(md5(v_email || clock_timestamp()::text), 1, 12);
  insert into public.admission_processes
    (id, owner_email, applicant_name, stage, student_step, step, max_reached, done,
     agency_id, created_at, updated_at, program_id, data)
  values
    (v_id, v_email, btrim(p_name), 'student', 0, 0, 0, false,
     v_agency, to_char(now(), 'YYYY-MM-DD'), now(),
     nullif(p_program_ids->>0, ''),
     jsonb_build_object(
       'program_ids', coalesce(p_program_ids, '[]'::jsonb),
       'term', nullif(btrim(coalesce(p_term, '')), ''),
       'personal', jsonb_build_object('name', btrim(p_name), 'email', v_email,
                                      'country', nullif(btrim(coalesce(p_country, '')), '')),
       'docs', '{}'::jsonb,
       '_agency_started', jsonb_build_object('agency_id', v_agency, 'at', to_char(now(), 'YYYY-MM-DD'))
     ))
  returning * into v_sor;

  return v_sor;
end
$fn$;

revoke all on function public.agency_application_start(text, text, text, jsonb, text) from public, anon;
grant execute on function public.agency_application_start(text, text, text, jsonb, text) to authenticated;

-- ============================================================
-- 2. MARKETINGANYAGOK: A 'marketing/' ELŐTAG MINDEN ÜGYNÖKSÉGNEK OLVASHATÓ
-- ============================================================
do $mkt$
begin
  begin
    execute $p$drop policy if exists "documents_read_marketing" on storage.objects$p$;
    execute $p$create policy "documents_read_marketing" on storage.objects
              for select to authenticated
              using (
                bucket_id = 'documents'
                and (storage.foldername(name))[1] = 'marketing'
                and (public.is_staff() or public.my_agency() is not null)
              )$p$;

    execute $p$drop policy if exists "documents_write_marketing" on storage.objects$p$;
    execute $p$create policy "documents_write_marketing" on storage.objects
              for insert to authenticated
              with check (
                bucket_id = 'documents'
                and (storage.foldername(name))[1] = 'marketing'
                and public.is_staff()
              )$p$;

    execute $p$drop policy if exists "documents_delete_marketing" on storage.objects$p$;
    execute $p$create policy "documents_delete_marketing" on storage.objects
              for delete to authenticated
              using (
                bucket_id = 'documents'
                and (storage.foldername(name))[1] = 'marketing'
                and public.is_staff()
              )$p$;
  exception when others then
    raise notice 'A marketing tarolo-szabalyok kihagyva (%). Allitsd be kezzel: Storage -> documents -> Policies.', sqlerrm;
  end;
end
$mkt$;

-- ============================================================
-- 3. ZÁRÓ ELLENŐRZÉS
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'agency_application_start') then
    raise exception 'Hianyzik az agency_application_start fuggveny.';
  end if;
  raise notice 'Rendben: 110 — szigorubb jelentkeztetes + marketinganyag-letoltes.';
end $$;

select polname as tarolo_szabaly
  from pg_policy
 where polname like 'documents_%marketing%'
 order by polname;


-- ####################################################################
-- ### 21_echo_harden_submit.sql
-- ####################################################################

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
