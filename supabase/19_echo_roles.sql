-- ============================================================
-- UniPortal Pro — ECHO (OMHV) 0.4: OKTATÓI BELÉPÉS
-- Az ECHO saját, HATÓKÖRÖS jogosultsági dimenziója
-- Neumann János Egyetem, 28/2023. szenátusi határozat
-- Változat: 2026-08-19, HELYI POSTGRES 16 REPLIKÁN MÉRVE
-- ELŐFELTÉTEL: 11_rbac_additive.sql + 15_echo_core.sql + 16_echo_reports.sql.
--   A 18a_echo_campaign.sql-től FÜGGETLEN — ez a fájl önmagában lefut, és
--   önmagában újrafuttatható.
-- ============================================================
--
-- MI VOLT A BAJ (MÉRVE, a replikán):
--   select count(*) from echo.teacher where profile_id is null;  -->  4 / 4
--   Vagyis echo.my_teacher_id() (16_echo_reports.sql, 5.1) MINDEN fiókra
--   NULL-t ad. Az echo_teacher_results() és az echo_course_results() ezután
--   a "sem admin, sem oktatóhoz kötött fiók" ágra fut, és ECHO_FORBIDDEN-t
--   dob. Az oktatói eredménynézet (features/echo.jsx, 10. szakasz) tehát
--   MEGÉPÜLT, de senki nem tudja használni: nincs mód a kötés létrehozására,
--   nincs OKTATO szerepkör, és nincs oktatói kurzuslistázó RPC sem
--   (az echo_campaigns() és az echo_rate() törzse is_admin()-t követel).
--
-- MIT CSINÁL EZ A FÁJL:
--   1. echo.role_grant — az ECHO saját, HATÓKÖRÖS szerepkör-táblája.
--   2. echo.has_role(role, scope) — a jogosultsági helper, org-hierarchiával.
--   3. public.echo_teacher_link()      — oktatói sor ↔ UniPortal-fiók kötés.
--   4. public.echo_my_teacher_courses()— az OKTATÓ saját kurzusai, EREDMÉNY NÉLKÜL.
--   5. public.echo_role_grants() / public.echo_role_grant() — kiosztás.
--   6. public.echo_my_roles()          — a menüszűréshez, saját szerepkörök.
--
-- FUTTATÁS: Supabase dashboard → SQL Editor → New query → beilleszt → Run.
-- Idempotens; a replikán KÉTSZER lefuttatva ON_ERROR_STOP=1 mellett hibátlan.
--
-- ============================================================
-- A NÉGY SZERKEZETI DÖNTÉS EBBEN A SZELETBEN
-- ============================================================
--
--   1. NEM A profiles.role ENUMOT BŐVÍTJÜK.
--      MÉRVE (app.jsx:9633): a menüszűrő utolsó ága `return false`. Az afölötti
--      ágak NEVESÍTETT szerepkörökre illeszkednek (SUPERADMIN, ADMIN, AGENT,
--      FINANCE, ADMISSIONS, STUDENT). Egy új profiles.role érték — mondjuk
--      'OKTATO' — tehát egyetlen ágra sem illeszkedne, és a fiók NULLA
--      menüpontot kapna: bejelentkezne, és üres oldalsávot látna. Ráadásul
--      a public.is_staff() és a public.is_superadmin() FEHÉRLISTÁS
--      (role in ('SUPERADMIN','ADMIN','ADMISSIONS','FINANCE')), tehát a
--      RLS-oldal sem ismerné fel. Egy szerepkör-enum bővítése így nem egy
--      migráció, hanem az egész alkalmazás jogosultsági felületének átírása.
--      Ezért az ECHO KÜLÖN DIMENZIÓT kap: a UniPortal-szerepkör marad, ami
--      volt (STUDENT / ADMIN / …), és mellé jön nulla vagy több ECHO-grant.
--      Egy oktató fiókja tehát tipikusan STUDENT vagy egy külön létrehozott,
--      jóváhagyott fiók, amelynek van 'OKTATO' grantja.
--
--   2. AZ ECHO-JOG SOHA NEM SZÁRMAZIK A UniPortal SUPERADMIN-BÓL.
--      Az echo.has_role() KIZÁRÓLAG az echo.role_grant táblát nézi. Egy
--      SUPERADMIN fiók echo.has_role('MIR') hívása FALSE, amíg nem kap
--      explicit grantot. Ez szándékos: az OMHV eredményeihez való hozzáférés
--      a szenátusi határozat szerint NEVESÍTETT, iktatható, lejáró
--      felhatalmazás, nem az üzemeltetői jogosultság mellékterméke. Ezért van
--      a táblán granted_by, granted_at, expires_at és iktatoszam.
--      (A 16_echo_reports.sql public.is_admin() kapui EGYELŐRE MARADNAK —
--       lásd a 3. döntést. Az ECHO saját dimenziója itt kezdődik, nem itt ér
--       véget.)
--
--   3. A 16-OS is_admin() KAPUI ÁTMENETI HÍDKÉNT MEGMARADNAK.
--      Ez a fájl EGYETLEN meglévő RPC törzsét sem írja át. Ha az
--      echo_moderation_queue() kapuját most cserélnénk echo.has_role('MODERATOR')-ra,
--      abban a pillanatban SENKI nem tudna moderálni — nulla grant van a
--      rendszerben —, és a moderálási sor elérhetetlenné válna. A csere ezért
--      külön migráció dolga, MIUTÁN a grantok ki vannak osztva. Addig a két
--      kapu egymás mellett él: a régi RPC-ket az is_admin() védi, az újakat
--      a role_grant. Ezt a 16_echo_reports.sql fejléce is kimondja.
--
--   4. EGY FIÓKHOZ LEGFELJEBB EGY OKTATÓI SOR TARTOZHAT.
--      Az echo.my_teacher_id() törzse `limit 1` — ha egy profilhoz két
--      echo.teacher sor is köthető lenne, a függvény CSENDBEN választana
--      közülük egyet, és az oktató hol az egyik, hol a másik eredményét
--      látná. Ezt nem szabad futásidőre bízni: részleges UNIQUE index tiltja.
--      A fordított irány (egy oktatói sorhoz egy fiók) a mező skalár
--      voltából adódik.
--
-- ============================================================


-- ============================================================
-- 0. SZAKASZ — ELŐFELTÉTELEK ELLENŐRZÉSE
-- ============================================================
-- Inkább álljunk meg beszédes hibával, mint hogy egy hiányzó függvény miatt
-- félkész állapot maradjon a sémában.
do $pre$
declare v_missing text := '';
begin
  if to_regnamespace('echo') is null then v_missing := v_missing || ' echo séma (15_echo_core.sql)'; end if;
  if to_regprocedure('public.is_admin()')    is null then v_missing := v_missing || ' public.is_admin()';    end if;
  if to_regprocedure('public.is_approved()') is null then v_missing := v_missing || ' public.is_approved()'; end if;
  if to_regprocedure('echo.log_access(text,uuid,uuid,uuid,text)') is null
    then v_missing := v_missing || ' echo.log_access() (16_echo_reports.sql)'; end if;
  if to_regprocedure('echo.my_teacher_id()') is null
    then v_missing := v_missing || ' echo.my_teacher_id() (16_echo_reports.sql)'; end if;
  if v_missing <> '' then
    raise exception 'ECHO_PREREQ_MISSING: hianyzik:%. Futtasd elobb a 11/15/16 migraciot.', v_missing;
  end if;
end $pre$;


-- ============================================================
-- 1. SZAKASZ — echo.role_grant: az ECHO hatókörös szerepkör-táblája
-- ============================================================
-- A NYOLC SZEREPKÖR és amit jelentenek (28/2023. szenátusi határozat nyomán):
--   OKTATO         — a saját kurzusainak saját bontását láthatja
--   TANSZEKVEZETO  — a hatókörébe eső tanszék oktatóinak eredménye
--   DEKAN          — a hatókörébe eső kar eredménye
--   MIR            — Minőségirányítás: intézményi szint, jegyzőkönyv
--   REKTORI        — rektori/vezetői betekintés
--   EHOK           — hallgatói önkormányzati betekintés (aggregált)
--   MODERATOR      — a szöveges válaszok érvényességi vizsgálata (3. § (10))
--   SYSADMIN       — az ECHO üzemeltetése, grantok kiosztása
-- A lista CHECK constraint, NEM enum: az enum bővítése Postgresben nem
-- vonható vissza tranzakción belül, a CHECK igen.
--
-- HATÓKÖR (scope_org): NULL = intézményi szint. Kitöltve = az adott
-- szervezeti egység ÉS minden alatta lévő. Az irány szándékosan lefelé nyílik:
-- a kari dékán a tanszékeit is látja, a tanszékvezető a karát nem.
--
-- LEJÁRAT (expires_at): NULL = határozatlan. A visszavonás nem sortörlés,
-- hanem expires_at = now(): a kiosztás ténye AUDITÁLHATÓ marad.

create table if not exists echo.role_grant (
  id          uuid primary key default gen_random_uuid(),
  person      uuid not null references public.profiles(id) on delete cascade,
  role        text not null,
  scope_org   uuid references echo.org_unit(id) on delete cascade,
  granted_by  uuid references public.profiles(id) on delete set null,
  granted_at  timestamptz not null default now(),
  expires_at  timestamptz,
  iktatoszam  text,
  megjegyzes  text
);

-- Az idempotencia miatt a constraint külön, létezés-vizsgálattal.
do $c$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'echo_role_grant_role_chk'
                    and conrelid = 'echo.role_grant'::regclass) then
    alter table echo.role_grant add constraint echo_role_grant_role_chk
      check (role in ('OKTATO','TANSZEKVEZETO','DEKAN','MIR','REKTORI','EHOK','MODERATOR','SYSADMIN'));
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'echo_role_grant_iktato_chk'
                    and conrelid = 'echo.role_grant'::regclass) then
    -- Üres iktatószám ne legyen: vagy NULL, vagy értelmes hivatkozás.
    alter table echo.role_grant add constraint echo_role_grant_iktato_chk
      check (iktatoszam is null or length(btrim(iktatoszam)) between 1 and 64);
  end if;
end $c$;

-- EGY személy + EGY szerepkör + EGY hatókör = EGY sor. Két részleges index,
-- mert a NULL scope_org-ot a sima UNIQUE nem fogná össze (a NULL-ok
-- Postgresben megkülönböztetettek, és a `nulls not distinct` csak PG15-től
-- érhető el — ez a megoldás régebbi kiszolgálón is áll).
create unique index if not exists echo_role_grant_scoped_uidx
  on echo.role_grant (person, role, scope_org) where scope_org is not null;
create unique index if not exists echo_role_grant_global_uidx
  on echo.role_grant (person, role) where scope_org is null;
create index if not exists echo_role_grant_person_idx on echo.role_grant (person);
create index if not exists echo_role_grant_role_idx   on echo.role_grant (role);

-- Az echo séma nincs kitéve (nem szerepel a PostgREST exposed listáján), de
-- a védelem itt is két rétegű: RLS bekapcsolva, POLICY NÉLKÜL. Így ha valaha
-- valaki kiteszi a sémát, a tábla akkor is néma marad mindenkinek, aki nem
-- kerüli meg az RLS-t (a SECURITY DEFINER RPC-k a tulajdonos jogán olvassák).
alter table echo.role_grant enable row level security;

-- A 15_echo_core.sql 10.1 grant-blokkja MÁR LEFUTOTT, amikor ez a tábla
-- létrejön, ezért a revoke-ot itt meg kell ismételni — különben a tábla a
-- Supabase alapértelmezett séma-grantjaival ottmaradna.
do $g$
begin
  execute 'revoke all on table echo.role_grant from public';
  if exists (select 1 from pg_roles where rolname='anon')          then execute 'revoke all on table echo.role_grant from anon';          end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then execute 'revoke all on table echo.role_grant from authenticated'; end if;
  if exists (select 1 from pg_roles where rolname='service_role')  then execute 'revoke all on table echo.role_grant from service_role';  end if;
end $g$;

-- A 4. szerkezeti döntés kikényszerítése: egy fiókhoz egy oktatói sor.
-- MÉRVE: ma mind a 4 sor profile_id-je NULL, tehát az index azonnal felvehető.
create unique index if not exists echo_teacher_profile_uidx
  on echo.teacher (profile_id) where profile_id is not null;


-- ============================================================
-- 2. SZAKASZ — JOGOSULTSÁGI HELPEREK
-- ============================================================

-- 2.1 A szervezeti egység ÖNMAGA + minden FELMENŐJE.
-- Ez adja a hatókör lefelé nyílását: ha a grant a karra szól, és a kérdéses
-- egység egy alatta lévő tanszék, akkor a kar szerepel a tanszék felmenői
-- között — tehát a grant fed. Rekurzív CTE; az org_unit.parent_id-n
-- ON DELETE RESTRICT áll, kör nem alakulhat ki tranzakción kívül, de a
-- biztonság kedvéért mélységkorlátot is teszünk rá.
create or replace function echo.org_ancestors(p_org uuid)
returns table (org_id uuid)
language sql stable
set search_path = echo, public, pg_temp
as $$
  with recursive up(id, parent_id, d) as (
    select o.id, o.parent_id, 0 from echo.org_unit o where o.id = p_org
    union all
    select o.id, o.parent_id, up.d + 1
      from echo.org_unit o join up on o.id = up.parent_id
     where up.d < 16
  )
  select id from up
$$;

-- 2.2 echo.has_role(szerepkör, hatókör)
-- IGAZ, ha a bejelentkezett fióknak van ÉLŐ (nem lejárt) grantja a megadott
-- szerepkörre, ÉS a hatókör fedi a kérdezett szervezeti egységet.
--   p_scope = NULL  → "van-e ilyen szerepköre BÁRHOL" (menüszűréshez).
--   p_scope kitöltve → a grant vagy intézményi (scope_org is null), vagy
--                      a p_scope felmenői között van.
-- A jóváhagyás (public.is_approved()) beépített feltétel — ugyanaz az elv,
-- mint a 11_rbac_additive.sql public.has_role()-jánál: egyetlen hívó sem
-- felejtheti el, és egy visszavont fiók grantja sem éled újra.
-- FIGYELEM: itt SEMMILYEN profiles.role NEM ad jogot. Lásd 2. szerkezeti döntés.
create or replace function echo.has_role(p_role text, p_scope uuid default null)
returns boolean
language sql stable
set search_path = echo, public, extensions, pg_temp
as $$
  select public.is_approved()
     and exists (
           select 1
             from echo.role_grant g
            where g.person = auth.uid()
              and g.role   = p_role
              and (g.expires_at is null or g.expires_at > now())
              and (p_scope is null
                   or g.scope_org is null
                   or g.scope_org in (select a.org_id from echo.org_ancestors(p_scope) a))
         )
$$;

-- 2.3 Bármelyik a felsoroltak közül (kényelmi burkoló, hatókör nélkül).
create or replace function echo.has_any_role(variadic p_roles text[])
returns boolean
language sql stable
set search_path = echo, public, extensions, pg_temp
as $$
  select public.is_approved()
     and exists (
           select 1 from echo.role_grant g
            where g.person = auth.uid()
              and g.role = any (p_roles)
              and (g.expires_at is null or g.expires_at > now())
         )
$$;

-- 2.4 Ki oszthat grantot / ki láthatja a kiosztásokat.
-- ÁTMENETI HÍD: a public.is_admin() itt is benne van, különben az ELSŐ grantot
-- senki nem tudná kiosztani (tyúk-tojás: SYSADMIN grant nélkül nincs, aki
-- SYSADMIN grantot adjon). Amint a SYSADMIN grantok megvannak, ez az ág egy
-- külön migrációval kivehető — a 3. szerkezeti döntés szerint MOST nem.
create or replace function echo.can_grant()
returns boolean
language sql stable
set search_path = echo, public, extensions, pg_temp
as $$ select public.is_admin() or echo.has_role('SYSADMIN') $$;

create or replace function echo.can_see_grants()
returns boolean
language sql stable
set search_path = echo, public, extensions, pg_temp
as $$ select public.is_admin() or echo.has_any_role('SYSADMIN','MIR') $$;

-- 2.5 A szerepkörlista EGY helyen. A CHECK constraint és a felület
-- ugyanabból az egy forrásból dolgozik, hogy ne csússzon el egymástól.
create or replace function echo.role_list()
returns text[]
language sql immutable
set search_path = pg_temp
as $$ select array['OKTATO','TANSZEKVEZETO','DEKAN','MIR','REKTORI','EHOK','MODERATOR','SYSADMIN']::text[] $$;


-- ============================================================
-- 3. SZAKASZ — public.echo_teacher_link(): oktatói sor ↔ fiók
-- ============================================================
-- EZ AZ A FÜGGVÉNY, AMI A 0.4 MÉRT HIBÁJÁT MEGSZÜNTETI.
-- Feltölti az echo.teacher.profile_id-t, amitől az echo.my_teacher_id()
-- végre értéket ad — és ADJA HOZZÁ AZ 'OKTATO' GRANTOT IS, a tanszéki
-- hatókörrel. A kettő együtt jár: kötés grant nélkül olyan oktatót adna,
-- aki a menüben nem látja a saját nézetét; grant kötés nélkül olyat, aki
-- látja a menüpontot, de a szerver mögötte üresen hagyja.
--
-- p_profile = NULL  → A KÖTÉS BONTÁSA. Ilyenkor a korábban kötött személy
--   'OKTATO' grantjait lejártra állítjuk (nem töröljük — audit). Ez a
--   kilépő/áthelyezett oktató útja.
--
-- NAPLÓZÁS: minden hívás EGY sort ír az echo.access_log-ba. A jogosultsági
-- változás legalább annyira naplózandó esemény, mint egy eredmény-megtekintés.
create or replace function public.echo_teacher_link(p_teacher uuid, p_profile uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_prev   uuid;
  v_org    uuid;
  v_tname  text;
  v_taken  uuid;
  v_grant  uuid;
  v_email  text;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not echo.can_grant() then
    raise exception 'ECHO_FORBIDDEN: az oktatoi kotes admin vagy ECHO SYSADMIN jog.';
  end if;

  select t.profile_id, t.org_unit_id, t.name
    into v_prev, v_org, v_tname
    from echo.teacher t where t.id = p_teacher;
  if v_tname is null then raise exception 'ECHO_TEACHER_NOT_FOUND'; end if;

  if p_profile is not null then
    select p.email into v_email from public.profiles p where p.id = p_profile;
    if v_email is null then raise exception 'ECHO_PROFILE_NOT_FOUND'; end if;

    -- A 4. szerkezeti döntés: egy fiók egy oktatói sorhoz. Az index amúgy is
    -- megfogná, de a beszédes hibaüzenet a felületnek szól.
    select t.id into v_taken from echo.teacher t
      where t.profile_id = p_profile and t.id <> p_teacher;
    if v_taken is not null then
      raise exception 'ECHO_PROFILE_TAKEN: ez a fiok mar egy masik oktatoi sorhoz van kotve (%).', v_taken;
    end if;
  end if;

  update echo.teacher set profile_id = p_profile where id = p_teacher;

  if p_profile is not null then
    -- 'OKTATO' grant a tanszéki hatókörrel. Ha az oktatónak nincs szervezeti
    -- egysége (org_unit_id NULL), a grant intézményi hatókörű lesz — ez NEM
    -- ad többletjogot: az echo_my_teacher_courses() és a 16-os eredmény-RPC-k
    -- amúgy is a course_teacher kötésre szűrnek, nem a hatókörre.
    update echo.role_grant
       set expires_at = null, granted_by = auth.uid(), granted_at = now()
     where person = p_profile and role = 'OKTATO'
       and scope_org is not distinct from v_org
    returning id into v_grant;
    if v_grant is null then
      insert into echo.role_grant (person, role, scope_org, granted_by, megjegyzes)
      values (p_profile, 'OKTATO', v_org, auth.uid(),
              'automatikus grant az echo_teacher_link() hivasabol')
      returning id into v_grant;
    end if;
  end if;

  -- A bontásnál a KORÁBBI személy oktatói grantjait zárjuk le. Sortörlés
  -- nincs: a kiosztás ténye és ideje auditálható marad.
  if p_profile is null and v_prev is not null then
    update echo.role_grant
       set expires_at = now()
     where person = v_prev and role = 'OKTATO'
       and (expires_at is null or expires_at > now());
  end if;

  perform echo.log_access('echo_teacher_link', null, null, p_teacher, 'roles');

  return jsonb_build_object(
    'teacher_id',    p_teacher,
    'teacher_name',  v_tname,
    'profile_id',    p_profile,
    'profile_email', v_email,
    'korabbi_profile_id', v_prev,
    'grant_id',      v_grant,
    'muvelet',       case when p_profile is null then 'bontas' else 'kotes' end);
end $$;


-- ============================================================
-- 4. SZAKASZ — public.echo_my_teacher_courses()
-- ============================================================
-- A BEJELENTKEZETT OKTATÓ SAJÁT KURZUSAI, KAMPÁNYONKÉNT — EREDMÉNY NÉLKÜL.
--
-- MIÉRT KELL EGYÁLTALÁN: a kampány- és kurzusválasztót eddig az
-- echo_campaigns() + echo_rate() töltötte, és MINDKETTŐ törzse
-- public.is_admin()-t követel (15_echo_core.sql 9.6). Oktatóként tehát a
-- választó üres maradt, és a felület nem is tudott mit ajánlani.
--
-- MI MEGY VISSZA: kampányonként az ÁLLAPOT és kurzusonként a DARABSZÁMOK
-- (jogosult / elkezdte / beérkezett). MI NEM MEGY VISSZA: egyetlen válasz
-- tartalma sem, egyetlen átlag sem, egyetlen szöveg sem. Az eredményt
-- továbbra is KIZÁRÓLAG az echo_teacher_results() / echo_course_results()
-- adja, a saját results_gate()-jével.
--
-- A DARABSZÁM MÁR A NYITOTT ABLAK ALATT IS LÁTSZIK. Ez ugyanaz a döntés,
-- mint az echo_rate()-nél: a kitöltésre buzdító kommunikációnak kell egy
-- szám, és egy darabszámból egyetlen kitöltő válasza sem olvasható ki. Az
-- ÁTLAG az, ami visszahatna a még kitöltetlen kérdőívekre — az marad zárva.
--
-- 'eredmeny_lathato': a mező NEM új szabály, hanem az echo.setting
-- 'results_teacher_states' kulcsának KIOLVASÁSA, hogy a felület ne
-- találgasson, és ne csak egy elkapott kivételből tudja meg.
create or replace function public.echo_my_teacher_courses()
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_me    uuid := auth.uid();
  v_mine  uuid;
  v_name  text;
  v_ok    text[];
  v_out   jsonb;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;

  v_mine := echo.my_teacher_id();
  if v_mine is null then
    raise exception 'ECHO_FORBIDDEN: a fiok nincs oktatoi sorhoz kotve (echo.teacher.profile_id).';
  end if;
  -- A KÖTÉS ÖNMAGÁBAN NEM ELÉG. A grant az, ami az ECHO-ban jogot ad, és a
  -- grant lejárhat — egy tavalyi óraadó kötése ottmaradhat, a jogosultsága nem.
  if not echo.has_role('OKTATO') then
    raise exception 'ECHO_FORBIDDEN: nincs ervenyes OKTATO grantod (echo.role_grant).';
  end if;

  select t.name into v_name from echo.teacher t where t.id = v_mine;
  v_ok := echo.allowed_states('results_teacher_states');

  select coalesce(jsonb_agg(x order by x->>'opens_at' desc), '[]'::jsonb)
    into v_out
  from (
    select jsonb_build_object(
             'id', c.id, 'code', c.code, 'name', c.name_hu, 'name_en', c.name_en,
             'term', c.term, 'state', c.state,
             'opens_at', c.opens_at, 'closes_at', c.closes_at,
             'eredmeny_lathato', (c.state = any (v_ok)),
             'eredmeny_allapotok', array_to_string(v_ok, ', '),
             'kurzusok', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'course_id',   k.id,
                        'course_code', k.code,
                        'course_name', k.name_hu,
                        'course_name_en', k.name_en,
                        'szerep',      ct.role,
                        'share_pct',   ct.share_pct,
                        'eligible',  (select count(*) from echo.participation p
                                       where p.campaign_id = c.id and p.course_id = k.id and p.eligible),
                        'attempted', (select count(*) from echo.participation p
                                       where p.campaign_id = c.id and p.course_id = k.id and p.attempted),
                        'valaszok',  (select count(*) from echo.response r
                                       where r.campaign_id = c.id and r.course_id = k.id and r.scope = 'course'),
                        'oktatoi_valaszok', (select count(*) from echo.response r
                                       where r.campaign_id = c.id and r.course_id = k.id
                                         and r.scope = 'teacher' and r.teacher_id = v_mine)
                      ) order by k.code), '[]'::jsonb)
                 from echo.eligibility el
                 join echo.course k on k.id = el.course_id
                 join echo.course_teacher ct on ct.course_id = k.id and ct.teacher_id = v_mine
                where el.campaign_id = c.id and el.teacher_id = v_mine)
           ) as x
      from echo.campaign c
     -- CSAK azok a kampányok, amelyekben az alkalmassági motor (echo.eligibility)
     -- ténylegesen felvette ezt az oktatót. A draft kampány itt nem jelenik meg,
     -- mert arra még nem futott a motor — ez helyes: nincs is mit mutatni rajta.
     where exists (select 1 from echo.eligibility el
                    where el.campaign_id = c.id and el.teacher_id = v_mine)
  ) s;

  -- Egy sor a naplóba: ki nézte meg a saját kurzuslistáját, és mikor.
  -- Kurzusra és kampányra nem bontjuk, mert ez a hívás nem egy BONTÁS
  -- megtekintése — az eredmény-naplózás továbbra is a 16-os RPC-k dolga.
  perform echo.log_access('echo_my_teacher_courses', null, null, v_mine, 'teacher_courses');

  return jsonb_build_object(
    'teacher_id',   v_mine,
    'teacher_name', v_name,
    'kampanyok',    v_out);
end $$;


-- ============================================================
-- 5. SZAKASZ — GRANT-KEZELÉS (MIR / SYSADMIN / admin)
-- ============================================================

-- 5.1 public.echo_role_grants() — a kiosztások, az oktatói kötések és a
-- kiosztható elemek EGY hívásban. A felület (ECHO_RolesPanel) különben
-- négy külön kérésből rakná össze ugyanezt, és az echo séma nincs kitéve,
-- tehát táblát nem is olvashat közvetlenül.
create or replace function public.echo_role_grants()
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_out jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not echo.can_see_grants() then
    raise exception 'ECHO_FORBIDDEN: a szerepkor-kiosztas admin, ECHO SYSADMIN vagy MIR jog.';
  end if;

  select jsonb_build_object(
    'oszthatok', echo.can_grant(),
    'szerepkorok', to_jsonb(echo.role_list()),

    'egysegek', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', o.id, 'code', o.code, 'name', o.name_hu,
               'kind', o.kind, 'parent_id', o.parent_id) order by o.code), '[]'::jsonb)
        from echo.org_unit o),

    -- Az oktatói sorok a KÖTÉS állapotával. Ez a panel bal oldala.
    'oktatok', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', t.id, 'code', t.code, 'name', t.name, 'email', t.email,
               'org_unit_id', t.org_unit_id,
               'org_name', (select o.name_hu from echo.org_unit o where o.id = t.org_unit_id),
               'active', t.active,
               'profile_id', t.profile_id,
               'profile_email', (select p.email from public.profiles p where p.id = t.profile_id),
               'profile_name',  (select p.name  from public.profiles p where p.id = t.profile_id),
               'kurzusok', (select count(*) from echo.course_teacher ct where ct.teacher_id = t.id),
               'van_oktato_grant', exists (
                  select 1 from echo.role_grant g
                   where g.person = t.profile_id and g.role = 'OKTATO'
                     and (g.expires_at is null or g.expires_at > now()))
             ) order by t.name), '[]'::jsonb)
        from echo.teacher t),

    -- A köthető fiókok. JÓVÁHAGYOTT profilok — függetlenül a UniPortal-
    -- szerepkörüktől, mert az ECHO-jog nem abból származik (2. döntés).
    'profilok', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'email', p.email, 'name', p.name, 'role', p.role)
             order by lower(coalesce(p.email, ''))), '[]'::jsonb)
        from public.profiles p
       where p.approval_status = 'approved'),

    'grantok', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id,
               'person', g.person,
               'person_email', (select p.email from public.profiles p where p.id = g.person),
               'person_name',  (select p.name  from public.profiles p where p.id = g.person),
               'role', g.role,
               'scope_org', g.scope_org,
               'scope_name', (select o.name_hu from echo.org_unit o where o.id = g.scope_org),
               'granted_at', g.granted_at,
               'granted_by', g.granted_by,
               'granted_by_email', (select p.email from public.profiles p where p.id = g.granted_by),
               'expires_at', g.expires_at,
               'iktatoszam', g.iktatoszam,
               'megjegyzes', g.megjegyzes,
               'aktiv', (g.expires_at is null or g.expires_at > now())
             ) order by (g.expires_at is null or g.expires_at > now()) desc, g.granted_at desc), '[]'::jsonb)
        from echo.role_grant g)
  ) into v_out;

  perform echo.log_access('echo_role_grants', null, null, null, 'roles');
  return v_out;
end $$;

-- 5.2 public.echo_role_grant(...) — kiosztás és visszavonás.
-- A VISSZAVONÁS is ez a függvény: p_expires <= now() esetén a grant lejártra
-- áll, de a SOR MEGMARAD. Törlés nincs, mert egy megtörtént felhatalmazás
-- utólag nem tehető meg nem történtté.
-- p_iktatoszam a spec négy paraméterén FELÜLI, alapértelmezett érték —
-- a négyparaméteres hívás változatlanul működik.
create or replace function public.echo_role_grant(
  p_person     uuid,
  p_role       text,
  p_scope      uuid        default null,
  p_expires    timestamptz default null,
  p_iktatoszam text        default null
) returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_role  text := upper(btrim(coalesce(p_role, '')));
  v_ikt   text := nullif(btrim(coalesce(p_iktatoszam, '')), '');
  v_id    uuid;
  v_email text;
  v_fig   text := null;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not echo.can_grant() then
    raise exception 'ECHO_FORBIDDEN: szerepkort admin vagy ECHO SYSADMIN oszthat.';
  end if;

  if not (v_role = any (echo.role_list())) then
    raise exception 'ECHO_BAD_ROLE: ismeretlen szerepkor "%". Engedett: %.',
      v_role, array_to_string(echo.role_list(), ', ');
  end if;

  select p.email into v_email from public.profiles p where p.id = p_person;
  if v_email is null then raise exception 'ECHO_PROFILE_NOT_FOUND'; end if;

  if p_scope is not null and not exists (select 1 from echo.org_unit o where o.id = p_scope) then
    raise exception 'ECHO_ORG_NOT_FOUND';
  end if;

  -- Kimondjuk, ha a grant önmagában nem lesz elég. Az OKTATO szerepkör
  -- MŰKÖDÉSÉHEZ az echo.teacher.profile_id kötés is kell — grant nélkül a
  -- menüpont látszana, mögötte a szerver ECHO_FORBIDDEN-nel válaszolna.
  if v_role = 'OKTATO' and not exists (
       select 1 from echo.teacher t where t.profile_id = p_person) then
    v_fig := 'Ehhez a fiokhoz nincs oktatoi sor kotve. Az OKTATO grant onmagaban '
          || 'nem eleg: hasznald az echo_teacher_link() hivast is.';
  end if;

  update echo.role_grant
     set expires_at = p_expires,
         granted_by = auth.uid(),
         granted_at = now(),
         iktatoszam = coalesce(v_ikt, iktatoszam)
   where person = p_person and role = v_role
     and scope_org is not distinct from p_scope
  returning id into v_id;

  if v_id is null then
    insert into echo.role_grant (person, role, scope_org, granted_by, expires_at, iktatoszam)
    values (p_person, v_role, p_scope, auth.uid(), p_expires, v_ikt)
    returning id into v_id;
  end if;

  perform echo.log_access('echo_role_grant', null, null, null, 'roles');

  return jsonb_build_object(
    'grant_id',   v_id,
    'person',     p_person,
    'person_email', v_email,
    'role',       v_role,
    'scope_org',  p_scope,
    'expires_at', p_expires,
    'iktatoszam', v_ikt,
    'aktiv',      (p_expires is null or p_expires > now()),
    'muvelet',    case when p_expires is not null and p_expires <= now()
                       then 'visszavonas' else 'kiosztas' end,
    'figyelmeztetes', v_fig);
end $$;

-- 5.3 public.echo_my_roles() — a SAJÁT ECHO-szerepkörök.
-- Ezt a menüszűrés hívja (app.jsx, loadProfile). Bárki hívhatja, mert
-- KIZÁRÓLAG a saját sorait adja vissza — egy fiók a saját jogosultságát
-- amúgy is megtudja abból, hogy mi működik neki.
create or replace function public.echo_my_roles()
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_mine uuid;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  v_mine := echo.my_teacher_id();
  return jsonb_build_object(
    'teacher_id',   v_mine,
    'teacher_name', (select t.name from echo.teacher t where t.id = v_mine),
    'jovahagyott',  public.is_approved(),
    'szerepkorok', (
      select coalesce(jsonb_agg(distinct g.role), '[]'::jsonb)
        from echo.role_grant g
       where g.person = auth.uid()
         and (g.expires_at is null or g.expires_at > now())),
    'grantok', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'role', g.role,
               'scope_org', g.scope_org,
               'scope_name', (select o.name_hu from echo.org_unit o where o.id = g.scope_org),
               'expires_at', g.expires_at) order by g.role), '[]'::jsonb)
        from echo.role_grant g
       where g.person = auth.uid()
         and (g.expires_at is null or g.expires_at > now())));
end $$;


-- ============================================================
-- 6. SZAKASZ — GRANTOK (a legkényesebb rész)
-- ============================================================
-- Postgresben MINDEN újonnan létrehozott függvény EXECUTE jogot ad a PUBLIC
-- szerepkörnek. Ezért itt is: előbb mindenkitől el, aztán célzottan vissza.
-- Ugyanaz a minta, mint a 15_echo_core.sql 10. szakaszában.
do $grants$
declare
  f record;
  has_anon bool := exists (select 1 from pg_roles where rolname='anon');
  has_auth bool := exists (select 1 from pg_roles where rolname='authenticated');
  has_svc  bool := exists (select 1 from pg_roles where rolname='service_role');
begin
  -- 6.1 az echo sémás új függvények zárva maradnak (a kliens nem éri el őket)
  for f in select p.oid::regprocedure::text n
             from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'echo'
              and p.proname in ('org_ancestors','has_role','has_any_role',
                                'can_grant','can_see_grants','role_list')
  loop
    execute format('revoke all on function %s from public', f.n);
    if has_anon then execute format('revoke all on function %s from anon', f.n); end if;
    if has_auth then execute format('revoke all on function %s from authenticated', f.n); end if;
    if has_svc  then execute format('revoke all on function %s from service_role', f.n); end if;
  end loop;

  -- 6.2 a négy+egy új public RPC: előbb mindenkitől el
  for f in select p.oid::regprocedure::text n
             from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'public'
              and p.proname in ('echo_teacher_link','echo_my_teacher_courses',
                                'echo_role_grants','echo_role_grant','echo_my_roles')
  loop
    execute format('revoke all on function %s from public', f.n);
    if has_anon then execute format('revoke all on function %s from anon', f.n); end if;
    if has_auth then execute format('revoke all on function %s from authenticated', f.n); end if;
    if has_svc  then execute format('revoke all on function %s from service_role', f.n); end if;
  end loop;

  -- 6.3 majd célzottan vissza. Az 'anon' EGYIKET SEM kapja meg: az anonim
  -- szerepkörnek az ECHO-ban egyetlen dolga van, az echo_submit.
  if has_auth then
    grant execute on function public.echo_teacher_link(uuid, uuid)                        to authenticated;
    grant execute on function public.echo_my_teacher_courses()                            to authenticated;
    grant execute on function public.echo_role_grants()                                   to authenticated;
    grant execute on function public.echo_role_grant(uuid, text, uuid, timestamptz, text) to authenticated;
    grant execute on function public.echo_my_roles()                                      to authenticated;
  end if;
end $grants$;


-- ============================================================
-- 7. SZAKASZ — ÖNELLENŐRZÉS (mérés, nem ígéret)
-- ============================================================
-- Minden sor egy MÉRT érték és a hozzá tartozó ELVÁRT érték. Ha egy sorban
-- a kettő eltér, a migráció ugyan lefutott, de valami nem az, aminek hittük.
with c(sorszam, mit, ertek, elvart) as (
  select 1, 'echo.role_grant tabla letezik',
         (to_regclass('echo.role_grant') is not null)::text, 'true'
  union all
  select 2, 'echo.role_grant RLS bekapcsolva, policy NELKUL',
         (select (relrowsecurity and not exists (
                    select 1 from pg_policies
                     where schemaname='echo' and tablename='role_grant'))::text
            from pg_class where oid = 'echo.role_grant'::regclass), 'true'
  union all
  select 3, 'a nyolc szerepkor CHECK-kel vedve',
         (select count(*)::text from pg_constraint
           where conname = 'echo_role_grant_role_chk'
             and conrelid = 'echo.role_grant'::regclass), '1'
  union all
  select 4, 'egy fiok = egy oktatoi sor (reszleges UNIQUE index)',
         (select count(*)::text from pg_indexes
           where schemaname='echo' and indexname='echo_teacher_profile_uidx'), '1'
  union all
  select 5, 'az ot uj public RPC letrejott',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in
             ('echo_teacher_link','echo_my_teacher_courses','echo_role_grants',
              'echo_role_grant','echo_my_roles')), '5'
  union all
  select 6, 'az uj public RPC-k kozul EGYIKET SEM hivhatja az anon',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public'
             and p.proname in ('echo_teacher_link','echo_my_teacher_courses',
                               'echo_role_grants','echo_role_grant','echo_my_roles')
             and has_function_privilege('anon', p.oid, 'execute')), '0'
  union all
  select 7, 'az echo semas helperek zarva az authenticated elol',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='echo'
             and p.proname in ('has_role','has_any_role','can_grant','can_see_grants','role_list','org_ancestors')
             and has_function_privilege('authenticated', p.oid, 'execute')), '0'
  union all
  -- 8. Az echo.has_role() TORZSE nem hivatkozhat a profiles.role-ra es az
  --    is_admin()-ra: az ECHO-jog kizarolag explicit grantbol szarmazhat.
  select 8, 'echo.has_role() NEM olvas UniPortal szerepkort (sem profiles.role, sem is_admin)',
         (select (pg_get_functiondef(p.oid) not like '%is_admin%'
              and pg_get_functiondef(p.oid) not like '%profiles%')::text
            from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='echo' and p.proname='has_role'), 'true'
  union all
  -- 9. A 16-os ket eredmeny-RPC kapuja VALTOZATLANUL is_admin() (atmeneti hid).
  select 9, 'a 16-os eredmeny-RPC-k kapuja is_admin() maradt (atmeneti hid)',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public'
             and p.proname in ('echo_teacher_results','echo_course_results')
             and pg_get_functiondef(p.oid) like '%is_admin()%'), '2'
  union all
  -- 10. Lejart grant nem ad jogot: a has_role() torzseben ott az expires_at szures.
  select 10, 'a lejarati szures benne van a has_role() torzseben',
         (select (pg_get_functiondef(p.oid) like '%expires_at%')::text
            from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='echo' and p.proname='has_role'), 'true'
)
select sorszam, mit, ertek, elvart,
       case when ertek is not distinct from elvart then 'OK' else 'ELTER' end as allapot
from c order by sorszam;

-- ============================================================
-- AMIT EZ A FÁJL NEM OLD MEG — kimondva
-- ============================================================
--   • A 16_echo_reports.sql eredmény- és moderálási RPC-inek kapuja MARADT
--     public.is_admin(). Az echo.has_role()-ra cserélésük külön migráció,
--     MIUTÁN a grantok ki vannak osztva (3. szerkezeti döntés).
--   • A TANSZEKVEZETO / DEKAN / MIR / REKTORI / EHOK szerepkörök a táblában
--     már felvehetők, de EGYETLEN RPC SEM olvassa őket még. A hatókörös
--     eredménynézetük a következő szelet dolga — a szerepkörlista most azért
--     teljes, hogy a kiosztás ne kelljen sémamódosítás hozzá.
--   • Az echo.teacher sorokat továbbra sem ez a fájl hozza létre; a
--     Neptun-szinkron (ext_source / ext_id) dolga marad. Az echo_teacher_link()
--     a MEGLÉVŐ sorokat köti fiókhoz.
-- ============================================================
