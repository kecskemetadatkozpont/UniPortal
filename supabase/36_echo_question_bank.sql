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
