-- ============================================================
-- UniPortal Pro — Felvételi folyamatok megosztott tárolása (Step 7)
-- Az admission_processes tábla teszi lehetővé, hogy a diák által
-- létrehozott jelentkezéseket az ügyintézők/adminok is lássák
-- (eszköztől és munkamenettől függetlenül).
--
-- FUTTATÁS: Supabase dashboard → SQL Editor → New query → beilleszt → Run
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

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
