-- ============================================================================
-- 32_ellenorzes.sql — a 32-es migráció leülésének ellenőrzése
-- Egyetlen lekérdezés, egy tábla. A SQL Editor csak az utolsó eredményt mutatja.
-- ============================================================================
with objektum(sorrend, mit, nev, tipus) as (values
  (1,  'Jelentkezés-sorok táblája',      'student_program',                 'tabla'),
  (2,  'Beállítások táblája',            'student_program_setting',         'tabla'),
  (3,  'Jelentkezés hozzáadása',         'student_program_add',             'fuggveny'),
  (4,  'Döntés rögzítése',               'student_program_decide',          'fuggveny'),
  (5,  'Beiratkozás',                    'student_program_enrol',           'fuggveny'),
  (6,  'Katalógushoz kötés',             'student_program_link',            'fuggveny'),
  (7,  'Visszavonó',                     'multi_program_rollback',          'fuggveny'),
  (8,  'students.program szinkron',      'student_program_sync_legacy_trg', 'trigger'),
  (9,  'Egy jelölési hely / sorszám',    'student_program_pref_uniq',       'index')
),
ellenorzes as (
  select o.sorrend, o.mit, o.nev,
         case when case o.tipus
           when 'tabla'    then exists (select 1 from pg_tables
                                         where schemaname='public' and tablename=o.nev)
           when 'fuggveny' then exists (select 1 from pg_proc p
                                         join pg_namespace n on n.oid=p.pronamespace
                                        where n.nspname='public' and p.proname=o.nev)
           when 'trigger'  then exists (select 1 from pg_trigger
                                        where tgname=o.nev and not tgisinternal)
           when 'index'    then exists (select 1 from pg_indexes
                                        where schemaname='public' and indexname=o.nev)
         end then 'OK' else '!! HIÁNYZIK' end as allapot
  from objektum o
),
-- Az átemelés eredménye: ezt kell átnézni futtatás után.
atemeles as (
  select 100 as sorrend,
         'Átemelt jelentkezések' as mit,
         'katalógushoz kötve / csak szöveges címkével' as nev,
         (select count(*) filter (where program_id is not null)::text || ' / ' ||
                 count(*) filter (where program_id is null)::text
            from public.student_program) as allapot
),
beallitas as (
  select 110 as sorrend, 'Kettős felvétel szabálya' as mit, key as nev, value as allapot
    from public.student_program_setting where key='dual_admission_policy'
  union all
  select 111, 'Szakok max. száma', key, value
    from public.student_program_setting where key='max_programs_per_applicant'
),
anonimitas as (
  select 120 as sorrend, 'ECHO anonimitás (21 utoljára futott?)' as mit,
         'echo_submit' as nev,
         string_agg(distinct grantee, ', ' order by grantee) ||
         case when bool_or(grantee='authenticated')
              then '   !! FUTTASD ÚJRA a 21_echo_harden_submit.sql-t'
              else '   OK' end as allapot
    from information_schema.routine_privileges
   where routine_name='echo_submit'
)
select mit as "mit ellenőrzünk", nev as "objektum", allapot as "állapot"
  from (select * from ellenorzes
        union all select * from atemeles
        union all select * from beallitas
        union all select * from anonimitas) t
 order by sorrend;
