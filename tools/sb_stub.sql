create extension if not exists pgcrypto;
create extension if not exists btree_gist;
create extension if not exists "uuid-ossp";
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin noinherit bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname='authenticator') then create role authenticator login noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_admin') then create role supabase_admin superuser login; end if;
end $$;
grant anon, authenticated, service_role to authenticator;
create schema if not exists auth;
create schema if not exists storage;
create schema if not exists extensions;
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(), email text unique,
  raw_user_meta_data jsonb default '{}'::jsonb, raw_app_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now(), encrypted_password text,
  email_confirmed_at timestamptz, last_sign_in_at timestamptz);
create table if not exists auth.identities (
  id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id) on delete cascade,
  provider text, identity_data jsonb default '{}'::jsonb, created_at timestamptz default now());
create or replace function auth.uid() returns uuid language sql stable
  as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create or replace function auth.role() returns text language sql stable
  as $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), current_user::text) $$;
create or replace function auth.email() returns text language sql stable
  as $$ select nullif(current_setting('request.jwt.claim.email', true), '') $$;
create or replace function auth.jwt() returns jsonb language sql stable
  as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;
create table if not exists storage.buckets (id text primary key, name text, public boolean default false);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id),
  name text, owner uuid, created_at timestamptz default now(), metadata jsonb);
create or replace function storage.foldername(name text) returns text[] language sql immutable
  as $$ select string_to_array(regexp_replace(name, '/[^/]*$', ''), '/') $$;
create or replace function storage.filename(name text) returns text language sql immutable
  as $$ select regexp_replace(name, '^.*/', '') $$;
grant usage on schema auth, storage, extensions to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter table auth.users add column if not exists instance_id uuid default '00000000-0000-0000-0000-000000000000',
  add column if not exists aud varchar(255) default 'authenticated', add column if not exists role varchar(255) default 'authenticated',
  add column if not exists invited_at timestamptz, add column if not exists confirmation_token varchar(255),
  add column if not exists confirmation_sent_at timestamptz, add column if not exists recovery_token varchar(255),
  add column if not exists recovery_sent_at timestamptz, add column if not exists email_change_token_new varchar(255),
  add column if not exists email_change varchar(255), add column if not exists email_change_sent_at timestamptz,
  add column if not exists phone text, add column if not exists phone_confirmed_at timestamptz,
 add column if not exists is_super_admin boolean,
  add column if not exists updated_at timestamptz default now(), add column if not exists is_sso_user boolean default false,
  add column if not exists deleted_at timestamptz, add column if not exists is_anonymous boolean default false,
  add column if not exists banned_until timestamptz, add column if not exists reauthentication_token varchar(255),
  add column if not exists reauthentication_sent_at timestamptz,
  add column if not exists email_change_token_current varchar(255) default '',
  add column if not exists email_change_confirm_status smallint default 0;
alter table auth.identities add column if not exists provider_id text, add column if not exists last_sign_in_at timestamptz,
  add column if not exists updated_at timestamptz default now(), add column if not exists email text;
alter table storage.buckets add column if not exists owner uuid, add column if not exists created_at timestamptz default now(),
  add column if not exists updated_at timestamptz default now(), add column if not exists file_size_limit bigint,
  add column if not exists allowed_mime_types text[], add column if not exists avif_autodetection boolean default false;
alter table storage.objects add column if not exists updated_at timestamptz default now(),
  add column if not exists last_accessed_at timestamptz default now(), add column if not exists path_tokens text[],
  add column if not exists version text, add column if not exists owner_id text;

-- A confirmed_at az ÉLES Supabase-ben GENERÁLT oszlop. Sima oszlopként a stub
-- átengedte a ráírást, élesben viszont "column confirmed_at can only be
-- updated to DEFAULT" hibát adott. A stub csak akkor ér valamit, ha ebben is
-- hű — különben pont az ilyen hibákat nem fogja meg.
alter table auth.users drop column if exists confirmed_at;
alter table auth.users
  add column confirmed_at timestamptz
  generated always as (least(email_confirmed_at, phone_confirmed_at)) stored;
