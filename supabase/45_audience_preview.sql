-- ============================================================================
--  45_audience_preview.sql — UniPortal / ECHO
--  A CÉLKÖZÖNSÉG BECSLÉSE MENTÉS ELŐTT
-- ============================================================================
--
--  MI A BAJ A MOSTANIVAL
--  Az echo_campaign_audience() a MENTETT sorokból számol, ezért a szerkesztőben
--  a "legfeljebb X kurzus · Y hallgató" csak mentés és visszanyitás után
--  frissült. Aki épp kijelöl egy csoportot, pont akkor nem látja, hány embert
--  érint — vagyis a szám akkor hiányzik, amikor a döntés születik.
--
--  MIÉRT ÚJ FÜGGVÉNY, ÉS NEM PARAMÉTER A RÉGIN
--  Az echo_campaign_audience() egy paraméterrel bővítve ÚJ függvényt hozna
--  létre a régi mellett (a plpgsql nem cseréli le eltérő szignatúrán), és a
--  PostgREST a névre illesztve nem tudná eldönteni, melyiket hívja. Ugyanez a
--  csapda ütött a 44-esben az echo_course_students()-nél.
--
--  A SZÁM ITT IS FELSŐ KORLÁT: a kizárási szabályok (létszám, órarendi info,
--  vizsgakurzus, oktatói óraarány) csak az alkalmasság újraépítésekor futnak.
--
--  ELŐFELTÉTEL: a RUN_ALL_42.sql már lefutott. Idempotens, csak olvas.
-- ============================================================================

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
  v_who      uuid[];
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

  -- HÁROM KÜLÖN lekérdezés, nem egy 'filter'-es aggregátum. A csoport
  -- azonosítója szöveg ('GRP...'), a kurzusé és a felhasználóé uuid: egyetlen
  -- SELECT-ben a ::uuid kasztolás a csoportsorokon is lefuthatna a FILTER
  -- előtt, és elhasalna. A sima WHERE viszont a sorokat AZ aggregátum
  -- kiértékelése előtt szűri ki.
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

  -- A 'KI' halmaz ugyanúgy áll össze, mint az echo.audience_profiles()-ban,
  -- csak a mentett sorok helyett a javasolt listából. Kézi csoportnál tagsági
  -- sor, szabály alapúnál a szabály illeszkedése.
  select coalesce(array_agg(distinct s.id), '{}'::uuid[]) into v_who
    from (
      select m.profile_id as id
        from public.user_group_member m
       where m.group_id = any(v_groups)
      union
      select p.id
        from public.profiles p
        join public.user_group g on g.id = any(v_groups) and g.tipus = 'szabaly'
       where public.group_rule_matches(g.szabaly, p.id)
      union
      select u from unnest(v_users) u
    ) s
   where s.id is not null;

  with cel as (
    select k.id from echo.course k
     where (    (v_has_c and k.id = any(v_courses))
            or (not v_has_c and k.term = c.term))
  )
  select count(*) into v_kurzus from cel;

  with cel as (
    select k.id from echo.course k
     where (    (v_has_c and k.id = any(v_courses))
            or (not v_has_c and k.term = c.term))
  )
  select count(distinct e.student_key) into v_hallgato
    from echo.enrollment e join cel on cel.id = e.course_id
   where e.status = 'active'
     and (not v_has_w or e.student_key = any(v_who));

  return jsonb_build_object(
    'campaign_id', p_campaign, 'term', c.term,
    'kurzus_szukitve', v_has_c,
    'hallgato_szukitve', v_has_w,
    'legfeljebb_kurzus', v_kurzus,
    'legfeljebb_hallgato', v_hallgato,
    -- A feloldott létszám külön is: egy szabály alapú csoportnál ez mondja meg,
    -- hogy egyáltalán hány emberre illeszkedik a szabály — akkor is, ha közülük
    -- senki nincs beiratkozva a célzott kurzusokra. A kettő eltérése magyaráz.
    'celzott_szemely', coalesce(array_length(v_who, 1), 0),
    'megjegyzes', 'FELSO KORLAT: a kizarasi szabalyok csak az alkalmassag '
               || 'ujraepitesekor futnak le.');
end $$;

do $jog$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'echo_audience_preview'
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon',   f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end
$jog$;



-- ------------------------------------------------------------
--  A célközönség mentése ÉPÍTSE ÚJRA az alkalmasságot
-- ------------------------------------------------------------
-- A törzs a 42_campaign_editor.sql-ből származik; a változás a végén az
-- eligibility_rebuild() hívása.

create or replace function public.echo_campaign_audience_set(p_campaign uuid, p_items jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c      echo.campaign%rowtype;
  v_it   jsonb;
  v_kind text;
  v_id   text;
  v_n    int := 0;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;

  select * into c from echo.campaign where id = p_campaign for update;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;
  if c.state <> 'draft' then
    raise exception 'ECHO_CAMPAIGN_RUNNING: a celkozonseg csak "draft" allapotban '
                    'modosithato (a kampany most "%"). Futo kampanyon a mar kiadott '
                    'jegyek valnanak ervenytelenne.', c.state;
  end if;
  if p_items is not null and jsonb_typeof(p_items) <> 'array' then
    raise exception 'ECHO_BAD_INPUT: a p_items tomb kell legyen.';
  end if;

  delete from echo.campaign_audience where campaign_id = p_campaign;

  for v_it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_kind := v_it->>'kind';
    v_id   := v_it->>'id';
    if coalesce(v_id, '') = '' then
      raise exception 'ECHO_BAD_INPUT: hianyzo azonosito a "%s" tetelnel.', v_kind;
    end if;

    if v_kind = 'course' then
      if not exists (select 1 from echo.course where id = v_id::uuid) then
        raise exception 'ECHO_COURSE_NOT_FOUND: %', v_id;
      end if;
      insert into echo.campaign_audience (campaign_id, kind, course_id, added_by)
      values (p_campaign, 'course', v_id::uuid, auth.uid())
      on conflict do nothing;

    elsif v_kind = 'group' then
      if not exists (select 1 from public.user_group where id = v_id) then
        raise exception 'ECHO_GROUP_NOT_FOUND: %', v_id;
      end if;
      insert into echo.campaign_audience (campaign_id, kind, group_id, added_by)
      values (p_campaign, 'group', v_id, auth.uid())
      on conflict do nothing;

    elsif v_kind = 'user' then
      if not exists (select 1 from public.profiles where id = v_id::uuid) then
        raise exception 'ECHO_PROFILE_NOT_FOUND: %', v_id;
      end if;
      insert into echo.campaign_audience (campaign_id, kind, profile_id, added_by)
      values (p_campaign, 'user', v_id::uuid, auth.uid())
      on conflict do nothing;

    else
      raise exception 'ECHO_BAD_INPUT: ismeretlen celkozonseg-tipus: "%". '
                      'Ervenyes: course, group, user.', coalesce(v_kind, '(null)');
    end if;
    v_n := v_n + 1;
  end loop;

  insert into echo.campaign_log (campaign_id, from_state, to_state, irany, actor_key, actor_email, detail)
  values (p_campaign, c.state, c.state, 'celkozonseg', auth.uid(),
          (select email from public.profiles where id = auth.uid()),
          jsonb_build_object('tetel', v_n, 'items', coalesce(p_items, '[]'::jsonb)));

  perform echo.log_access('echo_campaign_audience_set', p_campaign, null, null, 'campaign');

  -- AZONNAL ujraepitjuk az alkalmassagot. Enelkul a kampany "Jogosult par" es
  -- "Jogosult hallgato" szamai a MENTES UTAN IS a regi celkozonseget mutatjak,
  -- mert azok az echo.eligibility / echo.participation tablakbol jonnek, azokat
  -- pedig kizarolag az eligibility_rebuild() irja. A felhasznalo joggal hiszi,
  -- hogy nem tortent semmi.
  -- Biztonsagos: ez a fuggveny csak 'draft' allapotban fut le (lasd fent),
  -- tehat nincs meg kiadott jegy, amit ervenytelenithetne.
  perform echo.eligibility_rebuild(p_campaign);

  return public.echo_campaign_audience(p_campaign);
end $$;


-- ============================================================================
--  ELLENŐRZÉS
-- ============================================================================
select 'echo_audience_preview letezik' as mit_ellenorzunk,
       count(*)::text||' valtozat' as ertek,
       case when count(*) = 1 then 'OK' else 'HIBA' end as allapot
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_audience_preview'
union all
select 'csak authenticated hivhatja',
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon is' else 'csak authenticated' end,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_audience_preview'
union all
select 'a celkozonseg mentese ujraepiti az alkalmassagot',
       case when prosrc like '%eligibility_rebuild(p_campaign)%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%eligibility_rebuild(p_campaign)%' then 'OK'
            else 'HIBA — a Jogosult hallgato szam nem frissulne' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_campaign_audience_set'
union all
select 'stable (nem ir)',
       case when p.provolatile = 's' then 'stable' else 'volatile' end,
       case when p.provolatile = 's' then 'OK' else 'HIBA — irhatna' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_audience_preview';
