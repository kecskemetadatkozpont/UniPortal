-- ============================================================================
-- 40_attributes_edit.sql — a hallgatói besorolás szerkeszthetővé tétele
-- ----------------------------------------------------------------------------
-- MIÉRT
--   A 38-as migráció a besorolást (tagozat, képzési szint, szak, kar) csak
--   MEGJELENÍTHETŐVÉ tette: a student_attributes táblára a felület kizárólag
--   SELECT jogot kapott. Egy hallgató átsorolása levelezőről nappalira tehát
--   nem ment a Regisztrációk alól.
--
-- MIT AD
--   1. student_attributes_save() — a besorolás mentése egy fiókra. RPC, nem
--      közvetlen táblaírás: így a tábla jogait nem kell tágítani, és a
--      mentés egy helyen ellenőrizhető.
--   2. student_attribute_options() — a legördülők tartalma: a ténylegesen
--      előforduló értékek, darabszámmal. Így nem lehet elgépelni egy
--      "Levelezõ"-t, ami aztán külön csoportnak látszana.
--
-- KI SZERKESZTHET
--   Admin és szuperadmin — ugyanaz, mint amit a 38-as sorszintű szabálya
--   már enged a táblán.
--
-- IDEMPOTENS. Visszavonás: select public.attributes_edit_rollback();
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) A legördülők tartalma
--    A ténylegesen előforduló értékeket adja vissza, gyakoriság szerint.
--    Azért a MEGLÉVŐ adatból, mert egy szabadon beírt új érték némán külön
--    kategóriát csinálna — a csoportszabályok pedig pontos egyezésre mennek.
-- ---------------------------------------------------------------------------
create or replace function public.student_attribute_options()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'tagozat',       (select coalesce(jsonb_agg(jsonb_build_object('ertek', t.v, 'db', t.n)
                                                order by t.n desc), '[]'::jsonb)
                        from (select tagozat v, count(*) n from public.student_attributes
                               where tagozat is not null group by 1) t),
    'kepzesi_szint', (select coalesce(jsonb_agg(jsonb_build_object('ertek', t.v, 'db', t.n)
                                                order by t.n desc), '[]'::jsonb)
                        from (select kepzesi_szint v, count(*) n from public.student_attributes
                               where kepzesi_szint is not null group by 1) t),
    'szak',          (select coalesce(jsonb_agg(jsonb_build_object('ertek', t.v, 'db', t.n)
                                                order by t.n desc), '[]'::jsonb)
                        from (select szak v, count(*) n from public.student_attributes
                               where szak is not null group by 1) t),
    'kar',           (select coalesce(jsonb_agg(jsonb_build_object('ertek', t.v, 'db', t.n)
                                                order by t.n desc), '[]'::jsonb)
                        from (select kar v, count(*) n from public.student_attributes
                               where kar is not null group by 1) t)
  )
$$;

-- ---------------------------------------------------------------------------
-- 2) A besorolás mentése
--    A NULL érték "ne változtass"-t jelent, az üres szöveg "töröld".
--    Erre a kettősségre azért van szükség, mert a felületen egy mező
--    kiürítése értelmes művelet: a k-küszöb miatt egyes hallgatóknál
--    szándékosan nincs kar.
-- ---------------------------------------------------------------------------
create or replace function public.student_attributes_save(
  p_profile       uuid,
  p_tagozat       text default null,
  p_kepzesi_szint text default null,
  p_szak          text default null,
  p_kar           text default null,
  p_neptun        text default null)
returns public.student_attributes
language plpgsql security definer set search_path = public
as $$
declare
  v_r public.student_attributes;
begin
  if not public.is_admin() and not public.is_superadmin() then
    raise exception 'A besorolást csak admin vagy szuperadmin módosíthatja.'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile) then
    raise exception 'Nincs ilyen fiók.' using errcode = '02000';
  end if;

  insert into public.student_attributes (profile_id, tagozat, kepzesi_szint, szak, kar, neptun, forras)
  values (p_profile,
          nullif(btrim(coalesce(p_tagozat, '')), ''),
          nullif(btrim(coalesce(p_kepzesi_szint, '')), ''),
          nullif(btrim(coalesce(p_szak, '')), ''),
          nullif(btrim(coalesce(p_kar, '')), ''),
          nullif(btrim(coalesce(p_neptun, '')), ''),
          'kezi')
  on conflict (profile_id) do update set
    -- NULL = ne változtass; üres szöveg = töröld.
    tagozat       = case when p_tagozat       is null then public.student_attributes.tagozat
                         else nullif(btrim(p_tagozat), '') end,
    kepzesi_szint = case when p_kepzesi_szint is null then public.student_attributes.kepzesi_szint
                         else nullif(btrim(p_kepzesi_szint), '') end,
    szak          = case when p_szak          is null then public.student_attributes.szak
                         else nullif(btrim(p_szak), '') end,
    kar           = case when p_kar           is null then public.student_attributes.kar
                         else nullif(btrim(p_kar), '') end,
    neptun        = case when p_neptun        is null then public.student_attributes.neptun
                         else nullif(btrim(p_neptun), '') end,
    updated_at    = now()
  returning * into v_r;

  return v_r;
end $$;

revoke all on function public.student_attribute_options()                          from public, anon;
revoke all on function public.student_attributes_save(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.student_attribute_options()                       to authenticated;
grant execute on function public.student_attributes_save(uuid, text, text, text, text, text) to authenticated;

create or replace function public.attributes_edit_rollback()
returns text language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'Csak szuperadmin vonhatja vissza.' using errcode = '42501';
  end if;
  drop function if exists public.student_attribute_options();
  drop function if exists public.student_attributes_save(uuid, text, text, text, text, text);
  -- A besorolási ADATOKHOZ nem nyúlunk: azok a 38-as/teszt_jellemzok
  -- eredményei, nem ennek a migrációnak a tartozéka.
  return 'A 40-es visszavonva. A besorolási adatok érintetlenek.';
end $$;

revoke all on function public.attributes_edit_rollback() from public, anon;
grant execute on function public.attributes_edit_rollback() to authenticated;

commit;
