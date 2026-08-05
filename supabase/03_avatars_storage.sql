-- ============================================================
-- UniPortal Pro — Profilkép tárolás (Step 6)
-- Avatar feltöltés Supabase Storage-ba + profiles.avatar_url oszlop.
--
-- FUTTATÁS:
--   1. Supabase dashboard → SQL Editor → New query
--   2. Illeszd be ezt a teljes fájlt → Run
--
-- Ezt EGYSZER kell lefuttatni. Idempotens — biztonságosan újrafuttatható.
-- ============================================================

-- ---------- avatar_url oszlop a profiles táblához ----------
alter table public.profiles add column if not exists avatar_url text;

-- ---------- 'avatars' publikus storage bucket ----------
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

-- ---------- policy-k: bárki olvashatja, a felhasználó a sajátját írhatja ----------
-- A fájlnév konvenció: <auth.uid()>/<bármi>  → így a mappa neve a user id.

drop policy if exists "avatars_public_read" on storage.objects;
create policy "avatars_public_read" on storage.objects
  for select to public
  using (bucket_id = 'avatars');

drop policy if exists "avatars_insert_own" on storage.objects;
create policy "avatars_insert_own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars_update_own" on storage.objects;
create policy "avatars_update_own" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars_delete_own" on storage.objects;
create policy "avatars_delete_own" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- Kész. A profilkép feltöltés ezután a Supabase Storage-ba kerül.
