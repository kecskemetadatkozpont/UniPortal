-- ============================================================================
--  52_dorm_inventory.sql — UniPortal / kollégium
--  ÉPÜLET → SZINT → SZOBA → FÉRŐHELY: a törzsadat karbantarthatóvá tétele
-- ============================================================================
--
--  HOL TARTOTTUNK
--  A felület MA egyetlen kollégiumi törzsadat-táblába tud írni: dorm.building
--  (felvitel + szerkesztés). A szint, a szoba és a férőhely CSAK OLVASHATÓ —
--  pedig az RLS mindhármat engedi a GONDNOK / KOLI_ADMIN / KOLI_SYSADMIN
--  körnek. Vagyis az "Új épület" gomb ma olyan rekordot hoz létre, amit a
--  felület soha nem tud használhatóvá tenni: nincs benne szint, nincs benne
--  szoba, nincs benne ágy.
--
--  MI HIÁNYZOTT A SZERVEROLDALON
--  Egyetlen dolog: a dorm.room.full_code és a dorm.bed.full_code KÖTELEZŐ, de
--  nincs alapértéke. A kliensnek kellene összeraknia — ami azt jelentené, hogy
--  a kódképzés szabálya a felületen élne, és két helyen (szoba, ágy) is el
--  tudna csúszni attól, amit a meglévő adat használ. Ezt a szabályt az
--  adatbázisba tesszük, ahol egy helyen van.
--
--  A KÓDKÉPZÉS a MEGLÉVŐ adatból van visszafejtve, nem kitalálva:
--      szoba:  <épület kódja>/<szint száma>/<ajtószám>     pl. KOLL-A/1/102
--      ágy:    <szoba teljes kódja>-<ágy jele>              pl. KOLL-A/1/102-A
--
--  MIT AD MÉG: két RPC a tömeges felvitelhez. Egy 72 férőhelyes kollégiumot
--  szobánként egyesével felvinni nem munka, hanem büntetés.
--
--  ELŐFELTÉTEL: a 26_dorm.sql lefutott. Idempotens.
-- ============================================================================


-- ------------------------------------------------------------
-- 1. A teljes kód automatikus képzése
-- ------------------------------------------------------------
create or replace function dorm.room_code_fill()
returns trigger language plpgsql
set search_path = dorm, public, pg_temp
as $$
declare v_b text; v_l int;
begin
  if new.full_code is not null and btrim(new.full_code) <> '' then
    return new;                      -- amit a hivo megadott, azt tiszteljuk
  end if;
  select b.code into v_b from dorm.building b where b.id = new.building_id;
  select f.level_no into v_l from dorm.floor f where f.id = new.floor_id;
  new.full_code := coalesce(v_b, '?') || '/' || coalesce(v_l::text, '?')
                   || '/' || coalesce(nullif(btrim(new.door_number), ''), '?');
  return new;
end $$;

drop trigger if exists dorm_room_code_fill_trg on dorm.room;
create trigger dorm_room_code_fill_trg
  before insert or update of building_id, floor_id, door_number, full_code on dorm.room
  for each row execute function dorm.room_code_fill();


create or replace function dorm.bed_code_fill()
returns trigger language plpgsql
set search_path = dorm, public, pg_temp
as $$
declare v_r text;
begin
  if new.full_code is not null and btrim(new.full_code) <> '' then
    return new;
  end if;
  select r.full_code into v_r from dorm.room r where r.id = new.room_id;
  new.full_code := coalesce(v_r, '?') || '-'
                   || coalesce(nullif(btrim(new.bed_label), ''), '?');
  return new;
end $$;

drop trigger if exists dorm_bed_code_fill_trg on dorm.bed;
create trigger dorm_bed_code_fill_trg
  before insert or update of room_id, bed_label, full_code on dorm.bed
  for each row execute function dorm.bed_code_fill();


-- ------------------------------------------------------------
-- 2. Írási jog egy helyen
-- ------------------------------------------------------------
-- Ugyanaz a kör, amit a dorm_room_write / dorm_bed_write / dorm_floor_write
-- RLS-policy is enged. Azért külön függvény, hogy az RPC-k ne ismételjék.
create or replace function dorm.can_edit_inventory(p_building uuid default null)
returns boolean language sql stable
set search_path = dorm, public, pg_temp
as $$
  select public.is_admin()
      or dorm.has_any_role(array['GONDNOK','KOLI_ADMIN','KOLI_SYSADMIN'], p_building)
$$;


-- ------------------------------------------------------------
-- 3. Tömeges szobafelvitel egy szintre
-- ------------------------------------------------------------
-- Egy 72 férőhelyes kollégiumot egyesével felvinni nem munka, hanem büntetés.
-- A függvény ÁTUGORJA a már létező ajtószámokat (nem hibázik, nem duplikál),
-- és visszaadja, mit csinált — így kétszer lefuttatva sem keletkezik kár.
create or replace function public.dorm_rooms_generate(
  p_floor      uuid,
  p_count      int,
  p_first_door int    default 1,
  p_room_type  text   default 'DOUBLE',
  p_capacity   int    default null,   -- null = a típusból következő ágyszám
  p_purpose    text   default 'RESIDENTIAL',
  p_with_beds  boolean default true,
  p_prefix     text   default null    -- pl. '2' -> 201, 202 … (null: sima sorszám)
) returns jsonb
language plpgsql volatile security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare
  f          dorm.floor%rowtype;
  v_cap      int;
  v_ajto     text;
  v_room     uuid;
  v_letre    int := 0;
  v_kihagy   int := 0;
  v_agy      int := 0;
  i          int;
  j          int;
  v_betuk    text[] := array['A','B','C','D','E','F','G','H'];
begin
  if auth.uid() is null then raise exception 'DORM_NOT_AUTHENTICATED'; end if;
  select * into f from dorm.floor where id = p_floor;
  if not found then raise exception 'DORM_FLOOR_UNKNOWN: nincs ilyen szint.'; end if;
  if not dorm.can_edit_inventory(f.building_id) then
    raise exception 'DORM_FORBIDDEN: szobafelvitelhez GONDNOK (sajat epulet), KOLI_ADMIN '
                    'vagy KOLI_SYSADMIN jogosultsag kell.';
  end if;
  if coalesce(p_count, 0) < 1 or p_count > 200 then
    raise exception 'DORM_BAD_COUNT: egyszerre 1 es 200 kozott lehet szobat felvinni (kapott: %).', p_count;
  end if;

  -- A ferohelyszam a tipusbol kovetkezik, ha a hivo nem mond mast. Ez csak
  -- ALAPERTELMEZES: a szoba capacity mezoje utolag szabadon atirhato.
  v_cap := coalesce(p_capacity, case p_room_type
             when 'SINGLE' then 1 when 'DOUBLE' then 2 when 'TRIPLE' then 3
             when 'QUAD' then 4 when 'STUDIO' then 1 when 'DORMITORY' then 6
             else 0 end);

  for i in 0 .. (p_count - 1) loop
    v_ajto := coalesce(nullif(btrim(coalesce(p_prefix, '')), ''), '')
              || lpad((p_first_door + i)::text,
                      case when coalesce(nullif(btrim(coalesce(p_prefix,'')),''),'') <> '' then 2 else 1 end,
                      '0');

    -- Mar letezo ajtoszamot NEM irunk felul: a ketszeri futtatas ne duplikaljon.
    if exists (select 1 from dorm.room r
                where r.building_id = f.building_id and r.door_number = v_ajto) then
      v_kihagy := v_kihagy + 1;
      continue;
    end if;

    insert into dorm.room (building_id, floor_id, door_number, room_type, purpose, capacity)
    values (f.building_id, f.id, v_ajto, p_room_type, p_purpose, greatest(v_cap, 0))
    returning id into v_room;
    v_letre := v_letre + 1;

    if coalesce(p_with_beds, true) and v_cap > 0 and p_purpose = 'RESIDENTIAL' then
      for j in 1 .. least(v_cap, array_length(v_betuk, 1)) loop
        insert into dorm.bed (building_id, room_id, bed_label)
        values (f.building_id, v_room, v_betuk[j]);
        v_agy := v_agy + 1;
      end loop;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true, 'letrehozott_szoba', v_letre, 'kihagyott_letezo', v_kihagy,
    'letrehozott_ferohely', v_agy, 'szint', f.level_no, 'epulet', f.building_id);
end $$;


-- ------------------------------------------------------------
-- 4. Egy szoba férőhelyeinek beállítása
-- ------------------------------------------------------------
-- FOGLALT FÉRŐHELYET SOHA NEM TÖRÖL. Ha a kért szám kisebb, mint amennyi
-- foglalt, annyit hagy meg, amennyi foglalt, és ezt vissza is mondja — nem
-- hallgat, és nem törli ki valaki ágyát a lába alól.
create or replace function public.dorm_room_beds_set(p_room uuid, p_count int)
returns jsonb
language plpgsql volatile security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare
  r        dorm.room%rowtype;
  v_van    int;
  v_foglalt int;
  v_betuk  text[] := array['A','B','C','D','E','F','G','H'];
  v_uj     int := 0;
  v_torolt int := 0;
  b        record;
begin
  if auth.uid() is null then raise exception 'DORM_NOT_AUTHENTICATED'; end if;
  select * into r from dorm.room where id = p_room;
  if not found then raise exception 'DORM_ROOM_UNKNOWN: nincs ilyen szoba.'; end if;
  if not dorm.can_edit_inventory(r.building_id) then
    raise exception 'DORM_FORBIDDEN: ferohely-szerkesztes GONDNOK / KOLI_ADMIN / KOLI_SYSADMIN joggal.';
  end if;
  if coalesce(p_count, -1) < 0 or p_count > 8 then
    raise exception 'DORM_BAD_COUNT: egy szobaban 0 es 8 kozott lehet ferohely (kapott: %).', p_count;
  end if;

  select count(*) into v_van from dorm.bed where room_id = p_room;
  select count(distinct o.bed_id) into v_foglalt
    from dorm.occupancy o join dorm.bed d on d.id = o.bed_id
   where d.room_id = p_room and o.state <> 'CANCELLED';

  -- bovites
  while v_van < p_count and v_van < array_length(v_betuk, 1) loop
    insert into dorm.bed (building_id, room_id, bed_label)
    values (r.building_id, p_room, v_betuk[v_van + 1]);
    v_van := v_van + 1; v_uj := v_uj + 1;
  end loop;

  -- szukites: CSAK olyan agyat, amihez SOHA nem tartozott elhelyezes
  for b in
    select d.id, d.bed_label from dorm.bed d
     where d.room_id = p_room
       and not exists (select 1 from dorm.occupancy o where o.bed_id = d.id)
     order by d.bed_label desc
  loop
    exit when v_van <= p_count;
    delete from dorm.bed where id = b.id;
    v_van := v_van - 1; v_torolt := v_torolt + 1;
  end loop;

  update dorm.room set capacity = v_van where id = p_room;

  return jsonb_build_object(
    'ok', true, 'ferohely', v_van, 'letrehozott', v_uj, 'torolt', v_torolt,
    'erintetlen_mert_hasznalt', greatest(v_van - p_count, 0),
    'uzenet', case when v_van > p_count
                   then 'Nem torolheto minden ferohely: ' || (v_van - p_count)
                        || ' olyan agy maradt, amihez tartozik vagy tartozott elhelyezes.'
                   else null end);
end $$;


do $jog$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('dorm_rooms_generate','dorm_room_beds_set')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon',   f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end
$jog$;

notify pgrst, 'reload schema';


-- ============================================================================
--  ELLENŐRZÉS — futtasd le, és küldd vissza a táblát
-- ============================================================================
select 'a szoba teljes kodja magatol keletkezik' as mit_ellenorzunk,
       coalesce((select tgname from pg_trigger where tgname='dorm_room_code_fill_trg'), '(nincs)') as ertek,
       case when exists (select 1 from pg_trigger where tgname='dorm_room_code_fill_trg')
            then 'OK' else 'HIBA' end as allapot
union all
select 'a ferohely teljes kodja is',
       coalesce((select tgname from pg_trigger where tgname='dorm_bed_code_fill_trg'), '(nincs)'),
       case when exists (select 1 from pg_trigger where tgname='dorm_bed_code_fill_trg')
            then 'OK' else 'HIBA' end
union all
select 'RPC: '||p.proname,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon is' else 'csak authenticated' end,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE') then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('dorm_rooms_generate','dorm_room_beds_set')
union all
select 'foglalt ferohelyet nem torol',
       case when prosrc like '%not exists (select 1 from dorm.occupancy%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%not exists (select 1 from dorm.occupancy%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='dorm_room_beds_set'
union all
select 'a torzsadat ma (epulet / szint / szoba / ferohely)',
       (select count(*) from dorm.building)||' / '||(select count(*) from dorm.floor)||' / '||
       (select count(*) from dorm.room)||' / '||(select count(*) from dorm.bed),
       'INFO';
