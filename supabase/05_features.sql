-- ============================================================
-- UniPortal Pro — Feed, Program Management & AI Assistant (Step 8)
-- Shared storage for the three new features. Until this runs, the
-- app uses a seeded localStorage fallback (per device); after it
-- runs, all data is shared live across users and devices.
--
-- RUN: Supabase dashboard → SQL Editor → New query → paste → Run
-- Idempotent — safe to re-run. Column names match the app's object
-- shapes exactly, so reads/writes are a passthrough.
-- ============================================================

-- ---------- Campus Feed ----------
create table if not exists public.feed_posts (
  id             text primary key,
  type           text,            -- news | gallery | promo | ticket | event | deadline
  title          text,
  body           text,
  image_url      text,
  gallery        jsonb,
  author_name    text,
  pinned         boolean default false,
  promo_code     text,
  discount       text,
  event_date     text,
  event_location text,
  capacity       int,
  ticket_code    text,
  cta_label      text,
  cta_href       text,
  created_at     text
);

create table if not exists public.event_rsvps (
  id         text primary key,
  post_id    text,
  email      text,
  name       text,
  created_at text
);

create table if not exists public.ticket_claims (
  id         text primary key,
  post_id    text,
  email      text,
  code       text,
  created_at text
);

-- ---------- Program Management ----------
create table if not exists public.programs (
  id                 text primary key,
  code               text,
  name               text,
  level              text,          -- preparatory | bachelor | master | doctoral
  faculty            text,
  degree             text,
  duration_semesters int,
  ects               int,
  tuition            int,
  currency           text default 'EUR',
  language           text default 'English',
  deadline           text,
  capacity           int,
  seats_taken        int default 0,
  is_open            boolean default true,
  summary            text,
  image_url          text,
  required_docs      jsonb,         -- ["passport","hs_diploma", ...]
  steps              jsonb,         -- ["personal","documents","math", ...]
  tags               jsonb,
  created_at         text
);

create table if not exists public.program_applications (
  id              text primary key,
  program_id      text,
  applicant_email text,
  applicant_name  text,
  status          text default 'draft',   -- draft | submitted | in_review | accepted | waitlist | rejected
  step_index      int  default 0,
  data            jsonb,                    -- personal, docs, math, motivation, interview, fee
  created_at      text,
  updated_at      timestamptz default now()
);

-- ---------- AI Assistant knowledge base ----------
create table if not exists public.kb_documents (
  id         text primary key,
  title      text,
  source     text,            -- website | upload
  url        text,
  content    text,
  created_at text
);

-- Idempotent column add for installs created before programme images existed.
alter table public.programs add column if not exists image_url text;

-- ---------- Row Level Security (demo phase: permissive for authenticated) ----------
-- In production, tighten: only ADMIN may write feed_posts / programs / kb_documents,
-- and applicants may only read/write their own program_applications & rsvps.
do $$
declare t text;
begin
  foreach t in array array['feed_posts','event_rsvps','ticket_claims','programs','program_applications','kb_documents']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "%s_read"   on public.%I', t, t);
    execute format('drop policy if exists "%s_insert" on public.%I', t, t);
    execute format('drop policy if exists "%s_update" on public.%I', t, t);
    execute format('drop policy if exists "%s_delete" on public.%I', t, t);
    execute format('create policy "%s_read"   on public.%I for select to authenticated using (true)', t, t);
    execute format('create policy "%s_insert" on public.%I for insert to authenticated with check (true)', t, t);
    execute format('create policy "%s_update" on public.%I for update to authenticated using (true)', t, t);
    execute format('create policy "%s_delete" on public.%I for delete to authenticated using (true)', t, t);
  end loop;
end $$;

-- ---------- Realtime (instant updates without page refresh) ----------
-- "already member of publication" is harmless (already enabled).
do $$
begin
  begin execute 'alter publication supabase_realtime add table public.feed_posts';           exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table public.event_rsvps';           exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table public.ticket_claims';         exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table public.programs';              exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table public.program_applications';  exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table public.kb_documents';          exception when others then null; end;
end $$;

-- Done. The tables start EMPTY; the first time a signed-in user opens the app,
-- it upserts the seed programmes, sample feed posts and the website-derived
-- knowledge base into these tables (idempotent, keyed by id). Admins can then
-- edit programmes, publish feed posts and expand the knowledge base — and every
-- change is shared live across all users.
