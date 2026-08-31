-- ============================================================================
-- RUN_ALL_51.sql — UniPortal
--
--   51_dorm_photos.sql   képtároló a kollégiumi jegyzőkönyvekhez és károkhoz
--   + a végén a MODUL SAJÁT ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a 26_dorm.sql lefutott. Idempotens.
-- Sémához NEM nyúl: a dorm.handover.photos és a dorm.damage.photos oszlop
-- már létezett — csak tároló és jogosultság hiányzott hozzájuk.
-- ============================================================================


-- ============================================================================
--  51_dorm_photos.sql — UniPortal / kollégium
--  KÉPTÁROLÓ A JEGYZŐKÖNYVEKHEZ ÉS A KÁRBEJELENTÉSEKHEZ
-- ============================================================================
--
--  MIÉRT KELL ÚJ TÁROLÓ, ÉS MIÉRT NEM ELÉG A 'documents'
--  A meglévő 'documents' tároló olvasási policy-je (08_documents_storage.sql):
--      saját mappa  VAGY  public.is_staff()
--  Az is_staff() viszont CSAK a SUPERADMIN / ADMIN / ADMISSIONS / FINANCE kört
--  jelenti — a kollégiumi szerepkörök (GONDNOK, KOLI_ADMIN, ...) nincsenek
--  benne. Egy gondnok tehát fel tudná tölteni a képet, de a kollégája NEM
--  látná. Mérve: a beépített DORMV_uploadPhotos ráadásul 'dorm/...' alakú
--  útvonalat épít, amit a documents_insert_own policy (első szegmens =
--  auth.uid()) eleve elutasítana. A feltöltés tehát ma kétszeresen sem
--  működne — ezért nem hívja sehol a felület.
--
--  A MEGOLDÁS: saját, NEM nyilvános 'dorm-photos' tároló, kollégiumi
--  szerepkörhöz kötött jogosultsággal.
--    olvasás:  bármely élő kollégiumi szerepkör (a karbantartó is — a
--              sérülésfotó a munkája), vagy admin
--    írás:     aki jegyzőkönyvet is írhat: GONDNOK / KOLI_ADMIN /
--              KOLI_SYSADMIN, vagy admin
--  A hallgató NEM fér hozzá: a be-/kiköltözési jegyzőkönyv és a kárnyilván-
--  tartás belső dokumentum.
--
--  ÚTVONAL-KONVENCIÓ:  kollegium/<jegyzőkönyv-vagy-kár-id>/<fájl>
--  A policy szándékosan NEM elemzi az útvonalat: a hozzáférést a szerepkör
--  dönti el, nem a mappanév. Egy útvonal-alapú szabály itt hamis biztonság
--  lenne, mert a mappanevet a kliens adja.
--
--  ELŐFELTÉTEL: a 26_dorm.sql lefutott. Idempotens.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('dorm-photos', 'dorm-photos', false)
on conflict (id) do update set public = false;

-- A storage.objects policy-k létrehozása egyes projekteken jogosultsághoz
-- kötött, ezért kivételkezeléssel futtatjuk (mint a 03-as és 08-as migráció).
do $ph$
begin
  begin
    execute $p$drop policy if exists "dorm_photos_read" on storage.objects$p$;
    execute $p$create policy "dorm_photos_read" on storage.objects
              for select to authenticated
              using (
                bucket_id = 'dorm-photos'
                and (public.is_admin()
                     or dorm.has_any_role(array['GONDNOK','KARBANTARTO','KOLI_ADMIN',
                                                'INGATLAN','KOLI_SYSADMIN']))
              )$p$;

    execute $p$drop policy if exists "dorm_photos_write" on storage.objects$p$;
    execute $p$create policy "dorm_photos_write" on storage.objects
              for insert to authenticated
              with check (
                bucket_id = 'dorm-photos'
                and (public.is_admin()
                     or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN']))
              )$p$;

    execute $p$drop policy if exists "dorm_photos_update" on storage.objects$p$;
    execute $p$create policy "dorm_photos_update" on storage.objects
              for update to authenticated
              using (
                bucket_id = 'dorm-photos'
                and (public.is_admin()
                     or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN']))
              )$p$;

    execute $p$drop policy if exists "dorm_photos_delete" on storage.objects$p$;
    execute $p$create policy "dorm_photos_delete" on storage.objects
              for delete to authenticated
              using (
                bucket_id = 'dorm-photos'
                and (public.is_admin()
                     or dorm.has_any_role(array['KOLI_ADMIN','KOLI_SYSADMIN']))
              )$p$;
  exception when insufficient_privilege then
    raise notice 'KOLLEGIUM 51: a storage policy-k nem jottek letre (nincs jog). '
                 'A Supabase felulet Storage > Policies pontjaban kell felvenni oket; '
                 'a tarolo maga letrejott.';
  end;
end
$ph$;




-- A PostgREST sema-gyorsitotara: tarolo-valtozas nem igenyli, de artalmatlan.
notify pgrst, 'reload schema';

-- ============================================================================
--  ELLENŐRZÉS — futtasd le, és küldd vissza a táblát
-- ============================================================================
select 'a dorm-photos tarolo letrejott' as mit_ellenorzunk,
       coalesce((select id||case when public then ' (NYILVANOS!)' else ' (nem nyilvanos)' end
                   from storage.buckets where id='dorm-photos'), '(nincs)') as ertek,
       case when exists (select 1 from storage.buckets where id='dorm-photos' and not public)
            then 'OK' else 'HIBA' end as allapot
union all
select 'policy: '||policyname,
       cmd||' — '||left(coalesce(qual, with_check, ''), 60),
       'OK'
  from pg_policies
 where schemaname='storage' and tablename='objects' and policyname like 'dorm_photos%'
union all
select 'a jegyzokonyv tablaban van photos oszlop',
       coalesce((select data_type from information_schema.columns
                  where table_schema='dorm' and table_name='handover' and column_name='photos'), '(nincs)'),
       case when exists (select 1 from information_schema.columns
                          where table_schema='dorm' and table_name='handover' and column_name='photos')
            then 'OK — semaba nem kell nyulni' else 'HIBA' end
union all
select 'a karbejelentesben is van photos oszlop',
       coalesce((select data_type from information_schema.columns
                  where table_schema='dorm' and table_name='damage' and column_name='photos'), '(nincs)'),
       case when exists (select 1 from information_schema.columns
                          where table_schema='dorm' and table_name='damage' and column_name='photos')
            then 'OK' else 'HIBA' end;
