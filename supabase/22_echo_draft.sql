-- ============================================================
-- UniPortal Pro — ECHO: PISZKOZAT-MENTÉS a kitöltőben (F9)
-- Neumann János Egyetem · OMHV · 28/2023. szenátusi határozat
-- ------------------------------------------------------------
-- MIÉRT KELL:
--   A kérdőív hat lépés, célokkal tizenegy. Ma a kitöltő SEMMIT nem ment: aki
--   félbehagyja, aki lenyomja a böngésző Vissza gombját, akinek lejár a
--   munkamenete, az mindent elveszít, és jellemzően nem kezdi újra. A felület
--   ezt eddig őszintén ki is írta ("a válaszaid nem mentődnek") — ez a migráció
--   az az alap, amitől ez a mondat megváltoztatható.
--
-- ============================================================
-- ADATVÉDELMI KOMPROMISSZUM — OLVASD EL, MIELŐTT BÁRMIT MÓDOSÍTASZ
-- ============================================================
--   A piszkozat NEM ANONIM. Ez a rendszer többi részének pontos ellentéte, és
--   szándékos:
--
--     • az echo.response sorokon NINCS student_key és NINCS időbélyeg;
--     • az echo.draft soron VAN student_key ÉS VAN updated_at;
--     • a piszkozat a TELJES válaszkészletet tartalmazza, a szabadszöveges
--       válaszokkal együtt, még mielőtt bármilyen tisztítás lefutna rajta.
--
--   Vagyis a beküldés pillanatáig egyetlen sor összeköti a hallgatót azzal,
--   amit az oktatójáról leírt. EZ A RENDSZER LEGÉRZÉKENYEBB TÁBLÁJA. A
--   kockázat vállalásának ára a következő négy szabály, amelyek együtt adják
--   a védelmet — bármelyik feloldása önmagában kinyitja a rendszert:
--
--   (1) A TARTALMAT SENKI MÁS NEM LÁTJA. Nincs olyan RPC — se admin, se MIR,
--       se oktatói —, amely a payloadot visszaadná. Az echo_draft_get() a
--       hívó SAJÁT sorát adja vissza, és a WHERE-ben ott a student_key =
--       auth.uid(). Az egyetlen adminisztratív rálátás a DARABSZÁM
--       (echo_draft_stats), tartalom nélkül. Ha valaha felmerül, hogy "csak
--       megnézzük, mi akadt el" — az a rendszer megtörése, nem hibakeresés.
--
--   (2) A TÁBLA KÍVÜLRŐL ELÉRHETETLEN. Az 'echo' séma nem exposed, a táblán
--       row level security él, és SEMMILYEN policy nincs rajta. A "RLS
--       bekapcsolva + nulla policy" SZIGORÚBB, mint egy saját-soros policy:
--       az utóbbi definiál egy látható halmazt, az előbbi nem definiál
--       semmit — közvetlen úton egyetlen sor sem olvasható, akkor sem, ha egy
--       jövőbeli platform-művelet véletlenül grantot osztana a sémára.
--       (Ugyanez a minta él az echo.participation és az echo.spent_nonce
--       tábláin — lásd 15_echo_core.sql.)
--
--   (3) A PISZKOZAT RÖVID ÉLETŰ. Három, egymástól független út törli:
--         • a kliens a sikeres beküldés UTÁN (echo_draft_drop) — a fő út;
--         • a kampány 'open' állapotból való kilépésekor egy TRIGGER, tehát a
--           pecsételés előtt már egyetlen piszkozat sem létezik;
--         • lejárat szerint az echo.gc_draft() takarító.
--
--   (4) A BEKÜLDÉS PILLANATÁBAN SZAKAD EL. Az echo_submit anonim, és a
--       piszkozatot NEM ő törli — lásd a következő szakaszt.
--
-- ------------------------------------------------------------
-- MIÉRT NEM AZ echo_submit TÖRLI A PISZKOZATOT — A DÖNTÉS INDOKLÁSA
-- ------------------------------------------------------------
--   Az echo_submit() KIZÁRÓLAG 'anon' joggal hívható (21_echo_harden_submit.sql
--   tartja karban), és a jegyen kívül semmit nem tud: a jegy campaign-t,
--   course-t és verziót hordoz, hallgatót NEM. Ez nem hiányosság, hanem a
--   rendszer tartóoszlopa.
--
--   Ahhoz, hogy az echo_submit törölni tudja a beküldő piszkozatát, tudnia
--   kellene, KI küld be. Bármelyik megoldás ezt visszahozná:
--     • student_key a payloadban  → a hallgató azonosítója ugyanabban a HTTP-
--       kérésben utazna, mint a válaszai. Pontosan ezt kerüli az anonim kliens.
--     • student_key a jegyben     → a jegyet a szerver írja alá, de a kliens
--       tárolja és küldi vissza; a beküldő kérés így megint azonosítót vinne.
--     • visszakeresés a válaszból → nincs mihez kötni, és ha lenne, az maga
--       lenne a deanonimizálás.
--   Vagyis az echo_submit-tal való törlés ára a rendszer anonimitása volna.
--   Ez az ár nem fizethető ki egy kényelmi funkcióért.
--
--   EZÉRT A VÁLASZTOTT MEGOLDÁS: a KLIENS hívja az echo_draft_drop()-ot a
--   sikeres beküldés UTÁN, a bejelentkezett (authenticated) munkamenetével —
--   tehát egy MÁSIK, azonosított kérésben, amely már semmilyen válasz-
--   tartalmat nem hordoz. A két kérés így elválik egymástól: az egyik névtelen
--   és tartalmas, a másik azonosított és üres.
--
--   ÉS MI VAN, HA A KLIENS MEGHAL A KETTŐ KÖZÖTT? Akkor a piszkozat ott marad.
--   Ezért nem az egyetlen védvonal: a (3) pont másik két útja — a kampányzárás
--   trigger és a lejárati takarító — kliens nélkül is eltakarítja. A kliensre
--   csak a GYORSASÁG van bízva, a BIZONYOSSÁG nem.
--
-- ------------------------------------------------------------
-- FUTTATÁSI SORREND: 15 → 16 → 17 → 18 → 18b → 18c → 19 → 20 → EZ (22) → 21.
--   A 21_echo_harden_submit.sql MINDIG az utolsó. Ez a fájl új publikus
--   függvényeket hoz létre, ezért utána a 21-et ÚJRA le kell futtatni.
--
-- Idempotens: tetszőleges sokszor újrafuttatható, meglévő piszkozatot nem
-- veszít el (a tábla create if not exists, a függvények create or replace).
-- ============================================================


-- ============================================================
-- 1. A PISZKOZAT TÁBLA
-- ============================================================
create table if not exists echo.draft (
  campaign_id  uuid        not null references echo.campaign(id) on delete cascade,
  course_id    uuid        not null references echo.course(id)   on delete cascade,
  -- A hallgató. A participation-nel azonos kulcsminta: profiles.id.
  -- FIGYELEM: EZ AZ AZONOSÍTÓ, ami miatt ez a tábla nem anonim.
  student_key  uuid        not null references public.profiles(id) on delete cascade,
  -- A kitöltő teljes állapota: { ans: {...}, tans: {...}, goals_seen: bool }.
  -- Nyers, tisztítatlan — a tisztítás az echo_submit 4. szakaszában történik,
  -- a beküldéskor. Itt SZÁNDÉKOSAN nyersen áll, mert a hallgatónak pontosan
  -- azt kell visszakapnia, amit beírt.
  payload      jsonb       not null default '{}'::jsonb,
  -- Hányadik lépésnél tartott. Csak a folytatás kényelmét szolgálja.
  step         integer     not null default 0,
  updated_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  primary key (campaign_id, course_id, student_key),
  constraint echo_draft_payload_obj_chk check (jsonb_typeof(payload) = 'object'),
  constraint echo_draft_step_chk        check (step >= 0),
  -- Ugyanaz a méretkorlát, mint az echo_submit payloadján (15_echo_core.sql):
  -- a piszkozat nem lehet nagyobb annál, ami később beküldhető.
  constraint echo_draft_size_chk        check (pg_column_size(payload) <= 65536)
);

-- A takarító és a kampányzárás szerinti törlés indexei.
create index if not exists echo_draft_expires_idx  on echo.draft (expires_at);
create index if not exists echo_draft_campaign_idx on echo.draft (campaign_id);

-- ---------- a védelem: RLS bekapcsolva, policy NÉLKÜL ----------
-- Lásd a fejléc (2) pontját: ez szigorúbb, mint egy saját-soros policy.
-- A hozzáférés KIZÁRÓLAG az alábbi SECURITY DEFINER RPC-ken át történik,
-- amelyek a törzsükben szűrnek a hívó auth.uid()-jára.
alter table echo.draft enable row level security;
alter table echo.draft force row level security;

-- Öv és nadrágtartó: a sémára amúgy sincs joga a kliensszerepköröknek, de ha
-- egy platform-művelet valaha grantot osztana, a táblát külön is visszazárjuk.
revoke all on echo.draft from public, anon, authenticated, service_role;

comment on table echo.draft is
  'ECHO piszkozat. NEM ANONIM: a beküldésig összeköti a hallgatót a válaszaival. '
  'Tartalmát csak a tulajdonos hallgató láthatja (echo_draft_get). Admin/MIR '
  'kizárólag darabszámot lát (echo_draft_stats). Törli: a kliens beküldés után, '
  'a kampányzárás triggere, és az echo.gc_draft() takarító.';


-- ============================================================
-- 2. LEJÁRAT (TTL)
-- ============================================================
-- A piszkozat élettartama két korlát közül a SZOROSABB:
--   • a kampány zárása után egy nappal semmiképp nem él tovább;
--   • és legfeljebb 'draft_ttl_days' napig a legutóbbi mentéstől.
insert into echo.setting (key, value, description)
values ('draft_ttl_days', '14',
        'A kitoltesi piszkozat elettartama napokban, a legutobbi mentestol '
        'szamitva. A kampany zarasa ennel is erosebb korlat: zaraskor minden '
        'piszkozat torlodik. Rovid ertek a helyes — a piszkozat az egyetlen '
        'hely, ahol a hallgato es a valasza egyutt all.')
on conflict (key) do nothing;

create or replace function echo.draft_expiry(p_campaign uuid)
returns timestamptz
language sql stable
set search_path to 'echo', 'public', 'pg_temp'
as $$
  select least(
           (select c.closes_at + interval '1 day' from echo.campaign c where c.id = p_campaign),
           now() + make_interval(days =>
             coalesce((select value::int from echo.setting where key = 'draft_ttl_days'), 14))
         );
$$;


-- ============================================================
-- 3. TAKARÍTÓ — lejárat szerint
-- ============================================================
-- Az echo.gc_spent_nonce() mintájára. Kézzel vagy cron-ból hívható:
--   select echo.gc_draft();
create or replace function echo.gc_draft()
returns integer
language plpgsql
set search_path to 'echo', 'public', 'pg_temp'
as $$
declare n integer;
begin
  delete from echo.draft where expires_at < now();
  get diagnostics n = row_count;
  return n;
end $$;


-- ============================================================
-- 4. TÖRLÉS A KAMPÁNY ZÁRÁSAKOR — TRIGGER
-- ============================================================
-- MIÉRT TRIGGER, ÉS NEM AZ echo_campaign_transition() KIEGÉSZÍTÉSE:
--   A pecsételés (sealed) visszafordíthatatlan, és a fejléc (3) pontja szerint
--   ELŐTTE egyetlen piszkozat sem maradhat. Ha ezt az átmenet-függvénybe
--   írnánk, minden jövőbeli írási út (kézi update, javító szkript, egy másik
--   RPC) megkerülhetné. A trigger a TÁBLÁN ül, tehát nem kerülhető meg.
--   Amint a kampány elhagyja az 'open' állapotot, a piszkozatai megszűnnek —
--   akkor is, ha valaki SQL-ből írja át az állapotot.
create or replace function echo.draft_purge_on_close()
returns trigger
language plpgsql
set search_path to 'echo', 'public', 'pg_temp'
as $$
begin
  if new.state is distinct from 'open' and old.state = 'open' then
    delete from echo.draft where campaign_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists echo_draft_purge_on_close on echo.campaign;
create trigger echo_draft_purge_on_close
  after update of state on echo.campaign
  for each row execute function echo.draft_purge_on_close();


-- ============================================================
-- 5. RPC — MENTÉS
-- ============================================================
create or replace function public.echo_draft_save(
  p_campaign uuid, p_course uuid, p_payload jsonb, p_step integer default 0)
returns jsonb
language plpgsql
security definer
set search_path to 'echo', 'public', 'extensions', 'pg_temp'
as $$
declare
  v_me uuid := auth.uid();
  v_p  echo.participation%rowtype;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;

  -- A payload alakja és mérete. Ugyanaz a korlát, mint a beküldésen.
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'ECHO_BAD_PAYLOAD';
  end if;
  if pg_column_size(p_payload) > 65536 then raise exception 'ECHO_PAYLOAD_TOO_LARGE'; end if;

  -- Csak nyitott kampányba, és csak arra a kurzusra, amire a hívó ALKALMAS.
  -- A participation sor egyben a jogosultság bizonyítéka: idegen kurzusra
  -- (és idegen hallgató nevében) nincs sor, tehát nincs mentés sem.
  select * into v_p
    from echo.participation
   where campaign_id = p_campaign and course_id = p_course and student_key = v_me;
  if not found or not v_p.eligible then raise exception 'ECHO_NOT_ELIGIBLE'; end if;
  if not echo.is_open(p_campaign) then raise exception 'ECHO_CAMPAIGN_CLOSED'; end if;

  -- Aki már beküldött, annak nincs mit menteni — és ne is lehessen új sort
  -- nyitni a nevében a zárás után.
  if v_p.submitted then raise exception 'ECHO_ALREADY_SUBMITTED'; end if;

  insert into echo.draft (campaign_id, course_id, student_key, payload, step,
                          updated_at, expires_at)
  values (p_campaign, p_course, v_me, p_payload, greatest(coalesce(p_step, 0), 0),
          now(), echo.draft_expiry(p_campaign))
  on conflict (campaign_id, course_id, student_key) do update
     set payload    = excluded.payload,
         step       = excluded.step,
         updated_at = now(),
         expires_at = excluded.expires_at;

  -- A visszatérés SZÁNDÉKOSAN nem tartalmaz tartalmat, csak nyugtát.
  return jsonb_build_object('ok', true, 'mentve', now(),
                            'lejar', echo.draft_expiry(p_campaign));
end $$;


-- ============================================================
-- 6. RPC — VISSZAOLVASÁS
-- ============================================================
-- A WHERE-ben ott a student_key = auth.uid(). Ez a függvény SEMMILYEN
-- paraméterrel nem vehető rá arra, hogy más sorát adja vissza: hallgató-
-- azonosítót nem is fogad.
create or replace function public.echo_draft_get(p_campaign uuid, p_course uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'echo', 'public', 'extensions', 'pg_temp'
as $$
declare
  v_me uuid := auth.uid();
  v_d  echo.draft%rowtype;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_approved() then raise exception 'ECHO_NOT_APPROVED'; end if;

  select * into v_d
    from echo.draft
   where campaign_id = p_campaign and course_id = p_course and student_key = v_me;

  -- A lejárt piszkozatot úgy kezeljük, mintha nem lenne — akkor is, ha a
  -- takarító még nem futott le rajta.
  if not found or v_d.expires_at < now() then
    return jsonb_build_object('van', false);
  end if;

  return jsonb_build_object(
    'van', true,
    'payload', v_d.payload,
    'step', v_d.step,
    'mentve', v_d.updated_at,
    'lejar', v_d.expires_at);
end $$;


-- ============================================================
-- 7. RPC — TÖRLÉS
-- ============================================================
-- Ezt hívja a kliens a SIKERES BEKÜLDÉS UTÁN (lásd a fejléc indoklását), és
-- ezt hívja az "elvetem a piszkozatot" gomb is. Csak a saját sort törli.
create or replace function public.echo_draft_drop(p_campaign uuid, p_course uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'echo', 'public', 'extensions', 'pg_temp'
as $$
declare
  v_me uuid := auth.uid();
  n    integer;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;

  delete from echo.draft
   where campaign_id = p_campaign and course_id = p_course and student_key = v_me;
  get diagnostics n = row_count;

  -- Nem hiba, ha nem volt mit törölni: a beküldés utáni törlés kétszer is
  -- lefuthat (újrapróbálkozás), és a takarító is elvihette előle.
  return jsonb_build_object('ok', true, 'torolve', n);
end $$;


-- ============================================================
-- 8. RPC — DARABSZÁM AZ ADMINNAK (TARTALOM NÉLKÜL)
-- ============================================================
-- Az üzemeltetésnek tudnia kell, hányan hagyták félbe — ez üzemi jelzés, nem
-- tartalom. A függvény kurzusonként ad EGY SZÁMOT, és semmi mást: se hallgatót,
-- se payloadot, se időbélyeget hallgatóhoz kötve.
--
-- MIÉRT VAN ITT k-KÜSZÖB: a kurzusonkénti darabszám önmagában is beszédes.
-- Ha egy háromfős kurzuson "1 piszkozat" látszik, az admin a kurzus névsorát
-- ismerve egyharmadra szűkítette, KI tölt éppen. Ezért a min_headcount alatti
-- kurzusok nem is jelennek meg, és a kampányszintű összeg mindig visszamegy.
create or replace function public.echo_draft_stats(p_campaign uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'echo', 'public', 'extensions', 'pg_temp'
as $$
declare
  v_min int := coalesce((select value::int from echo.setting where key = 'min_headcount'), 3);
  v_out jsonb;
  v_all int;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  select count(*) into v_all from echo.draft where campaign_id = p_campaign;

  select coalesce(jsonb_agg(x order by x->>'course_code'), '[]'::jsonb) into v_out
  from (
    select jsonb_build_object(
             'course_id',   k.id,
             'course_code', k.code,
             'course_name', k.name_hu,
             'piszkozat',   count(*)) as x
      from echo.draft d
      join echo.course k on k.id = d.course_id
     where d.campaign_id = p_campaign
     group by k.id, k.code, k.name_hu
    having count(*) >= v_min
  ) s;

  return jsonb_build_object('osszesen', v_all, 'kurzusonkent', v_out,
                            'kuszob', v_min);
end $$;


-- ============================================================
-- 9. echo_my_courses() — a "félbehagyott" állapot VALÓDIVÁ tétele
-- ============================================================
-- VÁLTOZÁS a 15_echo_core.sql-beli változathoz képest:
--   • új mező: 'has_draft'  — van-e élő piszkozat ezen a kurzuson;
--   • új mező: 'draft_step' — hányadik lépésnél tartott;
--   • új mező: 'draft_saved' — mikor mentett utoljára;
--   • az 'allapot' mező új értéke: 'felbehagyott'.
--
-- AZ ÁLLAPOTOK SORRENDJE SZÁMÍT. A 'felbehagyott' a 'folyamatban' ELÉ kerül:
--   'folyamatban'  = elindult egy BEKÜLDÉS, de nem fejeződött be (jegy kiadva,
--                    válasz nem érkezett) — ez hibaállapot;
--   'felbehagyott' = van mentett piszkozat, a kitöltés FOLYTATHATÓ — ez normál
--                    munkamenet.
-- Aki elkezdte és a beküldése hasalt el, annál mindkettő igaz lehet; ilyenkor a
-- FOLYTATHATÓSÁG a fontosabb üzenet, ezért az kerül előre.
create or replace function public.echo_my_courses()
returns jsonb
language plpgsql
stable security definer
set search_path to 'echo', 'public', 'extensions', 'pg_temp'
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
             -- A piszkozat LÉTE és a lépésszám megy vissza, a TARTALMA SOHA.
             -- Ez a hívó saját sora (student_key = v_me), tehát nem szivárgás.
             'has_draft',      (d.student_key is not null),
             'draft_step',     d.step,
             'draft_saved',    d.updated_at,
             -- Osszefoglalo allapot a felulet szamara:
             'allapot',
               case when p.submitted                        then 'kitoltve'
                    when echo.is_open(c.id) and d.student_key is not null
                                                            then 'felbehagyott'
                    when echo.is_open(c.id) and p.attempted then 'folyamatban'
                    when echo.is_open(c.id)                 then 'kitoltheto'
                    when echo.is_goals_open(c.id)           then 'celkituzes'
                    when c.state in ('closed','processing','sealed','published') then 'lezart'
                    else 'nem_nyitott' end
           ) as x
      from echo.participation p
      join echo.campaign c on c.id = p.campaign_id
      join echo.course   k on k.id = p.course_id
      -- BAL oldali join: a lejárt piszkozat úgy számít, mintha nem lenne
      -- (ugyanaz a szabály, mint az echo_draft_get()-ben).
      left join echo.draft d
             on d.campaign_id = p.campaign_id
            and d.course_id   = p.course_id
            and d.student_key = v_me
            and d.expires_at  >= now()
     where p.student_key = v_me
       and p.eligible
       and c.state <> 'draft'
  ) s;

  return v_out;
end $$;


-- ============================================================
-- 10. JOGOSULTSÁGOK
-- ============================================================
-- Mind a négy piszkozat-RPC AZONOSÍTOTT: a törzsük auth.uid()-ra szűr, tehát
-- munkamenet nélkül értelmezhetetlenek. Az anon egyiket sem hívhatja — ez az
-- ellentéte az echo_submit-nak, és szándékosan az.
do $$
declare fn text;
begin
  for fn in
    select p.oid::regprocedure::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('echo_draft_save', 'echo_draft_get',
                         'echo_draft_drop', 'echo_draft_stats')
  loop
    execute format('revoke all on function %s from public, anon, service_role', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end $$;

-- Az echo_my_courses() jogosultsága nem változik (authenticated), de a
-- create or replace után a platform alapértelmezett jogosztása visszaadhatja
-- az anon-t is. Visszazárjuk.
do $$
declare fn text;
begin
  for fn in
    select p.oid::regprocedure::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'echo_my_courses'
  loop
    execute format('revoke all on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end $$;


-- ============================================================
-- 11. ELLENŐRZÉS
-- ============================================================
with chk as (
  select 1 as sorrend, 'echo.draft tabla letezik' as ellenorzes,
         (to_regclass('echo.draft') is not null)::text as mert, 'true' as elvart
  union all
  select 2, 'RLS bekapcsolva es kenyszeritve',
         (select (relrowsecurity and relforcerowsecurity)::text
            from pg_class where oid = 'echo.draft'::regclass), 'true'
  union all
  select 3, 'policy-k szama a tablan (0 = semmi nem lathato kozvetlenul)',
         (select count(*)::text from pg_policies
           where schemaname = 'echo' and tablename = 'draft'), '0'
  union all
  select 4, 'kliensszerepkoroknek nincs joga a tablan',
         (select (coalesce(array_to_string(relacl, ' '), '') not like '%anon=%'
              and coalesce(array_to_string(relacl, ' '), '') not like '%authenticated=%')::text
            from pg_class where oid = 'echo.draft'::regclass), 'true'
  union all
  select 5, 'mind a 4 piszkozat-RPC letezik',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in
             ('echo_draft_save','echo_draft_get','echo_draft_drop','echo_draft_stats')), '4'
  union all
  select 6, 'egyik piszkozat-RPC sem hivhato anon-kent',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and p.proname in ('echo_draft_save','echo_draft_get','echo_draft_drop','echo_draft_stats')
             and coalesce(array_to_string(p.proacl, ' '), '') like '%anon=X%'), '0'
  union all
  select 7, 'a kampanyzaras trigger fent van',
         (select count(*)::text from pg_trigger
           where tgname = 'echo_draft_purge_on_close' and not tgisinternal), '1'
  union all
  select 8, 'echo_my_courses ad has_draft mezot',
         (select (pg_get_functiondef(p.oid) like '%has_draft%')::text
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'echo_my_courses'), 'true'
  union all
  select 9, 'a lejarati beallitas letezik',
         (select count(*)::text from echo.setting where key = 'draft_ttl_days'), '1'
)
select sorrend as "#", ellenorzes, mert, elvart,
       case when mert = elvart then 'OK' else 'HIBA' end as "allapot"
  from chk order by sorrend;

-- ============================================================
-- VÉGE — 22_echo_draft.sql
-- EZUTÁN FUTTASD ÚJRA: 21_echo_harden_submit.sql
-- ============================================================
