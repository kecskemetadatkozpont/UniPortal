-- ============================================================
-- UniPortal Pro — Folyamatlista nézet a lekérdezések lefogyasztásához (Step 11)
--
-- MIÉRT:
--   A felvételi listák (ügyintézői és jelentkezői oldal egyaránt) eddig
--   `admission_processes` → select('*')-ot futtattak, 12 másodpercenként
--   ismételve. A `data` JSONB viszont a feltöltött dokumentumokat is
--   tartalmazza, így a lekérdezés mérete a feltöltött fájlokkal együtt nő:
--   mérve 12,5 MB / 3,6 mp volt egyetlen lekérésre. Ez az oka annak, hogy a
--   rendszer „sokszor lassan tölt".
--
--   A 08-as migráció óta az új feltöltések a Storage-ba mennek, de a régebbi,
--   beágyazott (base64) dokumentumok továbbra is a `data`-ban ülnek, és a
--   lista lekérdezése behúzza őket. Ez a nézet garantálja, hogy a LISTÁBA
--   soha ne kerüljön fájltartalom — akkor sem, ha valahol mégis beágyazott
--   dokumentum keletkezne.
--
--   A megnyitott folyamat teljes sorát az alkalmazás külön, egyesével kéri le.
--
-- FUTTATÁS: Supabase dashboard → SQL Editor → New query → beilleszt → Run
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

drop view if exists public.admission_process_list;

create view public.admission_process_list
with (security_invoker = on)   -- a hívó felhasználó RLS-e érvényesül, nem a nézet tulajdonosáé
as
select
  p.id,
  p.owner_email,
  p.step,
  p.max_reached,
  p.done,
  p.created_at,
  p.updated_at,
  -- Ugyanaz a `data`, de a dokumentumokból kivéve a beágyazott fájltartalom.
  -- Marad a fájlnév, típus, méret, státusz és a Storage-beli elérési út —
  -- a listának pontosan ennyi kell.
  (
    coalesce(p.data, '{}'::jsonb)
    || jsonb_build_object(
         'docs',
         coalesce((
           select jsonb_object_agg(d.key, d.value - 'dataUrl')
           from jsonb_each(coalesce(p.data -> 'docs', '{}'::jsonb)) as d
         ), '{}'::jsonb)
       )
  ) as data
from public.admission_processes p;

grant select on public.admission_process_list to authenticated;

-- ---------- ellenőrzés ----------
-- A jobb oldali oszlopnak nagyságrendekkel kisebbnek kell lennie.
select
  pg_size_pretty(sum(length(p.data::text))::bigint)  as teljes_data,
  pg_size_pretty(sum(length(v.data::text))::bigint)  as lista_data
from public.admission_processes p
join public.admission_process_list v on v.id = p.id;
