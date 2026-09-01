-- ============================================================================
--  53_dorm_status.sql — UniPortal / kollégium
--  SZOBA- ÉS FÉRŐHELY-ÁLLAPOT VÁLTÁSA, INDOKLÁSSAL
-- ============================================================================
--
--  MI VOLT KÉSZEN, ÉS MI HIÁNYZOTT
--  Az állapotgép teljes: nyolc szobaállapot, 24 megengedett átmenet
--  (dorm.room_status_transition), őr trigger, ami a tiltott lépést elutasítja
--  ÉS magától naplóz. Az ágynál öt állapot van, átmeneti korlát nélkül — ott
--  is naplóz a trigger. Felület viszont EGYIKHEZ SEM volt: a szoba és a
--  férőhely állapotát a képernyőről nem lehetett megváltoztatni.
--
--  EGY DOLOG HIÁNYZOTT A SZERVEROLDALON IS: az INDOKLÁS. Mindkét
--  előzménytáblának van 'reason' oszlopa, de a trigger NULL-t hagy benne —
--  egy sima UPDATE-tel tehát nincs mód rögzíteni, MIÉRT került a szoba
--  felújítás alá. Márpedig fél év múlva pont ez a kérdés.
--
--  A MEGOLDÁS: két RPC, ami az állapotot állítja, majd az imént keletkezett
--  előzménysorra ráírja az indoklást. Egy tranzakcióban, tehát vagy mindkettő
--  megvan, vagy egyik sem.
--
--  MIÉRT NEM TRIGGERBŐL: az indoklás a HÍVÓ szándéka, nem a soré. Session-
--  változóval át lehetne adni (set local), de az láthatatlan függés lenne a
--  kliens és a trigger között — RPC-ben ki van mondva.
--
--  ELŐFELTÉTEL: a 26_dorm.sql lefutott. Idempotens.
-- ============================================================================

create or replace function public.dorm_room_status_set(
  p_room uuid, p_to text, p_reason text default null
) returns jsonb
language plpgsql volatile security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare
  r      dorm.room%rowtype;
  v_hist uuid;
  v_lab  text;
begin
  if auth.uid() is null then raise exception 'DORM_NOT_AUTHENTICATED'; end if;
  select * into r from dorm.room where id = p_room;
  if not found then raise exception 'DORM_ROOM_UNKNOWN: nincs ilyen szoba.'; end if;
  if not dorm.can_edit_inventory(r.building_id) then
    raise exception 'DORM_FORBIDDEN: allapotvaltashoz GONDNOK (sajat epulet), KOLI_ADMIN '
                    'vagy KOLI_SYSADMIN jogosultsag kell.';
  end if;
  if r.status = p_to then
    raise exception 'DORM_SAME_STATUS: a szoba mar "%" allapotban van.', p_to;
  end if;
  select label_hu into v_lab from dorm.room_status where code = p_to;
  if v_lab is null then
    raise exception 'DORM_BAD_STATUS: nincs ilyen szobaallapot: "%".', p_to;
  end if;
  -- A megengedett atmenetet az OR TRIGGER is ellenorzi; itt azert nezzuk meg
  -- elore, hogy beszedesebb uzenetet tudjunk adni (mi az, ami INNEN lehetne).
  if not exists (select 1 from dorm.room_status_transition
                  where from_code = r.status and to_code = p_to) then
    raise exception 'DORM_BAD_TRANSITION: "%" allapotbol nem lehet "%"-ra lepni. '
                    'Innen ez lehetseges: %.',
                    r.status, p_to,
                    coalesce((select string_agg(to_code, ', ' order by to_code)
                                from dorm.room_status_transition where from_code = r.status),
                             '(semmi)');
  end if;

  update dorm.room set status = p_to, status_changed_at = now() where id = p_room;

  -- Az elozmenysort az or trigger irta; az indoklas a hivo szandeka, azt
  -- utolag tesszuk ra. Az 'order by changed_at desc limit 1' biztonsagos:
  -- ugyanabban a tranzakcioban vagyunk, mas nem irhatott koze.
  if coalesce(btrim(p_reason), '') <> '' then
    select id into v_hist from dorm.room_status_history
     where room_id = p_room order by changed_at desc, id desc limit 1;
    if v_hist is not null then
      update dorm.room_status_history set reason = btrim(p_reason) where id = v_hist;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'szoba', r.full_code,
    'elozo', r.status, 'uj', p_to, 'megnevezes', v_lab);
end $$;


create or replace function public.dorm_bed_status_set(
  p_bed uuid, p_to text, p_reason text default null
) returns jsonb
language plpgsql volatile security definer
set search_path = dorm, public, extensions, pg_temp
as $$
declare
  b       dorm.bed%rowtype;
  v_hist  uuid;
  v_lab   text;
  v_lakik int;
begin
  if auth.uid() is null then raise exception 'DORM_NOT_AUTHENTICATED'; end if;
  select * into b from dorm.bed where id = p_bed;
  if not found then raise exception 'DORM_BED_UNKNOWN: nincs ilyen ferohely.'; end if;
  if not dorm.can_edit_inventory(b.building_id) then
    raise exception 'DORM_FORBIDDEN: allapotvaltashoz GONDNOK (sajat epulet), KOLI_ADMIN '
                    'vagy KOLI_SYSADMIN jogosultsag kell.';
  end if;
  if b.status = p_to then
    raise exception 'DORM_SAME_STATUS: a ferohely mar "%" allapotban van.', p_to;
  end if;
  select label_hu into v_lab from dorm.bed_status where code = p_to;
  if v_lab is null then
    raise exception 'DORM_BAD_STATUS: nincs ilyen ferohely-allapot: "%".', p_to;
  end if;

  -- Az agynal NINCS atmenettabla (a modul szandekosan nem korlatozza), de EGY
  -- dolgot kimondunk: ELO ELHELYEZES alatt nem vonunk ki agyat a forgalombol.
  -- A kiadhatatlanna tett agyon lako hallgato helyzete kulonben ertelmezhetetlen
  -- lenne: a rendszer szerint nincs is hol laknia.
  if not (select is_lettable from dorm.bed_status where code = p_to) then
    select count(*) into v_lakik from dorm.occupancy o
     where o.bed_id = p_bed and o.state in ('ALLOCATED','MOVED_IN')
       and (upper(o.period) is null or upper(o.period) > current_date);
    if v_lakik > 0 then
      raise exception 'DORM_BED_OCCUPIED: ezen a ferohelyen elo elhelyezes van. '
                      'Eloszor koltoztesd ki vagy helyezd at a kollegistat, utana '
                      'vond ki a ferohelyet.';
    end if;
  end if;

  update dorm.bed set status = p_to where id = p_bed;   -- a trigger allitja a datumot

  if coalesce(btrim(p_reason), '') <> '' then
    select id into v_hist from dorm.bed_status_history
     where bed_id = p_bed order by changed_at desc, id desc limit 1;
    if v_hist is not null then
      update dorm.bed_status_history set reason = btrim(p_reason) where id = v_hist;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'ferohely', b.full_code,
    'elozo', b.status, 'uj', p_to, 'megnevezes', v_lab);
end $$;


do $jog$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname in ('dorm_room_status_set','dorm_bed_status_set')
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
select 'RPC: '||p.proname as mit_ellenorzunk,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon is' else 'csak authenticated' end as ertek,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE') then 'OK' else 'HIBA' end as allapot
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('dorm_room_status_set','dorm_bed_status_set')
union all
select 'a tiltott atmenet beszedes uzenetet ad',
       case when prosrc like '%DORM_BAD_TRANSITION%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%DORM_BAD_TRANSITION%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='dorm_room_status_set'
union all
select 'elo elhelyezes alatt nem vonhato ki ferohely',
       case when prosrc like '%DORM_BED_OCCUPIED%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%DORM_BED_OCCUPIED%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='dorm_bed_status_set'
union all
select 'az indoklas rakerul az elozmenyre',
       case when prosrc like '%room_status_history set reason%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%room_status_history set reason%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='dorm_room_status_set'
union all
select 'megengedett szobaatmenetek szama', count(*)::text, 'INFO' from dorm.room_status_transition;
