-- ============================================================
-- UniPortal Pro — Regisztráció jóváhagyás + superadmin (Step 9)
--
-- MIT CSINÁL:
--   • A profiles tábla kap egy `approval_status` mezőt:
--     pending | approved | rejected. Új regisztráció mindig `pending` — a
--     felhasználó be tud lépni, de SEMMILYEN adatot nem lát, amíg a
--     superadmin jóvá nem hagyja.
--   • Superadmin: kecskemet.adatkozpont@gmail.com. Ez az egyetlen fiók,
--     amely jóváhagyhat/elutasíthat regisztrációkat és szerepkört oszthat.
--   • A jóváhagyás nem csak a felületen látszik: minden UniPortal adattábla
--     RLS-e a public.is_approved() függvényre épül, tehát egy pending fiók a
--     nyers API-n keresztül sem ér el semmit.
--   • Egy trigger megakadályozza, hogy bárki a saját szerepkörét vagy
--     jóváhagyási állapotát átírja (különben egy pending fiók egyetlen
--     PATCH-csel jóváhagyhatná magát).
--
-- MIÉRT `approval_status` ÉS NEM `status`:
--   Ebben a Supabase projektben a public.profiles táblát egy másik
--   alkalmazás is használja (publications / kutatói nyilvántartás), és annak
--   már van egy `status` oszlopa 'incomplete' értékekkel. Azt nem írjuk felül
--   és nem is olvassuk — az UniPortal saját, külön nevű mezőt kap.
--
-- FUTTATÁS: Supabase dashboard → SQL Editor → New query → beilleszt → Run
-- Idempotens — biztonságosan újrafuttatható.
--
-- EZUTÁN KÖTELEZŐ (a dashboardon, SQL-ből nem állítható):
--   Authentication → Sign In / Providers → Email → "Confirm email" BE.
--   E nélkül a regisztráció megerősítetlen e-mail-címmel is belép.
-- ============================================================

-- ---------- 0. a superadmin e-mail-címe egy helyen ----------
create or replace function public.superadmin_email()
returns text language sql immutable as $$ select 'kecskemet.adatkozpont@gmail.com' $$;

-- ---------- 1. profiles: UniPortal jóváhagyási mezők ----------
alter table public.profiles add column if not exists approval_status text not null default 'pending';
alter table public.profiles add column if not exists requested_role  text;
alter table public.profiles add column if not exists approved_at     timestamptz;
alter table public.profiles add column if not exists approved_by     text;
alter table public.profiles add column if not exists rejected_reason text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_approval_status_check') then
    alter table public.profiles
      add constraint profiles_approval_status_check
      check (approval_status in ('pending', 'approved', 'rejected'));
  end if;
end $$;

create index if not exists profiles_approval_status_idx on public.profiles (approval_status);

-- Minden MÁR LÉTEZŐ fiók jóváhagyottnak számít (az 5 demo fiók és a meglévő
-- valódi fiókok így változatlanul működnek tovább); csak az ezután érkező
-- regisztrációk lesznek pending állapotúak.
update public.profiles
   set approval_status = 'approved', approved_at = coalesce(approved_at, now())
 where approval_status is distinct from 'approved';

-- A superadmin fiók előléptetése, ha már regisztrált. Ha még nem, a lenti
-- trigger intézi az első bejelentkezéskor.
update public.profiles
   set role = 'SUPERADMIN', approval_status = 'approved', approved_at = coalesce(approved_at, now())
 where lower(email) = public.superadmin_email();

-- ---------- 2. jogosultság-vizsgáló függvények ----------
-- SECURITY DEFINER: a profiles saját RLS-ét megkerülik, így nincs rekurzió,
-- amikor egy profiles-policy hívja őket.
create or replace function public.is_superadmin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'SUPERADMIN' and approval_status = 'approved'
  )
$$;

create or replace function public.is_approved()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and approval_status = 'approved'
  )
$$;

grant execute on function public.is_superadmin() to anon, authenticated;
grant execute on function public.is_approved()  to anon, authenticated;

-- ---------- 3. sign-up trigger: pending, kivéve a superadmint ----------
-- A másik alkalmazás oszlopait (status, is_researcher, …) nem állítjuk —
-- azok a saját alapértelmezésüket kapják, mint eddig.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  wanted_role text;
  is_super    boolean;
begin
  is_super    := lower(new.email) = public.superadmin_email();
  wanted_role := upper(coalesce(new.raw_user_meta_data->>'role', 'STUDENT'));

  insert into public.profiles (id, email, name, role, requested_role, "agencyId", approval_status, approved_at)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
    case when is_super then 'SUPERADMIN' else wanted_role end,
    wanted_role,
    new.raw_user_meta_data->>'agencyId',
    case when is_super then 'approved' else 'pending' end,
    case when is_super then now() else null end
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 4. senki ne léptethesse elő önmagát ----------
-- A profiles UPDATE policy megengedi, hogy a felhasználó a SAJÁT sorát írja
-- (név, avatar — és a másik alkalmazás mezői). Ez a trigger kizárólag az
-- UniPortal jogosultsági mezőit írja vissza, hacsak nem superadmin módosít.
create or replace function public.profiles_protect_privileges()
returns trigger language plpgsql security definer set search_path = public as $$
declare actor text;
begin
  -- auth.uid() is null when there is no end-user JWT: the SQL Editor, a
  -- service-role key, a migration. Those are trusted server-side contexts and
  -- must stay able to fix an account by hand — the guard is only about what a
  -- signed-in client may do to itself.
  if public.is_superadmin() or auth.uid() is null then
    if new.approval_status is distinct from old.approval_status then
      new.approved_at := case when new.approval_status = 'approved' then now() else null end;
      select email into actor from public.profiles where id = auth.uid();
      new.approved_by := coalesce(actor, 'sql-editor');
    end if;
    return new;
  end if;
  new.role            := old.role;
  new.approval_status := old.approval_status;
  new.requested_role  := old.requested_role;
  new.approved_at     := old.approved_at;
  new.approved_by     := old.approved_by;
  new.rejected_reason := old.rejected_reason;
  new."agencyId"      := old."agencyId";
  new."studentId"     := old."studentId";
  return new;
end $$;

drop trigger if exists profiles_protect_privileges_trg on public.profiles;
create trigger profiles_protect_privileges_trg
  before update on public.profiles
  for each row execute function public.profiles_protect_privileges();

-- ---------- 5. profiles RLS ----------
-- Szándékosan óvatos: a profiles táblát a másik alkalmazás is használja.
--   SELECT — a saját sor mindig, minden sor csak jóváhagyott fióknak.
--            (Minden meglévő fiók jóváhagyott lett fentebb, tehát a másik
--             alkalmazás jelenlegi felhasználóinak semmi nem változik.)
--   INSERT — csak a saját sor, mint eddig.
--   UPDATE — a saját sor, plusz a superadmin bárkiét (a jóváhagyáshoz).
alter table public.profiles enable row level security;

drop policy if exists "profiles_read"        on public.profiles;
drop policy if exists "profiles_upsert_self" on public.profiles;
drop policy if exists "profiles_update_self" on public.profiles;
drop policy if exists "profiles_select"      on public.profiles;
drop policy if exists "profiles_insert"      on public.profiles;
drop policy if exists "profiles_update"      on public.profiles;

create policy "profiles_select" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_approved());

create policy "profiles_insert" on public.profiles
  for insert to authenticated
  with check (id = auth.uid());

create policy "profiles_update" on public.profiles
  for update to authenticated
  using (id = auth.uid() or public.is_superadmin())
  with check (id = auth.uid() or public.is_superadmin());

-- ---------- 6. az UniPortal adattáblái jóváhagyáshoz kötve ----------
-- Csak az UniPortal saját tábláit érintjük; a másik alkalmazás tábláihoz
-- (publications, …) nem nyúlunk.
do $$
declare t text;
begin
  foreach t in array array[
    -- 01_schema_and_seed
    'users', 'students', 'payments', 'invoices', 'campaigns', 'auditLogs',
    'webhooks', 'interviewSlots', 'agencies', 'leads', 'marketingCampaigns',
    'scholarships', 'integrations', 'videoInterviewQuestions',
    -- 04_admission_processes
    'admission_processes', 'process_messages',
    -- 05_features
    'feed_posts', 'event_rsvps', 'ticket_claims',
    'programs', 'program_applications', 'kb_documents'
  ]
  loop
    if to_regclass(format('public.%I', t)) is null then continue; end if;

    execute format('alter table public.%I enable row level security', t);
    -- a korábbi migrációk policy-nevei
    execute format('drop policy if exists "demo_all"   on public.%I', t);
    execute format('drop policy if exists "%s_read"    on public.%I', t, t);
    execute format('drop policy if exists "%s_insert"  on public.%I', t, t);
    execute format('drop policy if exists "%s_update"  on public.%I', t, t);
    execute format('drop policy if exists "%s_delete"  on public.%I', t, t);
    execute format('drop policy if exists "ap_read"    on public.%I', t);
    execute format('drop policy if exists "ap_insert"  on public.%I', t);
    execute format('drop policy if exists "ap_update"  on public.%I', t);
    execute format('drop policy if exists "ap_delete"  on public.%I', t);
    execute format('drop policy if exists "pm_read"    on public.%I', t);
    execute format('drop policy if exists "pm_insert"  on public.%I', t);
    execute format('drop policy if exists "pm_update"  on public.%I', t);
    execute format('drop policy if exists "pm_delete"  on public.%I', t);

    execute format('drop policy if exists "approved_all" on public.%I', t);
    execute format(
      'create policy "approved_all" on public.%I for all to authenticated
         using (public.is_approved()) with check (public.is_approved())', t);
  end loop;
end $$;

-- ---------- 7. takarítás ----------
-- Teszt-fiók, amit a "Confirm email" beállítás ellenőrzése hozott létre.
delete from auth.users where email = 'probe-confirm-check@example.com';

-- ---------- 8. ellenőrzés ----------
select email, role, approval_status, requested_role
from public.profiles order by approval_status, email;
