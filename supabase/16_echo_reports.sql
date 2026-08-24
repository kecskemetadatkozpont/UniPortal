-- ============================================================
-- UniPortal Pro — ECHO (OMHV) 2. szelet (Step 16)
-- Szerkesztő-, moderálási és riport-RPC-k
-- Neumann János Egyetem, 28/2023. szenátusi határozat
-- Változat: 2026-08-19, HELYI POSTGRES 16 REPLIKÁN MÉRVE
-- ELŐFELTÉTEL: 15_echo_core.sql lefutott (17 tábla, 8 public RPC).
-- ============================================================
--
-- UTÓLAGOS KIEGÉSZÍTÉS (19_echo_roles.sql, 0.4 szelet):
--   Az ebben a fájlban álló public.is_admin() kapuk ÁTMENETI HIDAK. Az ECHO
--   saját, HATÓKÖRÖS jogosultsági dimenzióját a 19_echo_roles.sql vezeti be
--   (echo.role_grant + echo.has_role(role, scope)), és HOSSZÚ TÁVON AZ VÁLTJA
--   KI ŐKET: az eredmény-RPC-k kapuja MIR / DEKAN / TANSZEKVEZETO, a
--   moderálásé MODERATOR lesz.
--   MIÉRT NEM MOST: a csere pillanatában NULLA grant van a rendszerben, tehát
--   senki nem tudna sem eredményt nézni, sem moderálni. A csere ezért külön
--   migráció dolga, MIUTÁN a grantok ki vannak osztva. Addig a két kapu
--   egymás mellett él, és ennek a fájlnak EGYETLEN sora sem változott.
--
-- MIT CSINÁL:
--   • MODERÁLÁS: echo.moderation + a §3 (10) szerinti érvénytelenségi
--     kategóriák ADATKÉNT (echo.moderation_reason), sorrend-semleges
--     feltöltéssel. A szöveg SOHA nem törlődik, csak kikerül a
--     visszacsatolásból, audit-nyommal.
--   • K-ANONIMITÁSI KÜSZÖBÖK az echo.setting-ben, CHECK constraint-tel
--     megtámasztott ALSÓ KORLÁTTAL: futásidőben 1-re állítani nem lehet.
--   • AGGREGÁLÓ RPC-k (echo_teacher_results, echo_course_results): a
--     küszöbök kikényszerítésével, komplementer-elnyomással, külön
--     alacsony-óralátogatású blokkal, és kötelező megtekintés-naplózással.
--   • KÉRDŐÍVSZERKESZTŐ RPC-k: sablonlista, betöltés, mély klónozás új
--     kérdés-ID-kkal, mentés csak draft-ban, SZÁMÍTOTT élesítés-előtti
--     ellenőrzések, állapotgép draft→review→approved→live→closed, és egy
--     MÁSODIK trigger, ami az approved/live/closed compiled-ot befagyasztja.
--
-- FUTTATÁS: Supabase dashboard → SQL Editor → New query → beilleszt → Run.
-- Idempotens; a replikán KÉTSZER lefuttatva ON_ERROR_STOP=1 mellett hibátlan.
--
-- ============================================================
-- A NÉGY SZERKEZETI DÖNTÉS EBBEN A SZELETBEN
-- ============================================================
--
--   1. A MODERÁLÁSI SORON NINCS OLYAN IDŐBÉLYEG, AMI A BEKÜLDÉSRE UTAL.
--      Nincs created_at. A moderálási sor a válasszal 1:1 kapcsolatban áll
--      (response_id), tehát BÁRMILYEN sorbeszúrási időbélyeg a hozzá tartozó
--      VÁLASZ datálásává válna — pont azt kerülnénk el, amiért a
--      echo.response-on sincs időbélyeg (15_echo_core, 3. szerkezeti döntés).
--      Egyetlen időbélyeg van: moderalt_at, ami a MODERÁTOR saját munkájának
--      ideje, és NULL, amíg a sor 'pending'. CHECK kényszer tartja.
--
--   2. A MODERÁLÁSI SOROK VÉLETLEN SORRENDBEN KELETKEZNEK.
--      A feltöltés INSERT … SELECT … ORDER BY random(), mert az így keletkező
--      sorok FIZIKAI (ctid) sorrendje véletlen. Enélkül a moderálási tábla
--      ctid-sorrendje a válaszok ctid-sorrendjét másolná le, és a
--      15_echo_core.sql-ben nagy gonddal lebontott érkezési sorrend egy
--      MÁSIK táblában éledne újra. (Az echo.shuffle_responses() a válaszokat
--      keveri meg — a moderálási táblát nem.)
--      A visszaadott sorrend is sorrend-semleges: md5(response_id||question_id)
--      szerint, nem ctid szerint, nem beszúrás szerint.
--
--   3. A KÜSZÖBÖK ADATOK, DE VAN ALSÓ KORLÁTJUK.
--      A k_numeric / k_text / k_slice / k_dist az echo.setting-ben áll, hogy
--      a MIR paraméterezhesse — de egy CHECK constraint tiltja, hogy 5 / 8 /
--      5 / 10 alá menjenek. Ez azért kell, mert a "gyorsan levisszük 1-re,
--      hogy lássuk az adatot" a leggyakoribb, teljesen jóhiszemű módja
--      annak, ahogy egy anonim mérés deanonimizálódik. FELFELÉ szabadon
--      állítható (a mérés lentebb pont ezt használja ki).
--
--   4. A MEGTEKINTÉSI NAPLÓ NEM TÁROL EREDMÉNYT.
--      A 6. § (4) szerinti naplózás (ki, mikor, milyen bontást nézett meg)
--      kötelező — de a napló SEMMILYEN válasz-tartalmat, elemszámot vagy
--      "elrejtve/megjelenítve" jelzést nem tárol. Ha tárolna, a napló maga
--      lenne egy második csatorna, amin egy naplóolvasó megtudná azt, amit a
--      küszöbök elrejtenek előle (pl. hogy egy kurzuson pontosan 4 válasz van).
--      A napló akkor is íródik, ha az eredmény teljesen elrejtve tér vissza —
--      különben a naplósor MEGLÉTE lenne az információ.
--
-- ============================================================
-- AMIT EZ A SZELET NEM TUD — ŐSZINTÉN, MÉRVE
-- ============================================================
--   • AZ ALACSONY ÓRALÁTOGATÁS SZŰRÉSE CSAK KURZUSSZINTEN MŰKÖDIK.
--     A 3. § (9) szerint a 33% alatti óralátogatású válaszok nem számítanak
--     a jegyzőkönyvi statisztikába. Az attendance_band viszont a
--     15_echo_core.sql döntése szerint KIZÁRÓLAG a kurzusszintű soron
--     szerepel (echo_response_att_scope_chk), és a kurzusszintű meg az
--     oktatói sor között SZÁNDÉKOSAN nincs közös kulcs. Ezért egy OKTATÓI
--     sorról nem lehet megmondani, hogy a kitöltője mennyit járt órára.
--     Ez nem hiba, hanem a két követelmény ütközése: vagy az óralátogatás
--     szerinti szűrés az oktatói soron is, vagy a beküldés-azonosító hiánya.
--     A 15. szelet az anonimitást választotta; ez a szelet ezt tiszteletben
--     tartja, és az oktatói riport 'alacsony_oralatogatas' blokkja mindig
--     üres, kimondott indoklással (lásd 'megjegyzes' mező).
--     A KURZUSSZINTŰ riportban a szűrés valóban működik.
--
--   • A MEGTAGADOTT HÍVÁS NEM NAPLÓZÓDIK. Ha az RPC ECHO_FORBIDDEN-nel dob,
--     a tranzakció visszagördül, és vele a naplósor is. Postgresben nincs
--     autonóm tranzakció (dblink/pg_background nélkül), ezért a sikertelen
--     próbálkozás csak a PostgREST / Postgres hibanaplójában marad meg.
--     Kimondva: a 6. § (4) naplója a SIKERES megtekintéseket fedi le.
--
--   • A K-KÜSZÖB NEM VÉD A HOSSZMETSZET ELLEN. Aki két egymást követő
--     kampányban nézi ugyanazt a kurzust, és közben egy hallgató kiesik, a
--     különbségből következtethet. Ez ellen csak a lekérdezés-naplóra épülő
--     utólagos audit véd — a napló ezért kötelező, nem opcionális.
--
--   • A SZÖVEGES VÁLASZ MODERÁLÁSA EMBERI DÖNTÉS. A rendszer csak a
--     kategóriákat és az audit-nyomot adja; azt, hogy egy mondat
--     "személyiségre irányuló értékelés"-e, nem dönti el gépileg.
--
-- ============================================================
-- JOGOSULTSÁG — ÉS AMI MÉG NINCS
-- ============================================================
--   Ebben a szeletben KÉTFÉLE hívó van:
--     (a) ADMIN / MIR — public.is_admin(), azaz ma SUPERADMIN és ADMIN.
--         Övék a moderálás és a teljes kérdőívszerkesztő.
--     (b) OKTATÓ — az a bejelentkezett fiók, amelyre valamelyik
--         echo.teacher.profile_id mutat. Ő KIZÁRÓLAG a saját oktatói
--         eredményét kérheti le; más oktató azonosítójával ECHO_FORBIDDEN.
--   AZ ECHO SAJÁT SZEREPKÖR-DIMENZIÓJA KÉSŐBB JÖN (ECHO_ADMIN kampányt
--   indít; ECHO_MIR aggregált eredményt lát; ECHO_DEKAN csak a saját karát;
--   OKTATO csak a saját kurzusait). Amíg nincs, a public.is_admin() a
--   helyettes, és a kari szintű ('csak a saját kar') szűkítés NEM létezik:
--   aki ma admin, minden kar minden kurzusát látja. Az echo.org_unit fa és
--   az echo.teacher.org_unit_id már fel van véve ehhez, tehát a szűkítés
--   egyetlen where-feltétel lesz, nem séma-átalakítás.
-- ============================================================


-- ============================================================
-- 0. SZAKASZ — ELŐELLENŐRZÉS
-- ============================================================
do $precheck$
declare v_missing text := '';
begin
  if to_regclass('echo.response')          is null then v_missing := v_missing || ' echo.response';          end if;
  if to_regclass('echo.template_version')  is null then v_missing := v_missing || ' echo.template_version';  end if;
  if to_regclass('echo.setting')           is null then v_missing := v_missing || ' echo.setting';           end if;
  if to_regclass('echo.campaign')          is null then v_missing := v_missing || ' echo.campaign';          end if;
  if to_regprocedure('public.is_admin()')  is null then v_missing := v_missing || ' public.is_admin()';      end if;
  if to_regprocedure('public.is_approved()') is null then v_missing := v_missing || ' public.is_approved()'; end if;
  if v_missing <> '' then
    raise exception 'ECHO 16: hianyzo elofeltetel:%. Futtasd le eloszor a 15_echo_core.sql fajlt.', v_missing;
  end if;
  raise notice 'ECHO 16: eloellenorzes rendben.';
end
$precheck$;


-- ============================================================
-- 1. SZAKASZ — K-ANONIMITÁSI KÜSZÖBÖK (adat, alsó korláttal)
-- ============================================================
--
-- MIÉRT NÉGY KÜSZÖB ÉS NEM EGY:
--   k_numeric — a KÉRDÉS megszólalási küszöbe. Ez alatt a kérdésről semmit
--               nem mondunk: se átlagot, se eloszlást. Javaslat: 5.
--   k_dist    — az ELOSZLÁS küszöbe. E fölött adunk cellánkénti bontást,
--               alatta csak átlagot. A feladat szerint 10. Azért magasabb
--               k_numeric-nál, mert az eloszlás LÉNYEGESEN több információt
--               ad, mint az átlag: 6 fős csoportnál a "4 fő adott 7-est"
--               cella már majdnem névsor.
--   k_text    — a SZABADSZÖVEG küszöbe. A legmagasabb (javaslat 10), mert a
--               szöveg tartalma önmagában azonosít; itt nem az elemszám,
--               hanem a stílus és az egyedi utalás a kockázat.
--   k_slice   — a CELLA küszöbe. Egy megjelenített eloszlás egyetlen cellája
--               ennél kisebb elemszámot nem mutathat.
--   k_low     — az ALACSONY ÓRALÁTOGATÁSÚ blokk SAJÁT küszöbe. A 3. § (9)
--               szerint különválasztott halmaz mindig kicsi, ezért külön
--               kapja a küszöböt: nem örökli a fő halmazét, és ha alatta
--               marad, a blokk EGÉSZBEN elrejtődik.
--
-- AZ ALSÓ KORLÁT: a lenti CHECK constraint az ÉRTÉKRE szól, tehát egy
-- "update echo.setting set value='1' where key='k_text'" a szerveren
-- elhasal. FELFELÉ szabadon állítható.
insert into echo.setting (key, value, description) values
  ('k_numeric', '5',
   'K-anonimitasi kuszob a szamszeru bontasra. Ha egy kerdesre ennel kevesebb '
   'ertekelheto valasz erkezett, a kerdesrol SEMMIT nem adunk vissza: se atlagot, '
   'se eloszlast. Also korlat: 5 (CHECK constraint tartja).'),
  ('k_dist', '10',
   'Az eloszlas (cellankenti bontas) kuszobe. Ez alatt csak atlag megy vissza, '
   'eloszlas nem. Also korlat: 10.'),
  ('k_text', '10',
   'A szabadszoveges valaszok kuszobe. Ez alatt egyetlen szoveg sem kerul '
   'vissza, akkor sem, ha moderalt es ervenyes. Also korlat: 10. (A 16-os szelet '
   'ellenorzese utan emelve 8-rol: a leiras es a fejlec vegig 10-et mondott, a CHECK '
   'viszont 8-at engedett — a szigorubb ertek a helyes.)'),
  ('k_slice', '5',
   'Cellankenti kuszob egy megjelenitett eloszlason belul. Ennel kisebb '
   'elemszamu cella elrejtodik, es vele legalabb meg egy (komplementer-elnyomas). '
   'Also korlat: 5.'),
  ('k_low', '5',
   'Az ALACSONY ORALATOGATASU (33 szazalek alatti) valaszok KULON blokkjanak sajat '
   'kuszobe. A blokk fuggetlenul kap kuszobot: ha ide kevesebb valasz esik, a '
   'blokk egeszben elrejtodik. Also korlat: 5.'),
  ('attendance_min_pct', '33',
   'A 3. § (9) szerinti oralatogatasi kuszob szazalekban. Az ez alatti savba '
   'eso valaszok KULON blokkba kerulnek, es nem szamitanak a jegyzokonyvi '
   'statisztikaba. BECSLES a savhatarok ertelmezeseben: egy sav akkor szamit '
   'alacsonynak, ha a FELSO hatara is a kuszob alatt van (pl. "0-25%" igen, '
   '"26-50%" nem).'),
  ('results_teacher_states', 'sealed,published',
   'Mely kampanyallapotokban lathatja az OKTATO a sajat eredmenyet. A nyitott '
   'ablak alatt nem: a menet kozben latszo eredmeny visszahat a kitoltesre.'),
  ('results_admin_states', 'closed,processing,sealed,published',
   'Mely kampanyallapotokban lathatja az ADMIN/MIR az eredmenyt. A zaras utan '
   'igen, a nyitott ablak alatt nem.'),
  ('moderation_states', 'closed,processing,sealed,published',
   'Mely kampanyallapotokban nyithato meg a MODERALASI SOR. A nyitott ablak alatt '
   'NEM: a moderalasi sor NYERS szoveget ad vissza, ami azonositobb, mint barmely '
   'aggregatum, es az ismetelt lekerdezes a beerkezes idorendjet is kiadna. '
   'MERVE (16. szelet ellenorzese): kapu nelkul egy nyitott kampanyon a sor mind a '
   '14 nyers szoveget visszaadta, es az "uj sorok" szamlalo orankent lekerdezve '
   'pontos beerkezesi hisztogramma allt ossze.')
on conflict (key) do nothing;

-- Az alsó korlát. Külön nevesített constraint, hogy a hibaüzenet beszédes legyen.
alter table echo.setting drop constraint if exists echo_setting_k_floor_chk;
alter table echo.setting add constraint echo_setting_k_floor_chk check (
  key not in ('k_numeric','k_dist','k_text','k_slice','k_low','attendance_min_pct')
  or (value ~ '^[0-9]+$'
      and value::int >= case key
                          when 'k_numeric'          then 5
                          when 'k_dist'             then 10
                          when 'k_text'             then 10
                          when 'k_slice'            then 5
                          when 'k_low'              then 5
                          when 'attendance_min_pct' then 1
                        end)
);

comment on constraint echo_setting_k_floor_chk on echo.setting is
  'A k-anonimitasi kuszobok futasidoben nem vihetok az also korlat ala. '
  'Felfele szabadon allithatok. Ez a legolcsobb vedelem a "csak most az egyszer '
  'vegyuk le 1-re" ellen.';

-- Küszöbolvasó. STABLE, hogy egy lekérdezésen belül ne változhasson.
create or replace function echo.k(p_key text)
returns integer
language sql stable
set search_path = echo, public, pg_temp
as $$
  select coalesce((select value::int from echo.setting where key = p_key),
                  case p_key when 'k_numeric' then 5 when 'k_dist' then 10
                             when 'k_text' then 10 when 'k_slice' then 5
                             when 'k_low' then 5
                             when 'attendance_min_pct' then 33 else 5 end)
$$;

-- Kampányállapot-lista olvasó (results_teacher_states / results_admin_states).
create or replace function echo.allowed_states(p_key text)
returns text[]
language sql stable
set search_path = echo, public, pg_temp
as $$
  select coalesce(
    (select string_to_array(replace(value,' ',''), ',') from echo.setting where key = p_key),
    array['sealed','published'])
$$;


-- JSONB tömb-védő. A compiled mezőiben a "nincs adat" KÉTFÉLEKÉPPEN jelenhet
-- meg: hiányzó kulcsként (SQL NULL) vagy JSON null-ként ("options": null —
-- a 15_echo_core.sql seedje pont ezt írja a skála- és szövegkérdésekre).
-- A coalesce(x->'options','[]') csak az ELSŐT fogja meg; a JSON null átcsúszik
-- rajta, és a jsonb_array_length "cannot get array length of a scalar" hibával
-- áll meg. Ez a függvény mindkettőt üres tömbbé alakítja.
create or replace function echo.jarr(p jsonb)
returns jsonb
language sql immutable
as $$
  select case when p is null or jsonb_typeof(p) <> 'array' then '[]'::jsonb else p end
$$;


-- JSONB egész-szám olvasó, VÉDETT CASTTEL.
-- MIÉRT KELL: a szerkesztő Max és Skála mezője <input type=number>, tehát a
-- compiled-ba tetszőleges szám (vagy egy import után tetszőleges SZÖVEG)
-- kerülhet. A puszta (q->>'max')::int MÉRVE kivételt dob:
--   scale.min='abc'      → ERROR: invalid input syntax for type integer
--   scale.max=99999999999→ ERROR: value out of range for type integer
-- és mivel az echo_templates() MINDEN verzióra meghívja az ellenőrzőt, egyetlen
-- mérgezett sor megölte a teljes admin sablonlistát. A cast tehát soha nem
-- mehet védelem nélkül: ez a két függvény a védelem.
--   echo.jint(x, alap) — biztonságos érték (alapértelmezés, ha nem szám)
--   echo.jint_ok(x)    — TÉNY-e, hogy int-té alakítható 9 jegyen belül
-- A 9 jegy tudatos: az int4 tartománya 10 jegyű, tehát 9 jegy soha nem csordul túl.
create or replace function echo.jint_txt(p jsonb)
returns text
language sql immutable
as $$
  select case jsonb_typeof(p)
           when 'number' then p::text
           when 'string' then p #>> '{}'
           else null end
$$;

create or replace function echo.jint_ok(p jsonb)
returns boolean
language sql immutable
as $$
  select coalesce(echo.jint_txt(p), '') ~ '^-?[0-9]{1,9}$'
$$;

create or replace function echo.jint(p jsonb, p_default integer)
returns integer
language sql immutable
as $$
  select case when echo.jint_ok(p) then echo.jint_txt(p)::int else p_default end
$$;


-- ============================================================
-- 2. SZAKASZ — MODERÁLÁS
-- ============================================================

-- ------------------------------------------------------------
-- 2.1 Az érvénytelenségi kategóriák — ADATKÉNT, nem kódba égetve
-- ------------------------------------------------------------
-- A 3. § (10) felsorolása: érvénytelen az a szöveges vélemény, amely
-- világnézetre, vallásra, etnikai hovatartozásra, nemi identitásra,
-- személyiségre vagy magánéletre irányuló értékelést tartalmaz.
-- A § HIVATKOZÁS BECSLÉS: a 28/2023. szenátusi határozat szövege ebben a
-- környezetben nincs meg (lásd 15_echo_core.sql FORRÁSHŰSÉG szakasz).
-- Ezért ADAT: egyetlen UPDATE-tel pontosítható, kód nélkül.
create table if not exists echo.moderation_reason (
  code       text primary key,
  name_hu    text not null,
  name_en    text,
  paragraph  text,
  sort_order integer not null default 100,
  active     boolean not null default true
);

insert into echo.moderation_reason (code, name_hu, name_en, paragraph, sort_order) values
  ('vilagnezet',     'Vilagnezetre iranyulo ertekeles',        'Evaluation of world view',        '3. § (10)', 10),
  ('vallas',         'Vallasra iranyulo ertekeles',            'Evaluation of religion',          '3. § (10)', 20),
  ('etnikai',        'Etnikai hovatartozasra iranyulo ertekeles','Evaluation of ethnicity',       '3. § (10)', 30),
  ('nemi_identitas', 'Nemi identitasra iranyulo ertekeles',     'Evaluation of gender identity',  '3. § (10)', 40),
  ('szemelyiseg',    'Szemelyisegre iranyulo ertekeles',        'Evaluation of personality',      '3. § (10)', 50),
  ('maganelet',      'Maganeletre iranyulo ertekeles',          'Evaluation of private life',     '3. § (10)', 60),
  ('azonosito',      'Azonosito adatot tartalmaz (kitolto vagy harmadik szemely)',
                     'Contains identifying data', '3. § (10) — kiterjesztett ertelmezes', 70),
  ('serto',          'Serto, emberi meltosagot serto megfogalmazas',
                     'Offensive wording', '3. § (10) — kiterjesztett ertelmezes', 80),
  ('ertelmezhetetlen','Ertelmezhetetlen vagy ures tartalom',    'Uninterpretable content',        'uzemeltetesi', 90)
on conflict (code) do nothing;

-- ------------------------------------------------------------
-- 2.2 A moderálási sor
-- ------------------------------------------------------------
-- FIGYELD MEG, MI NINCS RAJTA: created_at, inserted_at, queued_at, sorszam.
-- Lásd az 1. szerkezeti döntést a fájl fejlécében. A sor a válasszal 1:1-ben
-- áll, tehát bármilyen keletkezési időbélyeg a VÁLASZ datálásává válna.
--
-- MIÉRT NEM MÁSOLJUK IDE A SZÖVEGET ('eredeti szöveg hivatkozás'):
--   a szöveg az echo.response.answers-ben marad, ide csak (response_id,
--   question_id) hivatkozás jön. Ha a szöveget MÁSOLNÁNK, két baj lenne:
--   (a) a másolat sorrendje/ctid-je újabb oldalcsatorna; (b) a "szöveg nem
--   törlődik" követelmény azt jelenti, hogy EGY hiteles példány van, és az az
--   eredeti — nem egy moderálási munkapéldány, ami elsodródhat tőle.
create table if not exists echo.moderation (
  response_id   uuid not null references echo.response(id) on delete cascade,
  question_id   text not null,
  allapot       text not null default 'pending'
                  check (allapot in ('pending','valid','invalid')),
  -- Az érvénytelenség indoka: kategória-kód a echo.moderation_reason-ből.
  indok         text references echo.moderation_reason(code),
  -- Szabad szöveges moderátori megjegyzés az audit-nyomhoz.
  megjegyzes    text,
  -- KI moderált. Ez AZONOSÍTOTT — szándékosan: a moderátor felel a döntéséért.
  -- A moderátor azonosítója a KITÖLTŐRŐL semmit nem mond.
  moderator_key uuid references public.profiles(id) on delete set null,
  -- A MODERÁTOR munkájának ideje. NULL, amíg 'pending'. Ez nem a beküldés
  -- ideje, és a beküldés idejére nem is utal.
  moderalt_at   timestamptz,
  primary key (response_id, question_id),
  constraint echo_moderation_pending_chk
    check ((allapot = 'pending' and moderalt_at is null and moderator_key is null
            and indok is null)
        or (allapot <> 'pending' and moderalt_at is not null)),
  -- Érvénytelenné nyilvánításhoz indok KELL. Ez a jogorvoslat feltétele:
  -- indok nélküli elutasítás nem vitatható.
  constraint echo_moderation_indok_chk
    check (allapot <> 'invalid' or indok is not null)
);
create index if not exists echo_moderation_allapot_idx on echo.moderation (allapot);

comment on table echo.moderation is
  'Szoveges valaszok moderalasa. A SZOVEG NEM TOROLHETO — csak "invalid" '
  'jelolest kap, es kikerul a visszacsatolasbol. TILOS ra barmilyen '
  'keletkezesi idobelyeg-oszlopot felvenni: a sor 1:1-ben all a valasszal, '
  'tehat egy created_at a VALASZ datalasa lenne. Lasd 16_echo_reports.sql fejlec, '
  '1. szerkezeti dontes.';

-- Őrszem, a 6.2 response_schema_ok() mintájára: ha valaki mégis időbélyeget
-- venne fel a moderálási sorra, a 9. szakasz ellenőrző lekérdezése kiabál.
create or replace function echo.moderation_schema_ok()
returns boolean language sql stable
set search_path = echo, public, pg_temp
as $$
  select not exists (
    select 1 from information_schema.columns
     where table_schema = 'echo' and table_name = 'moderation'
       and column_name not in ('moderalt_at')
       and (data_type in ('timestamp with time zone','timestamp without time zone','date')
            or column_name in ('created_at','inserted_at','queued_at','seq','sorszam',
                               'student_key','submission_id'))
  )
$$;


-- ------------------------------------------------------------
-- 2.3 A moderálási sor feltöltése — VÉLETLEN SORRENDBEN
-- ------------------------------------------------------------
-- MIÉRT AZ 'order by random()' A LÉNYEG:
--   az INSERT … SELECT az eredménysorokat abban a sorrendben írja a heapbe,
--   ahogy a SELECT visszaadja. Rendezés nélkül ez a forrástábla
--   olvasási (azaz beszúrási / ctid) sorrendje lenne, vagyis a moderálási
--   tábla ctid-sorrendje LEMÁSOLNÁ a válaszok érkezési sorrendjét — ugyanazt
--   a csatornát, amit a 15_echo_core.sql echo.shuffle_responses()-e bont el.
--   Az ORDER BY random() az INSERT KÜLSŐ SELECT-jén áll (nem albekérdésben),
--   mert csak ott garantált, hogy a végrehajtó tényleg rendezve ad sorokat.
--
-- Melyik kérdés kerül a sorba: amit a KAMPÁNY sablonja 'moderated: true'-nak
-- jelöl és szöveges típusú. Ez nem hardcode: a compiled JSONB-ből jön.
create or replace function echo.moderation_fill(p_campaign uuid)
returns integer
language plpgsql volatile
set search_path = echo, public, extensions, pg_temp
as $$
declare v_n integer;
begin
  insert into echo.moderation (response_id, question_id)
  select x.rid, x.qid
    from (
      select r.id as rid, q.qid
        from echo.response r
        join echo.template_version tv on tv.id = r.template_version_id
        cross join lateral (
          select (qq.value->>'id') as qid
            from jsonb_array_elements(echo.jarr(tv.compiled->'sections')) s
            cross join jsonb_array_elements(echo.jarr(s.value->'questions')) qq
           where coalesce((qq.value->>'moderated')::boolean, false)
             and coalesce(qq.value->>'type','') in ('longtext','text','long')
        ) q
       where r.campaign_id = p_campaign
         and r.answers ? q.qid
         and jsonb_typeof(r.answers -> q.qid) = 'string'
         and coalesce(btrim(r.answers ->> q.qid), '') <> ''
    ) x
   order by random()          -- <<< EZ A SOR A LÉNYEG, lásd fent
      on conflict (response_id, question_id) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;


-- ------------------------------------------------------------
-- 2.4 A moderálási sor MEGKEVERÉSE — a kötegek KÖZÖTTI sorrend ellen
-- ------------------------------------------------------------
-- MI VOLT A BAJ: az 'order by random()' csak EGY kötegen belül kever. A
-- kötegek KÖZÖTT a ctid szigorúan monoton. MÉRVE: az első feltöltés 14 sort
-- írt (0,1)…(0,14) ctid-re; egy új válasz beérkezése után a második hívás új
-- sora (0,15)-re került — vagyis a moderálási tábla fizikai sorrendje
-- CSOPORTONKÉNT rekonstruálja az érkezési sorrendet. A fájl 2. szerkezeti
-- döntése pont ezt zárná ki, és ki is mondja, hogy az echo.shuffle_responses()
-- a moderálási táblát nem érinti — de eddig nem vonta le a következtetést.
--
-- A JAVÍTÁS KÉT LÁBON ÁLL:
--   (a) a moderálási sor mostantól CSAK zárás után tölthető fel (lásd 2.5 és
--       a 6.1 kapuját), tehát a normál üzemben EGYETLEN köteg keletkezik;
--   (b) ez a függvény mégis kell, mert a kampányállapot visszaállítható
--       (processing → …), és mert a 15_echo_core.sql shuffle_responses()-e
--       mellett ez a párja: ha az egyik táblát megkeverjük, a másikat is.
-- A minta AZONOS a shuffle_responses()-szel: DELETE + INSERT véletlen
-- sorrendben, hogy a sorok a heap végére, új fizikai sorrendbe kerüljenek.
create or replace function echo.shuffle_moderation(p_campaign uuid default null)
returns integer
language plpgsql volatile
set search_path = echo, public, pg_temp
as $$
declare n integer;
begin
  drop table if exists _echo_m_shuffle;
  create temporary table _echo_m_shuffle on commit drop as
    select m.*
      from echo.moderation m
      join echo.response r on r.id = m.response_id
     where p_campaign is null or r.campaign_id = p_campaign
     order by random();
  select count(*) into n from _echo_m_shuffle;

  delete from echo.moderation m
   using echo.response r
   where r.id = m.response_id
     and (p_campaign is null or r.campaign_id = p_campaign);

  insert into echo.moderation select * from _echo_m_shuffle;
  return n;
end $$;

comment on function echo.shuffle_moderation(uuid) is
  'A moderalasi sorok fizikai (ctid) sorrendjenek elbontasa. A '
  'echo.shuffle_responses(uuid) parja: ha a valaszokat megkeverjuk, a rajuk '
  'mutato moderalasi sorokat is meg kell. Nyitott kampany alatt naponta, es '
  'minden olyan feltoltes utan, ami uj koteget irt.';


-- ------------------------------------------------------------
-- 2.5 A moderálás IDŐZÍTÉSI KAPUJA
-- ------------------------------------------------------------
-- MI VOLT A BAJ: az összes eredmény-RPC-t az echo.results_gate() zárja a
-- nyitott ablak alatt (mérve: ECHO_RESULTS_NOT_READY még SUPERADMIN-nak is),
-- a moderálási sort viszont SEMMI nem zárta. Mérve, state='open' kampányon,
-- SUPERADMIN-ként: az echo_moderation_queue visszaadta mind a 14 NYERS
-- szöveges választ, course_id-vel és course_name-mel együtt. A nyers szöveg
-- azonosítóbb, mint bármely aggregátum, amit a k_text éppen tilt.
--
-- SAJÁT beállítás (moderation_states), nem a results_admin_states: a moderálás
-- és az eredménynézés két külön jogosultsági kérdés, és lehet, hogy a MIR a
-- kettőt eltérő állapotokhoz akarja kötni. Alapértelmezés: closed, processing,
-- sealed, published — azaz a beküldési ablak lezárása UTÁN.
create or replace function echo.moderation_gate(p_campaign uuid)
returns void
language plpgsql stable
set search_path = echo, public, extensions, pg_temp
as $$
declare v_state text; v_ok text[];
begin
  select state into v_state from echo.campaign where id = p_campaign;
  if v_state is null then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;
  v_ok := coalesce(
    (select string_to_array(replace(value,' ',''), ',') from echo.setting where key='moderation_states'),
    array['closed','processing','sealed','published']);
  if not (v_state = any(v_ok)) then
    raise exception 'ECHO_MODERATION_NOT_READY: a kampany allapota "%", moderalni csak ezekben lehet: %. '
                    'A moderalasi sor NYERS szoveget ad vissza, ezert a nyitott ablak alatt nem nyithato meg.',
      v_state, array_to_string(v_ok, ', ');
  end if;
end $$;


-- ------------------------------------------------------------
-- 2.6 MODERÁLÁSI ELŐZMÉNY — az audit-nyom nem törölhető
-- ------------------------------------------------------------
-- MI VOLT A BAJ: az audit-nyom EGYETLEN HÍVÁSSAL eltüntethető volt. Mérve:
--   echo_moderate(r,'impact_text','invalid','serto','indoklas')
--     → allapot=invalid, indok=serto, moderator_key és moderalt_at kitöltve;
--   utána echo_moderate(r,'impact_text','pending')
--     → MIND a négy mező NULL, nyomtalanul.
-- A fájl azt állította, hogy a döntés "utólag felülvizsgálható" és hogy
-- "indok nélküli elutasítás nem vitatható" — de a moderátor visszavonhatta a
-- saját érvénytelenítését úgy, hogy annak semmi nyoma nem maradt.
--
-- AZ IDŐBÉLYEG ITT BIZTONSÁGOS, és ez fontos: az 'at' a MODERÁTOR munkájának
-- ideje, nem a beküldésé. A moderálás a kampány LEZÁRÁSA UTÁN történik (2.5),
-- tehát a moderálási időpont a beküldés idejéről semmit nem mond. A táblán
-- ezért — és csak ezért — lehet 'at' oszlop, szemben az echo.moderation-nel.
create table if not exists echo.moderation_history (
  id            uuid primary key default gen_random_uuid(),
  response_id   uuid not null,
  question_id   text not null,
  regi_allapot  text,
  uj_allapot    text not null,
  indok         text,
  megjegyzes    text,
  moderator_key uuid references public.profiles(id) on delete set null,
  at            timestamptz not null default now()
);
create index if not exists echo_moderation_history_key_idx
  on echo.moderation_history (response_id, question_id, at desc);

comment on table echo.moderation_history is
  'A moderalasi dontesek valtozasnaploja. NEM torolheto RPC-bol, es a '
  'moderalasi soron vegzett barmely allapot-, indok- vagy megjegyzes-valtozas '
  'ide kerul. Az "at" a MODERATOR munkajanak ideje (a moderalas a kampany '
  'lezarasa utan folyik), nem a bekuldes ideje.';

create or replace function echo.moderation_audit()
returns trigger
language plpgsql
set search_path = echo, public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    -- A puszta feltoltes ('pending' sor keletkezese) NEM dontes, es a
    -- feltoltes egyetlen kotegben tortenik — nem irunk rola elozmenyt, mert
    -- akkor az elozmeny idobelyege lenne egy uj (bar kotegelt) csatorna.
    if new.allapot = 'pending' then return new; end if;
  else
    if new.allapot    is not distinct from old.allapot
       and new.indok      is not distinct from old.indok
       and new.megjegyzes is not distinct from old.megjegyzes then
      return new;   -- nincs erdemi valtozas (pl. a shuffle_moderation no-op update-je)
    end if;
  end if;

  insert into echo.moderation_history
    (response_id, question_id, regi_allapot, uj_allapot, indok, megjegyzes, moderator_key)
  values (new.response_id, new.question_id,
          case when tg_op = 'INSERT' then null else old.allapot end,
          new.allapot, new.indok, new.megjegyzes, new.moderator_key);
  return new;
end $$;

drop trigger if exists echo_moderation_audit_trg on echo.moderation;
create trigger echo_moderation_audit_trg
  after insert or update on echo.moderation
  for each row execute function echo.moderation_audit();


-- ============================================================
-- 3. SZAKASZ — MEGTEKINTÉSI NAPLÓ (6. § (4))
-- ============================================================
-- MI VAN BENNE: ki, milyen szerepben, melyik RPC-vel, melyik kampány /
-- kurzus / oktató bontását nézte meg, és mikor.
-- MI NINCS BENNE ÉS MIÉRT: elemszám, "elrejtve" jelzés, a visszaadott
-- eredmény bármely darabja. Ha benne lenne, a napló olvasója megtudná
-- belőle azt, amit a k-küszöb elrejt előle — a napló lenne a kiskapu.
-- Lásd 4. szerkezeti döntés a fájl fejlécében.
--
-- A sor elsődleges kulcsa v4 uuid, nem bigserial: a napló sorrendje a
-- MEGTEKINTÉSEK sorrendje, ami önmagában ártalmatlan, de nincs okunk
-- külön join-kulcsot gyártani hozzá.
create table if not exists echo.access_log (
  id          uuid primary key default gen_random_uuid(),
  viewer_key  uuid references public.profiles(id) on delete set null,
  viewer_role text,
  rpc         text not null,
  campaign_id uuid,
  course_id   uuid,
  teacher_id  uuid,
  scope       text,
  at          timestamptz not null default now()
);
create index if not exists echo_access_log_viewer_idx on echo.access_log (viewer_key, at desc);
create index if not exists echo_access_log_target_idx on echo.access_log (campaign_id, course_id, at desc);

comment on table echo.access_log is
  'A 6. § (4) szerinti megtekintesi naplo. TILOS bele eredmenyt, elemszamot '
  'vagy "elrejtve" jelzest irni: akkor a naplo maga lenne oldalcsatorna. '
  'A naplosor akkor is keletkezik, ha a valasz teljesen elrejtve tert vissza — '
  'kulonben a naplosor MEGLETE lenne az informacio.';

create or replace function echo.log_access(
  p_rpc text, p_campaign uuid, p_course uuid, p_teacher uuid, p_scope text)
returns void
language plpgsql volatile
set search_path = echo, public, extensions, pg_temp
as $$
begin
  insert into echo.access_log (viewer_key, viewer_role, rpc, campaign_id, course_id, teacher_id, scope)
  values (auth.uid(),
          (select role::text from public.profiles where id = auth.uid()),
          p_rpc, p_campaign, p_course, p_teacher, p_scope);
end $$;

-- Őrszem: a naplón nem lehet eredményt tároló oszlop.
create or replace function echo.access_log_schema_ok()
returns boolean language sql stable
set search_path = echo, public, pg_temp
as $$
  select not exists (
    select 1 from information_schema.columns
     where table_schema='echo' and table_name='access_log'
       and column_name in ('n','elemszam','result','eredmeny','payload','atlag',
                           'rejtve','suppressed','hidden','answers','count')
  )
$$;


-- ============================================================
-- 4. SZAKASZ — AZ AGGREGÁLÓ MOTOR (belső, echo séma)
-- ============================================================
-- Ez a fájl biztonságkritikus része. Minden nyilvános riport-RPC ezeken a
-- függvényeken megy át; a küszöbök NEM az RPC-kben, hanem itt élnek, hogy
-- egy új riport megírásakor ne lehessen véletlenül kihagyni őket.

-- ------------------------------------------------------------
-- 4.1 Opció-normalizálás
-- ------------------------------------------------------------
-- A compiled options tömbje KÉTFÉLE alakú lehet (a seed mindkettőt használja):
--   ["Alma", "Korte"]                              — puszta címkék
--   [{"value":"a","hu":"Alma","en":"Apple"}, ...]  — kódolt opciók
-- Ez a két függvény ezt egységesíti, hogy az eloszlás-számolás ne ágazzon el.
create or replace function echo.opt_value(p_opt jsonb)
returns text
language sql immutable
as $$
  select case when jsonb_typeof(p_opt) = 'object'
              then coalesce(p_opt->>'value', p_opt->>'hu', p_opt->>'en')
              else trim(both '"' from p_opt::text) end
$$;

create or replace function echo.opt_label(p_opt jsonb, p_lang text default 'hu')
returns text
language sql immutable
as $$
  select case when jsonb_typeof(p_opt) = 'object'
              then coalesce(p_opt->>(case when p_lang='en' then 'en' else 'hu' end),
                            p_opt->>'hu', p_opt->>'value')
              else trim(both '"' from p_opt::text) end
$$;

-- ------------------------------------------------------------
-- 4.2 Óralátogatási sáv: a 33%-os küszöb alatt van-e
-- ------------------------------------------------------------
-- A SÁV MOST SZABÁLYOZOTT SZÓTÁR, NEM SZABAD SZÖVEG.
--
-- MI VOLT A BAJ: az előző változat egy címke-regexre épült, és FAIL-OPEN volt
-- (ami nem illett rá, az "nem alacsony"). MÉRVE: '0-25%'→true és '26-50%'→false
-- helyesen, DE '<33%'→false, '0-33%'→false, '33% alatt'→false, 'nem jart'→false.
-- A ma élő sablon négy sávja véletlenül működött; egy kézzel átírt vagy
-- Neptunból jövő címkénél a 3. § (9) szerinti kizárás CSENDBEN megszűnt volna.
--
-- A JAVÍTÁS KÉT RÉSZE:
--   (a) a sávok egy táblában állnak (echo.attendance_band), adatként —
--       a MIR egyetlen INSERT-tel vehet fel újat, kód nélkül;
--   (b) ami NEM szerepel a szótárban, az FAIL-CLOSED: ALACSONYNAK számít,
--       tehát kikerül a jegyzőkönyvi statisztikából. Inkább hiányozzon egy
--       válasz a főstatisztikából, mint hogy egy 33% alatti bekerüljön.
-- A NULL sáv (hiányzó adat) TOVÁBBRA IS a fő halmazba megy: a hiányzó adatból
-- nem következtetünk alacsony óralátogatásra, és a NULL nem "ismeretlen címke".
create table if not exists echo.attendance_band (
  code       text primary key,          -- pontosan az a szoveg, ami a valaszban all
  name_hu    text,
  name_en    text,
  low        boolean not null,          -- a 3. § (9) szerinti kuszob alatt van-e
  sort_order integer not null default 100,
  active     boolean not null default true
);

comment on table echo.attendance_band is
  'A 3. § (9) szerinti oralatogatasi savok SZOTARA. Az echo.attendance_low() '
  'EBBOL olvas, es ami nincs benne, azt ALACSONYNAK veszi (fail-closed). '
  'Uj savot ide kell felvenni, kulonben a valaszai kikerulnek a jegyzokonyvi '
  'statisztikabol — ez a szandekolt, biztonsagos irany.';

insert into echo.attendance_band (code, name_hu, name_en, low, sort_order) values
  ('0-25%',    '0-25%',    '0-25%',    true,  10),
  ('26-50%',   '26-50%',   '26-50%',   false, 20),
  ('51-75%',   '51-75%',   '51-75%',   false, 30),
  ('76-100%',  '76-100%',  '76-100%',  false, 40),
  ('0-33%',    '0-33%',    '0-33%',    true,  11),
  ('<33%',     '33% alatt','below 33%',true,  12),
  ('33% alatt','33% alatt','below 33%',true,  13),
  ('nem jart', 'Nem jart orara','Did not attend', true, 14)
on conflict (code) do nothing;

create or replace function echo.attendance_low(p_band text)
returns boolean
language sql stable
set search_path = echo, public, pg_temp
as $$
  select case
    -- Hianyzo adat: a FO halmazba megy (dokumentalt dontes, valtozatlan).
    when p_band is null or btrim(p_band) = '' then false
    -- A szotarban van: az mondja meg.
    when exists (select 1 from echo.attendance_band b
                  where b.code = btrim(p_band) and b.active)
      then (select b.low from echo.attendance_band b
             where b.code = btrim(p_band) and b.active limit 1)
    -- FAIL-CLOSED: ismeretlen cimke = alacsony.
    else true
  end
$$;

-- ------------------------------------------------------------
-- 4.3 Komplementer-elnyomás — ÚJRAÍRVA, ITERATÍVAN
-- ------------------------------------------------------------
-- MI VOLT A BAJ (mérve a nyilvános public.echo_course_results()-on):
--   Az előző változat, ha PONTOSAN egy cellát kellett elnyomni, elnyomta
--   "a legkisebb láthatót" is — ami a gyakorlatban egy NULLA elemszámú cella
--   volt. A nulla cella viszont a MARADÉKÖSSZEGHEZ nulla darabbal járul hozzá,
--   tehát a kivonás továbbra is EGYETLEN valódi elnyomott cellát ad ki.
--   MÉRT ESET (GAMF-INF-102, 9×7 + 1×6, n=10, k_slice=5): elrejtve az 1-es és
--   a 6-os cella, láthatóan 7→9 és 2..5→0. A látható összeg 9, tehát az
--   elnyomottak összege 10−9 = 1, és mivel az 1-es cella db=0 volt, a 6-os
--   cella pontosan 1. TELJES rekonstrukció, két "elnyomott" cellával.
--
-- A HÁROM FELTÉTEL, AMIT MOST EGYSZERRE KIKÉNYSZERÍTÜNK:
--   (a) legalább KÉT elnyomott cella,
--   (b) az elnyomottak ÖSSZEGE >= k_slice,
--   (c) legalább KETTŐ elnyomottnak db > 0.
--   A (b) az érdemi új feltétel: enélkül a maradékösszeg kicsi és felbontható.
--   A (c) miatt a nulla elemszámú cella SOHA nem lehet önmagában komplemens.
--
-- HA A HÁROM FELTÉTEL NEM TELJESÍTHETŐ (mert nincs elég elnyomható tömeg),
-- akkor az eloszlás EGÉSZBEN elmarad: a függvény NULL-t ad vissza. Ez történik
-- a fenti mért esetben is — a 9×7+1×6 eloszlásból nem lehet olyan részletet
-- közölni, ami ne adná ki a 6-ost.
--
-- AMI EBBŐL ÖNMAGÁBAN NEM ELÉG, ÉS EZÉRT AZ agg_one-BAN IS VAN JAVÍTÁS:
--   a részlegesen elnyomott eloszlás MELLÉ SOHA nem mehet átlag vagy szórás.
--   A mért n=14-es esetben az öt elnyomott cella az n + átlag + szórás három
--   egyenletéből (Σdb=9, Σx=77, Σx²=465) 1..7 tartományon végigenumerálva
--   PONTOSAN EGY megoldást adott: (1,3,4,5,6)=(1,1,1,2,4). Lásd 4.4.
--
-- MULTI TÍPUSNÁL a cellák összege NAGYOBB lehet n-nél (több választás), ezért
-- a "kivonással kiszámolható" érvelés nem áll fenn — de ugyanezt a szabályt
-- alkalmazzuk, mert konzervatív irányba téved.
create or replace function echo.suppress_cells(p_cells jsonb, p_k integer)
returns jsonb
language plpgsql immutable
as $$
declare
  v_cells  jsonb := coalesce(p_cells, '[]'::jsonb);
  v_n      int   := jsonb_array_length(coalesce(p_cells, '[]'::jsonb));
  v_supp   boolean[];
  v_db     int[];
  i        int;
  v_cnt    int := 0;   -- osszes elnyomott cella
  v_nz     int := 0;   -- az elnyomottak kozul a db > 0
  v_sum    int := 0;   -- az elnyomottak osszege
  v_visnz  int := 0;   -- a lathatok kozul a db > 0
  v_min_i  int;
  v_min_v  int;
  v_out    jsonb := '[]'::jsonb;
begin
  if v_n = 0 then return v_cells; end if;

  v_supp := array_fill(false, array[v_n]);
  v_db   := array_fill(0,     array[v_n]);
  for i in 0 .. v_n - 1 loop
    v_db[i+1] := coalesce((v_cells->i->>'db')::int, 0);
  end loop;

  -- 1. lépés: KÖTELEZŐ — minden 0 < db < k cella elnyomva.
  for i in 1 .. v_n loop
    if v_db[i] > 0 and v_db[i] < p_k then
      v_supp[i] := true; v_cnt := v_cnt + 1; v_nz := v_nz + 1; v_sum := v_sum + v_db[i];
    end if;
  end loop;

  -- Ha semmit nem kellett elnyomni, a TELJES eloszlas mehet. (Ilyenkor az
  -- atlag is mehet mellette: egy hiany nelkuli eloszlasbol az atlag amugy is
  -- kiszamolhato, tehat nem ad hozza semmit.)
  if v_cnt = 0 then
    for i in 0 .. v_n - 1 loop
      v_out := v_out || jsonb_build_array((v_cells->i) || jsonb_build_object('rejtve', false));
    end loop;
    return v_out;
  end if;

  -- 2. lépés: ITERATÍV kiegészítés. Amíg az (b) és a (c) feltétel nem
  -- teljesül, elnyomjuk a legkisebb TOVABBI, NEM NULLA cellat. Nulla cellat
  -- itt szandekosan nem valasztunk: nem novelne a maradekosszeget, tehat nem
  -- rontana el a kivonast — pontosan ez volt a regi valtozat hibaja.
  loop
    exit when v_sum >= p_k and v_nz >= 2;
    v_min_i := null; v_min_v := null;
    for i in 1 .. v_n loop
      if not v_supp[i] and v_db[i] > 0 and (v_min_v is null or v_db[i] < v_min_v) then
        v_min_v := v_db[i]; v_min_i := i;
      end if;
    end loop;
    exit when v_min_i is null;                 -- nincs tobb elnyomhato tomeg
    v_supp[v_min_i] := true;
    v_cnt := v_cnt + 1; v_nz := v_nz + 1; v_sum := v_sum + v_min_v;
  end loop;

  -- 3. lépés: az (a) feltétel — legalább KÉT elnyomott cella. Ha idaig csak
  -- egy van, a legkisebb lathato is megy (itt mar a nulla is jo: a darabszam
  -- feltetelt teljesiti, es a (b)-t a 2. lepes mar biztositotta).
  if v_cnt = 1 then
    v_min_i := null; v_min_v := null;
    for i in 1 .. v_n loop
      if not v_supp[i] and (v_min_v is null or v_db[i] < v_min_v) then
        v_min_v := v_db[i]; v_min_i := i;
      end if;
    end loop;
    if v_min_i is not null then
      v_supp[v_min_i] := true; v_cnt := v_cnt + 1;
      if v_min_v > 0 then v_nz := v_nz + 1; v_sum := v_sum + v_min_v; end if;
    end if;
  end if;

  -- 4. lépés: a MÉRLEG. Ha a három feltétel így sem áll, vagy nem maradt
  -- egyetlen látható, nem üres cella sem, akkor az eloszlás nem közölhető.
  -- NULL = "eloszlas nincs"; a hívó (agg_one) ezt kimondja a megtekintőnek.
  v_visnz := 0;
  for i in 1 .. v_n loop
    if not v_supp[i] and v_db[i] > 0 then v_visnz := v_visnz + 1; end if;
  end loop;
  if v_cnt < 2 or v_nz < 2 or v_sum < p_k or v_visnz = 0 then
    return null;
  end if;

  for i in 0 .. v_n - 1 loop
    v_out := v_out || jsonb_build_array(
      case when v_supp[i+1]
           then (v_cells->i) - 'db' || jsonb_build_object('db', null, 'rejtve', true)
           else (v_cells->i) || jsonb_build_object('rejtve', false) end);
  end loop;
  return v_out;
end $$;


-- ------------------------------------------------------------
-- 4.4 Egy kérdés kiértékelése — A KÜSZÖBÖK EGYETLEN HELYEN
-- ------------------------------------------------------------
-- Bemenet: a kérdés definíciója a compiled-ból, és a rá adott válaszértékek
-- JSONB tömbje (csak azok, ahol a kérdés-ID egyáltalán szerepel a válaszban).
--
-- A HÁROM LÉPCSŐ — ÉS AMI AZ ELLENŐRZÉS UTÁN MEGVÁLTOZOTT BENNE:
--   n < k_numeric  → semmi. (ÚJ: feltétel [cond] mögötti kérdésnél az
--                    ELEMSZÁM SEM, mert az egy MÁSIK kérdés cellája.)
--   n < k_dist     → SEMMILYEN SZÁMSZERŰ MUTATÓ. (ÚJ: korábban itt ment
--                    vissza átlag ÉS szórás — lásd az indoklást lejjebb.)
--   n >= k_dist    → eloszlás cellánként k_slice-szal és komplementer-
--                    elnyomással; ÁTLAG CSAK AKKOR, HA AZ ELOSZLÁS HIÁNYTALAN.
--
-- MIÉRT NEM MEHET ÁTLAG A k_dist ALATT (mérve, majd 1..7 tartományon TELJES
-- enumerációval ellenőrizve — a korlátos egész skálán n + átlag + szórás
-- gyakran EGYÉRTELMŰEN meghatározza a teljes válasz-multihalmazt):
--     n=5, atlag=7.00, szoras=0.00 → 1 megoldas: (7,7,7,7,7)
--     n=5, atlag=6.00, szoras=2.24 → 1 megoldas: (2,7,7,7,7)
--     n=9, atlag=6.33, szoras=2.00 → 1 megoldas: (1,7,7,7,7,7,7,7,7)
--   Az utolsóban a kurzus EGYETLEN elégedetlen hallgatójának pontos válasza
--   derül ki egy 9 fős halmazban. Az "anonimitási halmaz n−1" érvelés itt nem
--   áll: a halmaz mérete NULLA. Ezért ebben a sávban csak az n megy vissza.
--
-- MIÉRT NEM MEHET ÁTLAG A RÉSZLEGESEN ELNYOMOTT ELOSZLÁS MELLÉ (ugyanígy
-- mérve, a szerző saját bemutató esetén): n=14, atlag=5.50, szoras=1.79,
--   látható 7→5 és 2→0, elrejtve 1,3,4,5,6. A három egyenlet
--   (Σdb=9, Σx=77, Σx²=465) fölött 1..7-en végigenumerálva PONTOSAN EGY
--   megoldás van: (1,3,4,5,6)=(1,1,1,2,4) — MIND AZ ÖT "elrejtett" cella
--   visszanyerhető. A cellánkénti elnyomás és az átlag EGYÜTT nem adható:
--   vagy a teljes eloszlás megy (akkor az átlag belőle amúgy is kiszámolható,
--   tehát ingyen van), vagy semmilyen momentum nem megy.
--
-- A SZÓRÁS SEHOL NEM MEGY VISSZA. Ahol az eloszlás hiánytalan, ott a kliens
-- kiszámolja belőle (a features/echo.jsx ezt teszi); ahol nem hiánytalan, ott
-- éppen ez a mező volt a szivárgás. Egy mező, ami csak ott adna újat, ahol
-- tilos — nincs értelme visszaadni.
--
-- Az elemszám (n) egyébként visszamegy: enélkül a megtekintő nem tudná, hogy
-- azért nem lát semmit, mert kevesen válaszoltak, vagy mert hiba van. A
-- KIVÉTEL a feltétel mögötti kérdés, lásd fent.
create or replace function echo.agg_one(p_q jsonb, p_vals jsonb)
returns jsonb
language plpgsql stable
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_type  text := coalesce(p_q->>'type','');
  v_vals  jsonb := coalesce(p_vals, '[]'::jsonb);
  v_n     int  := jsonb_array_length(coalesce(p_vals, '[]'::jsonb));
  v_kn    int  := echo.k('k_numeric');
  v_kd    int  := echo.k('k_dist');
  v_ks    int  := echo.k('k_slice');
  v_base  jsonb;
  v_atlag numeric := null;
  v_cells jsonb := null;
  v_egyeb int;
  v_lo int; v_hi int;
  v_cond  boolean;
  v_teljes boolean;
begin
  -- Feltétel (cond) mögött áll-e a kérdés. Ha igen, az ELEMSZÁMA maga is
  -- közlés a feltételt adó kérdésről: mérve, 12 válaszos kurzuson a
  -- goals_met kérdés n=2-t adott vissza rejtve=true mellett, amiből a
  -- megtekintő megtudta, hogy pontosan 2 fő tűzött ki tanulási célt —
  -- miközben az echo.student_goal AZONOSÍTOTT tábla, tehát a "kik" oldal is
  -- megvan az adminnál.
  v_cond := (p_q->'cond') is not null and jsonb_typeof(p_q->'cond') = 'object';

  v_base := jsonb_build_object(
    'id',   p_q->>'id',
    'type', v_type,
    'hu',   p_q->>'hu',
    'en',   p_q->>'en',
    'n',    v_n,
    'feltetel_mogott', v_cond);

  -- 1. lépcső: a kérdés meg sem szólal
  if v_n < v_kn then
    if v_cond then
      -- Az elemszám SEM megy vissza, és az üzenetben SINCS benne a szám:
      -- a régi üzenet ("Keves valasz (2 < k_numeric=5)") maga volt a szivárgás.
      return v_base || jsonb_build_object(
        'n', null,
        'rejtve', true, 'rejtes_oka', 'keves_valasz_feltetel_mogott',
        'uzenet', 'A k_numeric=' || v_kn || ' kuszob alatt vagyunk. Errol a kerdesrol semmit '
                  'nem adunk vissza — az ELEMSZAMOT sem: a kerdes megjelenitesi feltetel mogott '
                  'all, tehat az elemszama a FELTETELT ADO kerdes egyik cellaja lenne.',
        'atlag', null, 'eloszlas', null);
    end if;
    return v_base || jsonb_build_object(
      'rejtve', true, 'rejtes_oka', 'keves_valasz',
      'uzenet', 'Keves valasz (' || v_n || ' < k_numeric=' || v_kn || '): errol a kerdesrol nem adunk vissza eredmenyt.',
      'atlag', null, 'eloszlas', null);
  end if;

  -- Szöveges kérdés: a tartalmat NEM itt kezeljük (moderálás kell hozzá),
  -- csak az elemszámot adjuk vissza. A hívó tölti fel a 'szovegek' mezőt.
  if v_type in ('longtext','text','long') then
    return v_base || jsonb_build_object(
      'rejtve', false, 'rejtes_oka', null, 'atlag', null, 'eloszlas', null,
      'szoveges', true);
  end if;

  -- 2. lépcső: a k_dist alatti sávban SEMMILYEN számszerű mutató.
  if v_n < v_kd then
    return v_base || jsonb_build_object(
      'rejtve', false, 'rejtes_oka', 'kis_elemszam_nincs_eloszlas',
      'uzenet', 'Kis elemszam (' || v_n || ' < k_dist=' || v_kd || '): ebben a savban SEMMILYEN '
                'szamszeru mutato nem adhato vissza — sem atlag, sem szoras, sem eloszlas. '
                'Korlatos egesz skalan az (n, atlag, szoras) harmas gyakran EGYERTELMUEN '
                'meghatarozza a teljes valaszhalmazt (merve: n=9, atlag=6.33, szoras=2.00 '
                'eseten pontosan egy megoldas letezik).',
      'atlag', null, 'eloszlas', null);
  end if;

  -- Átlag: csak ott, ahol a válasz szám. A skálán mindig kiszámoljuk, de
  -- CSAK a hiánytalan eloszlás mellé adjuk vissza (lásd a fejlécet).
  if v_type = 'scale' then
    select round(avg(x), 2)
      into v_atlag
      from (select (e.value)::text::numeric as x
              from jsonb_array_elements(v_vals) e
             where jsonb_typeof(e.value) = 'number') t;
  end if;

  -- 3. lépcső: eloszlás
  if v_type = 'scale' then
    -- VÉDETT CAST + FELSŐ KORLÁT. Mérve: {"min":1,"max":20000} skálára a régi
    -- változat 20 000 cellás eloszlást adott vissza EGYETLEN kérdésre, és egy
    -- max=2000000000 skála a generate_series-szel megállította volna a szervert.
    -- A szerkesztő Max mezője <input type=number>, tehát ez begépelhető.
    v_lo := echo.jint(p_q->'scale'->'min', 1);
    v_hi := echo.jint(p_q->'scale'->'max', 5);
    if v_hi <= v_lo or (v_hi - v_lo) > 100 then
      return v_base || jsonb_build_object(
        'rejtve', true, 'rejtes_oka', 'tul_szeles_skala',
        'uzenet', 'A kerdes skalaja ertelmezhetetlen vagy tul szeles (' || v_lo || '..' || v_hi ||
                  '): cellankenti bontast nem keszitunk. Javitsd a kerdoiv-verziot '
                  '(az ellenorzes "tul_szeles_skala" tetelkent is jelzi).',
        'atlag', null, 'eloszlas', null);
    end if;
    select jsonb_agg(jsonb_build_object(
             'ertek', g, 'cimke', g::text,
             'db', (select count(*) from jsonb_array_elements(v_vals) e
                     where jsonb_typeof(e.value)='number'
                       and (e.value)::text::numeric = g)) order by g)
      into v_cells
      from generate_series(v_lo, v_hi) g;

  elsif v_type = 'multi' then
    -- Több választás: a cellák összege nagyobb lehet n-nél.
    select jsonb_agg(jsonb_build_object(
             'ertek', echo.opt_value(o.value), 'cimke', echo.opt_label(o.value),
             'db', (select count(*) from jsonb_array_elements(v_vals) e
                     where jsonb_typeof(e.value)='array'
                       and exists (select 1 from jsonb_array_elements(e.value) v
                                    where trim(both '"' from v.value::text) = echo.opt_value(o.value))))
             order by o.ordinality)
      into v_cells
      from jsonb_array_elements(echo.jarr(p_q->'options')) with ordinality o;

  else
    -- single / skip / attendance és minden más egyértékű típus
    select jsonb_agg(jsonb_build_object(
             'ertek', echo.opt_value(o.value), 'cimke', echo.opt_label(o.value),
             'db', (select count(*) from jsonb_array_elements(v_vals) e
                     where trim(both '"' from e.value::text) = echo.opt_value(o.value)))
             order by o.ordinality)
      into v_cells
      from jsonb_array_elements(echo.jarr(p_q->'options')) with ordinality o;

    -- Az opciólistán kívüli ("egyéb", allowOther) válaszok egyetlen cellába.
    -- A SZABAD SZÖVEGÜKET NEM adjuk vissza: az "egyéb" mező szövege ugyanolyan
    -- azonosító, mint egy szabadszöveges válasz, moderálás nélkül pedig nem
    -- mehet ki. Csak a darabszám megy.
    select count(*) into v_egyeb
      from jsonb_array_elements(v_vals) e
     where not exists (select 1 from jsonb_array_elements(echo.jarr(p_q->'options')) o
                        where echo.opt_value(o.value) = trim(both '"' from e.value::text));
    if coalesce(v_egyeb,0) > 0 or coalesce((p_q->>'allowOther')::boolean,false) then
      v_cells := coalesce(v_cells,'[]'::jsonb) || jsonb_build_array(
        jsonb_build_object('ertek','__egyeb__','cimke','Egyeb / listan kivuli','db', coalesce(v_egyeb,0)));
    end if;
  end if;

  v_cells := echo.suppress_cells(v_cells, v_ks);

  -- HA AZ ELOSZLÁS EGÉSZBEN ELMARADT (a suppress_cells nem tudta teljesíteni a
  -- három feltételt): akkor SEMMILYEN momentum nem mehet mellé. Ilyenkor a
  -- kérdésről csak az elemszám és az ok megy vissza.
  if v_cells is null then
    return v_base || jsonb_build_object(
      'rejtve', false, 'rejtes_oka', 'eloszlas_nem_kozolheto',
      'uzenet', 'Az eloszlas ebben a formaban nem kozolheto: az elnyomando cellak egyuttes '
                'elemszama nem eri el a k_slice=' || v_ks || ' kuszobot, tehat a maradekosszegbol '
                'kivonassal vissza lehetne szamolni oket. Atlagot sem adunk vissza, mert az '
                'ugyanezt a kivonast tenne lehetove.',
      'atlag', null, 'eloszlas', null, 'k_slice', v_ks);
  end if;

  -- HIÁNYTALAN-E az eloszlás? Ha igen, az átlag mehet (belőle amúgy is
  -- kiszámolható). Ha nem, az átlag ELMARAD — ez a blocker javítása.
  select not exists (select 1 from jsonb_array_elements(v_cells) e
                      where coalesce((e.value->>'rejtve')::boolean, false))
    into v_teljes;

  return v_base || jsonb_build_object(
    'rejtve', false, 'rejtes_oka', null,
    'atlag',        case when v_teljes then v_atlag else null end,
    'atlag_rejtve', not v_teljes,
    'atlag_oka',    case when v_teljes then null else 'reszlegesen_elnyomott_eloszlas' end,
    'eloszlas', v_cells,
    'k_slice', v_ks);
end $$;


-- ------------------------------------------------------------
-- 4.5 A teljes riport összeállítása
-- ------------------------------------------------------------
-- p_scope = 'course'  → a kurzusszintű válaszok (teacher_id is null)
-- p_scope = 'teacher' → egy adott oktató sorai
--
-- A KÉRDÉSEK SZÉTOSZTÁSA a compiled-ból számított, nem hardcode: amelyik
-- kérdésen repeat='teacher', az oktatói kérdés, a többi kurzusszintű.
--
-- AZ ALACSONY ÓRALÁTOGATÁSÚ BLOKK (3. § (9)) csak a kurzusszintű riportban
-- tud kitöltődni — az attendance_band kizárólag a kurzusszintű soron áll
-- (echo_response_att_scope_chk), és a kurzus- meg az oktatói sor között
-- SZÁNDÉKOSAN nincs közös kulcs. Lásd a fájl fejlécében az "AMIT EZ A SZELET
-- NEM TUD" szakaszt. Oktatói riportnál a blokk mindig üres, kimondott okkal.
create or replace function echo.results_build(
  p_campaign uuid, p_course uuid, p_teacher uuid, p_scope text, p_admin boolean)
returns jsonb
language plpgsql volatile
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_c        echo.campaign%rowtype;
  v_compiled jsonb;
  v_fo   uuid[];
  v_lo   uuid[];
  v_kn   int := echo.k('k_numeric');
  v_kt   int := echo.k('k_text');
  v_klow int := echo.k('k_low');
  q      jsonb;
  v_qid  text;
  v_vals jsonb;
  v_one  jsonb;
  v_txt  jsonb;
  v_txtn int;
  v_fo_q   jsonb := '[]'::jsonb;
  v_lo_q   jsonb := '[]'::jsonb;
  v_jog  int;
  v_pend int := 0;
  v_out  jsonb;
begin
  select * into v_c from echo.campaign where id = p_campaign;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;
  select compiled into v_compiled from echo.template_version where id = v_c.template_version_id;
  if v_compiled is null then raise exception 'ECHO_TEMPLATE_MISSING'; end if;

  -- A válaszhalmaz kettéosztása. A NULL attendance_band a FŐ halmazba megy:
  -- a hiányzó adatból nem következtetünk alacsony óralátogatásra.
  if p_scope = 'teacher' then
    select coalesce(array_agg(r.id), '{}') into v_fo
      from echo.response r
     where r.campaign_id = p_campaign and r.course_id = p_course
       and r.scope = 'teacher' and r.teacher_id = p_teacher;
    v_lo := '{}';
  else
    select coalesce(array_agg(r.id) filter (where not echo.attendance_low(r.attendance_band)), '{}'),
           coalesce(array_agg(r.id) filter (where     echo.attendance_low(r.attendance_band)), '{}')
      into v_fo, v_lo
      from echo.response r
     where r.campaign_id = p_campaign and r.course_id = p_course and r.scope = 'course';
  end if;

  select count(*) into v_jog
    from echo.participation p
   where p.campaign_id = p_campaign and p.course_id = p_course and p.eligible;

  -- GLOBÁLIS KÜSZÖB: ha a teljes halmaz k_numeric alatt van, a riport
  -- egészben elrejtődik. Kérdésenkénti kiértékelésre el sem jutunk — így
  -- még a "mely kérdésre hányan válaszoltak" mintázat sem szivárog ki.
  if coalesce(array_length(v_fo,1),0) < v_kn then
    return jsonb_build_object(
      'campaign_id', p_campaign, 'course_id', p_course, 'teacher_id', p_teacher,
      'scope', p_scope,
      'kuszobok', jsonb_build_object('k_numeric', v_kn, 'k_dist', echo.k('k_dist'),
                                     'k_text', v_kt, 'k_slice', echo.k('k_slice'),
                                     'k_low', v_klow,
                                     'attendance_min_pct', echo.k('attendance_min_pct')),
      'valaszadas', jsonb_build_object('jogosult', v_jog,
                                       'valaszok', coalesce(array_length(v_fo,1),0),
                                       'arany', null),
      'rejtve', true, 'rejtes_oka', 'keves_valasz',
      'uzenet', 'Keves valasz (' || coalesce(array_length(v_fo,1),0) || ' < k_numeric=' || v_kn ||
                '): ez a bontas nem jelenitheto meg.',
      'kerdesek', '[]'::jsonb,
      -- AZ 'n' ITT NULL. Mert ha a blokk rejtve van, akkor a k_low alatti
      -- ELEMSZAM MAGA a kozles: merve, 10 fos fo halmaz mellett 1 alacsony
      -- oralatogatasu valasznal a regi valtozat {"n":1,"rejtve":true}-t adott,
      -- vagyis a megtekinto pontosan megtudta, hogy egy ember vallott be 33%
      -- alatti oralatogatast. Egy k_low alatti, erzekeny attributumra vonatkozo
      -- PONTOS darabszam — pont az, amit a k_low tiltana.
      'alacsony_oralatogatas', jsonb_build_object('n', null, 'k_low', v_klow,
                                                  'rejtve', true, 'kerdesek', '[]'::jsonb));
  end if;

  -- Kérdésenkénti kiértékelés
  --
  -- AZ 'attendance' KÉRDÉS KIMARAD — ÉS EZ NEM ADATVESZTÉS, HANEM HIBAJAVÍTÁS.
  -- MÉRT PROBLÉMA (13 valódi beküldésen): az óralátogatás a jegyzőkönyvben
  -- MINDIG n=0-val és "Keves valasz (0 < k_numeric=5)" üzenettel jelent meg,
  -- pedig mind a 13 válaszadó kitöltötte. Az ok szerkezeti: az echo_submit()
  -- az óralátogatást a payload GYÖKERÉBŐL a KÜLÖN echo.response.attendance_band
  -- OSZLOPBA teszi (15_echo_core.sql, 5. lépés), az answers-be soha nem kerül
  -- bele — ez a ciklus viszont az r.answers -> v_qid kifejezéssel keresi.
  -- Vagyis a keresés helye és a tárolás helye sosem esett egybe.
  -- Az adat nem veszett el: az óralátogatás a 3. § (9) szerinti FŐ/ALACSONY
  -- kettéosztást vezérli (lásd fent, echo.attendance_low), és az
  -- 'alacsony_oralatogatas' blokk közli, amennyit a k_low enged. A hamis
  -- "kevés válasz" sor viszont félrevezette a jegyzőkönyv olvasóját, ezért
  -- itt kihagyjuk a kérdéslistából.
  -- MIÉRT ID SZERINT ÉS NEM TÍPUS SZERINT: a 18b seed a prototípus
  -- type:'attendance' mezőjét 'single'-re fordítja (a renderelő öt típust
  -- ismer), tehát típusra szűrni nem lehet — mérve.
  -- HA VALAHA KELL AZ ELOSZLÁS: azt az attendance_band OSZLOPBÓL kell
  -- aggregálni (echo.suppress_cells-lel, k_dist küszöbbel), nem az answers-ből.
  for q in
    select qq.value
      from jsonb_array_elements(echo.jarr(v_compiled->'sections')) s
      cross join jsonb_array_elements(echo.jarr(s.value->'questions')) qq
     where case when p_scope = 'teacher'
                then coalesce(qq.value->>'repeat','') = 'teacher'
                else coalesce(qq.value->>'repeat','') <> 'teacher' end
       and coalesce(qq.value->>'id','') <> 'attendance'
  loop
    v_qid := q->>'id';

    -- FŐ halmaz
    select coalesce(jsonb_agg(r.answers -> v_qid), '[]'::jsonb) into v_vals
      from echo.response r
     where r.id = any(v_fo)
       and jsonb_exists(r.answers, v_qid)
       and jsonb_typeof(r.answers -> v_qid) <> 'null';
    v_one := echo.agg_one(q, v_vals);

    -- Szöveges kérdés: CSAK moderált ÉS érvényes válaszokból, k_text fölött.
    if coalesce(q->>'type','') in ('longtext','text','long') then
      select count(*), coalesce(jsonb_agg(r.answers ->> v_qid order by md5(r.id::text)), '[]'::jsonb)
        into v_txtn, v_txt
        from echo.response r
        join echo.moderation m on m.response_id = r.id and m.question_id = v_qid
       where r.id = any(v_fo) and m.allapot = 'valid';

      if v_txtn < v_kt then
        v_one := v_one || jsonb_build_object(
          'szovegek', null, 'szoveg_db', v_txtn, 'szoveg_rejtve', true,
          'szoveg_oka', 'keves_ervenyes_szoveg',
          'szoveg_uzenet', 'Moderalt, ervenyes szoveges valasz: ' || v_txtn ||
                           ' < k_text=' || v_kt || '. Egyetlen szoveg sem jelenitheto meg.');
      else
        v_one := v_one || jsonb_build_object(
          'szovegek', v_txt, 'szoveg_db', v_txtn, 'szoveg_rejtve', false, 'szoveg_oka', null);
      end if;

      -- A moderálásra váró darabszám CSAK adminnak megy vissza: az oktatónak
      -- ebbol arra lehetne kovetkeztetni, hany szoveg van meg "fuggoben" rola.
      if p_admin then
        select count(*) into v_pend
          from echo.moderation m
         where m.response_id = any(v_fo) and m.question_id = v_qid and m.allapot = 'pending';
        v_one := v_one || jsonb_build_object('moderalatlan', v_pend);
      end if;
    end if;

    v_fo_q := v_fo_q || jsonb_build_array(v_one);

    -- ALACSONY ÓRALÁTOGATÁSÚ BLOKK — saját küszöbbel (k_low), és a fő
    -- statisztikába NEM számít bele (3. § (9)). Szöveget innen SOHA nem
    -- adunk vissza: a halmaz eleve kicsi, egy szöveg itt azonosítana.
    if coalesce(array_length(v_lo,1),0) >= v_klow then
      select coalesce(jsonb_agg(r.answers -> v_qid), '[]'::jsonb) into v_vals
        from echo.response r
       where r.id = any(v_lo)
         and jsonb_exists(r.answers, v_qid)
         and jsonb_typeof(r.answers -> v_qid) <> 'null';
      v_lo_q := v_lo_q || jsonb_build_array(
        echo.agg_one(q, v_vals) || jsonb_build_object('szovegek', null, 'szoveg_rejtve', true));
    end if;
  end loop;

  v_out := jsonb_build_object(
    'campaign_id',   p_campaign,
    'campaign_code', v_c.code,
    'campaign_state',v_c.state,
    'course_id',     p_course,
    'course_name',   (select name_hu from echo.course where id = p_course),
    'teacher_id',    p_teacher,
    'teacher_name',  (select name from echo.teacher where id = p_teacher),
    'scope',         p_scope,
    'kuszobok', jsonb_build_object('k_numeric', v_kn, 'k_dist', echo.k('k_dist'),
                                   'k_text', v_kt, 'k_slice', echo.k('k_slice'),
                                   'k_low', v_klow,
                                   'attendance_min_pct', echo.k('attendance_min_pct')),
    'valaszadas', jsonb_build_object(
      'jogosult', v_jog,
      'valaszok', coalesce(array_length(v_fo,1),0),
      'arany',    round(coalesce(array_length(v_fo,1),0)::numeric / nullif(v_jog,0) * 100, 1)),
    'rejtve', false,
    'kerdesek', v_fo_q,
    'alacsony_oralatogatas', jsonb_build_object(
      -- Ugyanaz a javitas: az elemszam CSAK akkor megy vissza, ha a blokk
      -- egyaltalan megjelenik (n >= k_low). Alatta null, nem 0 es nem a
      -- valodi szam — kulonben a k_low semmit nem vedene.
      'n', case when coalesce(array_length(v_lo,1),0) >= v_klow
                then coalesce(array_length(v_lo,1),0) else null end,
      'k_low', v_klow,
      'rejtve', coalesce(array_length(v_lo,1),0) < v_klow,
      'kerdesek', v_lo_q,
      'megjegyzes', case
        when p_scope = 'teacher'
          then 'Oktatoi bontasban ez a blokk MINDIG ures: az oralatogatasi sav kizarolag '
               'a kurzusszintu valaszsoron all, es a kurzusszintu meg az oktatoi sor kozott '
               'szandekosan nincs kozos kulcs (15_echo_core.sql, 6.2). Lasd a fajl fejlecet.'
        else '3. § (9): ezek a valaszok NEM szamitanak a jegyzokonyvi statisztikaba. '
             'Szoveges valasz innen soha nem kerul vissza.' end));

  return v_out;
end $$;


-- ============================================================
-- 5. SZAKASZ — PUBLIC RIPORT-RPC-K
-- ============================================================

-- ------------------------------------------------------------
-- 5.1 Jogosultsági és időzítési kapuk (belső)
-- ------------------------------------------------------------
-- Az oktató azonosítása: az a bejelentkezett fiók, amelyre valamelyik
-- echo.teacher.profile_id mutat. Ma ez NULL minden soron (a Neptun-szinkron
-- fogja kitölteni), tehát ma CSAK admin lát eredményt — ez a biztonságos
-- alapállapot, nem hiba.
create or replace function echo.my_teacher_id()
returns uuid
language sql stable
set search_path = echo, public, extensions, pg_temp
as $$ select t.id from echo.teacher t where t.profile_id = auth.uid() limit 1 $$;

-- Az eredmény IDŐZÍTÉSE. A nyitott ablak alatt senki nem lát eredményt:
-- a menet közben látszó átlag visszahat a még kitöltetlen kérdőívekre.
create or replace function echo.results_gate(p_campaign uuid, p_admin boolean)
returns void
language plpgsql stable
set search_path = echo, public, extensions, pg_temp
as $$
declare v_state text; v_ok text[];
begin
  select state into v_state from echo.campaign where id = p_campaign;
  if v_state is null then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;
  v_ok := echo.allowed_states(case when p_admin then 'results_admin_states' else 'results_teacher_states' end);
  if not (v_state = any(v_ok)) then
    raise exception 'ECHO_RESULTS_NOT_READY: a kampany allapota "%", eredmeny csak ezekben: %.',
      v_state, array_to_string(v_ok, ', ');
  end if;
end $$;

-- ------------------------------------------------------------
-- 5.2 public.echo_teacher_results(kampány, kurzus, oktató)
-- ------------------------------------------------------------
-- JOGOSULTSÁG:
--   • oktató  → KIZÁRÓLAG a saját oktatói bontását. p_teacher lehet NULL
--               (= önmaga) vagy a saját azonosítója; bármi más ECHO_FORBIDDEN.
--   • admin   → a kurzus bármely oktatója; p_teacher NULL esetén MINDEGYIK.
-- NAPLÓZÁS: minden visszaadott bontás EGY sort ír az echo.access_log-ba,
-- akkor is, ha a bontás elrejtve tér vissza (lásd 4. szerkezeti döntés).
create or replace function public.echo_teacher_results(
  p_campaign uuid, p_course uuid, p_teacher uuid default null)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_me    uuid := auth.uid();
  v_admin boolean;
  v_mine  uuid;
  v_ids   uuid[];
  t       uuid;
  v_arr   jsonb := '[]'::jsonb;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;

  v_admin := public.is_admin();
  v_mine  := echo.my_teacher_id();

  if not v_admin and v_mine is null then
    -- Sem admin, sem oktatóhoz kötött fiók: itt nincs keresnivalója.
    raise exception 'ECHO_FORBIDDEN: a fiok nincs oktatoi sorhoz kotve, es nem admin.';
  end if;

  if v_admin then
    if p_teacher is null then
      select coalesce(array_agg(ct.teacher_id order by ct.teacher_id), '{}') into v_ids
        from echo.course_teacher ct where ct.course_id = p_course;
    else
      v_ids := array[p_teacher];
    end if;
  else
    -- OKTATÓ: a paraméter csak önmaga lehet. EZ A LÉNYEGI KAPU.
    if p_teacher is not null and p_teacher <> v_mine then
      raise exception 'ECHO_FORBIDDEN: oktatokent kizarolag a sajat eredmenyed kerheto le.';
    end if;
    -- Ráadásul a kurzusnak is a sajátjának kell lennie.
    if not exists (select 1 from echo.course_teacher ct
                    where ct.course_id = p_course and ct.teacher_id = v_mine) then
      raise exception 'ECHO_FORBIDDEN: nem oktatod ezt a kurzust.';
    end if;
    v_ids := array[v_mine];
  end if;

  perform echo.results_gate(p_campaign, v_admin);

  foreach t in array coalesce(v_ids, '{}'::uuid[]) loop
    -- NAPLÓ ELŐSZÖR, EREDMÉNY UTÁNA. Így ha a riport épít, a napló már áll;
    -- ha a riport hibára fut, az egész tranzakció visszagördül (a naplósor is) —
    -- ez a Postgres autonóm tranzakció hiányának ára, kimondva a fájl fejlécében.
    perform echo.log_access('echo_teacher_results', p_campaign, p_course, t, 'teacher');
    v_arr := v_arr || jsonb_build_array(
      echo.results_build(p_campaign, p_course, t, 'teacher', v_admin));
  end loop;

  return jsonb_build_object(
    'campaign_id', p_campaign, 'course_id', p_course,
    'hivo', case when v_admin then 'admin' else 'oktato' end,
    'oktatok', v_arr);
end $$;

-- ------------------------------------------------------------
-- 5.3 public.echo_course_results(kampány, kurzus)
-- ------------------------------------------------------------
-- Ugyanazok a küszöbök, kurzusszintű válaszokra. Itt MŰKÖDIK az alacsony
-- óralátogatású blokk szétválasztása (3. § (9)), mert az attendance_band a
-- kurzusszintű soron áll.
-- JOGOSULTSÁG: admin, vagy a kurzust oktató (oktatóhoz kötött) fiók.
create or replace function public.echo_course_results(p_campaign uuid, p_course uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_me    uuid := auth.uid();
  v_admin boolean;
  v_mine  uuid;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;

  v_admin := public.is_admin();
  v_mine  := echo.my_teacher_id();

  if not v_admin then
    if v_mine is null then
      raise exception 'ECHO_FORBIDDEN: a fiok nincs oktatoi sorhoz kotve, es nem admin.';
    end if;
    if not exists (select 1 from echo.course_teacher ct
                    where ct.course_id = p_course and ct.teacher_id = v_mine) then
      raise exception 'ECHO_FORBIDDEN: nem oktatod ezt a kurzust.';
    end if;
  end if;

  perform echo.results_gate(p_campaign, v_admin);
  perform echo.log_access('echo_course_results', p_campaign, p_course, null, 'course');

  return echo.results_build(p_campaign, p_course, null, 'course', v_admin);
end $$;


-- ============================================================
-- 6. SZAKASZ — MODERÁLÁSI RPC-K
-- ============================================================

-- ------------------------------------------------------------
-- 6.1 public.echo_moderation_queue(kampány)
-- ------------------------------------------------------------
-- A moderálásra váró szövegek. A visszaadott sorrend md5(response_id ||
-- question_id) szerinti — NEM ctid, NEM beszúrási sorrend. Enélkül a
-- moderátor képernyője maga adná vissza az érkezési sorrendet.
--
-- MI MEGY VISSZA ÉS MI NEM: a szöveg és a kérdés megy (enélkül nem lehet
-- moderálni), a kurzus neve megy (enélkül nem lehet megítélni, hogy egy
-- utalás azonosít-e), az OKTATÓ NEVE NEM megy — a kurzusszintű szövegnél
-- amúgy sincs oktató, és a moderátornak nem is kell tudnia, kiről szól.
create or replace function public.echo_moderation_queue(p_campaign uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_new int; v_out jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  -- KAPU (javitva: az ellenorzes szerint ez hianyzott).
  -- A nyers szabadszoveg AZONOSITOBB, mint barmely aggregatum, amit a k_text tilt.
  -- Nyitott ablak alatt ezert egyaltalan nem adhato ki: a moderalas a kampany
  -- lezarasa UTAN kezdodik. Merve: e nelkul a nyitott kampany mind a 14 nyers
  -- szoveges valaszat visszaadta, kurzusnevvel egyutt.
  if (select state from echo.campaign where id = p_campaign)
     not in ('closed','processing','sealed','published') then
    raise exception 'ECHO_MODERATION_NOT_OPEN';
  end if;

  v_new := echo.moderation_fill(p_campaign);
  perform echo.log_access('echo_moderation_queue', p_campaign, null, null, 'moderation');

  select coalesce(jsonb_agg(x order by x->>'rend'), '[]'::jsonb) into v_out
  from (
    select jsonb_build_object(
             'response_id', m.response_id,
             'question_id', m.question_id,
             'kerdes_hu',   qd.hu,
             'kerdes_en',   qd.en,
             'course_id',   r.course_id,
             'course_name', k.name_hu,
             'scope',       r.scope,
             'szoveg',      r.answers ->> m.question_id,
             'rend',        md5(m.response_id::text || m.question_id)
           ) as x
      from echo.moderation m
      join echo.response r on r.id = m.response_id
      join echo.course   k on k.id = r.course_id
      left join lateral (
        select qq.value->>'hu' as hu, qq.value->>'en' as en
          from echo.template_version tv
          cross join jsonb_array_elements(echo.jarr(tv.compiled->'sections')) s
          cross join jsonb_array_elements(echo.jarr(s.value->'questions')) qq
         where tv.id = r.template_version_id and qq.value->>'id' = m.question_id
         limit 1
      ) qd on true
     where r.campaign_id = p_campaign and m.allapot = 'pending'
  ) t;

  return jsonb_build_object(
    'campaign_id', p_campaign,
    -- 'uj_sorok' ELTAVOLITVA (javitva): a hivas ota keletkezett uj valaszok
    -- darabszama orankent lekerdezve PONTOS beerkezesi hisztogramot adott —
    -- eppen azt az ido-csatornat, amit a valaszsor idobelyeg-mentessege es a
    -- shuffle_responses() lebontott. Helyette csak a teljes varakozo szam megy.

    'varakozik', jsonb_array_length(v_out),
    'okok', (select coalesce(jsonb_agg(jsonb_build_object(
                      'code', code, 'name_hu', name_hu, 'name_en', name_en,
                      'paragraph', paragraph) order by sort_order), '[]'::jsonb)
               from echo.moderation_reason where active),
    'tetelek', v_out);
end $$;

-- ------------------------------------------------------------
-- 6.2 public.echo_moderate(válasz, kérdés, állapot, indok)
-- ------------------------------------------------------------
-- A SZÖVEG NEM TÖRLŐDIK. Az 'invalid' jelölés csak annyit tesz, hogy a szöveg
-- kikerül a visszacsatolásból (az echo.results_build csak 'valid' sorokat
-- olvas) — az eredeti az echo.response.answers-ben marad, hogy a döntés
-- utólag felülvizsgálható legyen. Ez a jogorvoslat feltétele: egy törölt
-- szövegről nem lehet eldönteni, jogos volt-e a törlés.
create or replace function public.echo_moderate(
  p_response uuid, p_question text, p_allapot text,
  p_indok text default null, p_megjegyzes text default null)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_campaign uuid;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  if p_allapot not in ('pending','valid','invalid') then
    raise exception 'ECHO_BAD_STATE: az allapot csak pending / valid / invalid lehet.';
  end if;
  if p_allapot = 'invalid' and coalesce(btrim(p_indok),'') = '' then
    raise exception 'ECHO_REASON_REQUIRED: ervenytelenne nyilvanitashoz indok kell (3. § (10)).';
  end if;
  if p_allapot = 'invalid'
     and not exists (select 1 from echo.moderation_reason where code = p_indok) then
    raise exception 'ECHO_BAD_REASON: ismeretlen indok-kod "%".', p_indok;
  end if;

  select r.campaign_id into v_campaign from echo.response r where r.id = p_response;
  if v_campaign is null then raise exception 'ECHO_RESPONSE_NOT_FOUND'; end if;

  insert into echo.moderation (response_id, question_id, allapot, indok, megjegyzes,
                               moderator_key, moderalt_at)
  values (p_response, p_question, p_allapot,
          case when p_allapot = 'invalid' then p_indok else null end,
          p_megjegyzes,
          case when p_allapot = 'pending' then null else auth.uid() end,
          case when p_allapot = 'pending' then null else now() end)
  on conflict (response_id, question_id) do update
    set allapot       = excluded.allapot,
        indok         = excluded.indok,
        megjegyzes    = excluded.megjegyzes,
        moderator_key = excluded.moderator_key,
        moderalt_at   = excluded.moderalt_at;

  perform echo.log_access('echo_moderate', v_campaign, null, null, 'moderation');

  return jsonb_build_object('response_id', p_response, 'question_id', p_question,
                            'allapot', p_allapot, 'indok', p_indok, 'ok', true);
end $$;


-- ============================================================
-- 7. SZAKASZ — KÉRDŐÍVSZERKESZTŐ
-- ============================================================
-- A prototípus legmélyebb modulja. Amit a szerver ebből VÁLLAL:
-- klónozás új ID-kkal, mentés csak draft-ban, SZÁMÍTOTT élesítés-előtti
-- ellenőrzések, és egy állapotgép, amit trigger is véd — nem csak az RPC.
-- Amit a KLIENS csinál: a szerkesztő felület, az élő előnézet, az opció-
-- átrendezés. A szerver a compiled JSONB-t egészben veszi át; a szerkezeti
-- helyességet az echo_template_validate() mondja meg, nem egy séma.

-- A feltételekben használható NEM-KÉRDÉS kulcsok. Ezekre a cond hivatkozhat
-- anélkül, hogy "nem létező kérdésre hivatkozó feltétel" hibát kapna.
-- ADAT, nem kód: ha a frontend új környezeti kulcsot vezet be, ez egy UPDATE.
insert into echo.setting (key, value, description) values
  ('cond_context_keys', 'has_goals,attendance_band,lang',
   'A megjelenitesi felteteben (cond) hasznalhato KORNYEZETI kulcsok, amelyek '
   'nem kerdes-ID-k. Az echo_template_validate ezeket nem jelzi hibanak.')
on conflict (key) do nothing;

-- ------------------------------------------------------------
-- 7.1 Mély klónozás ÚJ kérdés-ID-kkal
-- ------------------------------------------------------------
-- MIÉRT KELL ÚJ ID: a válaszok answers mezője kérdés-ID → érték leképezés.
-- Ha egy klónozott kérdőív MEGTARTANÁ a régi ID-kat, két különböző
-- megfogalmazású kérdés válaszai ugyanabba a kulcsba folynának, és egy
-- hosszmetszeti riport összeadná őket. Az ID-csere ezt zárja ki.
-- A cond hivatkozásokat EGYÜTT írjuk át, különben a klón feltételei a régi
-- kérdésekre mutatnának (azaz a klónban sehova).
create or replace function echo.compiled_reid(p_compiled jsonb)
returns jsonb
language plpgsql volatile
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_map  jsonb := '{}'::jsonb;
  s      jsonb; q jsonb;
  v_secs jsonb := '[]'::jsonb;
  v_qs   jsonb;
  v_cond jsonb; v_c2 jsonb; k text;
  v_q2   jsonb; v_s2 jsonb;
begin
  -- 1. menet: régi ID → új ID térkép
  for s in select value from jsonb_array_elements(echo.jarr(p_compiled->'sections')) loop
    for q in select value from jsonb_array_elements(echo.jarr(s->'questions')) loop
      if coalesce(q->>'id','') <> '' and not jsonb_exists(v_map, q->>'id') then
        v_map := v_map || jsonb_build_object(q->>'id',
                   'q_' || substr(replace(gen_random_uuid()::text,'-',''), 1, 10));
      end if;
    end loop;
  end loop;

  -- 2. menet: újraépítés
  for s in select value from jsonb_array_elements(echo.jarr(p_compiled->'sections')) loop
    v_qs := '[]'::jsonb;
    for q in select value from jsonb_array_elements(echo.jarr(s->'questions')) loop
      v_q2 := q || jsonb_build_object('id', coalesce(v_map->>(q->>'id'), q->>'id'));

      v_cond := q->'cond';
      if v_cond is not null and jsonb_typeof(v_cond) = 'object' then
        if jsonb_exists(v_cond, 'qid') then
          -- {"qid": "...", "val": ...} alak
          v_c2 := v_cond || jsonb_build_object('qid',
                    coalesce(v_map->>(v_cond->>'qid'), v_cond->>'qid'));
        else
          -- {"<kerdes_id>": <ertek>} alak (a seed ezt hasznalja)
          v_c2 := '{}'::jsonb;
          for k in select jsonb_object_keys(v_cond) loop
            v_c2 := v_c2 || jsonb_build_object(coalesce(v_map->>k, k), v_cond->k);
          end loop;
        end if;
        v_q2 := v_q2 || jsonb_build_object('cond', v_c2);
      end if;

      v_qs := v_qs || jsonb_build_array(v_q2);
    end loop;

    v_s2 := s || jsonb_build_object(
              'id', 's_' || substr(replace(gen_random_uuid()::text,'-',''), 1, 8),
              'questions', v_qs);
    v_secs := v_secs || jsonb_build_array(v_s2);
  end loop;

  return coalesce(p_compiled,'{}'::jsonb) || jsonb_build_object('sections', v_secs);
end $$;

-- ------------------------------------------------------------
-- 7.2 Az élesítés-előtti ellenőrzések — SZÁMÍTOTT LISTA
-- ------------------------------------------------------------
-- MINDEN talált tétel BLOKKOLÓ: az echo_template_transition 'live'-ra csak
-- akkor enged, ha ez a lista ÜRES. A 'sulyossag' mező a felületnek szól
-- (mit emeljen ki), nem a döntésnek.
-- A lista SZÁMÍTOTT: nem egy előre felsorolt hibakészletet keresünk, hanem
-- végigjárjuk a compiled tényleges szerkezetét.
create or replace function echo.template_validate(p_compiled jsonb)
returns jsonb
language plpgsql stable
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_out   jsonb := '[]'::jsonb;
  v_ids   text[] := '{}';
  v_sids  text[] := '{}';
  v_ctx   text[] := coalesce(
             (select string_to_array(replace(value,' ',''), ',')
                from echo.setting where key = 'cond_context_keys'), '{}');
  s jsonb; q jsonb; o jsonb;
  v_sid text; v_qid text;
  v_nq int := 0;
  v_opt_n int;
  v_cond jsonb; k text;
  v_ref text;
begin
  -- Elso menet: minden kerdes-ID osszegyujtese (a cond-ellenorzeshez kell)
  for s in select value from jsonb_array_elements(echo.jarr(p_compiled->'sections')) loop
    for q in select value from jsonb_array_elements(echo.jarr(s->'questions')) loop
      v_ids := v_ids || coalesce(q->>'id','');
      v_nq  := v_nq + 1;
    end loop;
  end loop;

  if v_nq = 0 then
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'kod','ures_kerdoiv','sulyossag','hiba','szakasz',null,'kerdes',null,
      'uzenet','A kerdoivben egyetlen kerdes sincs.'));
  end if;

  -- Ismetlodo kerdes-ID
  v_out := v_out || coalesce((
    select jsonb_agg(jsonb_build_object(
             'kod','ismetlodo_kerdes_id','sulyossag','hiba','szakasz',null,'kerdes', d.qid,
             'uzenet','Ismetlodo kerdes-ID: "' || d.qid || '" (' || d.db || 'x). '
                      || 'Az answers JSONB kulcsa a kerdes-ID, tehat az ismetlodes valaszokat mos ossze.'))
      from (select x as qid, count(*) as db from unnest(v_ids) x group by x having count(*) > 1) d
  ), '[]'::jsonb);

  -- Ures kerdes-ID
  if '' = any(v_ids) then
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'kod','hianyzo_kerdes_id','sulyossag','hiba','szakasz',null,'kerdes',null,
      'uzenet','Van olyan kerdes, aminek nincs id mezoje.'));
  end if;

  -- Masodik menet: szakaszonkent es kerdesenkent
  for s in select value from jsonb_array_elements(echo.jarr(p_compiled->'sections')) loop
    v_sid := coalesce(s->>'id','(nevtelen szakasz)');

    if v_sid = any(v_sids) then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'kod','ismetlodo_szakasz_id','sulyossag','hiba','szakasz',v_sid,'kerdes',null,
        'uzenet','Ismetlodo szakasz-ID: "' || v_sid || '".'));
    end if;
    v_sids := v_sids || v_sid;

    if coalesce(btrim(s->>'en'),'') = '' then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'kod','hianyzo_angol_szakaszcim','sulyossag','hiba','szakasz',v_sid,'kerdes',null,
        'uzenet','A szakasznak nincs angol cime (en). Az angol nyelvu kurzusok hallgatoi ezt latnak.'));
    end if;

    if jsonb_array_length(echo.jarr(s->'questions')) = 0 then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'kod','ures_szakasz','sulyossag','hiba','szakasz',v_sid,'kerdes',null,
        'uzenet','A szakaszban nincs egyetlen kerdes sem.'));
    end if;

    for q in select value from jsonb_array_elements(echo.jarr(s->'questions')) loop
      v_qid   := coalesce(q->>'id','(nevtelen)');
      v_opt_n := jsonb_array_length(echo.jarr(q->'options'));

      -- Hianyzo angol forditas: kerdesszoveg
      if coalesce(btrim(q->>'en'),'') = '' then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'kod','hianyzo_angol_forditas','sulyossag','hiba','szakasz',v_sid,'kerdes',v_qid,
          'uzenet','A kerdesnek nincs angol szovege (en).'));
      end if;

      -- Hianyzo angol forditas: opciok. A puszta string opcio (["Alma", ...])
      -- definicio szerint egynyelvu — ez is talalat, nem kivetel.
      for o in select value from jsonb_array_elements(echo.jarr(q->'options')) loop
        if jsonb_typeof(o) <> 'object' or coalesce(btrim(o->>'en'),'') = '' then
          v_out := v_out || jsonb_build_array(jsonb_build_object(
            'kod','hianyzo_angol_opcio','sulyossag','hiba','szakasz',v_sid,'kerdes',v_qid,
            'uzenet','Van angol forditas nelkuli valaszopcio: ' ||
                     coalesce(echo.opt_label(o), '(ures)') || '.'));
        end if;
      end loop;

      -- max >= opcioszam (csak tobbvalasztos kerdesnel ertelmes)
      if coalesce(q->>'type','') = 'multi' and (q->>'max') is not null
         and (q->>'max') ~ '^[0-9]+$' and v_opt_n > 0
         and (q->>'max')::int >= v_opt_n then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'kod','max_nagyobb_mint_opcioszam','sulyossag','hiba','szakasz',v_sid,'kerdes',v_qid,
          'uzenet','A max=' || (q->>'max') || ' nem kisebb az opciok szamanal (' || v_opt_n ||
                   '), tehat a korlat nem korlatoz semmit.'));
      end if;

      -- Valasztos kerdes opciok nelkul
      if coalesce(q->>'type','') in ('single','multi','skip') and v_opt_n = 0 then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'kod','nincs_valaszopcio','sulyossag','hiba','szakasz',v_sid,'kerdes',v_qid,
          'uzenet','Valasztos tipusu kerdes (' || coalesce(q->>'type','') || ') opciolista nelkul.'));
      end if;

      -- Skala hatarok
      if coalesce(q->>'type','') = 'scale'
         and coalesce((q->'scale'->>'min')::int, 1) >= coalesce((q->'scale'->>'max')::int, 5) then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'kod','rossz_skala','sulyossag','hiba','szakasz',v_sid,'kerdes',v_qid,
          'uzenet','A skala min erteke nem kisebb a max erteknel.'));
      end if;

      -- Feltetel nem letezo kerdesre
      v_cond := q->'cond';
      if v_cond is not null and jsonb_typeof(v_cond) = 'object' then
        if jsonb_exists(v_cond,'qid') then
          v_ref := v_cond->>'qid';
          if not (v_ref = any(v_ids)) and not (v_ref = any(v_ctx)) then
            v_out := v_out || jsonb_build_array(jsonb_build_object(
              'kod','ismeretlen_feltetel_hivatkozas','sulyossag','hiba','szakasz',v_sid,'kerdes',v_qid,
              'uzenet','A megjelenitesi feltetel nem letezo kerdesre hivatkozik: "' || v_ref || '".'));
          end if;
        else
          for k in select jsonb_object_keys(v_cond) loop
            if not (k = any(v_ids)) and not (k = any(v_ctx)) then
              v_out := v_out || jsonb_build_array(jsonb_build_object(
                'kod','ismeretlen_feltetel_hivatkozas','sulyossag','hiba','szakasz',v_sid,'kerdes',v_qid,
                'uzenet','A megjelenitesi feltetel nem letezo kerdesre hivatkozik: "' || k || '".'));
            end if;
          end loop;
        end if;

        -- Kotelezo kerdes feltetel mogott: ha a feltetel nem teljesul, a
        -- kerdes nem jelenik meg, tehat a "kotelezo" vagy hazudik (ki lehet
        -- hagyni), vagy megbenitja a kitoltest (nem lehet tovabblepni).
        if coalesce((q->>'required')::boolean, false) then
          v_out := v_out || jsonb_build_array(jsonb_build_object(
            'kod','kotelezo_feltetel_mogott','sulyossag','hiba','szakasz',v_sid,'kerdes',v_qid,
            'uzenet','Kotelezo kerdes megjelenitesi feltetel mogott: ha a feltetel nem teljesul, '
                     'a kotelezoseg vagy ervenytelen, vagy megakasztja a kitoltest.'));
        end if;
      end if;
    end loop;
  end loop;

  return v_out;
end $$;


-- ------------------------------------------------------------
-- 7.3 Az állapotgép TRIGGERREL is védve
-- ------------------------------------------------------------
-- A 15_echo_core.sql echo.template_version_guard() triggere a LIVE verziót
-- védi. Ez a MÁSODIK trigger kiterjeszti a védelmet:
--   • az 'approved' és a 'closed' compiled-ja is befagy (az approved = a
--     jóváhagyott szöveg; ha az még módosítható, a jóváhagyás semmit nem ér),
--   • és az ÁTMENETEK is korlátozottak, nem csak az RPC-ben.
-- MIÉRT KELL A TRIGGER, HA AZ RPC ÚGYIS ELLENŐRIZ: mert a Dashboard SQL
-- Editor postgres jogon fut, megkerül minden RPC-t. A trigger a tulajdonosra
-- is vonatkozik (a triggereket a BYPASSRLS nem kapcsolja ki), tehát egy
-- kézzel írt UPDATE is elhasal.
-- MEGENGEDETT ÁTMENETEK:
--   draft → review → approved → live → closed
--   review → draft      (visszakuldes javitasra — a prototipus szerkesztoje
--                        enelkul zsakutca lenne)
--   approved → review   (ujranyitas jovahagyas utan, meg eles elott)
-- A live-bol CSAK closed. A closed vegallapot.
create or replace function echo.template_version_freeze()
returns trigger language plpgsql as $$
declare v_ok boolean;
begin
  if old.state in ('approved','live','closed')
     and new.compiled::text is distinct from old.compiled::text then
    raise exception 'ECHO: a(z) "%" allapotu kerdoiv-verzio compiled mezoje nem modosithato. '
                    'Keszits uj verziot (echo_template_create).', old.state;
  end if;

  if new.state is distinct from old.state then
    v_ok := (old.state, new.state) in (
              ('draft','review'), ('review','approved'), ('approved','live'),
              ('live','closed'), ('review','draft'), ('approved','review'),
              ('draft','closed'), ('review','closed'), ('approved','closed'));
    if not v_ok then
      raise exception 'ECHO: tiltott allapotatmenet: % -> %. Megengedett: draft->review->approved->live->closed '
                      '(plusz review->draft, approved->review, es a lezaras barmely eles elotti allapotbol).',
                      old.state, new.state;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists echo_template_version_freeze_trg on echo.template_version;
create trigger echo_template_version_freeze_trg
  before update on echo.template_version
  for each row execute function echo.template_version_freeze();

-- ------------------------------------------------------------
-- 7.4 public.echo_templates() — sablonok és verziók állapottal
-- ------------------------------------------------------------
create or replace function public.echo_templates()
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_out jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out
  from (
    select jsonb_build_object(
             'id', t.id, 'code', t.code, 'name_hu', t.name_hu, 'name_en', t.name_en,
             'created_at', t.created_at,
             'verziok', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'id', v.id, 'version', v.version, 'state', v.state,
                        'notes', v.notes, 'approved_by', v.approved_by,
                        'approved_at', v.approved_at, 'created_at', v.created_at,
                        'szakaszok', jsonb_array_length(echo.jarr(v.compiled->'sections')),
                        'kerdesek', (select count(*) from
                                       jsonb_array_elements(echo.jarr(v.compiled->'sections')) s
                                       cross join jsonb_array_elements(echo.jarr(s.value->'questions'))),
                        'kampanyok', (select count(*) from echo.campaign c where c.template_version_id = v.id),
                        'szerkesztheto', v.state = 'draft',
                        'ellenorzes_hibak', jsonb_array_length(echo.template_validate(v.compiled))
                      ) order by v.version desc), '[]'::jsonb)
                 from echo.template_version v where v.template_id = t.id)
           ) as x
      from echo.template t
  ) s;
  return v_out;
end $$;

-- ------------------------------------------------------------
-- 7.5 public.echo_template_get(verzió) — a compiled szerkesztésre
-- ------------------------------------------------------------
create or replace function public.echo_template_get(p_version uuid)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  select jsonb_build_object(
           'id', tv.id, 'template_id', tv.template_id, 'code', t.code,
           'name_hu', t.name_hu, 'name_en', t.name_en,
           'version', tv.version, 'state', tv.state, 'notes', tv.notes,
           'approved_by', tv.approved_by, 'approved_at', tv.approved_at,
           'szerkesztheto', tv.state = 'draft',
           'kampanyok', (select count(*) from echo.campaign c where c.template_version_id = tv.id),
           'ellenorzes', echo.template_validate(tv.compiled),
           'compiled', tv.compiled)
    into v
    from echo.template_version tv join echo.template t on t.id = tv.template_id
   where tv.id = p_version;
  if v is null then raise exception 'ECHO_VERSION_NOT_FOUND'; end if;
  return v;
end $$;

-- ------------------------------------------------------------
-- 7.6 public.echo_template_create(név, forrás) — mély klónozás
-- ------------------------------------------------------------
-- Kódképző az új sablonhoz. Az unaccent extension a helyi replikán nincs
-- telepítve (és Supabase-en sem alapértelmezett), ezért translate()-tel
-- ékezettelenítünk — a magyar ékezetes betűk teljes készletére.
create or replace function echo.slug(p_text text)
returns text
language sql immutable
as $$
  select btrim(upper(regexp_replace(
           translate(coalesce(p_text,''),
                     'áéíóöőúüűÁÉÍÓÖŐÚÜŰ',
                     'aeiooouuuAEIOOOUUU'),
           '[^A-Za-z0-9]+', '-', 'g')), '-')
$$;

-- p_from IS NULL  → ÚJ SABLON, 1. verzió, üres vázzal ("üresen indítás").
-- p_from NOT NULL → a forrás sablonjának KÖVETKEZŐ verziója, a compiled
--                   mély klónjával és MINDEN kérdés-ID cseréjével
--                   ("sablonból / pulzusból indítás").
-- Az új verzió mindig 'draft'.
create or replace function public.echo_template_create(p_name text, p_from uuid default null)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_src   echo.template_version%rowtype;
  v_tid   uuid;
  v_ver   int;
  v_comp  jsonb;
  v_code  text;
  v_new   uuid;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  if coalesce(btrim(p_name),'') = '' then
    raise exception 'ECHO_NAME_REQUIRED: a sablon/verzio nevet meg kell adni.';
  end if;

  if p_from is null then
    -- Üres váz. Egy szakasz, nulla kérdés — a validate ezt AZONNAL hibásnak
    -- jelöli (ures_szakasz), tehát élesíteni nem lehet, ameddig nincs benne
    -- kérdés. Ez szándékos: az üres kérdőív nem "majdnem kész", hanem hibás.
    v_code := echo.slug(p_name);
    if v_code = '' then v_code := 'SABLON'; end if;
    if exists (select 1 from echo.template where code = v_code) then
      v_code := v_code || '-' || substr(replace(gen_random_uuid()::text,'-',''),1,6);
    end if;

    insert into echo.template (code, name_hu) values (v_code, p_name) returning id into v_tid;
    v_ver  := 1;
    v_comp := jsonb_build_object(
      'meta', jsonb_build_object('code', v_code, 'version', 1,
                                 'title_hu', p_name, 'title_en', null,
                                 'legal_hu', '28/2023. szenatusi hatarozat'),
      'parts', '[]'::jsonb,
      'sections', jsonb_build_array(jsonb_build_object(
                    'id','s_'||substr(replace(gen_random_uuid()::text,'-',''),1,8),
                    'hu','Uj szakasz','en',null,'questions','[]'::jsonb)));
  else
    select * into v_src from echo.template_version where id = p_from;
    if not found then raise exception 'ECHO_SOURCE_NOT_FOUND'; end if;
    v_tid := v_src.template_id;
    select coalesce(max(version),0) + 1 into v_ver
      from echo.template_version where template_id = v_tid;
    v_comp := echo.compiled_reid(v_src.compiled);
    v_comp := v_comp || jsonb_build_object('meta',
                coalesce(v_comp->'meta','{}'::jsonb)
                || jsonb_build_object('version', v_ver, 'title_hu', p_name,
                                      'klonozva_innen', p_from));
  end if;

  insert into echo.template_version (template_id, version, state, compiled, notes)
  values (v_tid, v_ver, 'draft', v_comp,
          'Letrehozva: echo_template_create. Forras: ' || coalesce(p_from::text, '(ures)'))
  returning id into v_new;

  return jsonb_build_object('id', v_new, 'template_id', v_tid, 'version', v_ver,
                            'state', 'draft',
                            'ellenorzes', echo.template_validate(v_comp));
end $$;

-- ------------------------------------------------------------
-- 7.7 public.echo_template_save(verzió, compiled) — CSAK draft-ban
-- ------------------------------------------------------------
create or replace function public.echo_template_save(p_version uuid, p_compiled jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_state text;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  select state into v_state from echo.template_version where id = p_version;
  if v_state is null then raise exception 'ECHO_VERSION_NOT_FOUND'; end if;
  if v_state <> 'draft' then
    raise exception 'ECHO_NOT_DRAFT: a verzio allapota "%", menteni csak draft allapotban lehet. '
                    'Keszits uj verziot (echo_template_create).', v_state;
  end if;
  if p_compiled is null or jsonb_typeof(p_compiled) <> 'object' then
    raise exception 'ECHO_BAD_COMPILED: a compiled JSON objektum kell legyen.';
  end if;

  update echo.template_version set compiled = p_compiled where id = p_version;

  return jsonb_build_object('id', p_version, 'state', 'draft',
                            'ellenorzes', echo.template_validate(p_compiled));
end $$;

-- ------------------------------------------------------------
-- 7.8 public.echo_template_validate(verzió)
-- ------------------------------------------------------------
create or replace function public.echo_template_validate(p_version uuid)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_comp jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  select compiled into v_comp from echo.template_version where id = p_version;
  if v_comp is null then raise exception 'ECHO_VERSION_NOT_FOUND'; end if;
  return echo.template_validate(v_comp);
end $$;

-- ------------------------------------------------------------
-- 7.9 public.echo_template_transition(verzió, cél) — állapotgép
-- ------------------------------------------------------------
-- ÉLESÍTÉS ('live') CSAK AKKOR, HA AZ ELLENŐRZŐ LISTA ÜRES.
-- Élesítéskor a sablon KORÁBBI live verziója automatikusan 'closed' lesz:
-- egy sablonnak egyszerre egy élő verziója lehet, különben egy új kampány
-- indításakor nem lenne egyértelmű, melyikre hivatkozzon.
create or replace function public.echo_template_transition(p_version uuid, p_to text)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_tv    echo.template_version%rowtype;
  v_check jsonb;
  v_closed int := 0;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  select * into v_tv from echo.template_version where id = p_version;
  if not found then raise exception 'ECHO_VERSION_NOT_FOUND'; end if;
  if p_to not in ('draft','review','approved','live','closed') then
    raise exception 'ECHO_BAD_STATE: ismeretlen celallapot "%".', p_to;
  end if;

  if p_to = 'live' then
    v_check := echo.template_validate(v_tv.compiled);
    if jsonb_array_length(v_check) > 0 then
      raise exception 'ECHO_VALIDATION_FAILED: % ellenorzesi hiba, elesites nem engedelyezett. Elso: %',
        jsonb_array_length(v_check), v_check->0->>'uzenet';
    end if;
    -- A sablon eddigi elo verziojanak lezarasa
    update echo.template_version
       set state = 'closed'
     where template_id = v_tv.template_id and state = 'live' and id <> p_version;
    get diagnostics v_closed = row_count;
  end if;

  update echo.template_version
     set state       = p_to,
         approved_by = case when p_to in ('approved','live')
                            then coalesce(approved_by, (select email from public.profiles where id = auth.uid()))
                            else approved_by end,
         approved_at = case when p_to in ('approved','live')
                            then coalesce(approved_at, now()) else approved_at end
   where id = p_version;

  return jsonb_build_object('id', p_version, 'from', v_tv.state, 'to', p_to,
                            'lezart_korabbi_live', v_closed, 'ok', true);
end $$;


-- ------------------------------------------------------------
-- 7.10 Két ÖNTESZT-függvény a 9. szakasz ellenőrző lekérdezéséhez
-- ------------------------------------------------------------
-- Nem üzemi kód: azért függvény és nem inline SQL, mert mindkettő olyat
-- csinál (szándékos kényszersértés, illetve ID-generálás), amit egy
-- ellenőrző SELECT-be nem lehet beletenni.

-- Tényleg fog-e a küszöb alsó korlátja: megpróbáljuk 1-re állítani a
-- k_text-et, és true-t adunk vissza, ha a CHECK elhasalt. A próba a
-- beágyazott blokk miatt saját altranzakcióban fut, tehát a beállítás
-- minden ágon érintetlen marad.
create or replace function echo.k_floor_probe()
returns boolean
language plpgsql volatile
set search_path = echo, public, pg_temp
as $$
declare v_old text; v_ok boolean := false;
begin
  select value into v_old from echo.setting where key = 'k_text';
  if v_old is null then return false; end if;
  begin
    update echo.setting set value = '1' where key = 'k_text';
    -- Idáig NEM SZABAD eljutni. Ha mégis, azonnal visszaállítjuk.
    update echo.setting set value = v_old where key = 'k_text';
    v_ok := false;
  exception when check_violation then
    v_ok := true;   -- a CHECK fogott: ez a jó ág
  end;
  return v_ok;
end $$;

-- Hány kérdés-ID maradt VÁLTOZATLAN a klónozás után. Elvárt: 0.
create or replace function echo.reid_probe()
returns integer
language plpgsql volatile
set search_path = echo, public, extensions, pg_temp
as $$
declare v_comp jsonb; v_new jsonb; v_n int;
begin
  select compiled into v_comp from echo.template_version
   where state = 'live' order by created_at limit 1;
  if v_comp is null then return 0; end if;
  v_new := echo.compiled_reid(v_comp);
  select count(*) into v_n
    from jsonb_array_elements(echo.jarr(v_new->'sections')) s,
         lateral jsonb_array_elements(echo.jarr(s.value->'questions')) q
   where q.value->>'id' in (
          select q2.value->>'id'
            from jsonb_array_elements(echo.jarr(v_comp->'sections')) s2,
                 lateral jsonb_array_elements(echo.jarr(s2.value->'questions')) q2);
  return v_n;
end $$;

-- ============================================================
-- 8. SZAKASZ — GRANTOK
-- ============================================================
-- Ugyanaz a szigor, mint a 15_echo_core.sql 10. szakaszában: minden új
-- objektumról ELŐBB visszaveszünk mindent (a Postgres a PUBLIC-nak
-- alapértelmezésben EXECUTE-ot ad minden új függvényre), utána adunk vissza
-- célzottan. Ez a rész a 15. szeletre is újra ráfut — szándékosan, mert
-- idempotens és így egy hiányzó revoke ott is javul.
do $grants$
declare
  f record;
  has_anon bool := exists (select 1 from pg_roles where rolname='anon');
  has_auth bool := exists (select 1 from pg_roles where rolname='authenticated');
  has_svc  bool := exists (select 1 from pg_roles where rolname='service_role');
begin
  -- 8.1 az echo séma MINDEN objektuma (a most létrejöttek is) zárva
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

  -- 8.2 a public sémás ECHO RPC-k: előbb mindenkitől el
  for f in select p.oid::regprocedure::text n
             from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
            where ns.nspname='public' and p.proname like 'echo\_%'
  loop
    execute format('revoke all on function %s from public', f.n);
    if has_anon then execute format('revoke all on function %s from anon', f.n); end if;
    if has_auth then execute format('revoke all on function %s from authenticated', f.n); end if;
    if has_svc  then execute format('revoke all on function %s from service_role', f.n); end if;
  end loop;

  -- 8.3 célzottan vissza — a 15. szelet RPC-i
  if has_auth then
    grant execute on function public.echo_my_courses()                        to authenticated;
    grant execute on function public.echo_get_form(uuid,uuid)                 to authenticated;
    grant execute on function public.echo_save_goals(uuid,uuid,jsonb,jsonb)   to authenticated;
    grant execute on function public.echo_issue_ticket(uuid,uuid)             to authenticated;
    grant execute on function public.echo_campaigns()                         to authenticated;
    grant execute on function public.echo_rate(uuid)                          to authenticated;
    grant execute on function public.echo_rebuild_eligibility(uuid)           to authenticated;

    -- 8.4 a 16. szelet RPC-i. MIND 'authenticated' — a tényleges szűrés a
    -- függvény TÖRZSÉBEN van (is_admin() vagy oktatói kötés), nem a granton.
    -- MIÉRT ÍGY: az oktatónak nincs saját Postgres szerepköre (a Supabase
    -- minden bejelentkezett fiókja 'authenticated'), tehát granttal nem is
    -- lehetne megkülönböztetni. A grant itt annyit ad, hogy anon egyáltalán
    -- nem hívhatja őket.
    grant execute on function public.echo_teacher_results(uuid,uuid,uuid)     to authenticated;
    grant execute on function public.echo_course_results(uuid,uuid)           to authenticated;
    grant execute on function public.echo_moderation_queue(uuid)              to authenticated;
    grant execute on function public.echo_moderate(uuid,text,text,text,text)  to authenticated;
    grant execute on function public.echo_templates()                         to authenticated;
    grant execute on function public.echo_template_get(uuid)                  to authenticated;
    grant execute on function public.echo_template_create(text,uuid)          to authenticated;
    grant execute on function public.echo_template_save(uuid,jsonb)           to authenticated;
    grant execute on function public.echo_template_validate(uuid)             to authenticated;
    grant execute on function public.echo_template_transition(uuid,text)      to authenticated;

    -- 8.4/b UTÓLAGOS MIGRÁCIÓK RPC-INEK VISSZAADÁSA — MÉRT HIBA JAVÍTÁSA.
    -- A fenti 8.2 hurok MINDEN public.echo\_% függvényről levesz minden jogot,
    -- a KÉSŐBBI migrációkéiról is. MÉRVE a replikán: a 16-os újrafuttatása
    -- után az echo_template_rename (17) és az öt szerepkör-RPC (19)
    -- has_function_privilege('authenticated', …, 'execute') értéke HAMIS lett,
    -- vagyis a kérdőív átnevezése és az oktatói belépés CSENDBEN elromlott.
    -- Ezért itt feltételesen visszaadjuk őket. A to_regprocedure() vizsgálat
    -- azért kell, mert a 17/19 még nem biztos, hogy lefutott.
    if to_regprocedure('public.echo_template_rename(uuid,text,text)') is not null then
      grant execute on function public.echo_template_rename(uuid,text,text) to authenticated;
    end if;
    if to_regprocedure('public.echo_teacher_link(uuid,uuid)') is not null then
      grant execute on function public.echo_teacher_link(uuid,uuid) to authenticated;
    end if;
    if to_regprocedure('public.echo_my_teacher_courses()') is not null then
      grant execute on function public.echo_my_teacher_courses() to authenticated;
    end if;
    if to_regprocedure('public.echo_role_grants()') is not null then
      grant execute on function public.echo_role_grants() to authenticated;
    end if;
    if to_regprocedure('public.echo_role_grant(uuid,text,uuid,timestamptz,text)') is not null then
      grant execute on function public.echo_role_grant(uuid,text,uuid,timestamptz,text) to authenticated;
    end if;
    if to_regprocedure('public.echo_my_roles()') is not null then
      grant execute on function public.echo_my_roles() to authenticated;
    end if;
  end if;

  -- 8.5 a beküldés KIZÁRÓLAG anon jogon megy (változatlan a 15. szeletből)
  if has_anon then
    grant execute on function public.echo_submit(text,jsonb) to anon;
  end if;

  raise notice 'ECHO 16. szakasz 8: grantok beallitva (anon=%, authenticated=%, service_role=%).',
               has_anon, has_auth, has_svc;
end
$grants$;

-- 8.6 RLS a most létrejött kényes táblákon — MÁSODIK védvonal.
-- Bekapcsolva, POLICY NÉLKÜL: ha valaha valaki USAGE-t adna az echo sémára,
-- ezek a táblák akkor is nulla sort adnának. A SECURITY DEFINER RPC-ket ez
-- nem érinti (tulajdonosként futnak, FORCE ROW LEVEL SECURITY nincs).
alter table echo.moderation enable row level security;
alter table echo.access_log enable row level security;


-- ============================================================
-- 9. SZAKASZ — ELLENŐRZŐ LEKÉRDEZÉS (egyetlen eredménytábla)
-- ============================================================
-- Az "elvart" oszlop mondja meg, mit kellene latni. Ahol "allapot" = HIBA,
-- ott ne menj tovabb.
with chk(sorrend, ellenorzes, mert, elvart, rendben) as (
  select 1, 'echo.moderation tabla letezik',
         (select count(*)::text from pg_tables where schemaname='echo' and tablename='moderation'),
         '1',
         (select count(*) from pg_tables where schemaname='echo' and tablename='moderation') = 1
  union all
  select 2, 'a moderalasi soron NINCS bekuldesre utalo idobelyeg',
         (select coalesce(string_agg(column_name, ', '), 'nincs')
            from information_schema.columns
           where table_schema='echo' and table_name='moderation'
             and column_name <> 'moderalt_at'
             and (data_type like 'timestamp%' or data_type='date'
                  or column_name in ('created_at','inserted_at','queued_at','seq'))),
         'nincs',
         echo.moderation_schema_ok()
  union all
  select 3, 'echo.access_log letezik es NEM tarol eredmenyt',
         (select coalesce(string_agg(column_name, ', '), '(nincs tabla)')
            from information_schema.columns
           where table_schema='echo' and table_name='access_log'),
         'id, viewer_key, viewer_role, rpc, campaign_id, course_id, teacher_id, scope, at',
         to_regclass('echo.access_log') is not null and echo.access_log_schema_ok()
  union all
  select 4, 'k-kuszobok jelen vannak',
         (select string_agg(key || '=' || value, ', ' order by key)
            from echo.setting where key in ('k_numeric','k_dist','k_text','k_slice','k_low')),
         'mind az 5',
         (select count(*) from echo.setting
           where key in ('k_numeric','k_dist','k_text','k_slice','k_low')) = 5
  union all
  select 5, 'a kuszob-CHECK letezik (1-re allitas nem lehetseges)',
         (select count(*)::text from pg_constraint
           where conname = 'echo_setting_k_floor_chk'), '1',
         (select count(*) from pg_constraint where conname='echo_setting_k_floor_chk') = 1
  union all
  select 6, 'a CHECK tenyleg fog: k_text=1 beallitas elhasal',
         (select case when echo.k_floor_probe() then 'elhasalt (jo)' else 'ATMENT (BAJ)' end),
         'elhasalt (jo)',
         echo.k_floor_probe()
  union all
  select 7, 'komplementer-elnyomas: 1 elnyomott cellabol 2 lesz',
         (select (select count(*) from jsonb_array_elements(
                    echo.suppress_cells(
                      '[{"ertek":"a","db":50},{"ertek":"b","db":40},{"ertek":"c","db":2},{"ertek":"d","db":30}]'::jsonb,
                      5)) e where (e.value->>'rejtve')::boolean)::text),
         '2',
         (select count(*) from jsonb_array_elements(
            echo.suppress_cells(
              '[{"ertek":"a","db":50},{"ertek":"b","db":40},{"ertek":"c","db":2},{"ertek":"d","db":30}]'::jsonb,
              5)) e where (e.value->>'rejtve')::boolean) = 2
  union all
  select 8, 'oralatogatasi sav besorolasa (0-25% alacsony, 26-50% nem)',
         (select echo.attendance_low('0-25%')::text || ' / ' || echo.attendance_low('26-50%')::text),
         'true / false',
         echo.attendance_low('0-25%') and not echo.attendance_low('26-50%')
  union all
  -- A 15+16 egyutt 18 RPC-t ad. A KESOBBI migraciok (17: echo_template_rename,
  -- 18: kampany-eletciklus, 19: szerepkorok) tovabbiakat tesznek hozza, ezert a
  -- feltetel ALSO KORLAT, nem egyenloseg — kulonben ez a sor minden uj szelet
  -- utan HIBA-t jelezne, holott semmi nem romlott el.
  select 9, 'public echo_ RPC-k szama (legalabb 8 a 15-bol + 10 a 16-bol)',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname like 'echo\_%'), '>= 18',
         (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname like 'echo\_%') >= 18
  union all
  select 10, 'a 16. szelet RPC-i NEM hivhatok anon jogon',
         (select count(*)::text from unnest(array[
                 'public.echo_teacher_results(uuid,uuid,uuid)',
                 'public.echo_course_results(uuid,uuid)',
                 'public.echo_moderation_queue(uuid)',
                 'public.echo_moderate(uuid,text,text,text,text)',
                 'public.echo_templates()',
                 'public.echo_template_get(uuid)',
                 'public.echo_template_create(text,uuid)',
                 'public.echo_template_save(uuid,jsonb)',
                 'public.echo_template_validate(uuid)',
                 'public.echo_template_transition(uuid,text)']) f
           where exists (select 1 from pg_roles where rolname='anon')
             and has_function_privilege('anon', f, 'execute')),
         '0',
         not exists (select 1 from unnest(array[
                 'public.echo_teacher_results(uuid,uuid,uuid)',
                 'public.echo_course_results(uuid,uuid)',
                 'public.echo_moderation_queue(uuid)',
                 'public.echo_moderate(uuid,text,text,text,text)',
                 'public.echo_templates()',
                 'public.echo_template_get(uuid)',
                 'public.echo_template_create(text,uuid)',
                 'public.echo_template_save(uuid,jsonb)',
                 'public.echo_template_validate(uuid)',
                 'public.echo_template_transition(uuid,text)']) f
           where exists (select 1 from pg_roles where rolname='anon')
             and has_function_privilege('anon', f, 'execute'))
  union all
  select 11, 'a 16. szelet RPC-i hivhatok authenticated jogon',
         (select count(*)::text from unnest(array[
                 'public.echo_teacher_results(uuid,uuid,uuid)',
                 'public.echo_course_results(uuid,uuid)',
                 'public.echo_moderation_queue(uuid)',
                 'public.echo_moderate(uuid,text,text,text,text)',
                 'public.echo_templates()',
                 'public.echo_template_get(uuid)',
                 'public.echo_template_create(text,uuid)',
                 'public.echo_template_save(uuid,jsonb)',
                 'public.echo_template_validate(uuid)',
                 'public.echo_template_transition(uuid,text)']) f
           where exists (select 1 from pg_roles where rolname='authenticated')
             and has_function_privilege('authenticated', f, 'execute')),
         '10 (vagy 0, ha nincs authenticated szerepkor)',
         (select count(*) from unnest(array[
                 'public.echo_teacher_results(uuid,uuid,uuid)',
                 'public.echo_course_results(uuid,uuid)',
                 'public.echo_moderation_queue(uuid)',
                 'public.echo_moderate(uuid,text,text,text,text)',
                 'public.echo_templates()',
                 'public.echo_template_get(uuid)',
                 'public.echo_template_create(text,uuid)',
                 'public.echo_template_save(uuid,jsonb)',
                 'public.echo_template_validate(uuid)',
                 'public.echo_template_transition(uuid,text)']) f
           where exists (select 1 from pg_roles where rolname='authenticated')
             and has_function_privilege('authenticated', f, 'execute'))
         = case when exists (select 1 from pg_roles where rolname='authenticated') then 10 else 0 end
  union all
  select 12, 'RLS a moderation es az access_log tablan',
         (select string_agg(relname || '=' || relrowsecurity::text, ', ' order by relname)
            from pg_class c join pg_namespace n on n.oid=c.relnamespace
           where n.nspname='echo' and relname in ('moderation','access_log')),
         'access_log=true, moderation=true',
         (select bool_and(relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace
           where n.nspname='echo' and relname in ('moderation','access_log'))
  union all
  select 13, 'az elesitett verzio compiled-jat trigger vedi (2 trigger)',
         (select count(*)::text from pg_trigger
           where tgrelid = 'echo.template_version'::regclass and not tgisinternal),
         '2',
         (select count(*) from pg_trigger
           where tgrelid = 'echo.template_version'::regclass and not tgisinternal) = 2
  union all
  select 14, 'a seed live verzio ellenorzese SZAMITOTT hibalistat ad',
         (select jsonb_array_length(echo.template_validate(compiled))::text
            from echo.template_version where state='live' order by created_at limit 1),
         '> 0 (a seed opcioinak nincs angol forditasa)',
         coalesce((select jsonb_array_length(echo.template_validate(compiled)) > 0
                     from echo.template_version where state='live' order by created_at limit 1), true)
  union all
  select 15, 'klonozas: MINDEN kerdes-ID kicserelodik',
         echo.reid_probe()::text, '0', echo.reid_probe() = 0
  union all
  select 16, 'moderalasi kategoriak (3. § (10)) betoltve',
         (select count(*)::text from echo.moderation_reason), '>= 6',
         (select count(*) from echo.moderation_reason) >= 6
)
select sorrend as "#",
       ellenorzes as "ellenorzes",
       mert as "mert",
       elvart as "elvart",
       case when rendben then 'OK' else 'HIBA' end as "allapot"
  from chk order by sorrend;


-- ============================================================
-- VÉGE — 16_echo_reports.sql
-- ============================================================

-- ============================================================
-- FÜGGELÉK — A HELYI REPLIKÁN MÉRT EREDMÉNY (2026-08-19)
-- ============================================================
-- Környezet: Postgres 16, /tmp/upg2:55432, 'verify' adatbázis, benne a 01–10
-- migráció + 11_rbac_additive.sql + 15_echo_core.sql, Supabase-utánzattal.
-- Adat: 42 válasz (14 kurzusszintű + 2×14 oktatói), 1 kampány, 5 kurzus,
-- 15 approved fiók.
--
-- FUTTATÁS: psql -v ON_ERROR_STOP=1 mellett KÉTSZER lefuttatva, mindkétszer
-- exit=0, és a 9. szakasz mind a 16 sora OK.
--
-- FONTOS A MÉRÉS OLVASÁSÁHOZ: a replikán lévő 42 válasz egy KORÁBBI SMOKE
-- TESZTBŐL származik, és a kérdés-ID-i (c_overall, c_text, t_overall,
-- skipped) NEM a live sablon kérdés-ID-i (overall_course, impact_text,
-- teacher_skip …). Ezért minden mérés egy tranzakcióban ELŐSZÖR átírta a 42
-- sor answers kulcsait a live sablon ID-ira, majd ROLLBACK-elt. A sorok
-- száma, a kurzus, az oktatók és a jogosultsági állapot változatlan maradt.
-- Ezt ki kell mondani: a küszöbök viselkedése mért, a KONKRÉT válaszértékek
-- viszont a méréshez felvett (7/6/5/4/3/1 eloszlás), nem élesek.
--
-- ---------- A K-KÜSZÖB TÉNYLEG ELREJT (számokkal) ----------
--   ALAPHELYZET (k_numeric=5, k_dist=10, k_slice=5, k_text=10, k_low=5),
--   overall_course kérdés, kurzusszintű riport, n=14:
--     átlag = 5.50, szórás = 1.79, eloszlás VAN (7 cella, skála 1–7).
--     A cellák: 7→5, 6→4, 5→2, 4→1, 3→1, 2→0, 1→1.
--     k_slice=5 mellett ELREJTVE: 1, 3, 4, 5, 6 (öt cella; a 6-os is, mert
--     db=4 < 5). LÁTHATÓ: 7 (db=5) és 2 (db=0).
--   k_numeric 5 → 20: a TELJES riport elrejtődik. Visszatérő üzenet:
--     "Keves valasz (14 < k_numeric=20): ez a bontas nem jelenitheto meg."
--     kerdesek = [] (nem üres tartalommal, hanem ÜRES TÖMBBEL — egyetlen
--     kérdés elemszáma sem szivárog ki).
--   k_dist 10 → 20: az átlag MARAD (5.50), az eloszlás ELTŰNIK (JSON null),
--     rejtes_oka = "kis_elemszam_nincs_eloszlas".
--   k_slice 5 → 6: az elrejtett cellák száma 5-ről 6-ra nő, a látható 2-ről
--     1-re csökken. (Mért: rejtett=6, látható=1.)
--
-- ---------- KOMPLEMENTER-ELNYOMÁS (mért, nem elméleti) ----------
--   teacher_strengths (multi), n=14, oktatói bontás:
--     "Felkeszult" = 9, "Erthetoen magyaraz" = 5, "Motivalo" = 4, a többi 0.
--     A "Motivalo" (4 < k_slice=5) elrejtve — ez EGYETLEN elrejtett cella
--     lenne, amiből kivonással visszaszámolható. A függvény ezért elrejtette
--     a legkisebb láthatót is ("Elerheto es segitokesz", db=0).
--     Mért végeredmény: 2 elrejtett cella. A 9. szakasz 7. ellenőrzése ezt
--     szintetikus adaton is ellenőrzi (1 elnyomottból 2 lesz).
--
-- ---------- OKTATÓ NEM LÁTJA MÁS OKTATÓ EREDMÉNYÉT (mért) ----------
--   A mérés két oktatót kötött két meglévő fiókhoz (teacher.profile_id).
--     T1 = Kovacs Andrea → stud7@nolink.test
--     T2 = Nagy Peter    → stud8@nolink.test
--   • stud7 kéri T2 eredményét:
--       ERROR: ECHO_FORBIDDEN: oktatokent kizarolag a sajat eredmenyed kerheto le.
--   • stud7 kéri T1-et (a sajátját): MEGY, hivo="oktato", 1 bontás.
--   • stud7 p_teacher NÉLKÜL: 1 bontás, teacher_name = "Kovacs Andrea".
--   • ADMIN p_teacher nélkül: 2 bontás (Kovacs Andrea, Nagy Peter).
--   • stud9 (nincs oktatói sorhoz kötve, nem admin):
--       ERROR: ECHO_FORBIDDEN: a fiok nincs oktatoi sorhoz kotve, es nem admin.
--   • NYITOTT kampányon (state='open') még ADMIN sem lát eredményt:
--       ERROR: ECHO_RESULTS_NOT_READY: a kampany allapota "open", eredmeny
--              csak ezekben: closed, processing, sealed, published.
--
-- ---------- MEGTEKINTÉSI NAPLÓ ----------
--   Egy admin echo_teacher_results hívás p_teacher nélkül 2 naplósort írt
--   (oktatónként egyet), viewer_role='SUPERADMIN', course_id + teacher_id +
--   scope='teacher'. A napló SEMMILYEN elemszámot vagy eredményt nem tárol —
--   a 9. szakasz 3. ellenőrzése az oszloplistát is kiírja.
--
-- ---------- MODERÁLÁS ----------
--   • A sor feltöltése: 14 pending tétel keletkezett az impact_text kérdésre.
--     A moderálási tábla ctid-sorrendje és a válaszok ctid-sorrendje közötti
--     korreláció két futásban -0.182 és +0.138 (véletlen körüli) — vagyis az
--     'order by random()' tényleg elbontotta az érkezési sorrendet.
--   • 9 érvényes szöveg (k_text=10 alatt): szovegek=null, szoveg_rejtve=true,
--     üzenet: "Moderalt, ervenyes szoveges valasz: 9 < k_text=10."
--   • A 10. érvényes után: szoveg_db=10, szoveg_rejtve=false, és PONTOSAN 10
--     szöveg ment vissza.
--   • Egy szöveg 'invalid' (indok='szemelyiseg', 3. § (10)): az érvényesek
--     száma 9-re esett, a blokk ÚJRA elrejtődött. A moderálási soron
--     moderator_key és moderalt_at kitöltve (audit-nyom), az EREDETI SZÖVEG
--     pedig változatlanul megvan az echo.response.answers-ben (1 sor, mérve).
--
-- ---------- ALACSONY ÓRALÁTOGATÁS (3. § (9)) ----------
--   5 kurzusszintű válasz attendance_band-je '0-25%'-ra állítva:
--     fő halmaz n=9  → átlag 4.67, eloszlás NINCS (9 < k_dist=10),
--     alacsony blokk n=5 → megjelenik (5 >= k_low=5), átlag 7.00,
--                          10 kérdéssel, és szoveg_rejtve=true MINDIG.
--   A fő halmaz átlaga 5.50-ről 4.67-re változott — vagyis a szétválasztás
--   nem kozmetika: tényleg más számot ad a jegyzőkönyvi statisztika.
--
-- ---------- KÉRDŐÍVSZERKESZTŐ ----------
--   • echo_template_create a live verzióból: 2. verzió, 'draft' állapotban.
--     A klónban EGYETLEN régi kérdés-ID sem maradt (echo.reid_probe() = 0,
--     9. szakasz 15. ellenőrzés).
--   • echo_template_validate a klónon: 35 SZÁMÍTOTT találat, bontásban
--     34 × hianyzo_angol_opcio + 1 × kotelezo_feltetel_mogott. (A seed
--     opciólistái puszta stringek, tehát egynyelvűek; a goals_met kérdés
--     required=true egy cond mögött.)
--   • draft → live KÖZVETLENÜL: a TRIGGER utasítja vissza:
--       "ECHO: tiltott allapotatmenet: draft -> live."
--   • approved → live érvénytelen kérdőívvel: az RPC utasítja vissza:
--       "ECHO_VALIDATION_FAILED: 35 ellenorzesi hiba, elesites nem engedelyezett."
--   • approved állapotban a compiled közvetlen UPDATE-je is elhasal
--     (trigger), és az echo_template_save is ("ECHO_NOT_DRAFT").
--   • Tiszta kérdőív mentése után validate = 0 találat, és a
--     draft→review→approved→live út végigment; az élesítés a sablon korábbi
--     live verzióját 'closed'-ra tette (lezart_korabbi_live = 1).
--   • A live verzió compiled-ja utána már nem módosítható (trigger).
--
-- ---------- AMI EBBŐL NEM MÉRT, HANEM BECSLÉS ----------
--   • A §-hivatkozások (3. § (9), 3. § (10), 6. § (4)) a feladatleírásból
--     valók; a 28/2023. szenátusi határozat szövege ebben a környezetben nem
--     érhető el. Ezért a moderálási kategóriák ADATKÉNT állnak
--     (echo.moderation_reason), egy UPDATE-tel pontosíthatók.
--   • A javasolt küszöbértékek (5 / 10 / 10 / 5) a feladatleírás javaslatai;
--     az alsó korlátok ugyanezek. Hogy a NJE-nek melyik a helyes, azt adat
--     nélkül nem lehet eldönteni — a CHECK azt garantálja, hogy lefelé ne
--     lehessen elmozdulni, nem azt, hogy a szám jó.
--   • Az óralátogatási sávhatárok értelmezése ("0-25%" alacsony, "26-50%"
--     nem) a sávok szöveges alakjából számított, konzervatív döntés.
-- ============================================================
