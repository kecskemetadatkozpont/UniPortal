-- ============================================================================
--  47_audience_list.sql — UniPortal / ECHO
--  KIK AZOK A HALLGATÓK — névsor a becslés mögé
-- ============================================================================
--
--  MIT AD
--  (1) echo_audience_target_students() — a szerkesztőben, a MÉG NEM MENTETT
--      célközönséghez: kik kapnák meg.
--  (2) echo_campaign_students() — a kampány "Jogosult hallgató" kártyája mögé:
--      kik kapják meg TÉNYLEGESEN, az alkalmassági lista szerint.
--  A kettő szándékosan külön van, mert más forrásból dolgozik: az első a
--  javasolt listából számol, a második az echo.participation soraiból. Ha a
--  kettő eltér, az azt jelenti, hogy a mentés óta nem épült újra az
--  alkalmasság — ezt látni KELL, nem elfedni.
--
--  AMIT SZÁNDÉKOSAN NEM AD: hogy ki KÜLDTE BE a kérdőívet.
--  Az echo.participation tárolja a 'submitted' jelzőt (kell, különben nem
--  lehetne a kétszeres kitöltést megakadályozni), de ennek BÖNGÉSZHETŐ
--  listája más irányból nyitja meg ugyanazt, amit a k-anonimitási küszöbök
--  védenek: egy 3 fős kurzuson a "ki töltötte ki" és a közzétett eredmény
--  együtt visszafejthető. A névsor tehát azt mondja meg, KIT ÉRINT a kampány,
--  nem azt, hogy ki mit tett.
--
--  ELŐFELTÉTEL: a RUN_ALL_45_46.sql már lefutott. Idempotens, csak olvas.
-- ============================================================================


-- ------------------------------------------------------------
-- 1. A célzott hallgatók halmaza — EGY forrásból
-- ------------------------------------------------------------
-- Ezt a logikát eddig az echo_audience_preview() törzse tartalmazta. Most
-- kiemeljük, mert a becslés és a névsor ugyanabból kell hogy dolgozzon —
-- különben a "268 hallgató" és a mögötte megnyíló lista el tud csúszni
-- egymástól, és nem derül ki, melyik hazudik.
create or replace function echo.audience_target(p_campaign uuid, p_items jsonb)
returns table (student_key uuid, kurzus int)
language plpgsql stable
set search_path = echo, public, pg_temp
as $$
declare
  c         echo.campaign%rowtype;
  v_courses uuid[];
  v_groups  text[];
  v_users   uuid[];
  v_who     uuid[];
  v_has_c   boolean;
  v_has_w   boolean;
begin
  select * into c from echo.campaign where id = p_campaign;
  if not found then return; end if;

  -- Harom kulon lekerdezes: a csoport azonositoja szoveg, a kurzuse uuid, es
  -- egyetlen SELECT-ben a ::uuid kasztolas a csoportsorokon is lefuthatna a
  -- FILTER elott. A sima WHERE viszont a sorokat elobb szuri ki.
  select coalesce(array_agg((x->>'id')::uuid), '{}'::uuid[]) into v_courses
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
   where x->>'kind' = 'course' and coalesce(x->>'id','') <> '';
  select coalesce(array_agg(x->>'id'), '{}'::text[]) into v_groups
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
   where x->>'kind' = 'group' and coalesce(x->>'id','') <> '';
  select coalesce(array_agg((x->>'id')::uuid), '{}'::uuid[]) into v_users
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
   where x->>'kind' = 'user' and coalesce(x->>'id','') <> '';

  v_has_c := coalesce(array_length(v_courses, 1), 0) > 0;
  v_has_w := coalesce(array_length(v_groups, 1), 0) > 0
             or coalesce(array_length(v_users, 1), 0) > 0;

  select coalesce(array_agg(distinct s.id), '{}'::uuid[]) into v_who
    from (
      select m.profile_id as id from public.user_group_member m
       where m.group_id = any(v_groups)
      union
      select p.id from public.profiles p
        join public.user_group g on g.id = any(v_groups) and g.tipus = 'szabaly'
       where public.group_rule_matches(g.szabaly, p.id)
      union
      select u from unnest(v_users) u
    ) s
   where s.id is not null;

  -- A kurzusszam a CELZOTT halmazon belul ertendo: nem az osszes felvett
  -- kurzusa, hanem az, ahany kerdoivet ettol a kampanytol kapna.
  return query
  with cel as (
    select k.id from echo.course k
     where (    (v_has_c and k.id = any(v_courses))
            or (not v_has_c and k.term = c.term))
  )
  select e.student_key, count(distinct e.course_id)::int
    from echo.enrollment e join cel on cel.id = e.course_id
   where e.status = 'active'
     and (not v_has_w or e.student_key = any(v_who))
   group by e.student_key;
end $$;


-- Az echo_audience_preview() mostantol EBBOL veszi a letszamot, hogy a szam
-- es a mogotte megnyilo nevsor ne tudjon szetcsuszni.
create or replace function public.echo_audience_preview(p_campaign uuid, p_items jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c          echo.campaign%rowtype;
  v_courses  uuid[];
  v_groups   text[];
  v_users    uuid[];
  v_who      int;
  v_has_c    boolean;
  v_has_w    boolean;
  v_kurzus   int;
  v_hallgato int;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  select * into c from echo.campaign where id = p_campaign;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;
  if p_items is not null and jsonb_typeof(p_items) <> 'array' then
    raise exception 'ECHO_BAD_INPUT: a p_items tomb kell legyen.';
  end if;

  select coalesce(array_agg((x->>'id')::uuid), '{}'::uuid[]) into v_courses
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
   where x->>'kind' = 'course' and coalesce(x->>'id','') <> '';
  select coalesce(array_agg(x->>'id'), '{}'::text[]) into v_groups
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
   where x->>'kind' = 'group' and coalesce(x->>'id','') <> '';
  select coalesce(array_agg((x->>'id')::uuid), '{}'::uuid[]) into v_users
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
   where x->>'kind' = 'user' and coalesce(x->>'id','') <> '';

  v_has_c := coalesce(array_length(v_courses, 1), 0) > 0;
  v_has_w := coalesce(array_length(v_groups, 1), 0) > 0
             or coalesce(array_length(v_users, 1), 0) > 0;

  select count(*) into v_kurzus from echo.course k
   where (    (v_has_c and k.id = any(v_courses))
          or (not v_has_c and k.term = c.term));

  select count(*) into v_hallgato from echo.audience_target(p_campaign, p_items);

  -- Hany emberre illeszkedik egyaltalan a kijeloles (kurzustol fuggetlenul).
  select count(distinct s.id) into v_who
    from (
      select m.profile_id as id from public.user_group_member m
       where m.group_id = any(v_groups)
      union
      select p.id from public.profiles p
        join public.user_group g on g.id = any(v_groups) and g.tipus = 'szabaly'
       where public.group_rule_matches(g.szabaly, p.id)
      union
      select u from unnest(v_users) u
    ) s
   where s.id is not null;

  return jsonb_build_object(
    'campaign_id', p_campaign, 'term', c.term,
    'kurzus_szukitve', v_has_c,
    'hallgato_szukitve', v_has_w,
    'legfeljebb_kurzus', v_kurzus,
    'legfeljebb_hallgato', v_hallgato,
    'celzott_szemely', coalesce(v_who, 0),
    'megjegyzes', 'FELSO KORLAT: a kizarasi szabalyok csak az alkalmassag '
               || 'ujraepitesekor futnak le.');
end $$;


-- ------------------------------------------------------------
-- 2. A javasolt célközönség névsora (szerkesztő)
-- ------------------------------------------------------------
create or replace function public.echo_audience_target_students(
  p_campaign uuid, p_items jsonb, p_q text default null, p_limit int default 300
) returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_q   text := nullif(btrim(coalesce(p_q, '')), '');
  v_lim int  := least(greatest(coalesce(p_limit, 300), 1), 2000);
  v_ossz int;
  v_out jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  if not exists (select 1 from echo.campaign where id = p_campaign) then
    raise exception 'ECHO_CAMPAIGN_NOT_FOUND';
  end if;

  select count(*) into v_ossz from echo.audience_target(p_campaign, p_items);

  select coalesce(jsonb_agg(x order by x->>'nev'), '[]'::jsonb) into v_out
  from (
    select jsonb_build_object(
             'profile_id', p.id,
             'nev', coalesce(p.name, p.email),
             'email', p.email,
             'tagozat', a.tagozat, 'kepzesi_szint', a.kepzesi_szint,
             'szak', a.szak, 'kar', a.kar,
             'kurzus', t.kurzus) as x
      from echo.audience_target(p_campaign, p_items) t
      join public.profiles p on p.id = t.student_key
      left join public.student_attributes a on a.profile_id = p.id
     where v_q is null or p.email ilike '%'||v_q||'%' or coalesce(p.name,'') ilike '%'||v_q||'%'
     order by coalesce(p.name, p.email)
     limit v_lim
  ) s;

  return jsonb_build_object('ossz', v_ossz, 'mutatva', jsonb_array_length(v_out),
                            'hatar', v_lim, 'sorok', v_out);
end $$;


-- ------------------------------------------------------------
-- 3. A kampány TÉNYLEGES jogosultjai (a "Jogosult hallgató" kártya mögé)
-- ------------------------------------------------------------
-- Ez az echo.participation-ből dolgozik, tehát azt mutatja, ami az utolsó
-- alkalmasság-újraépítés óta érvényes. A 'submitted' jelzőt SZÁNDÉKOSAN nem
-- adjuk ki — lásd a fájl fejlécét.
create or replace function public.echo_campaign_students(
  p_campaign uuid, p_q text default null, p_limit int default 300
) returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_q   text := nullif(btrim(coalesce(p_q, '')), '');
  v_lim int  := least(greatest(coalesce(p_limit, 300), 1), 2000);
  v_ossz int;
  v_out jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  if not exists (select 1 from echo.campaign where id = p_campaign) then
    raise exception 'ECHO_CAMPAIGN_NOT_FOUND';
  end if;

  select count(distinct student_key) into v_ossz
    from echo.participation where campaign_id = p_campaign and eligible;

  select coalesce(jsonb_agg(x order by x->>'nev'), '[]'::jsonb) into v_out
  from (
    select jsonb_build_object(
             'profile_id', p.id,
             'nev', coalesce(p.name, p.email),
             'email', p.email,
             'tagozat', a.tagozat, 'kepzesi_szint', a.kepzesi_szint,
             'szak', a.szak, 'kar', a.kar,
             'kurzus', count(distinct pa.course_id)) as x
      from echo.participation pa
      join public.profiles p on p.id = pa.student_key
      left join public.student_attributes a on a.profile_id = p.id
     where pa.campaign_id = p_campaign and pa.eligible
       and (v_q is null or p.email ilike '%'||v_q||'%' or coalesce(p.name,'') ilike '%'||v_q||'%')
     group by p.id, p.name, p.email, a.tagozat, a.kepzesi_szint, a.szak, a.kar
     order by coalesce(p.name, p.email)
     limit v_lim
  ) s;

  return jsonb_build_object('ossz', v_ossz, 'mutatva', jsonb_array_length(v_out),
                            'hatar', v_lim, 'sorok', v_out);
end $$;


do $jog$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('echo_audience_preview','echo_audience_target_students',
                         'echo_campaign_students')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon',   f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end
$jog$;


-- ============================================================================
--  ELLENŐRZÉS — futtasd le, és küldd vissza a táblát
-- ============================================================================
select 'RPC: '||p.proname as mit_ellenorzunk,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon is' else 'csak authenticated' end as ertek,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'OK' else 'HIBA' end as allapot
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public'
   and p.proname in ('echo_audience_preview','echo_audience_target_students','echo_campaign_students')
union all
select 'a becsles es a nevsor EGY forrasbol dolgozik',
       case when prosrc like '%echo.audience_target(p_campaign, p_items)%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%echo.audience_target(p_campaign, p_items)%' then 'OK'
            else 'HIBA — a szam es a lista szetcsuszhat' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_audience_preview'
union all
select 'a nevsor NEM adja ki a bekuldest',
       case when prosrc like '%submitted%' then 'kiadja' else 'nem adja ki' end,
       case when prosrc like '%submitted%' then 'HIBA — nevtelenseget sert' else 'OK' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_campaign_students'
union all
-- A ket fuggvenyt NEM hivjuk meg itt: mindketto auth.uid()-ot kovetel, az SQL
-- Editorban viszont az NULL, tehat ECHO_NOT_AUTHENTICATED-del elhasalna az
-- egesz ellenorzes. (Ezt sajat magamon mertem meg.) Helyette azt nezzuk, hogy
-- a nevsor is a kozos echo.audience_target()-bol dolgozik-e.
select 'a nevsor is a kozos forrasbol dolgozik',
       case when prosrc like '%echo.audience_target(p_campaign, p_items)%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%echo.audience_target(p_campaign, p_items)%' then 'OK'
            else 'HIBA — a szam es a lista szetcsuszhat' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_audience_target_students'
union all
select 'echo.audience_target letezik',
       count(*)::text||' valtozat',
       case when count(*) = 1 then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='echo' and p.proname='audience_target';
