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
