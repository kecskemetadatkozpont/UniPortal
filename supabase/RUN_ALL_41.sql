-- ============================================================================
-- RUN_ALL_41.sql — UniPortal
--
--   41_campaign_term_free.sql  a félév nem foglalható erőforrás többé
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--   + a végén a MODUL SAJÁT ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a RUN_ALL_40.sql már lefutott.
-- Idempotens. Egy indexet dob el és egy függvényt cserél — adatot nem módosít,
-- meglévő kampányt nem érint.
--
-- MIT CSINÁL EGY MONDATBAN: eddig egy félévre egyetlen aktív kampány létezhetett;
-- ezután bármennyi. A félév a kampány metaadata marad, nem foglalható erőforrás.
-- ============================================================================


-- ============================================================
--  41_campaign_term_free.sql
--  A FÉLÉV NEM FOGLALHATÓ ERŐFORRÁS
-- ============================================================
--
--  MI VÁLTOZIK
--  Eddig egy félévre EGYETLEN aktív kampány létezhetett. Ezt két helyen
--  kényszerítettük ki:
--    (1) echo_campaign_active_term_uidx — egyedi index az echo.campaign
--        (term) oszlopon, ahol state in ('draft','open','closed','processing')
--    (2) az echo_campaign_create() ECHO_TERM_BUSY ellenőrzése
--  Mindkettő megszűnik. Egy félévre ezután bármennyi kampány futhat, a félév
--  pedig az marad, ami valójában: metaadat a kampányon.
--
--  MI VOLT AZ EREDETI INDOK, ÉS MIÉRT NEM ELÉG
--  Az echo.eligibility_rebuild() a kampány félévére szűrve gyűjti a kurzusokat
--  (where c.term = v_term), tehát két kampány ugyanarra a félévre ugyanazt a
--  kurzushalmazt célozza meg, és a hallgató két kérdőívet kap ugyanarról az
--  oktatóról. Ez IGAZ, és a változás után is így lesz — csak nem hiba, hanem
--  a szándék: félévközi visszajelzés és félév végi értékelés, vagy egy kar
--  saját mérőeszköze a központi kérdőív mellett. Az echo_my_courses() minden
--  sorban adja a campaign_id-t és a kampány nevét, a hallgatói felület pedig
--  campaign_id|course_id párral kulcsol, tehát a két kérdőív a felületen
--  megkülönböztethető marad.
--
--  AMI NEM VÁLTOZIK
--  Az echo_form_activate() továbbra is LEPECSÉTELI a futó kampányt, mielőtt
--  az új sablonverzióval újat nyit. Ezt eddig ez az index kényszerítette ki,
--  most viszont szándékos döntés marad: a kérdőívet lecserélted, tehát a régi
--  ne gyűjtsön tovább ugyanarra a kurzusra. Aki párhuzamos kérdőívet akar,
--  az két külön kampányt hoz létre — azt már semmi nem tiltja.
--
--  MELLÉKHATÁS, AMIT KEZELNI KELL
--  Az echo_campaign_create() a kampánykódot kereséssel állítja elő
--  ('OMHV-2025-26-2', ütközésnél '-1', '-2', ...). A keresés és a beszúrás
--  nem atomi. Eddig ezt a félév-index takarta el: két egyidejű létrehozás
--  közül a második úgyis elbukott. Most viszont mindkettő jogos, és a
--  második az echo_campaign_code_uidx-en hasalna el nyers unique_violation
--  hibával. Ezért a függvény tranzakció végéig tartó tanácsadó zárat vesz
--  fel. A kampánylétrehozás ritka művelet, a sorosítás ára elhanyagolható.
--
--  VISSZAÁLLÍTÁS: 41_rollback.sql (a fájl alján, kikommentezve).
-- ============================================================


-- ------------------------------------------------------------
-- 1. Az index eldobása
-- ------------------------------------------------------------
-- Az index lehet, hogy létre sem jött: a 18a migráció NOTICE-szal átlépte,
-- ha már akkor is volt két aktív kampány egy félévre. Az 'if exists' emiatt
-- kell, nem óvatosságból.
drop index if exists echo.echo_campaign_active_term_uidx;


-- ------------------------------------------------------------
-- 2. Az echo_campaign_create() az ECHO_TERM_BUSY ellenőrzés nélkül
-- ------------------------------------------------------------
-- A törzs szó szerint a 18a_echo_campaign.sql-ből származik, hogy a friss
-- telepítés és az élő adatbázis ne csússzon el egymástól.

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


  -- Kód: emberi olvasásra, egyedi. Az echo.slug() a magyar ékezeteket is kezeli.
  -- A kereses+beszuras nem atomi: ket egyidejű letrehozas ugyanazt a kodot
  -- talalhatna szabadnak, es a masodik az echo_campaign_code_uidx-en hasalna
  -- el. Eddig ezt a felev-index takarta el (a masodik kampany ugyis elbukott);
  -- most, hogy egy felevre tobb kampany lehet, ez a verseny valodiva valt.
  -- Tranzakcio vegeig tarto tanacsado zar: a kampanyletrehozas ritka, a
  -- sorositas ara elhanyagolhato.
  perform pg_advisory_xact_lock(hashtextextended('echo_campaign_create', 0));
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

-- A jog nem öröklődik a create or replace után automatikusan minden
-- beállításban — kiírjuk, hogy ne csendben tűnjön el.
revoke all on function public.echo_campaign_create(text,text,uuid,timestamptz,timestamptz) from public;
grant execute on function public.echo_campaign_create(text,text,uuid,timestamptz,timestamptz) to authenticated;




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


-- ============================================================
--  ELLENŐRZÉS — futtasd le, és küldd vissza a táblát
-- ============================================================
select 'az index eldobva' as mit_ellenorzunk,
       coalesce((select indexname from pg_indexes
                  where schemaname='echo' and indexname='echo_campaign_active_term_uidx'),
                '(nincs)') as ertek,
       case when not exists (select 1 from pg_indexes
                              where schemaname='echo'
                                and indexname='echo_campaign_active_term_uidx')
            then 'OK' else 'HIBA — meg letezik' end as allapot
union all
select 'a TERM_BUSY ellenorzes eltunt a fuggvenybol',
       case when prosrc like '%ECHO_TERM_BUSY%' then 'meg benne van' else '(nincs)' end,
       case when prosrc like '%ECHO_TERM_BUSY%' then 'HIBA' else 'OK' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_campaign_create'
union all
select 'a kodutkozes elleni zar bekerult',
       case when prosrc like '%pg_advisory_xact_lock%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%pg_advisory_xact_lock%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_campaign_create'
union all
select 'a code egyedisege megmaradt (ez kell is)',
       coalesce((select indexname from pg_indexes
                  where schemaname='echo' and indexname='echo_campaign_code_uidx'), '(nincs)'),
       case when exists (select 1 from pg_indexes
                          where schemaname='echo' and indexname='echo_campaign_code_uidx')
            then 'OK' else 'HIBA — eltunt' end
union all
select 'hany felevre van tobb aktiv kampany',
       count(*)::text,
       'INFO — ez mostantol megengedett'
  from (select term from echo.campaign
         where state in ('draft','open','closed','processing')
         group by term having count(*) > 1) t;


-- ============================================================
--  VISSZAÁLLÍTÁS  (csak ha kell — kikommentezve)
-- ============================================================
-- Az index csak akkor jon vissza, ha nincs ket aktiv kampany egy felevre.
-- Ha van, eloszor azokat kell rendezni.
--
-- create unique index echo_campaign_active_term_uidx
--   on echo.campaign (term)
--   where state in ('draft','open','closed','processing');


-- ===========================================================================
-- A POSTGREST SÉMA-GYORSÍTÓTÁRÁNAK FRISSÍTÉSE
-- ===========================================================================
-- A PostgREST gyorsítótárazza, milyen függvények léteznek, és rendszerint
-- magától frissíti DDL után — de ez késhet vagy kimaradhat. Ilyenkor a
-- felület "Could not find the function ... in the schema cache" (PGRST202)
-- hibát ad egy olyan függvényre, ami VALÓJÁBAN létezik. Egy valós
-- bejelentésnél pontosan ez történt az echo_my_enrollments()-szel.
-- Ártalmatlan akkor is, ha nem volt rá szükség.
notify pgrst, 'reload schema';
