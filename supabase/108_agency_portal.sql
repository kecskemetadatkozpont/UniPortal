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
