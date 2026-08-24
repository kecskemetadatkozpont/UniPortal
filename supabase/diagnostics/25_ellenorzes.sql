-- ============================================================
-- 25_ellenorzes.sql — a 25_status_model.sql utáni ELLENŐRZÉS
-- CSAK OLVAS. Egyetlen eredménytáblát ad vissza.
-- Elvárt: minden sor "OK" jelzéssel.
--
--   psql -d fresh -f supabase/diagnostics/25_ellenorzes.sql
-- ============================================================
with v as (
  select 'statusz-katalogus merete' as mit,
         (select count(*) from public.student_status)::text as ertek,
         '7' as elvart
  union all select 'fo lanc atmenetei',
         (select count(*) from public.student_status_transition)::text, '13'
  union all select 'ebbol visszalepes (is_backward)',
         (select count(*) from public.student_status_transition where is_backward)::text, '6'
  union all select 'sav-allapotok (visa+deferral+refund)',
         (select count(*) from public.student_track_state)::text, '10'
  union all select 'sav-atmenetek',
         (select count(*) from public.student_track_transition)::text, '27'

  -- D1: a 'Failed' vegallapot — csak az EXPLICIT ujranyitas vezet ki belole
  union all select 'Failed-bol kivezeto atmenet (csak ujranyitas)',
         (select count(*) from public.student_status_transition where from_code='Failed')::text, '1'
  union all select 'Failed -> Nominated visszalepeskent naplozott',
         (select count(*) from public.student_status_transition
           where from_code='Failed' and to_code='Nominated' and is_backward)::text, '1'
  union all select 'Accepted-bol elore vezeto atmenet (0 kell)',
         (select count(*) from public.student_status_transition
           where from_code='Accepted' and not is_backward)::text, '0'

  -- Az atvezetes teljessege
  union all select 'ervenytelen statuszu students sor (0 kell)',
         (select count(*) from public.students s
           left join public.student_status c on c.code = s.status
          where c.code is null)::text, '0'
  union all select 'megmaradt legacy ertek a status oszlopban (0 kell)',
         (select count(*) from public.students
           where status in ('Missing Info','Paid','Rejected'))::text, '0'
  union all select 'status_legacy kitoltve minden soron',
         (select count(*) from public.students where status_legacy is null)::text, '0'

  -- A sav-mezok csak 'Accepted' mellett ertelmesek, de a tarolas fuggetlen:
  -- itt csak azt nezzuk, hogy a mezok leteznek es a katalogusra hivatkoznak.
  union all select 'sav-mezok a students tablan',
         (select count(*) from information_schema.columns
           where table_schema='public' and table_name='students'
             and column_name in ('visa_state','deferral_state','refund_state'))::text, '3'
  union all select 'ervenytelen sav-ertek (0 kell)',
         (select count(*) from public.students s
           where (s.visa_state     is not null and not exists (select 1 from public.student_track_state t where t.track='visa'     and t.code=s.visa_state))
              or (s.deferral_state is not null and not exists (select 1 from public.student_track_state t where t.track='deferral' and t.code=s.deferral_state))
              or (s.refund_state   is not null and not exists (select 1 from public.student_track_state t where t.track='refund'   and t.code=s.refund_state)))::text, '0'

  -- Az allapotgep es az oszlopvedelem triggerei
  union all select 'statusz-orzo triggerek',
         (select count(*) from pg_trigger
           where tgrelid='public.students'::regclass and not tgisinternal
             and tgname in ('students_status_guard_trg','students_status_insert_trg',
                            'students_track_guard_trg','students_protect_tracks_trg'))::text, '4'
  union all select 'a 11-es oszlopvedo trigger megmaradt',
         (select count(*) from pg_trigger
           where tgrelid='public.students'::regclass and not tgisinternal
             and tgname='students_protect_identity_trg')::text, '1'
  union all select 'naplozo fuggveny',
         (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname='log_status_event')::text, '1'
  union all select 'visszaallito fuggveny',
         (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname='status_model_rollback')::text, '1'

  -- A katalogus-tablak olvashatok, de csak admin irhatja
  union all select 'katalogus-tablak RLS-e bekapcsolva',
         (select count(*) from pg_class
           where relname in ('student_status','student_status_transition',
                             'student_track_state','student_track_transition')
             and relrowsecurity)::text, '4'
)
select mit, ertek, elvart,
       case when ertek = elvart then 'OK' else '>>> ELTER <<<' end as jelzes
from v;
