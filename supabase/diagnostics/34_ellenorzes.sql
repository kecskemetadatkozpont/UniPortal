-- ============================================================================
-- 34_ellenorzes.sql — a 34-es (ECHO export) leülésének ellenőrzése
-- Egyetlen lekérdezés, egy tábla.
-- ============================================================================
with objektum(sorrend, mit, nev, tipus) as (values
  (1, 'Export-napló táblája',        'export_log',              'echo_tabla'),
  (2, 'Riport lapítása sorokká',     'export_rows',             'echo_fv'),
  (3, 'Publikus export-kapu',        'echo_export_results',     'pub_fv'),
  (4, 'Export-napló olvasása',       'echo_export_log',         'pub_fv'),
  (5, 'Visszavonó',                  'echo_export_rollback',    'pub_fv')
),
ellenorzes as (
  select o.sorrend, o.mit, o.nev,
         case when case o.tipus
           when 'echo_tabla' then exists (select 1 from pg_tables
                                           where schemaname='echo' and tablename=o.nev)
           when 'echo_fv'    then exists (select 1 from pg_proc p
                                           join pg_namespace n on n.oid=p.pronamespace
                                          where n.nspname='echo' and p.proname=o.nev)
           when 'pub_fv'     then exists (select 1 from pg_proc p
                                           join pg_namespace n on n.oid=p.pronamespace
                                          where n.nspname='public' and p.proname=o.nev)
         end then 'OK' else '!! HIÁNYZIK' end as allapot
  from objektum o
),
-- A LÉNYEG: az export tényleg nem tud kiadni elrejtett adatot?
-- Élő próba: egy "rejtve" riportot adunk neki, amiben BENNE HAGYUNK egy átlagot.
szivargas as (
  select 50 as sorrend,
         'Élő próba: rejtett riport exportja' as mit,
         'export_rows(rejtve=true, atlag=4.9)' as nev,
         case when jsonb_array_length(r->'sorok') = 0
                   and (r->>'teljesen_rejtve')::boolean
              then 'OK — 0 sor, nem szivárog'
              else '!! SZIVÁRGÁS: ' || jsonb_array_length(r->'sorok') || ' sor' end as allapot
    from (select echo.export_rows(jsonb_build_object(
            'rejtve', true, 'rejtes_oka', 'keves_valasz',
            'kerdesek', jsonb_build_array(jsonb_build_object('id','q','atlag',4.9)))) r) t
),
-- És fordítva: rejtetlen adatot ki TUD adni? (különben a próba vak lenne)
nem_vak as (
  select 51 as sorrend,
         'Ellenpróba: rejtetlen adat átjön-e' as mit,
         'export_rows(atlag=4.2, rejtve=false)' as nev,
         case when (r->'sorok'->0->>'atlag') = '4.2'
              then 'OK — átjön, tehát a próba nem vak'
              else '!! A PRÓBA VAK: ' || coalesce(r->'sorok'->0->>'atlag','nincs sor') end as allapot
    from (select echo.export_rows(jsonb_build_object(
            'rejtve', false,
            'kerdesek', jsonb_build_array(jsonb_build_object(
              'id','q','hu','t','type','scale','n',12,
              'atlag',4.2,'atlag_rejtve',false)),
            'alacsony_oralatogatas', jsonb_build_object('rejtve',true))) r) t
),
jogosultsag as (
  select 60 as sorrend, 'anon NEM exportálhat' as mit, 'echo_export_results' as nev,
         case when exists (select 1 from information_schema.routine_privileges
                            where routine_name='echo_export_results' and grantee='anon')
              then '!! anon-nak VAN joga' else 'OK — anon-nak nincs joga' end as allapot
),
sema as (
  select 70 as sorrend, 'Az echo séma rejtve marad' as mit, 'echo.export_log' as nev,
         case when exists (select 1 from information_schema.role_table_grants
                            where table_schema='echo' and table_name='export_log'
                              and grantee in ('anon','authenticated'))
              then '!! közvetlen jog van rajta' else 'OK — csak burkolón át' end as allapot
),
anonimitas as (
  select 80 as sorrend, 'ECHO anonimitás (21 utoljára futott?)' as mit, 'echo_submit' as nev,
         string_agg(distinct grantee, ', ' order by grantee) ||
         case when bool_or(grantee='authenticated')
              then '   !! FUTTASD ÚJRA a 21-est' else '   OK' end as allapot
    from information_schema.routine_privileges where routine_name='echo_submit'
)
select mit as "mit ellenőrzünk", nev as "objektum", allapot as "állapot"
  from (select * from ellenorzes union all select * from szivargas
        union all select * from nem_vak union all select * from jogosultsag
        union all select * from sema union all select * from anonimitas) t
 order by sorrend;
