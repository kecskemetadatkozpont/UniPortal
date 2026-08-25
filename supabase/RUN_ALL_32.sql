-- ============================================================================
-- RUN_ALL_32.sql  —  UniPortal
-- EGYBEN BEILLESZTHETŐ a Supabase SQL Editorba.
--
--   32_multi_program.sql       egy jelentkező, több program (II/4)
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--
-- ELŐFELTÉTEL: a RUN_ALL_27_31.sql már lefutott.
-- Idempotens: többször is beilleszthető.
-- ============================================================================


-- ===========================================================================
-- >>> 32_multi_program.sql
-- ===========================================================================
-- ============================================================================
-- 32_multi_program.sql — Egy jelentkező, több program  (II/4)
-- ----------------------------------------------------------------------------
-- A KOLLÉGÁK KÉRÉSE (észrevételek, 8. tétel):
--   "A személyhez tartozó lépések — dokumentum-ellenőrzés, matek, interjú —
--    egyszer történjenek, a programhoz tartozók programonként."
--
-- A LÉPÉSEK SZÉTVÁLÁSA (STEP_IDS_V2):
--   programs   -> PROGRAM-szintű : maga a szakválasztás
--   documents  -> személy-szintű : egyszer kell feltölteni
--   check      -> személy-szintű : egyszer kell ellenőrizni
--   interview  -> személy-szintű : egy interjú, nem szakonként egy
--   math       -> személy-szintű : egy szintfelmérő
--   letter     -> PROGRAM-szintű : szakonként külön felvételi levél
--
-- MIT NEM BÁNTUNK:
--   A személy-szintű állapot marad a students.status-ban, ahogy eddig. Ezt a
--   migráció NEM alakítja át — így a 25-ös állapotgép, a 27/30-as interjú-kapu
--   és minden meglévő felület változatlanul működik tovább.
--
--   A students.program mezőt SEM szüntetjük meg: a felület húsz helyen olvassa.
--   Trigger tartja szinkronban az ELSŐ helyen jelölt szak nevével, tehát a
--   régi kód végig helyes értéket lát.
--
-- IDEMPOTENS. Visszavonás: select public.multi_program_rollback();
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) Jelentkezés-sorok: egy jelentkező × egy program
-- ---------------------------------------------------------------------------
create table if not exists public.student_program (
  id           text primary key
                 default left('SP' || replace(gen_random_uuid()::text,'-',''), 22),
  student_id   text not null references public.students(id) on delete cascade,
  -- A program_id SZÁNDÉKOSAN nullázható. A students.program ma szabad szöveg
  -- ("BSc Business Admin"), ami nem feltétlenül illeszkedik a programs
  -- katalógushoz. Ha nincs találat, a sor a szöveggel jön létre, és az iroda
  -- utólag hozzákötheti a katalógushoz — így egyetlen jelentkezés sem vész el.
  program_id   text references public.programs(id),
  program_label text,
  preference   smallint not null default 1,
  decision     text not null default 'Pending',
  decided_at   timestamptz,
  decided_by   uuid,
  letter_state text not null default 'None',
  letter_url   text,
  enrolled     boolean not null default false,
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint student_program_uniq unique (student_id, program_id),
  -- Legalább az egyik azonosítás legyen meg.
  constraint student_program_ident_ck check (
    program_id is not null or nullif(btrim(coalesce(program_label,'')),'') is not null),
  constraint student_program_pref_ck check (preference between 1 and 20),
  constraint student_program_decision_ck check (
    decision in ('Pending','Admitted','Rejected','Waitlisted','Withdrawn')),
  constraint student_program_letter_ck check (
    letter_state in ('None','Draft','Issued','Sent')),
  -- Beiratkozni csak felvett szakra lehet.
  constraint student_program_enrol_ck check (
    enrolled = false or decision = 'Admitted')
);

create index if not exists student_program_student_idx
  on public.student_program (student_id, preference);
create index if not exists student_program_program_idx
  on public.student_program (program_id, decision);

-- A unique(student_id, program_id) NULL-nál nem fog: a NULL sosem egyenlő
-- önmagával. A katalógushoz még nem kötött sorokat a címke alapján védjük.
create unique index if not exists student_program_label_uniq
  on public.student_program (student_id, lower(btrim(program_label)))
  where program_id is null;

-- Egy jelentkező egy sorszámot csak egyszer használhat (1. hely, 2. hely, ...)
create unique index if not exists student_program_pref_uniq
  on public.student_program (student_id, preference);

comment on table public.student_program is
  'Egy jelentkező programonkénti jelentkezése. A PROGRAM-szintű állapot él itt '
  '(jelölési sorrend, döntés, felvételi levél, beiratkozás). A SZEMÉLY-szintű '
  'állapot — dokumentum, matek, interjú — a students táblában marad.';

-- ---------------------------------------------------------------------------
-- 2) Beállítások (a kettős felvétel kezelése is innen jön)
-- ---------------------------------------------------------------------------
create table if not exists public.student_program_setting (
  key   text primary key,
  value text not null,
  note  text
);

insert into public.student_program_setting(key, value, note) values
  ('dual_admission_policy', 'applicant_chooses',
   'Mi történjen, ha a jelentkezőt TÖBB szakra is felveszik. '
   'applicant_chooses = a jelentkező választ egyet, a többi Withdrawn lesz (alapértelmezés). '
   'first_preference_wins = automatikusan az 1. helyen jelölt szak marad. '
   'both_allowed = párhuzamosan több szakra is beiratkozhat.'),
  ('max_programs_per_applicant', '3',
   'Hány szakra jelentkezhet egy személy. 0 = korlátlan.')
on conflict (key) do nothing;

create or replace function public.student_program_setting_text(p_key text, p_default text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.student_program_setting where key = p_key), p_default)
$$;

create or replace function public.student_program_setting_int(p_key text, p_default integer)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(
    (select nullif(value,'')::integer from public.student_program_setting where key = p_key),
    p_default)
$$;

commit;

begin;

-- ---------------------------------------------------------------------------
-- 3) A meglévő adat átemelése
--    Minden jelentkező mostani szakja 1. helyen jelölt jelentkezés lesz.
--    Ahol a szöveg illeszkedik a programs katalógushoz, ott a sor be is
--    kötődik; ahol nem, ott a szöveg marad címkeként.
-- ---------------------------------------------------------------------------
do $$
declare
  v_kotott   integer;
  v_cimke    integer;
begin
  insert into public.student_program (student_id, program_id, program_label, preference)
  select s.id,
         p.id,
         case when p.id is null then btrim(s.program) else null end,
         1
    from public.students s
    left join public.programs p
      on lower(btrim(p.name)) = lower(btrim(s.program))
   where nullif(btrim(coalesce(s.program,'')), '') is not null
     and not exists (
       select 1 from public.student_program sp where sp.student_id = s.id
     );

  select count(*) filter (where program_id is not null),
         count(*) filter (where program_id is null)
    into v_kotott, v_cimke
    from public.student_program;

  raise notice 'Átemelve: % jelentkezés a katalógushoz kötve, % csak szöveges címkével.',
    v_kotott, v_cimke;

  if v_cimke > 0 then
    raise notice 'A szöveges címkéjű sorok utólag hozzáköthetők a programs '
                 'katalógushoz — addig is minden felületen megjelennek.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4) A students.program szinkronban tartása
--
--    A régi felület húsz helyen olvassa a students.program mezőt. Nem
--    szüntetjük meg: trigger írja bele mindig az ELSŐ helyen jelölt szak
--    nevét, így a meglévő kód végig helyes értéket lát.
-- ---------------------------------------------------------------------------
create or replace function public.student_program_sync_legacy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student text := coalesce(new.student_id, old.student_id);
  v_nev     text;
begin
  select coalesce(p.name, sp.program_label)
    into v_nev
    from public.student_program sp
    left join public.programs p on p.id = sp.program_id
   where sp.student_id = v_student
     and sp.decision <> 'Withdrawn'
   order by sp.preference asc, sp.created_at asc
   limit 1;

  update public.students
     set program = v_nev
   where id = v_student
     and program is distinct from v_nev;

  return null;
end $$;

drop trigger if exists student_program_sync_legacy_trg on public.student_program;
create trigger student_program_sync_legacy_trg
  after insert or update of preference, program_id, program_label, decision
     or delete
  on public.student_program
  for each row execute function public.student_program_sync_legacy();

-- updated_at karbantartás
create or replace function public.student_program_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists student_program_touch_trg on public.student_program;
create trigger student_program_touch_trg
  before update on public.student_program
  for each row execute function public.student_program_touch();

commit;

begin;

-- ---------------------------------------------------------------------------
-- 5) Jelentkezés hozzáadása
-- ---------------------------------------------------------------------------
create or replace function public.student_program_add(
  p_student    text,
  p_program_id text default null,
  p_label      text default null,
  p_preference smallint default null)
returns public.student_program
language plpgsql security definer set search_path = public
as $$
declare
  v_max  integer := public.student_program_setting_int('max_programs_per_applicant', 3);
  v_db   integer;
  v_pref smallint;
  v_sor  public.student_program;
begin
  if not public.is_approved() then
    raise exception 'Jóváhagyásra váró fiókkal nem lehet jelentkezést rögzíteni.'
      using errcode = '42501';
  end if;

  -- Jelentkező a SAJÁT sorára, ügyintéző bármelyikre.
  if not public.is_staff() and p_student is distinct from public.my_student_id() then
    raise exception 'Csak a saját jelentkezéseit rögzítheti.' using errcode = '42501';
  end if;

  if p_program_id is null
     and nullif(btrim(coalesce(p_label,'')), '') is null then
    raise exception 'Meg kell adni a programot.' using errcode = '22023';
  end if;

  select count(*) into v_db
    from public.student_program
   where student_id = p_student and decision <> 'Withdrawn';

  if v_max > 0 and v_db >= v_max then
    raise exception
      'Egy jelentkező legfeljebb % szakra jelentkezhet. Jelenleg % aktív jelentkezése van.',
      v_max, v_db using errcode = '42501';
  end if;

  -- A következő szabad jelölési hely.
  v_pref := coalesce(p_preference, (
    select coalesce(max(preference), 0) + 1
      from public.student_program where student_id = p_student
  )::smallint);

  insert into public.student_program (student_id, program_id, program_label, preference)
  values (p_student, p_program_id,
          case when p_program_id is null then btrim(p_label) else null end,
          v_pref)
  returning * into v_sor;

  return v_sor;
end $$;

-- ---------------------------------------------------------------------------
-- 6) Döntés egy jelentkezésről
-- ---------------------------------------------------------------------------
create or replace function public.student_program_decide(
  p_id       text,
  p_decision text,
  p_note     text default null)
returns public.student_program
language plpgsql security definer set search_path = public
as $$
declare v_sor public.student_program;
begin
  if not public.is_admissions() and not public.is_admin() and not public.is_superadmin() then
    raise exception 'Csak a Felvételi Iroda dönthet jelentkezésről.' using errcode = '42501';
  end if;
  if p_decision not in ('Pending','Admitted','Rejected','Waitlisted','Withdrawn') then
    raise exception 'Ismeretlen döntés: %', p_decision using errcode = '22023';
  end if;

  update public.student_program
     set decision   = p_decision,
         decided_at = case when p_decision = 'Pending' then null else now() end,
         decided_by = case when p_decision = 'Pending' then null else auth.uid() end,
         note       = coalesce(p_note, note),
         enrolled   = case when p_decision <> 'Admitted' then false else enrolled end
   where id = p_id
  returning * into v_sor;

  if v_sor.id is null then
    raise exception 'Nincs ilyen jelentkezés: %', p_id using errcode = '02000';
  end if;
  return v_sor;
end $$;

commit;

begin;

-- ---------------------------------------------------------------------------
-- 7) Beiratkozás — és a KETTŐS FELVÉTEL kezelése
--
--    NYITOTT INTÉZMÉNYI KÉRDÉS: a kollégáktól még nem kaptunk választ arra,
--    mi történjen, ha valakit TÖBB szakra is felvesznek. Ezért ez itt
--    BEÁLLÍTÁS, nem beégetett szabály — a döntés utólag, kód nélkül
--    átállítható:
--
--      update student_program_setting
--         set value = 'first_preference_wins'
--       where key = 'dual_admission_policy';
--
--    applicant_chooses     (alapértelmezés) — a jelentkező választ egyet,
--                          a többi felvétele Withdrawn lesz. Ez a legelterjedtebb
--                          egyetemi gyakorlat, és visszafordítható.
--    first_preference_wins — automatikusan az 1. helyen jelölt szak marad.
--    both_allowed          — párhuzamosan több szakra is beiratkozhat.
-- ---------------------------------------------------------------------------
create or replace function public.student_program_enrol(p_id text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_sor      public.student_program;
  v_policy   text := public.student_program_setting_text('dual_admission_policy','applicant_chooses');
  v_masik    integer;
  v_elso     text;
  v_lezart   integer := 0;
begin
  select * into v_sor from public.student_program where id = p_id;
  if v_sor.id is null then
    raise exception 'Nincs ilyen jelentkezés: %', p_id using errcode = '02000';
  end if;

  -- Jelentkező a sajátjára, ügyintéző bármelyikre.
  if not public.is_staff() and v_sor.student_id is distinct from public.my_student_id() then
    raise exception 'Csak a saját jelentkezésére iratkozhat be.' using errcode = '42501';
  end if;

  if v_sor.decision <> 'Admitted' then
    raise exception 'Beiratkozni csak felvett szakra lehet. A jelentkezés állapota: "%".',
      v_sor.decision using errcode = '42501';
  end if;

  select count(*) into v_masik
    from public.student_program
   where student_id = v_sor.student_id and id <> p_id
     and decision = 'Admitted' and enrolled = false;

  if v_policy = 'first_preference_wins' and v_masik > 0 then
    select id into v_elso
      from public.student_program
     where student_id = v_sor.student_id and decision = 'Admitted'
     order by preference asc, created_at asc
     limit 1;
    if v_elso is distinct from p_id then
      raise exception
        'Az intézményi szabály szerint az 1. helyen jelölt szak az irányadó. '
        'Ezen a jelentkezésen nem lehet beiratkozni.'
        using errcode = '42501';
    end if;
  end if;

  update public.student_program set enrolled = true where id = p_id;

  if v_policy in ('applicant_chooses','first_preference_wins') then
    update public.student_program
       set decision = 'Withdrawn', enrolled = false,
           note = coalesce(note,'') ||
                  case when coalesce(note,'') = '' then '' else ' | ' end ||
                  'Automatikusan lezárva: a jelentkező másik szakra iratkozott be.'
     where student_id = v_sor.student_id
       and id <> p_id
       and decision in ('Admitted','Pending','Waitlisted');
    get diagnostics v_lezart = row_count;
  end if;

  -- A SZEMÉLY-szintű beiratkozási dátumot csak akkor írjuk, ha a fő státusz
  -- már "Accepted". A 25-ös migráció students_enrollment_guard őre ezt
  -- amúgy is kikényszeríti — nem harcolunk vele, hanem igazodunk hozzá:
  -- a program-szintű beiratkozás ettől függetlenül rögzül.
  update public.students set enrolled_at = current_date
   where id = v_sor.student_id
     and enrolled_at is null
     and status = 'Accepted';

  return jsonb_build_object(
    'id', p_id,
    'student_id', v_sor.student_id,
    'policy', v_policy,
    'lezart_masik_jelentkezes', v_lezart);
end $$;

-- ---------------------------------------------------------------------------
-- 8) Szöveges címke hozzákötése a katalógushoz
-- ---------------------------------------------------------------------------
create or replace function public.student_program_link(p_id text, p_program_id text)
returns public.student_program
language plpgsql security definer set search_path = public
as $$
declare v_sor public.student_program;
begin
  if not public.is_staff() then
    raise exception 'Csak ügyintéző kötheti a katalógushoz.' using errcode = '42501';
  end if;
  update public.student_program
     set program_id = p_program_id, program_label = null
   where id = p_id
  returning * into v_sor;
  if v_sor.id is null then
    raise exception 'Nincs ilyen jelentkezés: %', p_id using errcode = '02000';
  end if;
  return v_sor;
end $$;

commit;

begin;

-- ---------------------------------------------------------------------------
-- 9) Sorszintű biztonság
--    Ugyanaz a logika, mint a students táblán: az ügyintéző mindent lát,
--    a jelentkező a sajátját, az ügynökség pedig CSAK a saját diákjait.
-- ---------------------------------------------------------------------------
alter table public.student_program        enable row level security;
alter table public.student_program_setting enable row level security;

drop policy if exists sp_select on public.student_program;
create policy sp_select on public.student_program for select
  using (
    public.is_staff()
    or student_id = public.my_student_id()
    or (public.is_agent() and exists (
          select 1 from public.students s
           where s.id = student_program.student_id
             and public.is_my_agency_student_email(s.email)))
  );

drop policy if exists sp_insert on public.student_program;
create policy sp_insert on public.student_program for insert
  with check (public.is_staff() or student_id = public.my_student_id());

drop policy if exists sp_update on public.student_program;
create policy sp_update on public.student_program for update
  using (public.is_staff() or student_id = public.my_student_id())
  with check (public.is_staff() or student_id = public.my_student_id());

drop policy if exists sp_delete on public.student_program;
create policy sp_delete on public.student_program for delete
  using (public.is_staff() or student_id = public.my_student_id());

-- A beállításokat mindenki olvashatja, de csak szuperadmin írhatja.
drop policy if exists sps_select on public.student_program_setting;
create policy sps_select on public.student_program_setting for select
  using (public.is_approved());

drop policy if exists sps_write on public.student_program_setting;
create policy sps_write on public.student_program_setting for all
  using (public.is_superadmin()) with check (public.is_superadmin());

grant select, insert, update, delete on public.student_program to authenticated;
grant select on public.student_program_setting to authenticated;
grant execute on function
  public.student_program_add(text, text, text, smallint),
  public.student_program_decide(text, text, text),
  public.student_program_enrol(text),
  public.student_program_link(text, text)
  to authenticated;

revoke all on function public.student_program_add(text, text, text, smallint) from anon;
revoke all on function public.student_program_decide(text, text, text) from anon;
revoke all on function public.student_program_enrol(text) from anon;
revoke all on function public.student_program_link(text, text) from anon;

-- ---------------------------------------------------------------------------
-- 10) Visszavonás
-- ---------------------------------------------------------------------------
create or replace function public.multi_program_rollback()
returns text language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'Csak szuperadmin vonhatja vissza.' using errcode = '42501';
  end if;
  drop trigger if exists student_program_sync_legacy_trg on public.student_program;
  drop trigger if exists student_program_touch_trg on public.student_program;
  drop table if exists public.student_program cascade;
  drop table if exists public.student_program_setting cascade;
  return 'A 32-es migráció visszavonva. A students.program mező érintetlen maradt.';
end $$;

revoke all on function public.multi_program_rollback() from public, anon;
grant execute on function public.multi_program_rollback() to authenticated;

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

