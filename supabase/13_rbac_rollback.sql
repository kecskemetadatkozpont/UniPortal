-- ============================================================
-- UniPortal Pro — VÉSZVISSZAÁLLÁS a 12-es flip után
-- ------------------------------------------------------------
-- MIKOR FUTTASD:
--   Ha a 12_rbac_flip.sql után bármelyik képernyő üresen jön be, hibát dob,
--   vagy egy kolléga nem éri el azt, amit elérnie kellene.
--
-- MIT CSINÁL:
--   Visszateszi a 07-es migráció "approved_all" policy-jét mind a 22 táblára.
--   Ettől a pillanattól minden jóváhagyott fiók újra mindent lát és ír —
--   vagyis pontosan a 12 előtti állapot.
--
-- MIT NEM CSINÁL:
--   Nem törli a rbac_ policy-ket és nem szedi le a triggereket. Nem is kell:
--   a Postgres a megengedő policy-ket VAGY-olja, tehát az approved_all
--   visszatétele önmagában feloldja a szűkítést. Így a 12 bármikor
--   újrafuttatható anélkül, hogy a 11-et újra kellene telepíteni.
--
--   FIGYELEM: a 4 integritás-trigger BENT MARAD. Ez szándékos — azok olyan
--   visszaéléseket zárnak, amiket a 12 előtti állapot is megengedett
--   (a jelentkező átírta a nevét, felvette magát, hamis naplót gyártott).
--   Ha valamiért ezeket is le kell szedni, a fájl végén megtalálod, kommentben.
--
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

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
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "approved_all" on public.%I', t);
    execute format(
      'create policy "approved_all" on public.%I for all to authenticated
         using (public.is_approved()) with check (public.is_approved())', t);
    n := n + 1;
  end loop;
  raise notice 'Visszaállítva % táblán az approved_all policy.', n;
end $$;

-- ---------- ellenőrzés ----------
with v as (
  select 'approved_all visszaallt' as mit,
         (select count(*) from pg_policies where schemaname='public' and policyname='approved_all')::text as ertek,
         '22' as elvart
  union all select 'rbac_ policy erintetlen',
         (select count(*) from pg_policies where schemaname='public' and policyname like 'rbac\_%')::text, '86'
)
select mit, ertek, elvart, case when ertek=elvart then 'OK' else '*** ELTER ***' end as allapot from v;

-- ------------------------------------------------------------
-- HA A TRIGGEREKET IS LE KELL SZEDNI (csak nagyon indokolt esetben):
--
--   drop trigger if exists students_protect_identity_trg  on public."students";
--   drop trigger if exists interviewslots_force_owner_trg on public."interviewSlots";
--   drop trigger if exists auditlogs_force_actor_trg      on public."auditLogs";
--   drop trigger if exists payments_force_owner_trg       on public."payments";
--
-- Ezzel viszont visszanyílik: a jelentkező átírja a saját nevét és onnantól
-- más fizetéseit látja; 'Accepted'-re állítja magát; idegen névre foglal
-- interjú-idősávot; hamis naplóbejegyzést gyárt. Mind a négy mérve volt.
-- ------------------------------------------------------------
