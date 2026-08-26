-- ============================================================================
-- RUN_ALL_35_36.sql  —  UniPortal
-- EGYBEN BEILLESZTHETŐ a Supabase SQL Editorba.
--
--   35_echo_comment.sql        jegyzőkönyv-átvétel + 7 napos oktatói észrevétel
--   36_echo_question_bank.sql  központi kérdésbank
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--   + a végén a MODUL SAJÁT ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a RUN_ALL_34.sql már lefutott.
-- Idempotens.
--
-- A SQL Editor csak az UTOLSÓ eredményt mutatja — ezért a csomag végén a
-- modul saját ellenőrző lekérdezése áll. Egy beillesztés, egy tábla,
-- benne a modul ÉS az anonimitás állapota. Külön futtatás nem kell.
-- ============================================================================


-- ===========================================================================
-- >>> 35_echo_comment.sql
-- ===========================================================================
-- ============================================================================
-- 35_echo_comment.sql — ECHO: jegyzőkönyv-átvétel és 7 napos oktatói észrevétel
--                       (III/2, a szabályzat 6. § (7) alapján)
-- ----------------------------------------------------------------------------
-- MIÉRT
--   A szabályzat szerint az oktatónak 7 napja van észrevételt tenni a saját
--   jegyzőkönyvére. A határidő NEM a kampány zárásától indul, hanem az
--   ÁTVÉTELTŐL: attól, hogy az oktató ténylegesen megkapta a jegyzőkönyvet.
--   Enélkül a 7 nap nem számolható, és a határidő nem védhető meg vitában.
--
-- NYITOTT INTÉZMÉNYI KÉRDÉS
--   Azt, hogy jogilag mi számít "átvételnek", még nem kaptuk meg. Ezért a
--   migráció a MECHANIZMUST építi meg, a jelentést nyitva hagyja: az átvétel
--   módja rögzíthető (személyes, e-mail, rendszeren belüli visszaigazolás),
--   és bármelyik indítja a 7 napot. Amikor a definíció megvan, elég a
--   megengedett módok listáját szűkíteni — az adat és a számítás marad.
--
-- A CÍMZETT
--   "A megfelelő címzetthez irányítva" — az észrevétel az oktató szervezeti
--   egységéhez tartozó TANSZEKVEZETO-höz megy. Ha ott nincs, felfelé lépünk a
--   hierarchiában (tanszék -> intézet -> kar -> egyetem), majd DEKAN, végül
--   MIR. A lépcső az echo.setting-ben átírható.
--
-- IDEMPOTENS. Visszavonás: select public.echo_comment_rollback();
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) Az átvétel ténye — innen indul a 7 nap
-- ---------------------------------------------------------------------------
create table if not exists echo.protocol_handover (
  id          uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references echo.campaign(id) on delete cascade,
  teacher_id  uuid not null references echo.teacher(id)  on delete cascade,
  handed_at   timestamptz not null default now(),
  handed_by   uuid,
  method      text not null default 'rendszer',
  note        text,
  created_at  timestamptz not null default now(),
  constraint protocol_handover_uniq unique (campaign_id, teacher_id),
  constraint protocol_handover_method_ck check (
    method in ('rendszer', 'email', 'szemelyes', 'posta'))
);

create index if not exists protocol_handover_campaign_idx
  on echo.protocol_handover (campaign_id, handed_at desc);

comment on table echo.protocol_handover is
  'A jegyzőkönyv átvételének ténye oktatónként. A 6. § (7) szerinti 7 napos '
  'észrevételi határidő EBBŐL indul, nem a kampány zárásából.';

-- ---------------------------------------------------------------------------
-- 2) Az észrevétel
-- ---------------------------------------------------------------------------
create table if not exists echo.teacher_comment (
  id             uuid primary key default gen_random_uuid(),
  campaign_id    uuid not null references echo.campaign(id) on delete cascade,
  teacher_id     uuid not null references echo.teacher(id)  on delete cascade,
  body           text not null,
  recipient      uuid,
  recipient_role text,
  recipient_org  uuid,
  state          text not null default 'submitted',
  submitted_at   timestamptz not null default now(),
  deadline_at    timestamptz,
  late           boolean not null default false,
  ack_by         uuid,
  ack_at         timestamptz,
  ack_note       text,
  constraint teacher_comment_state_ck check (
    state in ('submitted', 'acknowledged', 'withdrawn')),
  constraint teacher_comment_body_ck check (length(btrim(body)) between 1 and 20000)
);

create index if not exists teacher_comment_campaign_idx
  on echo.teacher_comment (campaign_id, submitted_at desc);
create index if not exists teacher_comment_recipient_idx
  on echo.teacher_comment (recipient, state);

comment on table echo.teacher_comment is
  '6. § (7) szerinti oktatói észrevétel. A late oszlop MEGŐRZI, hogy a beadás '
  'a határidőn túl történt-e — az észrevételt nem utasítjuk el, csak jelöljük.';

-- ---------------------------------------------------------------------------
-- 3) Beállítások
-- ---------------------------------------------------------------------------
insert into echo.setting(key, value) values
  ('comment_window_days', '7'),
  ('comment_recipient_chain', 'TANSZEKVEZETO,DEKAN,MIR')
on conflict (key) do nothing;

commit;

begin;

-- Szöveges beállítás olvasása (az echo.k() számot ad vissza).
create or replace function echo.k_text_setting(p_key text, p_default text)
returns text language sql stable as $$
  select coalesce((select value from echo.setting where key = p_key), p_default)
$$;

-- ---------------------------------------------------------------------------
-- 4) Ki a címzett?
--    Az oktató szervezeti egységéből indulunk, és FELFELÉ lépkedünk
--    (tanszék -> intézet -> kar -> egyetem). Minden szinten megnézzük a
--    lépcső első szerepkörét, aztán a következőt. Így a tanszékvezető
--    megelőzi a dékánt, de ha tanszékvezető sehol nincs, a dékán megkapja.
--
--    Az echo.role_grant.scope_org NULL értéke EGYETEM-szintű jogosultságot
--    jelent — az ilyen viselő minden szervezeti egységre illik.
-- ---------------------------------------------------------------------------
create or replace function echo.comment_recipient(p_teacher uuid)
returns table (person uuid, role text, org uuid)
language plpgsql
stable
as $$
declare
  v_org    uuid;
  v_lanc   text[];
  v_szerep text;
  v_ancest uuid[];
  v_o      uuid;
begin
  select t.org_unit_id into v_org from echo.teacher t where t.id = p_teacher;

  v_lanc := string_to_array(
    coalesce(echo.k_text_setting('comment_recipient_chain', 'TANSZEKVEZETO,DEKAN,MIR'), ''), ',');

  if v_org is not null then
    select array_agg(a order by ord) into v_ancest
      from (select a, row_number() over () as ord
              from echo.org_ancestors(v_org) a) s;
  end if;

  foreach v_szerep in array v_lanc
  loop
    v_szerep := btrim(v_szerep);
    continue when v_szerep = '';

    -- Elsőként a szervezeti lánc mentén, alulról felfelé.
    if v_ancest is not null then
      foreach v_o in array v_ancest
      loop
        return query
          select rg.person, rg.role, rg.scope_org
            from echo.role_grant rg
           where rg.role = v_szerep
             and rg.scope_org = v_o
             and (rg.expires_at is null or rg.expires_at > now())
           limit 1;
        if found then return; end if;
      end loop;
    end if;

    -- Végül az egyetem-szintű (scope_org is null) viselő.
    return query
      select rg.person, rg.role, null::uuid
        from echo.role_grant rg
       where rg.role = v_szerep
         and rg.scope_org is null
         and (rg.expires_at is null or rg.expires_at > now())
       limit 1;
    if found then return; end if;
  end loop;

  return;
end $$;

-- ---------------------------------------------------------------------------
-- 5) Meddig lehet észrevételt tenni?
--    NULL határidő = még nem volt átvétel, tehát az óra el sem indult.
-- ---------------------------------------------------------------------------
create or replace function echo.comment_deadline(p_campaign uuid, p_teacher uuid)
returns timestamptz
language sql
stable
as $$
  select h.handed_at
       + make_interval(days => echo.k_text_setting('comment_window_days','7')::integer)
    from echo.protocol_handover h
   where h.campaign_id = p_campaign and h.teacher_id = p_teacher
$$;

commit;

begin;

-- ---------------------------------------------------------------------------
-- 6) Az átvétel rögzítése — ez INDÍTJA a 7 napot
-- ---------------------------------------------------------------------------
create or replace function public.echo_protocol_handover(
  p_campaign uuid,
  p_teacher  uuid,
  p_method   text default 'rendszer',
  p_note     text default null)
returns jsonb
language plpgsql security definer set search_path = public, echo
as $$
declare v_row echo.protocol_handover;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then
    raise exception 'ECHO_FORBIDDEN: az atvetel tenyet csak admin rogzitheti.';
  end if;

  insert into echo.protocol_handover(campaign_id, teacher_id, handed_by, method, note)
  values (p_campaign, p_teacher, auth.uid(), coalesce(p_method,'rendszer'), p_note)
  on conflict (campaign_id, teacher_id) do update
    set method = excluded.method,
        note   = coalesce(excluded.note, echo.protocol_handover.note)
  returning * into v_row;

  return jsonb_build_object(
    'campaign_id', v_row.campaign_id, 'teacher_id', v_row.teacher_id,
    'atvette', v_row.handed_at, 'mod', v_row.method,
    'hatarido', echo.comment_deadline(p_campaign, p_teacher));
end $$;

-- ---------------------------------------------------------------------------
-- 7) Az oktató saját észrevételi ablaka
-- ---------------------------------------------------------------------------
create or replace function public.echo_my_comment_window(p_campaign uuid)
returns jsonb
language plpgsql security definer set search_path = public, echo
as $$
declare
  v_me   uuid;
  v_hand timestamptz;
  v_dead timestamptz;
  v_c    integer;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  v_me := echo.my_teacher_id();
  if v_me is null then
    raise exception 'ECHO_FORBIDDEN: a fiok nincs oktatoi sorhoz kotve.';
  end if;

  select h.handed_at into v_hand
    from echo.protocol_handover h
   where h.campaign_id = p_campaign and h.teacher_id = v_me;

  v_dead := echo.comment_deadline(p_campaign, v_me);

  select count(*) into v_c
    from echo.teacher_comment tc
   where tc.campaign_id = p_campaign and tc.teacher_id = v_me
     and tc.state <> 'withdrawn';

  return jsonb_build_object(
    'atvette',        v_hand,
    'hatarido',       v_dead,
    -- Ha nem volt átvétel, az óra el sem indult: nyitva sincs, lejárva sincs.
    'nyitva',         (v_hand is not null and now() <= v_dead),
    'lejart',         (v_hand is not null and now() > v_dead),
    'nap',            echo.k_text_setting('comment_window_days','7')::integer,
    'hatralevo_orak', case when v_hand is null then null
                           else greatest(0, ceil(extract(epoch from (v_dead - now())) / 3600)) end,
    'eddigi_eszrevetel', v_c);
end $$;

-- ---------------------------------------------------------------------------
-- 8) Észrevétel beadása
--    A határidőn TÚLI beadást NEM utasítjuk el — csak megjelöljük. Egy
--    elutasított észrevétel nyomtalanul eltűnne; egy megjelölt viszont
--    ott marad, és a címzett dönt róla.
-- ---------------------------------------------------------------------------
create or replace function public.echo_teacher_comment_submit(
  p_campaign uuid,
  p_body     text)
returns jsonb
language plpgsql security definer set search_path = public, echo
as $$
declare
  v_me   uuid;
  v_dead timestamptz;
  v_rec  record;
  v_row  echo.teacher_comment;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;

  v_me := echo.my_teacher_id();
  if v_me is null then
    raise exception 'ECHO_FORBIDDEN: a fiok nincs oktatoi sorhoz kotve.';
  end if;
  if nullif(btrim(coalesce(p_body,'')), '') is null then
    raise exception 'ECHO_EMPTY_BODY: az eszrevetel nem lehet ures.';
  end if;

  if not exists (select 1 from echo.protocol_handover h
                  where h.campaign_id = p_campaign and h.teacher_id = v_me) then
    raise exception
      'ECHO_NO_HANDOVER: eszrevetelt csak a jegyzokonyv atvetele utan lehet tenni. '
      'Az atvetel meg nincs rogzitve.';
  end if;

  v_dead := echo.comment_deadline(p_campaign, v_me);
  select * into v_rec from echo.comment_recipient(v_me) limit 1;

  insert into echo.teacher_comment(
    campaign_id, teacher_id, body, recipient, recipient_role, recipient_org,
    deadline_at, late)
  values (p_campaign, v_me, btrim(p_body),
          v_rec.person, v_rec.role, v_rec.org,
          v_dead, (v_dead is not null and now() > v_dead))
  returning * into v_row;

  return jsonb_build_object(
    'id', v_row.id, 'beadva', v_row.submitted_at,
    'hatarido', v_row.deadline_at, 'kesett', v_row.late,
    'cimzett_szerep', v_row.recipient_role,
    'cimzett_van', (v_row.recipient is not null));
end $$;

commit;

begin;

-- ---------------------------------------------------------------------------
-- 9) Észrevételek listája
--    Három nézőpont, egy függvényben:
--      - az oktató a SAJÁTJAIT látja,
--      - a címzett a NEKI szólókat,
--      - az admin mindent.
--    Aki egyik sem, az üres listát kap — nem hibát: a puszta hibaüzenet is
--    elárulná, hogy van mit nem látnia.
-- ---------------------------------------------------------------------------
create or replace function public.echo_teacher_comments(p_campaign uuid default null)
returns table (
  id uuid, campaign_id uuid, teacher_id uuid, teacher_name text,
  body text, recipient_role text, state text,
  submitted_at timestamptz, deadline_at timestamptz, late boolean,
  ack_at timestamptz, ack_note text, sajat boolean, nekem boolean)
language plpgsql security definer set search_path = public, echo
as $$
declare
  v_me    uuid := auth.uid();
  v_mine  uuid;
  v_admin boolean;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  v_mine  := echo.my_teacher_id();
  v_admin := public.is_admin();

  return query
    select tc.id, tc.campaign_id, tc.teacher_id, t.name,
           tc.body, tc.recipient_role, tc.state,
           tc.submitted_at, tc.deadline_at, tc.late,
           tc.ack_at, tc.ack_note,
           (tc.teacher_id = v_mine) as sajat,
           (tc.recipient = v_me)    as nekem
      from echo.teacher_comment tc
      join echo.teacher t on t.id = tc.teacher_id
     where (p_campaign is null or tc.campaign_id = p_campaign)
       and tc.state <> 'withdrawn'
       and (v_admin
            or (v_mine is not null and tc.teacher_id = v_mine)
            or tc.recipient = v_me)
     order by tc.submitted_at desc
     limit 500;
end $$;

-- ---------------------------------------------------------------------------
-- 10) Nyugtázás — a címzett vagy az admin
-- ---------------------------------------------------------------------------
create or replace function public.echo_comment_acknowledge(
  p_comment uuid,
  p_note    text default null)
returns jsonb
language plpgsql security definer set search_path = public, echo
as $$
declare
  v_me  uuid := auth.uid();
  v_row echo.teacher_comment;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;

  select * into v_row from echo.teacher_comment where id = p_comment;
  if v_row.id is null then raise exception 'ECHO_NOT_FOUND'; end if;

  if not public.is_admin() and v_row.recipient is distinct from v_me then
    raise exception 'ECHO_FORBIDDEN: ezt az eszrevetelt nem neked cimeztek.';
  end if;

  update echo.teacher_comment
     set state = 'acknowledged', ack_by = v_me, ack_at = now(), ack_note = p_note
   where id = p_comment
  returning * into v_row;

  return jsonb_build_object('id', v_row.id, 'nyugtazva', v_row.ack_at);
end $$;

-- ---------------------------------------------------------------------------
-- 11) Jogosultságok — anon SEHOL
-- ---------------------------------------------------------------------------
revoke all on function public.echo_protocol_handover(uuid, uuid, text, text)  from public, anon;
revoke all on function public.echo_my_comment_window(uuid)                     from public, anon;
revoke all on function public.echo_teacher_comment_submit(uuid, text)          from public, anon;
revoke all on function public.echo_teacher_comments(uuid)                      from public, anon;
revoke all on function public.echo_comment_acknowledge(uuid, text)             from public, anon;

grant execute on function public.echo_protocol_handover(uuid, uuid, text, text) to authenticated;
grant execute on function public.echo_my_comment_window(uuid)                    to authenticated;
grant execute on function public.echo_teacher_comment_submit(uuid, text)         to authenticated;
grant execute on function public.echo_teacher_comments(uuid)                     to authenticated;
grant execute on function public.echo_comment_acknowledge(uuid, text)            to authenticated;

-- ---------------------------------------------------------------------------
-- 12) Visszavonás
-- ---------------------------------------------------------------------------
create or replace function public.echo_comment_rollback()
returns text language plpgsql security definer set search_path = public, echo
as $$
begin
  if not public.is_superadmin() then
    raise exception 'Csak szuperadmin vonhatja vissza.' using errcode = '42501';
  end if;
  drop function if exists public.echo_protocol_handover(uuid, uuid, text, text);
  drop function if exists public.echo_my_comment_window(uuid);
  drop function if exists public.echo_teacher_comment_submit(uuid, text);
  drop function if exists public.echo_teacher_comments(uuid);
  drop function if exists public.echo_comment_acknowledge(uuid, text);
  drop function if exists echo.comment_recipient(uuid);
  drop function if exists echo.comment_deadline(uuid, uuid);
  -- A beadott észrevételeket és az átvételi eseményeket SZÁNDÉKOSAN nem
  -- töröljük: mindkettő jogilag számít, nem a modul tartozéka.
  return 'A 35-os visszavonva. Az eszrevetelek es az atveteli esemenyek megmaradtak.';
end $$;

revoke all on function public.echo_comment_rollback() from public, anon;
grant execute on function public.echo_comment_rollback() to authenticated;

commit;


-- ===========================================================================
-- >>> 36_echo_question_bank.sql
-- ===========================================================================
-- ============================================================================
-- 36_echo_question_bank.sql — ECHO: központi kérdésbank  (III/2)
-- ----------------------------------------------------------------------------
-- MIÉRT
--   Ma minden sablonváltozat a SAJÁT kérdéseit tartalmazza a compiled JSON-ban.
--   Ez működik, de két dolgot nem enged meg:
--     - ugyanazt a kérdést nem lehet több sablonban újrahasználni úgy, hogy
--       tudjuk, ugyanarról van szó (így trend és összehasonlítás sem épül);
--     - egy elírás javítása minden sablonban külön munka.
--
--   A kérdésbank ezt oldja: a kérdéstételek egy helyen élnek, a sablonok
--   pedig HIVATKOZNAK rájuk.
--
-- AMIT SZÁNDÉKOSAN NEM CSINÁLUNK
--   A meglévő sablonokat NEM írjuk át. A compiled JSON marad a mérvadó a
--   már kiadott kampányoknál — egy lezárt kampány kérdései nem változhatnak
--   utólag azzal, hogy valaki a bankban javít egy szót. A bank a SZERKESZTÉST
--   segíti; a kiadott sablon önhordó marad.
--
-- IDEMPOTENS. Visszavonás: select public.echo_question_bank_rollback();
-- ============================================================================

begin;

create table if not exists echo.question_bank (
  id          uuid primary key default gen_random_uuid(),
  code        text not null,
  type        text not null,
  hu          text not null,
  en          text,
  options     jsonb,
  min_value   integer,
  max_value   integer,
  required    boolean not null default false,
  tags        text[] not null default '{}',
  state       text not null default 'draft',
  notes       text,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint question_bank_code_uniq unique (code),
  constraint question_bank_type_ck check (
    type in ('scale','single','multi','text','longtext','bool')),
  constraint question_bank_state_ck check (
    state in ('draft','active','retired')),
  constraint question_bank_code_shape_ck check (
    code ~ '^[A-Za-z0-9_.-]{2,64}$'),
  -- A választós típusoknak kell opciólista; a skálának tartomány.
  constraint question_bank_options_ck check (
    type not in ('single','multi')
    or (options is not null and jsonb_typeof(options) = 'array'
        and jsonb_array_length(options) >= 2)),
  constraint question_bank_scale_ck check (
    type <> 'scale'
    or (min_value is not null and max_value is not null and min_value < max_value))
);

create index if not exists question_bank_state_idx on echo.question_bank (state, code);
create index if not exists question_bank_tags_idx  on echo.question_bank using gin (tags);

comment on table echo.question_bank is
  'Újrahasználható kérdéstételek. A KIADOTT sablonok compiled JSON-ja '
  'önhordó marad — a bankban végzett javítás visszamenőleg nem írja át egy '
  'lezárt kampány kérdéseit.';

create or replace function echo.question_bank_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists question_bank_touch_trg on echo.question_bank;
create trigger question_bank_touch_trg
  before update on echo.question_bank
  for each row execute function echo.question_bank_touch();

commit;

begin;

-- ---------------------------------------------------------------------------
-- Listázás — a szerkesztők látják, a többiek nem
-- ---------------------------------------------------------------------------
create or replace function public.echo_question_bank(
  p_state text default null,
  p_tag   text default null)
returns setof echo.question_bank
language plpgsql security definer set search_path = public, echo
as $$
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then
    raise exception 'ECHO_FORBIDDEN: a kerdesbankot csak admin szerkesztheti.';
  end if;
  return query
    select * from echo.question_bank
     where (p_state is null or state = p_state)
       and (p_tag   is null or tags @> array[p_tag])
     order by state, code
     limit 1000;
end $$;

-- ---------------------------------------------------------------------------
-- Mentés (új vagy meglévő)
-- ---------------------------------------------------------------------------
create or replace function public.echo_question_bank_save(
  p_id       uuid    default null,
  p_code     text    default null,
  p_type     text    default null,
  p_hu       text    default null,
  p_en       text    default null,
  p_options  jsonb   default null,
  p_min      integer default null,
  p_max      integer default null,
  p_required boolean default false,
  p_tags     text[]  default '{}',
  p_notes    text    default null)
returns echo.question_bank
language plpgsql security definer set search_path = public, echo
as $$
declare v_row echo.question_bank;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then
    raise exception 'ECHO_FORBIDDEN: a kerdesbankot csak admin szerkesztheti.';
  end if;

  if p_id is null then
    insert into echo.question_bank(
      code, type, hu, en, options, min_value, max_value, required, tags, notes, created_by)
    values (p_code, p_type, p_hu, p_en, p_options, p_min, p_max,
            coalesce(p_required,false), coalesce(p_tags,'{}'), p_notes, auth.uid())
    returning * into v_row;
  else
    -- A KIADOTT (active) tétel kódját nem engedjük átírni: arra már
    -- hivatkozhatnak sablonok, és a hivatkozás a kód mentén él.
    if exists (select 1 from echo.question_bank
                where id = p_id and state = 'active'
                  and p_code is not null and p_code <> code) then
      raise exception
        'ECHO_CODE_LOCKED: aktiv kerdes kodja nem irhato at, mert sablonok '
        'hivatkozhatnak ra. Vondd vissza (retired), es hozz letre ujat.';
    end if;

    update echo.question_bank
       set code      = coalesce(p_code, code),
           type      = coalesce(p_type, type),
           hu        = coalesce(p_hu, hu),
           en        = coalesce(p_en, en),
           options   = coalesce(p_options, options),
           min_value = coalesce(p_min, min_value),
           max_value = coalesce(p_max, max_value),
           required  = coalesce(p_required, required),
           tags      = coalesce(p_tags, tags),
           notes     = coalesce(p_notes, notes)
     where id = p_id
    returning * into v_row;

    if v_row.id is null then raise exception 'ECHO_NOT_FOUND'; end if;
  end if;

  return v_row;
end $$;

-- ---------------------------------------------------------------------------
-- Állapotváltás — a törlés helyett VISSZAVONÁS
--   Egy kérdést, amire kampányok hivatkoznak, nem szabad kitörölni: a
--   hivatkozás elszakadna. A retired tétel nem ajánlható fel újként, de a
--   régi sablonokban továbbra is értelmezhető marad.
-- ---------------------------------------------------------------------------
create or replace function public.echo_question_bank_state(p_id uuid, p_state text)
returns echo.question_bank
language plpgsql security definer set search_path = public, echo
as $$
declare v_row echo.question_bank;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then
    raise exception 'ECHO_FORBIDDEN: a kerdesbankot csak admin szerkesztheti.';
  end if;
  if p_state not in ('draft','active','retired') then
    raise exception 'ECHO_BAD_STATE: "%"', p_state;
  end if;
  update echo.question_bank set state = p_state where id = p_id returning * into v_row;
  if v_row.id is null then raise exception 'ECHO_NOT_FOUND'; end if;
  return v_row;
end $$;

-- ---------------------------------------------------------------------------
-- Sablon-kérdés alakra hozás — a szerkesztő ezt fűzi a compiled JSON-ba
-- ---------------------------------------------------------------------------
create or replace function public.echo_question_bank_as_item(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, echo
as $$
declare v_row echo.question_bank;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then
    raise exception 'ECHO_FORBIDDEN: a kerdesbankot csak admin hasznalhatja.';
  end if;
  select * into v_row from echo.question_bank where id = p_id;
  if v_row.id is null then raise exception 'ECHO_NOT_FOUND'; end if;
  if v_row.state = 'retired' then
    raise exception 'ECHO_RETIRED: visszavont kerdes nem tehető uj sablonba.';
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'id',       v_row.code,
    'type',     v_row.type,
    'hu',       v_row.hu,
    'en',       v_row.en,
    'options',  v_row.options,
    'min',      v_row.min_value,
    'max',      v_row.max_value,
    'required', v_row.required,
    'bank_id',  v_row.id));
end $$;

revoke all on function public.echo_question_bank(text, text)                        from public, anon;
revoke all on function public.echo_question_bank_save(uuid, text, text, text, text, jsonb, integer, integer, boolean, text[], text)
  from public, anon;
revoke all on function public.echo_question_bank_state(uuid, text)                  from public, anon;
revoke all on function public.echo_question_bank_as_item(uuid)                      from public, anon;
grant execute on function public.echo_question_bank(text, text)                     to authenticated;
grant execute on function public.echo_question_bank_save(uuid, text, text, text, text, jsonb, integer, integer, boolean, text[], text)
  to authenticated;
grant execute on function public.echo_question_bank_state(uuid, text)               to authenticated;
grant execute on function public.echo_question_bank_as_item(uuid)                   to authenticated;

create or replace function public.echo_question_bank_rollback()
returns text language plpgsql security definer set search_path = public, echo
as $$
begin
  if not public.is_superadmin() then
    raise exception 'Csak szuperadmin vonhatja vissza.' using errcode = '42501';
  end if;
  drop function if exists public.echo_question_bank(text, text);
  drop function if exists public.echo_question_bank_save(uuid, text, text, text, text, jsonb, integer, integer, boolean, text[], text);
  drop function if exists public.echo_question_bank_state(uuid, text);
  drop function if exists public.echo_question_bank_as_item(uuid);
  drop table if exists echo.question_bank cascade;
  return 'A 36-os kerdesbank visszavonva. A sablonok compiled JSON-ja erintetlen.';
end $$;

revoke all on function public.echo_question_bank_rollback() from public, anon;
grant execute on function public.echo_question_bank_rollback() to authenticated;

commit;


-- ===========================================================================
-- >>> 21_echo_harden_submit.sql
-- ===========================================================================
-- ============================================================
-- UniPortal Pro — ECHO: az anonim beküldés jogosultságának lezárása
-- ------------------------------------------------------------
-- MIÉRT KELL:
--   Az ECHO anonimitásának egyik tartóoszlopa, hogy a beküldés NEM a hallgató
--   munkamenetével fut: az echo_submit() kizárólag 'anon' joggal hívható, így
--   egy JWT-t hordozó kérés jogosultsági hibával elhasal, és a hallgató
--   azonosítója nem kerül a tranzakciós naplóba és a platform edge-logjába.
--
--   A 15_echo_core.sql ezt CSAK azzal éri el, hogy megadja a jogot az anon-nak
--   (1712. sor) — de SOHA NEM VONJA VISSZA az authenticated-tól. A Supabase
--   alapértelmezett jogosztása (alter default privileges … grant execute on
--   functions to anon, authenticated, service_role) viszont MINDEN új publikus
--   függvényre ad authenticated végrehajtási jogot. Ha ez a projekten él, akkor
--   az echo_submit bejelentkezve is hívható, és a garancia csendben elveszik.
--
--   MÉRVE: egy tiszta adatbázison, ahol a migrációk UTÁN lefutott egy tömeges
--   'grant all on all functions in schema public to anon, authenticated' —
--   ami pontosan azt utánozza, amit a platform tesz —, az echo_submit
--   jogosultsága 'anon=X authenticated=X service_role=X' lett.
--
-- MIT CSINÁL:
--   Visszavonja a végrehajtási jogot mindenkitől, majd kizárólag az anon-nak adja
--   vissza. Beállítja az alapértelmezett jogosztást is, hogy egy jövőbeli
--   platform-művelet ne nyissa vissza. A végén ellenőriz.
--
-- FUTTATÁSI SORREND: ez az UTOLSÓ migráció. Minden alkalommal futtasd újra,
-- amikor bármilyen új ECHO-migráció felment.
--
-- Idempotens — biztonságosan újrafuttatható, és futtatandó MINDEN olyan
-- alkalommal, amikor új ECHO-migráció ment fel.
-- ============================================================

-- ---------- 1. a beküldő függvény lezárása ----------
do $$
declare fn text;
begin
  for fn in
    select p.oid::regprocedure::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'echo_submit'
  loop
    execute format('revoke all on function %s from public, authenticated, service_role', fn);
    execute format('grant execute on function %s to anon', fn);
    raise notice 'Lezarva es anon-ra szukitve: %', fn;
  end loop;
end $$;

-- ---------- 2. a jegykiadó marad authenticated ----------
-- Ez SZÁNDÉKOSAN azonosított: itt még nincs válasz, tehát nincs mit korrelálni.
do $$
declare fn text;
begin
  for fn in
    select p.oid::regprocedure::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'echo_issue_ticket'
  loop
    execute format('revoke all on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end $$;

-- ---------- 3. ellenőrzés ----------
with a as (
  select p.proname,
         coalesce(array_to_string(p.proacl, ' '), '(alapertelmezett)') as acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('echo_submit', 'echo_issue_ticket')
)
select proname as fuggveny, acl,
       case
         when proname = 'echo_submit'
           then case when acl like '%anon=X%' and acl not like '%authenticated=X%'
                     then 'OK — csak anon' else '*** BAJ: bejelentkezve is hivhato ***' end
         when proname = 'echo_issue_ticket'
           then case when acl like '%authenticated=X%' and acl not like '%anon=X%'
                     then 'OK — csak authenticated' else '*** BAJ ***' end
       end as allapot
from a order by proname;


-- ===========================================================================
-- >>> ELLENŐRZÉS — ez az utolsó eredmény, ezt fogod látni
-- ===========================================================================
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
