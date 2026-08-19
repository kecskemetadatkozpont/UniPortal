-- ============================================================
-- UniPortal Pro — ECHO (OMHV) adatbázis-mag, 1. szelet (Step 15)
-- Neumann János Egyetem, 28/2023. szenátusi határozat
-- Változat: 2026-08-19, HELYI POSTGRES 16 REPLIKÁN MÉRVE
-- ============================================================
--
-- MIT CSINÁL:
--   • Létrehoz egy KÜLÖN 'echo' sémát, és azonnal el is zárja: az anon és az
--     authenticated szerepkör semmilyen jogot nem kap rá. A kliens KIZÁRÓLAG
--     public sémás SECURITY DEFINER RPC-ken keresztül ér el bármit.
--   • Törzsadat (Neptunból jön majd): org_unit, teacher, course,
--     course_teacher, enrollment — mind külső azonosítóval és szinkron-bélyeggel.
--   • Kérdőívmotor: template / template_version, a kérdéslogika JSONB-ben.
--   • Kampány (draft → open → closed → processing → sealed → published).
--   • Alkalmassági motor: echo.eligibility_rebuild(kampány) + kizárási napló
--     okkal és §-hivatkozással.
--   • Kettéválasztott beküldés: azonosított RÉSZVÉTELI NAPLÓ és anonim
--     VÁLASZHALMAZ, MAC-elt jeggyel összekötve — úgy, hogy a kettő ne legyen
--     összefésülhető.
--   • Public RPC-k a frontendnek, és egy idempotens DEMÓ SEED, hogy a
--     lefuttatás után bárki, aki ma belép, lásson kitölthető kurzust.
--
-- FUTTATÁS: Supabase dashboard → SQL Editor → New query → beilleszt → Run.
-- Idempotens — egyetlen beillesztéssel lefut, nincs benne psql meta-parancs.
-- A replikán KÉTSZER lefuttatva ON_ERROR_STOP=1 mellett hibátlan (lásd lent).
--
-- ============================================================
-- KÖTELEZŐ KÉZI LÉPÉS A LEFUTTATÁS UTÁN (SQL-ből nem állítható)
-- ============================================================
--   Supabase Dashboard → bal oldali menü: Project Settings (fogaskerék)
--     → API → "Data API" (régebbi felületen: "API Settings") szakasz
--     → "Exposed schemas" mező.
--   ITT AZ 'echo' NE SZEREPELJEN. A mezőben alapértelmezésben 'public' és
--   'graphql_public' áll. Ha bármi okból bekerült volna az 'echo', vedd ki,
--   és nyomj Save-et.
--   MIÉRT: ha az 'echo' szerepel az Exposed schemas listán, a PostgREST
--   közvetlen tábla-végpontot nyit rá (/rest/v1/response?select=*). Attól,
--   hogy lentebb minden jogot visszavonunk, a végpont még létrejön, és
--   minden hibás jövőbeli grant azonnal kifelé nyílik. A séma kihagyása a
--   MÁSODIK védvonal — nem helyettesíti a revoke-okat, hanem kiegészíti.
--
--   Ugyanitt NE add hozzá az echo tábláit a Realtime publikációhoz:
--     Database → Replication → supabase_realtime → Tables.
--   Az ECHO táblái SOHA nem kerülhetnek a supabase_realtime publikációba:
--   a realtime WAL-folyam a beérkezés SORRENDJÉBEN küldi a sorokat, ami
--   önmagában deanonimizálja a válaszokat. Ez a fájl nem is teszi be őket.
--
-- ============================================================
-- A HÁROM SZERKEZETI DÖNTÉS (utólag nem javítható — ezért itt, elöl)
-- ============================================================
--   1. KÜLÖN 'echo' SÉMA, nem 'public.echo_*' tábla-prefix.
--      Ugyanebben az adatbázisban él egy MÁSIK alkalmazás (prefs,
--      publications, publication_files) és maga az UniPortal is. A public
--      séma Supabase-en alapértelmezésben ki van téve a Data API-nak, és a
--      Supabase default privilege-ei (ALTER DEFAULT PRIVILEGES … IN SCHEMA
--      public GRANT ALL ON TABLES TO anon, authenticated) SEMATIKUSAN a
--      public sémára szólnak. Egy 'public.echo_response' tábla tehát
--      alapértelmezés szerint OLVASHATÓ lenne, és csak az RLS védené.
--      Külön sémában a védelem nem egy policy helyességén múlik, hanem azon,
--      hogy a szerepkörnek nincs USAGE joga a sémára — ez sokkal nehezebben
--      rontható el.
--
--   2. A VÁLASZSOR ELSŐDLEGES KULCSA random uuid v4 (gen_random_uuid()).
--      Se bigserial, se uuid v7. Mindkettő a beérkezés SORRENDJÉT kódolja a
--      kulcsba: a bigserial nyíltan, a uuid v7 az első 48 biten ezredmásodperc
--      pontosságú időbélyeggel. A részvételi naplóval (ki próbálkozott, mikor)
--      összefésülve ez sorrend-egyeztetéssel deanonimizál. A v4 kulcs nem
--      hordoz sorrendet.
--
--   3. A VÁLASZSORON SEMMILYEN IDŐBÉLYEG-OSZLOP. Nincs created_at, nincs
--      inserted_at, nincs updated_at. Egy 'created_at default now()' oszlop
--      VISSZAMENŐLEG is megtöri az anonimitást: nemcsak az ezután érkező,
--      hanem az addig már összegyűjtött MINDEN válaszra, mert az oszlop
--      felvételekor a régi sorok ugyan NULL-t kapnak, de az újak azonnal
--      összeköthetők a napló attempted-bejegyzéseivel. Ezért nincs rajta.
--
--   AMIT A 2. ÉS 3. DÖNTÉS NEM OLD MEG — ÉS EZT KI KELL MONDANI:
--      KÉT rendszerszintű nyom marad, és EGYIKET SEM az oszlopok hordozzák:
--
--      (a) ctid — a sorok FIZIKAI sorrendje a heap-ben továbbra is a beszúrás
--          sorrendje. Egy postgres jogú olvasó 'select ctid, * from
--          echo.response order by ctid' paranccsal megkapja az érkezési
--          sorrendet, időbélyeg nélkül is.
--
--      (b) xmin — a sort létrehozó tranzakció azonosítója, szintén olvasható
--          rendszeroszlop. MÉRVE a replikán: a jegykiadás és a beküldés két
--          EGYMÁST KÖVETŐ tranzakció, ezért javítás nélkül
--          response.xmin = participation.xmin + 1, és egy hatsoros join a
--          kitöltő e-mail címét adja vissza minden válaszhoz. Ez ellen a
--          9.4 echo_issue_ticket a kurzus TELJES kohorszának sorverzióját
--          frissíti ugyanabban a tranzakcióban, így a kohorsz minden naplósora
--          azonos xmin-t kap, és a join az egész anonimitás-halmazt adja
--          vissza egyetlen ember helyett (mérve: 1 helyett 14 gyanúsított).
--
--      Mindkettőt a tábla véletlen sorrendű újraírása szünteti meg:
--      echo.shuffle_responses(kampány) a 6.5 szakaszban. EZT NEM ELÉG
--      PECSÉTELÉSKOR LEFUTTATNI: a nyitott kampány alatt is KELL, naponta
--      egyszer (pl. éjszakai ütemezéssel), különben a frissen beérkezett
--      válaszok xmin-je a nyitott ablak teljes ideje alatt azonosít.
--      A fájl nem futtatja automatikusan, mert kizárólagos zárat kér.
--
-- ============================================================
-- MIT NEM GARANTÁL EZ A FELÁLLÁS (őszintén)
-- ============================================================
--   • KÖZÖS PROJEKT. Az ECHO ugyanabban a Postgres adatbázisban él, mint az
--     UniPortal és a publikációs alkalmazás. Aki 'postgres' vagy 'service_role'
--     jogot szerez, mindent lát: a naplót is, a válaszokat is, a ctid-sorrendet
--     is. Ez a séma-elválasztással NEM oldható meg, csak külön projekttel /
--     külön adatbázissal. A felhasználó tudatosan az egy-projekt felállást
--     választotta.
--   • DASHBOARD. A Supabase SQL Editor postgres jogon fut, tehát megkerül
--     minden RLS-t és minden grantot. Aki a Dashboardhoz fér hozzá,
--     technikailag képes egyeztetni a naplót és a válaszokat.
--   • BACKUP / PITR. A Supabase automatikus mentése és a WAL-archívum a
--     tranzakciók sorrendjét megőrzi. Egy PITR-visszaállítás időben szeletelve
--     megmutatja, mely válasz mikor keletkezett — akkor is, ha az élő táblát
--     azóta megkeverték. Ez ellen csak a mentések hozzáférés-korlátozása véd.
--   • KIS ELEMSZÁM. Ha egy kurzuson 3-4 hallgató van, semmilyen kriptográfia
--     nem segít: a válasz tartalma önmagában azonosít. Ezért van az
--     alkalmassági motorban a 3 fős küszöb (5. szakasz) — az anonimitás első
--     védvonala nem technikai, hanem az, hogy kis csoportot nem kérdezünk.
--   • A SZÖVEGES VÁLASZ. A szabad szöveg tartalma (stílus, egyedi utalás)
--     azonosíthat. Ezért 'moderated: true' a szöveges kérdéseken — a
--     moderálási folyamat MÉG NINCS MEGÍRVA, ez a jelen szelet határa.
--
-- ============================================================
-- MIT KELL A FRONTENDNEK TUDNIA (integrációs jegyzet)
-- ============================================================
--   A public.echo_submit() grantja SZÁNDÉKOSAN csak 'anon'-nak szól, és az
--   'authenticated'-től VISSZA VAN VONVA. A supabase-js kliens viszont
--   automatikusan ráteszi a bejelentkezett felhasználó JWT-jét minden
--   kérésre, tehát a szokásos window.sb.rpc('echo_submit', …) hívás
--   'authenticated' szerepkörben érkezik, és 42501 (permission denied)
--   hibával BUKIK. EZ NEM HIBA, EZ A LÉNYEG.
--   A beküldéshez a frontendnek KÜLÖN, munkamenet nélküli klienst kell
--   nyitnia, például:
--       const sbAnon = window.supabase.createClient(URL, ANON_KEY, {
--         auth: { persistSession: false, autoRefreshToken: false } });
--       await sbAnon.rpc('echo_submit', { p_ticket: t, p_payload: v });
--   Így a beküldő kéréshez semmilyen felhasználó-azonosító nem tapad, és a
--   hallgató azonosítója egyetlen szerveroldali naplóban (postgres log,
--   pgbouncer, PostgREST access log) sem kerül a válasz mellé.
--   Minden MÁS ECHO RPC a rendes, bejelentkezett window.sb klienssel megy.
--
-- ============================================================
-- FORRÁSHŰSÉG — EZT OLVASD EL, MIELŐTT A SZÖVEGEKRE ÉPÍTESZ
-- ============================================================
--   A feladat az ECHO prototípus 'ECHO Prototipus.dc.html' fájljának
--   1183–2345. sorára hivatkozott (FORM_SEED, ATTENDANCE, SKIP_REASONS,
--   COURSE_STRENGTHS, COURSE_IMPROVE, T_STRENGTHS, T_IMPROVE, Q_TYPES …).
--   EZ A FÁJL A JELEN KÖRNYEZETBEN NEM LÉTEZIK — ellenőrizve: sem a megadott
--   útvonalon, sem a teljes /private/tmp/claude-501 és
--   ~/Documents/AntigravityProjects fa alatt nincs sem 'ECHO Prototipus.dc.html',
--   sem 'feedback-demo' könyvtár, és a 'FORM_SEED' / 'EVAL_STEPS' /
--   'SKIP_REASONS' azonosítókra 0 találat van.
--   Ezért a 11. szakasz compiled JSONB-je a feladatleírás szöveges
--   ismertetéséből REKONSTRUÁLT: a SZERKEZET (mezőnevek, típusok, 6 szakasz,
--   13 kérdés, repeat/cond/max/audience szemantika) az, amire a frontend
--   építhet; a KONKRÉT MAGYAR ÉS ANGOL KÉRDÉSSZÖVEGEK ÉS VÁLASZLISTÁK
--   BECSLÉSEK, amelyeket a prototípus előkerülésekor egyetlen UPDATE-tel
--   felül kell írni (a template_version 2-es verziójaként, lásd 3. szakasz).
--   Minden ilyen becsült szöveg mellé "-- BECSLÉS" megjegyzés került.
--   Ugyanígy BECSLÉS a kizárási szabályok §-hivatkozása: a 28/2023.
--   szenátusi határozat szövege sincs meg, a paragrafusszámok az
--   echo.exclusion_rule táblában ADATKÉNT állnak, hogy egy UPDATE-tel
--   pontosíthatók legyenek, kód módosítása nélkül.
-- ============================================================


-- ============================================================
-- 0. SZAKASZ — ELŐELLENŐRZÉS
-- ============================================================
do $precheck$
declare
  v_missing text := '';
begin
  -- A 07/08-as migráció helper függvényei kellenek az RPC-k jogosultságához.
  if to_regprocedure('public.is_approved()') is null then v_missing := v_missing || ' is_approved()'; end if;
  if to_regprocedure('public.is_staff()')    is null then v_missing := v_missing || ' is_staff()';    end if;
  if to_regclass('public.profiles')          is null then v_missing := v_missing || ' profiles';      end if;
  if v_missing <> '' then
    raise exception 'ECHO: hianyzo elofeltetel:%. Futtasd elobb a 07 es 08 migraciot.', v_missing;
  end if;

  -- pgcrypto: a hmac() a jegy alairasahoz kell. Supabase-en az 'extensions'
  -- semaban el, a helyi replikan a 'public'-ban; mindkettot eltaláljuk, mert
  -- a SECURITY DEFINER fuggvenyek search_path-ja mindkettot tartalmazza.
  if to_regprocedure('public.hmac(bytea,bytea,text)') is null
     and to_regprocedure('extensions.hmac(bytea,bytea,text)') is null then
    raise exception 'ECHO: a pgcrypto hmac() nem talalhato sem a public, sem az extensions semaban.';
  end if;

  raise notice 'ECHO 0. szakasz: elofeltetelek rendben.';
end
$precheck$;


-- A pgcrypto Supabase-en az 'extensions', a helyi replikan a 'public' semaban
-- el. A fajl felsó szintjen (nem fuggvenyen belul) is hivunk gen_random_bytes-t,
-- ezert a munkamenet search_path-jaba mindketto bekerul. Nem letezo sema a
-- search_path-ban nem hiba, csak figyelmen kivul marad.
set search_path = public, extensions, pg_temp;


-- ============================================================
-- 1. SZAKASZ — AZ 'echo' SÉMA ÉS A ZÁRÁS
-- ============================================================
create schema if not exists echo;
comment on schema echo is
  'ECHO / OMHV kérdőívrendszer. NEM kerül a Supabase "Exposed schemas" listájára. '
  'A kliens kizárólag public sémás SECURITY DEFINER RPC-ken keresztül éri el.';

-- A zárás. A séma létrejöttekor a PUBLIC (azaz minden szerepkör) nem kap
-- automatikusan USAGE-t, de a Supabase telepítők és korábbi migrációk
-- állíthattak be tág default privilege-eket, ezért kimondjuk.
-- A revoke csak létező szerepkörre adható ki, ezért ellenőrizzük.
do $lock$
declare r text;
begin
  execute 'revoke all on schema echo from public';
  foreach r in array array['anon','authenticated','service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on schema echo from %I', r);
      -- Az ezután, POSTGRES által létrehozott objektumokra se szivárogjon jog.
      execute format('alter default privileges in schema echo revoke all on tables    from %I', r);
      execute format('alter default privileges in schema echo revoke all on sequences from %I', r);
      execute format('alter default privileges in schema echo revoke all on functions from %I', r);
      raise notice 'ECHO: % szerepkortol minden jog visszavonva az echo semara.', r;
    else
      raise notice 'ECHO: % szerepkor nem letezik, kihagyva.', r;
    end if;
  end loop;
end
$lock$;

-- MIÉRT a service_role is: a service_role kulcs a frontendbe soha nem kerül,
-- de szerver nélküli projektben könnyen egy scriptbe vagy egy Edge Functionbe
-- vándorol. Az ECHO-hoz nincs rá szükség: minden adminisztratív művelet
-- (eligibility_rebuild, mark_submitted, shuffle_responses) a Dashboard SQL
-- Editorából, postgres jogon fut. Így egy kiszivárgott service_role kulcs sem
-- ad hozzáférést a válaszokhoz.


-- ------------------------------------------------------------
-- 1.1 Beállítások (küszöbértékek adatként, nem kódba égetve)
-- ------------------------------------------------------------
create table if not exists echo.setting (
  key         text primary key,
  value       text        not null,
  description text,
  updated_at  timestamptz not null default now()
);

insert into echo.setting (key, value, description) values
  ('min_headcount', '3',
   'A veleményezhetőség alsó létszámküszöbe. Ez alatt a kurzus kimarad, mert '
   'a valaszok tartalma onmagaban azonositana a kitoltot.'),
  ('min_share_pct', '25',
   'Az oktatoi oraarany alsó kuszobe szazalekban. Ez alatt az oktato–kurzus '
   'par kimarad, mert a hallgatonak nincs eleg tapasztalata rola.'),
  ('ticket_ttl_minutes', '90',
   'A kiadott jegy ervenyessegi ideje percben. Ennyi ido all rendelkezesre a '
   'kerdoiv kitoltesere egy jegykiadastol szamitva.'),
  ('max_tickets_per_course', '2',
   'Egy hallgato egy kurzuson legfeljebb ennyi jegyet kaphat. A jegy egyszer '
   'hasznalhato, ezert ez egyben a bekuldesek felso korlatja is. Azert 2 es '
   'nem 1, hogy egy felbehagyott vagy halozati hiba miatt elhasalt kitoltes '
   'utan legyen meg egy probalkozas.')
on conflict (key) do nothing;

-- ------------------------------------------------------------
-- 1.2 A jegy aláíró kulcsa
-- ------------------------------------------------------------
-- MIÉRT saját tábla és nem supabase_vault: a Vault ugyanannak a postgres
-- szerepkörnek olvasható, mint ez a tábla, tehát a fenyegetési modellünkben
-- (postgres = mindent lát) NEM ad többletvédelmet — csak függőséget és egy
-- olyan extensiont, ami a helyi replikán nincs telepítve, tehát tesztelhetetlen
-- lenne. A táblát a lenti revoke zárja el mindenki mástól.
-- HA MÉGIS VAULT KELL: cseréld ki az echo.ticket_key() törzsét erre:
--   select decode(decrypted_secret, 'hex') from vault.decrypted_secrets
--    where name = 'echo_ticket_key';
create table if not exists echo.app_secret (
  key        text  primary key,
  secret     bytea not null,
  created_at timestamptz not null default now()
);

insert into echo.app_secret (key, secret)
select 'ticket_hmac', gen_random_bytes(32)
where not exists (select 1 from echo.app_secret where key = 'ticket_hmac');

-- A kulcs olvasása külön függvényben, hogy a Vaultra váltás egyetlen helyen
-- történjen. STABLE, nem IMMUTABLE: a kulcs cserélhető.
create or replace function echo.ticket_key()
returns bytea
language sql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$ select secret from echo.app_secret where key = 'ticket_hmac' $$;


-- ============================================================
-- 2. SZAKASZ — TÖRZSADAT (Neptunból jön majd)
-- ============================================================
-- Minden törzsadat-tábla ugyanazt a három szinkron-mezőt viseli:
--   ext_id        — a forrásrendszer azonosítója (Neptun kód, belső id)
--   ext_source    — melyik rendszerből jött ('neptun', 'manual', 'seed')
--   ext_synced_at — mikor frissült utoljára a forrásból
-- Így a későbbi tömeges szinkron upsertelhet ext_id + ext_source párosra,
-- és látszik, mi az, amit kézzel vittek fel és a szinkron nem ír felül.

-- ------------------------------------------------------------
-- 2.1 Szervezeti egység (kar / intézet / tanszék fa)
-- ------------------------------------------------------------
create table if not exists echo.org_unit (
  id            uuid primary key default gen_random_uuid(),
  parent_id     uuid references echo.org_unit(id) on delete restrict,
  code          text not null,
  name_hu       text not null,
  name_en       text,
  kind          text not null default 'tanszek'
                  check (kind in ('egyetem','kar','intezet','tanszek')),
  ext_id        text,
  ext_source    text not null default 'manual',
  ext_synced_at timestamptz,
  created_at    timestamptz not null default now()
);
create unique index if not exists echo_org_unit_code_uidx on echo.org_unit (code);
create unique index if not exists echo_org_unit_ext_uidx  on echo.org_unit (ext_source, ext_id)
  where ext_id is not null;
create index        if not exists echo_org_unit_parent_idx on echo.org_unit (parent_id);

-- ------------------------------------------------------------
-- 2.2 Oktató
-- ------------------------------------------------------------
create table if not exists echo.teacher (
  id            uuid primary key default gen_random_uuid(),
  code          text not null,
  name          text not null,
  title         text,                      -- 'dr.', 'egyetemi docens' …
  email         text,
  org_unit_id   uuid references echo.org_unit(id) on delete set null,
  active        boolean not null default true,
  -- A későbbi oktatói belépéshez: melyik UniPortal fiók ez az oktató.
  -- Ma NULL; az ECHO saját szerepkör-dimenziója még nem létezik.
  profile_id    uuid references public.profiles(id) on delete set null,
  ext_id        text,
  ext_source    text not null default 'manual',
  ext_synced_at timestamptz,
  created_at    timestamptz not null default now()
);
create unique index if not exists echo_teacher_code_uidx on echo.teacher (code);
create unique index if not exists echo_teacher_ext_uidx  on echo.teacher (ext_source, ext_id)
  where ext_id is not null;
create index        if not exists echo_teacher_org_idx   on echo.teacher (org_unit_id);

-- ------------------------------------------------------------
-- 2.3 Kurzus
-- ------------------------------------------------------------
create table if not exists echo.course (
  id                uuid primary key default gen_random_uuid(),
  code              text not null,               -- Neptun kurzuskód
  name_hu           text not null,
  name_en           text,
  term              text not null,               -- '2025/26/1'
  lang              text not null default 'hu' check (lang in ('hu','en','de','other')),
  org_unit_id       uuid references echo.org_unit(id) on delete set null,
  -- A letszam a forrásrendszer szerinti hallgatói létszám. Ha NULL, az
  -- alkalmassági motor az enrollment sorok számát használja helyette.
  letszam           integer check (letszam is null or letszam >= 0),
  van_orarendi_info boolean not null default true,
  vizsgakurzus      boolean not null default false,
  ext_id            text,
  ext_source        text not null default 'manual',
  ext_synced_at     timestamptz,
  created_at        timestamptz not null default now()
);
create unique index if not exists echo_course_code_term_uidx on echo.course (code, term);
create unique index if not exists echo_course_ext_uidx       on echo.course (ext_source, ext_id)
  where ext_id is not null;
create index        if not exists echo_course_term_idx       on echo.course (term);

-- ------------------------------------------------------------
-- 2.4 Kurzus ↔ oktató (share_pct: a 25%-os küszöbhöz)
-- ------------------------------------------------------------
create table if not exists echo.course_teacher (
  course_id     uuid not null references echo.course(id)  on delete cascade,
  teacher_id    uuid not null references echo.teacher(id) on delete cascade,
  -- Hány százalékát tartotta az órarendi óráknak. A 28/2023. határozat
  -- szerinti küszöb alatt az oktató nem véleményezhető ezen a kurzuson.
  share_pct     numeric(5,2) not null default 100
                  check (share_pct >= 0 and share_pct <= 100),
  role          text not null default 'oktato'
                  check (role in ('kurzusfelelos','oktato','gyakvezeto','vendeg')),
  ext_source    text not null default 'manual',
  ext_synced_at timestamptz,
  primary key (course_id, teacher_id)
);
create index if not exists echo_course_teacher_teacher_idx on echo.course_teacher (teacher_id);

-- ------------------------------------------------------------
-- 2.5 Felvétel (kurzus ↔ hallgató)
-- ------------------------------------------------------------
-- student_key: a public.profiles.id. SZÁNDÉKOSAN nem 'student_id', hogy a
-- kódban ránézésre látszódjon: ez az AZONOSÍTOTT oldal. A válaszhalmazban
-- ilyen oszlop nincs és nem is lehet.
create table if not exists echo.enrollment (
  id            uuid primary key default gen_random_uuid(),
  course_id     uuid not null references echo.course(id) on delete cascade,
  student_key   uuid not null references public.profiles(id) on delete cascade,
  status        text not null default 'active' check (status in ('active','dropped')),
  ext_id        text,
  ext_source    text not null default 'manual',
  ext_synced_at timestamptz,
  created_at    timestamptz not null default now()
);
create unique index if not exists echo_enrollment_uidx      on echo.enrollment (course_id, student_key);
create index        if not exists echo_enrollment_student_idx on echo.enrollment (student_key);


-- ============================================================
-- 3. SZAKASZ — KÉRDŐÍVMOTOR
-- ============================================================
--
-- MIÉRT JSONB ÉS NEM NORMALIZÁLT KÉRDÉSTÁBLÁK — az MVP döntés indoklása:
--
--   1. A KÉRDŐÍV EGYBEN ÉL. Az OMHV kérdőív nem kérdések laza halmaza, hanem
--      egyetlen, szenátus által jóváhagyott dokumentum. Ha kérdés-, opció-,
--      feltétel- és szakasztáblákra bontjuk, a "mi volt a jóváhagyott
--      kérdőív" kérdésre már csak egy hatféle join válaszol — és minden
--      későbbi sémamódosítás visszamenőleg átértelmezi a régi kitöltéseket.
--      A compiled JSONB EGY SOR, amit ki lehet nyomtatni és alá lehet írni.
--
--   2. A FUTÓ KAMPÁNYOK NEM SODRÓDNAK. A kampány a template_VERSION-re
--      hivatkozik, nem a template-re. A live verzió compiled mezője
--      immutábilis (lásd az alábbi triggert), tehát egy nyitott kampány alatt
--      senki nem tudja átfogalmazni a kérdést vagy kivenni egy válaszopciót.
--      Normalizált táblákkal ehhez minden kapcsolódó táblát verziózni és
--      minden UPDATE-et tiltani kellene — ugyanaz a védelem, ötszörös
--      felülettel.
--
--   3. A FRONTEND KÖZVETLENÜL HASZNÁLJA. A compiled alakja szándékosan a
--      prototípus FORM_SEED szerkezete (id, type, hu, en, help, options,
--      required, moderated, randomize, allowOther, max, repeat, cond, scale,
--      audience). Az echo_get_form() ezt VÁLTOZATLANUL adja vissza, tehát a
--      renderelő nem alakít át semmit, és nincs szerver–kliens séma-drift.
--
--   4. AZ ELEMZÉS NEM SÉRÜL. A válaszok answers mezője kérdés-id → érték
--      leképezés; a Postgres jsonb_path_ops GIN indexe és a jsonb_to_recordset
--      elegendő a kiértékeléshez. Amikor a MIR-riportok megírásra kerülnek,
--      a compiled-ból egyetlen view legenerálható — akkor, amikor már tudjuk,
--      milyen riport kell. Most nem tudjuk.
--
--   MIKOR LESZ EBBŐL BAJ: ha a kérdéseket kérdésbankból, kari szinten,
--   felületen akarják majd összerakni és kérdésenként hosszmetszetben
--   elemezni. Akkor a compiled marad a jóváhagyott pillanatkép, és MELLÉ jön
--   egy szerkesztő-oldali normalizált kérdésbank, ami compiled-ot GENERÁL.
--   Az irány tehát nem zsákutca — a compiled akkor is a hiteles forrás marad.

create table if not exists echo.template (
  id         uuid primary key default gen_random_uuid(),
  code       text not null,
  name_hu    text not null,
  name_en    text,
  created_at timestamptz not null default now()
);
create unique index if not exists echo_template_code_uidx on echo.template (code);

create table if not exists echo.template_version (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid not null references echo.template(id) on delete cascade,
  version      integer not null check (version >= 1),
  state        text not null default 'draft'
                 check (state in ('draft','review','approved','live','closed')),
  -- A teljes kérdőív pillanatképe. Alakja: { "meta": {...}, "sections": [ ... ] }
  compiled     jsonb not null,
  notes        text,
  approved_by  text,
  approved_at  timestamptz,
  created_at   timestamptz not null default now()
);
create unique index if not exists echo_template_version_uidx
  on echo.template_version (template_id, version);
create index if not exists echo_template_version_state_idx
  on echo.template_version (state);

-- A compiled csak akkor módosítható, amíg a verzió nem 'live'. Élesben a
-- kérdőív immutábilis; onnan már csak 'closed' állapotba mehet.
create or replace function echo.template_version_guard()
returns trigger language plpgsql as $$
begin
  if old.state = 'live' then
    if new.compiled::text is distinct from old.compiled::text then
      raise exception 'ECHO: elo (live) kerdoiv-verzio compiled mezoje nem modosithato. '
                      'Keszits uj verziot (version+1).';
    end if;
    if new.version is distinct from old.version then
      raise exception 'ECHO: elo (live) kerdoiv-verzio sorszama nem modosithato.';
    end if;
    if new.state not in ('live','closed') then
      raise exception 'ECHO: elo (live) kerdoiv-verzio csak closed allapotba mehet, nem %.', new.state;
    end if;
  end if;
  if old.state = 'closed' and new.state <> 'closed' then
    raise exception 'ECHO: lezart (closed) kerdoiv-verzio nem nyithato ujra.';
  end if;
  return new;
end $$;

drop trigger if exists echo_template_version_guard_trg on echo.template_version;
create trigger echo_template_version_guard_trg
  before update on echo.template_version
  for each row execute function echo.template_version_guard();


-- ============================================================
-- 4. SZAKASZ — KAMPÁNY
-- ============================================================
-- Állapotgép:
--   draft      — készül, nem látszik senkinek
--   open       — a hallgatók kitölthetik (opens_at ≤ now < closes_at is kell)
--   closed     — az ablak bezárt, több válasz nem jön
--   processing — feldolgozás: moderálás, aggregálás
--   sealed     — az adat lezárva; ITT KELL lefuttatni az echo.shuffle_responses()-t
--   published  — az eredmény közzétéve
create table if not exists echo.campaign (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null,
  name_hu             text not null,
  name_en             text,
  term                text not null,
  template_version_id uuid not null references echo.template_version(id) on delete restrict,
  opens_at            timestamptz not null,
  closes_at           timestamptz not null,
  state               text not null default 'draft'
                        check (state in ('draft','open','closed','processing','sealed','published')),
  -- A célmeghatározási (Part 1) ablak. Külön, mert a félév ELEJÉN van.
  goals_open_at       timestamptz,
  goals_close_at      timestamptz,
  created_at          timestamptz not null default now(),
  constraint echo_campaign_window_chk check (closes_at > opens_at)
);
create unique index if not exists echo_campaign_code_uidx  on echo.campaign (code);
create index        if not exists echo_campaign_state_idx  on echo.campaign (state);

-- Segédfüggvény: nyitva van-e a kitöltési ablak. Egy helyen, hogy az RPC-k és
-- a beküldés PONTOSAN ugyanazt a feltételt használják.
create or replace function echo.is_open(p_campaign uuid)
returns boolean language sql stable
set search_path = echo, public, pg_temp
as $$
  select exists (
    select 1 from echo.campaign c
     where c.id = p_campaign
       and c.state = 'open'
       and now() >= c.opens_at
       and now() <  c.closes_at
  )
$$;

create or replace function echo.is_goals_open(p_campaign uuid)
returns boolean language sql stable
set search_path = echo, public, pg_temp
as $$
  select exists (
    select 1 from echo.campaign c
     where c.id = p_campaign
       and c.state in ('draft','open')
       and now() >= coalesce(c.goals_open_at, c.opens_at)
       and now() <  coalesce(c.goals_close_at, c.closes_at)
  )
$$;


-- ============================================================
-- 5. SZAKASZ — ALKALMASSÁGI MOTOR
-- ============================================================
-- Kimenet: echo.eligibility — a ténylegesen véleményezhető kurzus–oktató párok.
-- Melléktermék, és legalább annyira fontos: echo.exclusion_log — MINDEN kizárás
-- okkal és §-hivatkozással. Ha egy oktató megkérdezi, miért nem kapott
-- visszajelzést, erre a táblára kell tudni mutatni.

create table if not exists echo.exclusion_rule (
  code          text primary key,
  name_hu       text not null,
  name_en       text,
  -- BECSLÉS: a 28/2023. szenátusi határozat szövege nem áll rendelkezésre,
  -- a paragrafusszámok pontosítandók. ADAT, nem kód — egy UPDATE javítja.
  paragraph_ref text not null,
  description_hu text,
  scope         text not null default 'course' check (scope in ('course','pair'))
);

insert into echo.exclusion_rule (code, name_hu, name_en, paragraph_ref, description_hu, scope) values
  ('LETSZAM_ALATT',
   'Létszám a küszöb alatt', 'Headcount below threshold',
   '28/2023. (PONTOSÍTANDÓ) §',                                   -- BECSLÉS
   'A kurzusra felvett hallgatók száma nem éri el a beállított küszöböt '
   '(echo.setting.min_headcount). Ilyen kis csoportban a válasz tartalma '
   'önmagában azonosítaná a kitöltőt, ezért a kurzus nem véleményezhető.',
   'course'),
  ('NINCS_ORARENDI_INFO',
   'Nincs órarendi információ', 'No timetable information',
   '28/2023. (PONTOSÍTANDÓ) §',                                   -- BECSLÉS
   'A kurzushoz nem tartozik órarendi információ (nincs kontaktóra), ezért '
   'nincs mit véleményezni.',
   'course'),
  ('VIZSGAKURZUS',
   'Vizsgakurzus', 'Exam-only course',
   '28/2023. (PONTOSÍTANDÓ) §',                                   -- BECSLÉS
   'A vizsgakurzuson nincs oktatási tevékenység, csak számonkérés.',
   'course'),
  ('OKTATOI_ARANY_ALATT',
   'Oktatói óraarány a küszöb alatt', 'Teacher share below threshold',
   '28/2023. (PONTOSÍTANDÓ) §',                                   -- BECSLÉS
   'Az oktató a kurzus óráinak kevesebb mint a beállított hányadát tartotta '
   '(echo.setting.min_share_pct), ezért a hallgatónak nincs elegendő '
   'tapasztalata a munkájáról.',
   'pair'),
  ('NINCS_OKTATO',
   'Nincs rögzített oktató', 'No teacher assigned',
   '28/2023. (PONTOSÍTANDÓ) §',                                   -- BECSLÉS
   'A kurzushoz egyetlen oktató sincs rögzítve, így oktatói értékelés nem '
   'képezhető.',
   'course')
on conflict (code) do nothing;

create table if not exists echo.exclusion_log (
  id          uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references echo.campaign(id) on delete cascade,
  course_id   uuid not null references echo.course(id)   on delete cascade,
  teacher_id  uuid references echo.teacher(id) on delete cascade,   -- NULL = az egész kurzus
  rule_code   text not null references echo.exclusion_rule(code),
  detail      jsonb not null default '{}'::jsonb,   -- {"letszam":2,"kuszob":3}
  -- Itt SZABAD az időbélyeg: ez adminisztratív napló, nem válasz.
  logged_at   timestamptz not null default now()
);
create index if not exists echo_exclusion_log_campaign_idx on echo.exclusion_log (campaign_id);
create index if not exists echo_exclusion_log_course_idx   on echo.exclusion_log (course_id);

create table if not exists echo.eligibility (
  campaign_id uuid not null references echo.campaign(id) on delete cascade,
  course_id   uuid not null references echo.course(id)   on delete cascade,
  teacher_id  uuid not null references echo.teacher(id)  on delete cascade,
  share_pct   numeric(5,2) not null,
  built_at    timestamptz not null default now(),
  primary key (campaign_id, course_id, teacher_id)
);
create index if not exists echo_eligibility_course_idx on echo.eligibility (campaign_id, course_id);

-- ------------------------------------------------------------
-- 5.1 echo.eligibility_rebuild(kampány)
-- ------------------------------------------------------------
-- Teljes újraépítés: eldobja a kampány korábbi eligibility és exclusion_log
-- sorait, majd újraszámolja. Idempotens. NYITOTT kampányon is futtatható —
-- de akkor a már kiadott jegyek egy része érvénytelenné válhat, ezért
-- figyelmeztet.
create or replace function echo.eligibility_rebuild(p_campaign uuid)
returns table (
  eligible_pairs  integer,
  eligible_courses integer,
  excluded_courses integer,
  excluded_pairs   integer
)
language plpgsql
set search_path = echo, public, pg_temp
as $$
declare
  v_term      text;
  v_state     text;
  v_min_head  integer := (select value::integer from echo.setting where key = 'min_headcount');
  v_min_share numeric := (select value::numeric from echo.setting where key = 'min_share_pct');
begin
  select c.term, c.state into v_term, v_state from echo.campaign c where c.id = p_campaign;
  if v_term is null then
    raise exception 'ECHO: nincs ilyen kampany: %', p_campaign;
  end if;
  if v_state in ('sealed','published') then
    raise exception 'ECHO: lepecsetelt/kozzetett kampany alkalmassaga nem epitheto ujra (%).', v_state;
  end if;
  if v_state = 'open' then
    raise warning 'ECHO: NYITOTT kampany alkalmassagat epited ujra. A mar kiadott jegyek '
                  'kozul azok, amelyek kikerulo kurzusra szoltak, ervenytelenne valnak.';
  end if;

  delete from echo.eligibility   where campaign_id = p_campaign;
  delete from echo.exclusion_log where campaign_id = p_campaign;

  -- A kampány félévéhez tartozó kurzusok, a tényleges létszámmal.
  -- Ugyanabban a tranzakcioban ketszer hivva a temp tabla mar letezne.
  drop table if exists _echo_c;
  drop table if exists _echo_ok;
  create temporary table _echo_c on commit drop as
  select c.id                                   as course_id,
         coalesce(c.letszam, cnt.n, 0)          as headcount,
         c.van_orarendi_info,
         c.vizsgakurzus,
         coalesce(tc.n, 0)                      as teacher_count
    from echo.course c
    left join lateral (
      select count(*)::integer as n from echo.enrollment e
       where e.course_id = c.id and e.status = 'active') cnt on true
    left join lateral (
      select count(*)::integer as n from echo.course_teacher ct
       where ct.course_id = c.id) tc on true
   where c.term = v_term;

  -- --- kurzusszintű kizárások ---
  insert into echo.exclusion_log (campaign_id, course_id, teacher_id, rule_code, detail)
  select p_campaign, course_id, null, 'LETSZAM_ALATT',
         jsonb_build_object('letszam', headcount, 'kuszob', v_min_head)
    from _echo_c where headcount < v_min_head;

  insert into echo.exclusion_log (campaign_id, course_id, teacher_id, rule_code, detail)
  select p_campaign, course_id, null, 'NINCS_ORARENDI_INFO', '{}'::jsonb
    from _echo_c where van_orarendi_info = false;

  insert into echo.exclusion_log (campaign_id, course_id, teacher_id, rule_code, detail)
  select p_campaign, course_id, null, 'VIZSGAKURZUS', '{}'::jsonb
    from _echo_c where vizsgakurzus = true;

  insert into echo.exclusion_log (campaign_id, course_id, teacher_id, rule_code, detail)
  select p_campaign, course_id, null, 'NINCS_OKTATO', '{}'::jsonb
    from _echo_c where teacher_count = 0;

  -- --- a túlélő kurzusok ---
  create temporary table _echo_ok on commit drop as
  select course_id from _echo_c
   where headcount >= v_min_head
     and van_orarendi_info = true
     and vizsgakurzus = false
     and teacher_count > 0;

  -- --- pár szintű kizárás: oktatói óraarány ---
  insert into echo.exclusion_log (campaign_id, course_id, teacher_id, rule_code, detail)
  select p_campaign, ct.course_id, ct.teacher_id, 'OKTATOI_ARANY_ALATT',
         jsonb_build_object('share_pct', ct.share_pct, 'kuszob', v_min_share)
    from echo.course_teacher ct
    join _echo_ok o on o.course_id = ct.course_id
   where ct.share_pct < v_min_share;

  -- --- a véleményezhető párok ---
  insert into echo.eligibility (campaign_id, course_id, teacher_id, share_pct)
  select p_campaign, ct.course_id, ct.teacher_id, ct.share_pct
    from echo.course_teacher ct
    join _echo_ok o on o.course_id = ct.course_id
   where ct.share_pct >= v_min_share
  on conflict (campaign_id, course_id, teacher_id) do nothing;

  -- --- a részvételi napló vázának előállítása/frissítése ---
  -- Csak az 'eligible' jelzőt állítja; az attempted/submitted mezőkhöz nem nyúl,
  -- hogy egy újraépítés ne törölje a már megtörtént kitöltés nyomát.
  insert into echo.participation (campaign_id, course_id, student_key, eligible)
  select p_campaign, e.course_id, e.student_key, true
    from echo.enrollment e
    join echo.eligibility el on el.campaign_id = p_campaign and el.course_id = e.course_id
   where e.status = 'active'
   group by e.course_id, e.student_key
  on conflict (campaign_id, course_id, student_key) do update set eligible = true;

  update echo.participation p set eligible = false
   where p.campaign_id = p_campaign
     and not exists (select 1 from echo.eligibility el
                      where el.campaign_id = p_campaign and el.course_id = p.course_id);

  return query
  select (select count(*)::integer from echo.eligibility where campaign_id = p_campaign),
         (select count(distinct course_id)::integer from echo.eligibility where campaign_id = p_campaign),
         (select count(distinct course_id)::integer from echo.exclusion_log
           where campaign_id = p_campaign and teacher_id is null),
         (select count(*)::integer from echo.exclusion_log
           where campaign_id = p_campaign and teacher_id is not null);
end $$;


-- ============================================================
-- 6. SZAKASZ — RÉSZVÉTELI NAPLÓ ÉS VÁLASZHALMAZ
-- ============================================================
--
-- A RENDSZER LELKE. Két tábla, KÖZÖS KULCS NÉLKÜL:
--
--   echo.participation — KI töltötte ki. Azonosított: student_key.
--                        Nincs benne SEMMI a válasz tartalmából.
--   echo.response      — MIT válaszolt. Nincs benne SEMMI a kitöltőről.
--                        Nincs student_key, nincs participation_id,
--                        nincs időbélyeg, nincs beküldés-azonosító.
--
-- A kettő között NINCS oszlop, amin joinolni lehetne. Ez nem véletlen és nem
-- pótolható később: ha valaha bekerül egy közös kulcs, az visszamenőleg
-- deanonimizálja az összes addigi választ.
--
-- MIÉRT NEM EGY TRANZAKCIÓ a beküldés:
--   Ha ugyanaz a tranzakció írná a naplót és a választ, akkor
--     (a) a WAL-ban a két írás egyetlen commit-rekordba kerül, tehát a
--         WAL-ból (backup, PITR, logikai dekódolás) párosíthatók;
--     (b) a két sor xmin-je azonos lenne — a rendszeroszlop 'select xmin,*'
--         paranccsal bárki számára olvasható, aki a táblát olvashatja;
--     (c) a tranzakció commit-sorrendje a két táblában ugyanaz, tehát a
--         ctid-sorrendek egymásra illeszthetők.
--
--   FIGYELEM — A SZÉTVÁLASZTÁS ÖNMAGÁBAN NEM ELÉG (mérve, nem elmélet):
--   a két hívás két EGYMÁST KÖVETŐ tranzakció, ezért az xmin-jük nem azonos,
--   hanem SZOMSZÉDOS: response.xmin = participation.xmin + 1. Ez ugyanolyan
--   jól párosít, mint az azonosság volna. Ezért KÉT további védelem kell, és
--   mindkettő a kódban van:
--     • 9.4 echo_issue_ticket a saját naplósor mellett a kurzus TELJES
--       kohorszának sorverzióját frissíti ugyanabban a tranzakcióban, így a
--       kohorsz minden sora azonos xmin-t kap (a gyanúsítottak száma 1-ről a
--       teljes létszámra nő);
--     • 6.5 echo.shuffle_responses() a válaszsorok xmin-jét ÉS fizikai (ctid)
--       sorrendjét normalizálja — ezt a NYITOTT kampány alatt is RENDSZERESEN
--       (naponta) le kell futtatni, nem csak pecsételéskor.
--   Ezért a beküldés KÉT, EGYMÁSTÓL FÜGGETLEN HÍVÁS:
--     1) echo_issue_ticket — azonosított, csak a NAPLÓRA ír (attempted),
--        és visszaad egy MAC-elt, egyszer használatos jegyet. A jegyről a
--        szerver semmit nem jegyez meg: sem a nonce-ot, sem azt, kinek adta.
--     2) echo_submit — anonim (anon szerepkör!), csak a VÁLASZHALMAZBA ír,
--        és elkölti a nonce-ot. A hívás nem tudja, ki küldte be.
--   A kettő között eltelik a kitöltés ideje (percek), tehát még az időbeli
--   egymásutániság sem ad megbízható párosítást — ezért is coarse (napi)
--   felbontású a napló időbélyege.

-- ------------------------------------------------------------
-- 6.1 Részvételi napló (AZONOSÍTOTT)
-- ------------------------------------------------------------
-- FIGYELD MEG: attempted_on és submitted_on DATE, nem timestamptz.
-- A pontos időbélyeg itt lenne a legveszélyesebb: a napló ezredmásodperces
-- attempted_at-je és a válaszok fizikai (ctid) sorrendje együtt sorrend-
-- egyeztetéssel párosítható lenne. Napi felbontás mellett egy nap összes
-- kitöltője egyetlen, megkülönböztethetetlen halmaz. Az üzemeltetéshez
-- (hol tartunk, kell-e emlékeztetőt küldeni) a napi bontás elegendő.
create table if not exists echo.participation (
  campaign_id  uuid not null references echo.campaign(id) on delete cascade,
  course_id    uuid not null references echo.course(id)   on delete cascade,
  student_key  uuid not null references public.profiles(id) on delete cascade,
  eligible     boolean not null default false,
  attempted    boolean not null default false,
  submitted    boolean not null default false,
  attempted_on date,
  submitted_on date,
  -- Hány jegyet kért összesen. Nem azonosít semmit, viszont megmutatja, ha
  -- valaki újra és újra jegyet kér (félbehagyott kitöltés vagy visszaélés).
  ticket_count integer not null default 0,
  primary key (campaign_id, course_id, student_key)
);
create index if not exists echo_participation_student_idx
  on echo.participation (student_key, campaign_id);
create index if not exists echo_participation_course_idx
  on echo.participation (campaign_id, course_id);

-- ------------------------------------------------------------
-- 6.2 Válaszhalmaz (ANONIM)
-- ------------------------------------------------------------
-- SZÁNDÉKOSAN NINCS: student_key, participation_id, submission_id,
-- created_at, updated_at, ip, user_agent, session_id, sorszám.
--
-- Egy beküldés 1 kurzusszintű + N oktatószintű sort ír. A hozzájuk tartozó
-- sorok között SINCS közös azonosító: ha lenne (submission_id), akkor egy
-- kurzusértékelés és az oktatói értékelések egymáshoz kötése egyetlen
-- kiugró szöveges válasz alapján az egész beküldést azonosíthatóvá tenné.
-- Amit ezzel elveszítünk: a "milyen kurzusértékelést adott az, aki X oktatót
-- így értékelte" típusú kereszt-elemzés. Ez tudatos ár.
--
-- DE PONTOSÍTÁS (mérve): a közös OSZLOP hiánya nem jelenti, hogy a sorok
-- összeköthetetlenek. Egy beküldés sorai ugyanabban a tranzakcióban jönnek
-- létre, ezért AZONOS az xmin-jük és SZOMSZÉDOS a ctid-jük — ez de facto
-- beküldés-azonosító. Ezt csak az echo.shuffle_responses() (6.5) bontja el,
-- amit ezért rendszeresen futtatni kell, nem csak pecsételéskor.
-- Egy harmadik csatornát viszont itt, a sémában zárunk le: az attendance_band
-- (óralátogatási sáv) korábban a kurzusszintű ÉS az oktatói sorokra is
-- ráíródott ugyanazzal az értékkel, ami külön join-kulcsként szolgált.
-- Mostantól kizárólag a kurzusszintű soron szerepelhet.
create table if not exists echo.response (
  id                  uuid primary key default gen_random_uuid(),   -- v4, NEM v7, NEM serial
  campaign_id         uuid not null references echo.campaign(id) on delete restrict,
  course_id           uuid not null references echo.course(id)  on delete restrict,
  teacher_id          uuid references echo.teacher(id) on delete restrict,  -- NULL = kurzusszintű
  template_version_id uuid not null references echo.template_version(id) on delete restrict,
  scope               text not null check (scope in ('course','teacher')),
  -- A prototípus ATTENDANCE sávja. Sáv, nem szám: a pontos óraszám azonosítana.
  attendance_band     text,
  -- A kitöltő válaszai: { "<kerdes_id>": <ertek>, ... }
  answers             jsonb not null default '{}'::jsonb,
  constraint echo_response_scope_chk
    check ((scope = 'course' and teacher_id is null)
        or (scope = 'teacher' and teacher_id is not null))
);
create index if not exists echo_response_campaign_course_idx
  on echo.response (campaign_id, course_id);
create index if not exists echo_response_teacher_idx
  on echo.response (campaign_id, teacher_id) where teacher_id is not null;
create index if not exists echo_response_answers_gin
  on echo.response using gin (answers jsonb_path_ops);

-- Az oktatoi sorokrol levesszuk az oralatogatasi savot. Ez visszamenoleg is
-- kell: a kenyszer kulonben egy mar meglevo adatbazison nem lenne felvehetok.
update echo.response set attendance_band = null
 where scope = 'teacher' and attendance_band is not null;

alter table echo.response drop constraint if exists echo_response_att_scope_chk;
alter table echo.response add constraint echo_response_att_scope_chk
  check (attendance_band is null or scope = 'course');

comment on table echo.response is
  'ANONIM valaszhalmaz. TILOS ra barmilyen idobelyeg-, sorszam- vagy '
  'kitolto-azonosito oszlopot felvenni. Lasd a fajl fejlecet, 3. szerkezeti dontes.';

-- Őrszem: ha valaki (vagy egy jövőbeli migráció) mégis időbélyeg-oszlopot
-- venne fel a válaszsorra, ez azonnal kiabál. Nem tudja megakadályozni
-- (az event trigger DDL-hez superuser kell), de a 12. szakasz ellenőrző
-- lekérdezése minden futáskor kimutatja.
create or replace function echo.response_schema_ok()
returns boolean language sql stable
set search_path = echo, public, pg_temp
as $$
  select not exists (
    select 1 from information_schema.columns
     where table_schema = 'echo' and table_name = 'response'
       and (data_type in ('timestamp with time zone','timestamp without time zone','date')
            or column_name in ('student_key','participation_id','submission_id','seq','sorszam'))
  )
$$;

-- ------------------------------------------------------------
-- 6.3 Elköltött nonce-ok (visszajátszás elleni védelem)
-- ------------------------------------------------------------
-- MIÉRT NEM SZIVÁROG: a jegy KIADÁSAKOR a szerver semmit nem tárol, tehát a
-- nonce-hoz nem tartozik student_key SEHOL. Amikor a beküldés elkölti, csak
-- annyi derül ki, hogy "ezt a nonce-ot már felhasználták" — de hogy kinek
-- adták ki, azt semmilyen tábla nem tudja. Az expires_at a JEGY sajat lejarata
-- (a kiadástól számított TTL), amit NAPRA KEREKÍTVE tárolunk, hogy még a
-- takarítás sem adjon perc — vagy akár óra — pontosságú érkezési időt.
-- MIÉRT NEM ÓRA (ez volt korábban): a nonce sora a beküldő tranzakció UTÁNI
-- altranzakcióban jön létre (spent_nonce.xmin = response.xmin + 1), tehát a
-- válaszsorhoz rendelhető; ha az expires_at órára kerekített, abból a jegy
-- kiadásának ÓRÁJA visszaszámolható — vagyis a válasz óra pontossággal
-- datálható lenne, holott a 3. szerkezeti döntés szerint nincs rajta időbélyeg.
-- Napi felbontással ez a napló DATE felbontásával egyezik, tehát nem ad többet.
create table if not exists echo.spent_nonce (
  nonce      uuid primary key,
  expires_at timestamptz not null
);
create index if not exists echo_spent_nonce_exp_idx on echo.spent_nonce (expires_at);

create or replace function echo.gc_spent_nonce()
returns integer language plpgsql
set search_path = echo, public, pg_temp
as $$
declare n integer;
begin
  delete from echo.spent_nonce where expires_at < now() - interval '1 day';
  get diagnostics n = row_count;
  return n;
end $$;

-- ------------------------------------------------------------
-- 6.4 echo.mark_submitted(kampány) — kötegelt, cron/kézi hívásra
-- ------------------------------------------------------------
-- MIT TUD ÉS MIT NEM:
--   NEM tudja megmondani, hogy EGY adott hallgató beküldött-e. Nem is
--   tudhatja: pontosan ezért nincs közös kulcs. Ha valaha egyenként jelölni
--   akarjuk, azzal az anonimitás megszűnik.
--   AMIT TUD: kurzusonként összeveti a beérkezett kurzusszintű válaszok
--   számát a KIADOTT JEGYEK számával (sum(ticket_count)), NEM a próbálkozó
--   hallgatók számával. Csak akkor jelöl, ha a kettő PONTOSAN egyezik.
--
--   MIÉRT EZ A HELYES KÜSZÖB — a bizonyítás:
--     Egy jegy nonce-a egyszer költhető el (6.3 spent_nonce elsődleges kulcs),
--     tehát egy jegyből LEGFELJEBB egy kurzusszintű válasz születhet, és válasz
--     csak érvényes jegyből születhet. Ebből: resp <= T, ahol T a kiadott jegyek
--     száma. Ha resp = T, akkor MINDEN kiadott jegyet elköltöttek, tehát minden
--     próbálkozó hallgató elköltötte az összes sajátját — vagyis mindenki
--     beküldött. Ez logikailag zárt.
--
--   MIÉRT NEM 'resp >= att' ÉS MIÉRT NEM 'resp = att' (mindkettőt LEMÉRTÜK):
--     Mindkettő a hallgatók számához hasonlít, a válaszok viszont a JEGYEKHEZ
--     tartoznak, és egy hallgató több jegyet kaphat (max_tickets_per_course = 2).
--     Ezért egyetlen kétszer beküldő hallgató PONTOSAN kompenzál egy soha be nem
--     küldőt: att = 2, resp = 2, az egyezés tökéletes — és a rendszer mégis
--     'submitted'-nek jelöl valakit, aki soha nem töltött ki semmit. Az illető
--     onnantól ECHO_ALREADY_SUBMITTED-tel VÉGLEG kizárja magát a kitöltésből,
--     és a részvételi statisztika is hamis. A jegyalapú számlálásnál ugyanez a
--     helyzet T = 3, resp = 2 — nincs egyezés, tehát helyesen NEM jelöl.
--
--   AZ ÁR: ha valaki jegyet kér, de nem küld be (bezárja a böngészőt), a kurzus
--   addig nem jelölhető, amíg be nem küldi vagy le nem zárul a kampány. Ez
--   tudatosan konzervatív: inkább ne jelöljön, mint hogy hamisan jelöljön —
--   a hamis jelölés ugyanis visszafordíthatatlanul kizár egy hallgatót.
create or replace function echo.mark_submitted(p_campaign uuid)
returns table (
  course_id      uuid,
  attempted_cnt  integer,
  response_cnt   integer,
  marked         integer,
  megjegyzes     text
)
language plpgsql
set search_path = echo, public, pg_temp
as $$
declare r record; v_marked integer;
begin
  for r in
    select p.course_id,
           count(*) filter (where p.attempted)::integer as att,
           -- A KIADOTT JEGYEK szama. Ehhez hasonlitunk, nem a hallgatokehoz.
           coalesce(sum(p.ticket_count) filter (where p.attempted), 0)::integer as tickets,
           coalesce((select count(*) from echo.response x
                      where x.campaign_id = p_campaign
                        and x.course_id = p.course_id
                        and x.scope = 'course'), 0)::integer as resp
      from echo.participation p
     where p.campaign_id = p_campaign
     group by p.course_id
  loop
    if r.att = 0 then
      return query select r.course_id, r.att, r.resp, 0, 'nincs próbálkozás'::text;
    elsif r.resp = r.tickets then
      update echo.participation p
         set submitted = true,
             submitted_on = coalesce(p.submitted_on, current_date)
       where p.campaign_id = p_campaign and p.course_id = r.course_id and p.attempted
         and p.submitted = false;
      get diagnostics v_marked = row_count;
      return query select r.course_id, r.att, r.resp, v_marked,
        format('beküldöttnek jelölve (mind a %s kiadott jegy elköltve)', r.tickets)::text;
    elsif r.resp > r.tickets then
      -- Ez elvben LEHETETLEN (egy jegy egyszer költhető el). Ha mégis
      -- előfordul, az adatintegritási hiba — ilyenkor semmiképp nem jelölünk.
      return query select r.course_id, r.att, r.resp, 0,
        format('ADATHIBA: több válasz (%s), mint kiadott jegy (%s) — NEM jelölve',
               r.resp, r.tickets)::text;
    else
      return query select r.course_id, r.att, r.resp, 0,
        format('%s válasz a %s kiadott jegyből (%s hallgató) — van be nem küldött jegy, nem jelölve',
               r.resp, r.tickets, r.att)::text;
    end if;
  end loop;
end $$;

-- ------------------------------------------------------------
-- 6.5 echo.shuffle_responses(kampány) — a ctid-sorrend megszüntetése
-- ------------------------------------------------------------
-- A random uuid v4 kulcs nem hordoz sorrendet, de KÉT rendszerszintű nyom
-- igen, és mindkettőt ez a függvény tünteti el:
--   • a HEAP fizikai sorrendje: 'select ctid,* from echo.response order by ctid'
--     visszaadja a beérkezés sorrendjét;
--   • az xmin rendszeroszlop: a beküldő tranzakció azonosítója, ami a
--     részvételi napló xmin-jével párosítva DEANONIMIZÁL (lásd a 6. szakasz
--     fejlécét). Az újraírás után minden sor ugyanazt az xmin-t kapja.
--
-- MIKOR FUTTASD:
--   • a kampány lepecsételésekor (state = 'sealed') — KÖTELEZŐ; és
--   • a NYITOTT kampány alatt is RENDSZERESEN, naponta egyszer. Ez nem
--     opcionális szépítés: enélkül a nyitott ablak teljes ideje alatt a friss
--     válaszok xmin-je azonosítja a kitöltőt.
-- KIZÁRÓLAGOS ZÁRAT kér az érintett sorokra, ezért válaszd hozzá a legkisebb
-- forgalmú időszakot (éjszaka). Egy kampányra szűkítve fut, hogy egy másik,
-- épp nyitott kampány adatát ne érintse.
--
-- FIGYELEM: a szignatúra megváltozott (paraméter nélküliről kampányra), ezért
-- a régi változatot előbb el kell dobni — a 'create or replace' nem elég.
drop function if exists echo.shuffle_responses();

create or replace function echo.shuffle_responses(p_campaign uuid default null)
returns integer language plpgsql
set search_path = echo, public, pg_temp
as $$
declare n integer;
begin
  drop table if exists _echo_r_shuffle;
  create temporary table _echo_r_shuffle on commit drop as
    select * from echo.response
     where p_campaign is null or campaign_id = p_campaign
     order by random();
  select count(*) into n from _echo_r_shuffle;
  -- DELETE es nem TRUNCATE: szurni akarunk egy kampanyra, a truncate viszont
  -- a teljes tablat uritene — egy masik, epp nyitott kampany valaszaival egyutt.
  -- A sorok igy is a heap vegere, uj fizikai sorrendbe kerulnek.
  delete from echo.response
   where p_campaign is null or campaign_id = p_campaign;
  insert into echo.response select * from _echo_r_shuffle;
  return n;
end $$;


-- ============================================================
-- 7. SZAKASZ — CÉLKITŰZÉS (Part 1) — SZÁNDÉKOSAN NEM ANONIM
-- ============================================================
-- A félév eleji célmeghatározás a hallgató SAJÁT eszköze: vissza kell tudnia
-- nézni, mit tűzött ki. Ezért a student_goal a hallgatóhoz van kötve, és
-- időbélyege is van — ez NEM a válaszhalmaz.
--
-- A HATÁR, AMIT NEM LÉPÜNK ÁT: a félév végi beküldéskor a célok SZÖVEGE NEM
-- megy át a válaszba, és a célok SZÁMOSSÁGA (1, 2 vagy 3 cél) SEM. A számosság
-- kvázi-azonosító: a student_goal táblából látszik, ki hány célt írt, tehát
-- egy "3 célt tűzött ki" jelzés a válaszban a hallgatók egy szűk részhalmazára
-- szűkít. Csak egyetlen, összevont TELJESÜLÉSI ÖSSZEGZÉS megy át
-- (nem_teljesult / reszben / teljesult / tulteljesult) — ezt az
-- echo_submit() a payloadból veszi, és a 9. szakasz ki is kényszeríti.
create table if not exists echo.student_goal (
  id           uuid primary key default gen_random_uuid(),
  campaign_id  uuid not null references echo.campaign(id) on delete cascade,
  course_id    uuid not null references echo.course(id)   on delete cascade,
  student_key  uuid not null references public.profiles(id) on delete cascade,
  -- goals:        ["...", "...", "..."]  1–3 elem
  -- expectations: ["...", "...", "..."]  1–3 elem  (oktatói elvárások)
  goals        jsonb not null default '[]'::jsonb,
  expectations jsonb not null default '[]'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint echo_goal_shape_chk check (
    jsonb_typeof(goals) = 'array' and jsonb_typeof(expectations) = 'array'
    and jsonb_array_length(goals) <= 3 and jsonb_array_length(expectations) <= 3
  )
);
create unique index if not exists echo_student_goal_uidx
  on echo.student_goal (campaign_id, course_id, student_key);


-- ============================================================
-- 8. SZAKASZ — JEGYKIADÁS ÉS BEKÜLDÉS (belső mechanika)
-- ============================================================
-- A jegy alakja:   base64(payload_json) || '.' || base64(hmac_sha256)
-- A payload_json:  {"c":<kampány>,"k":<kurzus>,"v":<template_version>,
--                   "n":<nonce uuid>,"e":<lejárat epoch másodpercben>}
-- A payload SZÁNDÉKOSAN NEM tartalmaz hallgatói azonosítót — a beküldő
-- oldal így akkor sem tudná megtudni, ki tölti ki, ha akarná.
--
-- MIÉRT nem sima titkosítás: a jegynek nem titkosnak kell lennie, hanem
-- HAMISÍTHATATLANNAK. A tartalma (melyik kampány, melyik kurzus) a kitöltő
-- előtt amúgy is ismert. A HMAC pontosan ezt adja, és a szerver nem tárol
-- semmit a kiadáskor.

create or replace function echo.ticket_sign(p_payload text)
returns text language sql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
  -- Az encode(...,'base64') 76 karakterenként sortörést tesz be; a jegynek
  -- egyetlen sornak kell lennie, ezért kiszedjük.
  select translate(encode(hmac(convert_to(p_payload,'utf8'), echo.ticket_key(), 'sha256'), 'base64'),
                   E'\n\r', '')
$$;

create or replace function echo.ticket_make(p_campaign uuid, p_course uuid,
                                            p_version uuid, p_ttl_min integer)
returns text language sql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
  with p as (
    select (jsonb_build_object(
              'c', p_campaign, 'k', p_course, 'v', p_version,
              'n', gen_random_uuid(),
              'e', floor(extract(epoch from now() + make_interval(mins => p_ttl_min)))::bigint
            ))::text as j
  )
  select translate(encode(convert_to(j,'utf8'),'base64'), E'\n\r', '') || '.' || echo.ticket_sign(j)
    from p
$$;

-- Ellenőrzés: visszaadja a payloadot, ha a MAC stimmel; különben kivételt dob.
create or replace function echo.ticket_open(p_ticket text)
returns jsonb language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_dot int; v_b64 text; v_mac text; v_json text;
begin
  if p_ticket is null then raise exception 'ECHO_TICKET_INVALID'; end if;
  v_dot := position('.' in p_ticket);
  if v_dot < 2 then raise exception 'ECHO_TICKET_INVALID'; end if;
  v_b64 := substring(p_ticket from 1 for v_dot - 1);
  v_mac := substring(p_ticket from v_dot + 1);
  begin
    v_json := convert_from(decode(v_b64, 'base64'), 'utf8');
  exception when others then
    raise exception 'ECHO_TICKET_INVALID';
  end;
  -- Az összehasonlítás nem konstans idejű. Reális fenyegetésnek nem tartjuk:
  -- a támadónak sok ezer, hálózaton mért kísérlet kellene egyetlen jegy
  -- hamisításához, miközben a kampányablak véges és a kísérletek a
  -- PostgREST logban látszanak. Ha mégis kell, a pgcrypto-ban nincs rá
  -- beépített függvény — ott egy XOR-alapú, teljes hosszon végigmenő
  -- összehasonlítást kell írni.
  if echo.ticket_sign(v_json) <> v_mac then
    raise exception 'ECHO_TICKET_BADSIG';
  end if;
  return v_json::jsonb;
end $$;


-- ============================================================
-- 9. SZAKASZ — PUBLIC RPC-K (a frontend EGYETLEN belépési pontja)
-- ============================================================
--
-- JOGOSULTSÁG — ÉS AMI MÉG NINCS:
--   A hallgatói RPC-k (echo_my_courses, echo_get_form, echo_issue_ticket,
--   echo_save_goals) KIZÁRÓLAG a hívó SAJÁT adatára dolgoznak: mindenütt
--   auth.uid() a szűrő, paraméterből hallgatót átadni nem lehet.
--   A MIR/admin RPC-k (echo_campaigns, echo_rate, echo_rebuild_eligibility)
--   EGYELŐRE a meglévő public.is_staff() / public.is_admin() függvényekre
--   épülnek — vagyis a SUPERADMIN/ADMIN/ADMISSIONS/FINANCE szerepkörökre.
--   EZ IDEIGLENES. Az ECHO-nak saját szerepkör-dimenziója lesz
--   (ECHO_ADMIN — kampányt indít; ECHO_MIR — aggregált eredményt lát;
--   ECHO_DEKAN — csak a saját kara; OKTATO — csak a saját kurzusai), mert az
--   UniPortal FINANCE szerepköre nyilvánvalóan nem való oktatói
--   visszajelzésekhez. Az echo.teacher.profile_id oszlop már fel van véve
--   ehhez. Amíg ez nincs kész, a MIR-RPC-k SEMMILYEN válasz-TARTALMAT nem
--   adnak vissza — csak darabszámot és arányt (lásd echo_rate).

-- ------------------------------------------------------------
-- 9.1 echo_my_courses() — a bejelentkezett hallgató kurzusai + állapot
-- ------------------------------------------------------------
create or replace function public.echo_my_courses()
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_me uuid := auth.uid(); v_out jsonb;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;

  select coalesce(jsonb_agg(x order by x->>'closes_at', x->>'course_name'), '[]'::jsonb)
    into v_out
  from (
    select jsonb_build_object(
             'campaign_id',    c.id,
             'campaign_code',  c.code,
             'campaign_name',  c.name_hu,
             'campaign_state', c.state,
             'term',           c.term,
             'opens_at',       c.opens_at,
             'closes_at',      c.closes_at,
             'is_open',        echo.is_open(c.id),
             'is_goals_open',  echo.is_goals_open(c.id),
             'course_id',      k.id,
             'course_code',    k.code,
             'course_name',    k.name_hu,
             'course_name_en', k.name_en,
             'lang',           k.lang,
             'teacher_count',  (select count(*) from echo.eligibility el
                                 where el.campaign_id = c.id and el.course_id = k.id),
             'goals_saved',    exists (select 1 from echo.student_goal g
                                        where g.campaign_id = c.id and g.course_id = k.id
                                          and g.student_key = v_me
                                          and jsonb_array_length(g.goals) > 0),
             'attempted',      p.attempted,
             'submitted',      p.submitted,
             -- Osszefoglalo allapot a felulet szamara:
             'allapot',
               case when p.submitted                      then 'kitoltve'
                    when echo.is_open(c.id) and p.attempted then 'folyamatban'
                    when echo.is_open(c.id)                then 'kitoltheto'
                    when echo.is_goals_open(c.id)          then 'celkituzes'
                    when c.state in ('closed','processing','sealed','published') then 'lezart'
                    else 'nem_nyitott' end
           ) as x
      from echo.participation p
      join echo.campaign c on c.id = p.campaign_id
      join echo.course   k on k.id = p.course_id
     where p.student_key = v_me
       and p.eligible
       and c.state <> 'draft'
  ) s;

  return v_out;
end $$;

-- ------------------------------------------------------------
-- 9.2 echo_get_form(kampány, kurzus) — kérdőív + oktatók + saját célok
-- ------------------------------------------------------------
create or replace function public.echo_get_form(p_campaign uuid, p_course uuid)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_me uuid := auth.uid(); v_p echo.participation%rowtype; v_c echo.campaign%rowtype; v_out jsonb;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;

  select * into v_p from echo.participation
   where campaign_id = p_campaign and course_id = p_course and student_key = v_me;
  if not found or not v_p.eligible then raise exception 'ECHO_NOT_ELIGIBLE'; end if;

  select * into v_c from echo.campaign where id = p_campaign;
  if v_c.state = 'draft' then raise exception 'ECHO_CAMPAIGN_NOT_READY'; end if;

  select jsonb_build_object(
           'campaign', jsonb_build_object(
              'id', v_c.id, 'code', v_c.code, 'name', v_c.name_hu, 'term', v_c.term,
              'state', v_c.state, 'opens_at', v_c.opens_at, 'closes_at', v_c.closes_at,
              'is_open', echo.is_open(v_c.id), 'is_goals_open', echo.is_goals_open(v_c.id)),
           'course', (select jsonb_build_object(
                        'id', k.id, 'code', k.code, 'name', k.name_hu,
                        'name_en', k.name_en, 'lang', k.lang, 'term', k.term)
                        from echo.course k where k.id = p_course),
           -- Csak az ALKALMAS oktatók (a 25% alattiak nem jelennek meg).
           'teachers', (select coalesce(jsonb_agg(jsonb_build_object(
                          'id', t.id, 'name', t.name, 'title', t.title,
                          'share_pct', el.share_pct) order by t.name), '[]'::jsonb)
                          from echo.eligibility el
                          join echo.teacher t on t.id = el.teacher_id
                         where el.campaign_id = p_campaign and el.course_id = p_course),
           -- A kérdőív VÁLTOZATLAN pillanatképe — a frontend közvetlenül rendereli.
           'form', (select tv.compiled from echo.template_version tv
                     where tv.id = v_c.template_version_id),
           'template_version_id', v_c.template_version_id,
           -- A SAJÁT célok (azonosított hívás, ezért szabad).
           'goals', coalesce((select jsonb_build_object('goals', g.goals, 'expectations', g.expectations)
                                from echo.student_goal g
                               where g.campaign_id = p_campaign and g.course_id = p_course
                                 and g.student_key = v_me),
                             jsonb_build_object('goals','[]'::jsonb,'expectations','[]'::jsonb)),
           'participation', jsonb_build_object(
              'attempted', v_p.attempted, 'submitted', v_p.submitted)
         )
    into v_out;
  return v_out;
end $$;

-- ------------------------------------------------------------
-- 9.3 echo_save_goals(kampány, kurzus, célok, elvárások) — Part 1
-- ------------------------------------------------------------
create or replace function public.echo_save_goals(p_campaign uuid, p_course uuid,
                                                  p_goals jsonb, p_expectations jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;
  if not exists (select 1 from echo.participation
                  where campaign_id = p_campaign and course_id = p_course
                    and student_key = v_me and eligible) then
    raise exception 'ECHO_NOT_ELIGIBLE';
  end if;
  if not echo.is_goals_open(p_campaign) then raise exception 'ECHO_GOALS_CLOSED'; end if;

  if jsonb_typeof(p_goals) <> 'array' or jsonb_typeof(p_expectations) <> 'array' then
    raise exception 'ECHO_BAD_PAYLOAD';
  end if;
  if jsonb_array_length(p_goals) > 3 or jsonb_array_length(p_expectations) > 3 then
    raise exception 'ECHO_TOO_MANY_GOALS';
  end if;

  insert into echo.student_goal (campaign_id, course_id, student_key, goals, expectations)
  values (p_campaign, p_course, v_me, p_goals, p_expectations)
  on conflict (campaign_id, course_id, student_key)
  do update set goals = excluded.goals,
                expectations = excluded.expectations,
                updated_at = now();

  return jsonb_build_object('ok', true,
                            'goals', jsonb_array_length(p_goals),
                            'expectations', jsonb_array_length(p_expectations));
end $$;

-- ------------------------------------------------------------
-- 9.4 echo_issue_ticket(kampány, kurzus) — AZONOSÍTOTT, csak a naplóra ír
-- ------------------------------------------------------------
create or replace function public.echo_issue_ticket(p_campaign uuid, p_course uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_me   uuid := auth.uid();
  v_ttl  integer := (select value::integer from echo.setting where key = 'ticket_ttl_minutes');
  v_max  integer := (select value::integer from echo.setting where key = 'max_tickets_per_course');
  v_ver  uuid;
  v_tkt  text;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;
  if not echo.is_open(p_campaign) then raise exception 'ECHO_CAMPAIGN_CLOSED'; end if;

  if not exists (select 1 from echo.participation
                  where campaign_id = p_campaign and course_id = p_course
                    and student_key = v_me and eligible) then
    raise exception 'ECHO_NOT_ELIGIBLE';
  end if;
  -- A 'submitted' jelzőt a kötegelt echo.mark_submitted() teszi fel; addig a
  -- rendszer NEM tudja, ki küldött be. Ha már fel van téve, ne adjunk új jegyet.
  if exists (select 1 from echo.participation
              where campaign_id = p_campaign and course_id = p_course
                and student_key = v_me and submitted) then
    raise exception 'ECHO_ALREADY_SUBMITTED';
  end if;

  -- JEGYSZAM-KORLAT. Enelkul egy hallgato tetszoleges szamu jegyet kerhet es
  -- tetszoleges sokszor bekuldhet ugyanarra a kurzusra: ez egyreszt szavazat-
  -- sokszorozas, masreszt — es ez a sulyosabb — elrontja az echo.mark_submitted()
  -- kotegelt szamlalasat, ami ilyenkor MAS, be nem kuldo hallgatot is
  -- 'submitted'-nek jelolne, orokre kizarva ot a kitoltesbol.
  if coalesce((select ticket_count from echo.participation
                where campaign_id = p_campaign and course_id = p_course
                  and student_key = v_me), 0) >= v_max then
    raise exception 'ECHO_TICKET_LIMIT';
  end if;

  select template_version_id into v_ver from echo.campaign where id = p_campaign;

  -- CSAK A NAPLÓRA ÍRUNK. A jegyről (nonce, lejárat) semmit nem tárolunk:
  -- ha tárolnánk, a nonce összekötné a hallgatót a beküldött válasszal.
  -- Sorosítjuk a kurzus jegykiadasait. Ket okbol: (a) a lenti kohorsz-szintu
  -- UPDATE-ek kulonbozo sorrendben erhetnek el a sorokat, ami holtponthoz
  -- vezethetne; (b) a ticket_count ellenorzese es novelese igy egyutt atomos.
  perform pg_advisory_xact_lock(hashtext('echo_ticket:' || p_course::text));

  update echo.participation
     set attempted = true,
         attempted_on = coalesce(attempted_on, current_date),
         ticket_count = ticket_count + 1
   where campaign_id = p_campaign and course_id = p_course and student_key = v_me;

  -- ===== xmin-VEDELEM — NE TAVOLITSD EL =====
  -- A Postgres minden sorban tarolja a beszuro/modosito tranzakcio azonositojat
  -- (xmin rendszeroszlop), amit BARKI kiolvashat, aki a tablat olvashatja
  -- ('select xmin, * from ...'). Mivel a jegykiadas es a bekuldes ket EGYMAST
  -- KOVETO tranzakcio, e vedelem nelkul a sajat naplosor xmin-je es a valaszsor
  -- xmin-je szomszedos (response.xmin = participation.xmin + 1) — ez idobelyeg
  -- NELKUL is hezagmentesen parositja a kitoltot a valaszaval. LEMERTUK: egy
  -- hatsoros join mindharom tesztkitolto e-mail cimet visszaadta.
  -- Az ellenszer: ugyanebben a tranzakcioban a kurzus TELJES kohorszanak
  -- sorverziojat frissitjuk, igy a kohorsz minden sora AZONOS xmin-t kap, es a
  -- join a teljes anonimitas-halmazt adja vissza egyetlen szemely helyett.
  -- (Ara: kurzusonkent N halott sorverzio jegykiadasonkent — az autovacuum
  -- kezeli, 200 fos kurzusnal is elhanyagolhato.)
  update echo.participation
     set eligible = eligible
   where campaign_id = p_campaign and course_id = p_course
     and student_key <> v_me and eligible;

  v_tkt := echo.ticket_make(p_campaign, p_course, v_ver, v_ttl);

  return jsonb_build_object(
    'ticket', v_tkt,
    'ttl_minutes', v_ttl,
    'template_version_id', v_ver,
    -- Emlékeztető a frontendnek: a beküldés MÁS klienssel megy (lásd fejléc).
    'submit_hint', 'Az echo_submit hivast munkamenet nelkuli (anon) klienssel kuldd.');
end $$;

-- ------------------------------------------------------------
-- 9.5 echo_submit(jegy, payload) — ANONIM, csak a válaszhalmazba ír
-- ------------------------------------------------------------
-- A payload alakja:
--   { "attendance": "51-75",
--     "course":   { "<kerdes_id>": <ertek>, ... },
--     "teachers": [ { "teacher": "<uuid>", "skipped": false,
--                     "skip_reason": null, "answers": { ... } }, ... ] }
create or replace function public.echo_submit(p_ticket text, p_payload jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_t         jsonb;
  v_campaign  uuid; v_course uuid; v_ver uuid; v_nonce uuid; v_exp bigint;
  v_att       text;
  v_course_a  jsonb;
  v_teachers  jsonb;
  v_item      jsonb;
  v_tid       uuid;
  v_n         integer := 0;
  -- A célteljesülés EGYETLEN megengedett átvitele a Part 1-ből. A célok
  -- szövege és SZÁMOSSÁGA nem jöhet át — a számosság kvázi-azonosító.
  v_goals_met text;
begin
  -- 1) a jegy hitelessége
  v_t := echo.ticket_open(p_ticket);          -- hibás MAC → ECHO_TICKET_BADSIG
  v_campaign := (v_t->>'c')::uuid;
  v_course   := (v_t->>'k')::uuid;
  v_ver      := (v_t->>'v')::uuid;
  v_nonce    := (v_t->>'n')::uuid;
  v_exp      := (v_t->>'e')::bigint;

  if to_timestamp(v_exp) < now() then raise exception 'ECHO_TICKET_EXPIRED'; end if;
  if not echo.is_open(v_campaign) then raise exception 'ECHO_CAMPAIGN_CLOSED'; end if;

  -- 2) a nonce elköltése ELSŐKÉNT — így egy párhuzamos visszajátszás elbukik,
  --    mielőtt bármilyen válasz beíródna. Az expires_at NAPRA KEREKÍTVE megy be,
  --    hogy a takarítási mező se adjon perc vagy óra pontosságú érkezési időt
  --    (a napló attempted_on-ja is DATE, tehát ez konzisztens vele).
  begin
    insert into echo.spent_nonce (nonce, expires_at)
    values (v_nonce, date_trunc('day', to_timestamp(v_exp)) + interval '2 days');
  exception when unique_violation then
    raise exception 'ECHO_TICKET_SPENT';
  end;

  -- 3) a payload alakja és mérete
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'ECHO_BAD_PAYLOAD';
  end if;
  if pg_column_size(p_payload) > 65536 then raise exception 'ECHO_PAYLOAD_TOO_LARGE'; end if;

  v_att      := nullif(p_payload->>'attendance', '');
  v_course_a := coalesce(p_payload->'course', '{}'::jsonb);
  v_teachers := coalesce(p_payload->'teachers', '[]'::jsonb);
  if jsonb_typeof(v_course_a) <> 'object' or jsonb_typeof(v_teachers) <> 'array' then
    raise exception 'ECHO_BAD_PAYLOAD';
  end if;

  -- 4) TISZTÍTÁS. Ami azonosíthat, azt itt vágjuk le — nem a frontendben.
  --    A frontend jóhiszemű, de nem ő a védvonal.
  v_goals_met := v_course_a->>'goals_met';
  if v_goals_met is not null
     and v_goals_met not in ('nem_teljesult','reszben','teljesult','tulteljesult') then
    raise exception 'ECHO_BAD_GOALS_MET';
  end if;
  v_course_a := v_course_a
    - 'goals' - 'goal_texts' - 'goals_text' - 'goal_count' - 'goals_count'
    - 'expectations' - 'expectation_texts' - 'student' - 'student_key'
    - 'email' - 'name' - 'neptun' - 'user_id' - 'uid'
    - 'created_at' - 'submitted_at' - 'timestamp' - 'ts';

  -- 5) kurzusszintű válaszsor
  insert into echo.response (campaign_id, course_id, teacher_id, template_version_id,
                             scope, attendance_band, answers)
  values (v_campaign, v_course, null, v_ver, 'course', v_att, v_course_a);
  v_n := v_n + 1;

  -- 6) oktatószintű válaszsorok
  for v_item in select * from jsonb_array_elements(v_teachers) loop
    v_tid := nullif(v_item->>'teacher','')::uuid;
    if v_tid is null then continue; end if;
    -- Csak ALKALMAS oktatóra fogadunk el választ (a 25% alattiakra nem).
    if not exists (select 1 from echo.eligibility
                    where campaign_id = v_campaign and course_id = v_course
                      and teacher_id = v_tid) then
      raise exception 'ECHO_TEACHER_NOT_ELIGIBLE';
    end if;
    insert into echo.response (campaign_id, course_id, teacher_id, template_version_id,
                               scope, attendance_band, answers)
    -- attendance_band SZANDEKOSAN null: ha ideirnank a v_att-ot, az azonos ertek
    -- egy bekuldes sorait egymashoz kotne (lasd 6.2). A savot a kurzusszintu
    -- sor hordozza, egyszer.
    values (v_campaign, v_course, v_tid, v_ver, 'teacher', null,
            (coalesce(v_item->'answers','{}'::jsonb)
              - 'student' - 'student_key' - 'email' - 'name' - 'neptun' - 'user_id' - 'uid'
              - 'created_at' - 'submitted_at' - 'timestamp' - 'ts')
            || jsonb_build_object('skipped', coalesce(v_item->'skipped','false'::jsonb),
                                  'skip_reason', coalesce(v_item->'skip_reason','null'::jsonb)));
    v_n := v_n + 1;
  end loop;

  -- A visszatérés NEM tartalmaz sorazonosítót: ha visszaadnánk a response.id-t,
  -- a kliens (és bárki, aki a hálózati naplót látja) össze tudná kötni a
  -- beküldő munkamenetét egy konkrét válaszsorral.
  return jsonb_build_object('ok', true, 'rows', v_n);
end $$;

-- ------------------------------------------------------------
-- 9.6 MIR / admin RPC-k
-- ------------------------------------------------------------
create or replace function public.echo_campaigns()
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_out jsonb;
begin
  -- is_admin() es NEM is_staff(): a menuben az 'ECHO kampanyok' csak
  -- SUPERADMIN/ADMIN-nak latszik, az is_staff() viszont az ADMISSIONS-t es a
  -- FINANCE-t is beengedne — vagyis ok a bongeszo konzoljabol elerhetnek egy
  -- olyan RPC-t, amit a felulet szerint nem lathatnak. A felulet es az API
  -- hatarat egy helyre hozzuk. (Tartalom eddig sem szivargott: mindket RPC
  -- kizarolag darabszamot ad vissza.)
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  select coalesce(jsonb_agg(x order by x->>'opens_at' desc), '[]'::jsonb) into v_out
  from (
    select jsonb_build_object(
             'id', c.id, 'code', c.code, 'name', c.name_hu, 'term', c.term,
             'state', c.state, 'opens_at', c.opens_at, 'closes_at', c.closes_at,
             'is_open', echo.is_open(c.id),
             'template_version_id', c.template_version_id,
             'eligible_courses', (select count(distinct course_id) from echo.eligibility
                                   where campaign_id = c.id),
             'eligible_pairs',   (select count(*) from echo.eligibility where campaign_id = c.id),
             'eligible_students',(select count(*) from echo.participation
                                   where campaign_id = c.id and eligible),
             'attempted',        (select count(*) from echo.participation
                                   where campaign_id = c.id and attempted),
             'responses',        (select count(*) from echo.response
                                   where campaign_id = c.id and scope = 'course'),
             'excluded_courses', (select count(distinct course_id) from echo.exclusion_log
                                   where campaign_id = c.id and teacher_id is null),
             'kitoltesi_arany',  round(
                (select count(*) from echo.response where campaign_id = c.id and scope='course')::numeric
                / nullif((select count(*) from echo.participation
                           where campaign_id = c.id and eligible), 0) * 100, 1)
           ) as x
      from echo.campaign c
  ) s;
  return v_out;
end $$;

-- echo_rate: részvételi arány EREDMÉNY NÉLKÜL. A nyitott ablak alatt is
-- hívható, mert kizárólag DARABSZÁMOKAT ad vissza — egyetlen válasz tartalma
-- sem szivárog ki rajta. Ez tudatos: a kitöltésre buzdító kommunikációnak
-- kell egy szám, az eredménynek viszont nem szabad menet közben látszania.
create or replace function public.echo_rate(p_campaign uuid)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_out jsonb;
begin
  -- is_admin() es NEM is_staff(): a menuben az 'ECHO kampanyok' csak
  -- SUPERADMIN/ADMIN-nak latszik, az is_staff() viszont az ADMISSIONS-t es a
  -- FINANCE-t is beengedne — vagyis ok a bongeszo konzoljabol elerhetnek egy
  -- olyan RPC-t, amit a felulet szerint nem lathatnak. A felulet es az API
  -- hatarat egy helyre hozzuk. (Tartalom eddig sem szivargott: mindket RPC
  -- kizarolag darabszamot ad vissza.)
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  select jsonb_build_object(
    'campaign_id', p_campaign,
    'osszesen', jsonb_build_object(
      'eligible',  (select count(*) from echo.participation where campaign_id=p_campaign and eligible),
      'attempted', (select count(*) from echo.participation where campaign_id=p_campaign and attempted),
      'submitted', (select count(*) from echo.participation where campaign_id=p_campaign and submitted),
      'valaszok',  (select count(*) from echo.response where campaign_id=p_campaign and scope='course')),
    'kurzusonkent', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'course_id', k.id, 'course_code', k.code, 'course_name', k.name_hu,
               'eligible',  (select count(*) from echo.participation p
                              where p.campaign_id=p_campaign and p.course_id=k.id and p.eligible),
               'attempted', (select count(*) from echo.participation p
                              where p.campaign_id=p_campaign and p.course_id=k.id and p.attempted),
               'valaszok',  (select count(*) from echo.response r
                              where r.campaign_id=p_campaign and r.course_id=k.id and r.scope='course')
             ) order by k.code), '[]'::jsonb)
        from echo.course k
       where exists (select 1 from echo.eligibility el
                      where el.campaign_id=p_campaign and el.course_id=k.id))
  ) into v_out;
  return v_out;
end $$;

-- Extra (a feladat listáján felül, de üzemeltetéshez kell): az alkalmassági
-- motor elindítása a felületről, admin joggal.
create or replace function public.echo_rebuild_eligibility(p_campaign uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare r record;
begin
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  select * into r from echo.eligibility_rebuild(p_campaign);
  return jsonb_build_object('eligible_pairs', r.eligible_pairs,
                            'eligible_courses', r.eligible_courses,
                            'excluded_courses', r.excluded_courses,
                            'excluded_pairs', r.excluded_pairs);
end $$;


-- ============================================================
-- 10. SZAKASZ — GRANTOK (a legkényesebb rész)
-- ============================================================
-- Postgresben MINDEN újonnan létrehozott függvény EXECUTE jogot ad a PUBLIC
-- szerepkörnek. Ezért minden egyes függvényről előbb visszavesszük, majd
-- célzottan adjuk oda. Egy kihagyott revoke itt csendes lyuk.
do $grants$
declare
  f record;
  has_anon bool := exists (select 1 from pg_roles where rolname='anon');
  has_auth bool := exists (select 1 from pg_roles where rolname='authenticated');
  has_svc  bool := exists (select 1 from pg_roles where rolname='service_role');
begin
  -- 10.1 az echo séma MINDEN objektuma zárva marad
  for f in select 'table' k, format('%I.%I', schemaname, tablename) n
             from pg_tables where schemaname='echo'
           union all
           select 'function', p.oid::regprocedure::text
             from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname='echo'
  loop
    if has_anon then execute format('revoke all on %s %s from anon', f.k, f.n); end if;
    if has_auth then execute format('revoke all on %s %s from authenticated', f.k, f.n); end if;
    if has_svc  then execute format('revoke all on %s %s from service_role', f.k, f.n); end if;
    execute format('revoke all on %s %s from public', f.k, f.n);
  end loop;

  -- 10.2 a public sémás ECHO RPC-k: előbb mindenkitől el
  for f in select p.oid::regprocedure::text n
             from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
            where ns.nspname='public' and p.proname like 'echo\_%'
  loop
    execute format('revoke all on function %s from public', f.n);
    if has_anon then execute format('revoke all on function %s from anon', f.n); end if;
    if has_auth then execute format('revoke all on function %s from authenticated', f.n); end if;
    if has_svc  then execute format('revoke all on function %s from service_role', f.n); end if;
  end loop;

  -- 10.3 majd célzottan vissza
  if has_auth then
    grant execute on function public.echo_my_courses()                        to authenticated;
    grant execute on function public.echo_get_form(uuid,uuid)                 to authenticated;
    grant execute on function public.echo_save_goals(uuid,uuid,jsonb,jsonb)   to authenticated;
    grant execute on function public.echo_issue_ticket(uuid,uuid)             to authenticated;
    grant execute on function public.echo_campaigns()                         to authenticated;
    grant execute on function public.echo_rate(uuid)                          to authenticated;
    grant execute on function public.echo_rebuild_eligibility(uuid)           to authenticated;
    -- echo_submit SZÁNDÉKOSAN NINCS ITT. Lásd a fájl fejlécét.
  end if;

  -- 10.4 a beküldés KIZÁRÓLAG anon jogon megy
  if has_anon then
    grant execute on function public.echo_submit(text,jsonb) to anon;
  end if;

  raise notice 'ECHO 10. szakasz: grantok beallitva (anon=%, authenticated=%, service_role=%).',
               has_anon, has_auth, has_svc;
end
$grants$;

-- 10.5 RLS a kényes echo táblákon — MÁSODIK védvonal.
-- A séma amúgy is zárva, de ha valaki valaha USAGE-t adna rá, ezek a táblák
-- akkor is nulla sort adnának: RLS bekapcsolva, POLICY NÉLKÜL. A SECURITY
-- DEFINER RPC-ket ez nem érinti, mert azok a tábla tulajdonosaként futnak,
-- és a tulajdonosra az RLS nem vonatkozik (nincs FORCE ROW LEVEL SECURITY).
alter table echo.response      enable row level security;
alter table echo.participation enable row level security;
alter table echo.student_goal  enable row level security;
alter table echo.spent_nonce   enable row level security;
alter table echo.app_secret    enable row level security;


-- ============================================================
-- 11. SZAKASZ — DEMÓ SEED (külön szakasz, idempotens, eltávolítható)
-- ============================================================
--
-- MINDEN itt létrehozott sor ext_source = 'echo_demo_seed'. Eltávolítás:
--   delete from echo.enrollment     where ext_source = 'echo_demo_seed';
--   delete from echo.course_teacher where ext_source = 'echo_demo_seed';
--   delete from echo.campaign       where code = 'DEMO-2025-26-2';
--   delete from echo.course         where ext_source = 'echo_demo_seed';
--   delete from echo.teacher        where ext_source = 'echo_demo_seed';
--   delete from echo.org_unit       where ext_source = 'echo_demo_seed';
--   delete from echo.template       where code = 'OMHV-ALAP';   -- kaszkádol a verzióra
-- (A response/participation sorokat ez NEM törli — azokat kézzel, tudatosan.)
--
-- Rögzített UUID-k, hogy a seed újrafuttatható legyen. Ezek DEMÓ azonosítók;
-- éles törzsadatnál a gen_random_uuid() alapértelmezés dolgozik.

-- ---------- 11.1 szervezeti egységek ----------
insert into echo.org_unit (id, parent_id, code, name_hu, name_en, kind, ext_source) values
  ('e0000000-0000-4000-8000-000000000001', null,
   'GAMF', 'GAMF Muszaki es Informatikai Kar', 'GAMF Faculty of Engineering and Computer Science',
   'kar', 'echo_demo_seed'),
  ('e0000000-0000-4000-8000-000000000002', 'e0000000-0000-4000-8000-000000000001',
   'GAMF-INF', 'Informatika Tanszek', 'Department of Informatics', 'tanszek', 'echo_demo_seed')
on conflict (id) do nothing;

-- ---------- 11.2 oktatók ----------
insert into echo.teacher (id, code, name, title, email, org_unit_id, ext_source) values
  ('e1000000-0000-4000-8000-000000000001', 'OKT-001', 'Kovacs Andrea',  'egyetemi docens',
   'kovacs.andrea@nje.hu',  'e0000000-0000-4000-8000-000000000002', 'echo_demo_seed'),
  ('e1000000-0000-4000-8000-000000000002', 'OKT-002', 'Nagy Peter',     'adjunktus',
   'nagy.peter@nje.hu',     'e0000000-0000-4000-8000-000000000002', 'echo_demo_seed'),
  ('e1000000-0000-4000-8000-000000000003', 'OKT-003', 'Szabo Katalin',  'egyetemi tanar',
   'szabo.katalin@nje.hu',  'e0000000-0000-4000-8000-000000000002', 'echo_demo_seed'),
  ('e1000000-0000-4000-8000-000000000004', 'OKT-004', 'Toth Gergely',   'tanarseged',
   'toth.gergely@nje.hu',   'e0000000-0000-4000-8000-000000000002', 'echo_demo_seed')
on conflict (id) do nothing;

-- ---------- 11.3 kurzusok ----------
-- Szandekosan van kozottuk KIZARANDO is, hogy az alkalmassagi motor
-- mukodese azonnal latszodjon a kizarasi naploban.
insert into echo.course (id, code, name_hu, name_en, term, lang, org_unit_id,
                         letszam, van_orarendi_info, vizsgakurzus, ext_source) values
  ('e2000000-0000-4000-8000-000000000001', 'GAMF-INF-101',
   'Bevezetes a szoftverfejlesztesbe', 'Introduction to Software Engineering',
   '2025/26/2', 'hu', 'e0000000-0000-4000-8000-000000000002', null, true,  false, 'echo_demo_seed'),
  ('e2000000-0000-4000-8000-000000000002', 'GAMF-INF-102',
   'Adatbazisok alapjai', 'Database Fundamentals',
   '2025/26/2', 'hu', 'e0000000-0000-4000-8000-000000000002', null, true,  false, 'echo_demo_seed'),
  ('e2000000-0000-4000-8000-000000000003', 'GAMF-INF-103',
   'Statisztika mernokoknek', 'Statistics for Engineers',
   '2025/26/2', 'hu', 'e0000000-0000-4000-8000-000000000002', null, true,  false, 'echo_demo_seed'),
  -- KIZARANDO: vizsgakurzus
  ('e2000000-0000-4000-8000-000000000004', 'GAMF-INF-104',
   'Szakmai szeminarium (vizsgakurzus)', 'Professional Seminar (exam course)',
   '2025/26/2', 'hu', 'e0000000-0000-4000-8000-000000000002', null, true,  true,  'echo_demo_seed'),
  -- KIZARANDO: letszam a kuszob alatt
  ('e2000000-0000-4000-8000-000000000005', 'GAMF-INF-105',
   'Kutatasmodszertan (kis letszam)', 'Research Methodology (small group)',
   '2025/26/2', 'hu', 'e0000000-0000-4000-8000-000000000002', 2,    true,  false, 'echo_demo_seed')
on conflict (id) do nothing;

-- ---------- 11.4 kurzus ↔ oktató ----------
insert into echo.course_teacher (course_id, teacher_id, share_pct, role, ext_source) values
  ('e2000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001', 60, 'kurzusfelelos','echo_demo_seed'),
  ('e2000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000002', 40, 'oktato',       'echo_demo_seed'),
  ('e2000000-0000-4000-8000-000000000002','e1000000-0000-4000-8000-000000000003',100, 'kurzusfelelos','echo_demo_seed'),
  ('e2000000-0000-4000-8000-000000000003','e1000000-0000-4000-8000-000000000003', 85, 'kurzusfelelos','echo_demo_seed'),
  -- KIZARANDO PAR: 15% < 25% kuszob
  ('e2000000-0000-4000-8000-000000000003','e1000000-0000-4000-8000-000000000004', 15, 'gyakvezeto',   'echo_demo_seed'),
  ('e2000000-0000-4000-8000-000000000004','e1000000-0000-4000-8000-000000000002',100, 'kurzusfelelos','echo_demo_seed'),
  ('e2000000-0000-4000-8000-000000000005','e1000000-0000-4000-8000-000000000001',100, 'kurzusfelelos','echo_demo_seed')
on conflict (course_id, teacher_id) do nothing;

-- ---------- 11.5 a kérdőív (template + live template_version) ----------
insert into echo.template (id, code, name_hu, name_en) values
  ('e3000000-0000-4000-8000-000000000001', 'OMHV-ALAP',
   'OMHV alapkerdoiv (28/2023.)', 'Student Course Evaluation (base)')
on conflict (id) do nothing;

-- A compiled alakja a prototipus FORM_SEED szerkezete. FIGYELEM: a
-- prototipus fajl a jelen kornyezetben nem letezik (lasd a fajl fejleceben a
-- FORRASHUSEG szakaszt), ezert a SZOVEGEK BECSLESEK; a SZERKEZET a szerzodes.
-- Elo verziot a trigger vedi: javitas = uj template_version (version 2).
insert into echo.template_version (id, template_id, version, state, compiled, notes, approved_by, approved_at)
values (
  'e3000000-0000-4000-8000-000000000002',
  'e3000000-0000-4000-8000-000000000001',
  1, 'live',
  $json$
  {
    "meta": {
      "code": "OMHV-ALAP",
      "version": 1,
      "title_hu": "Oktatoi munka hallgatoi velemenyezese",
      "title_en": "Student evaluation of teaching",
      "legal_hu": "28/2023. szenatusi hatarozat",
      "forras_megjegyzes": "A kerdesszovegek REKONSTRUKCIOK, a prototipus FORM_SEED tombje nem allt rendelkezesre. A szerkezet vegleges, a szovegek pontositandok."
    },
    "parts": [
      { "id": "part1", "hu": "Celmeghatarozas (felev eleje)", "en": "Goal setting (start of term)" },
      { "id": "part2", "hu": "Ertekeles (felev vege)",        "en": "Evaluation (end of term)" }
    ],
    "sections": [
      {
        "id": "s1", "part": "part2",
        "hu": "Oralatogatas", "en": "Attendance",
        "questions": [
          { "id": "attendance", "type": "single",
            "hu": "Az orak korulbelul hany szazalekan vettel reszt?",
            "en": "Roughly what share of the classes did you attend?",
            "help": "Sav, nem pontos szam. A pontos oraszam azonositana.",
            "options": ["0-25%", "26-50%", "51-75%", "76-100%"],
            "required": true, "moderated": false, "randomize": false,
            "allowOther": false, "max": 1, "repeat": null, "cond": null,
            "scale": null, "audience": "student" }
        ]
      },
      {
        "id": "s2", "part": "part2",
        "hu": "A celok teljesulese", "en": "Goal fulfilment",
        "questions": [
          { "id": "goals_met", "type": "single",
            "hu": "Mennyiben teljesultek a felev elejen kituzott celjaid?",
            "en": "To what extent did you meet the goals you set at the start of term?",
            "help": "Csak ez az osszegzes kerul at a valaszba; a celok szovege es szamossaga nem.",
            "options": [
              { "value": "nem_teljesult",  "hu": "Nem teljesultek",        "en": "Not met" },
              { "value": "reszben",        "hu": "Reszben teljesultek",    "en": "Partly met" },
              { "value": "teljesult",      "hu": "Teljesultek",            "en": "Met" },
              { "value": "tulteljesult",   "hu": "Tulteljesultek",         "en": "Exceeded" }
            ],
            "required": true, "moderated": false, "randomize": false,
            "allowOther": false, "max": 1, "repeat": null,
            "cond": { "has_goals": true }, "scale": null, "audience": "student" }
        ]
      },
      {
        "id": "s3", "part": "part2",
        "hu": "Szoveges elmenyek", "en": "Open feedback",
        "questions": [
          { "id": "best_experience", "type": "longtext",
            "hu": "Mi volt a legjobb elmenyed ezen a kurzuson?",
            "en": "What was your best experience on this course?",
            "help": "Kerjuk, ne irj le olyat, ami tegedet vagy masokat azonosit.",
            "options": null, "required": false, "moderated": true, "randomize": false,
            "allowOther": false, "max": 1500, "repeat": null, "cond": null,
            "scale": null, "audience": "student" },
          { "id": "missing_experience", "type": "longtext",
            "hu": "Mi hianyzott a kurzusbol?",
            "en": "What did you miss from this course?",
            "help": null,
            "options": null, "required": false, "moderated": true, "randomize": false,
            "allowOther": false, "max": 1500, "repeat": null, "cond": null,
            "scale": null, "audience": "student" }
        ]
      },
      {
        "id": "s4", "part": "part2",
        "hu": "A kurzus ertekelese", "en": "Course evaluation",
        "questions": [
          { "id": "course_strengths", "type": "multi",
            "hu": "Mi volt a kurzus ket legnagyobb erossege?",
            "en": "What were the two greatest strengths of the course?",
            "help": "Legfeljebb kettot valassz.",
            "options": ["Vilagos kovetelmenyek", "Jol felepitett tananyag",
                        "Hasznos gyakorlati peldak", "Elerheto segedanyagok",
                        "Kiszamithato szamonkeres", "Korszeru tartalom"],
            "required": false, "moderated": false, "randomize": true,
            "allowOther": true, "max": 2, "repeat": null, "cond": null,
            "scale": null, "audience": "student" },
          { "id": "course_improve", "type": "multi",
            "hu": "Min kellene a leginkabb valtoztatni a kurzuson?",
            "en": "What should be changed most about the course?",
            "help": "Legfeljebb kettot valassz.",
            "options": ["Tul sok a tananyag", "Nem vilagosak a kovetelmenyek",
                        "Keves a gyakorlat", "Elavult tartalom",
                        "Hianyosak a segedanyagok", "Nehezen kovetheto utemezes"],
            "required": false, "moderated": false, "randomize": true,
            "allowOther": true, "max": 2, "repeat": null, "cond": null,
            "scale": null, "audience": "student" }
        ]
      },
      {
        "id": "s5", "part": "part2",
        "hu": "Az oktatok ertekelese", "en": "Teacher evaluation",
        "questions": [
          { "id": "teacher_skip", "type": "skip",
            "hu": "Ha nem tudod ertekelni ezt az oktatot, jelold meg az okat.",
            "en": "If you cannot evaluate this teacher, select the reason.",
            "help": "A kihagyas nem szamit hianyos kitoltesnek.",
            "options": ["Nem ismerem elegge az oktato munkajat",
                        "Csak nehany alkalommal tartott orat",
                        "Nem tudok erdemi velemenyt megfogalmazni",
                        "Egyeb"],
            "required": false, "moderated": false, "randomize": false,
            "allowOther": true, "max": 1, "repeat": "teacher", "cond": null,
            "scale": null, "audience": "student" },
          { "id": "teacher_strengths", "type": "multi",
            "hu": "Mi jellemzi leginkabb az oktato munkajat? (legfeljebb 5)",
            "en": "What best characterises this teacher? (max 5)",
            "help": null,
            "options": ["Erthetoen magyaraz", "Felkeszult", "Elerheto es segitokesz",
                        "Motivalo", "Tiszteletteljes", "Erdemi visszajelzest ad",
                        "Pontos", "Jol strukturalt orak"],
            "required": false, "moderated": false, "randomize": true,
            "allowOther": true, "max": 5, "repeat": "teacher",
            "cond": { "teacher_skip": null }, "scale": null, "audience": "student" },
          { "id": "teacher_improve", "type": "multi",
            "hu": "Min kellene az oktatonak valtoztatnia? (legfeljebb 5)",
            "en": "What should this teacher change? (max 5)",
            "help": null,
            "options": ["Nehezen ertheto magyarazat", "Nehezen elerheto",
                        "Kiszamithatatlan szamonkeres", "Keves visszajelzes",
                        "Pontatlansag", "Nem tartja a tematikat"],
            "required": false, "moderated": false, "randomize": true,
            "allowOther": true, "max": 5, "repeat": "teacher",
            "cond": { "teacher_skip": null }, "scale": null, "audience": "student" }
        ]
      },
      {
        "id": "s6", "part": "part2",
        "hu": "Osszegzes", "en": "Summary",
        "questions": [
          { "id": "overall_course", "type": "scale",
            "hu": "Osszessegeben mennyire volt hasznos a kurzus?",
            "en": "Overall, how useful was the course?",
            "help": null, "options": null, "required": true, "moderated": false,
            "randomize": false, "allowOther": false, "max": 1, "repeat": null, "cond": null,
            "scale": { "min": 1, "max": 7, "min_hu": "Egyaltalan nem", "max_hu": "Teljes mertekben",
                       "min_en": "Not at all", "max_en": "Completely" },
            "audience": "student" },
          { "id": "overall_teaching", "type": "scale",
            "hu": "Osszessegeben mennyire volt szinvonalas az oktatas?",
            "en": "Overall, how good was the teaching?",
            "help": null, "options": null, "required": true, "moderated": false,
            "randomize": false, "allowOther": false, "max": 1, "repeat": null, "cond": null,
            "scale": { "min": 1, "max": 7, "min_hu": "Egyaltalan nem", "max_hu": "Teljes mertekben",
                       "min_en": "Not at all", "max_en": "Completely" },
            "audience": "student" },
          { "id": "impact", "type": "scale",
            "hu": "Mennyiben jarult hozza a kurzus a szakmai fejlodesedhez?",
            "en": "How much did the course contribute to your professional development?",
            "help": "Ez a hataskerdes: nem az elegedettseget, hanem a valtozast meri.",
            "options": null, "required": true, "moderated": false,
            "randomize": false, "allowOther": false, "max": 1, "repeat": null, "cond": null,
            "scale": { "min": 1, "max": 7, "min_hu": "Egyaltalan nem", "max_hu": "Teljes mertekben",
                       "min_en": "Not at all", "max_en": "Completely" },
            "audience": "student" },
          { "id": "impact_text", "type": "longtext",
            "hu": "Miben lettel tobb ettol a kurzustol?",
            "en": "In what way did this course make you better?",
            "help": null, "options": null, "required": false, "moderated": true,
            "randomize": false, "allowOther": false, "max": 1500, "repeat": null,
            "cond": null, "scale": null, "audience": "student" }
        ]
      }
    ]
  }
  $json$::jsonb,
  'Demo seed. A kerdesszovegek rekonstrukciok — lasd meta.forras_megjegyzes.',
  'seed', now())
on conflict (id) do nothing;   -- ELO verziot soha nem irunk felul: uj verzio kell

-- ---------- 11.6 kampány (NYITOTT ablakkal) ----------
insert into echo.campaign (id, code, name_hu, name_en, term, template_version_id,
                           opens_at, closes_at, goals_open_at, goals_close_at, state)
values ('e4000000-0000-4000-8000-000000000001', 'DEMO-2025-26-2',
        'OMHV demo kampany 2025/26/2', 'Course evaluation demo 2025/26/2',
        '2025/26/2', 'e3000000-0000-4000-8000-000000000002',
        now() - interval '7 days', now() + interval '30 days',
        now() - interval '60 days', now() + interval '30 days',
        'open')
on conflict (id) do update
  set opens_at       = excluded.opens_at,
      closes_at      = excluded.closes_at,
      goals_open_at  = excluded.goals_open_at,
      goals_close_at = excluded.goals_close_at,
      -- Lepecsetelt/kozzetett kampanyt SOHA nem nyitunk ujra egy migracio
      -- ujrafuttatasaval: az visszamenoleg engedne ujabb kitolteseket egy mar
      -- lezart meresbe. Csak a meg nem zart kampany ablaka frissul.
      state = case when echo.campaign.state in ('closed','processing','sealed','published')
                   then echo.campaign.state else 'open' end;

-- ---------- 11.7 felvétel: MINDEN jóváhagyott fiók ----------
-- Igy barki, aki ma belep (SUPERADMIN, ADMIN, ADMISSIONS, FINANCE, AGENT,
-- STUDENT), lat kitoltheto kurzust. A tomeges, Neptunbol jovo felvetel ezt
-- majd felvaltja.
insert into echo.enrollment (course_id, student_key, ext_source)
select c.id, p.id, 'echo_demo_seed'
  from public.profiles p
  cross join (values
      ('e2000000-0000-4000-8000-000000000001'::uuid),
      ('e2000000-0000-4000-8000-000000000002'::uuid),
      ('e2000000-0000-4000-8000-000000000003'::uuid),
      ('e2000000-0000-4000-8000-000000000004'::uuid)   -- vizsgakurzus: kizarodik
    ) as c(id)
 -- Az AGENT kulsos partnerugynokseg, nem hallgato: OMHV-t nem veleményez.
 where p.approval_status = 'approved' and p.role <> 'AGENT'
on conflict (course_id, student_key) do nothing;

-- A kis letszamu kurzusra szandekosan csak 2 fo, hogy a LETSZAM_ALATT
-- kizaras lathato legyen a naploban.
insert into echo.enrollment (course_id, student_key, ext_source)
select 'e2000000-0000-4000-8000-000000000005'::uuid, p.id, 'echo_demo_seed'
  from (select id from public.profiles
         where approval_status = 'approved' and role <> 'AGENT'
         order by email limit 2) p
on conflict (course_id, student_key) do nothing;

-- ---------- 11.8 az alkalmassági motor lefuttatása ----------
do $seedrun$
declare r record;
begin
  select * into r from echo.eligibility_rebuild('e4000000-0000-4000-8000-000000000001');
  raise notice 'ECHO seed: % velemenyezheto par, % kurzus; % kurzus es % oktatoi par kizarva.',
               r.eligible_pairs, r.eligible_courses, r.excluded_courses, r.excluded_pairs;
end
$seedrun$;


-- ============================================================
-- 12. SZAKASZ — ELLENŐRZŐ LEKÉRDEZÉS (egyetlen eredménytábla)
-- ============================================================
-- Az "elvart" oszlop mondja meg, mit kellene latni. Ahol "allapot" = HIBA,
-- ott ne menj tovabb.
with chk(sorrend, ellenorzes, mert, elvart, rendben) as (
  select 1, 'echo sema letezik',
         (select count(*)::text from pg_namespace where nspname='echo'),
         '1',
         (select count(*) from pg_namespace where nspname='echo') = 1
  union all
  select 2, 'anon/authenticated USAGE joga az echo semara (0 = jo)',
         (select count(*)::text from information_schema.usage_privileges
           where object_schema is not distinct from 'echo'
             and grantee in ('anon','authenticated'))
         || ' + ' ||
         (select count(*)::text from pg_namespace n, unnest(array['anon','authenticated']) g(r)
           where n.nspname='echo'
             and exists (select 1 from pg_roles where rolname=g.r)
             and has_schema_privilege(g.r, n.oid, 'USAGE')),
         'barmi + 0',
         not exists (select 1 from pg_namespace n, unnest(array['anon','authenticated']) g(r)
                      where n.nspname='echo' and exists (select 1 from pg_roles where rolname=g.r)
                        and has_schema_privilege(g.r, n.oid, 'USAGE'))
  union all
  select 3, 'echo tablak szama',
         (select count(*)::text from pg_tables where schemaname='echo'), '>= 14',
         (select count(*) from pg_tables where schemaname='echo') >= 14
  union all
  select 4, 'a valaszsoron NINCS idobelyeg / kitolto-oszlop',
         (select coalesce(string_agg(column_name, ', '), 'nincs')
            from information_schema.columns
           where table_schema='echo' and table_name='response'
             and (data_type like 'timestamp%' or data_type='date'
                  or column_name in ('student_key','participation_id','submission_id','seq'))),
         'nincs',
         echo.response_schema_ok()
  union all
  select 5, 'response elsodleges kulcs alapertelmezese',
         (select coalesce(column_default,'(nincs)') from information_schema.columns
           where table_schema='echo' and table_name='response' and column_name='id'),
         'gen_random_uuid()',
         (select column_default from information_schema.columns
           where table_schema='echo' and table_name='response' and column_name='id')
           = 'gen_random_uuid()'
  union all
  select 6, 'response NINCS a supabase_realtime publikacioban',
         (select count(*)::text from pg_publication_tables
           where pubname='supabase_realtime' and schemaname='echo'),
         '0',
         (select count(*) from pg_publication_tables
           where pubname='supabase_realtime' and schemaname='echo') = 0
  union all
  select 7, 'public echo_ RPC-k szama',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname like 'echo\_%'), '8',
         (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname like 'echo\_%') = 8
  union all
  select 8, 'echo_submit: anon IGEN, authenticated NEM',
         (select case when has_function_privilege('anon','public.echo_submit(text,jsonb)','execute')
                      then 'anon=I' else 'anon=N' end || ', ' ||
                 case when has_function_privilege('authenticated','public.echo_submit(text,jsonb)','execute')
                      then 'auth=I' else 'auth=N' end),
         'anon=I, auth=N',
         has_function_privilege('anon','public.echo_submit(text,jsonb)','execute')
         and not has_function_privilege('authenticated','public.echo_submit(text,jsonb)','execute')
  union all
  select 9, 'echo_issue_ticket: authenticated IGEN, anon NEM',
         (select case when has_function_privilege('authenticated','public.echo_issue_ticket(uuid,uuid)','execute')
                      then 'auth=I' else 'auth=N' end || ', ' ||
                 case when has_function_privilege('anon','public.echo_issue_ticket(uuid,uuid)','execute')
                      then 'anon=I' else 'anon=N' end),
         'auth=I, anon=N',
         has_function_privilege('authenticated','public.echo_issue_ticket(uuid,uuid)','execute')
         and not has_function_privilege('anon','public.echo_issue_ticket(uuid,uuid)','execute')
  union all
  select 10, 'elo kerdoiv-verzio (live) szakaszainak/kerdeseinek szama',
         (select jsonb_array_length(compiled->'sections')::text || ' szakasz, ' ||
                 (select count(*)::text from jsonb_array_elements(compiled->'sections') s,
                         jsonb_array_elements(s->'questions') q) || ' kerdes'
            from echo.template_version where state='live' order by created_at limit 1),
         '6 szakasz, 13 kerdes',
         (select jsonb_array_length(compiled->'sections') = 6
                 and (select count(*) from jsonb_array_elements(compiled->'sections') s,
                             jsonb_array_elements(s->'questions') q) = 13
            from echo.template_version where state='live' order by created_at limit 1)
  union all
  select 11, 'nyitott kampany',
         (select coalesce(string_agg(code, ', '), 'nincs') from echo.campaign where echo.is_open(id)),
         'DEMO-2025-26-2',
         exists (select 1 from echo.campaign where code='DEMO-2025-26-2' and echo.is_open(id))
  union all
  select 12, 'velemenyezheto kurzus-oktato parok (demo kampany)',
         (select count(*)::text from echo.eligibility
           where campaign_id='e4000000-0000-4000-8000-000000000001'), '4',
         (select count(*) from echo.eligibility
           where campaign_id='e4000000-0000-4000-8000-000000000001') = 4
  union all
  select 13, 'kizarasok okonkent',
         (select coalesce(string_agg(rule_code || '=' || n, ', ' order by rule_code), 'nincs')
            from (select rule_code, count(*)::text n from echo.exclusion_log
                   where campaign_id='e4000000-0000-4000-8000-000000000001'
                   group by rule_code) z),
         'LETSZAM_ALATT=1, OKTATOI_ARANY_ALATT=1, VIZSGAKURZUS=1',
         (select count(distinct rule_code) from echo.exclusion_log
           where campaign_id='e4000000-0000-4000-8000-000000000001') = 3
  union all
  select 14, 'reszveteli naplo sorai (jovahagyott, nem-AGENT fiok x 3 kurzus)',
         (select count(*)::text from echo.participation
           where campaign_id='e4000000-0000-4000-8000-000000000001' and eligible),
         (select (count(*)*3)::text from public.profiles
           where approval_status='approved' and role <> 'AGENT'),
         (select count(*) from echo.participation
           where campaign_id='e4000000-0000-4000-8000-000000000001' and eligible)
         = (select count(*)*3 from public.profiles
             where approval_status='approved' and role <> 'AGENT')
  union all
  select 15, 'NINCS kozos oszlop a naplo es a valaszhalmaz kozott',
         (select coalesce(string_agg(column_name, ', '), 'nincs') from (
            select column_name from information_schema.columns
             where table_schema='echo' and table_name='participation'
            intersect
            select column_name from information_schema.columns
             where table_schema='echo' and table_name='response') z
           where column_name not in ('campaign_id','course_id')),
         'nincs',
         not exists (select 1 from (
            select column_name from information_schema.columns
             where table_schema='echo' and table_name='participation'
            intersect
            select column_name from information_schema.columns
             where table_schema='echo' and table_name='response') z
           where column_name not in ('campaign_id','course_id'))
  union all
  select 16, 'a jegy alairo kulcsa letezik es 32 bajt',
         (select coalesce(octet_length(secret)::text,'nincs') from echo.app_secret where key='ticket_hmac'),
         '32',
         (select octet_length(secret) from echo.app_secret where key='ticket_hmac') = 32
  union all
  select 17, 'jegyszam-korlat kuszobe be van allitva',
         (select coalesce(value,'nincs') from echo.setting where key='max_tickets_per_course'),
         '>= 1',
         coalesce((select value::integer from echo.setting
                    where key='max_tickets_per_course'), 0) >= 1
  union all
  select 18, 'oralatogatasi sav CSAK a kurzusszintu soron (kenyszer + adat)',
         (select case when exists (select 1 from pg_constraint
                                    where conname='echo_response_att_scope_chk')
                      then 'kenyszer=van' else 'kenyszer=NINCS' end || ', ' ||
                 (select count(*)::text from echo.response
                   where scope='teacher' and attendance_band is not null)
                 || ' rossz sor'),
         'kenyszer=van, 0 rossz sor',
         exists (select 1 from pg_constraint where conname='echo_response_att_scope_chk')
         and not exists (select 1 from echo.response
                          where scope='teacher' and attendance_band is not null)
  union all
  select 19, 'echo_campaigns/echo_rate kapuja a szukebb is_admin()',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in ('echo_campaigns','echo_rate')
             and pg_get_functiondef(p.oid) like '%is_admin()%'),
         '2',
         (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in ('echo_campaigns','echo_rate')
             and pg_get_functiondef(p.oid) like '%is_admin()%') = 2
)
select sorrend as "#",
       ellenorzes as "ellenorzes",
       mert as "mert",
       elvart as "elvart",
       case when rendben then 'OK' else 'HIBA' end as "allapot"
  from chk order by sorrend;

-- ============================================================
-- VÉGE — 15_echo_core.sql
-- ============================================================

-- ============================================================
-- FÜGGELÉK — A HELYI REPLIKÁN MÉRT EREDMÉNY (2026-08-19, javítás után)
-- ============================================================
-- Környezet: Postgres 16.14, /tmp/upg2:55432, 'verify' adatbázis, benne a
-- 01–10 migráció + 11_rbac_additive.sql, Supabase-utánzattal (auth séma,
-- auth.uid(), anon/authenticated/service_role, supabase_realtime publikáció).
-- 15 approved fiók, ebből 1 AGENT (a seed őt már nem veszi fel) → 14 kitöltő.
--
-- FUTTATÁS: tiszta lapról (drop schema echo cascade + a 8 RPC eldobása után)
-- KÉTSZER lefuttatva, psql -v ON_ERROR_STOP=1, mindkétszer exit=0, és a
-- 12. szakasz mind a 19 sora OK. Egyetlen tranzakcióban (psql -1) is exit=0.
-- Idempotens és adatbiztos.
--
-- ---------- A KÉT BLOKKOLÓ HIBA JAVÍTÁSÁNAK MÉRÉSE ----------
--
-- (1) TÖBBSZÖRÖS BEKÜLDÉS / HAMIS 'submitted' JELÖLÉS
--   JAVÍTÁS ELŐTT: stud11 kétszer beküldött a GAMF-INF-102-re, stud10 csak
--     jegyet kért és soha nem küldött be. echo.mark_submitted() att=2, resp=2
--     párost látott, és MINDKETTŐT submitted=true-ra állította. stud10 ezután
--     ECHO_ALREADY_SUBMITTED-et kapott: egy hallgató, aki soha nem töltött ki
--     semmit, VÉGLEG kizárta magát. (Lemérve, reprodukálva.)
--   FIGYELEM: a puszta 'resp = att' (pontos egyezés) EZT NEM OLDJA MEG —
--     szintén lemértük: egyetlen kétszer beküldő PONTOSAN kompenzál egy be nem
--     küldőt, att=2, resp=2, és a hamis jelölés újra megtörténik.
--   A TÉNYLEGES JAVÍTÁS KETTŐS:
--     • 9.4 max_tickets_per_course = 2 küszöb (ECHO_TICKET_LIMIT). Mérve:
--       a 3. jegykérés ECHO_TICKET_LIMIT-tel elutasítva.
--     • 6.4 a jelölés a KIADOTT JEGYEK számához hasonlít (sum(ticket_count)),
--       nem a hallgatókéhoz. Mérve ugyanabban a helyzetben: T=3, resp=2 →
--       '2 válasz a 3 kiadott jegyből — nem jelölve', stud10 submitted=false.
--   BOLDOG ÚT (regresszió): a GAMF-INF-103 mind a 14 alkalmas hallgatója
--     pontosan egyszer kitöltött → att=14, T=14, resp=14 → 14 sor jelölve,
--     echo_my_courses() 'kitoltve', újabb jegykérés ECHO_ALREADY_SUBMITTED.
--
-- (2) xmin-ALAPÚ DEANONIMIZÁLÁS
--   JAVÍTÁS ELŐTT: 3 tesztkitöltő (stud12/13/14) után
--     participation.xmin = 3805, 3808, 3811
--     response.xmin      = 3806, 3809, 3812   (= participation.xmin + 1)
--     spent_nonce.xmin   = 3807, 3810, 3813
--   Egy hatsoros join (p.xmin between r.xmin-2 and r.xmin-1) stud13-at és
--   stud14-et EGYEDILEG azonosította a saját válaszához. Időbélyeg nem kellett
--   hozzá. (Lemérve, reprodukálva.)
--   JAVÍTÁS UTÁN (9.4 kohorsz-szintű sorverzió-frissítés): ugyanaz a join
--     válaszonként 1 helyett a TELJES 14 fős kohorszot adja vissza, két
--     válaszra pedig egyáltalán nem talál párt. A kurzus mind a 14 naplósora
--     azonos xmin-t visel (mérve: 4074).
--   echo.shuffle_responses(kampány) után mind a 9 válaszsor xmin-je azonos
--     (mérve: 4077), és a join 0 sort ad. A végső adatbázis-állapotban a
--     támadó join egyetlen választ sem tud naplósorhoz kötni.
--   HOLTPONT-PRÓBA: 8 párhuzamos echo_issue_ticket ugyanarra a kurzusra —
--     mind a 8 sikeres, 0 deadlock (a pg_advisory_xact_lock sorosít).
--
-- ---------- A TOVÁBBI JAVÍTÁSOK MÉRÉSE ----------
--   • Egy beküldés sorai: az attendance_band már CSAK a kurzusszintű soron van.
--     A kényszer él: teacher + attendance_band beszúrása
--     → ERROR: violates check constraint "echo_response_att_scope_chk".
--     (Az azonos xmin és a szomszédos ctid megmarad — azt a 6.5 shuffle bontja.)
--   • spent_nonce.expires_at NAPRA kerekítve (a napló DATE felbontásával
--     konzisztens); óra pontosságú érkezési idő többé nem számolható vissza.
--   • echo.shuffle_responses(p_campaign) kampányra szűkíthető, DELETE-tel:
--     egy másik, épp nyitott kampány válaszait nem írja át.
--   • A kampány-upsert lepecsételt/közzétett kampányt nem nyit újra.
--   • echo_campaigns() és echo_rate() kapuja a szűkebb public.is_admin() —
--     így a felület (menü) és az API ugyanazt a határt mondja.
--   • A seed az AGENT szerepkört nem veszi fel kurzusra (11.7), a menüpont
--     pedig nem jelenik meg neki (app.jsx filteredMenuItems).
--
-- ---------- VÁLTOZATLANUL ÉRVÉNYES KORÁBBI MÉRÉSEK ----------
--   • echo_submit AUTHENTICATED jogon → permission denied (csak anon hívhatja);
--     echo_issue_ticket ANON jogon → permission denied.
--   • 'select from echo.response' authenticated/anon jogon → permission denied
--     for schema echo.
--   • ugyanaz a jegy kétszer → ECHO_TICKET_SPENT; meghamisított jegy →
--     ECHO_TICKET_BADSIG; csonka jegy → ECHO_TICKET_INVALID.
--   • a szerveroldali tisztítás levágja a goals/goal_count/email/created_at
--     kulcsokat, a goals_met átmegy.
--   • az élő (live) kérdőívverzió immutábilis (trigger fogja a módosítást).
--   • a válaszsoron nincs időbélyeg-oszlop, a kulcs gen_random_uuid() (v4),
--     és az echo.response nincs a supabase_realtime publikációban.
--
-- ---------- AMI MÉG NEM KÉSZ (tartalmi, nem kódhiba) ----------
--   A kérdőív 13 kérdésének SZÖVEGE és a kizárási szabályok §-hivatkozásai
--   REKONSTRUKCIÓK: az ECHO prototípus fájlja ebben a környezetben nem
--   található meg (ellenőrizve). A szerkezet használható, a tartalom még nem
--   éles — lásd a 11.5 szakasz FORRÁSHŰSÉG megjegyzését.
-- ============================================================
