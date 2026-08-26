-- 40 ellenőrzés: a besorolás szerkeszthetősége.
with o(s,mit,nev) as (values
  (1,'Besorolás mentése','student_attributes_save'),
  (2,'Legördülők tartalma','student_attribute_options'),
  (3,'Visszavonó','attributes_edit_rollback')
),
letezik as (
  select o.s,o.mit,o.nev,
    case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                       where n.nspname='public' and p.proname=o.nev)
         then 'OK' else '!! HIÁNYZIK' end from o
),
valaszthato as (
  select 20,'Választható tagozat','student_attribute_options',
         coalesce((select string_agg(distinct tagozat, ', ')
                     from public.student_attributes where tagozat is not null),'(nincs adat)')
  union all
  select 21,'Választható szak (db)','student_attribute_options',
         coalesce((select count(distinct szak)::text
                     from public.student_attributes where szak is not null),'0')
),
adat as (
  select 30,'Besorolt fiók','student_attributes', count(*)::text from public.student_attributes
  union all
  select 31,'Ebből kézzel módosított','forras=kezi', count(*)::text
    from public.student_attributes where forras='kezi'
),
anon_echo as (
  select 70,'ECHO anonimitás (21 utoljára futott?)','echo_submit',
         string_agg(distinct grantee,', ' order by grantee) ||
         case when bool_or(grantee='authenticated') then '   !! FUTTASD ÚJRA a 21-est' else '   OK' end
    from information_schema.routine_privileges where routine_name='echo_submit'
)
select mit as "mit ellenőrzünk", nev as "objektum", allapot as "állapot"
  from (select * from letezik union all select * from valaszthato
        union all select * from adat union all select * from anon_echo) x(s,mit,nev,allapot)
 order by s;
