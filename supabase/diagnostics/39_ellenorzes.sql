-- 39 ellenőrzés: szerepkör-szerkesztés + a kizárás elleni védelem.
with o(s,mit,nev,t) as (values
  (1,'Szerepkör-tábla','role_definition','tab'),
  (2,'Szerepkör-jogosultság','role_permission','tab'),
  (3,'Saját menüpontjaim','my_role_permissions','fn'),
  (4,'Szerepkör mentése','role_save','fn'),
  (5,'Jogosultság állítása','role_permission_set','fn'),
  (6,'Szerepkör törlése','role_delete','fn'),
  (7,'Visszavonó','role_admin_rollback','fn')
),
letezik as (
  select o.s,o.mit,o.nev, case when case o.t
      when 'tab' then exists (select 1 from pg_tables where schemaname='public' and tablename=o.nev)
      when 'fn'  then exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                               where n.nspname='public' and p.proname=o.nev)
    end then 'OK' else '!! HIÁNYZIK' end from o
),
allapot as (
  select 20+row_number() over (order by rd.sorrend), 'Szerepkör: '||rd.nev, rd.kod,
         count(rp.permission)::text || ' menüpont' ||
         case when rd.kod='SUPERADMIN' then '  (nem a táblából — mindent lát)' else '' end
    from public.role_definition rd
    left join public.role_permission rp on rp.role_kod = rd.kod
   group by rd.kod, rd.nev, rd.sorrend
),
vedelem as (
  select 60,'A SUPERADMIN jogát nem lehet elvenni','role_permission_set',
         case when exists (select 1 from public.role_permission where role_kod='SUPERADMIN')
              then '!! van sora a táblában' else 'OK — nincs, és a szűrő sem nézi' end
),
anon_echo as (
  select 70,'ECHO anonimitás (21 utoljára futott?)','echo_submit',
         string_agg(distinct grantee,', ' order by grantee) ||
         case when bool_or(grantee='authenticated') then '   !! FUTTASD ÚJRA a 21-est' else '   OK' end
    from information_schema.routine_privileges where routine_name='echo_submit'
)
select mit as "mit ellenőrzünk", nev as "objektum", allapot as "állapot"
  from (select * from letezik union all select * from allapot
        union all select * from vedelem union all select * from anon_echo) x(s,mit,nev,allapot)
 order by s;
