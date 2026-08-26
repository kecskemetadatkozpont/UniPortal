-- 38 ellenőrzés: hallgatói besorolás, csoportok, jogosultság — egy táblában.
with o(s,mit,nev,t) as (values
  (1,'Jellemzők táblája','student_attributes','tab'),
  (2,'Csoportok','user_group','tab'),
  (3,'Csoporttagság','user_group_member','tab'),
  (4,'Csoport-jogosultság','group_permission','tab'),
  (5,'Szabály-kiértékelő','group_rule_matches','fn'),
  (6,'Egy profil csoportjai','groups_of','fn'),
  (7,'Saját jogosultságaim','my_group_permissions','fn'),
  (8,'Csoport tagjai','group_members','fn'),
  (9,'Csoport mentése','group_save','fn'),
  (10,'Tagság állítása','group_member_set','fn'),
  (11,'Jogosultság állítása','group_permission_set','fn'),
  (12,'Visszavonó','student_groups_rollback','fn'),
  (13,'Regisztrációs nézet','registration_directory','view')
),
letezik as (
  select o.s,o.mit,o.nev,
    case when case o.t
      when 'tab'  then exists (select 1 from pg_tables where schemaname='public' and tablename=o.nev)
      when 'fn'   then exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                                where n.nspname='public' and p.proname=o.nev)
      when 'view' then exists (select 1 from pg_views where schemaname='public' and viewname=o.nev)
    end then 'OK' else '!! HIÁNYZIK' end
  from o
),
-- ÉLŐ PRÓBA: egy elgépelt mezőnevű szabály senkire illeszkedjen, ne mindenkire.
zart as (
  select 40, 'Élő próba: elgépelt szabály-mező', 'group_rule_matches',
         case when public.group_rule_matches('{"tagozatt":["Nappali"]}'::jsonb,
                (select profile_id from public.student_attributes limit 1)) is not true
              then 'OK — senkire nem illeszkedik'
              else '!! VESZÉLY: ismeretlen mező átengedi' end
),
-- Ellenpróba: a helyes mezőnév viszont illeszkedjen (különben a próba vak).
nemvak as (
  select 41, 'Ellenpróba: helyes mezőnév', 'group_rule_matches',
         coalesce((select case when public.group_rule_matches(
                    jsonb_build_object('tagozat', jsonb_build_array(a.tagozat)), a.profile_id)
                  then 'OK — illeszkedik, a próba nem vak'
                  else '!! nem illeszkedik' end
              from public.student_attributes a where a.tagozat is not null limit 1),
              'nincs adat a próbához')
),
adat as (
  select 50,'Besorolt hallgató','student_attributes', count(*)::text from public.student_attributes
  union all select 51,'Csoport','user_group', count(*)::text from public.user_group
  union all select 52,'Kiosztott jogosultság','group_permission', count(*)::text from public.group_permission
),
kuszob as (
  select 60,'Legkisebb besorolási cella','szak × tagozat × szint',
         coalesce(min(n)::text,'—') ||
         case when min(n) is null then '' when min(n) >= 5 then '  OK' else '  !! k-küszöb alatt' end
    from (select count(*) n from public.student_attributes
           where szak is not null group by szak, tagozat, kepzesi_szint) t
),
anon_echo as (
  select 70,'ECHO anonimitás (21 utoljára futott?)','echo_submit',
         string_agg(distinct grantee,', ' order by grantee) ||
         case when bool_or(grantee='authenticated') then '   !! FUTTASD ÚJRA a 21-est' else '   OK' end
    from information_schema.routine_privileges where routine_name='echo_submit'
)
select mit as "mit ellenőrzünk", nev as "objektum", allapot as "állapot"
  from (select * from letezik union all select * from zart union all select * from nemvak
        union all select * from adat union all select * from kuszob
        union all select * from anon_echo) x(s,mit,nev,allapot)
 order by s;
