-- ============================================================
-- UniPortal Pro — WhatsApp Business (Meta Cloud API) tárolás (Step 12)
--
-- MIT CSINÁL:
--   • wa_contacts  — beszélgetőpartnerek. A `last_inbound_at` tartja nyilván,
--     mikor írt utoljára a jelentkező: ettől számít a Meta 24 órás
--     „customer service window"-ja, amin belül szabad szöveget is lehet
--     küldeni. Azon kívül CSAK jóváhagyott sablon mehet.
--   • wa_messages  — minden ki- és bemenő üzenet, kézbesítési státusszal.
--
--   Mindkettőt csak ügyintéző látja (public.is_staff(), 08-as migráció) —
--   jelentkező nem. Az Edge Function service role kulccsal ír, tehát az RLS
--   őt nem korlátozza; ez a policy a böngészőből jövő hozzáférésről szól.
--
-- FUTTATÁS: Supabase dashboard → SQL Editor → New query → beilleszt → Run
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

-- ---------- kapcsolatok ----------
create table if not exists public.wa_contacts (
  wa_id            text primary key,     -- E.164, + jel nélkül (pl. 36301234567)
  display_name     text,
  student_id       text,                 -- kapcsolás a students táblához, ha van
  last_inbound_at  timestamptz,          -- ettől számít a 24 órás ablak
  last_message_at  timestamptz,
  created_at       timestamptz default now()
);

-- ---------- üzenetek ----------
create table if not exists public.wa_messages (
  id             text primary key,
  wa_message_id  text,                   -- a Meta „wamid…" azonosítója
  wa_id          text not null,
  direction      text not null check (direction in ('in', 'out')),
  msg_type       text default 'text',    -- text | template | image | document | …
  body           text,
  template_name  text,
  status         text default 'queued'   -- queued | sent | delivered | read | failed
                 check (status in ('queued', 'sent', 'delivered', 'read', 'failed', 'received')),
  error          text,
  sent_by        text,                   -- a küldő ügyintéző e-mail-címe
  simulated      boolean default false,  -- Meta-hitelesítés nélküli, szimulált küldés
  created_at     timestamptz default now()
);

create unique index if not exists wa_messages_wamid_idx on public.wa_messages (wa_message_id) where wa_message_id is not null;
create index if not exists wa_messages_thread_idx on public.wa_messages (wa_id, created_at);
create index if not exists wa_contacts_student_idx on public.wa_contacts (student_id);

-- ---------- RLS: csak ügyintéző ----------
do $$
declare t text;
begin
  foreach t in array array['wa_contacts', 'wa_messages']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "wa_staff_all" on public.%I', t);
    execute format(
      'create policy "wa_staff_all" on public.%I for all to authenticated
         using (public.is_staff()) with check (public.is_staff())', t);
  end loop;
end $$;

-- ---------- Realtime: az inbox magától frissüljön ----------
do $$
begin
  begin execute 'alter publication supabase_realtime add table public.wa_messages'; exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table public.wa_contacts'; exception when others then null; end;
end $$;

-- ---------- segédfüggvény: nyitva van-e a 24 órás ablak? ----------
-- A felület ez alapján dönti el, hogy szabad szöveget vagy sablont ajánljon.
create or replace function public.wa_window_open(p_wa_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select last_inbound_at > now() - interval '24 hours' from public.wa_contacts where wa_id = p_wa_id),
    false)
$$;

grant execute on function public.wa_window_open(text) to authenticated;

-- ---------- ellenőrzés ----------
select 'wa_contacts' as tabla, count(*) from public.wa_contacts
union all
select 'wa_messages', count(*) from public.wa_messages;
