-- ============================================================
-- UniPortal Pro — RLS szigorítás: anonim írás kikapcsolása (ajánlott)
--
-- MIÉRT:
--   A 01-es migráció a 14 demo táblára "for all to anon, authenticated"
--   policy-t tesz. Mivel a publikálható Supabase kulcs benne van a statikus
--   oldal forrásában, ez azt jelenti, hogy BÁRKI — bejelentkezés nélkül —
--   olvashatja, írhatja és törölheti a demo adatokat.
--
--   Az alkalmazás minden adatlekérése bejelentkezés UTÁN történik (a
--   landing page és a login képernyő csak a Supabase Auth-ot használja),
--   ezért az "anon" jogosultság elvétele semmit nem tör el, viszont
--   megszünteti azt, hogy egy véletlen látogató kiürítse a demót.
--
-- FUTTATÁS: Supabase dashboard → SQL Editor → New query → beilleszt → Run
-- Idempotens — biztonságosan újrafuttatható.
--
-- VISSZAVONÁS: futtasd újra a 01_schema_and_seed.sql végén lévő
-- policy-blokkot (vagy a 00_setup_all.sql 1/5 részét).
-- ============================================================

do $$
declare t text;
begin
  foreach t in array array[
    'users', 'students', 'payments', 'invoices', 'campaigns', 'auditLogs',
    'webhooks', 'interviewSlots', 'agencies', 'leads', 'marketingCampaigns',
    'scholarships', 'integrations', 'videoInterviewQuestions'
  ]
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "demo_all" on public.%I', t);
    execute format(
      'create policy "demo_all" on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- Ellenőrzés: a "roles" oszlopban már csak {authenticated} szerepelhet.
select tablename, policyname, roles
from pg_policies
where schemaname = 'public' and policyname = 'demo_all'
order by tablename;
