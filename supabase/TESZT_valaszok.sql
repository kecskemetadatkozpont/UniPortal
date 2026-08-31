-- ============================================================================
--  TESZT_valaszok.sql — UniPortal / ECHO
--  MESTERSÉGES KITÖLTÉS EGY TESZTKAMPÁNYHOZ
-- ============================================================================
--
--  MIT CSINÁL: a megadott kampány minden jogosult (kurzus, hallgató) párjához
--  eldönti, hogy "kitöltötte-e", és a kitöltésekhez válaszsorokat ír az
--  echo.response táblába — ugyanolyan alakban, ahogy az echo_submit() tenné.
--
--  EZ NEM ÉLES ADAT. Csak akkor futtasd, ha a kampány kifejezetten tesztre
--  való. A fájl alján ott a VISSZAVONÁS, ami pontosan ezeket a sorokat törli.
--
--  MIÉRT NEM AZ echo_submit()-EN KERESZTÜL: az anon jogú, jegyet kér, nonce-t
--  éget, és hallgatónkénti bejelentkezést igényelne. Négyszáz fiókkal ez nem
--  megoldható egy SQL-ablakból. A KIMENET viszont azonos: ugyanaz a két
--  sorfajta (kurzusszintű + oktatószintű), ugyanazokkal a mezőkkel.
--
--  A NÉVTELENSÉG NEM SÉRÜL: az echo.response-ban nincs hallgatói hivatkozás
--  (se oszlop, se időbélyeg) — ez a tábla eleve így készült. A generátor sem
--  ír be ilyet: a "ki töltötte ki" információ csak az echo.participation
--  submitted jelzőjében marad, ahol eddig is volt.
--
--  A KITÖLTÉSI ARÁNY KURZUSONKÉNT VÁLTOZIK (35%–95%), hogy a k-anonimitási
--  sávok mindegyike előálljon, és ne egyforma legyen minden kurzus.
-- ============================================================================

do $gen$
declare
  -- ---- ÁLLÍTHATÓ ----
  c_kod        text    := 'TESZT-2026';   -- melyik kampány
  c_mag        double precision := 0.42;  -- véletlenmag: ugyanaz a mag = ugyanaz az eredmény
  -- -------------------

  v_c          echo.campaign%rowtype;
  v_compiled   jsonb;
  v_kurzus_q   jsonb;      -- kurzusszintű kérdések
  v_oktato_q   jsonb;      -- oktatószintű kérdések (repeat = 'teacher')
  r            record;
  q            jsonb;
  v_ans        jsonb;
  v_tans       jsonb;
  v_arany      double precision;
  v_att        text;
  v_n_valasz   int := 0;
  v_n_kitolto  int := 0;
  v_v          double precision;
  v_opt        jsonb;
  v_szoveg     text[] := array[
    'Nagyon jó volt a hangulat az órákon, sokat tanultam.',
    'Az elméleti rész néha túl gyors volt, de a gyakorlat kárpótolt.',
    'Több példafeladat jó lenne a félév közben.',
    'Az oktató mindig segítőkész volt, ha kérdésem volt.',
    'A számonkérés arányos volt az órai anyaggal.',
    'A jegyzet elavult, érdemes lenne frissíteni.',
    'A csoportmunka jól szervezett volt.',
    'Kevesebb elmélet, több valós eset kellene.',
    'Az online anyagok nagyon hasznosak voltak.',
    'A félév vége felé összetorlódtak a beadandók.'];
begin
  perform setseed(c_mag);

  select * into v_c from echo.campaign where code = c_kod;
  if not found then raise exception 'Nincs ilyen kampany: %', c_kod; end if;
  if v_c.template_version_id is null then
    raise exception 'A(z) % kampanyhoz nincs kerdoiv rendelve.', c_kod;
  end if;
  select compiled into v_compiled from echo.template_version where id = v_c.template_version_id;

  -- A ket kerdeshalmaz UGYANAZZAL a feltetellel all elo, mint az
  -- echo.results_build()-ben: repeat = 'teacher' -> oktatoszintu, minden mas
  -- kurzusszintu, es az 'attendance' egyik halmazba sem tartozik (az a sav).
  select coalesce(jsonb_agg(qq), '[]'::jsonb) into v_kurzus_q
    from jsonb_array_elements(v_compiled->'sections') s,
         jsonb_array_elements(s->'questions') qq
   where coalesce(qq->>'repeat','') <> 'teacher' and coalesce(qq->>'id','') <> 'attendance';

  select coalesce(jsonb_agg(qq), '[]'::jsonb) into v_oktato_q
    from jsonb_array_elements(v_compiled->'sections') s,
         jsonb_array_elements(s->'questions') qq
   where coalesce(qq->>'repeat','') = 'teacher';

  raise notice 'Kampany: % | kurzusszintu kerdes: % | oktatoszintu kerdes: %',
               c_kod, jsonb_array_length(v_kurzus_q), jsonb_array_length(v_oktato_q);
  if jsonb_array_length(v_oktato_q) = 0 then
    raise notice 'FIGYELEM: ennek a kerdoivnek NINCS oktatoszintu kerdese, ezert a '
                 'Teaching Results-ban csak KURZUSSZINTU eredmeny fog latszani.';
  end if;

  -- Kurzusonkent mas kitoltesi arany, de determinisztikusan: a kurzus
  -- azonositojanak hashe adja, tehat ujrafuttatasnal ugyanaz jon ki.
  for r in
    select p.course_id, p.student_key,
           0.35 + 0.60 * ((abs(hashtextextended(p.course_id::text, 0)) % 1000) / 1000.0) as arany
      from echo.participation p
     where p.campaign_id = v_c.id and p.eligible
     order by p.course_id, p.student_key
  loop
    v_arany := r.arany;
    if random() > v_arany then continue; end if;   -- ez a hallgato nem toltott ki
    v_n_kitolto := v_n_kitolto + 1;

    -- --- oralatogatasi sav ---
    v_v := random();
    v_att := case when v_v < 0.12 then '0-33' when v_v < 0.38 then '34-66' else '67-100' end;

    -- --- kurzusszintu valaszok ---
    v_ans := '{}'::jsonb;
    for q in select * from jsonb_array_elements(v_kurzus_q) loop
      if q->>'type' = 'scale' then
        -- Pozitiv fele huzo eloszlas: az 5 es a 4 a gyakori, az 1 ritka.
        v_v := random();
        v_ans := v_ans || jsonb_build_object(q->>'id',
                 case when v_v < 0.42 then 5 when v_v < 0.74 then 4
                      when v_v < 0.90 then 3 when v_v < 0.97 then 2 else 1 end);
      elsif q->>'type' in ('single','choice') then
        select o into v_opt from jsonb_array_elements(q->'options') o
         order by random() limit 1;
        if v_opt is not null then
          v_ans := v_ans || jsonb_build_object(q->>'id',
                   coalesce(v_opt->>'value', v_opt->>'id', v_opt#>>'{}'));
        end if;
      elsif q->>'type' in ('longtext','text') then
        -- Csak a kitoltok harmada ir szoveget — ez a valosaghoz kozelebb all,
        -- es igy a k_text kuszob is ertelmes helyeken fog harapni.
        if random() < 0.33 then
          v_ans := v_ans || jsonb_build_object(q->>'id',
                   v_szoveg[1 + floor(random() * array_length(v_szoveg,1))::int]);
        end if;
      end if;
    end loop;

    insert into echo.response (campaign_id, course_id, teacher_id, template_version_id,
                               scope, attendance_band, answers)
    values (v_c.id, r.course_id, null, v_c.template_version_id, 'course', v_att, v_ans);
    v_n_valasz := v_n_valasz + 1;

    -- --- oktatoszintu valaszsorok, kurzusonkent minden velemenyezheto oktatora ---
    if jsonb_array_length(v_oktato_q) > 0 then
      declare t record;
      begin
        for t in select el.teacher_id from echo.eligibility el
                  where el.campaign_id = v_c.id and el.course_id = r.course_id
        loop
          v_tans := '{}'::jsonb;
          for q in select * from jsonb_array_elements(v_oktato_q) loop
            if q->>'type' = 'scale' then
              v_v := random();
              v_tans := v_tans || jsonb_build_object(q->>'id',
                       case when v_v < 0.40 then 5 when v_v < 0.72 then 4
                            when v_v < 0.90 then 3 when v_v < 0.97 then 2 else 1 end);
            elsif q->>'type' in ('single','choice') then
              select o into v_opt from jsonb_array_elements(q->'options') o
               order by random() limit 1;
              if v_opt is not null then
                v_tans := v_tans || jsonb_build_object(q->>'id',
                         coalesce(v_opt->>'value', v_opt->>'id', v_opt#>>'{}'));
              end if;
            elsif q->>'type' in ('longtext','text') then
              if random() < 0.28 then
                v_tans := v_tans || jsonb_build_object(q->>'id',
                         v_szoveg[1 + floor(random() * array_length(v_szoveg,1))::int]);
              end if;
            end if;
          end loop;
          -- attendance_band SZANDEKOSAN null az oktatoi soron: a 15_echo_core.sql
          -- 6.2 pontja szerint az oralatogatas kurzusszintu adat.
          insert into echo.response (campaign_id, course_id, teacher_id, template_version_id,
                                     scope, attendance_band, answers)
          values (v_c.id, r.course_id, t.teacher_id, v_c.template_version_id, 'teacher', null,
                  v_tans || jsonb_build_object('skipped', false, 'skip_reason', null));
          v_n_valasz := v_n_valasz + 1;
        end loop;
      end;
    end if;

    -- A reszveteli naplo: ugyanaz, amit az echo_issue_ticket + mark_submitted tenne.
    update echo.participation
       set attempted = true, submitted = true,
           attempted_on = coalesce(attempted_on, current_date),
           submitted_on = coalesce(submitted_on, current_date),
           ticket_count = greatest(ticket_count, 1)
     where campaign_id = v_c.id and course_id = r.course_id and student_key = r.student_key;
  end loop;

  raise notice 'KESZ: % kitolto, % valaszsor.', v_n_kitolto, v_n_valasz;
end
$gen$;


-- ============================================================================
--  MI LETT BELŐLE — futtasd le, és küldd vissza a táblát
-- ============================================================================
select 'kitoltok / jogosultak' as mit_nezunk,
       (count(*) filter (where p.submitted))::text||' / '||count(*)::text as ertek,
       round(100.0 * count(*) filter (where p.submitted) / nullif(count(*),0))::text||'%' as arany
  from echo.participation p join echo.campaign c on c.id=p.campaign_id
 where c.code = 'TESZT-2026' and p.eligible
union all
select 'valaszsorok (kurzusszintu / oktatoszintu)',
       (count(*) filter (where r.scope='course'))::text||' / '||
       (count(*) filter (where r.scope='teacher'))::text, ''
  from echo.response r join echo.campaign c on c.id=r.campaign_id
 where c.code = 'TESZT-2026'
union all
select 'kurzus, amin van valasz', count(distinct r.course_id)::text, ''
  from echo.response r join echo.campaign c on c.id=r.campaign_id where c.code='TESZT-2026'
union all
select 'k-sav: '||sav, count(*)::text||' kurzus', ''
  from (select r.course_id,
               case when count(*) filter (where r.scope='course') < 5 then 'a 3-4 fos savban'
                    when count(*) filter (where r.scope='course') < 10 then 'az 5-9 fos savban'
                    else '10+ valasz (minden latszik)' end sav
          from echo.response r join echo.campaign c on c.id=r.campaign_id
         where c.code='TESZT-2026' group by r.course_id) x
 group by sav;


-- ============================================================================
--  VISSZAVONÁS  (csak ha kell — kikommentezve)
-- ============================================================================
-- Az echo.response-ban NINCS forrasjelolo (a nevtelenseg miatt), ezert a
-- torles kampanyszintu. Ez a teszt kampanynal helyes: minden valasza generalt.
-- ELES kampanyon SOHA ne futtasd.
--
-- begin;
--   delete from echo.response r using echo.campaign c
--    where c.id = r.campaign_id and c.code = 'TESZT-2026';
--   update echo.participation p set attempted = false, submitted = false,
--          attempted_on = null, submitted_on = null, ticket_count = 0
--     from echo.campaign c
--    where c.id = p.campaign_id and c.code = 'TESZT-2026';
-- commit;
