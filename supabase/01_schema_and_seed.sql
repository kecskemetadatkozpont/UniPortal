-- ============================================================
-- UniPortal Pro — Supabase schema + seed (Step 2)
-- John von Neumann University · International Admissions platform
--
-- HOW TO RUN:
--   1. Supabase dashboard → SQL Editor → New query
--   2. Paste this entire file → Run
--   3. Check Table Editor: 14 tables should appear, seeded with demo data
--
-- Notes:
--   • Column names match the app's data shape exactly (quoted camelCase),
--     so the frontend rewrite (Step 4) is a near-passthrough.
--   • Rich nested student data is stored as JSONB.
--   • TEXT primary keys preserve the existing demo IDs (S0, P1, AG1, ...).
--   • The TEMPORARY demo RLS policies at the bottom let the app read/write
--     with the public anon key BEFORE real auth exists. Step 3/5 replaces
--     them with proper role-based Row Level Security.
-- ============================================================

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
