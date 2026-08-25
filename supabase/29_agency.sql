-- ============================================================
-- UniPortal Pro — Ügynökségi portál (II/3)
-- Változat: 2026-08-25, HELYI POSTGRES-REPLIKÁN MÉRVE
--
-- MIT OLD MEG (a tesztelői visszajelzések sorrendjében):
--   0. A TÖRÖTT ADATKAPCSOLAT. A students."agentId" 'A1','A2','A3'
--      értékeket tárolt, az agencies.id viszont 'AG1','AG2','AG3' —
--      a két oldal SOHA nem talált össze. A frontend ráadásul egy
--      NEM LÉTEZŐ students."agencyId" mezőre szűrt, ami a Supabase-ből
--      jövő sorokon mindig undefined, tehát a szűrés semmit nem szűrt:
--      MÉRVE, hogy az AG1 ügynök mind a 11 diákot látta (ebből 6 másé).
--      Innentől a KANONIKUS kapcsolat: students."agentId" -> agencies.id,
--      idegenkulccsal. A régi érték a "agentId_legacy" oszlopban marad.
--   1./7. Ügynökségi önregisztráció. A handle_new_user eddig CSAK profilt
--      hozott létre AGENT szerepkörrel, ügynökség-sort nem — ezért az
--      önregisztrált ügynökségek sehol nem jelentek meg. Innentől
--      függőben lévő agencies sor is születik, és az admin dönt róla
--      (agency_decide), indoklással, az auditLogs-ba naplózva.
--   2. Ügynökségi elszigetelés RLS-szinten. RESTRICTIVE policy-vel, hogy
--      a 07-es migráció "approved_all" permisszív policy-je se tudja
--      megkerülni (a permisszívek VAGY-olódnak, a restrictive AND-elődik).
--   3. Kifizetés helyett SZÁMLÁZÁS: az admin számlát IGÉNYEL, az ügynökség
--      számlát CSATOL (documents bucket), a pénzügy jóváhagy vagy elutasít.
--   4. Jutalék CSAK a beiratkozás lezárása után. Új: students."enrolled_at"
--      (a beiratkozás ténye) + agency_commission_period (a beiratkozási
--      időszak nyit/zár állapota). Év közben (open időszak) az igénylés
--      kivételt dob. A listát az ADMIN állítja össze és küldi ki.
--   5. Ügynökségi dokumentumok (szerződés, meghatalmazás) a meglévő
--      'documents' bucketre építve.
--   6. Két új adatlap-mező: country_of_origin (egy) és
--      countries_of_recruitment (több).
--
-- FUTTATÁS: Supabase dashboard -> SQL Editor -> New query -> beilleszt -> Run
-- IDEMPOTENS — kétszer lefuttatva ugyanaz az eredmény (mérve).
-- FÜGG: 01, 07, 08, 11, 25.
-- ============================================================

-- ============================================================
-- 1. SZAKASZ — A TÖRÖTT ADATKAPCSOLAT JAVÍTÁSA
-- ============================================================

-- 1.1 A régi érték megőrzése, hogy a leképezés visszakövethető legyen.
alter table public."students" add column if not exists "agentId_legacy" text;

update public."students"
   set "agentId_legacy" = "agentId"
 where "agentId_legacy" is null
   and "agentId" is not null;

-- 1.2 Leképezés: 'A<n>' -> 'AG<n>', de CSAK ha a céloldal tényleg létezik.
--     Mérve a replikán: agentId A1=5, A2=3, A3=2, NULL=1 sor;
--     agencies.id = AG1, AG2, AG3.
do $mig29_map$
declare
  n integer;
begin
  update public."students" s
     set "agentId" = 'AG' || substring(s."agentId" from '^A([0-9]+)$')
   where s."agentId" ~ '^A[0-9]+$'
     and exists (
       select 1 from public."agencies" a
        where a.id = 'AG' || substring(s."agentId" from '^A([0-9]+)$')
     );
  get diagnostics n = row_count;
  raise notice '29: % students sor kapott kanonikus agencies.id-t.', n;
end
$mig29_map$;

-- 1.3 Ami így sem talál ügynökséget, az egyéni jelentkező (NULL). A régi
--     érték nem vész el: az "agentId_legacy" megőrizte.
update public."students" s
   set "agentId" = null
 where s."agentId" is not null
   and not exists (select 1 from public."agencies" a where a.id = s."agentId");

-- 1.4 Idegenkulcs — innentől az adatbázis őrzi, hogy a lánc ép marad.
do $mig29_fk$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'students_agentid_fkey'
       and conrelid = 'public.students'::regclass
  ) then
    alter table public."students"
      add constraint students_agentid_fkey
      foreign key ("agentId") references public."agencies"(id) on delete set null;
  end if;
end
$mig29_fk$;

create index if not exists students_agentid_idx on public."students" ("agentId");

-- ============================================================
-- 2. SZAKASZ — AZ ÜGYNÖKSÉG ADATLAPJA (6. tétel) ÉS ÉLETCIKLUSA (1./7.)
-- ============================================================

-- 2.1 Két új adatlap-mező.
--     country_of_origin      : EGY érték (az ügynökség székhelye)
--     countries_of_recruitment: TÖBB érték (ahonnan toboroz)
alter table public."agencies" add column if not exists "country_of_origin" text;
alter table public."agencies" add column if not exists "countries_of_recruitment" text[] not null default '{}';

-- 2.2 Elfogadás/elutasítás — az önregisztrált ügynökség itt kap döntést.
alter table public."agencies" add column if not exists "approval_status" text not null default 'pending';
alter table public."agencies" add column if not exists "requested_by"    uuid;
alter table public."agencies" add column if not exists "requested_at"    timestamptz not null default now();
alter table public."agencies" add column if not exists "decided_by"      text;
alter table public."agencies" add column if not exists "decided_at"      timestamptz;
alter table public."agencies" add column if not exists "rejected_reason" text;
alter table public."agencies" add column if not exists "self_registered" boolean not null default false;

do $mig29_agchk$
begin
  if not exists (select 1 from pg_constraint where conname = 'agencies_approval_status_check') then
    alter table public."agencies"
      add constraint agencies_approval_status_check
      check ("approval_status" in ('pending', 'approved', 'rejected'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'agencies_requested_by_fkey') then
    alter table public."agencies"
      add constraint agencies_requested_by_fkey
      foreign key ("requested_by") references public."profiles"(id) on delete set null;
  end if;
end
$mig29_agchk$;

-- 2.3 A már meglévő (seed) ügynökségek visszamenőleg jóváhagyottak: ezekkel
--     eddig is dolgoztak a kollégák, nem tehetjük őket függővé.
update public."agencies"
   set "approval_status" = 'approved',
       "decided_at"      = coalesce("decided_at", now()),
       "decided_by"      = coalesce("decided_by", 'migration 29')
 where "approval_status" = 'pending'
   and "self_registered" = false;

create index if not exists agencies_approval_status_idx on public."agencies" ("approval_status");

-- ============================================================
-- 3. SZAKASZ — A BEIRATKOZÁS TÉNYE (4. tétel alapja)
-- ============================================================
--
-- A 25_status_model.sql fő lánca a 'Accepted' státusszal ér véget: az a
-- FELVÉTEL, nem a BEIRATKOZÁS. A jutalék viszont a ténylegesen beiratkozott
-- hallgató után jár, ezért kell egy külön, egyértelmű jelzés.
alter table public."students" add column if not exists "enrolled_at" date;

create index if not exists students_enrolled_at_idx on public."students" ("enrolled_at");

-- 3.1 Őrtrigger: a beiratkozás tényét csak ügyintéző írhatja, és csak
--     'Accepted' fő státusz mellett (a 25-ös állapotgép végállapota).
create or replace function public.students_enrollment_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE'
     and new."enrolled_at" is distinct from old."enrolled_at"
     and not public.is_staff()
     and auth.uid() is not null then
    -- Nem hibát dobunk, hanem visszaírjuk: ugyanaz a minta, mint a
    -- 11-es migráció students_protect_identity triggerénél.
    new."enrolled_at" := old."enrolled_at";
    return new;
  end if;

  if new."enrolled_at" is not null and coalesce(new."status", '') <> 'Accepted' then
    raise exception
      'A beiratkozás csak "Accepted" (Felvéve) fő státusz mellett rögzíthető (a jelenlegi: "%").',
      coalesce(new."status", '(nincs)')
      using errcode = 'check_violation';
  end if;
  return new;
end
$$;

drop trigger if exists students_enrollment_guard_trg on public."students";
create trigger students_enrollment_guard_trg
  before insert or update on public."students"
  for each row execute function public.students_enrollment_guard();

-- ============================================================
-- 4. SZAKASZ — ÚJ TÁBLÁK
-- ============================================================

-- 4.1 Ügynökségi dokumentumtár (5. tétel).
--     A fájl a MEGLÉVŐ 'documents' bucketben él (08_documents_storage.sql),
--     itt csak az elérési út és a metaadat marad. Az útvonal-konvenció
--     a 08-as policy-k miatt KÖTÖTT:  <auth.uid()>/agency/<agencyId>/<fájl>
create table if not exists public.agency_document (
  id           text primary key,
  agency_id    text not null references public."agencies"(id) on delete cascade,
  kind         text not null default 'other',
  title        text not null,
  path         text not null,
  file_name    text,
  file_size    bigint,
  valid_from   date,
  valid_until  date,
  note         text,
  uploaded_by  uuid references public."profiles"(id) on delete set null,
  uploaded_at  timestamptz not null default now()
);

do $mig29_doc$
begin
  if not exists (select 1 from pg_constraint where conname = 'agency_document_kind_check') then
    alter table public.agency_document
      add constraint agency_document_kind_check
      check (kind in ('contract', 'power_of_attorney', 'certificate', 'invoice', 'other'));
  end if;
end
$mig29_doc$;

create index if not exists agency_document_agency_idx on public.agency_document (agency_id);
create unique index if not exists agency_document_path_key on public.agency_document (path);

-- 4.2 Beiratkozási időszak (4. tétel).
--     Amíg 'open', jutalékot IGÉNYELNI SEM LEHET. A zárás admin művelete.
create table if not exists public.agency_commission_period (
  id         text primary key,
  label      text not null,
  term       text,
  opens_on   date,
  closes_on  date,
  state      text not null default 'open',
  closed_at  timestamptz,
  closed_by  text,
  created_at timestamptz not null default now()
);

do $mig29_per$
begin
  if not exists (select 1 from pg_constraint where conname = 'agency_commission_period_state_check') then
    alter table public.agency_commission_period
      add constraint agency_commission_period_state_check
      check (state in ('open', 'closed'));
  end if;
end
$mig29_per$;

-- Egy induló időszak, hogy a felület ne üres listával nyíljon.
insert into public.agency_commission_period (id, label, term, opens_on, closes_on, state)
values ('PER-2024-25-1', '2024/25 őszi beiratkozás', '2024/25/1',
        date '2024-08-01', date '2024-10-15', 'open')
on conflict (id) do nothing;

-- 4.3 Ügynökségi számla (3. + 4. tétel).
--     Az ÉLETCIKLUS SZÁNDÉKOSAN az adminnál kezdődik:
--       requested  — az admin számlát kért (a jutaléklistával együtt)
--       submitted  — az ügynökség csatolta a saját számláját
--       approved   — a pénzügy elfogadta
--       rejected   — a pénzügy visszaküldte (indoklással, újracsatolható)
--       paid       — kifizetve
--     Az ügynökség SEHOL nem tud 'requested' sort létrehozni: a jutalékot
--     nem ő igényli, hanem az admin küldi ki.
create table if not exists public.agency_invoice (
  id             text primary key,
  agency_id      text not null references public."agencies"(id) on delete cascade,
  period_id      text references public.agency_commission_period(id) on delete set null,
  status         text not null default 'requested',
  amount         numeric not null default 0,
  currency       text not null default 'EUR',
  student_count  integer not null default 0,
  requested_at   timestamptz not null default now(),
  requested_by   text,
  due_on         date,
  note           text,
  invoice_number text,
  issued_on      date,
  document_id    text references public.agency_document(id) on delete set null,
  submitted_at   timestamptz,
  submitted_by   text,
  decided_at     timestamptz,
  decided_by     text,
  reject_reason  text,
  paid_at        timestamptz
);

do $mig29_inv$
begin
  if not exists (select 1 from pg_constraint where conname = 'agency_invoice_status_check') then
    alter table public.agency_invoice
      add constraint agency_invoice_status_check
      check (status in ('requested', 'submitted', 'approved', 'rejected', 'paid'));
  end if;
end
$mig29_inv$;

create index if not exists agency_invoice_agency_idx on public.agency_invoice (agency_id);
create index if not exists agency_invoice_status_idx on public.agency_invoice (status);

-- 4.4 A számla jutalék-tételei: PILLANATKÉP a kiküldés idejéből.
--     Ha a tandíj vagy a jutalékkulcs később változik, a kiküldött számla
--     nem mozdul el alóla.
create table if not exists public.agency_commission_item (
  id           text primary key,
  invoice_id   text not null references public.agency_invoice(id) on delete cascade,
  student_id   text,
  student_name text,
  program      text,
  tuition_fee  numeric not null default 0,
  rate         numeric not null default 0,
  amount       numeric not null default 0,
  enrolled_on  date
);

create index if not exists agency_commission_item_invoice_idx on public.agency_commission_item (invoice_id);
create unique index if not exists agency_commission_item_uniq on public.agency_commission_item (invoice_id, student_id);

-- ============================================================
-- 5. SZAKASZ — RLS: AZ ÜGYNÖKSÉGI ELSZIGETELÉS (2. tétel)
-- ============================================================
--
-- MIÉRT RESTRICTIVE: a Postgres a PERMISSZÍV policy-ket VAGY-olja, tehát
-- amíg a 07-es migráció "approved_all" policy-je él (mérve: ÉL a students
-- és az agencies táblán), addig hiába szűkít a rbac_students_select — az
-- approved_all úgyis átengedi mind a 11 sort. A RESTRICTIVE policy viszont
-- AND-elődik MINDEN permisszívvel, tehát akkor is zár, ha az approved_all
-- ott marad. Mérve: az AG1 ügynök 11 -> 5 sorra esik, más ügynökség diákja 0.

drop policy if exists "agency_isolation_students" on public."students";
create policy "agency_isolation_students" on public."students"
  as restrictive for all to authenticated
  using (
    not public.is_agent()
    or (public.my_agency() is not null and "agentId" = public.my_agency())
  )
  with check (
    not public.is_agent()
    or (public.my_agency() is not null and "agentId" = public.my_agency())
  );

drop policy if exists "agency_isolation_agencies" on public."agencies";
create policy "agency_isolation_agencies" on public."agencies"
  as restrictive for all to authenticated
  using (
    not public.is_agent()
    or (public.my_agency() is not null and id = public.my_agency())
  )
  with check (
    not public.is_agent()
    or (public.my_agency() is not null and id = public.my_agency())
  );

-- 5.1 Az új táblák saját policy-készlete (a 11-es migráció "rbac_" mintája).
alter table public.agency_document          enable row level security;
alter table public.agency_commission_period enable row level security;
alter table public.agency_invoice           enable row level security;
alter table public.agency_commission_item   enable row level security;

-- agency_document
drop policy if exists "rbac_agency_document_select" on public.agency_document;
create policy "rbac_agency_document_select" on public.agency_document
  for select to authenticated
  using (public.is_staff() or (public.is_agent() and agency_id = public.my_agency()));

drop policy if exists "rbac_agency_document_insert" on public.agency_document;
create policy "rbac_agency_document_insert" on public.agency_document
  for insert to authenticated
  with check (public.is_staff() or (public.is_agent() and agency_id = public.my_agency()));

drop policy if exists "rbac_agency_document_update" on public.agency_document;
create policy "rbac_agency_document_update" on public.agency_document
  for update to authenticated
  using (public.is_staff() or (public.is_agent() and agency_id = public.my_agency()))
  with check (public.is_staff() or (public.is_agent() and agency_id = public.my_agency()));

drop policy if exists "rbac_agency_document_delete" on public.agency_document;
create policy "rbac_agency_document_delete" on public.agency_document
  for delete to authenticated
  using (public.is_staff() or (public.is_agent() and agency_id = public.my_agency() and uploaded_by = auth.uid()));

-- agency_commission_period — mindenki OLVASSA (az ügynök is lássa, hogy
-- nyitva van-e még az időszak), de csak az admin írja.
drop policy if exists "rbac_agency_period_select" on public.agency_commission_period;
create policy "rbac_agency_period_select" on public.agency_commission_period
  for select to authenticated using (public.is_approved());

drop policy if exists "rbac_agency_period_write" on public.agency_commission_period;
create policy "rbac_agency_period_write" on public.agency_commission_period
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- agency_invoice — az ügynökség LÁTJA a sajátját, de nem ír rá közvetlenül:
-- a csatolás a SECURITY DEFINER agency_invoice_attach() RPC-n megy át.
drop policy if exists "rbac_agency_invoice_select" on public.agency_invoice;
create policy "rbac_agency_invoice_select" on public.agency_invoice
  for select to authenticated
  using (public.is_staff() or (public.is_agent() and agency_id = public.my_agency()));

drop policy if exists "rbac_agency_invoice_insert" on public.agency_invoice;
create policy "rbac_agency_invoice_insert" on public.agency_invoice
  for insert to authenticated
  with check (public.is_admin() or public.is_finance());

drop policy if exists "rbac_agency_invoice_update" on public.agency_invoice;
create policy "rbac_agency_invoice_update" on public.agency_invoice
  for update to authenticated
  using (public.is_admin() or public.is_finance())
  with check (public.is_admin() or public.is_finance());

drop policy if exists "rbac_agency_invoice_delete" on public.agency_invoice;
create policy "rbac_agency_invoice_delete" on public.agency_invoice
  for delete to authenticated using (public.is_admin());

-- agency_commission_item
drop policy if exists "rbac_agency_item_select" on public.agency_commission_item;
create policy "rbac_agency_item_select" on public.agency_commission_item
  for select to authenticated
  using (
    public.is_staff()
    or exists (
      select 1 from public.agency_invoice i
       where i.id = invoice_id
         and public.is_agent()
         and i.agency_id = public.my_agency()
    )
  );

drop policy if exists "rbac_agency_item_write" on public.agency_commission_item;
create policy "rbac_agency_item_write" on public.agency_commission_item
  for all to authenticated
  using (public.is_admin() or public.is_finance())
  with check (public.is_admin() or public.is_finance());

-- 5.2 Storage: az ügynökségi dokumentumot az ügynökség MINDEN tagja lássa,
--     ne csak a feltöltő. A 08-as "documents_read" policy csak a saját
--     mappát engedi; ezt bővítjük az agency_document-ben regisztrált utakkal.
do $mig29_stor$
begin
  begin
    execute $p$drop policy if exists "documents_read" on storage.objects$p$;
    execute $p$create policy "documents_read" on storage.objects
              for select to authenticated
              using (
                bucket_id = 'documents'
                and (
                  (storage.foldername(name))[1] = auth.uid()::text
                  or public.is_staff()
                  or exists (
                    select 1 from public.agency_document d
                     where d.path = storage.objects.name
                       and public.is_agent()
                       and d.agency_id = public.my_agency()
                  )
                )
              )$p$;
  exception when others then
    raise notice '29: storage policy kihagyva (%). Allitsd be kezzel: Storage -> documents -> Policies.', sqlerrm;
  end;
end
$mig29_stor$;

-- ============================================================
-- 6. SZAKASZ — ÖNREGISZTRÁCIÓ: ÜGYNÖKSÉG-SOR IS SZÜLESSEN (1./7. tétel)
-- ============================================================
--
-- A 07-es migráció handle_new_user() függvénye eddig CSAK profiles sort
-- hozott létre AGENT szerepkörrel. Ügynökség-sor nélkül az admin
-- "Ügynökségek" listája nem tudott róla — ezért panaszkodtak a tesztelők,
-- hogy az önregisztrált ügynökségek "eltűnnek". Innentől a trigger
-- FÜGGŐBEN LÉVŐ agencies sort is létrehoz, és a profilt hozzáköti.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  wanted_role text;
  is_super    boolean;
  ag_id       text;
  ag_name     text;
  ag_countries text[];
begin
  is_super    := lower(new.email) = public.superadmin_email();
  wanted_role := upper(coalesce(new.raw_user_meta_data->>'role', 'STUDENT'));
  ag_id       := nullif(new.raw_user_meta_data->>'agencyId', '');

  -- Önregisztráló ügynök, aki NEM egy meglévő ügynökséghez csatlakozik:
  -- neki nyitunk egy függőben lévő ügynökség-sort.
  if wanted_role = 'AGENT' and not is_super and ag_id is null then
    ag_name := nullif(trim(coalesce(new.raw_user_meta_data->>'agencyName', '')), '');
    if ag_name is null then
      ag_name := coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1));
    end if;

    -- 'countries_of_recruitment': tömb vagy vesszős lista is jöhet.
    begin
      if jsonb_typeof(new.raw_user_meta_data->'agencyCountries') = 'array' then
        select coalesce(array_agg(trim(v)), '{}')
          into ag_countries
          from jsonb_array_elements_text(new.raw_user_meta_data->'agencyCountries') v
         where trim(v) <> '';
      else
        select coalesce(array_agg(trim(v)), '{}')
          into ag_countries
          from unnest(string_to_array(coalesce(new.raw_user_meta_data->>'agencyCountries', ''), ',')) v
         where trim(v) <> '';
      end if;
    exception when others then
      ag_countries := '{}';
    end;

    ag_id := 'AG-' || substr(md5(new.id::text), 1, 10);
  end if;

  -- A SORREND KÖTÖTT, és mérésből tanultuk meg: az agencies."requested_by"
  -- a profiles(id)-ra mutat, tehát a PROFIL SORNAK ELŐBB kell megszületnie.
  -- Fordított sorrendben az idegenkulcs azonnal eldobja az egész
  -- önregisztrációt ("agencies_requested_by_fkey"), és az ügynök egyáltalán
  -- nem tud regisztrálni. A profiles."agencyId" nem idegenkulcs, ezért
  -- előre beírható a még nem létező ügynökség azonosítója.
  insert into public.profiles (id, email, name, role, requested_role, "agencyId", approval_status, approved_at)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
    case when is_super then 'SUPERADMIN' else wanted_role end,
    wanted_role,
    ag_id,
    case when is_super then 'approved' else 'pending' end,
    case when is_super then now() else null end
  )
  on conflict (id) do nothing;

  -- Most már van mire hivatkoznia a requested_by-nak.
  if ag_name is not null then
    insert into public."agencies"
      (id, name, "commissionRate", "contactPerson", email, status,
       "country_of_origin", "countries_of_recruitment",
       "approval_status", "requested_by", "requested_at", "self_registered")
    values
      (ag_id, ag_name, 0,
       coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
       new.email, 'Pending',
       nullif(trim(coalesce(new.raw_user_meta_data->>'agencyCountry', '')), ''),
       coalesce(ag_countries, '{}'),
       'pending', new.id, now(), true)
    on conflict (id) do nothing;
  end if;

  return new;
end $$;

-- ============================================================
-- 7. SZAKASZ — MŰVELETEK (RPC)
-- ============================================================

-- 7.1 Az admin döntése az ügynökségi regisztrációról (1./7. tétel).
--     A döntés az auditLogs-ba kerül (log_status_event), és a jóváhagyás
--     az ügynökség felhasználói fiókjait is aktiválja — különben az admin
--     két helyen kattintana ugyanarról.
create or replace function public.agency_decide(
  p_agency   text,
  p_decision text,
  p_reason   text default null,
  p_rate     numeric default null
) returns public."agencies"
language plpgsql security definer set search_path = public as $$
declare
  ag public."agencies";
  who       text;
  jwt_saved text;
begin
  if not public.is_admin() and auth.uid() is not null then
    raise exception 'Csak SUPERADMIN vagy ADMIN dönthet ügynökségi regisztrációról.'
      using errcode = 'insufficient_privilege';
  end if;
  -- A döntéshozó nevét MOST rögzítjük: lentebb a JWT-t átmenetileg kiütjük,
  -- és utána a my_email() már nem tudná megmondani, ki döntött.
  who := coalesce(nullif(public.my_email(), ''), 'system (SQL)');
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Ismeretlen döntés: % (approved vagy rejected lehet).', p_decision
      using errcode = 'check_violation';
  end if;
  if p_decision = 'rejected' and coalesce(trim(p_reason), '') = '' then
    raise exception 'Az elutasításhoz indoklás kell.' using errcode = 'check_violation';
  end if;

  update public."agencies" a
     set "approval_status" = p_decision,
         "status"          = case when p_decision = 'approved' then 'Active' else 'Rejected' end,
         "commissionRate"  = case when p_decision = 'approved' and p_rate is not null
                                  then p_rate else a."commissionRate" end,
         "rejected_reason" = case when p_decision = 'rejected' then trim(p_reason) else null end,
         "decided_at"      = now(),
         "decided_by"      = who
   where a.id = p_agency
  returning * into ag;

  if ag.id is null then
    raise exception 'Nincs ilyen ügynökség: %', p_agency using errcode = 'no_data_found';
  end if;

  -- A hozzá tartozó fiókok együtt mozognak az ügynökséggel.
  --
  -- MÉRVE, ÉS EZÉRT NÉZ KI ÍGY: a 11-es migráció profiles_protect_privileges
  -- triggere NÉMÁN visszaírja az approval_status-t mindenkinek, aki nem
  -- SUPERADMIN és van JWT-je (nem hibát dob — egyszerűen nem történik semmi).
  -- Egy sima ADMIN döntése tehát nyom nélkül elveszett: az ügynökség
  -- jóváhagyottá vált, a hozzá tartozó fiók viszont 'pending' maradt, és a
  -- kolléga hiába próbált belépni.
  --
  -- A trigger a JWT NÉLKÜLI hívót (migráció, SQL Editor, service_role)
  -- megbízhatónak tekinti. Ez a függvény SECURITY DEFINER, a jogosultságot
  -- pedig már fent ellenőriztük, tehát erre az EGY utasításra jogosan
  -- lépünk be ezen az ajtón: a claimeket tranzakció-lokálisan kiütjük,
  -- majd visszaállítjuk. A 11-es migrációhoz nem nyúlunk.
  -- ÜRES SZTRING NEM JÓ IDE, és ezt is méréssel tanultuk meg: az auth.uid()
  -- a claimeket JSON-ként olvassa, az '' pedig érvénytelen JSON — az egész
  -- hívás elszállt volna. Az ÜRES JSON OBJEKTUM viszont mindkét oldalon
  -- (helyi replika és Supabase) szabályosan NULL azonosítót ad.
  jwt_saved := coalesce(current_setting('request.jwt.claims', true), '{}');
  perform set_config('request.jwt.claims', '{}', true);

  update public.profiles
     set approval_status = case when p_decision = 'approved' then 'approved' else 'rejected' end,
         rejected_reason = case when p_decision = 'rejected' then trim(p_reason) else null end
   where "agencyId" = p_agency
     and role = 'AGENT'
     and approval_status = 'pending';

  -- A trigger a státuszváltáskor 'sql-editor'-t ír az approved_by-ba (mert
  -- épp nincs JWT). Egy külön, státuszt NEM mozgató utasítással írjuk vissza
  -- a valódi döntéshozót — ezt a trigger már békén hagyja.
  update public.profiles
     set approved_by = who
   where "agencyId" = p_agency
     and role = 'AGENT'
     and approved_by = 'sql-editor';

  perform set_config('request.jwt.claims', coalesce(nullif(jwt_saved, ''), '{}'), true);

  perform public.log_status_event(
    'agency.' || p_decision,
    'agencies/' || ag.id,
    ag.name || ' -> ' || p_decision || coalesce(' (' || nullif(trim(p_reason), '') || ')', '')
  );
  return ag;
end
$$;

-- 7.2 A beiratkozás tényének rögzítése (ügyintéző).
create or replace function public.student_set_enrolled(
  p_student text,
  p_on      date default current_date
) returns public."students"
language plpgsql security definer set search_path = public as $$
declare st public."students";
begin
  if not public.is_staff() and auth.uid() is not null then
    raise exception 'A beiratkozást csak ügyintéző rögzítheti.' using errcode = 'insufficient_privilege';
  end if;
  update public."students" set "enrolled_at" = p_on where id = p_student returning * into st;
  if st.id is null then
    raise exception 'Nincs ilyen jelentkező: %', p_student using errcode = 'no_data_found';
  end if;
  perform public.log_status_event('student.enrolled', 'students/' || st.id,
    coalesce(st.name, st.id) || ' beiratkozott: ' || coalesce(p_on::text, '(törölve)'));
  return st;
end
$$;

-- 7.3 Beiratkozási időszak zárása / újranyitása (admin).
create or replace function public.agency_period_set_state(
  p_period text,
  p_state  text
) returns public.agency_commission_period
language plpgsql security definer set search_path = public as $$
declare pr public.agency_commission_period;
begin
  if not public.is_admin() and auth.uid() is not null then
    raise exception 'A beiratkozási időszakot csak ADMIN zárhatja vagy nyithatja.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_state not in ('open', 'closed') then
    raise exception 'Ismeretlen állapot: %', p_state using errcode = 'check_violation';
  end if;
  update public.agency_commission_period
     set state     = p_state,
         closed_at = case when p_state = 'closed' then now() else null end,
         closed_by = case when p_state = 'closed'
                          then coalesce(nullif(public.my_email(), ''), 'system (SQL)') else null end
   where id = p_period
  returning * into pr;
  if pr.id is null then
    raise exception 'Nincs ilyen időszak: %', p_period using errcode = 'no_data_found';
  end if;
  perform public.log_status_event('agency.period.' || p_state, 'agency_commission_period/' || pr.id, pr.label);
  return pr;
end
$$;

-- 7.4 Jutalék-előnézet: MELY hallgatók után jár jutalék az időszakban?
--     A lista a TÉNYLEGESEN BEIRATKOZOTT hallgatókból áll (enrolled_at),
--     nem a felvett vagy fizetett jelentkezőkből.
create or replace function public.agency_commission_preview(
  p_period text,
  p_agency text default null
) returns table (
  agency_id    text,
  agency_name  text,
  student_id   text,
  student_name text,
  program      text,
  tuition_fee  numeric,
  rate         numeric,
  amount       numeric,
  enrolled_on  date,
  already_invoiced boolean
)
language sql stable security definer set search_path = public as $$
  select a.id,
         a.name,
         s.id,
         s.name,
         s.program,
         coalesce(s."tuitionFee", 0),
         coalesce(a."commissionRate", 0),
         round(coalesce(s."tuitionFee", 0) * coalesce(a."commissionRate", 0) / 100.0, 2),
         s."enrolled_at",
         exists (
           select 1
             from public.agency_commission_item ci
             join public.agency_invoice i on i.id = ci.invoice_id
            where ci.student_id = s.id
              and i.period_id = p_period
              and i.status <> 'rejected'
         )
    from public."students" s
    join public."agencies" a on a.id = s."agentId"
    join public.agency_commission_period pr on pr.id = p_period
   where s."enrolled_at" is not null
     and s."status" = 'Accepted'
     and a."approval_status" = 'approved'
     and (pr.opens_on  is null or s."enrolled_at" >= pr.opens_on)
     and (pr.closes_on is null or s."enrolled_at" <= pr.closes_on)
     and (p_agency is null or a.id = p_agency)
     and (
       -- A rendszer-hívó (nincs JWT: psql, service_role) ugyanúgy lát, mint
       -- a többi függvényben — enélkül az admin SQL-ből hívva üres listát kap,
       -- és az agency_commission_issue tévesen "nincs elszámolható hallgató"-t jelent.
       auth.uid() is null
       or public.is_staff()
       or (public.is_agent() and a.id = public.my_agency())
     )
   order by a.name, s.name
$$;

-- 7.5 A jutalék KIKÜLDÉSE — ADMIN művelet, és CSAK LEZÁRT időszakra.
--     Ez a 4. tétel lényege: év közben (open időszak) a hívás elbukik,
--     és az ügynöknek egyáltalán nincs hívási joga.
create or replace function public.agency_commission_issue(
  p_period text,
  p_agency text,
  p_due_on date default null,
  p_note   text default null
) returns public.agency_invoice
language plpgsql security definer set search_path = public as $$
declare
  pr  public.agency_commission_period;
  ag  public."agencies";
  inv public.agency_invoice;
  n   integer := 0;
  tot numeric := 0;
begin
  if not public.is_admin() and auth.uid() is not null then
    raise exception 'A jutalék-számlaigénylést csak ADMIN küldheti ki (az ügynökség nem igényli).'
      using errcode = 'insufficient_privilege';
  end if;

  select * into pr from public.agency_commission_period where id = p_period;
  if pr.id is null then
    raise exception 'Nincs ilyen beiratkozási időszak: %', p_period using errcode = 'no_data_found';
  end if;
  if pr.state <> 'closed' then
    raise exception
      'A jutalék csak a beiratkozás LEZÁRÁSA után igényelhető. A(z) "%" időszak még nyitva van.',
      pr.label using errcode = 'check_violation';
  end if;

  select * into ag from public."agencies" where id = p_agency;
  if ag.id is null then
    raise exception 'Nincs ilyen ügynökség: %', p_agency using errcode = 'no_data_found';
  end if;
  if ag."approval_status" <> 'approved' then
    raise exception 'A(z) "%" ügynökség még nincs jóváhagyva.', ag.name using errcode = 'check_violation';
  end if;

  insert into public.agency_invoice
    (id, agency_id, period_id, status, amount, currency, student_count,
     requested_at, requested_by, due_on, note)
  values
    ('AGI-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12),
     ag.id, pr.id, 'requested', 0, 'EUR', 0,
     now(), coalesce(nullif(public.my_email(), ''), 'system (SQL)'),
     coalesce(p_due_on, (current_date + 30)), p_note)
  returning * into inv;

  insert into public.agency_commission_item
    (id, invoice_id, student_id, student_name, program, tuition_fee, rate, amount, enrolled_on)
  select 'AGC-' || substr(md5(inv.id || v.student_id), 1, 14),
         inv.id, v.student_id, v.student_name, v.program,
         v.tuition_fee, v.rate, v.amount, v.enrolled_on
    from public.agency_commission_preview(p_period, p_agency) v
   where v.already_invoiced = false
  on conflict (invoice_id, student_id) do nothing;

  select count(*), coalesce(sum(amount), 0) into n, tot
    from public.agency_commission_item where invoice_id = inv.id;

  if n = 0 then
    delete from public.agency_invoice where id = inv.id;
    raise exception
      'A(z) "%" ügynökséghez nincs elszámolható beiratkozott hallgató a(z) "%" időszakban.',
      ag.name, pr.label using errcode = 'no_data_found';
  end if;

  update public.agency_invoice
     set student_count = n, amount = tot
   where id = inv.id
  returning * into inv;

  perform public.log_status_event('agency.commission.issued', 'agency_invoice/' || inv.id,
    ag.name || ' · ' || pr.label || ' · ' || n || ' hallgató · ' || tot || ' EUR');
  return inv;
end
$$;

-- 7.6 Az ügynökség CSATOLJA a saját számláját (3. tétel).
--     A fájl a documents bucketben van; itt a dokumentum-sort kötjük rá.
create or replace function public.agency_invoice_attach(
  p_invoice   text,
  p_number    text,
  p_issued_on date,
  p_path      text,
  p_title     text default null,
  p_file_name text default null,
  p_file_size bigint default null,
  p_note      text default null
) returns public.agency_invoice
language plpgsql security definer set search_path = public as $$
declare
  inv public.agency_invoice;
  doc public.agency_document;
begin
  select * into inv from public.agency_invoice where id = p_invoice;
  if inv.id is null then
    raise exception 'Nincs ilyen számlaigénylés: %', p_invoice using errcode = 'no_data_found';
  end if;
  if auth.uid() is not null
     and not public.is_staff()
     and not (public.is_agent() and inv.agency_id = public.my_agency()) then
    raise exception 'Ehhez a számlaigényléshez nincs jogosultsága.' using errcode = 'insufficient_privilege';
  end if;
  if inv.status not in ('requested', 'rejected', 'submitted') then
    raise exception 'A(z) "%" állapotú számlához már nem csatolható új dokumentum.', inv.status
      using errcode = 'check_violation';
  end if;
  if coalesce(trim(p_number), '') = '' then
    raise exception 'A számlaszám kötelező.' using errcode = 'check_violation';
  end if;
  if coalesce(trim(p_path), '') = '' then
    raise exception 'A számla fájlját fel kell tölteni.' using errcode = 'check_violation';
  end if;

  insert into public.agency_document
    (id, agency_id, kind, title, path, file_name, file_size, note, uploaded_by, uploaded_at)
  values
    ('AGD-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12),
     inv.agency_id, 'invoice',
     coalesce(nullif(trim(p_title), ''), 'Számla ' || trim(p_number)),
     trim(p_path), p_file_name, p_file_size, p_note, auth.uid(), now())
  on conflict (path) do update
     set title = excluded.title, file_name = excluded.file_name, file_size = excluded.file_size
  returning * into doc;

  update public.agency_invoice
     set status         = 'submitted',
         invoice_number = trim(p_number),
         issued_on      = p_issued_on,
         document_id    = doc.id,
         submitted_at   = now(),
         submitted_by   = coalesce(nullif(public.my_email(), ''), 'system (SQL)'),
         reject_reason  = null,
         note           = coalesce(p_note, note)
   where id = inv.id
  returning * into inv;

  perform public.log_status_event('agency.invoice.submitted', 'agency_invoice/' || inv.id,
    'Számlaszám: ' || trim(p_number));
  return inv;
end
$$;

-- 7.7 A pénzügy / admin döntése a beérkezett számláról (3. tétel).
create or replace function public.agency_invoice_decide(
  p_invoice  text,
  p_decision text,
  p_reason   text default null
) returns public.agency_invoice
language plpgsql security definer set search_path = public as $$
declare inv public.agency_invoice;
begin
  if auth.uid() is not null and not (public.is_admin() or public.is_finance()) then
    raise exception 'A számláról csak ADMIN vagy PÉNZÜGY dönthet.' using errcode = 'insufficient_privilege';
  end if;
  if p_decision not in ('approved', 'rejected', 'paid') then
    raise exception 'Ismeretlen döntés: % (approved, rejected vagy paid).', p_decision
      using errcode = 'check_violation';
  end if;
  if p_decision = 'rejected' and coalesce(trim(p_reason), '') = '' then
    raise exception 'A visszaküldéshez indoklás kell.' using errcode = 'check_violation';
  end if;

  update public.agency_invoice
     set status        = p_decision,
         reject_reason = case when p_decision = 'rejected' then trim(p_reason) else null end,
         decided_at    = now(),
         decided_by    = coalesce(nullif(public.my_email(), ''), 'system (SQL)'),
         paid_at       = case when p_decision = 'paid' then now() else paid_at end
   where id = p_invoice
  returning * into inv;

  if inv.id is null then
    raise exception 'Nincs ilyen számla: %', p_invoice using errcode = 'no_data_found';
  end if;
  perform public.log_status_event('agency.invoice.' || p_decision, 'agency_invoice/' || inv.id,
    coalesce(inv.invoice_number, inv.id) || coalesce(' — ' || nullif(trim(p_reason), ''), ''));
  return inv;
end
$$;

-- ============================================================
-- 8. SZAKASZ — JOGOSULTSÁGOK
-- ============================================================
grant select, insert, update, delete on public.agency_document          to authenticated;
grant select, insert, update, delete on public.agency_invoice           to authenticated;
grant select, insert, update, delete on public.agency_commission_item   to authenticated;
grant select, insert, update, delete on public.agency_commission_period to authenticated;

grant execute on function public.agency_decide(text, text, text, numeric)                        to authenticated;
grant execute on function public.student_set_enrolled(text, date)                                to authenticated;
grant execute on function public.agency_period_set_state(text, text)                             to authenticated;
grant execute on function public.agency_commission_preview(text, text)                           to authenticated;
grant execute on function public.agency_commission_issue(text, text, date, text)                 to authenticated;
grant execute on function public.agency_invoice_attach(text, text, date, text, text, text, bigint, text) to authenticated;
grant execute on function public.agency_invoice_decide(text, text, text)                         to authenticated;
grant execute on function public.students_enrollment_guard()                                     to authenticated;

-- ============================================================
-- 9. SZAKASZ — VISSZAÁLLÍTÁS (ha valami félremegy)
-- ============================================================
create or replace function public.agency_module_rollback(p_confirm text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if p_confirm <> 'IGEN, TOROLD' then
    return 'Nem történt semmi. Hívás: select public.agency_module_rollback(''IGEN, TOROLD'');';
  end if;
  drop policy if exists "agency_isolation_students" on public."students";
  drop policy if exists "agency_isolation_agencies" on public."agencies";
  drop trigger if exists students_enrollment_guard_trg on public."students";
  drop table if exists public.agency_commission_item cascade;
  drop table if exists public.agency_invoice cascade;
  drop table if exists public.agency_commission_period cascade;
  drop table if exists public.agency_document cascade;
  -- Az adatátvezetés visszafordítása: a régi 'A<n>' érték visszaírása.
  alter table public."students" drop constraint if exists students_agentid_fkey;
  update public."students" set "agentId" = "agentId_legacy" where "agentId_legacy" is not null;
  return 'Az ügynökségi modul (29) visszaállítva. Az agencies új oszlopai megmaradtak.';
end
$$;

-- ============================================================
-- 10. SZAKASZ — ELLENŐRZÉS
-- ============================================================
select 'students.agentId -> agencies.id kotes' as mit,
       count(*) filter (where "agentId" is not null) as kotott,
       count(*) filter (where "agentId" is null)     as egyeni,
       count(*)                                      as osszes
  from public."students";

select 'agencies allapot' as mit, "approval_status", count(*)
  from public."agencies" group by 2 order by 2;

select 'uj tablak' as mit, table_name
  from information_schema.tables
 where table_schema = 'public'
   and table_name in ('agency_document', 'agency_invoice',
                      'agency_commission_period', 'agency_commission_item')
 order by 2;

select 'restrictive policy-k (2 kell)' as mit, count(*)
  from pg_policies
 where schemaname = 'public'
   and policyname in ('agency_isolation_students', 'agency_isolation_agencies');

select 'uj RPC-k (7 kell)' as mit, count(*)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('agency_decide', 'student_set_enrolled', 'agency_period_set_state',
                     'agency_commission_preview', 'agency_commission_issue',
                     'agency_invoice_attach', 'agency_invoice_decide');
