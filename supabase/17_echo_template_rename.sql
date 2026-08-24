-- ============================================================
-- UniPortal Pro — ECHO: a kérdőív nevének szerkesztése piszkozat állapotban
-- ------------------------------------------------------------
-- MIÉRT:
--   A 16-os migráció echo_template_save() függvénye csak a KÉRDÉSEKET (compiled)
--   menti. A kérdőív neve az echo.template táblán él (name_hu / name_en), és
--   létrehozás után nem volt módosítható. Piszkozat állapotban ez indokolatlan
--   korlát: a szerkesztés alatt álló kérdőívnek a neve is alakulhat.
--
-- MIT CSINÁL:
--   Új RPC: public.echo_template_rename(p_version, p_name_hu, p_name_en).
--   Csak akkor enged, ha a MEGADOTT VERZIÓ állapota 'draft'.
--
-- FONTOS KÖVETKEZMÉNY, amit a felület is kiír:
--   A név a SABLONHOZ tartozik, nem a verzióhoz. Ha ugyanennek a sablonnak van
--   élesített (live) verziója is, az átnevezés ANNAK a megjelenő nevét is
--   megváltoztatja. A szenátus a kérdőív TARTALMÁT hagyja jóvá (3. § (2)),
--   nem a megjelenítési nevét, ezért ez megengedett — de nem mellékhatás nélküli,
--   ezért a függvény visszaadja, hány másik verziót érint.
--
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

create or replace function public.echo_template_rename(
  p_version uuid,
  p_name_hu text,
  p_name_en text default null
) returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_state text;
  v_tpl   uuid;
  v_hu    text := nullif(btrim(coalesce(p_name_hu, '')), '');
  v_en    text := nullif(btrim(coalesce(p_name_en, '')), '');
  v_other int;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  select tv.state, tv.template_id into v_state, v_tpl
    from echo.template_version tv where tv.id = p_version;
  if v_state is null then raise exception 'ECHO_VERSION_NOT_FOUND'; end if;

  -- Ugyanaz a kapu, mint az echo_template_save-nél: élesített vagy jóváhagyott
  -- verzió mellől nem nevezünk át, mert az a futó kampányok címkéjét mozdítaná el.
  if v_state <> 'draft' then
    raise exception 'ECHO_NOT_DRAFT: a verzio allapota "%", atnevezni csak draft '
                    'allapotban lehet.', v_state;
  end if;

  if v_hu is null then
    raise exception 'ECHO_NAME_EMPTY: a magyar nev nem lehet ures.';
  end if;
  if length(v_hu) > 120 or length(coalesce(v_en, '')) > 120 then
    raise exception 'ECHO_NAME_TOO_LONG: a nev legfeljebb 120 karakter.';
  end if;

  -- Hany masik verziot erint az atnevezes (a felulet ezt kiirja)?
  select count(*) into v_other
    from echo.template_version tv
   where tv.template_id = v_tpl and tv.id <> p_version;

  update echo.template
     set name_hu = v_hu,
         name_en = coalesce(v_en, name_en)
   where id = v_tpl;

  perform echo.log_access('echo_template_rename', null, null, null, 'template');

  return jsonb_build_object(
    'template_id',   v_tpl,
    'name_hu',       v_hu,
    'name_en',       coalesce(v_en, (select name_en from echo.template where id = v_tpl)),
    'erintett_tovabbi_verzio', v_other);
end $$;

revoke execute on function public.echo_template_rename(uuid, text, text) from public, anon;
grant  execute on function public.echo_template_rename(uuid, text, text) to authenticated;

-- ---------- ellenőrzés ----------
select 'echo_template_rename letrejott' as mit,
       (to_regprocedure('public.echo_template_rename(uuid,text,text)') is not null)::text as ertek,
       'true' as elvart;
