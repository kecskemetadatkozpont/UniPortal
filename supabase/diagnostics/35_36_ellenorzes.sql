-- 35–36 ellenőrzés: észrevétel-modul + kérdésbank + anonimitás, egy táblában.
with o(s, mit, nev, t) as (values
  (1,'Átvételi esemény táblája','protocol_handover','et'),
  (2,'Észrevétel táblája','teacher_comment','et'),
  (3,'Kérdésbank táblája','question_bank','et'),
  (4,'Címzett feloldása','comment_recipient','ef'),
  (5,'Határidő számítása','comment_deadline','ef'),
  (6,'Átvétel rögzítése','echo_protocol_handover','pf'),
  (7,'Saját észrevételi ablak','echo_my_comment_window','pf'),
  (8,'Észrevétel beadása','echo_teacher_comment_submit','pf'),
  (9,'Észrevételek listája','echo_teacher_comments','pf'),
  (10,'Nyugtázás','echo_comment_acknowledge','pf'),
  (11,'Kérdésbank listája','echo_question_bank','pf'),
  (12,'Kérdésbank mentés','echo_question_bank_save','pf'),
  (13,'Sablon-alakra hozás','echo_question_bank_as_item','pf')
),
letezik as (
  select o.s, o.mit, o.nev,
    case when case o.t
      when 'et' then exists (select 1 from pg_tables where schemaname='echo' and tablename=o.nev)
      when 'ef' then exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                              where n.nspname='echo' and p.proname=o.nev)
      when 'pf' then exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                              where n.nspname='public' and p.proname=o.nev)
    end then 'OK' else '!! HIÁNYZIK' end as allapot
  from o
),
ablak as (
  select 50 as s, 'Észrevételi ablak hossza' as mit, 'comment_window_days' as nev,
         coalesce((select value||' nap' from echo.setting where key='comment_window_days'),'!! nincs beállítva') as allapot
  union all
  select 51, 'Címzett-lépcső', 'comment_recipient_chain',
         coalesce((select value from echo.setting where key='comment_recipient_chain'),'!! nincs beállítva')
),
jog as (
  select 60 as s, 'anon NEM férhet hozzá' as mit,
         'echo_question_bank_save' as nev,
         case when exists (select 1 from information_schema.routine_privileges
                            where routine_name in ('echo_question_bank_save','echo_teacher_comment_submit',
                                                   'echo_protocol_handover')
                              and grantee in ('anon','PUBLIC'))
              then '!! anon/PUBLIC jogot talált' else 'OK — csak authenticated' end as allapot
),
anon_echo as (
  select 70 as s, 'ECHO anonimitás (21 utoljára futott?)' as mit, 'echo_submit' as nev,
         string_agg(distinct grantee, ', ' order by grantee) ||
         case when bool_or(grantee='authenticated') then '   !! FUTTASD ÚJRA a 21-est' else '   OK' end
    from information_schema.routine_privileges where routine_name='echo_submit'
)
select mit as "mit ellenőrzünk", nev as "objektum", allapot as "állapot"
  from (select * from letezik union all select * from ablak
        union all select * from jog union all select * from anon_echo) x
 order by s;
