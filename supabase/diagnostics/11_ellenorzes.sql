-- ============================================================
-- 11_ellenorzes.sql — a 11-es migráció utáni ELLENŐRZÉS
-- CSAK OLVAS. Egyetlen eredménytáblát ad vissza.
-- Elvárt: minden sor "OK" jelzéssel.
-- ============================================================
with v as (
  select 'rbac_ policy száma' as mit,
         (select count(*) from pg_policies where schemaname='public' and policyname like 'rbac\_%')::text as ertek,
         '86' as elvart
  union all select 'rbac_ policy-val fedett tábla',
         (select count(distinct tablename) from pg_policies where schemaname='public' and policyname like 'rbac\_%')::text, '22'
  union all select 'approved_all megmaradt',
         (select count(*) from pg_policies where schemaname='public' and policyname='approved_all')::text, '22'
  union all select 'anon-nak szolo policy (0 kell)',
         (select count(*) from pg_policies where schemaname='public' and 'anon' = any(roles))::text, '0'
  union all select 'integritas-trigger',
         (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
            join pg_namespace n on n.oid=c.relnamespace
          where n.nspname='public' and not t.tgisinternal
            and t.tgname in ('students_protect_identity_trg','interviewslots_force_owner_trg',
                             'auditlogs_force_actor_trg','payments_force_owner_trg'))::text, '4'
  union all select 'helper fuggveny',
         (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and p.proname in
            ('my_role','my_email','my_agency','my_student_id','my_student_name','my_display_name',
             'has_role','is_admin','is_student','is_agent','is_admissions','is_finance',
             'is_my_agency_student_email'))::text, '13'
  union all select 'idegen app tablai erintve (0 kell)',
         (select count(*) from pg_policies where schemaname='public'
            and tablename in ('prefs','publications','publication_files')
            and policyname like 'rbac\_%')::text, '0'
  union all select 'is_staff() valtozatlan',
         (select case when prosrc like '%SUPERADMIN%ADMIN%ADMISSIONS%FINANCE%' then 'igen' else 'NEM' end
          from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and p.proname='is_staff'), 'igen'
)
select mit, ertek, elvart,
       case when ertek = elvart then 'OK' else '*** ELTER ***' end as allapot
from v;
