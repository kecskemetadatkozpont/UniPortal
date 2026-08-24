-- ============================================================
-- UniPortal Pro — ÖSSZEFŰZÖTT MIGRÁCIÓ: 17 → 25
-- ------------------------------------------------------------
-- MI EZ:
--   A 17-estől a 25-ösig tartó összes migráció, HELYES SORRENDBEN,
--   egyetlen másolható blokkban. A 15-öst és a 16-ost már lefuttattad.
--
-- FUTTATÁS:
--   Supabase → SQL Editor → új query → a TELJES fájl beillesztése → Run.
--   Minden rész idempotens: ha kétszer futtatod, nem hibázik.
--
-- MIT TARTALMAZ:
--   17  a kérdőív átnevezése piszkozat állapotban
--   18a kampány-életciklus (létrehozás + állapotgép)
--   18b a prototípus VALÓDI kérdőívszövegei új verzióként
--   18c a valódi verzió élesítése
--   19  ECHO szerepkörök és oktatói összekötés
--   20  óralátogatás-riport javítás
--   21  az anonim beküldés lezárása
--   22  piszkozat-mentés
--   23  űrlap-szabályok (legalább egy cél, "Egyéb" kötelező mező)
--   24  kérdőív 3. verzió (célmeghatározó bevezető kérdései)
--   25  felvételi státuszmodell + a beiratkozás utáni három sáv
--   21  MÉG EGYSZER — minden új függvény után újra kell zárni a beküldést
--
-- A VÉGÉN egy összesítő ellenőrzés fut. Küldd vissza a kimenetét.
-- ============================================================



-- ############################################################
-- ###  17_echo_template_rename.sql
-- ############################################################

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


-- ############################################################
-- ###  18a_echo_campaign.sql
-- ############################################################

-- ============================================================
-- UniPortal Pro — ECHO (OMHV): KAMPÁNY-ÉLETCIKLUS
-- 18a_echo_campaign.sql  ·  a 15_echo_core.sql és a 16_echo_reports.sql UTÁN fut
-- ------------------------------------------------------------
-- MIÉRT KELL EZ A SZELET
--   A 16_echo_reports.sql 2551 sornyi riport-, moderálási és szerkesztőmotorja
--   MA A FELÜLETRŐL ELÉRHETETLEN. Nem azért, mert hibás, hanem mert nincs
--   hozzá kapcsoló: a 19 publikus RPC között NINCS kampánylétrehozó és NINCS
--   kampány-állapotváltó. Az echo.results_gate() 'closed' vagy későbbi
--   állapotot követel (mérve: nyitott kampányon ECHO_RESULTS_NOT_READY még
--   SUPERADMIN-nak is), a kampányt viszont semmi nem tudja 'open'-ből
--   'closed'-ba vinni. A demó seed egyetlen kampánya örökre 'open'.
--   Ez a fájl teszi a meglévő motort használhatóvá — új riportlogika NINCS
--   benne, egyetlen k-küszöböt nem mozdít el.
--
-- MIT AD HOZZÁ
--   • public.echo_campaign_create(...)      — új kampány 'draft' állapotban
--   • public.echo_campaign_transition(...)  — az állapotgép egyetlen kapuja
--   • public.echo_campaign_get(...)         — egy kampány részletei + a
--                                             lehetséges következő állapotok
--   • echo.campaign_log                     — az állapotváltások naplója
--   • echo.campaign_seal_guard()            — a pecsét ADATBÁZIS-SZINTŰ zárja
--
-- AZ ÁLLAPOTGÉP
--   draft → open → closed → processing → sealed → published
--   Előre: EGYETLEN lépés. Az átugrás (pl. draft → sealed) elutasítva.
--   Vissza: EGYETLEN lépés, és KIZÁRÓLAG a pecsét előtt (open→draft,
--           closed→open, processing→closed). Minden visszalépés naplózva.
--   A 'sealed' és a 'published' állapotból visszaút NINCS — ezt nem csak az
--   RPC, hanem egy trigger is őrzi, tehát közvetlen UPDATE-tel sem lehet
--   megkerülni.
--
-- SZERKEZETI DÖNTÉSEK, amiket ez a fájl SEM sért
--   • az 'echo' séma nem exposed; minden hozzáférés public sémás
--     SECURITY DEFINER RPC-n megy
--   • a válaszsoron továbbra sincs időbélyeg; az itt bevezetett
--     echo.campaign_log a KAMPÁNYRÓL szól, nem a beküldésről, és nincs
--     közös kulcsa az echo.response-szal
--   • a pecsételés meghívja az echo.shuffle_responses()-t: a fizikai
--     sorrend (ctid) mint rejtett csatorna itt bomlik el végleg
--
-- FUTTATÁSI SORREND — FONTOS
--   A 16_echo_reports.sql 8. szakaszának grant-blokkja MINDEN public sémás
--   echo_* függvényről visszavon minden jogot, és csak a SAJÁT listáján
--   szereplőket adja vissza. Ha a 16-ost EZUTÁN futtatod le újra, az itteni
--   három RPC elveszíti az 'authenticated' grantot, és a felület
--   "permission denied for function" hibát kap. Ilyenkor futtasd le újra
--   ezt a fájlt is — idempotens, a 4. szakasz visszaadja a grantokat.
--
-- Idempotens — biztonságosan újrafuttatható (ON_ERROR_STOP=1 mellett is).
-- ============================================================


-- ============================================================
-- 1. SZAKASZ — SÉMABŐVÍTÉS
-- ============================================================

-- 1.1 A pecsételés és a közzététel időpontja a kampánysoron.
-- MIÉRT A SOROn: az echo.campaign nem tartalmaz válasz-adatot, tehát ide
-- tehető időbélyeg anélkül, hogy bármelyik beküldés idejét elárulná.
alter table echo.campaign add column if not exists sealed_at    timestamptz;
alter table echo.campaign add column if not exists published_at timestamptz;

comment on column echo.campaign.sealed_at is
  'A lepecsetelés időpontja. Ha nem NULL, a kampány adata VÉGLEGES: '
  'az echo.shuffle_responses() lefutott, visszalépés nincs.';
comment on column echo.campaign.published_at is
  'A közzététel időpontja — ettől kezdve az oktatók is látják a saját '
  'bontásukat (echo.results_gate: results_teacher_states).';

-- 1.2 Az állapotváltások naplója.
-- MIÉRT KÜLÖN TÁBLA ÉS NEM CSAK access_log: az access_log MEGTEKINTÉST
-- naplóz (ki nézte meg melyik bontást). Az állapotváltás DÖNTÉS, más a
-- megőrzési ideje és más a köre. Mindkettőbe írunk: ide a döntést, oda a
-- műveletet — a kettő egymást ellenőrzi.
create table if not exists echo.campaign_log (
  id           uuid primary key default gen_random_uuid(),
  campaign_id  uuid not null references echo.campaign(id) on delete cascade,
  from_state   text,
  to_state     text not null,
  irany        text not null default 'elore',   -- elore | vissza | letrehozas
  forced       boolean not null default false,
  actor_key    uuid references public.profiles(id) on delete set null,
  actor_email  text,
  detail       jsonb not null default '{}'::jsonb,
  at           timestamptz not null default now(),
  constraint echo_campaign_log_irany_chk check (irany in ('elore','vissza','letrehozas'))
);
create index if not exists echo_campaign_log_campaign_idx
  on echo.campaign_log (campaign_id, at desc);

comment on table echo.campaign_log is
  'A kampany allapotvaltasainak naploja. Nem torolheto RPC-bol. Az "at" a '
  'DONTES ideje (adminisztrativ esemeny), semmilyen kapcsolata nincs az '
  'echo.response soraival — kozos kulcs sincs koztuk.';

-- RLS a naplón is: második védvonal, policy nélkül (lásd 16_echo_reports.sql 8.6).
alter table echo.campaign_log enable row level security;

-- 1.3 Ugyanarra a félévre ne legyen két AKTÍV kampány.
-- MIÉRT: az echo.eligibility_rebuild() a kampány FÉLÉVÉRE szűrve gyűjti a
-- kurzusokat (where c.term = v_term). Két aktív kampány ugyanarra a félévre
-- tehát pontosan UGYANAZT a kurzushalmazt célozná meg, és minden hallgató
-- két kérdőívet kapna ugyanarról az oktatóról. A 'sealed'/'published'
-- kampányok kimaradnak a feltételből: azok már lezárt történelmi adatok,
-- melléjük a következő félév kampánya nyugodtan létrejöhet.
-- Ha valakinél mégis van két aktív kampány egy félévre, az index nem jön
-- létre, a migráció viszont NEM hasal el — a szabályt ilyenkor csak az RPC
-- kényszeríti ki, és erről NOTICE szól.
do $idx$
begin
  begin
    create unique index if not exists echo_campaign_active_term_uidx
      on echo.campaign (term)
      where state in ('draft','open','closed','processing');
  exception when unique_violation then
    raise notice 'ECHO 18: az echo_campaign_active_term_uidx NEM jott letre — '
                 'mar most van ket aktiv kampany ugyanarra a felevre. '
                 'A szabalyt ilyenkor csak az echo_campaign_create() ellenorzi.';
  end;
end
$idx$;


-- ============================================================
-- 2. SZAKASZ — AZ ÁLLAPOTGÉP BELSŐ FÜGGVÉNYEI
-- ============================================================

-- 2.1 Az állapotok sorrendje. Egyetlen helyen — ha valaha új állapot kerül
-- a láncba, csak ez a függvény és a CHECK constraint változik.
create or replace function echo.campaign_state_rank(p_state text)
returns integer
language sql immutable
as $$
  select case p_state
           when 'draft'      then 0
           when 'open'       then 1
           when 'closed'     then 2
           when 'processing' then 3
           when 'sealed'     then 4
           when 'published'  then 5
           else -1
         end
$$;

-- 2.2 A PECSÉT ZÁRJA — adatbázis-szintű, nem RPC-szintű.
-- MIÉRT TRIGGER: az RPC-t meg lehet kerülni (psql, service_role, egy későbbi
-- migráció figyelmetlen UPDATE-je). A pecsét viszont az a pont, ahol az
-- adat véglegessé válik és a kutatási/archiválási hivatkozás értelmet nyer.
-- Ha egy sealed kampány visszaléphetne, a "végleges" szó elveszítené a
-- jelentését, és ezt UTÓLAG nem lehet visszaállítani. Ezért itt őrizzük.
create or replace function echo.campaign_seal_guard()
returns trigger
language plpgsql
set search_path = echo, public, pg_temp
as $$
declare r_old int; r_new int;
begin
  if tg_op = 'DELETE' then
    if echo.campaign_state_rank(old.state) >= 4 then
      raise exception 'ECHO_SEAL_IRREVERSIBLE: lepecsetelt kampany (%) nem torolheto.', old.code;
    end if;
    return old;
  end if;

  r_old := echo.campaign_state_rank(old.state);
  r_new := echo.campaign_state_rank(new.state);

  -- Visszalépés a pecsét után: soha.
  if r_old >= 4 and r_new < r_old then
    raise exception 'ECHO_SEAL_IRREVERSIBLE: a kampany allapota "%", ebbol "%"-ba '
                    'visszalepni nem lehet. A pecsetelessel az adat veglegesse valt.',
                    old.state, new.state;
  end if;

  -- A pecsét után az ablak és a sablonverzió is befagy: ezek határozzák meg,
  -- MIT jelent a lepecsételt adat. Ha utólag elmozdulnának, az eredmény
  -- értelmezhetetlenné válna.
  if r_old >= 4 then
    if new.template_version_id is distinct from old.template_version_id
       or new.opens_at  is distinct from old.opens_at
       or new.closes_at is distinct from old.closes_at
       or new.term      is distinct from old.term then
      raise exception 'ECHO_SEAL_IRREVERSIBLE: lepecsetelt kampany ablaka, feleve '
                      'es sablonverzioja nem modosithato.';
    end if;
    -- A pecsételés időpontját sem lehet átírni.
    if new.sealed_at is distinct from old.sealed_at and old.sealed_at is not null then
      raise exception 'ECHO_SEAL_IRREVERSIBLE: a sealed_at nem irhato felul.';
    end if;
  end if;

  return new;
end $$;

drop trigger if exists echo_campaign_seal_guard_trg on echo.campaign;
create trigger echo_campaign_seal_guard_trg
  before update or delete on echo.campaign
  for each row execute function echo.campaign_seal_guard();

-- 2.3 Előfeltétel-ellenőrzés EGY célállapotra.
-- Nem dob kivételt: jsonb-t ad vissza, hogy ugyanezt a logikát használhassa
-- a felület is ("mi hiányzik még?"), ne csak a tényleges váltás.
--   ok          — mehet-e
--   kod/uzenet  — beszédes hiba, ha nem
--   forcolhato  — feloldható-e p_force-szal. IDŐZÍTÉSI és TELJESSÉGI
--                 feltételek igen; SZERKEZETI feltételek (átugrás, hiányzó
--                 jogosultsági lista, nem éles sablon) SOHA.
create or replace function echo.campaign_precheck(p_campaign uuid, p_to text)
returns jsonb
language plpgsql stable
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c        echo.campaign%rowtype;
  r_from   int;
  r_to     int;
  v_tvst   text;
  v_elig   int;
  v_pend   int;
begin
  select * into c from echo.campaign where id = p_campaign;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;

  r_from := echo.campaign_state_rank(c.state);
  r_to   := echo.campaign_state_rank(p_to);

  if r_to < 0 then
    return jsonb_build_object('ok', false, 'kod', 'ECHO_BAD_STATE', 'forcolhato', false,
      'uzenet', format('ismeretlen celallapot: "%s".', p_to));
  end if;
  if r_to = r_from then
    return jsonb_build_object('ok', false, 'kod', 'ECHO_SAME_STATE', 'forcolhato', false,
      'uzenet', format('a kampany mar "%s" allapotban van.', c.state));
  end if;

  -- --- visszalépés ---
  if r_to < r_from then
    if r_from >= 4 then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_SEAL_IRREVERSIBLE', 'forcolhato', false,
        'uzenet', format('a kampany allapota "%s": a pecsetelés utan visszalepni nem lehet.', c.state));
    end if;
    if r_to < r_from - 1 then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_STATE_SKIP', 'forcolhato', false,
        'uzenet', format('visszafele is csak EGY lepes engedelyezett: "%s" utan "%s" kovetkezne.',
                         c.state, case r_from when 1 then 'draft' when 2 then 'open' else 'closed' end));
    end if;
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', format('visszalepes "%s" -> "%s" (naplozva).', c.state, p_to));
  end if;

  -- --- előrelépés: csak egy lépés ---
  if r_to > r_from + 1 then
    return jsonb_build_object('ok', false, 'kod', 'ECHO_STATE_SKIP', 'forcolhato', false,
      'uzenet', format('az allapotgep nem ugorhato at: "%s" utan "%s" kovetkezik, nem "%s".',
        c.state,
        case r_from when 0 then 'open' when 1 then 'closed' when 2 then 'processing'
                    when 3 then 'sealed' when 4 then 'published' else '-' end,
        p_to));
  end if;

  if p_to = 'open' then
    select tv.state into v_tvst from echo.template_version tv where tv.id = c.template_version_id;
    if coalesce(v_tvst, '') <> 'live' then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_TEMPLATE_NOT_LIVE', 'forcolhato', false,
        'uzenet', format('a kampany sablonverzioja "%s" allapotu; megnyitni csak "live" '
                         'verzioval lehet (echo_template_transition).', coalesce(v_tvst,'nincs')));
    end if;
    select count(*) into v_elig from echo.eligibility where campaign_id = p_campaign;
    if v_elig = 0 then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_NO_ELIGIBILITY', 'forcolhato', false,
        'uzenet', 'nincs egyetlen jogosultsagi sor sem: futtasd le eloszor az '
                  'echo_rebuild_eligibility()-t. Jogosultsagi lista nelkul a kampanyt '
                  'senki nem tudna kitolteni, es a kizarasi naplo is ures maradna.');
    end if;
    if now() >= c.closes_at then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_WINDOW_ELAPSED', 'forcolhato', true,
        'uzenet', format('a zarasi idopont (%s) mar elmult: a kampany megnyitasa utan '
                         'azonnal zarhato lenne. Kenyszeritessel megis megnyithato.', c.closes_at));
    end if;
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', format('%s jogosultsagi par, eles sablonverzio.', v_elig));
  end if;

  if p_to = 'closed' then
    if now() < c.closes_at then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_WINDOW_OPEN', 'forcolhato', true,
        'uzenet', format('a kitoltesi ablak %s-ig tart. Korai zaras csak kenyszeritessel '
                         '(p_force), mert a mar kiadott, el nem koltott jegyek ervenyuket vesztik.',
                         c.closes_at));
    end if;
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', 'a kitoltesi ablak lejart.');
  end if;

  if p_to = 'processing' then
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', 'a moderalasi sor feltoltese es a reszvetel lezarasa ekkor indul.');
  end if;

  if p_to = 'sealed' then
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', 'FIGYELEM: a pecsetelés VISSZAFORDITHATATLAN. Lefut az '
                'echo.shuffle_responses(), a valaszok fizikai sorrendje elbomlik.');
  end if;

  if p_to = 'published' then
    select count(*) into v_pend
      from echo.moderation m
      join echo.response r on r.id = m.response_id
     where r.campaign_id = p_campaign and m.allapot = 'pending';
    if v_pend > 0 then
      return jsonb_build_object('ok', false, 'kod', 'ECHO_MODERATION_PENDING', 'forcolhato', true,
        'uzenet', format('%s moderalatlan szoveges valasz van meg a sorban. A kozzetetellel '
                         'ezek az oktatokhoz is eljutnanak. Kenyszeritessel megis kozzeteheto.', v_pend));
    end if;
    return jsonb_build_object('ok', true, 'kod', null, 'forcolhato', false,
      'uzenet', 'a moderalasi sor ures: az eredmeny megnyithato a jogosulti kornek.');
  end if;

  return jsonb_build_object('ok', false, 'kod', 'ECHO_BAD_STATE', 'forcolhato', false,
    'uzenet', format('kezeletlen celallapot: "%s".', p_to));
end $$;

-- 2.4 A lehetséges következő állapotok — a felület gombjainak forrása.
create or replace function echo.campaign_next(p_campaign uuid)
returns jsonb
language plpgsql stable
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_state text;
  r_from  int;
  v_out   jsonb := '[]'::jsonb;
  v_cand  text;
  v_pre   jsonb;
begin
  select state into v_state from echo.campaign where id = p_campaign;
  if v_state is null then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;
  r_from := echo.campaign_state_rank(v_state);

  -- előre egy lépés
  if r_from between 0 and 4 then
    v_cand := (array['draft','open','closed','processing','sealed','published'])[r_from + 2];
    v_pre  := echo.campaign_precheck(p_campaign, v_cand);
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'to', v_cand, 'irany', 'elore',
      'ok', v_pre->'ok', 'kod', v_pre->'kod',
      'forcolhato', v_pre->'forcolhato', 'uzenet', v_pre->>'uzenet',
      'visszafordithatatlan', (v_cand = 'sealed')));
  end if;

  -- vissza egy lépés — csak a pecsét ELŐTT
  if r_from between 1 and 3 then
    v_cand := (array['draft','open','closed','processing','sealed','published'])[r_from];
    v_pre  := echo.campaign_precheck(p_campaign, v_cand);
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'to', v_cand, 'irany', 'vissza',
      'ok', v_pre->'ok', 'kod', v_pre->'kod',
      'forcolhato', v_pre->'forcolhato', 'uzenet', v_pre->>'uzenet',
      'visszafordithatatlan', false));
  end if;

  return v_out;
end $$;


-- ============================================================
-- 3. SZAKASZ — PUBLIKUS RPC-K
-- ============================================================

-- ------------------------------------------------------------
-- 3.1 public.echo_campaign_create(...)
-- ------------------------------------------------------------
-- Új kampány MINDIG 'draft' állapotban jön létre. Megnyitni csak külön
-- lépésben, a jogosultsági lista felépítése után lehet — így nem fordulhat
-- elő, hogy egy kampány már fogad kitöltést, mielőtt eldőlt volna, kit érint.
drop function if exists public.echo_campaign_create(text,text,uuid,timestamptz,timestamptz);
create or replace function public.echo_campaign_create(
  p_nev              text,
  p_term             text,
  p_template_version uuid,
  p_opens_at         timestamptz,
  p_closes_at        timestamptz
) returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_nev    text := nullif(btrim(coalesce(p_nev, '')), '');
  v_term   text := nullif(btrim(coalesce(p_term, '')), '');
  v_tvst   text;
  v_tpl    text;
  v_code   text;
  v_base   text;
  v_n      int := 1;
  v_id     uuid;
  v_busy   text;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  if v_nev is null then
    raise exception 'ECHO_NAME_EMPTY: a kampany neve nem lehet ures.';
  end if;
  if length(v_nev) > 160 then
    raise exception 'ECHO_NAME_TOO_LONG: a kampany neve legfeljebb 160 karakter.';
  end if;
  if v_term is null then
    raise exception 'ECHO_TERM_EMPTY: a felev jelolese nem lehet ures (pl. 2025/26/2).';
  end if;
  if p_opens_at is null or p_closes_at is null then
    raise exception 'ECHO_WINDOW_MISSING: a nyitasi es a zarasi idopont is kotelezo.';
  end if;
  if p_closes_at <= p_opens_at then
    raise exception 'ECHO_WINDOW_INVALID: a zaras (%) nem lehet a nyitas (%) elott vagy azzal egyido.',
      p_closes_at, p_opens_at;
  end if;

  -- A sablonverzió: 'live' vagy 'approved'.
  -- MIÉRT ENGEDJÜK AZ 'approved'-ot IS: a kampány létrehozása előkészítő
  -- művelet, a jóváhagyott verzió élesítése önálló, naplózott lépés
  -- (echo_template_transition). A MEGNYITÁS viszont már 'live'-ot követel —
  -- lásd echo.campaign_precheck(): ECHO_TEMPLATE_NOT_LIVE.
  select tv.state, t.name_hu into v_tvst, v_tpl
    from echo.template_version tv
    join echo.template t on t.id = tv.template_id
   where tv.id = p_template_version;
  if v_tvst is null then raise exception 'ECHO_VERSION_NOT_FOUND'; end if;
  if v_tvst not in ('live','approved') then
    raise exception 'ECHO_TEMPLATE_NOT_READY: a valasztott sablonverzio allapota "%", '
                    'kampanyhoz csak "approved" vagy "live" verzio hasznalhato.', v_tvst;
  end if;

  -- Egy félévre egy aktív kampány. Az indoklás az 1.3 pontnál.
  select c.code into v_busy
    from echo.campaign c
   where c.term = v_term
     and c.state in ('draft','open','closed','processing')
   limit 1;
  if v_busy is not null then
    raise exception 'ECHO_TERM_BUSY: a(z) % felevre mar van aktiv kampany (%). '
                    'Az echo.eligibility_rebuild() a felev OSSZES kurzusat gyujti, '
                    'igy ket aktiv kampany ugyanazt a kort celozna meg ketszer.',
                    v_term, v_busy;
  end if;

  -- Kód: emberi olvasásra, egyedi. Az echo.slug() a magyar ékezeteket is kezeli.
  v_base := 'OMHV-' || echo.slug(v_term);
  v_code := v_base;
  while exists (select 1 from echo.campaign where code = v_code) loop
    v_n := v_n + 1;
    v_code := v_base || '-' || v_n::text;
  end loop;

  insert into echo.campaign (code, name_hu, term, template_version_id, opens_at, closes_at, state)
  values (v_code, v_nev, v_term, p_template_version, p_opens_at, p_closes_at, 'draft')
  returning id into v_id;

  insert into echo.campaign_log (campaign_id, from_state, to_state, irany, actor_key, actor_email, detail)
  values (v_id, null, 'draft', 'letrehozas', auth.uid(),
          (select email from public.profiles where id = auth.uid()),
          jsonb_build_object('code', v_code, 'term', v_term,
                             'template_version_id', p_template_version,
                             'template', v_tpl, 'template_state', v_tvst));

  perform echo.log_access('echo_campaign_create', v_id, null, null, 'campaign');

  return jsonb_build_object(
    'id', v_id, 'code', v_code, 'name', v_nev, 'term', v_term, 'state', 'draft',
    'opens_at', p_opens_at, 'closes_at', p_closes_at,
    'template_version_id', p_template_version, 'template_state', v_tvst,
    'kovetkezo_lepes', 'echo_rebuild_eligibility() a jogosultsagi listahoz, majd megnyitas.');
end $$;


-- ------------------------------------------------------------
-- 3.2 public.echo_campaign_transition(kampány, célállapot, kényszerítés)
-- ------------------------------------------------------------
-- AZ ÁLLAPOTGÉP EGYETLEN KAPUJA. Minden lépéshez tartozik előfeltétel
-- (echo.campaign_precheck) és mellékhatás:
--   closed → processing : echo.mark_submitted() + echo.moderation_fill()
--                         (+ echo.shuffle_moderation(), ha még minden pending)
--   processing → sealed : echo.shuffle_responses() — VISSZAFORDÍTHATATLAN
--   sealed → published  : az eredmény megnyílik az oktatóknak is
drop function if exists public.echo_campaign_transition(uuid,text,boolean);
create or replace function public.echo_campaign_transition(
  p_campaign uuid,
  p_to       text,
  p_force    boolean default false
) returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c          echo.campaign%rowtype;
  v_pre      jsonb;
  v_forced   boolean := false;
  v_irany    text;
  v_detail   jsonb := '{}'::jsonb;
  v_marked   int;
  v_courses  int;
  v_fill     int;
  v_mix      int;
  v_shuf     int;
  v_nonpend  int;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  -- Sorzár: két párhuzamos admin ne vihesse ugyanazt a kampányt kétfelé.
  select * into c from echo.campaign where id = p_campaign for update;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;

  v_pre := echo.campaign_precheck(p_campaign, p_to);
  if not (v_pre->>'ok')::boolean then
    if coalesce(p_force, false) and (v_pre->>'forcolhato')::boolean then
      v_forced := true;   -- a felteteltol eltekintunk, de NAPLOZZUK
    else
      raise exception '%: %', v_pre->>'kod', v_pre->>'uzenet';
    end if;
  end if;

  v_irany := case when echo.campaign_state_rank(p_to) < echo.campaign_state_rank(c.state)
                  then 'vissza' else 'elore' end;

  -- --- mellékhatások ---
  if p_to = 'processing' then
    -- 1) A részvételi napló lezárása: mely kurzusokon költötték el az összes
    --    kiadott jegyet. (Az echo.mark_submitted() kurzusonként egy sort ad.)
    select coalesce(sum(m.marked), 0), count(*) into v_marked, v_courses
      from echo.mark_submitted(p_campaign) m;

    -- 2) A moderálási sor feltöltése. Ugyanezt teszi az echo_moderation_queue()
    --    is minden hívásnál (on conflict do nothing), tehát ez idempotens —
    --    itt csak azért fut, hogy a moderátor NE üres sorral találkozzon.
    v_fill := echo.moderation_fill(p_campaign);

    -- 3) Keverés — CSAK akkor, ha még EGYETLEN döntés sem született.
    --    MIÉRT A FELTÉTEL: az echo.shuffle_moderation() DELETE + INSERT-tel
    --    dolgozik, és az echo.moderation_audit() trigger a nem-'pending'
    --    sorok ÚJRABESZÚRÁSÁT valódi döntésnek látná — hamis előzménysorokat
    --    írna az echo.moderation_history-ba. Friss feltöltésnél ez nem áll fenn.
    select count(*) into v_nonpend
      from echo.moderation m join echo.response r on r.id = m.response_id
     where r.campaign_id = p_campaign and m.allapot <> 'pending';
    if v_nonpend = 0 then
      v_mix := echo.shuffle_moderation(p_campaign);
    else
      v_mix := null;
    end if;

    v_detail := jsonb_build_object(
      'bekuldottnek_jelolt', v_marked, 'erintett_kurzus', v_courses,
      'moderalasi_sor_uj', v_fill, 'moderalasi_sor_kevert', v_mix,
      'mar_moderalt', v_nonpend);
  end if;

  if p_to = 'sealed' then
    -- A PECSÉT. A fizikai sorrend (ctid) mint rejtett csatorna itt bomlik el.
    v_shuf := echo.shuffle_responses(p_campaign);
    v_detail := jsonb_build_object('megkevert_valasz', v_shuf);
  end if;

  -- --- maga a váltás ---
  update echo.campaign
     set state        = p_to,
         sealed_at    = case when p_to = 'sealed'    then coalesce(sealed_at, now())    else sealed_at end,
         published_at = case when p_to = 'published' then coalesce(published_at, now()) else published_at end
   where id = p_campaign;

  insert into echo.campaign_log (campaign_id, from_state, to_state, irany, forced,
                                 actor_key, actor_email, detail)
  values (p_campaign, c.state, p_to, v_irany, v_forced, auth.uid(),
          (select email from public.profiles where id = auth.uid()),
          v_detail || jsonb_build_object('elofeltetel', v_pre));

  perform echo.log_access('echo_campaign_transition', p_campaign, null, null, p_to);

  return jsonb_build_object(
    'id', p_campaign, 'code', c.code, 'from', c.state, 'to', p_to,
    'irany', v_irany, 'forced', v_forced,
    'visszafordithatatlan', (p_to = 'sealed'),
    'detail', v_detail,
    'kovetkezo', echo.campaign_next(p_campaign),
    'ok', true);
end $$;


-- ------------------------------------------------------------
-- 3.3 public.echo_campaign_get(kampány)
-- ------------------------------------------------------------
-- Egy kampány TELJES adminisztratív képe. Válasz-TARTALMAT nem ad vissza —
-- csak darabszámot, arányt és állapotot, akárcsak az echo_campaigns().
drop function if exists public.echo_campaign_get(uuid);
create or replace function public.echo_campaign_get(p_campaign uuid)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c      echo.campaign%rowtype;
  v_out  jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  select * into c from echo.campaign where id = p_campaign;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;

  select jsonb_build_object(
    'id', c.id, 'code', c.code, 'name', c.name_hu, 'name_en', c.name_en,
    'term', c.term, 'state', c.state,
    'opens_at', c.opens_at, 'closes_at', c.closes_at,
    'sealed_at', c.sealed_at, 'published_at', c.published_at,
    'is_open', echo.is_open(c.id),
    'ablak_lejart', (now() >= c.closes_at),

    'template_version_id', c.template_version_id,
    'template', (select jsonb_build_object(
                    'template_id', t.id, 'name_hu', t.name_hu, 'name_en', t.name_en,
                    'version', tv.version, 'state', tv.state,
                    'szakaszok', jsonb_array_length(echo.jarr(tv.compiled->'sections')),
                    'kerdesek', (select count(*) from
                                   jsonb_array_elements(echo.jarr(tv.compiled->'sections')) s
                                   cross join jsonb_array_elements(echo.jarr(s.value->'questions'))))
                   from echo.template_version tv
                   join echo.template t on t.id = tv.template_id
                  where tv.id = c.template_version_id),

    'eligible_courses',  (select count(distinct course_id) from echo.eligibility where campaign_id = c.id),
    'eligible_pairs',    (select count(*) from echo.eligibility where campaign_id = c.id),
    'eligible_students', (select count(*) from echo.participation where campaign_id = c.id and eligible),
    'attempted',         (select count(*) from echo.participation where campaign_id = c.id and attempted),
    'submitted',         (select count(*) from echo.participation where campaign_id = c.id and submitted),
    'responses',         (select count(*) from echo.response where campaign_id = c.id and scope = 'course'),
    'excluded_courses',  (select count(distinct course_id) from echo.exclusion_log
                           where campaign_id = c.id and teacher_id is null),
    'excluded_pairs',    (select count(*) from echo.exclusion_log
                           where campaign_id = c.id and teacher_id is not null),
    'kitoltesi_arany', round(
        (select count(*) from echo.response where campaign_id = c.id and scope='course')::numeric
        / nullif((select count(*) from echo.participation where campaign_id = c.id and eligible), 0) * 100, 1),

    'moderalasra_var', (select count(*) from echo.moderation m
                          join echo.response r on r.id = m.response_id
                         where r.campaign_id = c.id and m.allapot = 'pending'),
    'moderalt',        (select count(*) from echo.moderation m
                          join echo.response r on r.id = m.response_id
                         where r.campaign_id = c.id and m.allapot <> 'pending'),

    -- Mikor lát eredményt ki: a beállításból, nem beégetve.
    'eredmeny_admin_allapotok',  to_jsonb(echo.allowed_states('results_admin_states')),
    'eredmeny_oktato_allapotok', to_jsonb(echo.allowed_states('results_teacher_states')),
    'eredmeny_lathato_adminnak', (c.state = any(echo.allowed_states('results_admin_states'))),
    'eredmeny_lathato_oktatonak',(c.state = any(echo.allowed_states('results_teacher_states'))),

    'kovetkezo', echo.campaign_next(c.id),
    'naplo', (select coalesce(jsonb_agg(jsonb_build_object(
                      'at', l.at, 'from', l.from_state, 'to', l.to_state,
                      'irany', l.irany, 'forced', l.forced,
                      'ki', l.actor_email, 'detail', l.detail) order by l.at desc), '[]'::jsonb)
                from echo.campaign_log l where l.campaign_id = c.id)
  ) into v_out;

  perform echo.log_access('echo_campaign_get', p_campaign, null, null, 'campaign');
  return v_out;
end $$;


-- ============================================================
-- 4. SZAKASZ — GRANTOK
-- ============================================================
-- Ugyanaz a minta, mint a 15. és a 16. szeletben: előbb MINDENKITŐL el,
-- azután célzottan vissza. Az echo sémás objektumok (campaign_log, a belső
-- függvények) zárva maradnak — a kliens csak a public RPC-ket éri el.
do $grants$
declare
  has_anon bool := exists (select 1 from pg_roles where rolname='anon');
  has_auth bool := exists (select 1 from pg_roles where rolname='authenticated');
  has_svc  bool := exists (select 1 from pg_roles where rolname='service_role');
  f text;
begin
  -- 4.1 az új echo sémás objektumok zárva
  foreach f in array array[
    'table echo.campaign_log',
    'function echo.campaign_state_rank(text)',
    'function echo.campaign_seal_guard()',
    'function echo.campaign_precheck(uuid,text)',
    'function echo.campaign_next(uuid)'
  ] loop
    execute format('revoke all on %s from public', f);
    if has_anon then execute format('revoke all on %s from anon', f); end if;
    if has_auth then execute format('revoke all on %s from authenticated', f); end if;
    if has_svc  then execute format('revoke all on %s from service_role', f); end if;
  end loop;

  -- 4.2 a public RPC-k: előbb mindenkitől el
  foreach f in array array[
    'public.echo_campaign_create(text,text,uuid,timestamptz,timestamptz)',
    'public.echo_campaign_transition(uuid,text,boolean)',
    'public.echo_campaign_get(uuid)'
  ] loop
    execute format('revoke all on function %s from public', f);
    if has_anon then execute format('revoke all on function %s from anon', f); end if;
    if has_auth then execute format('revoke all on function %s from authenticated', f); end if;
    if has_svc  then execute format('revoke all on function %s from service_role', f); end if;
  end loop;

  -- 4.3 majd célzottan vissza. MIND 'authenticated' — a tényleges szűrés a
  -- függvény TÖRZSÉBEN van (public.is_admin()), nem a granton: a Supabase
  -- minden bejelentkezett fiókja ugyanaz a Postgres szerepkör.
  if has_auth then
    grant execute on function public.echo_campaign_create(text,text,uuid,timestamptz,timestamptz) to authenticated;
    grant execute on function public.echo_campaign_transition(uuid,text,boolean)                  to authenticated;
    grant execute on function public.echo_campaign_get(uuid)                                      to authenticated;
  end if;

  raise notice 'ECHO 18. szakasz 4: grantok beallitva (anon=%, authenticated=%, service_role=%).',
               has_anon, has_auth, has_svc;
end
$grants$;


-- ============================================================
-- 5. SZAKASZ — ELLENŐRZŐ LEKÉRDEZÉS
-- ============================================================
-- Az "elvart" oszlop mondja meg, mit kellene latni. Ahol rendben = false,
-- ott ne menj tovabb.
with chk(sorrend, ellenorzes, mert, elvart, rendben) as (
  select 1, 'echo_campaign_create letrejott',
         (to_regprocedure('public.echo_campaign_create(text,text,uuid,timestamptz,timestamptz)') is not null)::text,
         'true',
         to_regprocedure('public.echo_campaign_create(text,text,uuid,timestamptz,timestamptz)') is not null
  union all
  select 2, 'echo_campaign_transition letrejott',
         (to_regprocedure('public.echo_campaign_transition(uuid,text,boolean)') is not null)::text,
         'true',
         to_regprocedure('public.echo_campaign_transition(uuid,text,boolean)') is not null
  union all
  select 3, 'echo_campaign_get letrejott',
         (to_regprocedure('public.echo_campaign_get(uuid)') is not null)::text,
         'true',
         to_regprocedure('public.echo_campaign_get(uuid)') is not null
  union all
  select 4, 'echo.campaign_log tabla letezik',
         (select count(*)::text from pg_tables where schemaname='echo' and tablename='campaign_log'),
         '1',
         (select count(*) from pg_tables where schemaname='echo' and tablename='campaign_log') = 1
  union all
  select 5, 'a pecset-orzo trigger fel van rakva',
         (select count(*)::text from pg_trigger
           where tgrelid = 'echo.campaign'::regclass and tgname = 'echo_campaign_seal_guard_trg'),
         '1',
         (select count(*) from pg_trigger
           where tgrelid = 'echo.campaign'::regclass and tgname = 'echo_campaign_seal_guard_trg') = 1
  union all
  select 6, 'sealed_at es published_at oszlop letezik',
         (select count(*)::text from information_schema.columns
           where table_schema='echo' and table_name='campaign'
             and column_name in ('sealed_at','published_at')),
         '2',
         (select count(*) from information_schema.columns
           where table_schema='echo' and table_name='campaign'
             and column_name in ('sealed_at','published_at')) = 2
  union all
  select 7, 'az allapotgep NEM ugorhato at (rank-kulonbseg)',
         (echo.campaign_state_rank('sealed') - echo.campaign_state_rank('draft'))::text,
         '4',
         echo.campaign_state_rank('sealed') - echo.campaign_state_rank('draft') = 4
  union all
  select 8, 'a 3 uj RPC-t az anon NEM hivhatja',
         (select count(*)::text from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
           where n.nspname='public' and p.proname in
                 ('echo_campaign_create','echo_campaign_transition','echo_campaign_get')
             and has_function_privilege('anon', p.oid, 'execute')),
         '0',
         not exists (select 1 from pg_proc p
                       join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname='public' and p.proname in
                            ('echo_campaign_create','echo_campaign_transition','echo_campaign_get')
                        and has_function_privilege('anon', p.oid, 'execute'))
  union all
  select 9, 'a 3 uj RPC-t az authenticated hivhatja',
         (select count(*)::text from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
           where n.nspname='public' and p.proname in
                 ('echo_campaign_create','echo_campaign_transition','echo_campaign_get')
             and has_function_privilege('authenticated', p.oid, 'execute')),
         '3',
         (select count(*) from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
           where n.nspname='public' and p.proname in
                 ('echo_campaign_create','echo_campaign_transition','echo_campaign_get')
             and has_function_privilege('authenticated', p.oid, 'execute')) = 3
  union all
  select 10, 'az echo.campaign_log-ra a kliensnek nincs joga',
         (select count(*)::text from (values ('anon'),('authenticated')) r(rn)
           where has_table_privilege(rn, 'echo.campaign_log', 'select')),
         '0',
         not exists (select 1 from (values ('anon'),('authenticated')) r(rn)
                      where has_table_privilege(rn, 'echo.campaign_log', 'select'))
)
select sorrend, ellenorzes, mert, elvart,
       case when rendben then 'OK' else 'HIBA' end as allapot
  from chk order by sorrend;


-- ############################################################
-- ###  18b_echo_form_seed.sql
-- ############################################################

-- ============================================================
-- 18b_echo_form_seed.sql — A VALÓDI OMHV-KÉRDŐÍV BEEMELÉSE
-- ============================================================
-- Neumann János Egyetem — ECHO (OMHV), 28/2023. (VIII.31.) szenátusi határozat
--
-- MIÉRT VAN EZ A FÁJL
-- -------------------
-- A 15_echo_core.sql 11.5 szakasza egy template_version-t seedel, aminek a
-- SZERKEZETE helyes, de a SZÖVEGEI rekonstrukciók: a seed írásakor a
-- prototípus forrása nem állt rendelkezésre (a saját meta mezője ki is
-- mondja: "forras_megjegyzes": "A kerdesszovegek REKONSTRUKCIOK...").
-- Mérve: a jelenlegi 1. verzió EGYETLEN mondata sem egyezik a prototípuséval.
--
-- Ez a migráció a prototípus FORM_SEED tömbjéből emeli be a VALÓDI kérdőívet:
-- 6 szakasz, 13 kérdés, a teljes opciólistákkal
--   COURSE_STRENGTHS (7), COURSE_IMPROVE (7), T_STRENGTHS (10),
--   T_IMPROVE (12), SKIP_REASONS (4), ATTENDANCE (4).
--
-- FORRÁSHŰSÉG — MI HONNAN VAN
--   • a MAGYAR szövegek: a prototípus FORM_SEED-jéből SZÓ SZERINT, az
--     ékezetekkel és a gondolatjelekkel együtt (a 15-ös seed ékezet nélkül
--     írt, itt nem tesszük — a szenátus által jóváhagyott szöveg pontos alakja
--     a jóváhagyás tárgya);
--   • az ANGOL szövegek: ahol a prototípusban volt en mező, onnan szó szerint;
--     ahol nem volt (az opciók túlnyomó része), ott MIR-FORDÍTÁS, amit
--     jóvá kell hagyatni. A meta.forditas_statusz mező ezt rögzíti.
--     Miért kell mégis kitölteni: az echo.template_validate() az angol
--     fordítás hiányát ÉLESÍTÉS-BLOKKOLÓ hibaként jelzi (hianyzo_angol_opcio),
--     tehát angol szöveg nélkül a verzió nem tud 'live' állapotba menni.
--
-- MIT NEM CSINÁL EZ A FÁJL
--   • NEM írja át a 15_echo_core.sql-t (az a felhasználónál már lefutott);
--   • NEM törli és NEM módosítja az 1. verziót — az 'live' marad, hogy a
--     hozzá kötött, már beérkezett válaszok (mérve: 42 sor) értelmezhetők
--     maradjanak. Élő verzió compiled mezőjét a
--     echo.template_version_guard() trigger amúgy sem engedné átírni;
--   • NEM köti át a futó kampányt. Azt a jóváhagyás után, kézzel kell —
--     lásd a fájl végén a KÉZI LÉPÉSEK szakaszt.
--
-- IDEMPOTENS: újrafuttatva nem hoz létre duplikátumot. Ha a verzió már
-- létezik és még 'draft', a compiled FRISSÜL erre a tartalomra; ha már
-- kilépett a draft állapotból, a fájl hozzá sem nyúl.
--
-- FUTTATÁS: Supabase SQL Editor, egyetlen blokként bemásolva.
-- ============================================================

set search_path = echo, public, extensions, pg_temp;

-- ------------------------------------------------------------
-- 1. ÓRALÁTOGATÁSI SÁVOK — ELŐFELTÉTEL, NEM KOZMETIKA
-- ------------------------------------------------------------
-- MÉRT PROBLÉMA: a prototípus sávjai ('0–32%', '33–59%', '60–84%',
-- '85–100%') NINCSENEK benne az echo.attendance_band szótárban (a szótár ma
-- a 15/16-os seed nyolc kódját tartalmazza, mind ASCII kötőjellel).
-- Az echo.attendance_low() FAIL-CLOSED: ami nincs a szótárban, az
-- ALACSONY óralátogatásnak számít. Ha a sávokat nem vennénk fel, az ÚJ
-- kérdőívvel érkező MINDEN válasz kikerülne a jegyzőkönyvi főstatisztikából
-- (3. § (9)), csendben.
--
-- FIGYELEM A KÖTŐJELRE: a prototípus GONDOLATJELET használ (U+2013, "–"),
-- nem ASCII mínuszt. A code mezőnek BETŰ SZERINT egyeznie kell a kérdőív
-- opciójának value mezőjével, különben a szótár nem talál rá.
-- A küszöb 33% (echo.setting.attendance_min_pct), ezért csak a legalsó sáv
-- számít alacsonynak.
insert into echo.attendance_band (code, name_hu, name_en, low, sort_order) values
  ('0–32%',   '0–32%',   '0–32%',   true,  15),
  ('33–59%',  '33–59%',  '33–59%',  false, 25),
  ('60–84%',  '60–84%',  '60–84%',  false, 35),
  ('85–100%', '85–100%', '85–100%', false, 45)
on conflict (code) do nothing;

-- ------------------------------------------------------------
-- 2. AZ ÚJ KÉRDŐÍV-VERZIÓ
-- ------------------------------------------------------------
-- SZERKEZETI IGAZÍTÁSOK a prototípus FORM_SEED-jéhez képest. Mindegyik azért
-- van, mert a MEGLÉVŐ kód (features/echo.jsx renderelő + 15/16-os RPC-k) így
-- várja. A szöveg egyikben sem változik.
--
--  (a) TÍPUSNEVEK. A renderelő öt típust ismer: single, multi, scale,
--      longtext, skip. A prototípus 'attendance' típusa -> 'single'
--      (a kérdés id-ja marad 'attendance', lásd (b)); a 'text' -> 'longtext'.
--
--  (b) KÉRDÉS-ID-K. Két id KÖTÖTT, nem szabad megváltoztatni:
--        'attendance' — az ECHO_buildPayload() ezt az egy id-t emeli a
--                       payload GYÖKERÉBE (v_att := p_payload->>'attendance');
--        'goals_met'  — az echo_submit() 4. lépése NÉV SZERINT ezt az egy
--                       célteljesülés-mezőt engedi át, minden más cél-adatot
--                       levág. Lásd a 3. pontot.
--      A TÖBBI kérdés ÚJ id-t kap ('_p' utótag = prototípus-szöveg). Ez
--      szándékos: a válaszok answers mezője kérdés-id -> érték leképezés,
--      tehát ha a megváltozott szövegű kérdés MEGTARTANÁ a régi id-t, az
--      1. verzió találgatott kérdésére adott válaszok és a 2. verzió valódi
--      kérdésére adott válaszok EGY kulcsba folynának, és egy hosszmetszeti
--      riport összeadná őket. Ugyanez az indoklás áll a 16_echo_reports.sql
--      echo.compiled_reid() függvénye mögött.
--      MEGJEGYZÉS az 'attendance'-hoz: az id kötött, de a SÁVOK ÉRTÉKEI
--      különböznek (0-25%/26-50%/... vs. 0–32%/33–59%/...), ezért az
--      óralátogatás-eloszlást verziónként kell nézni, nem összevonva.
--
--  (c) A KIHAGYÁS-KAPU. A prototípusban a "Biztos nem akarod értékelni?"
--      kérdés a lista UTÁN áll, cond: {qid:'q8', val:'__skip__'}. A meglévő
--      renderelőben a 'skip' típus maga A KAPU (ECHO_QSkip): alapból nincs
--      bejelölve semmi, és ha a hallgató bejelöli, akkor kér indokot. Ezért
--      itt ELÖL áll, cond nélkül, a két lista pedig
--      cond: {"teacher_skip_p": null} feltétellel jelenik meg — ez a
--      prototípus logikájának pontos megfelelője a meglévő kódban.
--      A prototípus required:true-ját ezért nem vesszük át: a kapu
--      kikapcsolt állapota az alapértelmezés, nem hiányzó válasz.
--
--  (d) SKÁLÁK. A prototípus {min:'Rossznak', max:'Kiemelkedőnek', points:7}
--      alakot használ (min/max = FELIRAT). A meglévő ECHO_QScale a min/max-ot
--      SZÁMKÉNT olvassa, a feliratot a min_hu/max_hu/min_en/max_en mezőkből.
--      A prototípus feliratai ezért a *_hu mezőkbe kerülnek, a min/max pedig
--      1 és a points értéke lesz. A szöveg nem változik.
--
--  (e) SZÖVEGES MEZŐK max ÉRTÉKE. A prototípusban a text kérdések max:1-et
--      írnak (= egy válasz). A renderelőben a longtext max a KARAKTERKORLÁT,
--      ezért itt 1500 áll, a 15-ös seeddel egyezően. Ha 1 maradna, a
--      hallgató egyetlen karaktert tudna beírni.
--
--  (f) OPCIÓ-ÉRTÉKEK. A value MINDENÜTT a magyar szöveg (a prototípus
--      opt(hu,en) helpere is így viselkedik: value = hu), kivéve a
--      célteljesülést és az "Igen/Nem" kérdést, ahol slug áll — előbbinél
--      azért, mert az echo_submit() CHECK-je nevesített értékeket vár
--      ('nem_teljesult','reszben','teljesult','tulteljesult'), utóbbinál
--      azért, mert egy kétértékű jelző riportban slugként olvasható.
--
--  (g) SZAKASZ-BEVEZETŐK. A prototípus EVAL_STEPS tömbjének lead szövegeit
--      lead_hu/lead_en mezőben hozzuk. A mai renderelő ezeket MÉG NEM
--      rajzolja ki — a mező azért van itt, hogy a jóváhagyandó tartalom
--      egyben legyen, és a felület később hozzájuk tudjon nyúlni.

--  (h) A CÉLKÉRDÉS FELTÉTELE. A prototípusban a célkérdés required:true és
--      nincs cond-ja. A 15-ös seed rekonstrukciója ide egy
--      cond: {"has_goals": true} feltételt tett. MÉRVE: az
--      echo.template_validate() ezt 'kotelezo_feltetel_mogott' kóddal
--      ÉLESÍTÉS-BLOKKOLÓ hibának jelzi (kötelező kérdés megjelenítési
--      feltétel mögött), tehát a verzió a feltétellel nem tudna 'live'
--      állapotba menni. A feltétel amúgy is felesleges: a repeat:"goal"
--      MAGA a kapu — az ECHO_buildSteps() célonként bont, tehát ha a
--      hallgatónak nincs célja, a lépés meg sem születik. Ezért itt
--      cond: null áll, required: true mellett — a prototípussal egyezően.
--

do $mig$
declare
  v_tpl uuid := 'e3000000-0000-4000-8000-000000000001';   -- OMHV-ALAP (15-ös seed)
  v_id  uuid := 'e3000000-0000-4000-8000-000000000003';   -- EZ a verzió, fix id
  v_ver integer;
  v_state text;
  v_compiled jsonb;
begin
  if not exists (select 1 from echo.template where id = v_tpl) then
    raise exception '18b: nincs meg az OMHV-ALAP sablon (%). Eloszor a 15_echo_core.sql-t kell lefuttatni.', v_tpl;
  end if;

  v_compiled := $json$
{
  "meta": {
    "code": "OMHV-ALAP",
    "version": 2,
    "title_hu": "Oktatói munka hallgatói véleményezése",
    "title_en": "Student evaluation of teaching",
    "legal_hu": "28/2023. (VIII.31.) szenátusi határozat",
    "forras": "ECHO prototípus, FORM_SEED — a magyar szövegek szó szerint innen valók.",
    "forditas_statusz": "Az angol szövegek egy része MIR-fordítás, jóváhagyásra vár. Ahol a prototípusban is volt en mező, ott az szerepel.",
    "elozmeny": "Az 1. verzió szövegei rekonstrukciók voltak; ez a verzió váltja ki. Az 1. verzió NEM törölhető, mert a hozzá kötött válaszok arra hivatkoznak."
  },
  "parts": [
    { "id": "part1", "hu": "Célmeghatározás (félév eleje)", "en": "Goal setting (start of term)" },
    { "id": "part2", "hu": "Értékelés (félév vége)",        "en": "Evaluation (end of term)" }
  ],
  "sections": [
    {
      "id": "s1", "part": "part2", "audience": [],
      "hu": "Bevezetés", "en": "Introduction",
      "lead_hu": "Egy kérdés arról, mennyit voltál jelen — ez dönti el, hogyan számít be a véleményed.",
      "lead_en": "One question about how much you attended — this decides how your opinion counts.",
      "questions": [
        { "id": "attendance", "type": "single",
          "hu": "Az órák hány százalékán vettél részt ezen a kurzuson?",
          "en": "What share of the classes did you attend?",
          "help": { "hu": "Önbevallás. 33% alatt a véleményed csak tájékoztató jellegű — 3. § (9).",
                    "en": "Self-declared. Below 33% the response is indicative only." },
          "options": [
            { "value": "0–32%",   "hu": "0–32%",   "en": "0–32%" },
            { "value": "33–59%",  "hu": "33–59%",  "en": "33–59%" },
            { "value": "60–84%",  "hu": "60–84%",  "en": "60–84%" },
            { "value": "85–100%", "hu": "85–100%", "en": "85–100%" }
          ],
          "required": true, "moderated": false, "randomize": false, "allowOther": false,
          "max": 1, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    },
    {
      "id": "s2", "part": "part2", "audience": [],
      "hu": "Célok teljesülése", "en": "Goal fulfilment",
      "lead_hu": "A félév elején ezeket fogalmaztad meg. Értékeld, mennyire teljesültek.",
      "lead_en": "You set these at the start of the term. Rate how far they were met.",
      "questions": [
        { "id": "goals_met", "type": "single",
          "hu": "Értékeld a korábban megfogalmazott célodat!",
          "en": "Rate the goal you set earlier.",
          "help": { "hu": "A félév elején megadott saját célok és oktatói elvárások egyenként jelennek meg.",
                    "en": "The goals and expectations you set at the start of term appear one by one." },
          "options": [
            { "value": "nem_teljesult", "hu": "Nem teljesült",     "en": "Not achieved" },
            { "value": "reszben",       "hu": "Részben teljesült", "en": "Partly achieved" },
            { "value": "teljesult",     "hu": "Teljesült",         "en": "Achieved" }
          ],
          "required": true, "moderated": false, "randomize": false, "allowOther": false,
          "max": 1, "repeat": "goal", "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    },
    {
      "id": "s3", "part": "part2", "audience": [],
      "hu": "Szöveges élmények", "en": "Open feedback",
      "lead_hu": "Két szabad kérdés — ezek a legértékesebb visszajelzések az oktatónak.",
      "lead_en": "Two open questions — these are the most valuable feedback for the teacher.",
      "questions": [
        { "id": "exp_positive_p", "type": "longtext",
          "hu": "Mi volt a kurzuson a legpozitívabb élményed?",
          "en": "What was your most positive experience?",
          "help": null, "options": null,
          "required": false, "moderated": true, "randomize": false, "allowOther": false,
          "max": 1500, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "exp_negative_p", "type": "longtext",
          "hu": "Mi volt a kurzuson a legzavaróbb élményed?",
          "en": "What was the most disturbing experience on the course?",
          "help": { "hu": "Személyre, magánéletre, meggyőződésre vonatkozó megjegyzés érvénytelen — 3. § (10).",
                    "en": "Remarks about a person, private life or beliefs are invalid — Art. 3 (10)." },
          "options": null,
          "required": false, "moderated": true, "randomize": false, "allowOther": false,
          "max": 1500, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    },
    {
      "id": "s4", "part": "part2", "audience": [],
      "hu": "Kurzus értékelése", "en": "Course evaluation",
      "lead_hu": "Erősségek és fejlődési lehetőségek, legfeljebb két-két állítás.",
      "lead_en": "Strengths and areas to improve, at most two statements each.",
      "questions": [
        { "id": "req_changed_p", "type": "single",
          "hu": "A félév elején meghatározott teljesítési követelmények a félév során változtak?",
          "en": "Did the course requirements change during the term?",
          "help": null,
          "options": [
            { "value": "igen", "hu": "Igen", "en": "Yes" },
            { "value": "nem",  "hu": "Nem",  "en": "No" }
          ],
          "required": true, "moderated": false, "randomize": false, "allowOther": false,
          "max": 1, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "course_strengths_p", "type": "multi",
          "hu": "Szerinted mik voltak a kurzus erősségei?",
          "en": "What were the strengths of the course?",
          "help": null,
          "options": [
            { "value": "A kurzuson elvárt munka nagyban hozzájárult a szakmai fejlődésemhez",
              "hu": "A kurzuson elvárt munka nagyban hozzájárult a szakmai fejlődésemhez",
              "en": "The work required on the course contributed greatly to my professional development" },
            { "value": "Sok új dolgot tudtam megtanulni a kurzus során",
              "hu": "Sok új dolgot tudtam megtanulni a kurzus során",
              "en": "I was able to learn a lot of new things during the course" },
            { "value": "Rendszeresen volt alkalom csoportmunkára",
              "hu": "Rendszeresen volt alkalom csoportmunkára",
              "en": "There were regular opportunities for group work" },
            { "value": "A kurzuson végzett tevékenységek sokszínűek voltak",
              "hu": "A kurzuson végzett tevékenységek sokszínűek voltak",
              "en": "The activities on the course were varied" },
            { "value": "Az eszközök és nyersanyagok elérhetőek voltak",
              "hu": "Az eszközök és nyersanyagok elérhetőek voltak",
              "en": "The tools and materials were available" },
            { "value": "Egyéb", "hu": "Egyéb", "en": "Other" },
            { "value": "A kurzusnak nem volt erőssége",
              "hu": "A kurzusnak nem volt erőssége",
              "en": "The course had no strengths" }
          ],
          "required": false, "moderated": false, "randomize": true, "allowOther": true,
          "max": 2, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "course_improve_p", "type": "multi",
          "hu": "Szerinted miben fejlődhetne a kurzus?",
          "en": "In what way could the course improve?",
          "help": null,
          "options": [
            { "value": "A kurzuson elvárt munka jobban hozzájárulhatna a szakmai fejlődésemhez",
              "hu": "A kurzuson elvárt munka jobban hozzájárulhatna a szakmai fejlődésemhez",
              "en": "The work required on the course could contribute more to my professional development" },
            { "value": "A kurzus során több új információt lehetne megtanulni",
              "hu": "A kurzus során több új információt lehetne megtanulni",
              "en": "More new information could be learned during the course" },
            { "value": "Lehetne több alkalom a csoportmunkára",
              "hu": "Lehetne több alkalom a csoportmunkára",
              "en": "There could be more opportunities for group work" },
            { "value": "A kurzuson végzett tevékenységek lehetnének sokszínűbbek",
              "hu": "A kurzuson végzett tevékenységek lehetnének sokszínűbbek",
              "en": "The activities on the course could be more varied" },
            { "value": "Az eszközöknek és nyersanyagoknak elérhetőbbnek kellene lennie",
              "hu": "Az eszközöknek és nyersanyagoknak elérhetőbbnek kellene lennie",
              "en": "The tools and materials should be more available" },
            { "value": "Egyéb", "hu": "Egyéb", "en": "Other" },
            { "value": "A kurzus nem tud miben fejlődni; így jó, ahogy van",
              "hu": "A kurzus nem tud miben fejlődni; így jó, ahogy van",
              "en": "There is nothing to improve; the course is good as it is" }
          ],
          "required": false, "moderated": false, "randomize": true, "allowOther": true,
          "max": 2, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    },
    {
      "id": "s5", "part": "part2", "audience": [],
      "hu": "Oktató értékelése", "en": "Teacher evaluation",
      "lead_hu": "Oktatónként külön, legfeljebb öt-öt állítás.",
      "lead_en": "Separately for each teacher, at most five statements each.",
      "questions": [
        { "id": "teacher_skip_p", "type": "skip",
          "hu": "Biztos nem akarod értékelni az oktatót?",
          "en": "Are you sure you do not want to evaluate this teacher?",
          "help": { "hu": "Csak akkor jelenik meg, ha a hallgató kihagyja az oktató értékelését. A kihagyás oka minőségjelzés.",
                    "en": "Shown only if the student skips the teacher. The reason for skipping is a quality signal." },
          "options": [
            { "value": "Igen, mert nem jártam be",            "hu": "Igen, mert nem jártam be",            "en": "Yes, because I did not attend" },
            { "value": "Igen, de nem akarom elmondani miért", "hu": "Igen, de nem akarom elmondani miért", "en": "Yes, but I do not want to say why" },
            { "value": "Igen, mert nem is tanított",          "hu": "Igen, mert nem is tanított",          "en": "Yes, because they did not teach me" },
            { "value": "Igen, és leírom miért",               "hu": "Igen, és leírom miért",               "en": "Yes, and I will write why" }
          ],
          "required": false, "moderated": false, "randomize": false, "allowOther": true,
          "max": 1, "repeat": "teacher", "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "teacher_strengths_p", "type": "multi",
          "hu": "Mik voltak leginkább [Oktató neve] erősségei?",
          "en": "What were the main strengths of [Teacher name]?",
          "help": { "hu": "Legfeljebb öt állítás jelölhető, oktatónként külön.",
                    "en": "At most five statements, separately for each teacher." },
          "options": [
            { "value": "Felkészülten tartotta meg az órát", "hu": "Felkészülten tartotta meg az órát", "en": "Came to class prepared" },
            { "value": "Tartotta magát a megállapodottakhoz", "hu": "Tartotta magát a megállapodottakhoz", "en": "Kept to what was agreed" },
            { "value": "Elmélyítette a meglévő érdeklődésemet", "hu": "Elmélyítette a meglévő érdeklődésemet", "en": "Deepened my existing interest" },
            { "value": "Bevonta a hallgatókat", "hu": "Bevonta a hallgatókat", "en": "Involved the students" },
            { "value": "Az órákat mindig megtartotta", "hu": "Az órákat mindig megtartotta", "en": "Always held the classes" },
            { "value": "Lelkiismeretes volt a hallgatókhoz való hozzáállásában", "hu": "Lelkiismeretes volt a hallgatókhoz való hozzáállásában", "en": "Was conscientious in their attitude towards students" },
            { "value": "Rendelkezésre állt a tanórán kívül is", "hu": "Rendelkezésre állt a tanórán kívül is", "en": "Was available outside class as well" },
            { "value": "Segítőkész volt problémák és kérdések esetén", "hu": "Segítőkész volt problémák és kérdések esetén", "en": "Was helpful with problems and questions" },
            { "value": "Jó segédanyagokat adott", "hu": "Jó segédanyagokat adott", "en": "Provided good learning materials" },
            { "value": "Rendszeresen adott visszajelzést", "hu": "Rendszeresen adott visszajelzést", "en": "Gave feedback regularly" }
          ],
          "required": false, "moderated": false, "randomize": true, "allowOther": false,
          "max": 5, "repeat": "teacher", "cond": { "teacher_skip_p": null }, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "teacher_improve_p", "type": "multi",
          "hu": "Miben kellene leginkább fejlődnie [Oktató neve]-nek?",
          "en": "In what way should [Teacher name] improve most?",
          "help": null,
          "options": [
            { "value": "Jobban fel kéne készülnie az órákra", "hu": "Jobban fel kéne készülnie az órákra", "en": "Should prepare better for classes" },
            { "value": "Jobban kéne tartania magát a megállapodottakhoz", "hu": "Jobban kéne tartania magát a megállapodottakhoz", "en": "Should keep better to what was agreed" },
            { "value": "Jobban kéne bevonnia a hallgatókat", "hu": "Jobban kéne bevonnia a hallgatókat", "en": "Should involve the students more" },
            { "value": "Az órákat mindig tartsa meg", "hu": "Az órákat mindig tartsa meg", "en": "Should always hold the classes" },
            { "value": "Lelkiismeretesebbnek kellene lennie a hallgatókhoz való hozzáállásában", "hu": "Lelkiismeretesebbnek kellene lennie a hallgatókhoz való hozzáállásában", "en": "Should be more conscientious in their attitude towards students" },
            { "value": "Jobban rendelkezésre kellene állnia a tanórán kívül", "hu": "Jobban rendelkezésre kellene állnia a tanórán kívül", "en": "Should be more available outside class" },
            { "value": "Segítőkészebbnek kellene lennie problémák esetén", "hu": "Segítőkészebbnek kellene lennie problémák esetén", "en": "Should be more helpful with problems" },
            { "value": "Alaposabban kellene végig kísérnie a tanulási folyamatomat", "hu": "Alaposabban kellene végig kísérnie a tanulási folyamatomat", "en": "Should follow my learning process more thoroughly" },
            { "value": "Jobb segédanyagokra van szükség", "hu": "Jobb segédanyagokra van szükség", "en": "Better learning materials are needed" },
            { "value": "Többször kellene visszajelzést adnia", "hu": "Többször kellene visszajelzést adnia", "en": "Should give feedback more often" },
            { "value": "A hallgatókkal egyenlőbben kellene bánnia", "hu": "A hallgatókkal egyenlőbben kellene bánnia", "en": "Should treat students more equally" },
            { "value": "Az oktató nem tud miben fejlődni; így jó, ahogy van", "hu": "Az oktató nem tud miben fejlődni; így jó, ahogy van", "en": "There is nothing to improve; the teacher is good as they are" }
          ],
          "required": false, "moderated": false, "randomize": true, "allowOther": false,
          "max": 5, "repeat": "teacher", "cond": { "teacher_skip_p": null }, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    },
    {
      "id": "s6", "part": "part2", "audience": [],
      "hu": "Zárás", "en": "Closing",
      "lead_hu": "Összegzés a kurzusról és a visszajelzés hatásáról.",
      "lead_en": "A summary of the course and of the impact of your feedback.",
      "questions": [
        { "id": "overall_course_p", "type": "scale",
          "hu": "Összességében milyennek értékeled a kurzust?",
          "en": "Overall, how do you rate the course?",
          "help": { "hu": "A jegyzőkönyv része — 6. § (5).", "en": "Part of the official report — Art. 6 (5)." },
          "options": null,
          "required": true, "moderated": false, "randomize": false, "allowOther": false,
          "max": 1, "repeat": null, "cond": null,
          "scale": { "min": 1, "max": 7, "points": 7,
                     "min_hu": "Rossznak", "max_hu": "Kiemelkedőnek",
                     "min_en": "Poor",     "max_en": "Outstanding" },
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "course_summary_p", "type": "longtext",
          "hu": "Kérjük összegezd, hogy milyen élmény volt számodra a kurzus!",
          "en": "Please summarise what the course was like for you.",
          "help": null, "options": null,
          "required": false, "moderated": true, "randomize": false, "allowOther": false,
          "max": 1500, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "feedback_impact_p", "type": "scale",
          "hu": "Mennyire érzed, hogy a visszajelzésed hatására változni fognak a dolgok?",
          "en": "How much do you feel that things will change as a result of your feedback?",
          "help": null, "options": null,
          "required": false, "moderated": false, "randomize": false, "allowOther": false,
          "max": 1, "repeat": null, "cond": null,
          "scale": { "min": 1, "max": 5, "points": 5,
                     "min_hu": "Nem lesz hatása", "max_hu": "Lesz változás",
                     "min_en": "It will have no effect", "max_en": "There will be change" },
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    }
  ]
}
  $json$::jsonb;

  select state into v_state from echo.template_version where id = v_id;

  if v_state is null then
    -- Uj verzio. A sorszam a sablon eddigi legnagyobb verziojanal eggyel nagyobb,
    -- igy akkor sem utkozik, ha idokozben mas is keszitett verziot.
    select coalesce(max(version), 0) + 1 into v_ver
      from echo.template_version where template_id = v_tpl;

    insert into echo.template_version (id, template_id, version, state, compiled, notes)
    values (v_id, v_tpl, v_ver, 'draft', v_compiled,
            'A prototipus FORM_SEED valodi szovegei (18b_echo_form_seed.sql). '
            'Az angol forditas egy resze MIR-forditas, jovahagyasra var.');
    raise notice '18b: uj kerdoiv-verzio letrehozva, sorszam=%, allapot=draft, id=%', v_ver, v_id;

  elsif v_state = 'draft' then
    -- Idempotencia: mar letezik es meg piszkozat -> a tartalmat frissitjuk.
    update echo.template_version
       set compiled = v_compiled
     where id = v_id;
    raise notice '18b: a mar letezo % verzio (draft) compiled mezoje frissitve.', v_id;

  else
    -- Mar tullepett a piszkozaton (review/approved/live/closed) -> nem nyulunk hozza.
    raise notice '18b: a % verzio mar % allapotban van, a fajl nem modositja. '
                 'Ha uj szoveg kell, keszits kovetkezo verziot az echo_template_create() RPC-vel.',
                 v_id, v_state;
  end if;
end $mig$;

-- ------------------------------------------------------------
-- 3. MIÉRT NEM CÉLONKÉNT MEGY ÁT A CÉLTELJESÜLÉS
-- ------------------------------------------------------------
-- A goals_met kérdés repeat:"goal", tehát a KITÖLTŐBEN célonként külön sorban
-- jelenik meg (features/echo.jsx, ECHO_buildSteps). A BEKÜLDÖTT payloadba
-- viszont csak EGY összesített érték kerül, a course.goals_met kulcson.
--
-- Ez nem hiányosság, hanem a séma szándéka. Az echo_submit() 4. lépése
-- név szerint levágja a 'goals', 'goal_texts', 'goal_count', 'goals_count',
-- 'expectations', 'expectation_texts' kulcsokat, és a goals_met-en kívül
-- semmilyen cél-adatot nem enged be. Az ok a 15_echo_core.sql 1099. sora
-- körül áll: a célok SZÁMOSSÁGA kvázi-azonosító — az echo.student_goal
-- táblából (ami a hallgatóhoz van kötve) látszik, ki hány célt írt, tehát
-- egy "3 elemű célteljesülés-tömb" a névtelen válaszsoron leszűkítené a
-- lehetséges kitöltők körét. A szövegük még beszédesebb lenne.
--
-- Az összevonás szabálya (a kitöltőben, ECHO_buildPayload):
--   minden cél teljesült                  -> 'teljesult'
--   egy sem teljesült és nincs "részben"   -> 'nem_teljesult'
--   minden más (vegyes vagy részben)       -> 'reszben'
-- A 'tulteljesult' értéket a séma megengedi, de ez a kérdőív nem használja.

-- ------------------------------------------------------------
-- 4. ELLENŐRZÉS — ez a lekérdezés fut le a migráció végén
-- ------------------------------------------------------------
select tv.version,
       tv.state,
       jsonb_array_length(tv.compiled->'sections')                              as szakasz,
       (select count(*) from jsonb_array_elements(tv.compiled->'sections') s,
                             jsonb_array_elements(s.value->'questions') q)      as kerdes,
       jsonb_array_length(echo.template_validate(tv.compiled))                  as validator_talalat,
       echo.template_validate(tv.compiled)                                      as validator_reszletek
  from echo.template_version tv
 where tv.id = 'e3000000-0000-4000-8000-000000000003';

-- ============================================================
-- KÉZI LÉPÉSEK A MIGRÁCIÓ UTÁN — EZEKET A FÁJL SZÁNDÉKOSAN NEM TESZI MEG
-- ============================================================
-- 1) ÁTNÉZÉS A SZERKESZTŐBEN. ECHO -> Kérdőívek -> "OMHV alapkerdoiv (28/2023.)"
--    -> a most létrejött piszkozat verzió. Ellenőrizendő:
--       • a magyar szövegek egyeznek-e a szenátus által jóváhagyott alakkal;
--       • az ANGOL fordítások elfogadhatók-e (a fenti FORRÁSHŰSÉG szakasz
--         szerint egy részük MIR-fordítás).
--    A validátor eredményét a 4. pont lekérdezése is kiírja; élesítéshez
--    ÜRESNEK kell lennie (echo_template_transition ezt ellenőrzi).
--
-- 2) ÉLESÍTÉS. A szerkesztőből, vagy RPC-vel (admin munkamenetben):
--       select public.echo_template_validate('e3000000-0000-4000-8000-000000000003');
--       select public.echo_template_transition('e3000000-0000-4000-8000-000000000003', 'review');
--       select public.echo_template_transition('e3000000-0000-4000-8000-000000000003', 'approved');
--       select public.echo_template_transition('e3000000-0000-4000-8000-000000000003', 'live');
--
-- 3) A KAMPÁNY HOZZÁKÖTÉSE. KÉT ÚT VAN, és a választás nem technikai kérdés:
--
--    (a) ÚJ KAMPÁNY az új verzióval — EZ AZ AJÁNLOTT.
--        A már beérkezett válaszok az 1. verzióra hivatkoznak; ha a futó
--        kampányt átkötnénk, ugyanabban a kampányban kétféle kérdőívre adott
--        válasz keveredne, és a jegyzőkönyv nem lenne egységes.
--        (A kampánylétrehozó RPC a 18a_echo_campaign.sql-ben készül.)
--
--    (b) A FUTÓ DEMÓ KAMPÁNY ÁTKÖTÉSE — csak demó/teszt adatnál.
--        Éles kampányon NE. Kikommentelve, tudatos döntés után futtatandó:
--
--        -- update echo.campaign
--        --    set template_version_id = 'e3000000-0000-4000-8000-000000000003'
--        --  where id = 'e4000000-0000-4000-8000-000000000001'
--        --    and state in ('draft','open');
--
--        Ha ezt választod, a régi válaszok template_version_id-je NEM változik
--        (a response tábla a saját verzióját őrzi) — ez helyes, de azt jelenti,
--        hogy a kampány riportjait verziónként bontva kell nézni.
--
-- 4) AZ 1. VERZIÓ SORSA. Hagyd 'live' vagy tedd 'closed' állapotba, de NE
--    töröld: a echo.response.template_version_id idegen kulcs on delete
--    restrict, tehát a törlés amúgy is elbukna.
-- ============================================================


-- ############################################################
-- ###  18c_echo_form_activate.sql
-- ############################################################

-- ============================================================
-- 18c_echo_form_activate.sql — A VALÓDI KÉRDŐÍV ÉLESÍTÉSE ÉS AZ ÚJ KAMPÁNY
-- ============================================================
-- Neumann János Egyetem — ECHO (OMHV), 28/2023. (VIII.31.) szenátusi határozat
--
-- MIÉRT VAN EZ A FÁJL
-- -------------------
-- MÉRT PROBLÉMA: a 18b_echo_form_seed.sql a prototípus VALÓDI kérdőívét a
-- 2. verzióba írja, de azt szándékosan 'draft' állapotban hagyja, a futó
-- kampány pedig változatlanul az 1. verzióra — a REKONSTRUÁLT, találgatással
-- készült szövegekre — mutat. (Az 1. verzió saját meta mezője ki is mondja:
-- "forras_megjegyzes": "A kerdesszovegek REKONSTRUKCIOK...".)
-- Ebből az következik, hogy a 18 + 18b + 19 lefuttatása UTÁN a hallgató
-- TOVÁBBRA IS a rekonstruált kérdőívet kapja. Mérve: a repeat='goal'
-- (célonként ismétlődő) kérdésből az 1. verzióban 0 db van, a 2. verzióban
-- 1 db — vagyis a célonkénti célteljesülés (0.3 tétel) sem jelenne meg.
--
-- Ez a fájl azt a KÉZI lépéssort végzi el, ami eddig a 18b fájl végén
-- prózában állt: érvényesít, élesít, és átviszi a rendszert az új kérdőívre.
--
-- ================== MIT VÁLTOZTAT ÉLESBEN — OLVASD EL ==================
--  (1) A 2. kérdőív-verzió (a valódi szövegek) 'live' lesz. Az állapotlánc
--      draft -> review -> approved -> live, egyesével. A 'review' lépés NEM
--      hagyható ki: a draft->approved ugrás az echo.template_version_freeze()
--      triggerbe ütközik ("tiltott allapotatmenet: draft -> approved").
--  (2) Az 1. verzió automatikusan 'closed' lesz — egy sablonnak egyszerre
--      egy élő verziója lehet. Ez VÉGLEGES: a echo.template_version_guard()
--      szerint "lezart (closed) kerdoiv-verzio nem nyithato ujra". A már
--      beérkezett válaszok az 1. verzióra hivatkoznak és értelmezhetők
--      maradnak (a response tábla a saját verzióját őrzi).
--  (3) A félév FUTÓ kampánya lezáródik és LEPECSÉTELŐDIK (open -> closed ->
--      processing -> sealed). Ez is VÉGLEGES: a echo.campaign_seal_guard()
--      trigger a pecsét után minden visszalépést tilt. Lefut a
--      echo.shuffle_responses() is, tehát a válaszok fizikai sorrendje
--      elbomlik — ez a pecsét lényege, nem mellékhatás.
--      MIÉRT KELL: egy félévre EGY aktív kampány lehet
--      (echo_campaign_active_term_uidx + ECHO_TERM_BUSY), tehát az új
--      kampány csak a régi lezárása után jöhet létre.
--  (4) Új kampány jön létre a 2. verzióval, felépül a jogosultsági lista
--      (echo.eligibility_rebuild), és a kampány MEGNYÍLIK.
--
-- MIÉRT ÚJ KAMPÁNY ÉS NEM A RÉGI ÁTKÖTÉSE: a echo.results_build() a KAMPÁNY
-- sablonverziójából veszi a kérdéslistát, a válaszsor viszont a SAJÁT
-- verzióját őrzi. Ha a futó kampányt kötnénk át, a régi (1. verziós)
-- válaszokat a 2. verzió kérdés-ID-jeivel keresné — minden kérdésre n=0
-- jönne ki. Egy kampány = egy kérdőív-verzió.
--
-- MIT NEM TESZ MEG
--   • nem tesz közzé (sealed -> published): a közzététel a moderálási sor
--     kiürítése után, a felületről, tudatos döntéssel történjen;
--   • nem töröl semmit;
--   • nem nyúl a k-küszöbökhöz, a grantokhoz és a szerepkörökhöz.
--
-- HA MÉGSEM AKAROD: ne futtasd le ezt a fájlt. A 18 + 18b + 19 magában is
-- konzisztens állapotot hagy — csak a valódi kérdőív marad piszkozatban.
-- Visszaút ELLENBEN NINCS: a lezárt verzió és a lepecsételt kampány végleges.
--
-- MI MARAD EMBERI FELADAT: a 18b MIR-fordításai (az angol opciószövegek
-- nagy része gépi fordítás) jóváhagyást igényelnek. Ha változtatni kell
-- rajtuk, az echo_template_create() RPC-vel készül 3. verzió — a
-- 2. verzió compiled mezője élesben már nem írható.
--
-- FÜGG: 18a_echo_campaign.sql (állapotgép), 18b_echo_form_seed.sql (a verzió).
-- IDEMPOTENS: újrafuttatva nem hoz létre második kampányt és nem lép
-- állapotot. A második futás mindent NOTICE-szal átlép.
-- FUTTATÁS: Supabase SQL Editor, egyetlen blokként bemásolva.
-- ============================================================

set search_path = echo, public, extensions, pg_temp;

do $mig$
declare
  v_ver      uuid := 'e3000000-0000-4000-8000-000000000003';  -- a 18b 2. verziója
  v_tpl      uuid;
  v_state    text;
  v_check    jsonb;
  v_term     text;
  v_camp     uuid;
  v_code     text;
  v_base     text;
  v_n        int := 1;
  v_new      uuid;
  v_old      record;
  v_step     text;
  v_rank     int;
  v_target   int;
  v_marked   int;
  v_courses  int;
  v_fill     int;
  v_mix      int;
  v_nonpend  int;
  v_shuf     int;
  v_elig     int;
  v_closed   int;
  v_actor    text := 'migracio/18c_echo_form_activate.sql';
begin
  -- ----------------------------------------------------------
  -- 0. ELŐFELTÉTEL: létezik-e egyáltalán a 2. verzió
  -- ----------------------------------------------------------
  select tv.state, tv.template_id into v_state, v_tpl
    from echo.template_version tv where tv.id = v_ver;
  if v_state is null then
    raise notice '18c: a % verzio nem letezik. Futtasd le eloszor a 18b_echo_form_seed.sql-t. '
                 'A fajl nem valtoztat semmit.', v_ver;
    return;
  end if;

  if v_state = 'closed' then
    raise notice '18c: a % verzio mar "closed" allapotu — lezart verzio nem nyithato ujra. '
                 'A fajl nem valtoztat semmit. Uj szoveghez keszits uj verziot '
                 '(echo_template_create).', v_ver;
    return;
  end if;

  -- ----------------------------------------------------------
  -- 1. ÉRVÉNYESÍTÉS — MINDEN MÁS ELŐTT
  -- ----------------------------------------------------------
  -- Azért itt, a legelején: a 3. lépés (a régi kampány lepecsételése)
  -- VISSZAFORDÍTHATATLAN. Ha az élesítés a validátoron bukna el, a régi
  -- kampányt már hiába pecsételtük volna le. Ez a sorrend a garancia.
  select echo.template_validate(tv.compiled) into v_check
    from echo.template_version tv where tv.id = v_ver;
  if jsonb_array_length(v_check) > 0 then
    raise exception 'ECHO_VALIDATION_FAILED: % ellenorzesi hiba a % verzion, elesites nem '
                    'engedelyezett. Elso: %. Teljes lista: %',
      jsonb_array_length(v_check), v_ver, v_check->0->>'uzenet', v_check;
  end if;

  -- ----------------------------------------------------------
  -- 2. VAN-E MÁR KAMPÁNY A 2. VERZIÓRA — az idempotencia horgonya
  -- ----------------------------------------------------------
  select c.id, c.code into v_new, v_code
    from echo.campaign c where c.template_version_id = v_ver
   order by c.created_at limit 1;

  -- A cél-félév: annak a kampánynak a féléve, amelyiket leváltjuk; ha nincs
  -- ilyen, akkor a kurzusok legnepesebb feleve (az eligibility_rebuild
  -- amugy is a felevre szurve gyujt).
  if v_new is not null then
    select c.term into v_term from echo.campaign c where c.id = v_new;
  else
    select c.term into v_term
      from echo.campaign c
     where c.state in ('draft','open','closed','processing')
     order by c.created_at limit 1;
  end if;
  if v_term is null then
    select k.term into v_term from echo.course k
     group by k.term order by count(*) desc, k.term limit 1;
  end if;
  if v_term is null then
    raise notice '18c: nincs egyetlen kurzus sem, igy nincs mihez felevet rendelni. '
                 'A fajl nem hoz letre kampanyt.';
  end if;

  -- ----------------------------------------------------------
  -- 3. A RÉGI, AKTÍV KAMPÁNYOK NYUGDÍJAZÁSA — csak ha új kell
  -- ----------------------------------------------------------
  -- Egyesével lépünk, ugyanazokkal a mellékhatásokkal, amiket a
  -- public.echo_campaign_transition() futtat. Azért nem az RPC-t hívjuk:
  -- az SQL Editor postgres jogon fut, ott auth.uid() NULL, tehát az RPC
  -- ECHO_NOT_AUTHENTICATED-del elhasalna. A TRIGGEREK viszont a
  -- tulajdonosra is vonatkoznak, tehát az állapotgép védelme itt is él.
  if v_new is null and v_term is not null then
    for v_old in
      select c.* from echo.campaign c
       where c.term = v_term
         and c.state in ('draft','open','closed','processing')
       order by c.created_at
    loop
      raise notice '18c: a(z) % kampany nyugdijazasa (% -> sealed).', v_old.code, v_old.state;

      v_rank := echo.campaign_state_rank(v_old.state);
      v_target := 4;   -- sealed
      while v_rank < v_target loop
        v_step := case v_rank + 1
                    when 1 then 'open' when 2 then 'closed'
                    when 3 then 'processing' when 4 then 'sealed' end;

        -- MELLÉKHATÁSOK — szó szerint a 18a_echo_campaign.sql 3.2 pontjából
        if v_step = 'processing' then
          select coalesce(sum(m.marked), 0), count(*) into v_marked, v_courses
            from echo.mark_submitted(v_old.id) m;
          v_fill := echo.moderation_fill(v_old.id);
          select count(*) into v_nonpend
            from echo.moderation m join echo.response r on r.id = m.response_id
           where r.campaign_id = v_old.id and m.allapot <> 'pending';
          if v_nonpend = 0 then
            v_mix := echo.shuffle_moderation(v_old.id);
          else
            v_mix := null;
          end if;
          raise notice '18c:   processing — bekuldottnek jelolt: %, erintett kurzus: %, '
                       'moderalasi sor uj: %, kevert: %.', v_marked, v_courses, v_fill, v_mix;
        end if;

        if v_step = 'sealed' then
          v_shuf := echo.shuffle_responses(v_old.id);
          raise notice '18c:   sealed — megkevert valasz: % (VISSZAFORDITHATATLAN).', v_shuf;
        end if;

        update echo.campaign
           set state     = v_step,
               sealed_at = case when v_step = 'sealed' then coalesce(sealed_at, now()) else sealed_at end
         where id = v_old.id;

        insert into echo.campaign_log (campaign_id, from_state, to_state, irany, forced,
                                       actor_key, actor_email, detail)
        values (v_old.id,
                case v_rank when 0 then 'draft' when 1 then 'open'
                            when 2 then 'closed' when 3 then 'processing' end,
                v_step, 'elore', false, null, v_actor,
                jsonb_build_object(
                  'ok', 'nyugdijazas: a 18c migracio a valodi (2.) kerdoiv-verziora '
                        'valto uj kampany miatt lezarta',
                  'migracio', '18c_echo_form_activate.sql'));

        v_rank := v_rank + 1;
      end loop;
    end loop;
  end if;

  -- ----------------------------------------------------------
  -- 4. A 2. VERZIÓ ÉLESÍTÉSE — draft -> review -> approved -> live
  -- ----------------------------------------------------------
  -- Egyesével, mert a echo.template_version_freeze() trigger csak a
  -- szomszédos átmeneteket engedi. A lépés akkor is helyes, ha a verzió
  -- már 'review' vagy 'approved' — onnan folytatja.
  if v_state <> 'live' then
    if v_state = 'draft'    then
      update echo.template_version set state = 'review' where id = v_ver;
      v_state := 'review';
      raise notice '18c: a % verzio -> review.', v_ver;
    end if;
    if v_state = 'review'   then
      update echo.template_version
         set state = 'approved',
             approved_by = coalesce(approved_by, v_actor),
             approved_at = coalesce(approved_at, now())
       where id = v_ver;
      v_state := 'approved';
      raise notice '18c: a % verzio -> approved.', v_ver;
    end if;
    if v_state = 'approved' then
      -- A sablon eddigi elo verziojanak lezarasa — ugyanaz, amit a
      -- public.echo_template_transition() tesz 'live' celallapotnal.
      update echo.template_version
         set state = 'closed'
       where template_id = v_tpl and state = 'live' and id <> v_ver;
      get diagnostics v_closed = row_count;

      update echo.template_version
         set state = 'live',
             approved_by = coalesce(approved_by, v_actor),
             approved_at = coalesce(approved_at, now())
       where id = v_ver;
      v_state := 'live';
      raise notice '18c: a % verzio -> live. Lezart korabbi elo verzio: %.', v_ver, v_closed;
    end if;
  else
    raise notice '18c: a % verzio mar "live" — az elesitest atlepem.', v_ver;
  end if;

  -- ----------------------------------------------------------
  -- 5. AZ ÚJ KAMPÁNY
  -- ----------------------------------------------------------
  if v_new is not null then
    raise notice '18c: a 2. verziohoz mar tartozik kampany (%), ujat nem hozok letre.', v_code;
  elsif v_term is null then
    raise notice '18c: felev hianyaban nem hozok letre kampanyt.';
  else
    -- Kód: ugyanaz a szabály, mint a public.echo_campaign_create()-ben.
    v_base := 'OMHV-' || echo.slug(v_term);
    v_code := v_base;
    while exists (select 1 from echo.campaign where code = v_code) loop
      v_n := v_n + 1;
      v_code := v_base || '-' || v_n::text;
    end loop;

    -- Az ablak: mostantól 60 napig. A célkitűzési ablak AZONNAL nyit, mert
    -- a célonkénti célteljesülés (0.3) csak akkor látszik, ha a hallgató
    -- előbb célt tud rögzíteni. A echo.student_goal KAMPÁNYONKÉNT tárol,
    -- tehát a régi kampányban felvett célok NEM öröklődnek át.
    insert into echo.campaign (code, name_hu, name_en, term, template_version_id,
                               opens_at, closes_at, goals_open_at, goals_close_at, state)
    values (v_code,
            'OMHV kérdőív ' || v_term,
            'ECHO questionnaire ' || v_term,
            v_term, v_ver,
            now(), now() + interval '60 days',
            now(), now() + interval '60 days',
            'draft')
    returning id into v_new;

    insert into echo.campaign_log (campaign_id, from_state, to_state, irany, forced,
                                   actor_key, actor_email, detail)
    values (v_new, null, 'draft', 'letrehozas', false, null, v_actor,
            jsonb_build_object('code', v_code, 'term', v_term,
                               'template_version_id', v_ver,
                               'migracio', '18c_echo_form_activate.sql'));
    raise notice '18c: uj kampany: % (%).', v_code, v_new;
  end if;

  -- 5b. Jogosultsági lista + megnyitás. Külön ágon, hogy egy félbemaradt
  --     korábbi futás után is befejeződjön.
  if v_new is not null then
    select c.state into v_state from echo.campaign c where c.id = v_new;
    if v_state = 'draft' then
      perform * from echo.eligibility_rebuild(v_new);
      select count(*) into v_elig from echo.eligibility where campaign_id = v_new;
      raise notice '18c: jogosultsagi parok: %.', v_elig;

      if v_elig = 0 then
        raise notice '18c: NINCS jogosultsagi sor, ezert a kampanyt NEM nyitom meg '
                     '(ECHO_NO_ELIGIBILITY). Nezd meg a kizarasi naplot: echo.exclusion_log.';
      else
        update echo.campaign set state = 'open' where id = v_new;
        insert into echo.campaign_log (campaign_id, from_state, to_state, irany, forced,
                                       actor_key, actor_email, detail)
        values (v_new, 'draft', 'open', 'elore', false, null, v_actor,
                jsonb_build_object('jogosultsagi_par', v_elig,
                                   'migracio', '18c_echo_form_activate.sql'));
        raise notice '18c: a kampany MEGNYITVA.';
      end if;
    else
      raise notice '18c: a kampany allapota mar "%", nem nyulok hozza.', v_state;
    end if;
  end if;
end
$mig$;

-- ------------------------------------------------------------
-- ELLENŐRZÉS — ez a lekérdezés fut le a migráció végén
-- ------------------------------------------------------------
-- Elvárt kép a sikeres futás után:
--   • a 2. verzió state = 'live', az 1. verzió state = 'closed';
--   • a régi kampány state = 'sealed', az új state = 'open';
--   • az új kampány sorában goal_kerdes = 1 (van célonként ismétlődő kérdés)
--     és jogosultsagi_par > 0.
select c.code,
       c.term,
       c.state                                              as kampany_allapot,
       tv.version                                           as kerdoiv_verzio,
       tv.state                                             as verzio_allapot,
       (select count(*) from echo.eligibility e
         where e.campaign_id = c.id)                        as jogosultsagi_par,
       (select count(*) from echo.response r
         where r.campaign_id = c.id)                        as valasz,
       (select count(*)
          from jsonb_array_elements(tv.compiled->'sections') s,
               jsonb_array_elements(s.value->'questions') q
         where q.value->>'repeat' = 'goal')                 as goal_kerdes,
       (select count(*)
          from jsonb_array_elements(tv.compiled->'sections') s,
               jsonb_array_elements(s.value->'questions') q) as kerdes
  from echo.campaign c
  join echo.template_version tv on tv.id = c.template_version_id
 order by c.created_at;


-- ############################################################
-- ###  19_echo_roles.sql
-- ############################################################

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


-- ############################################################
-- ###  20_echo_report_fix.sql
-- ############################################################

-- ============================================================
-- 20_echo_report_fix.sql — AZ ÓRALÁTOGATÁS HAMIS "KEVÉS VÁLASZ" SORA
-- ============================================================
-- Neumann János Egyetem — ECHO (OMHV), 28/2023. (VIII.31.) szenátusi határozat
--
-- MIÉRT VAN EZ A FÁJL
-- -------------------
-- MÉRT HIBA (13 valódi beküldésen, a helyi replikán): az 'attendance'
-- (óralátogatás) kérdés a kurzusjegyzőkönyvben MINDIG így jelent meg:
--     { "id": "attendance", "n": 0,
--       "uzenet": "Keves valasz (0 < k_numeric=5): errol a kerdesrol nem
--                  adhato ki bontas" }
-- pedig mind a 13 válaszadó kitöltötte: az echo.response.attendance_band
-- mind a 13 kurzusszintű soron '85–100%' volt, ugyanakkor
-- (answers ? 'attendance') mind a 13 soron hamis.
--
-- AZ OK SZERKEZETI, NEM ADATVESZTÉS. Az echo_submit() (15_echo_core.sql,
-- 5. lépés) az óralátogatást a payload gyökeréből a KÜLÖN attendance_band
-- OSZLOPBA teszi — szándékosan, mert a sáv a 3. § (9) szerinti FŐ/ALACSONY
-- kettéosztás bemenete, és mert az oktatói soron NULL-nak kell maradnia
-- (különben az azonos érték egy beküldés sorait egymáshoz kötné).
-- Az echo.results_build() kérdésenkénti ciklusa viszont a compiled
-- kérdéslistáját járja be, és az r.answers -> v_qid kifejezéssel keres —
-- ott az óralátogatás soha nincs ott. A keresés helye és a tárolás helye
-- sosem esett egybe.
--
-- MIT VÁLTOZTAT
--   Az echo.results_build() kérdésciklusa kihagyja az 'attendance' id-jű
--   kérdést. Egyetlen sor a WHERE-ben:
--       and coalesce(qq.value->>'id','') <> 'attendance'
--   Minden más SORRÓL SORRA azonos a 16_echo_reports.sql-beli változattal.
--
-- MIÉRT ID SZERINT ÉS NEM TÍPUS SZERINT: a 18b seed a prototípus
-- type:'attendance' mezőjét 'single'-re fordítja (a renderelő öt típust
-- ismer: single, multi, scale, longtext, skip) — típusra szűrni tehát nem
-- lehet. Mérve.
--
-- MI NEM VÁLTOZIK
--   • az óralátogatás továbbra is vezérli a FŐ/ALACSONY kettéosztást
--     (echo.attendance_low), tehát a 3. § (9) szerinti szűrés érintetlen;
--   • az 'alacsony_oralatogatas' blokk változatlanul közli az elemszámot,
--     amennyit a k_low enged (alatta null, nem 0);
--   • egyetlen k-küszöb sem mozdul.
--
-- HA VALAHA KELL A SÁVOK ELOSZLÁSA a jegyzőkönyvbe: azt az attendance_band
-- OSZLOPBÓL kell aggregálni, echo.suppress_cells()-lel, k_dist küszöbbel —
-- nem az answers-ből. Ez a fájl ezt SZÁNDÉKOSAN nem teszi meg: új
-- közlési felület, amit előbb el kell dönteni, nem mellékesen bevezetni.
--
-- FÜGG: 16_echo_reports.sql (annak kell lefutnia előbb).
-- ÉRINT: echo.results_build() — ezt hívja a public.echo_course_results()
--        és a public.echo_teacher_results() is.
-- IDEMPOTENS: tiszta create or replace, akárhányszor futtatható.
-- FUTTATÁS: Supabase SQL Editor, egyetlen blokként bemásolva.
-- ============================================================

set search_path = echo, public, extensions, pg_temp;

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

-- ------------------------------------------------------------
-- ELLENŐRZÉS — ez a lekérdezés fut le a migráció végén
-- ------------------------------------------------------------
-- Elvárt: 'IGEN' — a futó definícióban benne van a kizárás.
select case when pg_get_functiondef(p.oid) like '%<> ''attendance''%'
            then 'IGEN' else 'NEM' end                       as attendance_kizarva,
       (select count(*) from echo.response r
         where r.scope = 'course' and r.attendance_band is not null) as savval_rendelkezo_valasz
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'echo' and p.proname = 'results_build';


-- ############################################################
-- ###  21_echo_harden_submit.sql
-- ############################################################

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


-- ############################################################
-- ###  22_echo_draft.sql
-- ############################################################

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


-- ############################################################
-- ###  23_echo_form_rules.sql
-- ############################################################

-- ============================================================
-- UniPortal Pro — ECHO: kitöltési szabályok szerveroldali kikényszerítése
-- ------------------------------------------------------------
-- Neumann János Egyetem — OMHV, 28/2023. (VIII.31.) szenátusi határozat
--
-- FUTTATÁSI SORREND: a 15..20 UTÁN. A 21_echo_harden_submit.sql MINDIG az
-- utolsó legyen — ez a fájl ÚJRAÍRJA az echo_submit()-et, tehát a futtatás
-- után a 21-et ÚJRA LE KELL FUTTATNI, különben a platform alapértelmezett
-- jogosztása visszaadhatja az 'authenticated' végrehajtási jogot, és az
-- anonimitás egyik tartóoszlopa csendben elvész.
--
--     ... 20_echo_report_fix.sql
--     23_echo_form_rules.sql      <- ez a fájl
--     21_echo_harden_submit.sql   <- ÚJRA
--
-- MIÉRT VAN EZ A FÁJL — KÉT MÉRT HIÁNY
-- ------------------------------------
-- (1.2) "LEGALÁBB EGY CÉL KÖTELEZŐ". MÉRVE a helyi 'fresh' replikán:
--       select public.echo_save_goals(<kampany>,<kurzus>,'[]','[]')
--         -> {"ok": true, "goals": 0, "expectations": 0}
--       Vagyis a célmeghatározás ÜRESEN is elmenthető volt. Ez nem elméleti
--       gond: cél nélkül a félév végi kitöltőből a "Célok teljesülése" szakasz
--       teljes egészében kiesik (features/echo.jsx, ECHO_buildSteps — "HA A
--       HALLGATÓNAK NINCS CÉLJA, a szakasz KIESIK"), tehát az üres
--       célmeghatározás egy látszatlépés, aminek a félév végén nincs nyoma.
--
-- (1.3) AZ "EGYÉB" MELLÉ KÖTELEZŐ SZÖVEG. MÉRVE ugyanott:
--       echo_submit(<jegy>, {"course":{"course_strengths_p":["Egyéb"]}, ...})
--         -> {"ok": true, "rows": 1}
--       Vagyis a nyers API-n át bemehetett egy csupasz "Egyéb" válasz. Abból
--       annyi derül ki, hogy "valami más volt", az viszont nem, hogy mi —
--       az oktatói eredménynézetben ez egy értelmezhetetlen sor.
--       A felület mostantól nem enged tovább nélküle (ECHO_otherMissing),
--       de a frontend jóhiszemű fél, nem védvonal.
--
-- MIT VÁLTOZTAT
--   1. echo.student_goal + 'intro' jsonb oszlop — a célmeghatározó két
--      BEVEZETŐ kérdésének válasza.
--   2. echo_save_goals(): +p_intro paraméter, normalizálás, és a
--      "legalább egy cél" szabály kikényszerítése.
--   3. echo_get_form(): a 'goals' objektum visszaadja az 'intro'-t is,
--      hogy a célmeghatározó vissza tudja tölteni a korábbi válaszokat.
--   4. echo_submit(): az "Egyéb" melletti szöveg kikényszerítése.
--
-- ================== ADATVÉDELMI HATÁR — OLVASD EL ==================
-- A két bevezető kérdés válasza az echo.student_goal sorba megy, ami a
-- hallgatóhoz VAN kötve (student_key), és a félév eleji célokkal együtt él.
-- Ez tudatos: ugyanaz az adatkör, ugyanaz a jogalap, ugyanaz a láthatóság.
--
-- A NÉVTELEN VÁLASZHALMAZBA (echo.response) EZ NEM MEHET ÁT. Az ok ugyanaz,
-- amiért a célok szövege és darabszáma sem megy át (15_echo_core.sql 1099.
-- sor környéke): az echo.student_goal a hallgatóhoz kötött, tehát bármi, ami
-- onnan a névtelen sorra átkerül, összekötési pontot ad. Az echo_submit()
-- 4. lépése ezért az 'intro' kulcsot is levágja — ugyanabban a listában,
-- ahol a 'goals' és a 'goal_count' áll.
--
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Az 'intro' oszlop
-- ------------------------------------------------------------
alter table echo.student_goal
  add column if not exists intro jsonb not null default '{}'::jsonb;

comment on column echo.student_goal.intro is
  'A celmeghatarozo (part1) BEVEZETO kerdeseinek valaszai: {"<kerdes_id>": <ertek>}. '
  'A hallgatohoz kotott sorban el, a nevtelen echo.response-ba SOHA nem kerul at '
  '(az echo_submit() 4. lepese nev szerint levagja).';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'echo_student_goal_intro_obj_chk') then
    alter table echo.student_goal
      add constraint echo_student_goal_intro_obj_chk
      check (jsonb_typeof(intro) = 'object');
  end if;
end $$;

-- ------------------------------------------------------------
-- 2. Segéd: egy kérdőív-verzió part1 kérdései
-- ------------------------------------------------------------
-- A bevezető kérdések a compiled JSONB part1 szakaszaiban élnek. A validáláshoz
-- tudnunk kell, melyik kérdés kötelező és milyen értékeket vehet fel — ezt
-- innen olvassuk, NEM beégetett listából: ha a kérdőív új verziót kap, a
-- szabály magától követi.
create or replace function echo.part1_questions(p_version uuid)
returns table (qid text, required boolean, qtype text, opts text[])
language sql stable
set search_path = echo, public, pg_temp
as $$
  select q->>'id',
         coalesce((q->>'required')::boolean, false),
         coalesce(q->>'type', 'single'),
         (select coalesce(array_agg(coalesce(o->>'value', o->>'hu', o #>> '{}')), '{}')
            from jsonb_array_elements(case when jsonb_typeof(q->'options') = 'array'
                                           then q->'options' else '[]'::jsonb end) o)
    from echo.template_version tv,
         jsonb_array_elements(case when jsonb_typeof(tv.compiled->'sections') = 'array'
                                   then tv.compiled->'sections' else '[]'::jsonb end) s,
         jsonb_array_elements(case when jsonb_typeof(s->'questions') = 'array'
                                   then s->'questions' else '[]'::jsonb end) q
   where tv.id = p_version
     and s->>'part' = 'part1'
     and coalesce(q->>'id','') <> ''
$$;

-- A part1 kérdés-ID-k listája. Az echo_submit() ezeket NÉV SZERINT levágja a
-- névtelen válaszsorról — lásd az ottani 4) lépést és az indoklást a fejlécben.
create or replace function echo.part1_question_ids(p_version uuid)
returns text[]
language sql stable
set search_path = echo, public, pg_temp
as $$
  select coalesce(array_agg(qid), '{}') from echo.part1_questions(p_version)
$$;

-- ------------------------------------------------------------
-- 3. echo_save_goals — +p_intro, +"legalább egy cél"
-- ------------------------------------------------------------
-- A régi, 4 paraméteres alakot EL KELL DOBNI: az új alak 5. paramétere
-- alapértelmezett értékű, tehát a kettő együtt LÉTEZVE a 4 argumentumos hívás
-- kétértelmű lenne ("function is not unique"). Ha a 15_echo_core.sql-t
-- valaha újrafuttatod, ez a fájl is futtatandó utána.
drop function if exists public.echo_save_goals(uuid, uuid, jsonb, jsonb);

create or replace function public.echo_save_goals(p_campaign uuid, p_course uuid,
                                                  p_goals jsonb, p_expectations jsonb,
                                                  p_intro jsonb default '{}'::jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_me    uuid := auth.uid();
  v_ver   uuid;
  v_g     jsonb;
  v_x     jsonb;
  v_intro jsonb := '{}'::jsonb;
  r       record;
  v_val   text;
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
  if p_intro is not null and jsonb_typeof(p_intro) <> 'object' then
    raise exception 'ECHO_BAD_INTRO: a bevezeto valaszok csak objektumkent adhatok meg.';
  end if;

  -- NORMALIZÁLÁS a hosszellenőrzés ELŐTT. Enélkül három darab whitespace-cél
  -- "3 cél"-nak számítana a korlátnál, a tárolt sorban viszont üres marad,
  -- és a félév végi kitöltő (ECHO_goalItems is trimmel) egyet sem mutatna:
  -- a hallgató úgy tudná, van célja, a rendszer szerint meg nincs.
  select coalesce(jsonb_agg(t), '[]'::jsonb) into v_g
    from (select distinct on (btrim(e #>> '{}')) btrim(e #>> '{}') as t
            from jsonb_array_elements(p_goals) e
           where btrim(coalesce(e #>> '{}', '')) <> '') z;
  select coalesce(jsonb_agg(t), '[]'::jsonb) into v_x
    from (select distinct on (btrim(e #>> '{}')) btrim(e #>> '{}') as t
            from jsonb_array_elements(p_expectations) e
           where btrim(coalesce(e #>> '{}', '')) <> '') z;

  if jsonb_array_length(v_g) > 3 or jsonb_array_length(v_x) > 3 then
    raise exception 'ECHO_TOO_MANY_GOALS';
  end if;

  -- LEGALÁBB EGY CÉL. Az elvárás (p_expectations) NEM helyettesíti: a félév
  -- végi "Célok teljesülése" szakasz mindkettőt felsorolja, de a szabály a
  -- CÉLRÓL szól — a hallgató saját, félév végén eldönthető vállalásáról.
  if jsonb_array_length(v_g) = 0 then
    raise exception 'ECHO_GOALS_REQUIRED';
  end if;

  -- A BEVEZETŐ VÁLASZOK ellenőrzése a kampány kérdőív-verziója szerint.
  select c.template_version_id into v_ver from echo.campaign c where c.id = p_campaign;

  for r in select * from echo.part1_questions(v_ver) loop
    v_val := nullif(btrim(coalesce(p_intro ->> r.qid, '')), '');
    if v_val is null then
      if r.required then
        raise exception 'ECHO_INTRO_REQUIRED: valaszolatlan bevezeto kerdes (%).', r.qid;
      end if;
      continue;
    end if;
    -- Zárt listás kérdésnél csak a felkínált érték mehet be. Enélkül a nyers
    -- API-n át tetszőleges szöveg landolhatna a bevezető válaszban.
    if array_length(r.opts, 1) is not null and not (v_val = any (r.opts)) then
      raise exception 'ECHO_BAD_INTRO: a(z) "%" kerdesre adott valasz nincs a felkinalt opciok kozott.', r.qid;
    end if;
    v_intro := v_intro || jsonb_build_object(r.qid, v_val);
  end loop;

  -- FIGYELEM: a v_intro-ba CSAK a kérdőívben szereplő part1 kérdés-ID-k
  -- kerülnek be. Ami nem onnan való, azt eldobjuk — így a mező nem válhat
  -- szabad tárhellyé a kliens kezében.

  insert into echo.student_goal (campaign_id, course_id, student_key, goals, expectations, intro)
  values (p_campaign, p_course, v_me, v_g, v_x, v_intro)
  on conflict (campaign_id, course_id, student_key)
  do update set goals = excluded.goals,
                expectations = excluded.expectations,
                intro = excluded.intro,
                updated_at = now();

  return jsonb_build_object('ok', true,
                            'goals', jsonb_array_length(v_g),
                            'expectations', jsonb_array_length(v_x),
                            'intro', v_intro);
end $$;

-- ------------------------------------------------------------
-- 4. echo_get_form — az 'intro' visszaadása
-- ------------------------------------------------------------
-- Csak a 'goals' objektum bővül. Minden más mező betű szerint a
-- 15_echo_core.sql 9.2 szakaszából való.
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
           -- A 'lang' MÁR ITT VOLT: a kurzus képzési nyelve. A kitöltő ezt
           -- használja a kérdőív nyelvének eldöntésére (3. § (1)) — NEM a
           -- fejléc nyelvválasztóját. Lásd features/echo.jsx, ECHO_formLang.
           'course', (select jsonb_build_object(
                        'id', k.id, 'code', k.code, 'name', k.name_hu,
                        'name_en', k.name_en, 'lang', k.lang, 'term', k.term)
                        from echo.course k where k.id = p_course),
           'teachers', (select coalesce(jsonb_agg(jsonb_build_object(
                          'id', t.id, 'name', t.name, 'title', t.title,
                          'share_pct', el.share_pct) order by t.name), '[]'::jsonb)
                          from echo.eligibility el
                          join echo.teacher t on t.id = el.teacher_id
                         where el.campaign_id = p_campaign and el.course_id = p_course),
           'form', (select tv.compiled from echo.template_version tv
                     where tv.id = v_c.template_version_id),
           'template_version_id', v_c.template_version_id,
           -- A SAJÁT célok, elvárások ÉS bevezető válaszok (azonosított hívás,
           -- ezért szabad). Ezekből SEMMI nem megy át a névtelen válaszsorra.
           'goals', coalesce((select jsonb_build_object('goals', g.goals,
                                       'expectations', g.expectations,
                                       'intro', coalesce(g.intro, '{}'::jsonb))
                                from echo.student_goal g
                               where g.campaign_id = p_campaign and g.course_id = p_course
                                 and g.student_key = v_me),
                             jsonb_build_object('goals','[]'::jsonb,'expectations','[]'::jsonb,
                                                'intro','{}'::jsonb)),
           'participation', jsonb_build_object(
              'attempted', v_p.attempted, 'submitted', v_p.submitted)
         )
    into v_out;
  return v_out;
end $$;

-- ------------------------------------------------------------
-- 5. Segéd: az "Egyéb"-hiányos többes választások egy válaszhalmazban
-- ------------------------------------------------------------
-- Visszaadja azoknak a kérdéseknek az ID-ját, ahol a beküldő bejelölte az
-- "Egyéb" opciót, de nem írt mellé saját szöveget.
--
-- AZ "EGYÉB" AZONOSÍTÁSA a compiled adatából megy:
--   elsődlegesen az opció "other": true jelzője, másodlagosan a value/hu/en
--   szövege ('Egyéb' / 'Egyeb' / 'Other'). A második ág azért kell, mert a MA
--   ÉLŐ 2. verzióban nincs "other" jelző (mérve) — e nélkül a szabály a
--   jelenlegi kérdőíven nem fogna semmit.
-- A SAJÁT SZÖVEG definíció szerint az, ami NINCS benne az opciólistában —
-- pontosan úgy, ahogy a felület is számolja (ECHO_QMulti `extras`).
create or replace function echo.other_text_gaps(p_version uuid, p_answers jsonb, p_scope text)
returns text[]
language plpgsql stable
set search_path = echo, public, pg_temp
as $$
declare
  q        jsonb;
  v_qid    text;
  v_vals   text[];
  v_opts   text[];
  v_others text[];
  v_extra  int;
  v_out    text[] := '{}';
begin
  if p_answers is null or jsonb_typeof(p_answers) <> 'object' then return v_out; end if;

  for q in
    select qq
      from echo.template_version tv,
           jsonb_array_elements(case when jsonb_typeof(tv.compiled->'sections') = 'array'
                                     then tv.compiled->'sections' else '[]'::jsonb end) s,
           jsonb_array_elements(case when jsonb_typeof(s->'questions') = 'array'
                                     then s->'questions' else '[]'::jsonb end) qq
     where tv.id = p_version
       and qq->>'type' = 'multi'
       -- A part1 (celmeghatarozas) kerdesei SOHA nem kerulnek a nevtelen
       -- valaszhalmazba, tehat itt nincs mit ellenorizni rajtuk.
       and coalesce(s->>'part', 'part2') <> 'part1'
       -- 'course' hatokorben a nem ismetlodo es a celonkenti kerdesek, 'teacher'
       -- hatokorben az oktatonkentiek. Igy egy oktatoi valaszhalmazon nem
       -- keresunk kurzusszintu kerdest es forditva.
       and ((p_scope = 'teacher' and qq->>'repeat' = 'teacher')
         or (p_scope = 'course'  and coalesce(qq->>'repeat','') is distinct from 'teacher'))
  loop
    v_qid := q->>'id';
    if coalesce(v_qid,'') = '' then continue; end if;
    if jsonb_typeof(p_answers -> v_qid) <> 'array' then continue; end if;

    select coalesce(array_agg(e #>> '{}'), '{}') into v_vals
      from jsonb_array_elements(p_answers -> v_qid) e;
    if array_length(v_vals, 1) is null then continue; end if;

    -- az osszes felkinalt ertek
    select coalesce(array_agg(coalesce(o->>'value', o->>'hu', o #>> '{}')), '{}') into v_opts
      from jsonb_array_elements(case when jsonb_typeof(q->'options') = 'array'
                                     then q->'options' else '[]'::jsonb end) o;
    -- ezek kozul az "Egyeb"-ek
    select coalesce(array_agg(coalesce(o->>'value', o->>'hu', o #>> '{}')), '{}') into v_others
      from jsonb_array_elements(case when jsonb_typeof(q->'options') = 'array'
                                     then q->'options' else '[]'::jsonb end) o
     where coalesce((o->>'other')::boolean, false)
        or lower(btrim(coalesce(o->>'value', ''))) in ('egyéb','egyeb','other')
        or lower(btrim(coalesce(o->>'hu',    ''))) in ('egyéb','egyeb','other')
        or lower(btrim(coalesce(o->>'en',    ''))) in ('egyéb','egyeb','other');

    if array_length(v_others, 1) is null then continue; end if;
    if not (v_vals && v_others) then continue; end if;      -- nincs "Egyeb" bejelolve

    -- van-e olyan bekuldott ertek, ami NINCS az opciolistaban
    select count(*) into v_extra
      from unnest(v_vals) v
     where btrim(coalesce(v,'')) <> '' and not (v = any (v_opts));

    if v_extra = 0 then v_out := v_out || v_qid; end if;
  end loop;

  return v_out;
end $$;

-- ------------------------------------------------------------
-- 6. echo_submit — az "Egyéb" melletti szöveg kikényszerítése
-- ------------------------------------------------------------
-- A 15_echo_core.sql 9.5 szakaszának változata. AMI VÁLTOZOTT:
--   • a 4) TISZTÍTÁS levágja az 'intro' kulcsot is (a bevezető válaszok a
--     hallgatóhoz kötött sorban élnek, a névtelen sorra nem jöhetnek át);
--   • új 4/b) lépés: az "Egyéb" melletti szöveg ellenőrzése kurzus- és
--     oktatószintű válaszhalmazon egyaránt.
-- Minden más betű szerint az eredeti.
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
  v_goals_met text;
  v_gaps      text[];
  v_tans      jsonb;
  v_p1        text[];
  v_key       text;
begin
  -- 1) a jegy hitelessége
  v_t := echo.ticket_open(p_ticket);
  v_campaign := (v_t->>'c')::uuid;
  v_course   := (v_t->>'k')::uuid;
  v_ver      := (v_t->>'v')::uuid;
  v_nonce    := (v_t->>'n')::uuid;
  v_exp      := (v_t->>'e')::bigint;

  if to_timestamp(v_exp) < now() then raise exception 'ECHO_TICKET_EXPIRED'; end if;
  if not echo.is_open(v_campaign) then raise exception 'ECHO_CAMPAIGN_CLOSED'; end if;

  -- 2) a nonce elköltése ELSŐKÉNT
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
  v_goals_met := v_course_a->>'goals_met';
  if v_goals_met is not null
     and v_goals_met not in ('nem_teljesult','reszben','teljesult','tulteljesult') then
    raise exception 'ECHO_BAD_GOALS_MET';
  end if;
  v_course_a := v_course_a
    - 'goals' - 'goal_texts' - 'goals_text' - 'goal_count' - 'goals_count'
    - 'expectations' - 'expectation_texts' - 'student' - 'student_key'
    -- 'intro': a celmeghatarozo bevezeto valaszai. Az echo.student_goal
    -- sorban elnek, ami a hallgatohoz VAN kotve — a nevtelen valaszsorra
    -- atemelve osszekotesi pontot adnanak. Lasd 23_echo_form_rules.sql fejlec.
    - 'intro'
    - 'email' - 'name' - 'neptun' - 'user_id' - 'uid'
    - 'created_at' - 'submitted_at' - 'timestamp' - 'ts';

  -- 4/a) A PART1 (CÉLMEGHATÁROZÁS) KÉRDÉSEINEK LEVÁGÁSA.
  --      MÉRVE: az 'intro' kulcs levágása ÖNMAGÁBAN KEVÉS volt. Egy kliens a
  --      part1 kérdéseket a SAJÁT ID-JÜKÖN is beírhatta a course objektumba
  --      ("goals_discussed", "req_clear"), és azok bementek a névtelen sorra.
  --      Ez ugyanaz a szivárgás, amiért a célok darabszáma sem mehet át: a
  --      part1 válasz az AZONOSÍTOTT echo.student_goal sorban is ott áll, tehát
  --      a két oldal összevethető, és a 4x4 lehetséges válaszpár erősen
  --      leszűkíti a szóba jöhető kitöltők körét.
  --      A lista a kérdőívből jön, nem beégetve: ha a part1 új kérdést kap,
  --      a levágás magától követi.
  v_p1 := echo.part1_question_ids(v_ver);
  if array_length(v_p1, 1) is not null then
    foreach v_key in array v_p1 loop
      v_course_a := v_course_a - v_key;
    end loop;
  end if;

  -- 4/b) AZ "EGYÉB" MELLÉ KÖTELEZŐ A SZÖVEG.
  --      A felület már nem enged tovább nélküle, de a frontend jóhiszemű fél,
  --      nem védvonal: a nyers API-n át enélkül bemehetne egy csupasz "Egyéb",
  --      amiből az oktatói eredménynézetben egy értelmezhetetlen sor lenne.
  v_gaps := echo.other_text_gaps(v_ver, v_course_a, 'course');
  if array_length(v_gaps, 1) is not null then
    raise exception 'ECHO_OTHER_TEXT_REQUIRED: az "Egyeb" valasz melle szoveget is meg kell adni (%).',
                    array_to_string(v_gaps, ', ');
  end if;

  -- 5) kurzusszintű válaszsor
  insert into echo.response (campaign_id, course_id, teacher_id, template_version_id,
                             scope, attendance_band, answers)
  values (v_campaign, v_course, null, v_ver, 'course', v_att, v_course_a);
  v_n := v_n + 1;

  -- 6) oktatószintű válaszsorok
  for v_item in select * from jsonb_array_elements(v_teachers) loop
    v_tid := nullif(v_item->>'teacher','')::uuid;
    if v_tid is null then continue; end if;
    if not exists (select 1 from echo.eligibility
                    where campaign_id = v_campaign and course_id = v_course
                      and teacher_id = v_tid) then
      raise exception 'ECHO_TEACHER_NOT_ELIGIBLE';
    end if;

    v_tans := (coalesce(v_item->'answers','{}'::jsonb)
                - 'student' - 'student_key' - 'email' - 'name' - 'neptun' - 'user_id' - 'uid'
                - 'intro'
                - 'created_at' - 'submitted_at' - 'timestamp' - 'ts');
    -- ugyanaz a levagas, mint a kurzusszintu halmazon (4/a)
    if array_length(v_p1, 1) is not null then
      foreach v_key in array v_p1 loop
        v_tans := v_tans - v_key;
      end loop;
    end if;

    v_gaps := echo.other_text_gaps(v_ver, v_tans, 'teacher');
    if array_length(v_gaps, 1) is not null then
      raise exception 'ECHO_OTHER_TEXT_REQUIRED: az "Egyeb" valasz melle szoveget is meg kell adni (%).',
                      array_to_string(v_gaps, ', ');
    end if;

    insert into echo.response (campaign_id, course_id, teacher_id, template_version_id,
                               scope, attendance_band, answers)
    -- attendance_band SZANDEKOSAN null: lasd 15_echo_core.sql 6.2.
    values (v_campaign, v_course, v_tid, v_ver, 'teacher', null,
            v_tans || jsonb_build_object(
              'skipped', coalesce(v_item->'skipped','false'::jsonb),
              'skip_reason', coalesce(v_item->'skip_reason','null'::jsonb)));
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'rows', v_n);
end $$;

-- ------------------------------------------------------------
-- 7. GRANTOK
-- ------------------------------------------------------------
-- Postgresben minden ÚJ függvény EXECUTE jogot ad a PUBLIC-nak, ezért előbb
-- mindenkitől elvesszük, majd célzottan adjuk oda. Az echo_submit itt
-- SZÁNDÉKOSAN csak anon-t kap — a 21_echo_harden_submit.sql ezt zárja le
-- véglegesen, és azt EZUTÁN kell futtatni.
do $$
declare
  fn text;
  has_anon bool := exists (select 1 from pg_roles where rolname='anon');
  has_auth bool := exists (select 1 from pg_roles where rolname='authenticated');
  has_svc  bool := exists (select 1 from pg_roles where rolname='service_role');
begin
  -- az echo semas segedek zarva maradnak
  for fn in select p.oid::regprocedure::text
              from pg_proc p join pg_namespace n on n.oid=p.pronamespace
             where n.nspname='echo' and p.proname in ('part1_questions','part1_question_ids','other_text_gaps')
  loop
    execute format('revoke all on function %s from public', fn);
    if has_anon then execute format('revoke all on function %s from anon', fn); end if;
    if has_auth then execute format('revoke all on function %s from authenticated', fn); end if;
    if has_svc  then execute format('revoke all on function %s from service_role', fn); end if;
  end loop;

  for fn in select p.oid::regprocedure::text
              from pg_proc p join pg_namespace n on n.oid=p.pronamespace
             where n.nspname='public' and p.proname in ('echo_save_goals','echo_get_form','echo_submit')
  loop
    execute format('revoke all on function %s from public', fn);
    if has_anon then execute format('revoke all on function %s from anon', fn); end if;
    if has_auth then execute format('revoke all on function %s from authenticated', fn); end if;
    if has_svc  then execute format('revoke all on function %s from service_role', fn); end if;
  end loop;

  if has_auth then
    grant execute on function public.echo_get_form(uuid,uuid)                       to authenticated;
    grant execute on function public.echo_save_goals(uuid,uuid,jsonb,jsonb,jsonb)   to authenticated;
  end if;
  if has_anon then
    grant execute on function public.echo_submit(text,jsonb) to anon;
  end if;
end $$;

-- ------------------------------------------------------------
-- 8. ELLENŐRZÉS
-- ------------------------------------------------------------
select 'echo.student_goal.intro' as mit,
       (select count(*)::text from information_schema.columns
         where table_schema='echo' and table_name='student_goal' and column_name='intro') as ertek
union all
select 'echo_save_goals argumentumai',
       (select pg_get_function_identity_arguments(p.oid) from pg_proc p
          join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='echo_save_goals')
union all
select 'echo_save_goals darab (1 legyen)',
       (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='echo_save_goals')
union all
select 'echo_submit acl',
       (select coalesce(array_to_string(p.proacl,' '),'(alapertelmezett)') from pg_proc p
          join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='echo_submit');


-- ############################################################
-- ###  24_echo_form_v3.sql
-- ############################################################

-- ============================================================
-- UniPortal Pro — ECHO: a célmeghatározó két BEVEZETŐ kérdése (3. verzió)
-- ------------------------------------------------------------
-- Neumann János Egyetem — OMHV, 28/2023. (VIII.31.) szenátusi határozat
--
-- FUTTATÁSI SORREND: a 23_echo_form_rules.sql UTÁN, a 21_echo_harden_submit.sql
-- ELŐTT (a 21 mindig az utolsó):
--     ... 20_echo_report_fix.sql
--     23_echo_form_rules.sql
--     24_echo_form_v3.sql        <- ez a fájl
--     21_echo_harden_submit.sql  <- MINDIG az utolsó
--
-- FIGYELEM — A 20_echo_report_fix.sql NEM FUTHAT EZUTÁN. Ez a fájl az
-- echo.results_build() függvényt írja felül (a 20-as változata + egy új
-- feltétel), tehát a 20 újrafuttatása CSENDBEN visszavenné a part1-kizárást,
-- és a célmeghatározás két bevezető kérdése n=0-val megjelenne az oktatói
-- eredménynézetben. Ha a 20-at bármiért újra kell futtatni, futtasd utána
-- ezt a fájlt is (idempotens: a kérdőív-verziót nem hozza létre másodszor,
-- csak a függvényt állítja helyre).
--
-- MIÉRT VAN EZ A FÁJL
-- -------------------
-- A célmeghatározás (part1) a prototípus szerint KÉT BEVEZETŐ KÉRDÉSSEL indul:
--   • beszélt-e a hallgató az oktatóval a kurzus céljairól,
--   • világosak-e a teljesítési követelmények.
-- MÉRVE a helyi 'fresh' replikán: a MA ÉLŐ 2. verzió compiled JSONB-jében
-- 0 db part1 szakasz van (mind a 6 szakasz part2), tehát ez a két kérdés
-- sehol nem szerepel. A célmeghatározó felület emiatt csak a két
-- listaszerkesztőt (célok / elvárások) mutatja.
--
-- MIÉRT A COMPILED JSONB-BE ÉS NEM A FELÜLETRE
-- --------------------------------------------
-- A features/echo.jsx fejlécének szabálya: "A KÉRDÉSEK NEM ITT VANNAK... Ha ide
-- bármikor bekerülne egy kérdésszöveg, az azt jelentené, hogy a felület és a
-- szenátus által jóváhagyott kérdőív szétcsúszhat." A két bevezető kérdés
-- VALÓDI kérdőívkérdés, tehát a kérdőív-verzióban a helye — akkor is, ha a
-- válasza nem a névtelen halmazba megy.
--
-- ================== FORRÁSHŰSÉG — OLVASD EL ==================
-- A megadott forrásfájl (forras/ECHO Prototipus.dc.html) EBBEN A MUNKAMÁSOLATBAN
-- NEM TALÁLHATÓ — kerestem, nincs meg. Az alábbi két kérdés szövege ezért NEM
-- szó szerinti átvétel, hanem a feladatleírás alapján, a 18b_echo_form_seed.sql
-- meglévő kérdéseinek stílusában megfogalmazott REKONSTRUKCIÓ. Ez ugyanaz a
-- helyzet, ami az 1. verziónál állt fenn ("Az 1. verzió szövegei
-- rekonstrukciók voltak"), és ugyanúgy MIR-jóváhagyást igényel.
-- A meta.forras_megjegyzes mező ezt a verzióban is kimondja, hogy a
-- szerkesztőben is látszódjon.
--
-- MIT VÁLTOZTAT
--   1. echo.results_build(): a part1 szakaszok kérdései kimaradnak a
--      riportból. (A 20_echo_report_fix.sql változatának betű szerinti
--      másolata EGYETLEN új feltétellel — lásd a megjegyzést a ciklusnál.)
--   2. Létrejön a 3. kérdőív-verzió: a mai ÉLŐ verzió másolata
--        + egy part1 szakasz a két bevezető kérdéssel,
--        + az "Egyéb" opciókon "other": true jelző.
--      A verzió 'draft' állapotban marad — az élesítés TUDATOS, kézi döntés.
--
-- MIT NEM TESZ MEG — SZÁNDÉKOSAN
--   • NEM élesíti a 3. verziót és NEM köti át a futó kampányt. A 18c fájl
--     tapasztalata szerint ez lepecsételi a futó kampányt és lezárja az előző
--     kérdőív-verziót — mindkettő VISSZAFORDÍTHATATLAN. Az élesítés lépéseit
--     a fájl végén, kikommentelve adom meg.
--   • NEM töröl és NEM módosít egyetlen meglévő verziót sem: az élő verzió
--     compiled mezőjét az echo.template_version_guard() amúgy sem engedné.
--
-- MIÉRT KELL AZ "other": true JELZŐ
--   Az "Egyéb melletti kötelező szöveg" szabálya (23_echo_form_rules.sql) ma
--   szövegegyezéssel ismeri fel az "Egyéb"/"Other" opciót, mert a 2. verzióban
--   nincs jelző. A szövegegyezés törékeny: egy jövőbeli "Egyéb (kérjük írd le)"
--   címke már nem illeszkedne. A 3. verzió ezért expliciten megjelöli az
--   opciót; a szövegalapú felismerés visszaesési ágként megmarad.
--
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

set search_path = echo, public, extensions, pg_temp;

-- ------------------------------------------------------------
-- 1. echo.results_build — a part1 kérdések kizárása a riportból
-- ------------------------------------------------------------
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
       -- AZ EGYETLEN VALTOZAS a 20_echo_report_fix.sql valtozatahoz kepest:
       -- a part1 (celmeghatarozas) szakaszok kerdesei KIMARADNAK. Ezek a
       -- felev ELEJEN, azonositva, az echo.student_goal sorba valaszolodnak,
       -- es SOHA nem kerulnek at a nevtelen echo.response-ba. Enelkul minden
       -- part1 kerdes n=0-val jelenne meg az oktatoi eredmenynezetben:
       -- olyan kerdesek, amikre ebben a halmazban nem is lehet valasz.
       and coalesce(s.value->>'part', 'part2') <> 'part1'
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

-- ------------------------------------------------------------
-- 2. A 3. kérdőív-verzió
-- ------------------------------------------------------------
do $mig$
declare
  v_tpl      uuid;
  v_live     uuid;
  v_src      jsonb;
  v_new      jsonb;
  v_secs     jsonb;
  v_part1    jsonb;
  v_ver      integer;
  v_id       uuid;
  v_state    text;
  v_hits     jsonb;
begin
  select id into v_tpl from echo.template where code = 'OMHV-ALAP';
  if v_tpl is null then
    raise exception '24: nincs meg az OMHV-ALAP sablon. Eloszor a 15_echo_core.sql fusson.';
  end if;

  -- A FORRAS a jelenleg ELO verzio. Ha nincs elo, a legmagasabb sorszamu.
  select id, compiled into v_live, v_src
    from echo.template_version
   where template_id = v_tpl
   order by (state = 'live') desc, version desc
   limit 1;
  if v_live is null then
    raise exception '24: az OMHV-ALAP sablonnak nincs egyetlen verzioja sem.';
  end if;

  -- Mar letezik a bevezeto kerdeseket tartalmazo verzio? Akkor nem csinalunk ujat.
  select id, state into v_id, v_state
    from echo.template_version
   where template_id = v_tpl
     and exists (select 1
                   from jsonb_array_elements(echo.jarr(compiled->'sections')) s
                  where s.value->>'part' = 'part1'
                    and jsonb_array_length(echo.jarr(s.value->'questions')) > 0)
   order by version desc
   limit 1;
  if v_id is not null then
    raise notice '24: mar letezik part1 kerdeseket tartalmazo verzio (%, allapot=%). A fajl nem csinal ujat.', v_id, v_state;
    return;
  end if;

  -- ---- a ket bevezeto kerdes ----
  v_part1 := $json$
{
  "id": "s0", "part": "part1", "audience": [],
  "hu": "Mielőtt célt tűzöl ki", "en": "Before you set your goals",
  "lead_hu": "Két rövid kérdés a félév indulásáról. A válaszod csak a Tiéd — az oktató nem látja.",
  "lead_en": "Two short questions about the start of the term. Your answer stays yours — the teacher does not see it.",
  "questions": [
    { "id": "goals_discussed", "type": "single",
      "hu": "Beszéltetek az oktatóval a kurzus céljairól a félév elején?",
      "en": "Did you discuss the aims of the course with the teacher at the start of the term?",
      "help": { "hu": "A válaszod a saját célmeghatározásodhoz tartozik, a félév végi névtelen értékelésbe nem kerül át.",
                "en": "Your answer belongs to your own goal setting; it is not carried over to the anonymous end-of-term evaluation." },
      "options": [
        { "value": "reszletesen",  "hu": "Igen, részletesen",   "en": "Yes, in detail" },
        { "value": "roviden",      "hu": "Igen, röviden",       "en": "Yes, briefly" },
        { "value": "nem",          "hu": "Nem",                 "en": "No" },
        { "value": "nem_emlekszem","hu": "Nem emlékszem",       "en": "I do not remember" }
      ],
      "required": true, "moderated": false, "randomize": false, "allowOther": false,
      "max": 1, "repeat": null, "cond": null, "scale": null,
      "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
    { "id": "req_clear", "type": "single",
      "hu": "Világosak számodra a kurzus teljesítési követelményei?",
      "en": "Are the course requirements clear to you?",
      "help": { "hu": "A félév végén ugyanerről még egyszer kérdezünk — akkor arról, hogy változtak-e.",
                "en": "We ask about this again at the end of the term — then about whether they changed." },
      "options": [
        { "value": "teljesen",   "hu": "Teljesen világosak",      "en": "Completely clear" },
        { "value": "nagyreszt",  "hu": "Nagyrészt világosak",     "en": "Mostly clear" },
        { "value": "reszben",    "hu": "Részben világosak",       "en": "Partly clear" },
        { "value": "egyaltalan", "hu": "Egyáltalán nem világosak","en": "Not clear at all" }
      ],
      "required": true, "moderated": false, "randomize": false, "allowOther": false,
      "max": 1, "repeat": null, "cond": null, "scale": null,
      "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
  ]
}
  $json$::jsonb;

  -- ---- a part1 szakasz a lista ELEJERE ----
  v_secs := jsonb_build_array(v_part1) || echo.jarr(v_src->'sections');

  -- ---- az "Egyeb" opciok megjelolese other:true jelzovel ----
  select jsonb_agg(
           case when jsonb_typeof(s.value->'questions') = 'array'
                then jsonb_set(s.value, '{questions}', (
                       select coalesce(jsonb_agg(
                         case when jsonb_typeof(q.value->'options') = 'array'
                              then jsonb_set(q.value, '{options}', (
                                     select coalesce(jsonb_agg(
                                       case when lower(btrim(coalesce(o.value->>'value',''))) in ('egyéb','egyeb','other')
                                              or lower(btrim(coalesce(o.value->>'hu',   ''))) in ('egyéb','egyeb','other')
                                              or lower(btrim(coalesce(o.value->>'en',   ''))) in ('egyéb','egyeb','other')
                                            then o.value || '{"other": true}'::jsonb
                                            else o.value end
                                       order by o.ordinality), '[]'::jsonb)
                                       from jsonb_array_elements(q.value->'options') with ordinality o))
                              else q.value end
                         order by q.ordinality), '[]'::jsonb)
                         from jsonb_array_elements(s.value->'questions') with ordinality q))
                else s.value end
           order by s.ordinality)
    into v_secs
    from jsonb_array_elements(v_secs) with ordinality s;

  -- ---- a verzio sorszama es meta mezoi ----
  select coalesce(max(version), 0) + 1 into v_ver
    from echo.template_version where template_id = v_tpl;

  v_new := jsonb_set(v_src, '{sections}', v_secs);
  v_new := jsonb_set(v_new, '{meta,version}', to_jsonb(v_ver));
  v_new := jsonb_set(v_new, '{meta,elozmeny}', to_jsonb(
    'A ' || v_ver || '. verzio a ' || coalesce((v_src->'meta'->>'version'),'?') ||
    '. verzio masolata, kiegeszitve a celmeghatarozas (part1) ket bevezeto '
    'kerdesevel, es az "Egyeb" opciok other:true jelzojevel. A korabbi verziok '
    'NEM torolhetok: a hozzajuk kotott valaszok rajuk hivatkoznak.'));
  v_new := jsonb_set(v_new, '{meta,forras_megjegyzes}', to_jsonb(
    'A ket bevezeto kerdes (goals_discussed, req_clear) szovege REKONSTRUKCIO: '
    'a prototipus forrasfajlja a munkamasolatban nem volt elerheto. MIR-jovahagyast '
    'igenyel az elesites elott.'::text));

  v_id := gen_random_uuid();
  insert into echo.template_version (id, template_id, version, state, compiled, notes)
  values (v_id, v_tpl, v_ver, 'draft', v_new,
          'A celmeghatarozas ket bevezeto kerdese + "Egyeb" jelzok (24_echo_form_v3.sql). '
          'A ket kerdes szovege rekonstrukcio, MIR-jovahagyasra var.');

  v_hits := echo.template_validate(v_new);
  raise notice '24: letrejott a %. verzio (draft), id=%. Validator talalatok: %',
               v_ver, v_id, jsonb_array_length(v_hits);
  if jsonb_array_length(v_hits) > 0 then
    raise notice '24: a validator reszletei: %', v_hits;
  end if;
end $mig$;

-- ------------------------------------------------------------
-- 3. ELLENŐRZÉS
-- ------------------------------------------------------------
select tv.version,
       tv.state,
       (select count(*) from jsonb_array_elements(echo.jarr(tv.compiled->'sections')) s
         where s.value->>'part' = 'part1')                                as part1_szakasz,
       (select count(*) from jsonb_array_elements(echo.jarr(tv.compiled->'sections')) s,
                             jsonb_array_elements(echo.jarr(s.value->'questions')) q
         where s.value->>'part' = 'part1')                                as part1_kerdes,
       (select count(*) from jsonb_array_elements(echo.jarr(tv.compiled->'sections')) s,
                             jsonb_array_elements(echo.jarr(s.value->'questions')) q,
                             jsonb_array_elements(echo.jarr(q.value->'options')) o
         where coalesce((o.value->>'other')::boolean, false))             as egyeb_jelzo,
       jsonb_array_length(echo.template_validate(tv.compiled))            as validator_talalat
  from echo.template_version tv
  join echo.template t on t.id = tv.template_id
 where t.code = 'OMHV-ALAP'
 order by tv.version;

-- Elvárt: 'IGEN' — a futó definícióban benne van a part1-kizárás is.
select case when pg_get_functiondef(p.oid) like '%<> ''part1''%'
            then 'IGEN' else 'NEM' end as part1_kizarva_a_riportbol
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'echo' and p.proname = 'results_build';

-- ============================================================
-- KÉZI LÉPÉSEK — EZEKET A FÁJL SZÁNDÉKOSAN NEM TESZI MEG
-- ============================================================
-- 1) ÁTNÉZÉS A SZERKESZTŐBEN: ECHO -> Kérdőívek -> OMHV alapkerdoiv ->
--    a most létrejött piszkozat. A két bevezető kérdés szövege
--    REKONSTRUKCIÓ (lásd a fájl fejlécét) — MIR-jóváhagyás kell rá.
--
-- 2) ÉLESÍTÉS. Admin munkamenetben, egyesével (a draft->approved ugrást a
--    echo.template_version_freeze() trigger tiltja):
--      -- select public.echo_template_validate('<uj_verzio_id>');
--      -- select public.echo_template_transition('<uj_verzio_id>', 'review');
--      -- select public.echo_template_transition('<uj_verzio_id>', 'approved');
--      -- select public.echo_template_transition('<uj_verzio_id>', 'live');
--
-- 3) A KAMPÁNY. Egy kampány = egy kérdőív-verzió (lásd 18c fejléce): a futó
--    kampányt NE kösd át, mert a régi válaszokat a régi verzió kérdés-ID-jeivel
--    keresné a riport. ÚJ kampány kell az új verzióval — a félév futó kampányát
--    előbb le kell zárni és lepecsételni. Mindkettő VISSZAFORDÍTHATATLAN.
--
-- 4) AZ ELŐZŐ VERZIÓ automatikusan 'closed' lesz az élesítéskor (egy sablonnak
--    egy élő verziója lehet). Ez végleges, de a rá hivatkozó válaszok
--    értelmezhetők maradnak: a response tábla a saját verzióját őrzi.
-- ============================================================


-- ############################################################
-- ###  25_status_model.sql
-- ############################################################

-- ============================================================================
-- 25_status_model.sql — A felvételi státuszmodell: katalógus + állapotgép
-- ============================================================================
--
-- FÁJLNÉV: a munkacsomag eredetileg 23_status_model.sql-t kért, de a 23-as és
-- a 24-es sorszámot időközben az ECHO-ág foglalta el (23_echo_form_rules.sql,
-- 24_echo_form_v3.sql). Két azonos sorszámú migráció a betöltési sorrendet
-- tenné kiszámíthatatlanná, ezért ez a fájl a 25-ös. Tartalmilag változatlan.
--
-- ---------------------------------------------------------------------------
-- MIÉRT
-- ---------------------------------------------------------------------------
-- A students."status" ma szabad szöveg: bármit bele lehet írni, és bárhonnan
-- bárhová át lehet ugrani. MÉRVE a 'fresh' replikán a migráció ELŐTT:
--
--     Accepted 3 | Draft 1 | Missing Info 2 | Paid 3 | Submitted 2   (11 sor)
--
-- Ez a hét érték (a 'Rejected' és a 'Failed' az app.jsx-ben él, az adatban
-- nem) három különböző dolgot kever össze egyetlen mezőben: a jelentkezés
-- előrehaladását, a dokumentumok hiányát és a pénzügyi teljesítést.
--
-- ---------------------------------------------------------------------------
-- A FŐ LÁNC (C1 · D1 döntés)
-- ---------------------------------------------------------------------------
--     Draft → Submitted → Documents checked → Nominated
--                                              ├─→ Failed                (vég)
--                                              └─→ Conditionally accepted
--                                                        ├─→ Accepted    (vég)
--                                                        └─→ Failed      (vég)
--
-- A 'Failed' VÉGÁLLAPOT, nem láncszem: a bírálat utáni elágazás egyik ága.
-- Kilépni belőle csak explicit újranyitással lehet (Failed → Nominated),
-- amit a lenti tábla is_backward = true sorként tart nyilván.
--
-- ---------------------------------------------------------------------------
-- A BEIRATKOZÁS UTÁNI HÁROM SÁV (C2 · D2 döntés)
-- ---------------------------------------------------------------------------
-- A beiratkozás után NEM folytatódik a lánc. A fő státusz 'Accepted' marad,
-- és mellé három EGYMÁSTÓL FÜGGETLEN mező kerül:
--
--     visa_state     : null | waiting | accepted | rejected
--     deferral_state : null | requested | letter_sent
--     refund_state   : null | requested | bank_details_needed
--                           | bank_details_provided | forwarded_to_finance
--                           | processed
--
-- INDOK: egy hallgató kérhet halasztást ÉS várhat visszatérítést egyszerre,
-- miközben a vízuma is elbírálás alatt van. Egyetlen státuszmezőben ez a
-- három párhuzamos tény ábrázolhatatlan lenne — vagy elveszne belőle kettő,
-- vagy kombinatorikus státuszrobbanás lenne (3 × 2 × 5 = 30 érték).
--
-- ---------------------------------------------------------------------------
-- A MEGLÉVŐ ÉRTÉKEK ÁTVEZETÉSE — ÉS AZ INDOKA
-- ---------------------------------------------------------------------------
--  'Missing Info' → 'Submitted'
--      A hiányzó dokumentum nem a jelentkezés állapota, hanem a
--      dokumentumoké: a students."visaChecklist" és az admission_processes
--      .data.docs tartja nyilván darabonként. Aki hiánypótlásra vár, az
--      pontosan ugyanott áll, mint bárki más beadás után: a
--      dokumentum-ellenőrzés még nem zárult le. Ezért 'Submitted'.
--
--  'Paid' → 'Accepted'
--      A fizetés pénzügyi tény, nem felvételi döntés — a payments/invoices
--      táblák tartják nyilván, és a C2 sávok mellé illeszkedik. A régi kód
--      (app.jsx api.processPayment / verifyPayment) a fizetéskor a
--      students.status-t 'Paid'-re írta, ami FELÜLÍRTA a felvételi döntést:
--      egy 'Nominated' jelentkezőből a díj beérkezésétől 'Paid' lett, és a
--      bírálati állapot NYOMTALANUL ELVESZETT. Aki fizetett, azt korábban
--      felvették, tehát 'Accepted'.
--
--  'Rejected' → 'Failed'
--      A D1 döntés szerint az elutasítás egyetlen neve 'Failed'. A 'Rejected'
--      az adatban ma 0 sor (mérve), az app.jsx-ben viszont előfordult; a
--      leképezés így a jövőbeni beszivárgás ellen is véd.
--
-- VISSZAFORDÍTHATÓSÁG: a students kap egy "status_legacy" oszlopot, amibe a
-- migráció EGYSZER beírja az eredeti értéket (csak ha még NULL). A visszaút:
--     update public.students set status = status_legacy
--       where status_legacy is not null;      -- előbb a triggert kikapcsolva
-- A fájl végén szereplő public.status_model_rollback() ezt meg is teszi.
--
-- ---------------------------------------------------------------------------
-- JOGOSULTSÁG
-- ---------------------------------------------------------------------------
-- Épít a 11_rbac_additive.sql students_protect_identity triggerére: az NEM
-- ügyintézőnek már ma visszaírja a status és a tuitionFee régi értékét, tehát
-- a jelentkező a fő láncot nem tudja mozgatni. A triggerek nevei úgy vannak
-- megválasztva, hogy a PostgreSQL ábécésorrendje a helyes sorrendet adja:
--     students_protect_identity_trg  (11) → a status visszaáll nem-ügyintézőnél
--     students_protect_tracks_trg    (25) → a három sáv visszaáll ugyanígy
--     students_status_guard_trg      (25) → a fő lánc átmenetellenőrzése
--     students_track_guard_trg       (25) → a három sáv átmenetellenőrzése
--
-- IDEMPOTENS: kétszer lefuttatva ugyanaz az eredmény (mérve, ON_ERROR_STOP=1).
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. A triggerek eldobása a fájl elején
-- ---------------------------------------------------------------------------
-- Az adatátvezetés (3. szakasz) maga is UPDATE a students táblán, és a régi
-- értékekből ('Paid', 'Missing Info') nem vezet megengedett átmenet. A guard
-- triggereket ezért az átvezetés ELŐTT dobjuk el, és csak utána hozzuk létre.
-- Újrafuttatáskor ugyanez történik, az átvezetés viszont már 0 sort érint.
drop trigger if exists students_status_guard_trg   on public."students";
drop trigger if exists students_track_guard_trg    on public."students";
drop trigger if exists students_protect_tracks_trg on public."students";
drop trigger if exists students_status_insert_trg  on public."students";

-- ---------------------------------------------------------------------------
-- 1. A megengedett státuszok KATALÓGUSA
-- ---------------------------------------------------------------------------
-- Tábla és nem CHECK constraint: új állapotot (pl. 'Withdrawn') egy INSERT-tel
-- fel lehet venni, migráció és táblaátírás nélkül. A felület ugyanebből a
-- sorrendből és címkékből dolgozik (app.jsx STUDENT_STATUSES).
create table if not exists public.student_status (
  code        text primary key,
  label_hu    text    not null,
  label_en    text    not null,
  sort_order  integer not null,
  is_terminal boolean not null default false,  -- nincs előrefelé átmenet
  tone        text    not null default 'slate', -- felületi színkulcs
  note        text
);

insert into public.student_status (code, label_hu, label_en, sort_order, is_terminal, tone, note) values
  ('Draft',                  'Piszkozat',                  'Draft',                  1, false, 'slate',   'A jelentkező elkezdte, de még nem adta be.'),
  ('Submitted',              'Beadva',                     'Submitted',              2, false, 'indigo',  'Dokumentum-ellenőrzésre vár — ez a napi munka bemenete.'),
  ('Documents checked',      'Dokumentumok ellenőrizve',   'Documents checked',      3, false, 'sky',     'A dokumentumok rendben, mehet a bírálatra.'),
  ('Nominated',              'Bírálatra jelölve',          'Nominated',              4, false, 'violet',  'A bírálat előtt/alatt. Innen ágazik el a döntés.'),
  ('Conditionally accepted', 'Feltételesen felvéve',       'Conditionally accepted', 5, false, 'amber',   'Feltételes felvételi levél kiállítva.'),
  ('Accepted',               'Felvéve',                    'Accepted',               6, true,  'emerald', 'Végleges felvétel. A beiratkozás utáni sávok innen indulnak.'),
  ('Failed',                 'Elutasítva',                 'Failed',                 7, true,  'red',     'VÉGÁLLAPOT (D1). Csak explicit újranyitással hagyható el.')
on conflict (code) do update set
  label_hu    = excluded.label_hu,
  label_en    = excluded.label_en,
  sort_order  = excluded.sort_order,
  is_terminal = excluded.is_terminal,
  tone        = excluded.tone,
  note        = excluded.note;

-- ---------------------------------------------------------------------------
-- 2. A megengedett ÁTMENETEK
-- ---------------------------------------------------------------------------
-- is_backward = true: hibajavító visszalépés. Megengedett, de CSAK
-- ügyintézőnek, és minden ilyen lépés bekerül az "auditLogs"-ba.
create table if not exists public.student_status_transition (
  from_code   text    not null references public.student_status(code) on update cascade on delete cascade,
  to_code     text    not null references public.student_status(code) on update cascade on delete cascade,
  is_backward boolean not null default false,
  note        text,
  primary key (from_code, to_code)
);

insert into public.student_status_transition (from_code, to_code, is_backward, note) values
  -- előre
  ('Draft',                  'Submitted',              false, 'A jelentkező beadja.'),
  ('Submitted',              'Documents checked',      false, 'Az ügyintéző lezárja a dokumentum-ellenőrzést.'),
  ('Documents checked',      'Nominated',              false, 'Bírálatra jelölés.'),
  ('Nominated',              'Conditionally accepted', false, 'A bírálat pozitív ága (D1).'),
  ('Nominated',              'Failed',                 false, 'A bírálat elutasító ága (D1) — végállapot.'),
  ('Conditionally accepted', 'Accepted',               false, 'A feltétel teljesült, végleges felvétel.'),
  ('Conditionally accepted', 'Failed',                 false, 'A feltétel nem teljesült — végállapot.'),
  -- vissza (hibajavítás, ügyintézőnek, naplózva)
  ('Submitted',              'Draft',                  true,  'Tévesen beadottnak jelölt jelentkezés visszanyitása.'),
  ('Documents checked',      'Submitted',              true,  'Az ellenőrzés újranyitása (utólag kiderült hiány).'),
  ('Nominated',              'Documents checked',      true,  'A jelölés visszavonása.'),
  ('Conditionally accepted', 'Nominated',              true,  'A feltételes döntés visszavonása.'),
  ('Accepted',               'Conditionally accepted', true,  'A végleges felvétel visszavonása.'),
  ('Failed',                 'Nominated',              true,  'A D1 szerinti EXPLICIT ÚJRANYITÁS — csak így hagyható el a Failed.')
on conflict (from_code, to_code) do update set
  is_backward = excluded.is_backward,
  note        = excluded.note;

-- ---------------------------------------------------------------------------
-- 3. Az oszlopok és a MEGLÉVŐ ÉRTÉKEK ÁTVEZETÉSE
-- ---------------------------------------------------------------------------
alter table public."students" add column if not exists "status_legacy"  text;
alter table public."students" add column if not exists "visa_state"     text;
alter table public."students" add column if not exists "deferral_state" text;
alter table public."students" add column if not exists "refund_state"   text;

comment on column public."students"."status_legacy" is
  'A 25_status_model.sql előtti eredeti status érték. Csak egyszer íródik (ha NULL). A visszaút: public.status_model_rollback().';

-- Az eredeti érték mentése — kizárólag azoknál, ahol még nincs mentés.
-- Újrafuttatáskor ez 0 sort érint, tehát a mentés nem íródik felül a
-- már átvezetett értékkel.
update public."students"
   set "status_legacy" = "status"
 where "status_legacy" is null;

-- A leképezés. Az indoklás a fájl fejlécében.
update public."students" set "status" = 'Submitted' where "status" = 'Missing Info';
update public."students" set "status" = 'Accepted'  where "status" = 'Paid';
update public."students" set "status" = 'Failed'    where "status" = 'Rejected';

-- Bármi más ismeretlen érték (elgépelés, régi kísérlet) 'Draft'-ra esik, hogy
-- a katalógus zárt maradjon. A status_legacy megőrzi az eredetit.
update public."students" s
   set "status" = 'Draft'
 where "status" is null
    or not exists (select 1 from public.student_status c where c.code = s."status");

-- ---------------------------------------------------------------------------
-- 4. A HÁROM SÁV katalógusa és átmenetei (C2 · D2)
-- ---------------------------------------------------------------------------
-- Egy közös táblapár, 'track' oszloppal kulcsolva — a három sáv szerkezete
-- azonos (lineáris lánc), csak a hossza más. A "nincs sáv" (NULL) állapotot a
-- táblákban az üres sztring képviseli, mert a NULL nem lehet elsődleges kulcs
-- része; a triggerek coalesce(...,'')-lel normalizálnak.
create table if not exists public.student_track_state (
  track       text    not null,
  code        text    not null,
  label_hu    text    not null,
  label_en    text    not null,
  sort_order  integer not null,
  is_terminal boolean not null default false,
  tone        text    not null default 'slate',
  primary key (track, code)
);

create table if not exists public.student_track_transition (
  track       text    not null,
  from_code   text    not null default '',   -- '' = a sáv még nem indult (NULL)
  to_code     text    not null,              -- '' = a sáv törlése
  is_backward boolean not null default false,
  note        text,
  primary key (track, from_code, to_code)
);

insert into public.student_track_state (track, code, label_hu, label_en, sort_order, is_terminal, tone) values
  -- vízum
  ('visa',     'waiting',               'Vízumra vár',            'Waiting for visa',      1, false, 'amber'),
  ('visa',     'accepted',              'Vízum megadva',          'Visa accepted',         2, true,  'emerald'),
  ('visa',     'rejected',              'Vízum elutasítva',       'Visa rejected',         3, true,  'red'),
  -- halasztás
  ('deferral', 'requested',             'Halasztást kért',        'Deferral requested',    1, false, 'amber'),
  ('deferral', 'letter_sent',           'Halasztási levél kiküldve','Deferral letter sent',2, true,  'emerald'),
  -- visszatérítés
  ('refund',   'requested',             'Visszatérítést kért',    'Refund requested',      1, false, 'amber'),
  ('refund',   'bank_details_needed',   'Bankadat bekérve',       'Bank details requested',2, false, 'amber'),
  ('refund',   'bank_details_provided', 'Bankadat megadva',       'Bank details provided', 3, false, 'sky'),
  ('refund',   'forwarded_to_finance',  'Pénzügyre továbbítva',   'Forwarded to finance',  4, false, 'violet'),
  ('refund',   'processed',             'Kifizetve',              'Refund processed',      5, true,  'emerald')
on conflict (track, code) do update set
  label_hu    = excluded.label_hu,
  label_en    = excluded.label_en,
  sort_order  = excluded.sort_order,
  is_terminal = excluded.is_terminal,
  tone        = excluded.tone;

insert into public.student_track_transition (track, from_code, to_code, is_backward, note) values
  -- vízum
  ('visa',     '',                      'waiting',               false, 'A sáv indítása: beadott vízumkérelem.'),
  ('visa',     'waiting',               'accepted',              false, null),
  ('visa',     'waiting',               'rejected',              false, null),
  ('visa',     'accepted',              'waiting',               true,  'Tévesen rögzített döntés visszavonása.'),
  ('visa',     'rejected',              'waiting',               true,  'Fellebbezés / új kérelem.'),
  ('visa',     'waiting',               '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('visa',     'accepted',              '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('visa',     'rejected',              '',                      true,  'A sáv törlése (tévesen nyitva).'),
  -- halasztás
  ('deferral', '',                      'requested',             false, 'A sáv indítása: halasztási kérelem érkezett.'),
  ('deferral', 'requested',             'letter_sent',           false, null),
  ('deferral', 'letter_sent',           'requested',             true,  'A levél visszavonása.'),
  ('deferral', 'requested',             '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('deferral', 'letter_sent',           '',                      true,  'A sáv törlése (tévesen nyitva).'),
  -- visszatérítés
  ('refund',   '',                      'requested',             false, 'A sáv indítása: visszatérítési kérelem.'),
  ('refund',   'requested',             'bank_details_needed',   false, null),
  ('refund',   'bank_details_needed',   'bank_details_provided', false, 'EZT a lépést a jelentkező is megteheti.'),
  ('refund',   'bank_details_provided', 'forwarded_to_finance',  false, null),
  ('refund',   'forwarded_to_finance',  'processed',             false, null),
  ('refund',   'bank_details_needed',   'requested',             true,  null),
  ('refund',   'bank_details_provided', 'bank_details_needed',   true,  'Hibás bankadat — újra bekérve.'),
  ('refund',   'forwarded_to_finance',  'bank_details_provided', true,  null),
  ('refund',   'processed',             'forwarded_to_finance',  true,  'Téves kifizetés visszavonása.'),
  ('refund',   'requested',             '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('refund',   'bank_details_needed',   '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('refund',   'bank_details_provided', '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('refund',   'forwarded_to_finance',  '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('refund',   'processed',             '',                      true,  'A sáv törlése (tévesen nyitva).')
on conflict (track, from_code, to_code) do update set
  is_backward = excluded.is_backward,
  note        = excluded.note;

-- ---------------------------------------------------------------------------
-- 5. Naplózó segédfüggvény
-- ---------------------------------------------------------------------------
-- Az "auditLogs" sémája a 01_schema_and_seed.sql-ből: id/timestamp/user/
-- action/target/changes, mind text. A seed 'LOG-2' sora pontosan ilyen
-- státuszváltást rögzít ('Submitted -> Accepted'), tehát a formátum adott.
create or replace function public.log_status_event(
  p_action  text,
  p_target  text,
  p_changes text
) returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public."auditLogs" ("id", "timestamp", "user", "action", "target", "changes")
  values (
    'LOG-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12),
    to_char(now(), 'YYYY.MM.DD HH24:MI'),
    coalesce(nullif(public.my_email(), ''), 'system (SQL)'),
    p_action,
    p_target,
    p_changes
  );
exception when others then
  -- A naplózás soha ne buktassa el a felvételi műveletet.
  null;
end
$$;

-- ---------------------------------------------------------------------------
-- 6. A FŐ LÁNC állapotgépe
-- ---------------------------------------------------------------------------
create or replace function public.students_status_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_from     text := coalesce(old."status", 'Draft');
  v_backward boolean;
  v_found    boolean := false;
  v_allowed  text;
begin
  if new."status" is not distinct from old."status" then
    return new;
  end if;

  -- 6.1 a célállapot benne van-e a katalógusban
  if new."status" is null
     or not exists (select 1 from public.student_status c where c.code = new."status") then
    raise exception
      'Ismeretlen felvételi státusz: "%". A megengedett értékek: %.',
      coalesce(new."status", '<NULL>'),
      (select string_agg(code, ', ' order by sort_order) from public.student_status)
      using errcode = '23514',
            hint    = 'A státuszok katalógusa: public.student_status.';
  end if;

  -- 6.2 megengedett-e az átmenet
  select true, t.is_backward
    into v_found, v_backward
    from public.student_status_transition t
   where t.from_code = v_from and t.to_code = new."status";

  if not coalesce(v_found, false) then
    select coalesce(string_agg(c.label_en || ' (' || c.code || ')', ', ' order by c.sort_order), '')
      into v_allowed
      from public.student_status_transition t
      join public.student_status c on c.code = t.to_code
     where t.from_code = v_from;

    raise exception
      'Tiltott státuszátmenet: "%" → "%". A(z) "%" állapotból ezek engedettek: %',
      v_from, new."status", v_from,
      case when v_allowed = '' or v_allowed is null
           then 'egy sem — ez végállapot, csak explicit újranyitással hagyható el.'
           else v_allowed end
      using errcode = '23514',
            hint    = 'A megengedett átmenetek: public.student_status_transition.';
  end if;

  -- 6.3 visszalépés: csak ügyintéző, és mindig naplózva
  if v_backward then
    if auth.uid() is not null and not public.is_staff() then
      raise exception
        'A visszalépés ("%" → "%") csak ügyintézői jogosultsággal végezhető.',
        v_from, new."status"
        using errcode = '42501';
    end if;
    perform public.log_status_event(
      'STUDENT_STATUS_ROLLBACK',
      coalesce(new."name", new."id"),
      v_from || ' -> ' || new."status" || ' (visszalépés / hibajavítás)'
    );
  else
    perform public.log_status_event(
      'STUDENT_STATUS_CHANGE',
      coalesce(new."name", new."id"),
      v_from || ' -> ' || new."status"
    );
  end if;

  return new;
end
$$;

-- Az INSERT is a katalógusra korlátozódik. Az app.jsx api.addStudent status
-- nélkül szúr be (app.jsx:283) — az ilyen sor 'Draft'-ként indul.
create or replace function public.students_status_insert_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new."status" is null or new."status" = '' then
    new."status" := 'Draft';
  end if;
  if not exists (select 1 from public.student_status c where c.code = new."status") then
    raise exception
      'Ismeretlen felvételi státusz új jelentkezőnél: "%". A megengedett értékek: %.',
      new."status",
      (select string_agg(code, ', ' order by sort_order) from public.student_status)
      using errcode = '23514';
  end if;
  -- Új jelentkezés csak a lánc elejéről indulhat.
  if new."status" not in ('Draft', 'Submitted') then
    raise exception
      'Új jelentkező csak "Draft" vagy "Submitted" állapotban hozható létre, nem "%"-ként.',
      new."status"
      using errcode = '23514';
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- 7. A HÁROM SÁV állapotgépe
-- ---------------------------------------------------------------------------
create or replace function public.check_track_transition(
  p_track  text,
  p_old    text,
  p_new    text,
  p_name   text
) returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_from    text := coalesce(p_old, '');
  v_to      text := coalesce(p_new, '');
  v_back    boolean;
  v_found   boolean := false;
  v_allowed text;
begin
  if v_from = v_to then
    return false;
  end if;

  if v_to <> '' and not exists (
       select 1 from public.student_track_state s where s.track = p_track and s.code = v_to) then
    raise exception
      'Ismeretlen "%" sáv-állapot: "%". A megengedett értékek: %.',
      p_track, v_to,
      (select string_agg(code, ', ' order by sort_order)
         from public.student_track_state where track = p_track)
      using errcode = '23514';
  end if;

  select true, t.is_backward
    into v_found, v_back
    from public.student_track_transition t
   where t.track = p_track and t.from_code = v_from and t.to_code = v_to;

  if not coalesce(v_found, false) then
    select coalesce(string_agg(case when t.to_code = '' then '(sáv törlése)' else t.to_code end,
                               ', ' order by t.to_code), '')
      into v_allowed
      from public.student_track_transition t
     where t.track = p_track and t.from_code = v_from;

    raise exception
      'Tiltott átmenet a "%" sávban: "%" → "%". Innen ezek engedettek: %',
      p_track,
      case when v_from = '' then '(nincs sáv)' else v_from end,
      case when v_to = ''   then '(sáv törlése)' else v_to end,
      case when v_allowed = '' or v_allowed is null then 'egy sem.' else v_allowed end
      using errcode = '23514',
            hint    = 'A sávok átmenetei: public.student_track_transition.';
  end if;

  perform public.log_status_event(
    case when v_back then 'STUDENT_TRACK_ROLLBACK' else 'STUDENT_TRACK_CHANGE' end,
    coalesce(p_name, '?'),
    p_track || ': ' ||
      case when v_from = '' then '(nincs)' else v_from end || ' -> ' ||
      case when v_to   = '' then '(nincs)' else v_to   end
  );
  return v_back;
end
$$;

create or replace function public.students_track_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_name text := coalesce(new."name", new."id");
begin
  -- D2: a vízum- és a halasztási sáv a beiratkozás utáni szakasz, tehát csak
  -- 'Accepted' fő státusz mellett nyitható. A visszatérítés ettől független
  -- (elutasított jelentkező is kérheti vissza a jelentkezési díjat).
  if coalesce(new."visa_state", '') <> coalesce(old."visa_state", '')
     and coalesce(new."visa_state", '') <> ''
     and new."status" <> 'Accepted' then
    raise exception
      'A vízum-sáv csak "Accepted" fő státusz mellett használható (a jelenlegi: "%").',
      new."status" using errcode = '23514';
  end if;
  if coalesce(new."deferral_state", '') <> coalesce(old."deferral_state", '')
     and coalesce(new."deferral_state", '') <> ''
     and new."status" <> 'Accepted' then
    raise exception
      'A halasztási sáv csak "Accepted" fő státusz mellett használható (a jelenlegi: "%").',
      new."status" using errcode = '23514';
  end if;

  perform public.check_track_transition('visa',     old."visa_state",     new."visa_state",     v_name);
  perform public.check_track_transition('deferral', old."deferral_state", new."deferral_state", v_name);
  perform public.check_track_transition('refund',   old."refund_state",   new."refund_state",   v_name);

  -- Az üres sztringet NULL-ra normalizáljuk: a felület "nincs sáv"-ként
  -- mindkettőt küldheti, az adatban viszont egyféle "nincs" legyen.
  if new."visa_state"     = '' then new."visa_state"     := null; end if;
  if new."deferral_state" = '' then new."deferral_state" := null; end if;
  if new."refund_state"   = '' then new."refund_state"   := null; end if;
  return new;
end
$$;

-- A három sáv ügyintézői döntés — a jelentkező nem írhatja. Egy kivétel: a
-- saját bankszámlaszámát ő adja meg, tehát a
-- bank_details_needed → bank_details_provided lépést megteheti.
-- Ugyanaz a minta, mint a 11-es students_protect_identity: nem hibát dobunk,
-- hanem visszaírjuk a régi értéket (a PATCH "1 sor"-t jelent vissza, de nem
-- változtat semmit).
create or replace function public.students_protect_tracks()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_staff() or auth.uid() is null then
    return new;
  end if;
  new."status_legacy"  := old."status_legacy";
  new."visa_state"     := old."visa_state";
  new."deferral_state" := old."deferral_state";
  if not (coalesce(old."refund_state", '') = 'bank_details_needed'
          and coalesce(new."refund_state", '') = 'bank_details_provided') then
    new."refund_state" := old."refund_state";
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- 8. A triggerek felkötése
-- ---------------------------------------------------------------------------
-- A nevek ábécésorrendje adja a helyes végrehajtási sorrendet, lásd a fejléc
-- "JOGOSULTSÁG" szakaszát.
create trigger students_protect_tracks_trg
  before update on public."students"
  for each row execute function public.students_protect_tracks();

create trigger students_status_guard_trg
  before update on public."students"
  for each row execute function public.students_status_guard();

create trigger students_track_guard_trg
  before update on public."students"
  for each row execute function public.students_track_guard();

create trigger students_status_insert_trg
  before insert on public."students"
  for each row execute function public.students_status_insert_guard();

-- ---------------------------------------------------------------------------
-- 9. RLS a katalógustáblákon
-- ---------------------------------------------------------------------------
-- A katalógus nyilvános olvasmány (a felület legördülői ebből épülnek), írni
-- viszont csak adminisztrátor tud. A 11-es is_admin() a SUPERADMIN/ADMIN.
alter table public.student_status             enable row level security;
alter table public.student_status_transition  enable row level security;
alter table public.student_track_state        enable row level security;
alter table public.student_track_transition   enable row level security;

do $$
declare t text;
begin
  foreach t in array array['student_status', 'student_status_transition',
                           'student_track_state', 'student_track_transition']
  loop
    execute format('drop policy if exists %I on public.%I', t || '_read',  t);
    execute format('drop policy if exists %I on public.%I', t || '_write', t);
    execute format(
      'create policy %I on public.%I for select to anon, authenticated using (true)',
      t || '_read', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())',
      t || '_write', t);
    execute format('grant select on public.%I to anon, authenticated', t);
  end loop;
end
$$;

grant execute on function public.log_status_event(text, text, text)                 to authenticated;
grant execute on function public.check_track_transition(text, text, text, text)     to authenticated;

-- ---------------------------------------------------------------------------
-- 10. VISSZAÚT
-- ---------------------------------------------------------------------------
-- A leképezés visszafordítása: kikapcsolja a guard-ot, visszaírja a mentett
-- értékeket, majd visszakapcsol. A sáv-oszlopokat MEGHAGYJA (adatvesztés
-- nélkül), csak a fő láncot állítja vissza a migráció előtti állapotra.
create or replace function public.status_model_rollback()
returns integer language plpgsql security definer set search_path = public as $$
declare v_rows integer;
begin
  alter table public."students" disable trigger students_status_guard_trg;
  update public."students"
     set "status" = "status_legacy"
   where "status_legacy" is not null
     and "status" is distinct from "status_legacy";
  get diagnostics v_rows = row_count;
  alter table public."students" enable trigger students_status_guard_trg;
  perform public.log_status_event('STATUS_MODEL_ROLLBACK', 'students',
                                  v_rows || ' sor visszaállítva a status_legacy oszlopból');
  return v_rows;
end
$$;

revoke all on function public.status_model_rollback() from public, anon, authenticated;

commit;


-- ############################################################
-- ###  21_echo_harden_submit.sql  (ISMÉTELT ZÁRÁS)
-- ############################################################

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


-- ============================================================
-- ÖSSZESÍTŐ ELLENŐRZÉS

-- ============================================================
select 'echo tábla'                as mit, count(*)::text as ertek, '25 körül' as elvart
  from information_schema.tables where table_schema='echo'
union all select 'publikus echo_ RPC',
  (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname like 'echo\_%'), '30 körül'
union all select 'echo séma zárva (anon)',
  (not has_schema_privilege('anon','echo','USAGE'))::text, 'true'
union all select 'echo_submit CSAK anon',
  (coalesce((select array_to_string(proacl,' ') from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and proname='echo_submit'),'') like '%anon=X%'
   and coalesce((select array_to_string(proacl,' ') from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and proname='echo_submit'),'') not like '%authenticated=X%')::text, 'true'
union all select 'időbélyeg a válaszsoron (0 kell)',
  (select count(*)::text from information_schema.columns
    where table_schema='echo' and table_name='response' and data_type like 'timestamp%'), '0'
union all select 'státusz-átmenet szabály',
  (select count(*)::text from information_schema.tables
    where table_schema='public' and table_name like '%status_transition%'), '1'
union all select 'beiratkozás utáni sávok',
  (select count(*)::text from information_schema.columns where table_schema='public'
    and table_name='students' and column_name in ('visa_state','deferral_state','refund_state')), '3'
union all select 'érvénytelen státuszú jelentkező (0 kell)',
  (select count(*)::text from public.students s
    where not exists (select 1 from public.student_status st where st.code = s.status)), '0';
