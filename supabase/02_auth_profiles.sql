-- ============================================================
-- UniPortal Pro — Auth & profiles (Step 5)
-- Email + password authentication via Supabase Auth.
--
-- HOW TO RUN:
--   1. Supabase dashboard → SQL Editor → New query
--   2. Paste this entire file → Run
--   3. (Recommended) Authentication → Providers → Email:
--        turn OFF "Confirm email" so new sign-ups work instantly in the demo.
--
-- WHAT IT DOES:
--   • Creates a public.profiles table: one row per auth user, holding the
--     app role (ADMIN / ADMISSIONS / FINANCE / AGENT / STUDENT) + name.
--   • Adds a trigger so every new sign-up automatically gets a profile,
--     reading name/role from the sign-up metadata sent by the landing page.
--   • Seeds the 5 demo accounts (below) WITH a password and confirmed email,
--     so you can log in immediately.
--
-- DEMO LOGIN (all use the same password):
--     admin@uni.hu          ADMIN
--     admissions@uni.hu     ADMISSIONS
--     finance@uni.hu        FINANCE
--     agent@globalstudy.com AGENT
--     ammar@test.com        STUDENT
--     password:  Demo1234!
--
-- This script is idempotent — safe to run more than once.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- profiles ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  name        text,
  role        text not null default 'STUDENT',
  "agencyId"  text,
  "studentId" text,
  created_at  timestamptz default now()
);

alter table public.profiles enable row level security;

-- During the demo phase: any authenticated user can read profiles, and
-- can insert/update their own. Step 3 (role-based RLS) tightens this.
drop policy if exists "profiles_read" on public.profiles;
create policy "profiles_read" on public.profiles
  for select to authenticated using (true);

drop policy if exists "profiles_upsert_self" on public.profiles;
create policy "profiles_upsert_self" on public.profiles
  for insert to authenticated with check (auth.uid() = id);

drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self" on public.profiles
  for update to authenticated using (auth.uid() = id);

-- ---------- auto-create a profile on every new sign-up ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, name, role, "agencyId")
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
    upper(coalesce(new.raw_user_meta_data->>'role', 'STUDENT')),
    new.raw_user_meta_data->>'agencyId'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- seed the 5 demo accounts (idempotent) ----------
do $$
declare
  rec  record;
  uid  uuid;
begin
  for rec in
    select * from (values
      ('admin@uni.hu',          'ADMIN',      'Dr. Kovács István'),
      ('admissions@uni.hu',     'ADMISSIONS', 'Szabó Péter'),
      ('finance@uni.hu',        'FINANCE',    'Nagy Ilona'),
      ('agent@globalstudy.com', 'AGENT',      'Agent Smith'),
      ('ammar@test.com',        'STUDENT',    'Al-Farabi Ammar')
    ) as t(email, role, name)
  loop
    if not exists (select 1 from auth.users where email = rec.email) then
      uid := gen_random_uuid();

      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, created_at, updated_at,
        raw_app_meta_data, raw_user_meta_data, is_super_admin,
        confirmation_token, recovery_token, email_change_token_new, email_change
      ) values (
        '00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated',
        rec.email, crypt('Demo1234!', gen_salt('bf')),
        now(), now(), now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('name', rec.name, 'role', rec.role),
        false,
        '', '', '', ''
      );

      insert into auth.identities (
        id, user_id, provider_id, identity_data, provider,
        last_sign_in_at, created_at, updated_at
      ) values (
        gen_random_uuid(), uid, uid::text,
        jsonb_build_object('sub', uid::text, 'email', rec.email),
        'email', now(), now(), now()
      );
    end if;
  end loop;
end $$;

-- ---------- make sure demo roles/names are correct (idempotent) ----------
update public.profiles p set role = 'ADMIN',      name = 'Dr. Kovács István' where email = 'admin@uni.hu';
update public.profiles p set role = 'ADMISSIONS', name = 'Szabó Péter'        where email = 'admissions@uni.hu';
update public.profiles p set role = 'FINANCE',    name = 'Nagy Ilona'         where email = 'finance@uni.hu';
update public.profiles p set role = 'AGENT',      name = 'Agent Smith', "agencyId" = 'AG1' where email = 'agent@globalstudy.com';
update public.profiles p set role = 'STUDENT',    name = 'Al-Farabi Ammar', "studentId" = 'S1' where email = 'ammar@test.com';

-- Done. Log in with any demo email above + password  Demo1234!
