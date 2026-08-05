-- ============================================================
-- UniPortal Pro — TELJES Supabase setup (egyetlen futtatás)
-- Neumann János Egyetem · nemzetközi felvételi platform
--
-- FUTTATÁS:
--   1. Supabase dashboard → SQL Editor → New query
--   2. Illeszd be ezt a TELJES fájlt → Run
--   3. Authentication → Sign In / Providers → Email:
--        kapcsold KI a "Confirm email" opciót, hogy a demo regisztráció
--        azonnal működjön (e-mail megerősítés nélkül).
--
-- Ez a fájl a supabase/01..05 migrációk sorrendben összefűzött változata.
-- Az 5 rész külön-külön is futtatható, ha lépésenként haladnál.
--
-- FIGYELEM: az 1. rész eldobja és újralétrehozza a 14 demo táblát
-- (drop table ... cascade), tehát a bennük lévő adat elvész. Ez szándékos:
-- a demót így lehet egy kattintással visszaállítani a kiindulási állapotba.
--
-- DEMO BELÉPÉS (mind ugyanazzal a jelszóval):
--   admin@uni.hu · admissions@uni.hu · finance@uni.hu
--   agent@globalstudy.com · ammar@test.com        jelszó: Demo1234!
-- ============================================================


-- ############################################################
-- ##  1/5 — Séma + demo adatok (14 tábla)
-- ############################################################

-- ===================== users =====================
drop table if exists public."users" cascade;
create table public."users" (
  "id" text primary key,
  "name" text,
  "email" text,
  "role" text,
  "agencyId" text,
  "avatar" text
);
insert into public."users" ("id", "name", "email", "role", "agencyId", "avatar") values
  ('U1', 'Dr. Kovács István', 'admin@uni.hu', 'ADMIN', NULL, 'https://i.pravatar.cc/150?u=admin'),
  ('U2', 'Szabó Péter', 'admissions@uni.hu', 'ADMISSIONS', NULL, 'https://i.pravatar.cc/150?u=admissions'),
  ('U3', 'Nagy Ilona', 'finance@uni.hu', 'FINANCE', NULL, 'https://i.pravatar.cc/150?u=finance'),
  ('U4', 'Al-Farabi Ammar', 'ammar@test.com', 'STUDENT', NULL, 'https://i.pravatar.cc/150?u=ammar'),
  ('U5', 'Szalay Tamás', 'tamas@test.com', 'STUDENT', NULL, 'https://i.pravatar.cc/150?u=tamas'),
  ('U6', 'Agent Smith', 'agent@globalstudy.com', 'AGENT', 'AG1', 'https://i.pravatar.cc/150?u=agent');

-- ===================== students =====================
drop table if exists public."students" cascade;
create table public."students" (
  "id" text primary key,
  "name" text,
  "email" text,
  "phone" text,
  "program" text,
  "status" text,
  "appliedAt" text,
  "tuitionFee" numeric,
  "agentId" text,
  "country" text,
  "birthDate" text,
  "passportNumber" text,
  "gender" text,
  "personalStatement" text,
  "paymentLink" text,
  "address" jsonb,
  "educationHistory" jsonb,
  "languageSkills" jsonb,
  "visaChecklist" jsonb,
  "recommendationLetters" jsonb,
  "visaApplication" jsonb,
  "evaluation" jsonb
);
insert into public."students" ("id", "name", "email", "phone", "program", "status", "appliedAt", "tuitionFee", "agentId", "country", "birthDate", "passportNumber", "gender", "personalStatement", "paymentLink", "address", "educationHistory", "languageSkills", "visaChecklist", "recommendationLetters", "visaApplication", "evaluation") values
  ('S0', 'Szalay Tamás', 'tamas@test.com', '+36301234567', 'MSc Software Engineering', 'Accepted', '2024.03.01', 4800, NULL, 'Magyarország', '1995.08.15', 'BH123456', 'Male', 'I want to deepen my knowledge in software architecture and cloud systems...', NULL, '{"street":"Kossuth Lajos utca 10","city":"Budapest","zip":"1052","country":"Magyarország"}'::jsonb, '[{"institution":"BME","degree":"BSc Computer Science","fieldOfStudy":"Software Engineering","startDate":"2014","endDate":"2018","grade":"4.5"}]'::jsonb, '[{"language":"Hungarian","level":"Native"},{"language":"English","level":"C1","certificate":"Cambridge Advanced"}]'::jsonb, '[{"id":"1","label":"Érvényes útlevél másolata","required":true,"status":"Verified"},{"id":"2","label":"Anyagi fedezet igazolása","required":true,"status":"Uploaded"},{"id":"3","label":"Befogadó nyilatkozat","required":true,"status":"Verified"}]'::jsonb, '[{"id":"RL1","studentId":"S0","referee":{"id":"R1","name":"Dr. Kiss László","email":"laszlo.kiss@bme.hu","position":"Egyetemi Docens","institution":"BME","relationship":"Szakdolgozati konzulens"},"status":"Verified","requestedAt":"2024.03.05","receivedAt":"2024.03.10","letterUrl":"#"},{"id":"RL2","studentId":"S0","referee":{"id":"R2","name":"Kovács János","email":"janos.kovacs@techcorp.com","position":"Senior Software Architect","institution":"TechCorp Solutions","relationship":"Közvetlen felettes"},"status":"Received","requestedAt":"2024.03.06","receivedAt":"2024.03.12","letterUrl":"#"}]'::jsonb, '{"id":"V-S0","studentId":"S0","type":"D-type","status":"Approved","submissionDate":"2024.03.15","decisionDate":"2024.03.20","expiryDate":"2025.03.20","visaNumber":"HUN123456789","consulate":"Budapest","riskFactors":[]}'::jsonb, NULL),
  ('S1', 'Al-Farabi Ammar', 'ammar@test.com', '+2348012345678', 'MSc Computer Science', 'Paid', '2024.03.01', 5000, 'A1', 'Nigéria', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '[{"id":"1","label":"Érvényes útlevél másolata","required":true,"status":"Verified"},{"id":"2","label":"Anyagi fedezet igazolása","required":true,"status":"Uploaded"},{"id":"3","label":"Befogadó nyilatkozat","required":true,"status":"Verified"}]'::jsonb, '[{"id":"RL3","studentId":"S1","referee":{"id":"R3","name":"Prof. John Doe","email":"john.doe@university.ng","position":"Professor","institution":"University of Lagos","relationship":"Academic Advisor"},"status":"Verified","requestedAt":"2024.02.15","receivedAt":"2024.02.20","letterUrl":"#"}]'::jsonb, '{"id":"V-S1","studentId":"S1","type":"D-type","status":"In Progress","submissionDate":"2024.03.10","consulate":"Abuja","riskFactors":[{"label":"Financial Gap","impact":"Medium","description":"Bank statement shows irregular deposits."}]}'::jsonb, '{"criteria":[{"id":"1","label":"Szakmai Motiváció","maxScore":5,"currentScore":4},{"id":"2","label":"Tanulmányi Átlag (GPA)","maxScore":10,"currentScore":8},{"id":"3","label":"Nyelvi Készségek","maxScore":5,"currentScore":5},{"id":"4","label":"Szakmai Tapasztalat","maxScore":5,"currentScore":4},{"id":"5","label":"Ajánlólevelek Minősége","maxScore":5,"currentScore":4}],"comments":[{"id":"C1","author":"Dr. Szabó Péter","text":"Kiváló technikai háttér.","timestamp":"10:20"}],"videos":[{"id":"V1","question":"Miért választotta ezt a szakot?","videoUrl":"#","duration":"01:45"}]}'::jsonb),
  ('S2', 'Chen Wei', 'chen@test.com', '+8613812345678', 'BSc Business Admin', 'Submitted', '2024.03.18', 4500, 'A1', 'Kína', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '[{"id":"1","label":"Érvényes útlevél másolata","required":true,"status":"Pending"},{"id":"2","label":"Anyagi fedezet igazolása","required":true,"status":"Pending"}]'::jsonb, NULL, NULL, '{"criteria":[{"id":"1","label":"Szakmai Motiváció","maxScore":5,"currentScore":3},{"id":"2","label":"Tanulmányi Átlag (GPA)","maxScore":10,"currentScore":9},{"id":"3","label":"Nyelvi Készségek","maxScore":5,"currentScore":4},{"id":"4","label":"Szakmai Tapasztalat","maxScore":5,"currentScore":2},{"id":"5","label":"Ajánlólevelek Minősége","maxScore":5,"currentScore":5}],"comments":[{"id":"C1","author":"Dr. Kovács István","text":"Nagyon erős elméleti tudás.","timestamp":"09:15"}],"videos":[{"id":"V1","question":"Miért választotta ezt a szakot?","videoUrl":"#","duration":"02:10"}]}'::jsonb),
  ('S3', 'Elena Rodriguez', 'elena@test.com', NULL, 'MA Visual Arts', 'Missing Info', '2024.03.10', 6000, 'A2', 'Brazília', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '[{"id":"1","label":"Érvényes útlevél másolata","required":true,"status":"Uploaded"}]'::jsonb, NULL, NULL, NULL),
  ('S4', 'Lars Svensson', 'lars@test.com', NULL, 'MSc Computer Science', 'Accepted', '2024.02.20', 5000, 'A1', 'Svédország', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '[]'::jsonb, NULL, NULL, NULL),
  ('S5', 'Yuki Tanaka', 'yuki@test.com', NULL, 'BSc Engineering', 'Draft', '2024.03.21', 5500, 'A3', 'Japán', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '[]'::jsonb, NULL, NULL, NULL),
  ('S6', 'Ahmed Hassan', 'ahmed@test.com', NULL, 'MSc Data Science', 'Paid', '2024.01.15', 5200, 'A1', 'Egyiptom', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '[{"id":"1","label":"Érvényes útlevél másolata","required":true,"status":"Verified"},{"id":"2","label":"Anyagi fedezet igazolása","required":true,"status":"Verified"}]'::jsonb, NULL, '{"id":"V-S6","studentId":"S6","type":"Residence Permit","status":"Submitted","submissionDate":"2024.03.01","consulate":"Cairo","riskFactors":[]}'::jsonb, NULL),
  ('S7', 'Sofia Bianchi', 'sofia@test.com', NULL, 'MA Architecture', 'Submitted', '2024.03.19', 5800, 'A2', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
  ('S8', 'Igor Petrov', 'igor@test.com', NULL, 'BSc Physics', 'Accepted', '2024.02.28', 4800, 'A3', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
  ('S9', 'Maria Garcia', 'maria@test.com', NULL, 'LLM International Law', 'Missing Info', '2024.03.05', 6500, 'A2', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
  ('S10', 'John Smith', 'john@test.com', NULL, 'BSc Business Admin', 'Paid', '2023.12.10', 4500, 'A1', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- ===================== payments =====================
drop table if exists public."payments" cascade;
create table public."payments" (
  "id" text primary key,
  "studentName" text,
  "type" text,
  "amount" numeric,
  "currency" text,
  "status" text,
  "date" text,
  "method" text,
  "proofUrl" text
);
insert into public."payments" ("id", "studentName", "type", "amount", "currency", "status", "date", "method", "proofUrl") values
  ('P1', 'Al-Farabi Ammar', 'Tuition', 5000, 'EUR', 'Paid', '2024.03.20', 'Bank Transfer', NULL),
  ('P2', 'Chen Wei', 'Application Fee', 50, 'EUR', 'Pending', '2024.03.21', 'Bank Transfer', 'https://example.com/proofs/chenwei_transfer.pdf'),
  ('P3', 'Ahmed Hassan', 'Tuition', 5200, 'EUR', 'Paid', '2024.02.01', 'Stripe', NULL),
  ('P4', 'John Smith', 'Tuition', 4500, 'EUR', 'Paid', '2024.01.10', 'PayPal', NULL),
  ('P5', 'Sofia Bianchi', 'Application Fee', 50, 'EUR', 'Failed', '2024.03.20', 'Stripe', NULL);

-- ===================== invoices =====================
drop table if exists public."invoices" cascade;
create table public."invoices" (
  "id" text primary key,
  "studentName" text,
  "amount" numeric,
  "currency" text,
  "dueDate" text,
  "status" text
);
insert into public."invoices" ("id", "studentName", "amount", "currency", "dueDate", "status") values
  ('INV-1001', 'Elena Rodriguez', 3200, 'USD', '2024.03.10', 'Overdue'),
  ('INV-1002', 'Maria Garcia', 6500, 'EUR', '2024.04.15', 'Sent'),
  ('INV-1003', 'Chen Wei', 4500, 'EUR', '2024.05.01', 'Draft');

-- ===================== campaigns =====================
drop table if exists public."campaigns" cascade;
create table public."campaigns" (
  "id" text primary key,
  "title" text,
  "segment" text,
  "sentCount" numeric,
  "openRate" numeric,
  "status" text
);
insert into public."campaigns" ("id", "title", "segment", "sentCount", "openRate", "status") values
  ('C1', 'Tavaszi Nyílt Nap 2024', 'Minden érdeklődő', 1250, 68, 'Sent'),
  ('C2', 'Early Bird Kedvezmény', 'Draft státuszúak', 85, 42, 'Draft');

-- ===================== auditLogs =====================
drop table if exists public."auditLogs" cascade;
create table public."auditLogs" (
  "id" text primary key,
  "timestamp" text,
  "user" text,
  "action" text,
  "target" text,
  "changes" text
);
insert into public."auditLogs" ("id", "timestamp", "user", "action", "target", "changes") values
  ('LOG-1', '2024.03.21 14:32', 'admin@uni.hu', 'CRITICAL_SECURITY_UPDATE', 'RBAC Policy', 'Elevated Finance access'),
  ('LOG-2', '2024.03.21 15:10', 'admissions@uni.hu', 'STUDENT_STATUS_CHANGE', 'Lars Svensson', 'Submitted -> Accepted'),
  ('LOG-4', '2024.03.21 16:20', 'admin@uni.hu', 'WEBHOOK_CONFIG_UPDATE', 'Neptun Sync', 'URL changed to v2');

-- ===================== webhooks =====================
drop table if exists public."webhooks" cascade;
create table public."webhooks" (
  "id" text primary key,
  "url" text,
  "event" text,
  "status" text
);
insert into public."webhooks" ("id", "url", "event", "status") values
  ('W1', 'https://api.neptun.hu/sync', 'STUDENT_ENROLLED', 'Active'),
  ('W2', 'https://hooks.slack.com/services/T000/B000', 'NEW_APPLICATION', 'Active');

-- ===================== interviewSlots =====================
drop table if exists public."interviewSlots" cascade;
create table public."interviewSlots" (
  "id" text primary key,
  "startTime" timestamptz,
  "endTime" timestamptz,
  "status" text,
  "interviewerId" text,
  "interviewerName" text,
  "studentId" text,
  "studentName" text,
  "teamsMeetingUrl" text
);
insert into public."interviewSlots" ("id", "startTime", "endTime", "status", "interviewerId", "interviewerName", "studentId", "studentName", "teamsMeetingUrl") values
  ('S1', '2024-03-25T09:00:00Z'::timestamptz, '2024-03-25T09:30:00Z'::timestamptz, 'Available', 'U1', 'Dr. Kovács István', NULL, NULL, NULL),
  ('S2', '2024-03-25T10:00:00Z'::timestamptz, '2024-03-25T10:30:00Z'::timestamptz, 'Available', 'U1', 'Dr. Kovács István', NULL, NULL, NULL),
  ('S5', '2024-03-26T15:00:00Z'::timestamptz, '2024-03-26T15:30:00Z'::timestamptz, 'Available', 'U2', 'Szabó Péter', NULL, NULL, NULL);

-- ===================== agencies =====================
drop table if exists public."agencies" cascade;
create table public."agencies" (
  "id" text primary key,
  "name" text,
  "commissionRate" numeric,
  "contactPerson" text,
  "email" text,
  "status" text
);
insert into public."agencies" ("id", "name", "commissionRate", "contactPerson", "email", "status") values
  ('AG1', 'Global Study Ltd.', 15, 'John Doe', 'john@globalstudy.com', 'Active'),
  ('AG2', 'Elite Education', 10, 'Jane Smith', 'jane@eliteedu.com', 'Active'),
  ('AG3', 'Direct Applicant', 0, '-', '-', 'Active');

-- ===================== leads =====================
drop table if exists public."leads" cascade;
create table public."leads" (
  "id" text primary key,
  "name" text,
  "email" text,
  "phone" text,
  "country" text,
  "source" text,
  "utmSource" text,
  "utmMedium" text,
  "utmCampaign" text,
  "status" text,
  "createdAt" text
);
insert into public."leads" ("id", "name", "email", "phone", "country", "source", "utmSource", "utmMedium", "utmCampaign", "status", "createdAt") values
  ('L1', 'James Wilson', 'james@example.com', '+123456789', 'USA', 'Google Ads', 'google', 'cpc', 'spring_2024', 'New', '2024.03.20'),
  ('L2', 'Anna Müller', 'anna@example.de', '+491234567', 'Németország', 'Facebook', 'facebook', 'social', 'international_students', 'Qualified', '2024.03.18'),
  ('L3', 'Li Wei', 'li@example.cn', '+861234567', 'Kína', 'Direct', NULL, NULL, NULL, 'Contacted', '2024.03.15'),
  ('L4', 'Raj Patel', 'raj@example.in', '+911234567', 'India', 'Google Ads', 'google', 'cpc', 'spring_2024', 'Converted', '2024.03.10');

-- ===================== marketingCampaigns =====================
drop table if exists public."marketingCampaigns" cascade;
create table public."marketingCampaigns" (
  "id" text primary key,
  "name" text,
  "platform" text,
  "status" text,
  "budget" numeric,
  "spent" numeric,
  "leadsGenerated" numeric,
  "conversions" numeric,
  "startDate" text,
  "endDate" text
);
insert into public."marketingCampaigns" ("id", "name", "platform", "status", "budget", "spent", "leadsGenerated", "conversions", "startDate", "endDate") values
  ('MC1', 'Spring Enrollment 2024', 'Google Ads', 'Active', 5000, 1200, 45, 12, '2024.03.01', NULL),
  ('MC2', 'International Outreach', 'Facebook', 'Active', 3000, 800, 32, 8, '2024.03.05', NULL),
  ('MC3', 'Winter Webinar', 'LinkedIn', 'Completed', 2000, 2000, 15, 3, '2024.01.15', '2024.02.15');

-- ===================== scholarships =====================
drop table if exists public."scholarships" cascade;
create table public."scholarships" (
  "id" text primary key,
  "name" text,
  "type" text,
  "value" numeric,
  "criteria" text,
  "status" text
);
insert into public."scholarships" ("id", "name", "type", "value", "criteria", "status") values
  ('SCH-1', 'Excellence Scholarship', 'Percentage', 25, 'GPA > 4.5', 'Active'),
  ('SCH-2', 'Early Bird Discount', 'Fixed', 500, 'Apply before April 1st', 'Active'),
  ('SCH-3', 'Regional Grant (Central Asia)', 'Fixed', 1000, 'Citizens of Kazakhstan, Uzbekistan', 'Inactive');

-- ===================== integrations =====================
drop table if exists public."integrations" cascade;
create table public."integrations" (
  "id" text primary key,
  "provider" text,
  "status" text,
  "mode" text,
  "lastSync" text
);
insert into public."integrations" ("id", "provider", "status", "mode", "lastSync") values
  ('INT-1', 'Stripe', 'Connected', 'Test', '2024.03.21 10:00'),
  ('INT-2', 'PayPal', 'Disconnected', 'Test', NULL),
  ('INT-3', 'Billingo', 'Connected', 'Live', '2024.03.21 09:30'),
  ('INT-4', 'Wise', 'Error', 'Test', NULL);

-- ===================== videoInterviewQuestions =====================
drop table if exists public."videoInterviewQuestions" cascade;
create table public."videoInterviewQuestions" (
  "id" text primary key,
  "text" text,
  "durationLimit" numeric
);
insert into public."videoInterviewQuestions" ("id", "text", "durationLimit") values
  ('Q1', 'Kérjük, mutassa be magát röviden!', 60),
  ('Q2', 'Miért választotta a Neumann János Egyetemet?', 90),
  ('Q3', 'Milyen szakmai céljai vannak a diploma megszerzése után?', 120),
  ('Q4', 'Hogyan tervezi finanszírozni a tanulmányait?', 60);

-- ===================== TEMPORARY demo access policies =====================
-- WARNING: these allow full read/write with the public anon key.
-- They exist only so the demo works before authentication (Step 5).
-- Step 3 will DROP these and add role-based RLS.
alter table public."users" enable row level security;
drop policy if exists "demo_all" on public."users";
create policy "demo_all" on public."users" for all to anon, authenticated using (true) with check (true);
alter table public."students" enable row level security;
drop policy if exists "demo_all" on public."students";
create policy "demo_all" on public."students" for all to anon, authenticated using (true) with check (true);
alter table public."payments" enable row level security;
drop policy if exists "demo_all" on public."payments";
create policy "demo_all" on public."payments" for all to anon, authenticated using (true) with check (true);
alter table public."invoices" enable row level security;
drop policy if exists "demo_all" on public."invoices";
create policy "demo_all" on public."invoices" for all to anon, authenticated using (true) with check (true);
alter table public."campaigns" enable row level security;
drop policy if exists "demo_all" on public."campaigns";
create policy "demo_all" on public."campaigns" for all to anon, authenticated using (true) with check (true);
alter table public."auditLogs" enable row level security;
drop policy if exists "demo_all" on public."auditLogs";
create policy "demo_all" on public."auditLogs" for all to anon, authenticated using (true) with check (true);
alter table public."webhooks" enable row level security;
drop policy if exists "demo_all" on public."webhooks";
create policy "demo_all" on public."webhooks" for all to anon, authenticated using (true) with check (true);
alter table public."interviewSlots" enable row level security;
drop policy if exists "demo_all" on public."interviewSlots";
create policy "demo_all" on public."interviewSlots" for all to anon, authenticated using (true) with check (true);
alter table public."agencies" enable row level security;
drop policy if exists "demo_all" on public."agencies";
create policy "demo_all" on public."agencies" for all to anon, authenticated using (true) with check (true);
alter table public."leads" enable row level security;
drop policy if exists "demo_all" on public."leads";
create policy "demo_all" on public."leads" for all to anon, authenticated using (true) with check (true);
alter table public."marketingCampaigns" enable row level security;
drop policy if exists "demo_all" on public."marketingCampaigns";
create policy "demo_all" on public."marketingCampaigns" for all to anon, authenticated using (true) with check (true);
alter table public."scholarships" enable row level security;
drop policy if exists "demo_all" on public."scholarships";
create policy "demo_all" on public."scholarships" for all to anon, authenticated using (true) with check (true);
alter table public."integrations" enable row level security;
drop policy if exists "demo_all" on public."integrations";
create policy "demo_all" on public."integrations" for all to anon, authenticated using (true) with check (true);
alter table public."videoInterviewQuestions" enable row level security;
drop policy if exists "demo_all" on public."videoInterviewQuestions";
create policy "demo_all" on public."videoInterviewQuestions" for all to anon, authenticated using (true) with check (true);

-- Done. 14 tables created and seeded.


-- ############################################################
-- ##  2/5 — Auth: profiles tábla, trigger, demo fiókok
-- ############################################################

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


-- ############################################################
-- ##  3/5 — Profilkép tárolás (Storage bucket + policy-k)
-- ##  A storage.objects policy-k létrehozása egyes projekteken
-- ##  jogosultsághoz kötött; ezért kivételkezeléssel futtatjuk,
-- ##  hogy egy elutasítás ne szakítsa meg a teljes setupot.
-- ############################################################

alter table public.profiles add column if not exists avatar_url text;

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

do $storage$
begin
  begin
    execute $p$drop policy if exists "avatars_public_read" on storage.objects$p$;
    execute $p$create policy "avatars_public_read" on storage.objects
              for select to public using (bucket_id = 'avatars')$p$;

    execute $p$drop policy if exists "avatars_insert_own" on storage.objects$p$;
    execute $p$create policy "avatars_insert_own" on storage.objects
              for insert to authenticated
              with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)$p$;

    execute $p$drop policy if exists "avatars_update_own" on storage.objects$p$;
    execute $p$create policy "avatars_update_own" on storage.objects
              for update to authenticated
              using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)$p$;

    execute $p$drop policy if exists "avatars_delete_own" on storage.objects$p$;
    execute $p$create policy "avatars_delete_own" on storage.objects
              for delete to authenticated
              using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
  exception when others then
    raise notice 'Storage policy-k kihagyva (%). Allitsd be kezzel: Storage -> avatars -> Policies.', sqlerrm;
  end;
end
$storage$;


-- ############################################################
-- ##  4/5 — Felvételi folyamatok + üzenetek (megosztott tárolás)
-- ############################################################

create table if not exists public.admission_processes (
  id           text primary key,
  owner_email  text,
  step         int  default 0,
  max_reached  int  default 0,
  done         boolean default false,
  data         jsonb,
  created_at   text,
  updated_at   timestamptz default now()
);

alter table public.admission_processes enable row level security;

-- Demó fázis: bármely bejelentkezett felhasználó olvashatja az összeset
-- (ügyintéző/admin nézet), és írhat. Élesben ezt szerepkör szerint szűkítjük.
drop policy if exists "ap_read"   on public.admission_processes;
create policy "ap_read"   on public.admission_processes for select to authenticated using (true);

drop policy if exists "ap_insert" on public.admission_processes;
create policy "ap_insert" on public.admission_processes for insert to authenticated with check (true);

drop policy if exists "ap_update" on public.admission_processes;
create policy "ap_update" on public.admission_processes for update to authenticated using (true);

drop policy if exists "ap_delete" on public.admission_processes;
create policy "ap_delete" on public.admission_processes for delete to authenticated using (true);

-- ---------- process_messages: a folyamatokhoz tartozó üzenetek megosztva ----------
create table if not exists public.process_messages (
  id           text primary key,
  process_id   text,
  owner_email  text,
  applicant    text,
  sender       text,
  subject      text,
  preview      text,
  tone         text,
  attachments  jsonb,
  read         boolean default false,
  date         text,
  created_at   timestamptz default now()
);

alter table public.process_messages enable row level security;

drop policy if exists "pm_read"   on public.process_messages;
create policy "pm_read"   on public.process_messages for select to authenticated using (true);
drop policy if exists "pm_insert" on public.process_messages;
create policy "pm_insert" on public.process_messages for insert to authenticated with check (true);
drop policy if exists "pm_update" on public.process_messages;
create policy "pm_update" on public.process_messages for update to authenticated using (true);
drop policy if exists "pm_delete" on public.process_messages;
create policy "pm_delete" on public.process_messages for delete to authenticated using (true);

-- ---------- Realtime: azonnali (oldalfrissítés nélküli) értesítések ----------
-- A 12 mp-es lekérdezés enélkül is frissít; ettől a frissítés AZONNALI lesz.
-- Ha "already member of publication" hibát ír, az rendben van (már engedélyezve).
do $$
begin
  begin execute 'alter publication supabase_realtime add table public.admission_processes'; exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table public.process_messages';     exception when others then null; end;
end $$;

-- Kész. A jelentkezések és üzenetek mostantól megosztva tárolódnak, és élőben frissülnek.


-- ############################################################
-- ##  5/5 — Hírfolyam, programok, AI tudásbázis
-- ############################################################

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


-- ############################################################
-- ##  KÉSZ — ellenőrzés
-- ############################################################
select table_name from information_schema.tables
where table_schema = 'public' order by table_name;
