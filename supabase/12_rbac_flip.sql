-- ============================================================
-- UniPortal Pro — Szerepkör-alapú RLS, 2. fázis: ÁTKAPCSOLÁS
-- ------------------------------------------------------------
-- EZ AZ A LÉPÉS, AMI TÉNYLEGESEN VÁLTOZTAT.
--
-- MIT CSINÁL:
--   Eldobja a 07-es migráció "approved_all" policy-jét mind a 22 UniPortal
--   adattábláról. Ettől a ponttól kizárólag a 11-es migráció rbac_ policy-i
--   döntik el, ki mit lát és mit írhat.
--
-- ELŐFELTÉTEL — a szkript maga ellenőrzi és megtagadja a futást, ha nem áll:
--   • lefutott a 11_rbac_additive.sql (86 rbac_ policy, 22 táblán)
--   • megvan mind a 4 integritás-trigger
--   Ha bármelyik hiányzik, a szkript HIBÁVAL leáll és NEM módosít semmit.
--
-- VISSZAÁLLÍTÁS: 13_rbac_rollback.sql — egyetlen blokk, azonnal visszateszi
--   az approved_all-t. Tartsd nyitva egy külön SQL Editor fülön futtatás előtt.
--
-- MIT ÉRDEMES ELŐTTE ELDÖNTENI (mérve, lásd diagnostics/11_OLVASSEL.md):
--   • a hallgatói fiókok bekötése — 9 STUDENT profilból ma 1 köthető
--     students sorhoz; a többi 8 üres Hallgatói Portált fog kapni
--   • az ügynöki lánc — az agencies tábla üres, az AGENT 0 sort fog látni
--     (megjegyzés: az Ügynök portál ma is üres, ezen a flip nem ront)
--
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

-- ---------- 1. biztonsági fék ----------
do $$
declare
  n_policy int;
  n_table  int;
  n_trig   int;
begin
  select count(*), count(distinct tablename) into n_policy, n_table
    from pg_policies where schemaname='public' and policyname like 'rbac\_%';

  select count(*) into n_trig
    from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and not t.tgisinternal
     and t.tgname in ('students_protect_identity_trg','interviewslots_force_owner_trg',
                      'auditlogs_force_actor_trg','payments_force_owner_trg');

  if n_policy < 86 or n_table < 22 then
    raise exception
      'MEGTAGADVA: a 11_rbac_additive.sql nem futott le teljesen (% policy / % tábla, elvárt 86 / 22). Futtasd előbb azt.',
      n_policy, n_table;
  end if;

  if n_trig < 4 then
    raise exception
      'MEGTAGADVA: hiányzik % integritás-trigger a 4-ből. A flip enélkül lyukat nyitna (a jelentkező átírná a saját sorát).',
      4 - n_trig;
  end if;

  raise notice 'Előfeltétel rendben: % rbac_ policy, % tábla, % trigger.', n_policy, n_table, n_trig;
end $$;

-- ---------- 2. az approved_all eldobása ----------
do $$
declare t text; n int := 0;
begin
  foreach t in array array[
    'users', 'students', 'payments', 'invoices', 'campaigns', 'auditLogs',
    'webhooks', 'interviewSlots', 'agencies', 'leads', 'marketingCampaigns',
    'scholarships', 'integrations', 'videoInterviewQuestions',
    'admission_processes', 'process_messages',
    'feed_posts', 'event_rsvps', 'ticket_claims',
    'programs', 'program_applications', 'kb_documents'
  ]
  loop
    if to_regclass(format('public.%I', t)) is null then continue; end if;
    if exists (select 1 from pg_policies
                where schemaname='public' and tablename=t and policyname='approved_all') then
      execute format('drop policy "approved_all" on public.%I', t);
      n := n + 1;
    end if;
  end loop;
  raise notice 'Eldobva % approved_all policy.', n;
end $$;

-- ---------- 3. ellenőrzés ----------
with v as (
  select 'approved_all maradt (0 kell)' as mit,
         (select count(*) from pg_policies where schemaname='public' and policyname='approved_all')::text as ertek,
         '0' as elvart
  union all select 'rbac_ policy',
         (select count(*) from pg_policies where schemaname='public' and policyname like 'rbac\_%')::text, '86'
  union all select 'policy nelkuli UniPortal tabla (0 kell)',
         (select count(*) from (
            select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
             where n.nspname='public' and c.relkind='r' and c.relrowsecurity
               and c.relname in ('users','students','payments','invoices','campaigns','auditLogs',
                    'webhooks','interviewSlots','agencies','leads','marketingCampaigns','scholarships',
                    'integrations','videoInterviewQuestions','admission_processes','process_messages',
                    'feed_posts','event_rsvps','ticket_claims','programs','program_applications','kb_documents')
               and not exists (select 1 from pg_policies p
                                where p.schemaname='public' and p.tablename=c.relname)) x)::text, '0'
  union all select 'rbac_ policy az idegen app tablain (0 kell)',
         (select count(*) from pg_policies where schemaname='public'
            and tablename in ('prefs','publications','publication_files')
            and policyname like 'rbac\_%')::text, '0'
)
select mit, ertek, elvart, case when ertek=elvart then 'OK' else '*** ELTER ***' end as allapot from v;
