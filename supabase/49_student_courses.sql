-- ============================================================================
--  49_student_courses.sql — UniPortal / ECHO
--  "MELYIK az az N kurzus?" — a névsor sorainak kibontása
-- ============================================================================
--
--  MIÉRT KÜLÖN HÍVÁS, ÉS NEM A LISTÁBAN
--  A névsor legfeljebb 300 sort ad, és a kurzuscímkéket beletenni kézenfekvő
--  lenne. MÉRVE viszont: a TESZT-2026 kampányban a jogosultak kurzusszáma
--  1-től 20-ig terjed, és a címkék együtt ~145 kB-ot tennének a mai ~79 kB-os
--  válaszhoz — vagyis a HÁROMSZOROSÁRA nőne, olyan adatért, amit a legtöbb
--  sornál soha nem nyit ki senki. Ezért kattintásra töltjük be.
--
--  EGY FÜGGVÉNY, KÉT FORRÁS — ugyanaz a kettősség, mint a névsornál:
--    p_items = NULL  -> a kampány TÉNYLEGES jogosultsága (echo.participation)
--    p_items megadva -> a JAVASOLT, még nem mentett célközönség
--  Így a kibontott lista mindig ugyanabból dolgozik, mint a fölötte álló szám.
--
--  ELŐFELTÉTEL: a RUN_ALL_48.sql már lefutott. Idempotens, csak olvas.
-- ============================================================================

create or replace function public.echo_student_courses(
  p_campaign uuid,
  p_profile  uuid,
  p_items    jsonb default null
) returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  c         echo.campaign%rowtype;
  v_courses uuid[];
  v_has_c   boolean;
  v_out     jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_admin() then raise exception 'ECHO_FORBIDDEN'; end if;
  select * into c from echo.campaign where id = p_campaign;
  if not found then raise exception 'ECHO_CAMPAIGN_NOT_FOUND'; end if;

  if p_items is null then
    -- A TÉNYLEGES állapot: amit az utolsó alkalmasság-újraépítés rögzített.
    select coalesce(jsonb_agg(jsonb_build_object(
             'course_id', k.id, 'code', k.code, 'name', k.name_hu,
             'term', k.term, 'lang', k.lang,
             'oktatok', (select coalesce(string_agg(
                                  t.name || ' (' || round(el.share_pct)::text || '%)',
                                  ', ' order by el.share_pct desc, t.name), '—')
                           from echo.eligibility el
                           join echo.teacher t on t.id = el.teacher_id
                          where el.campaign_id = p_campaign and el.course_id = k.id))
           order by k.code), '[]'::jsonb) into v_out
      from echo.participation pa
      join echo.course k on k.id = pa.course_id
     where pa.campaign_id = p_campaign and pa.student_key = p_profile and pa.eligible;
  else
    if jsonb_typeof(p_items) <> 'array' then
      raise exception 'ECHO_BAD_INPUT: a p_items tomb kell legyen.';
    end if;
    -- A JAVASOLT celkozonseg kurzus-hatokore. A 'KI' szurest itt nem kell
    -- ujra elvegezni: a hivo mar egy CELZOTT hallgato sorat bontja ki.
    select coalesce(array_agg((x->>'id')::uuid), '{}'::uuid[]) into v_courses
      from jsonb_array_elements(p_items) x
     where x->>'kind' = 'course' and coalesce(x->>'id','') <> '';
    v_has_c := coalesce(array_length(v_courses, 1), 0) > 0;

    select coalesce(jsonb_agg(jsonb_build_object(
             'course_id', k.id, 'code', k.code, 'name', k.name_hu,
             'term', k.term, 'lang', k.lang,
             -- A jelenlegi oktatoi kotes; alkalmassagi sor meg nincs, mert a
             -- celkozonseg nincs mentve. Ezt a felulet ki is mondja.
             'oktatok', (select coalesce(string_agg(
                                  t.name || ' (' || round(ct.share_pct)::text || '%)',
                                  ', ' order by ct.share_pct desc, t.name), '—')
                           from echo.course_teacher ct
                           join echo.teacher t on t.id = ct.teacher_id
                          where ct.course_id = k.id))
           order by k.code), '[]'::jsonb) into v_out
      from echo.enrollment e
      join echo.course k on k.id = e.course_id
     where e.student_key = p_profile
       and e.status = 'active'
       and (    (v_has_c and k.id = any(v_courses))
            or (not v_has_c and k.term = c.term));
  end if;

  return jsonb_build_object(
    'profile_id', p_profile,
    'forras', case when p_items is null then 'alkalmassag' else 'javaslat' end,
    'kurzusok', v_out);
end $$;

do $jog$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'echo_student_courses'
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
select 'echo_student_courses letezik' as mit_ellenorzunk,
       count(*)::text||' valtozat' as ertek,
       case when count(*) = 1 then 'OK' else 'HIBA' end as allapot
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_student_courses'
union all
select 'csak authenticated hivhatja',
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon is' else 'csak authenticated' end,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_student_courses'
union all
select 'stable (csak olvas)',
       case p.provolatile when 's' then 'stable' when 'v' then 'volatile' else 'immutable' end,
       case when p.provolatile = 's' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_student_courses'
union all
select 'mindket forrast kezeli (alkalmassag / javaslat)',
       case when prosrc like '%echo.participation%' and prosrc like '%echo.enrollment%'
            then 'megvan' else '(hianyos)' end,
       case when prosrc like '%echo.participation%' and prosrc like '%echo.enrollment%'
            then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_student_courses';
