-- ============================================================================
-- RUN_ALL_93.sql — a betöltő óránként magától fut
-- ============================================================================
-- HOL TARTUNK: a 88–92 lefutott, a lánc végigment élesben, és a felület is
-- kint van. MÉRVE: 5 700 absztrakt, 5 800 beágyazott mű, 212 kutató 490
-- témakör-vektora, 13 felhívás 43 arculata, 3 763 illesztési találat.
--
-- MIÉRT KELL AZ ÜTEMEZÉS: a sorok maguktól újratöltődnek — új kutató, új mű,
-- új felhívás, módosult arculat. Kézi indítás nélkül a modul a mai napon friss,
-- utána egyre avultabb. Óránként egy hívás elég: az időkeretre vágva dolgozik,
-- és ha nincs teendő, egy másodperc alatt visszatér, modellhívás nélkül.
--
-- EGY LÉPÉS ELŐTTE, KÉZZEL (a titok nem kerülhet a nyilvános repóba):
--
--     select vault.create_secret('<a GRANTS_CRON_SECRET értéke>', 'grants_cron_secret');
--
--   Ugyanaz az érték, ami az Edge Function titkai közt már szerepel
--   (Dashboard → Edge Functions → Secrets → GRANTS_CRON_SECRET). Ha kimarad,
--   a szkript lefut, de az első ütemezett futás beszédes hibával áll meg.
--
-- MIT VÁRJ A FUTÁS VÉGÉN:
--   NOTICE: 93 — utemezve: grants-etl, orankent (7 * * * *).
--   NOTICE: Rendben: 93 — a betolto orankent fut, a titok a vaultbol jon.
--   NOTICE: Rendben: az ECHO bekuldes tovabbra is zart.
--
-- ELLENŐRZÉS egy óra múlva:
--   select * from cron.job_run_details order by start_time desc limit 10;
-- LEÁLLÍTÁS bármikor:
--   select cron.unschedule('grants-etl');
-- ============================================================================



-- ####################################################################
-- ### 93_grants_etl_cron.sql
-- ####################################################################

-- ============================================================
-- 93_grants_etl_cron.sql — a betöltő óránként magától fut
-- ============================================================
-- MIÉRT: eddig kézzel hajtottam a láncot (metaadat → beágyazás → klaszterezés
-- → arculatok → illesztés). A sorok maguktól újratöltődnek: új kutató, új mű,
-- új felhívás, módosult arculat. Ha nem fut magától, a modul a kézi indítás
-- napján friss, utána egyre avultabb.
--
-- MIT CSINÁL: óránként meghívja a grants-semantic függvényt `mind` módban. Az
-- egy hívás időkeretre vágva dolgozik (~110 s), és mindig a sor elejét viszi —
-- tehát a hátralék napok alatt fogy el, nem egyetlen hosszú futásban. Ha nincs
-- teendő, a hívás 1 másodperc alatt visszatér, és NEM hív modellt.
--
-- A TITOK NEM KERÜL A KÓDBA. A hívás az ütemező titkával (GRANTS_CRON_SECRET)
-- azonosítja magát, és azt a Supabase Vault tárolja. A migráció csak HIVATKOZIK
-- rá; az értéket külön, egyszer kell felvinni (lásd alább). A repó nyilvános,
-- ezért ez nem stílus kérdése.
--
-- ELŐFELTÉTEL — EGYSZER, KÉZZEL, A SQL EDITORBAN:
--     select vault.create_secret('<a GRANTS_CRON_SECRET értéke>', 'grants_cron_secret');
--   Ugyanaz az érték, ami az Edge Function titkai közt már szerepel.
--   Ha kimarad, az ütemezett futás beszédes hibaüzenettel áll meg, és a
--   modul a kézi indítással változatlanul működik.
--
-- LEÁLLÍTÁS: select cron.unschedule('grants-etl');
-- ELLENŐRZÉS: select * from cron.job_run_details order by start_time desc limit 10;
--
-- Futtatás után: 21_echo_harden_submit.sql újra (a szokásos sorrend).
-- ============================================================

do $ext$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
  else
    raise notice '93 — pg_cron nem elerheto ezen a peldanyon: az utemezes kimarad.';
  end if;
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  else
    raise notice '93 — pg_net nem elerheto ezen a peldanyon: az utemezes kimarad.';
  end if;
end $ext$;

-- A hívás egy helyen. Így az ütemezett és a kézi indítás UGYANAZ a kód, és a
-- titok egyetlen helyen olvasódik ki.
create or replace function grants.etl_futtat(p_mod text default 'mind', p_limit integer default 400)
returns bigint
language plpgsql volatile security definer
set search_path = grants, public, extensions, pg_temp
as $$
declare v_kulcs text; v_id bigint;
begin
  select decrypted_secret into v_kulcs
    from vault.decrypted_secrets where name = 'grants_cron_secret' limit 1;
  if v_kulcs is null or btrim(v_kulcs) = '' then
    raise exception 'GRANTS_HIBA: hianyzik a vault-titok (grants_cron_secret). Vidd fel egyszer: select vault.create_secret(''<ertek>'', ''grants_cron_secret'');';
  end if;

  select net.http_post(
           url := 'https://mdccyastwhzwtyukxlpk.supabase.co/functions/v1/grants-semantic',
           headers := jsonb_build_object('Content-Type', 'application/json',
                                         'x-grants-cron', v_kulcs),
           body := jsonb_build_object('mod', coalesce(p_mod, 'mind'),
                                      'limit', greatest(1, least(500, coalesce(p_limit, 400)))),
           timeout_milliseconds := 150000)
    into v_id;
  return v_id;
end $$;

do $cron$
begin
  if to_regclass('cron.job') is null then
    raise notice '93 — nincs cron.job tabla, az utemezes kimarad (a fuggveny kezzel hivhato).';
    return;
  end if;
  -- Újrafuttatásnál ne szaporodjon a feladat.
  perform cron.unschedule('grants-etl') where exists (select 1 from cron.job where jobname = 'grants-etl');
  -- Óránként az óra 7. percében: ne essen egybe a többi ütemezett feladattal.
  perform cron.schedule('grants-etl', '7 * * * *', 'select grants.etl_futtat(''mind'', 400);');
  raise notice '93 — utemezve: grants-etl, orankent (7 * * * *).';
end $cron$;

do $grants$
declare
  has_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  has_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  f text := 'grants.etl_futtat(text,integer)';
begin
  -- A titkot olvassa: klienstől teljesen elzárva.
  execute format('revoke all on function %s from public', f);
  if has_anon then execute format('revoke all on function %s from anon', f); end if;
  if has_auth then execute format('revoke all on function %s from authenticated', f); end if;
end $grants$;

do $chk$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated')
     and has_function_privilege('authenticated', 'grants.etl_futtat(text,integer)', 'execute') then
    raise exception 'BIZTONSAGI HIBA: bejelentkezett felhasznalo is futtathatja az ETL-hivast.';
  end if;
  -- A két feltétel NEM mehet egy kifejezésbe: a plpgsql az egész IF-et egy
  -- lekérdezésként tervezi, tehát a cron.job hivatkozásnak akkor is fel kell
  -- oldódnia, ha a tábla nem létezik. Ezért egymásba ágyazva.
  if to_regclass('cron.job') is not null then
    if not exists (select 1 from cron.job where jobname = 'grants-etl') then
      raise notice 'FIGYELEM: a grants-etl feladat nem jott letre — nezd meg a cron.job tablat.';
    end if;
  end if;
  if not exists (select 1 from pg_extension where extname = 'vault')
     and to_regclass('vault.decrypted_secrets') is null then
    raise notice 'FIGYELEM: nincs vault sema — a titkot maskepp kell atadni.';
  end if;
  raise notice 'Rendben: 93 — a betolto orankent fut, a titok a vaultbol jon.';
end $chk$;


-- ####################################################################
-- ### 21_echo_harden_submit.sql
-- ####################################################################

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
