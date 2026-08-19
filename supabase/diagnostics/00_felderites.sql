-- ============================================================
-- 0. LÉPÉS — KÖRNYEZETFELDERÍTÉS  (egyetlen lekérdezés)
-- CSAK OLVAS. A Supabase SQL Editor egyetlen táblázatot ad vissza.
-- ============================================================
with
mig as (
  select * from (values
    ('is_approved() fv (07)',        (to_regproc('public.is_approved')      is not null)::text),
    ('is_superadmin() fv (07)',      (to_regproc('public.is_superadmin')    is not null)::text),
    ('is_staff() fv (08)',           (to_regproc('public.is_staff')         is not null)::text),
    ('superadmin_email() fv (07)',   (to_regproc('public.superadmin_email') is not null)::text),
    ('profiles.approval_status (07)',(exists (select 1 from information_schema.columns
        where table_schema='public' and table_name='profiles' and column_name='approval_status'))::text),
    ('admission_process_list nézet (09)', (to_regclass('public.admission_process_list') is not null)::text),
    ('wa_messages tábla (10)',       (to_regclass('public.wa_messages') is not null)::text),
    ('documents bucket (08)',        (exists (select 1 from storage.buckets where id='documents'))::text)
  ) t(k,v)
),
pol as (
  select tablename as k,
         count(*)::text || ' policy: ' || string_agg(policyname || '[' || cmd || ']', ', ' order by policyname) as v
  from pg_policies where schemaname='public' group by tablename
),
rls as (
  select c.relname as k,
         case when c.relrowsecurity then 'RLS be' else '*** RLS KI ***' end
         || case when c.relforcerowsecurity then ' + force' else '' end
         || ' | policy: ' || (select count(*) from pg_policies p
                              where p.schemaname='public' and p.tablename=c.relname)::text as v
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='r'
),
fiok as (
  select coalesce(role,'(nincs)') || ' / ' || coalesce(approval_status,'(nincs)') as k, count(*)::text as v
  from public.profiles group by 1
),
lanc as (
  select * from (values
    ('students sor',                (select count(*) from public.students)::text),
    ('profiles sor',                (select count(*) from public.profiles)::text),
    ('profiles."studentId" kitöltve',(select count(*) from public.profiles where "studentId" is not null)::text),
    ('profiles."agencyId" kitöltve', (select count(*) from public.profiles where "agencyId"  is not null)::text),
    ('students↔profiles e-mail egyezés',
       (select count(*) from public.students s join public.profiles p on lower(p.email)=lower(s.email))::text),
    ('students."agencyId" oszlop létezik',
       (exists (select 1 from information_schema.columns where table_schema='public'
                 and table_name='students' and column_name='agencyId'))::text),
    ('students."agentId" oszlop létezik',
       (exists (select 1 from information_schema.columns where table_schema='public'
                 and table_name='students' and column_name='agentId'))::text),
    ('payments sor / névre illeszkedő',
       (select count(*) from public.payments)::text || ' / ' ||
       (select count(*) from public.payments p where exists
          (select 1 from public.students s where s.name = p."studentName"))::text),
    ('invoices sor / névre illeszkedő',
       (select count(*) from public.invoices)::text || ' / ' ||
       (select count(*) from public.invoices i where exists
          (select 1 from public.students s where s.name = i."studentName"))::text),
    ('azonos nevű hallgatók',
       coalesce((select string_agg(name || ' ×' || db::text, ', ')
                 from (select name, count(*) db from public.students group by 1 having count(*)>1) x),'nincs'))
  ) t(k,v)
),
agent_lanc as (
  select 'agentId=' || coalesce(s."agentId",'(nincs)') as k,
         count(*)::text || ' hallgató, van ilyen agency: ' ||
         (exists (select 1 from public.agencies a where a.id = s."agentId"))::text as v
  from public.students s group by s."agentId"
),
ap_oszlop as (
  select 'admission_processes' as k, string_agg(column_name, ', ' order by ordinal_position) as v
  from information_schema.columns where table_schema='public' and table_name='admission_processes'
),
ext as (
  select name as k, coalesce(installed_version,'(nincs telepítve, elérhető: '||default_version||')') as v
  from pg_available_extensions
  where name in ('pg_cron','pg_net','pgcrypto','pg_trgm','supabase_vault','pgaudit','http')
),
realtime as (
  select 'supabase_realtime' as k,
         coalesce((select string_agg(schemaname||'.'||tablename, ', ' order by schemaname,tablename)
                   from pg_publication_tables where pubname='supabase_realtime'),'(üres)') as v
  union all
  select 'publikációk (minden tábla?)',
         coalesce((select string_agg(pubname||'='||puballtables::text, ', ') from pg_publication),'(nincs)')
),
buckets as (
  select 'bucket: '||id as k, 'nyilvános='||public::text||', limit='||coalesce(file_size_limit::text,'nincs') as v
  from storage.buckets
),
storage_pol as (
  select 'storage.objects' as k,
         coalesce(string_agg(policyname||'['||cmd||']', ', ' order by policyname),'(nincs policy)') as v
  from pg_policies where schemaname='storage' and tablename='objects'
),
sorok as (
  select relname as k, n_live_tup::text as v from pg_stat_user_tables where schemaname='public'
)
select blokk, kulcs, ertek from (
  select 1 as ord, '1. migrációk'        as blokk, k as kulcs, v as ertek from mig
  union all select 2, '2. policy-k',              k, v from pol
  union all select 3, '3. RLS állapot',           k, v from rls
  union all select 4, '4. fiókok',                k, v from fiok
  union all select 5, '5. tulajdonlási lánc',     k, v from lanc
  union all select 6, '5b. ügynök-lánc',          k, v from agent_lanc
  union all select 7, '6. admission_processes',   k, v from ap_oszlop
  union all select 8, '7. extension',             k, v from ext
  union all select 9, '8. realtime',              k, v from realtime
  union all select 10,'9. storage',               k, v from buckets
  union all select 11,'9. storage',               k, v from storage_pol
  union all select 12,'10. sorszám',              k, v from sorok
) q order by ord, kulcs;

-- ------------------------------------------------------------
-- MEGJEGYZÉS: ez a fájl SZÁNDÉKOSAN egyetlen lekérdezés.
-- A Supabase SQL Editor több utasítás esetén csak az UTOLSÓ
-- eredményt mutatja meg — ezért fut minden blokk egy CTE-ben,
-- és egyetlen táblázatot ad vissza (blokk / kulcs / ertek).
-- Helyi Postgres 16 másolaton tesztelve, a 01–10 migrációkkal.
-- ------------------------------------------------------------
