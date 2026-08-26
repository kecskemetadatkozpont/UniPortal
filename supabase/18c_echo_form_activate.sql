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
--      MIÉRT KELL: már NEM az adatbázis kényszeríti ki — egy félévre azóta
--      bármennyi kampány lehet (41_campaign_term_free.sql). A lezárás itt
--      szándékos döntés: a kérdőívet LECSERÉLTED, tehát a régi verzió ne
--      gyűjtsön tovább válaszokat ugyanarra a kurzusra. Ha a régi kampány
--      futva maradna, ugyanaz a hallgató kétszer értékelné ugyanazt az
--      oktatót két különböző kérdőívvel, és az eredmény egyik verzióhoz
--      sem tartozna tisztán. Aki SZÁNDÉKOSAN akar két párhuzamos kérdőívet,
--      az két külön kampányt hoz létre — azt már semmi nem tiltja.
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
