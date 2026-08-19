-- ============================================================
-- allapot.sql — HOL TARTOK MOST? Egyetlen olvasó lekérdezés.
-- Megmondja, melyik RLS-fázisban van az adatbázis, és mit jelent.
-- ============================================================
with f as (
  select
    (select count(*) from pg_policies where schemaname='public' and policyname like 'rbac\_%')      as rbac,
    (select count(distinct tablename) from pg_policies where schemaname='public' and policyname like 'rbac\_%') as rbac_tabla,
    (select count(*) from pg_policies where schemaname='public' and policyname='approved_all')      as appall,
    (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
       join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and not t.tgisinternal
        and t.tgname in ('students_protect_identity_trg','interviewslots_force_owner_trg',
                         'auditlogs_force_actor_trg','payments_force_owner_trg'))                   as trig,
    (select count(*) from pg_policies where schemaname='public' and 'anon' = any(roles))            as anonpol
),
d as (
  select *,
    case
      when rbac = 0                     then '0 — alapallapot (csak a 07-es approved_all)'
      when rbac >= 86 and appall = 22   then '11 — ADDITIV: az uj szabalyok fent vannak, de az approved_all is → a lathatosag a REGI'
      when rbac >= 86 and appall = 0    then '12 — ELES: kizarolag a szerepkor-alapu szabalyok ervenyesek'
      when rbac >  0  and rbac < 86     then '?? — RESZLEGES: a 11-es nem futott vegig, ne futtasd a 12-est'
      else '?? — ismeretlen kombinacio'
    end as fazis
  from f
)
select 'FAZIS'                          as mit, fazis                                as ertek, ''::text as megjegyzes from d
union all select 'rbac_ policy',        rbac::text || ' / 86',
       case when rbac >= 86 then 'OK' else 'HIANYZIK' end from d
union all select 'fedett tabla',        rbac_tabla::text || ' / 22',
       case when rbac_tabla >= 22 then 'OK' else 'HIANYZIK' end from d
union all select 'approved_all',        appall::text || ' / 22',
       case when appall = 22 then 'fent van → a lathatosag a regi'
            when appall = 0  then 'eldobva → eles szerepkor-alapu mukodes'
            else 'FELIG — ez hibas allapot, futtasd a 13-ast' end from d
union all select 'integritas-trigger',  trig::text || ' / 4',
       case when trig = 4 then 'OK — a jelentkezo nem irhatja at magat'
            else 'HIANYZIK — a 12-es meg fogja tagadni a futast' end from d
union all select 'anon-nak szolo policy', anonpol::text || ' / 0',
       case when anonpol = 0 then 'OK' else 'BAJ — bejelentkezes nelkul is latszik valami' end from d
union all select 'kovetkezo lepes',
       case
         when (select rbac from d) = 0                                     then 'futtasd a 11_rbac_additive.sql-t'
         when (select appall from d) = 22 and (select rbac from d) >= 86    then 'dontsd el a hallgatoi/ugynoki kotest, aztan 12_rbac_flip.sql'
         when (select appall from d) = 0                                    then 'teszteljetek a felulettel; ha baj van: 13_rbac_rollback.sql'
         else 'ellenorizd a fenti sorokat' end, '' from d;
