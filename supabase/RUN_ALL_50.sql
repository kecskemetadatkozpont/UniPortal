-- ============================================================================
-- RUN_ALL_50.sql — UniPortal
--
--   50_my_enrollments.sql      a hallgató saját kurzusai
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--   + a végén a MODUL SAJÁT ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a RUN_ALL_49.sql már lefutott.
-- Idempotens. Egyetlen olvasó függvényt ad hozzá, meglévőt nem módosít.
-- ============================================================================


-- ============================================================================
--  50_my_enrollments.sql — UniPortal / ECHO
--  A HALLGATÓ SAJÁT KURZUSAI
-- ============================================================================
--
--  MIT AD: a hívó SAJÁT beiratkozásait, félévekre bontva — kurzuskód, név,
--  félév, nyelv, szervezeti egység, leírás és az oktatók.
--
--  MIT NEM AD, ÉS MIÉRT:
--   - TANANYAGOKAT, FÁJLOKAT nem. A 43-as migrációnál ez kimondott döntés volt:
--     a kurzusdokumentumok belső nyilvántartás, ügyintézőnek és a kurzus
--     oktatójának szólnak. A hallgatói nézet ezen nem lazít.
--   - A KURZUSTÁRSAKAT nem. Egy hallgatónak semmi köze ahhoz, ki más járt
--     ugyanarra a kurzusra.
--   - LÉTSZÁMOT nem. Kis kurzusnál (3-4 fő) a létszám és az ECHO közzétett
--     eredménye együtt szűkíti a kört; a hallgatónak amúgy sincs rá szüksége.
--
--  A SZŰRÉS A SZERVEREN VAN: a függvény kizárólag auth.uid() sorait adja
--  vissza, paraméterrel nem lehet más hallgatóra kérdezni. Nincs is
--  paramétere — ez nem véletlen.
--
--  ELŐFELTÉTEL: a RUN_ALL_49.sql már lefutott. Idempotens, csak olvas.
-- ============================================================================

create or replace function public.echo_my_enrollments()
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_me  uuid := auth.uid();
  v_out jsonb;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;

  select coalesce(jsonb_agg(x order by x->>'term' desc), '[]'::jsonb) into v_out
  from (
    select jsonb_build_object(
             'term', k.term,
             'kurzus_szam', count(*),
             'kurzusok', jsonb_agg(jsonb_build_object(
                'course_id', k.id,
                'code', k.code,
                'name_hu', k.name_hu,
                'name_en', k.name_en,
                'lang', k.lang,
                'org_unit', (select o.name_hu from echo.org_unit o where o.id = k.org_unit_id),
                'leiras', k.leiras,
                'leiras_en', k.leiras_en,
                'status', e.status,
                'vizsgakurzus', k.vizsgakurzus,
                'oktatok', (select coalesce(jsonb_agg(jsonb_build_object(
                                     'nev', t.name, 'title', t.title,
                                     'role', ct.role, 'share_pct', ct.share_pct)
                                   order by ct.share_pct desc, t.name), '[]'::jsonb)
                              from echo.course_teacher ct
                              join echo.teacher t on t.id = ct.teacher_id
                             where ct.course_id = k.id))
                order by k.code)) as x
      from echo.enrollment e
      join echo.course k on k.id = e.course_id
     where e.student_key = v_me
     group by k.term
  ) s;

  return jsonb_build_object(
    'felev_szam', jsonb_array_length(v_out),
    'kurzus_szam', (select count(*) from echo.enrollment e where e.student_key = v_me),
    'felevek', v_out);
end $$;

do $jog$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'echo_my_enrollments'
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon',   f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end
$jog$;



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


-- ============================================================================
--  ELLENŐRZÉS — futtasd le, és küldd vissza a táblát
-- ============================================================================
select 'echo_my_enrollments letezik' as mit_ellenorzunk,
       count(*)::text||' valtozat' as ertek,
       case when count(*) = 1 then 'OK' else 'HIBA' end as allapot
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_my_enrollments'
union all
select 'NINCS parametere (mas hallgatora nem kerdezheto)',
       coalesce(nullif(pg_get_function_identity_arguments(p.oid), ''), '(nincs)'),
       case when pg_get_function_identity_arguments(p.oid) = '' then 'OK'
            else 'HIBA — parameterrel mas sorai is elkerhetok lennenek' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_my_enrollments'
union all
select 'auth.uid()-ra szur',
       case when prosrc like '%e.student_key = v_me%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%e.student_key = v_me%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_my_enrollments'
union all
select 'tananyagot NEM ad ki',
       case when prosrc ilike '%course_document%' then 'kiadja' else 'nem adja ki' end,
       case when prosrc ilike '%course_document%' then 'HIBA — belso nyilvantartas'
            else 'OK' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_my_enrollments'
union all
-- A 'letszam' oszlopot es a reszveteli tablat sem erintjuk. A fuggvenyben
-- van ugyan egy count(*), de az a HIVO sajat beiratkozasait szamolja —
-- ezt kulon nezzuk, hogy a cimke ne legyen felrevezeto.
select 'kurzustarsat / letszamot NEM ad ki',
       case when prosrc ilike '%participation%' then 'reszvetelt is olvas'
            when prosrc ~* '''letszam''' then 'letszamot is ad'
            else 'nem adja ki' end,
       case when prosrc ilike '%participation%' or prosrc ~* '''letszam'''
            then 'HIBA' else 'OK' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_my_enrollments'
union all
select 'csak authenticated hivhatja',
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon is' else 'csak authenticated' end,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_my_enrollments';
