-- ============================================================
-- 111_interview_notice.sql — AZ INTERJÚZTATÓ IS ÉRTESÜL A VÁLTOZÁSRÓL
-- ============================================================
-- MIÉRT: az iroda eddig is át tudta tenni az interjút másik interjúztatóhoz
-- (interview_move), és a JELENTKEZŐ kapott is róla üzenetet. Az interjúztatók
-- viszont nem: a régi naptárából szó nélkül eltűnt az interjú, az újnak pedig
-- szó nélkül megjelent. Aki aznap reggel ránézett a naptárára, azt hitte,
-- elrontott valamit.
--
-- MIT TELEPÍT
--   1. interview_notice — értesítések EGY-EGY interjúztatónak, olvasottsággal.
--   2. interview_move / interview_assign / interview_cancel: a változásról a
--      RÉGI és az ÚJ interjúztató is kap egy sort. A jelentkezői értesítés
--      változatlan.
--   3. interview_notices() / interview_notice_read() — a saját értesítéseim.
--
-- IDEMPOTENS. FÜGG: 61.
-- ============================================================

create table if not exists public.interview_notice (
  id         text primary key,
  profile_id uuid not null,
  slot_id    text,
  process_id text,
  kind       text not null default 'changed',   -- assigned | removed | moved | cancelled
  subject    text not null,
  body       text not null,
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists interview_notice_profile_idx
  on public.interview_notice (profile_id, created_at desc);
comment on table public.interview_notice is
  'Értesítés egy interjúztatónak: interjút kapott, elvettek tőle, vagy módosult az időpontja (111).';

alter table public.interview_notice enable row level security;

drop policy if exists "interview_notice_own" on public.interview_notice;
create policy "interview_notice_own" on public.interview_notice
  for select to authenticated using (profile_id = auth.uid() or public.is_staff());

drop policy if exists "interview_notice_own_read" on public.interview_notice;
create policy "interview_notice_own_read" on public.interview_notice
  for update to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());

grant select, update on public.interview_notice to authenticated;

-- ---------------------------------------------------------------------------
-- Az értesítés írása. SECURITY DEFINER: a hívó (iroda) a MÁSIK ember sorát írja.
-- ---------------------------------------------------------------------------
create or replace function public.interview_notice_add(
  p_profile uuid, p_slot text, p_process text, p_kind text, p_subject text, p_body text
) returns void
language plpgsql security definer set search_path = public, pg_temp
as $fn$
begin
  if p_profile is null then return; end if;
  -- Saját magának ne küldjön értesítést az, aki a módosítást csinálja.
  if p_profile = auth.uid() then return; end if;
  insert into public.interview_notice (id, profile_id, slot_id, process_id, kind, subject, body)
  values ('IVN-' || replace(gen_random_uuid()::text, '-', ''), p_profile,
          p_slot, p_process, coalesce(p_kind, 'changed'), p_subject, p_body);
end
$fn$;

revoke all on function public.interview_notice_add(uuid, text, text, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- A saját értesítéseim
-- ---------------------------------------------------------------------------
create or replace function public.interview_notices()
returns table (id text, slot_id text, process_id text, kind text, subject text, body text,
               created_at timestamptz, olvasott boolean)
language sql stable security definer set search_path = public, pg_temp
as $fn$
  select n.id, n.slot_id, n.process_id, n.kind, n.subject, n.body, n.created_at,
         (n.read_at is not null) as olvasott
    from public.interview_notice n
   where n.profile_id = auth.uid()
   order by n.created_at desc
   limit 100
$fn$;

revoke all on function public.interview_notices() from public, anon;
grant execute on function public.interview_notices() to authenticated;

create or replace function public.interview_notice_read(p_id text default null)
returns integer
language plpgsql security definer set search_path = public, pg_temp
as $fn$
declare v_db integer;
begin
  if auth.uid() is null then return 0; end if;
  update public.interview_notice
     set read_at = now()
   where profile_id = auth.uid() and read_at is null
     and (p_id is null or id = p_id);
  get diagnostics v_db = row_count;
  return v_db;
end
$fn$;

revoke all on function public.interview_notice_read(text) from public, anon;
grant execute on function public.interview_notice_read(text) to authenticated;

-- ============================================================
-- AZ ÁTHELYEZÉS: A RÉGI ÉS AZ ÚJ INTERJÚZTATÓ IS ÉRTESÜL
-- (a 61-es interview_move kiegészítése — a törzs változatlan, csak a
--  végén küld értesítést az érintett interjúztatóknak)
-- ============================================================
create or replace function public.interview_move(
  p_slot        text,
  p_start       timestamptz,
  p_end         timestamptz default null,
  p_interviewer uuid default null,
  p_note        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  s           public."interviewSlots";
  v_new_iv    uuid;
  v_end       timestamptz;
  v_reason    text;
  v_old_start timestamptz;
  v_old_iv    uuid;
  v_ki        text;
begin
  select * into s from public."interviewSlots" where id = p_slot for update;
  if s.id is null then
    raise exception 'Nincs ilyen interjú-időpont.' using errcode = '02000';
  end if;
  if not public.interview_can_manage(s."interviewerKey") then
    raise exception 'Az interjút csak a felvételi iroda munkatársa vagy az interjúztató helyezheti át.' using errcode = '42501';
  end if;
  if coalesce(s.status, '') not in ('Booked', 'Proposed') then
    raise exception 'Csak élő (foglalt vagy javasolt) interjú helyezhető át.' using errcode = '22023';
  end if;
  if p_start is null then
    raise exception 'Hiányzó időpont.' using errcode = '22023';
  end if;

  v_new_iv := coalesce(p_interviewer, s."interviewerKey");
  if v_new_iv is null then
    raise exception 'A régi, interjúztató nélküli időpont a naptárban nem helyezhető át.' using errcode = '22023';
  end if;
  if v_new_iv is distinct from s."interviewerKey" and not coalesce(public.is_admissions(), false) then
    raise exception 'Másik interjúztatóhoz csak a felvételi iroda munkatársa teheti át az interjút.' using errcode = '42501';
  end if;

  v_end := coalesce(p_end, p_start + (s."endTime" - s."startTime"));
  v_reason := public.interview_slot_blocked_reason_ex(v_new_iv, p_start, v_end, s.id, true);
  if v_reason is not null then
    raise exception '%', v_reason using errcode = '42501';
  end if;

  v_old_start := s."startTime";
  v_old_iv    := s."interviewerKey";

  update public."interviewSlots"
     set "startTime"       = p_start,
         "endTime"         = v_end,
         "interviewerKey"  = v_new_iv,
         "interviewerId"   = v_new_iv::text,
         "interviewerName" = public.interview_name(v_new_iv),
         note              = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note),
         updated_at        = now()
   where id = s.id
  returning * into s;

  perform public.interview_sync_process(s.process_id);

  -- A JELENTKEZŐ értesítése (változatlan a 61-eshez képest)
  if s.process_id is not null and (v_old_start is distinct from p_start or v_old_iv is distinct from v_new_iv) then
    perform public.interview_notify(s.process_id, 'Módosult az interjúd időpontja',
      'Az interjúd új időpontja: ' || public.interview_hu_label(p_start)
      || ' (korábban: ' || public.interview_hu_label(v_old_start) || '). Interjúztató: '
      || public.interview_name(v_new_iv) || '.'
      || case when s.status = 'Proposed' then ' Kérjük, fogadd el az időpontot a felvételi folyamatodban.' else '' end,
      'info');
  end if;

  -- AZ INTERJÚZTATÓK értesítése (111)
  v_ki := coalesce(nullif(btrim(s."studentName"), ''), 'a jelentkező');
  if v_old_iv is distinct from v_new_iv then
    perform public.interview_notice_add(v_old_iv, s.id, s.process_id, 'removed',
      'Lekerült rólad egy interjú',
      v_ki || ' interjúját a felvételi iroda áthelyezte ' || public.interview_name(v_new_iv)
      || ' naptárába. Eredeti időpont: ' || public.interview_hu_label(v_old_start) || '.');
    perform public.interview_notice_add(v_new_iv, s.id, s.process_id, 'assigned',
      'Új interjú került hozzád',
      v_ki || ' interjúját a felvételi iroda hozzád rendelte. Időpont: '
      || public.interview_hu_label(p_start) || '.');
  elsif v_old_start is distinct from p_start then
    perform public.interview_notice_add(v_new_iv, s.id, s.process_id, 'moved',
      'Módosult egy interjúd időpontja',
      v_ki || ' interjúja új időpontban: ' || public.interview_hu_label(p_start)
      || ' (korábban: ' || public.interview_hu_label(v_old_start) || ').');
  end if;

  return public.interview_slot_json(s);
end
$fn$;

revoke all on function public.interview_move(text, timestamptz, timestamptz, uuid, text) from public, anon;
grant execute on function public.interview_move(text, timestamptz, timestamptz, uuid, text) to authenticated;

-- ============================================================
-- AZ ELSŐ KIOSZTÁS: az interjúztató is tudjon róla
-- ============================================================
create or replace function public.interview_assign(
  p_process_id  text,
  p_interviewer uuid,
  p_start       timestamptz,
  p_end         timestamptz default null,
  p_note        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  p        public.admission_processes;
  s        public."interviewSlots";
  v_live   public."interviewSlots";
  v_end    timestamptz;
  v_reason text;
  v_id     text;
begin
  if not coalesce(public.is_admissions(), false) then
    raise exception 'Interjút jelentkezőhöz csak a felvételi iroda munkatársa rendelhet.' using errcode = '42501';
  end if;
  if p_process_id is null or p_interviewer is null or p_start is null then
    raise exception 'Hiányzó jelentkező, interjúztató vagy időpont.' using errcode = '22023';
  end if;

  select * into p from public.admission_processes where id = p_process_id for update;
  if p.id is null then
    raise exception 'Nincs ilyen felvételi folyamat: %', p_process_id using errcode = '02000';
  end if;
  if coalesce(p.data ->> '_cancelled', '') = 'true' then
    raise exception 'A jelentkező megszakította ezt a felvételi folyamatot.' using errcode = '22023';
  end if;

  select * into v_live from public."interviewSlots"
   where process_id = p.id and status in ('Booked', 'Proposed')
   order by "startTime" desc limit 1;
  if v_live.id is not null then
    raise exception 'Ennek a jelentkezőnek már van interjú-időpontja (%). Azt helyezd át, vagy előbb mondd le.',
      public.interview_hu_label(v_live."startTime") using errcode = '22023';
  end if;

  v_end := coalesce(p_end, p_start + make_interval(mins => public.interview_slot_minutes()));
  v_reason := public.interview_slot_blocked_reason_ex(p_interviewer, p_start, v_end, null, true);
  if v_reason is not null then
    raise exception '%', v_reason using errcode = '42501';
  end if;

  v_id := left('IV' || replace(gen_random_uuid()::text, '-', ''), 22);
  insert into public."interviewSlots"
    (id, "startTime", "endTime", status, "interviewerId", "interviewerName", "interviewerKey",
     "studentId", "studentName", "teamsMeetingUrl", process_id, note, created_by, updated_at)
  values
    (v_id, p_start, v_end, 'Booked', p_interviewer::text, public.interview_name(p_interviewer), p_interviewer,
     null, public.interview_applicant_name(p),
     'https://teams.microsoft.com/l/meetup-join/19%3ameeting_' || left(replace(v_id, 'IV', ''), 12),
     p.id, nullif(btrim(coalesce(p_note, '')), ''), auth.uid(), now())
  returning * into s;

  perform public.interview_sync_process(p.id);
  perform public.interview_notify(p.id, 'Interjú-időpont',
    'A felvételi interjúd időpontja: ' || public.interview_hu_label(p_start)
    || ' (Microsoft Teams). Interjúztató: ' || public.interview_name(p_interviewer)
    || '. Ha nem megfelelő, a felvételi folyamatodban lemondhatod, és választhatsz másikat.', 'info');

  -- 111: az interjúztató is kap értesítést az új interjúról.
  perform public.interview_notice_add(p_interviewer, s.id, p.id, 'assigned',
    'Új interjú került hozzád',
    coalesce(nullif(btrim(s."studentName"), ''), 'a jelentkező') || ' interjúját a felvételi iroda hozzád rendelte. Időpont: '
    || public.interview_hu_label(p_start) || '.');

  return public.interview_slot_json(s);
end
$fn$;

revoke all on function public.interview_assign(text, uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.interview_assign(text, uuid, timestamptz, timestamptz, text) to authenticated;

-- ============================================================
-- ZÁRÓ ELLENŐRZÉS
-- ============================================================
do $$
begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'interview_notice') then
    raise exception 'Hianyzik az interview_notice tabla.';
  end if;
  if has_function_privilege('anon', 'public.interview_notices()', 'execute') then
    raise exception 'BIZTONSAGI HIBA: az anon hivhatja az interview_notices fuggvenyt.';
  end if;
  raise notice 'Rendben: 111 — az interjuztatok is ertesulnek a valtozasrol.';
end $$;

select count(*) as interjuztatoi_ertesites from public.interview_notice;
