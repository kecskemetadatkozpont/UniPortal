-- ============================================================================
-- RUN_ALL_40.sql — UniPortal
--
--   40_attributes_edit.sql     a hallgatói besorolás szerkeszthetővé tétele
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--   + a végén a MODUL SAJÁT ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a RUN_ALL_39.sql már lefutott.
-- Idempotens. Csak függvényeket ad hozzá — meglévő adatot nem módosít.
-- ============================================================================


-- ===========================================================================
-- >>> 40_attributes_edit.sql
-- ===========================================================================
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
-- 40 ellenőrzés: a besorolás szerkeszthetősége.
with o(s,mit,nev) as (values
  (1,'Besorolás mentése','student_attributes_save'),
  (2,'Legördülők tartalma','student_attribute_options'),
  (3,'Visszavonó','attributes_edit_rollback')
),
letezik as (
  select o.s,o.mit,o.nev,
    case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                       where n.nspname='public' and p.proname=o.nev)
         then 'OK' else '!! HIÁNYZIK' end from o
),
valaszthato as (
  select 20,'Választható tagozat','student_attribute_options',
         coalesce((select string_agg(distinct tagozat, ', ')
                     from public.student_attributes where tagozat is not null),'(nincs adat)')
  union all
  select 21,'Választható szak (db)','student_attribute_options',
         coalesce((select count(distinct szak)::text
                     from public.student_attributes where szak is not null),'0')
),
adat as (
  select 30,'Besorolt fiók','student_attributes', count(*)::text from public.student_attributes
  union all
  select 31,'Ebből kézzel módosított','forras=kezi', count(*)::text
    from public.student_attributes where forras='kezi'
),
anon_echo as (
  select 70,'ECHO anonimitás (21 utoljára futott?)','echo_submit',
         string_agg(distinct grantee,', ' order by grantee) ||
         case when bool_or(grantee='authenticated') then '   !! FUTTASD ÚJRA a 21-est' else '   OK' end
    from information_schema.routine_privileges where routine_name='echo_submit'
)
select mit as "mit ellenőrzünk", nev as "objektum", allapot as "állapot"
  from (select * from letezik union all select * from valaszthato
        union all select * from adat union all select * from anon_echo) x(s,mit,nev,allapot)
 order by s;
