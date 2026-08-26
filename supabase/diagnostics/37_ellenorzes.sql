-- 37 ellenőrzés: az összevont jelentkezési folyamat + anonimitás, egy táblában.
with o(s, mit, nev, t) as (values
  (1,'stage oszlop (szakasz)','stage','col'),
  (2,'student_step oszlop','student_step','col'),
  (3,'program_id oszlop','program_id','col'),
  (4,'applicant_name oszlop','applicant_name','col'),
  (5,'submitted_at oszlop','submitted_at','col'),
  (6,'Beadás RPC','application_submit','fn'),
  (7,'Visszavonó','merge_flows_rollback','fn'),
  (8,'Listanézet','admission_process_list','view')
),
letezik as (
  select o.s, o.mit, o.nev,
    case when case o.t
      when 'col'  then exists (select 1 from information_schema.columns
                                where table_name='admission_processes' and column_name=o.nev)
      when 'fn'   then exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                                where n.nspname='public' and p.proname=o.nev)
      when 'view' then exists (select 1 from pg_views where schemaname='public' and viewname=o.nev)
    end then 'OK' else '!! HIÁNYZIK' end as allapot
  from o
),
-- A LÉNYEG: a listanézet átadja-e az új mezőket?
nezet as (
  select 40 as s, 'A listanézet viszi az új mezőket' as mit, 'admission_process_list' as nev,
    case when (select count(*) from information_schema.columns
                where table_name='admission_process_list'
                  and column_name in ('stage','student_step','program_id','applicant_name')) = 4
         then 'OK — mind a 4' else '!! hiányos' end as allapot
),
adat as (
  select 50 as s, 'Felvételi folyamatok' as mit,
         'hallgatói / irodai szakasz' as nev,
         (count(*) filter (where stage='student'))::text || ' / ' ||
         (count(*) filter (where stage='office'))::text as allapot
    from public.admission_processes
  union all
  select 51, 'Átemelt hallgatói jelentkezés', 'APP- előtaggal',
         count(*)::text from public.admission_processes where id like 'APP-%'
  union all
  select 52, 'A régi tábla érintetlen', 'program_applications',
         case when exists (select 1 from information_schema.tables
                            where table_schema='public' and table_name='program_applications')
              then (select count(*)::text || ' sor — megvan, visszafordítható'
                      from public.program_applications)
              else 'nincs ilyen tábla' end
),
anonimitas as (
  select 70 as s, 'ECHO anonimitás (21 utoljára futott?)' as mit, 'echo_submit' as nev,
         string_agg(distinct grantee, ', ' order by grantee) ||
         case when bool_or(grantee='authenticated') then '   !! FUTTASD ÚJRA a 21-est' else '   OK' end
    from information_schema.routine_privileges where routine_name='echo_submit'
)
select mit as "mit ellenőrzünk", nev as "objektum", allapot as "állapot"
  from (select * from letezik union all select * from nezet
        union all select * from adat union all select * from anonimitas) x
 order by s;
