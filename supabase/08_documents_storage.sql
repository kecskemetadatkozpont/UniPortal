-- ============================================================
-- UniPortal Pro — Jelentkezői dokumentumok tárolása (Step 10)
--
-- MIÉRT:
--   Eddig minden feltöltött dokumentum base64 data URL-ként az
--   admission_processes.data JSONB mezőbe került, és 4 MB felett a
--   tartalom csendben elveszett (a jelentkező mégis "sikeresen feltöltve"
--   üzenetet kapott). A JSONB a folyamat minden mentésekor teljes
--   egészében újraíródik, tehát néhány beszkennelt útlevél után
--   kezelhetetlenné válik.
--
--   Innentől a fájlok egy privát Supabase Storage bucketbe kerülnek, és a
--   folyamatban csak az elérési út marad. Új felső határ: 20 MB.
--
-- FUTTATÁS: Supabase dashboard → SQL Editor → New query → beilleszt → Run
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

-- ---------- 1. privát bucket, 20 MB-os felső határral ----------
-- A limitet a Storage szerveroldalon is érvényesíti, nem csak a böngésző.
insert into storage.buckets (id, name, public, file_size_limit)
values ('documents', 'documents', false, 20971520)
on conflict (id) do update
  set public = false, file_size_limit = 20971520;

-- ---------- 2. ki számít ügyintézőnek? ----------
-- A jelentkező a saját mappáját látja; az ügyintézők mindenkiét.
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and approval_status = 'approved'
      and role in ('SUPERADMIN', 'ADMIN', 'ADMISSIONS', 'FINANCE')
  )
$$;

grant execute on function public.is_staff() to authenticated;

-- ---------- 3. storage policy-k ----------
-- Fájlnév-konvenció:  <auth.uid()>/<folyamat-id>/<dokumentum-id>-<fájlnév>
-- tehát a mappa első szintje mindig a feltöltő felhasználó azonosítója.
--
-- A storage.objects policy-k létrehozása egyes projekteken jogosultsághoz
-- kötött, ezért kivételkezeléssel futtatjuk (mint a 03-as migrációban).
do $docs$
begin
  begin
    execute $p$drop policy if exists "documents_read" on storage.objects$p$;
    execute $p$create policy "documents_read" on storage.objects
              for select to authenticated
              using (
                bucket_id = 'documents'
                and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff())
              )$p$;

    execute $p$drop policy if exists "documents_insert_own" on storage.objects$p$;
    execute $p$create policy "documents_insert_own" on storage.objects
              for insert to authenticated
              with check (
                bucket_id = 'documents'
                and (storage.foldername(name))[1] = auth.uid()::text
                and public.is_approved()
              )$p$;

    execute $p$drop policy if exists "documents_update_own" on storage.objects$p$;
    execute $p$create policy "documents_update_own" on storage.objects
              for update to authenticated
              using (
                bucket_id = 'documents'
                and (storage.foldername(name))[1] = auth.uid()::text
                and public.is_approved()
              )$p$;

    execute $p$drop policy if exists "documents_delete_own" on storage.objects$p$;
    execute $p$create policy "documents_delete_own" on storage.objects
              for delete to authenticated
              using (
                bucket_id = 'documents'
                and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff())
              )$p$;
  exception when others then
    raise notice 'Storage policy-k kihagyva (%). Allitsd be kezzel: Storage -> documents -> Policies.', sqlerrm;
  end;
end
$docs$;

-- ---------- 4. ellenőrzés ----------
select id, public, file_size_limit from storage.buckets where id in ('documents', 'avatars');
