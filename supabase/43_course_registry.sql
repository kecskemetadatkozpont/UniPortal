-- ============================================================================
--  43_course_registry.sql — UniPortal / ECHO
--  KURZUSNYILVÁNTARTÁS: metaadat, oktatók, hallgatói névsor, dokumentumok
-- ============================================================================
--
--  MI VOLT MÁR MEG, ÉS MI HIÁNYZOTT
--  Az adatmodell nagy része létezett: echo.course (kód, név, félév, nyelv,
--  szervezeti egység, létszám, órarendi info, vizsgakurzus), echo.course_teacher
--  (ki tanítja, milyen óraaránnyal) és echo.enrollment (KI vette fel MELYIK
--  kurzust — a félév a kurzuson van). Ezekre épül az alkalmassági motor és a
--  42-es migráció célközönség-választója is.
--  Ami hiányzott: (1) felület, amin ez látszik és kézzel karbantartható,
--  (2) kurzusleírás, (3) tananyagok és fájlok.
--
--  KI LÁTJA A DOKUMENTUMOKAT
--  Ügyintéző (is_staff) és a kurzus OKTATÓJA. A hallgató NEM — ez belső
--  nyilvántartás, nem oktatási platform.
--  Az is_staff() nem tartalmazza a TEACHER szerepet, ezért az oktatói
--  hozzáférést külön kell megadni. Az echo.teacher.profile_id köti az oktatót
--  a portálfiókhoz; ez ma ki van töltve, ahol az oktatónak van fiókja.
--
--  ELŐFELTÉTEL: a RUN_ALL_42.sql már lefutott. Idempotens.
-- ============================================================================


-- ------------------------------------------------------------
-- 1. Kurzusleírás
-- ------------------------------------------------------------
alter table echo.course add column if not exists leiras    text;
alter table echo.course add column if not exists leiras_en text;


-- ------------------------------------------------------------
-- 2. Kurzusdokumentumok
-- ------------------------------------------------------------
-- A FÁJL a 'documents' tárolóban van, itt csak a HIVATKOZÁS és a metaadat. Így
-- a jogosultság két helyen dől el (tárolópolicy + RPC), de az igazság egy
-- helyen van: ha a sor eltűnik, a fájl árván marad, de nem szivárog — a
-- tárolópolicy önmagában is zárt.
create table if not exists echo.course_document (
  id           uuid primary key default gen_random_uuid(),
  course_id    uuid not null references echo.course(id) on delete cascade,
  cim          text not null,
  fajlnev      text not null,
  path         text not null,
  mime         text,
  meret        bigint,
  fajta        text not null default 'egyeb'
                 check (fajta in ('tanterv','tananyag','leiras','egyeb')),
  uploaded_by  uuid,
  uploaded_at  timestamptz not null default now()
);
create index if not exists course_document_course_idx on echo.course_document (course_id);
create unique index if not exists course_document_path_uidx on echo.course_document (path);
alter table echo.course_document enable row level security;


-- ------------------------------------------------------------
-- 3. „Ez az oktató tanítja ezt a kurzust?"
-- ------------------------------------------------------------
create or replace function echo.teaches(p_course uuid, p_profile uuid)
returns boolean language sql stable
set search_path = echo, public, pg_temp
as $$
  select exists (
    select 1 from echo.course_teacher ct
      join echo.teacher t on t.id = ct.teacher_id
     where ct.course_id = p_course
       and t.profile_id = p_profile
       and t.active
  )
$$;

-- A kurzus látható-e nekem egyáltalán. Egy helyen, hogy minden RPC ugyanazt
-- a feltételt használja.
create or replace function echo.course_visible(p_course uuid)
returns boolean language sql stable
set search_path = echo, public, pg_temp
as $$
  select public.is_staff() or echo.teaches(p_course, auth.uid())
$$;


-- ------------------------------------------------------------
-- 4. Tárolópolicy: az oktató lássa a SAJÁT kurzusa fájljait
-- ------------------------------------------------------------
-- Útvonal-konvenció:  <feltöltő-uid>/kurzus/<kurzus-id>/<fájl>
-- A meglévő "documents_read" policyt NEM írjuk át — RLS-ben több megengedő
-- policy VAGY kapcsolattal áll össze, tehát egy ÚJ policy tisztán additív.
-- Így ha ez elbukna jogosultság híján, a régi viselkedés érintetlen marad.
create or replace function echo.doc_course_teacher(p_name text)
returns boolean language plpgsql stable security definer
set search_path = echo, public, storage, pg_temp
as $$
declare v_p text[]; v_course uuid;
begin
  v_p := storage.foldername(p_name);
  if coalesce(array_length(v_p, 1), 0) < 3 or v_p[2] <> 'kurzus' then
    return false;
  end if;
  -- A harmadik szegmens elvileg uuid, de az útvonalat bárki megadhatja:
  -- a kasztolás hibája RLS-ben a LEKÉRDEZÉST döntené el, nem csak a sort.
  begin
    v_course := v_p[3]::uuid;
  exception when others then
    return false;
  end;
  return echo.teaches(v_course, auth.uid());
end $$;

do $pol$
begin
  begin
    execute $p$drop policy if exists "documents_read_course_teacher" on storage.objects$p$;
    execute $p$create policy "documents_read_course_teacher" on storage.objects
              for select to authenticated
              using (bucket_id = 'documents' and echo.doc_course_teacher(name))$p$;
  exception when insufficient_privilege then
    raise notice 'ECHO 43: a storage policy nem jott letre (nincs jog). Az oktatoi '
                 'fajlolvasast a Supabase felulet Storage > Policies pontjaban kell '
                 'felvenni; az ugyintezoi olvasas a meglevo documents_read policyval mukodik.';
  end;
end
$pol$;


-- ------------------------------------------------------------
-- 5. Olvasó RPC-k
-- ------------------------------------------------------------
-- Az ügyintéző MINDEN kurzust lát, az oktató CSAK a sajátjait. A szűrést a
-- lekérdezés végzi, nem a felület: így a böngésző konzoljából sem lehet
-- más kurzusát elkérni.
create or replace function public.echo_course_list(
  p_term  text default null,
  p_q     text default null,
  p_limit int  default 200
) returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_q     text := nullif(btrim(coalesce(p_q, '')), '');
  v_term  text := nullif(btrim(coalesce(p_term, '')), '');
  v_staff boolean := public.is_staff();
  v_me    uuid := auth.uid();
  v_lim   int  := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_out   jsonb;
begin
  if v_me is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not v_staff and not exists (select 1 from echo.teacher where profile_id = v_me and active) then
    raise exception 'ECHO_FORBIDDEN';
  end if;

  select coalesce(jsonb_agg(x order by x->>'term' desc, x->>'code'), '[]'::jsonb) into v_out
  from (
    select jsonb_build_object(
             'id', k.id, 'code', k.code, 'name_hu', k.name_hu, 'name_en', k.name_en,
             'term', k.term, 'lang', k.lang,
             'org_unit', o.name_hu,
             'letszam', k.letszam,
             'van_orarendi_info', k.van_orarendi_info,
             'vizsgakurzus', k.vizsgakurzus,
             'ext_source', k.ext_source,
             'oktato', (select count(*) from echo.course_teacher ct where ct.course_id = k.id),
             'hallgato', (select count(*) from echo.enrollment e
                           where e.course_id = k.id and e.status = 'active'),
             'dokumentum', (select count(*) from echo.course_document d where d.course_id = k.id),
             'sajat', echo.teaches(k.id, v_me)) as x
      from echo.course k
      left join echo.org_unit o on o.id = k.org_unit_id
     where (v_staff or echo.teaches(k.id, v_me))
       and (v_term is null or k.term = v_term)
       and (v_q is null or k.code ilike '%'||v_q||'%' or k.name_hu ilike '%'||v_q||'%'
                        or coalesce(k.name_en,'') ilike '%'||v_q||'%')
     order by k.term desc, k.code
     limit v_lim
  ) s;
  return v_out;
end $$;


create or replace function public.echo_course_get(p_course uuid)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare k echo.course%rowtype; v_out jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  select * into k from echo.course where id = p_course;
  if not found then raise exception 'ECHO_COURSE_NOT_FOUND'; end if;
  if not echo.course_visible(p_course) then raise exception 'ECHO_FORBIDDEN'; end if;

  select jsonb_build_object(
    'id', k.id, 'code', k.code, 'name_hu', k.name_hu, 'name_en', k.name_en,
    'term', k.term, 'lang', k.lang, 'org_unit_id', k.org_unit_id,
    'org_unit', (select name_hu from echo.org_unit where id = k.org_unit_id),
    'letszam', k.letszam,
    'van_orarendi_info', k.van_orarendi_info, 'vizsgakurzus', k.vizsgakurzus,
    'leiras', k.leiras, 'leiras_en', k.leiras_en,
    'ext_source', k.ext_source, 'ext_id', k.ext_id,
    'szerkesztheto', public.is_staff(),
    'oktatok', (select coalesce(jsonb_agg(jsonb_build_object(
                          'teacher_id', t.id, 'nev', t.name, 'title', t.title,
                          'email', t.email, 'share_pct', ct.share_pct, 'role', ct.role)
                        order by ct.share_pct desc, t.name), '[]'::jsonb)
                  from echo.course_teacher ct join echo.teacher t on t.id = ct.teacher_id
                 where ct.course_id = k.id),
    'hallgato_szam', (select count(*) from echo.enrollment e
                       where e.course_id = k.id and e.status = 'active'),
    'dokumentumok', (select coalesce(jsonb_agg(jsonb_build_object(
                          'id', d.id, 'cim', d.cim, 'fajlnev', d.fajlnev, 'path', d.path,
                          'mime', d.mime, 'meret', d.meret, 'fajta', d.fajta,
                          'uploaded_at', d.uploaded_at,
                          'feltolto', (select coalesce(pr.name, pr.email) from public.profiles pr
                                        where pr.id = d.uploaded_by))
                        order by d.uploaded_at desc), '[]'::jsonb)
                     from echo.course_document d where d.course_id = k.id),
    -- Kampányok, amikben ez a kurzus szerepel. A törlésnél ez a fék.
    'kampanyban', (select count(distinct el.campaign_id) from echo.eligibility el
                    where el.course_id = k.id)
  ) into v_out;
  return v_out;
end $$;


-- A kurzus hallgatói névsora. Az 'ext' oszlopokat szándékosan nem adjuk ki:
-- a névsor a NÉVRŐL szól, nem a forrásrendszer azonosítóiról.
create or replace function public.echo_course_students(
  p_course uuid, p_q text default null, p_limit int default 500
) returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_q   text := nullif(btrim(coalesce(p_q, '')), '');
  v_lim int  := least(greatest(coalesce(p_limit, 500), 1), 2000);
  v_out jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not echo.course_visible(p_course) then raise exception 'ECHO_FORBIDDEN'; end if;

  select coalesce(jsonb_agg(x order by x->>'nev'), '[]'::jsonb) into v_out
  from (
    select jsonb_build_object(
             'profile_id', p.id,
             'nev', coalesce(p.name, p.email),
             'email', p.email,
             'status', e.status,
             'tagozat', a.tagozat, 'kepzesi_szint', a.kepzesi_szint, 'szak', a.szak) as x
      from echo.enrollment e
      join public.profiles p on p.id = e.student_key
      left join public.student_attributes a on a.profile_id = p.id
     where e.course_id = p_course
       and (v_q is null or p.email ilike '%'||v_q||'%' or coalesce(p.name,'') ilike '%'||v_q||'%')
     order by coalesce(p.name, p.email)
     limit v_lim
  ) s;
  return v_out;
end $$;


-- Választható tételek: oktatók, még be nem iratkozott hallgatók, félévek.
create or replace function public.echo_course_options(
  p_kind text, p_course uuid default null, p_q text default null, p_limit int default 50
) returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_q   text := nullif(btrim(coalesce(p_q, '')), '');
  v_lim int  := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_out jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_staff() then raise exception 'ECHO_FORBIDDEN'; end if;

  if p_kind = 'teacher' then
    select coalesce(jsonb_agg(x order by x->>'cimke'), '[]'::jsonb) into v_out
    from (select jsonb_build_object('id', t.id, 'cimke', coalesce(t.title||' ','')||t.name,
                                    'reszlet', coalesce(t.email, t.code)) as x
            from echo.teacher t
           where t.active
             and (v_q is null or t.name ilike '%'||v_q||'%' or coalesce(t.email,'') ilike '%'||v_q||'%')
           order by t.name limit v_lim) s;

  elsif p_kind = 'student' then
    select coalesce(jsonb_agg(x order by x->>'cimke'), '[]'::jsonb) into v_out
    from (select jsonb_build_object('id', p.id, 'cimke', coalesce(p.name, p.email),
                                    'reszlet', p.email) as x
            from public.profiles p
           where p.role = 'STUDENT'
             and (p_course is null or not exists (
                    select 1 from echo.enrollment e
                     where e.course_id = p_course and e.student_key = p.id and e.status='active'))
             and (v_q is null or p.email ilike '%'||v_q||'%' or coalesce(p.name,'') ilike '%'||v_q||'%')
           order by coalesce(p.name, p.email) limit v_lim) s;

  elsif p_kind = 'group' then
    select coalesce(jsonb_agg(x order by x->>'cimke'), '[]'::jsonb) into v_out
    from (select jsonb_build_object('id', g.id, 'cimke', g.nev, 'reszlet', g.tipus) as x
            from public.user_group g
           where v_q is null or g.nev ilike '%'||v_q||'%'
           order by g.nev limit v_lim) s;

  elsif p_kind = 'term' then
    select coalesce(jsonb_agg(x order by x->>'cimke' desc), '[]'::jsonb) into v_out
    from (select jsonb_build_object('id', k.term, 'cimke', k.term,
                                    'reszlet', count(*)::text || ' kurzus') as x
            from echo.course k group by k.term) s;

  elsif p_kind = 'org_unit' then
    select coalesce(jsonb_agg(x order by x->>'cimke'), '[]'::jsonb) into v_out
    from (select jsonb_build_object('id', o.id, 'cimke', o.name_hu, 'reszlet', o.kind) as x
            from echo.org_unit o order by o.name_hu limit v_lim) s;

  else
    raise exception 'ECHO_BAD_INPUT: ismeretlen tipus: "%". Ervenyes: teacher, student, '
                    'group, term, org_unit.', coalesce(p_kind, '(null)');
  end if;
  return v_out;
end $$;


-- ------------------------------------------------------------
-- 6. Író RPC-k
-- ------------------------------------------------------------
-- Kurzus létrehozása és módosítása. p_id nélkül új jön létre.
create or replace function public.echo_course_save(
  p_id                uuid    default null,
  p_code              text    default null,
  p_name_hu           text    default null,
  p_name_en           text    default null,
  p_term              text    default null,
  p_lang              text    default null,
  p_org_unit_id       uuid    default null,
  p_letszam           int     default null,
  p_van_orarendi_info boolean default null,
  p_vizsgakurzus      boolean default null,
  p_leiras            text    default null,
  p_leiras_en         text    default null,
  p_clear             text[]  default null
) returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_clear text[] := coalesce(p_clear, '{}'::text[]);
  v_id    uuid;
  v_code  text := nullif(btrim(coalesce(p_code, '')), '');
  v_nev   text := nullif(btrim(coalesce(p_name_hu, '')), '');
  v_term  text := nullif(btrim(coalesce(p_term, '')), '');
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_staff() then raise exception 'ECHO_FORBIDDEN'; end if;

  if p_id is null then
    if v_code is null or v_nev is null or v_term is null then
      raise exception 'ECHO_BAD_INPUT: uj kurzushoz a kod, a magyar nev es a felev kotelezo.';
    end if;
    begin
      insert into echo.course (code, name_hu, name_en, term, lang, org_unit_id, letszam,
                               van_orarendi_info, vizsgakurzus, leiras, leiras_en, ext_source)
      values (v_code, v_nev, nullif(btrim(coalesce(p_name_en,'')),''), v_term,
              coalesce(nullif(btrim(coalesce(p_lang,'')),''), 'hu'),
              p_org_unit_id, p_letszam,
              coalesce(p_van_orarendi_info, true), coalesce(p_vizsgakurzus, false),
              nullif(btrim(coalesce(p_leiras,'')),''),
              nullif(btrim(coalesce(p_leiras_en,'')),''), 'manual')
      returning id into v_id;
    exception when unique_violation then
      raise exception 'ECHO_COURSE_DUPLICATE: a(z) "%" kod ebben a felevben (%) mar letezik. '
                      'A kurzuskod felevenkent egyedi.', v_code, v_term;
    end;
  else
    if not exists (select 1 from echo.course where id = p_id) then
      raise exception 'ECHO_COURSE_NOT_FOUND';
    end if;
    v_id := p_id;
    begin
      update echo.course set
        code              = coalesce(v_code, code),
        name_hu           = coalesce(v_nev, name_hu),
        name_en           = case when 'name_en' = any(v_clear) then null
                                 else coalesce(nullif(btrim(coalesce(p_name_en,'')),''), name_en) end,
        term              = coalesce(v_term, term),
        lang              = coalesce(nullif(btrim(coalesce(p_lang,'')),''), lang),
        org_unit_id       = case when 'org_unit' = any(v_clear) then null
                                 else coalesce(p_org_unit_id, org_unit_id) end,
        letszam           = case when 'letszam' = any(v_clear) then null
                                 else coalesce(p_letszam, letszam) end,
        van_orarendi_info = coalesce(p_van_orarendi_info, van_orarendi_info),
        vizsgakurzus      = coalesce(p_vizsgakurzus, vizsgakurzus),
        leiras            = case when 'leiras' = any(v_clear) then null
                                 else coalesce(nullif(btrim(coalesce(p_leiras,'')),''), leiras) end,
        leiras_en         = case when 'leiras_en' = any(v_clear) then null
                                 else coalesce(nullif(btrim(coalesce(p_leiras_en,'')),''), leiras_en) end
      where id = v_id;
    exception when unique_violation then
      raise exception 'ECHO_COURSE_DUPLICATE: ez a kod ebben a felevben mar letezik.';
    end;
  end if;

  perform echo.log_access('echo_course_save', null, v_id, null, 'course');
  return public.echo_course_get(v_id);
end $$;


-- Kurzus törlése. A FÉK: az echo.course idegen kulcsai KASZKÁDOLNAK az
-- eligibility, participation, exclusion_log, student_goal és draft táblákra —
-- egy törlés tehát csendben kampánytörténetet semmisítene meg. Csak az
-- echo.response van RESTRICT-tel védve, az viszont a legkésőbbi pillanatban
-- szólna. Ezért itt előre elutasítjuk, ha a kurzus bármelyik kampányban
-- szerepel; a helyes lépés ilyenkor nem a törlés.
create or replace function public.echo_course_delete(p_course uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare k echo.course%rowtype; v_k int; v_v int; v_h int;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_staff() then raise exception 'ECHO_FORBIDDEN'; end if;
  select * into k from echo.course where id = p_course;
  if not found then raise exception 'ECHO_COURSE_NOT_FOUND'; end if;

  select count(distinct campaign_id) into v_k from echo.eligibility where course_id = p_course;
  select count(*) into v_v from echo.response  where course_id = p_course;
  select count(*) into v_h from echo.enrollment where course_id = p_course;

  if v_k > 0 or v_v > 0 then
    raise exception 'ECHO_COURSE_IN_USE: a kurzus % kampanyban szerepel es % valasz tartozik '
                    'hozza. A torles kaszkadolna az alkalmassagi es reszveteli sorokra, '
                    'vagyis kampanytortenetet semmisitene meg. Ha a kurzus mar nem aktualis, '
                    'vedd ki a kesobbi kampanyok celkozonsegebol.', v_k, v_v;
  end if;

  delete from echo.course where id = p_course;
  perform echo.log_access('echo_course_delete', null, p_course, null, 'course');
  return jsonb_build_object('ok', true, 'code', k.code, 'torolt_beiratkozas', v_h);
end $$;


-- Oktató hozzárendelése / óraarány módosítása / levétele.
create or replace function public.echo_course_teacher_set(
  p_course uuid, p_teacher uuid,
  p_share numeric default null, p_role text default null, p_remove boolean default false
) returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_staff() then raise exception 'ECHO_FORBIDDEN'; end if;
  if not exists (select 1 from echo.course  where id = p_course)  then raise exception 'ECHO_COURSE_NOT_FOUND'; end if;
  if not exists (select 1 from echo.teacher where id = p_teacher) then raise exception 'ECHO_TEACHER_NOT_FOUND'; end if;

  if coalesce(p_remove, false) then
    delete from echo.course_teacher where course_id = p_course and teacher_id = p_teacher;
  else
    insert into echo.course_teacher (course_id, teacher_id, share_pct, role, ext_source)
    values (p_course, p_teacher, coalesce(p_share, 100), coalesce(nullif(p_role,''), 'oktato'), 'manual')
    on conflict (course_id, teacher_id) do update
      set share_pct = coalesce(p_share, echo.course_teacher.share_pct),
          role      = coalesce(nullif(p_role,''), echo.course_teacher.role);
  end if;
  perform echo.log_access('echo_course_teacher_set', null, p_course, null, 'course');
  return public.echo_course_get(p_course);
end $$;


-- Beiratkozás kezelése. Egyszerre lehet személyeket ÉS egy egész csoportot
-- megadni: 2627 felvételt egyenként felvinni nem munka, hanem büntetés.
create or replace function public.echo_course_enroll(
  p_course   uuid,
  p_profiles uuid[] default null,
  p_group    text   default null,
  p_action   text   default 'add'
) returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare v_ids uuid[]; v_n int := 0; v_act text := coalesce(p_action, 'add');
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not public.is_staff() then raise exception 'ECHO_FORBIDDEN'; end if;
  if not exists (select 1 from echo.course where id = p_course) then raise exception 'ECHO_COURSE_NOT_FOUND'; end if;
  if v_act not in ('add','remove','drop') then
    raise exception 'ECHO_BAD_INPUT: ismeretlen muvelet: "%". Ervenyes: add, remove, drop.', v_act;
  end if;

  -- A csoportot ITT oldjuk fel, a mentés pillanatában: egy szabály alapú
  -- csoport tagsága később változhat, a beiratkozás viszont tény, nem szabály.
  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_ids
    from (
      select unnest(coalesce(p_profiles, '{}'::uuid[])) as x
      union
      select m.profile_id from public.user_group_member m
       where p_group is not null and m.group_id = p_group
      union
      select p.id from public.profiles p
       join public.user_group g on g.id = p_group and g.tipus = 'szabaly'
       where p_group is not null and public.group_rule_matches(g.szabaly, p.id)
    ) s
   where x is not null;

  if coalesce(array_length(v_ids, 1), 0) = 0 then
    raise exception 'ECHO_BAD_INPUT: nincs egyetlen kijelolt hallgato sem.';
  end if;

  if v_act = 'add' then
    insert into echo.enrollment (course_id, student_key, status, ext_source)
    select p_course, u, 'active', 'manual' from unnest(v_ids) u
      where exists (select 1 from public.profiles pr where pr.id = u)
    on conflict (course_id, student_key) do update set status = 'active';
    get diagnostics v_n = row_count;
  elsif v_act = 'drop' then
    update echo.enrollment set status = 'dropped'
     where course_id = p_course and student_key = any(v_ids);
    get diagnostics v_n = row_count;
  else
    delete from echo.enrollment
     where course_id = p_course and student_key = any(v_ids);
    get diagnostics v_n = row_count;
  end if;

  perform echo.log_access('echo_course_enroll', null, p_course, null, v_act);
  return jsonb_build_object('ok', true, 'muvelet', v_act, 'erintett', v_n,
                            'hallgato_szam', (select count(*) from echo.enrollment
                                               where course_id = p_course and status='active'));
end $$;


-- Dokumentum bejegyzése. A FÁJLT a kliens tölti fel a 'documents' tárolóba,
-- <feltöltő-uid>/kurzus/<kurzus-id>/... útvonalra — ezt a tárolópolicy is
-- megköveteli. Itt csak a hivatkozás keletkezik. Az útvonalat ELLENŐRIZZÜK:
-- e nélkül egy rossz (vagy szándékosan más kurzusra mutató) útvonal
-- bekerülhetne, és a jogosultság két rétege elcsúszna egymástól.
create or replace function public.echo_course_document_add(
  p_course uuid, p_cim text, p_fajlnev text, p_path text,
  p_mime text default null, p_meret bigint default null, p_fajta text default 'egyeb'
) returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, storage, extensions, pg_temp
as $$
declare v_p text[]; v_cim text := nullif(btrim(coalesce(p_cim,'')),'');
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not echo.course_visible(p_course) then raise exception 'ECHO_FORBIDDEN'; end if;
  if coalesce(btrim(p_path), '') = '' or coalesce(btrim(p_fajlnev), '') = '' then
    raise exception 'ECHO_BAD_INPUT: az utvonal es a fajlnev kotelezo.';
  end if;

  v_p := storage.foldername(p_path);
  if coalesce(array_length(v_p,1),0) < 3
     or v_p[1] <> auth.uid()::text
     or v_p[2] <> 'kurzus'
     or v_p[3] <> p_course::text then
    raise exception 'ECHO_BAD_PATH: az utvonalnak "<sajat-uid>/kurzus/<kurzus-id>/..." '
                    'alakunak kell lennie. Kapott: "%".', p_path;
  end if;

  insert into echo.course_document (course_id, cim, fajlnev, path, mime, meret, fajta, uploaded_by)
  values (p_course, coalesce(v_cim, p_fajlnev), p_fajlnev, p_path, p_mime, p_meret,
          coalesce(nullif(p_fajta,''), 'egyeb'), auth.uid())
  on conflict (path) do update set cim = excluded.cim, fajta = excluded.fajta;

  perform echo.log_access('echo_course_document_add', null, p_course, null, 'course');
  return public.echo_course_get(p_course);
end $$;


-- Dokumentum levétele. A SOR tűnik el; a tárolóban lévő fájlt a kliens
-- próbálja törölni, de a documents_delete_own policy csak a FELTÖLTŐNEK
-- engedi. Ha más veszi le, a fájl a tárolóban marad — elérhetetlenül, mert
-- hivatkozás nélkül senki nem kap rá aláírt URL-t. Ezt kimondjuk, nem
-- hallgatjuk el: egy takarítási feladat marad belőle, nem szivárgás.
create or replace function public.echo_course_document_remove(p_doc uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare d echo.course_document%rowtype;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  select * into d from echo.course_document where id = p_doc;
  if not found then raise exception 'ECHO_DOC_NOT_FOUND'; end if;
  if not echo.course_visible(d.course_id) then raise exception 'ECHO_FORBIDDEN'; end if;

  delete from echo.course_document where id = p_doc;
  perform echo.log_access('echo_course_document_remove', null, d.course_id, null, 'course');
  return jsonb_build_object('ok', true, 'path', d.path,
                            'sajat_feltoltes', (d.uploaded_by = auth.uid()));
end $$;


-- ------------------------------------------------------------
-- 7. Jogosultságok
-- ------------------------------------------------------------
-- Nevesített revoke az 'anon'-tól: a Supabase alapértelmezett jogosultsága
-- minden ÚJ public sémabeli függvényre ad EXECUTE-ot az anon-nak, és a
-- 'revoke ... from public' ezt NEM veszi el (külön bejegyzés).
do $jog$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('echo_course_list','echo_course_get','echo_course_students',
                         'echo_course_options','echo_course_save','echo_course_delete',
                         'echo_course_teacher_set','echo_course_enroll',
                         'echo_course_document_add','echo_course_document_remove')
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
select 'kurzusleiras oszlopok' as mit_ellenorzunk,
       count(*)::text as ertek,
       case when count(*) = 2 then 'OK' else 'HIBA' end as allapot
  from information_schema.columns
 where table_schema='echo' and table_name='course' and column_name in ('leiras','leiras_en')
union all
select 'course_document tabla',
       coalesce((select count(*)::text||' sor' from echo.course_document), '(nincs)'),
       case when exists (select 1 from information_schema.tables
                          where table_schema='echo' and table_name='course_document')
            then 'OK' else 'HIBA' end
union all
select 'RLS a course_document-en',
       case when relrowsecurity then 'be' else 'ki' end,
       case when relrowsecurity then 'OK' else 'HIBA' end
  from pg_class where oid='echo.course_document'::regclass
union all
select 'oktatoi fajlolvasas (storage policy)',
       coalesce((select policyname from pg_policies
                  where schemaname='storage' and tablename='objects'
                    and policyname='documents_read_course_teacher'), '(nincs)'),
       case when exists (select 1 from pg_policies
                          where schemaname='storage' and tablename='objects'
                            and policyname='documents_read_course_teacher')
            then 'OK'
            else 'FIGYELEM — kezzel kell felvenni a Storage > Policies alatt' end
union all
select 'torlesi fek (kampanyban levo kurzus)',
       case when prosrc like '%ECHO_COURSE_IN_USE%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%ECHO_COURSE_IN_USE%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_course_delete'
union all
select 'utvonal-ellenorzes a dokumentumnal',
       case when prosrc like '%ECHO_BAD_PATH%' then 'megvan' else '(nincs)' end,
       case when prosrc like '%ECHO_BAD_PATH%' then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_course_document_add'
union all
select 'RPC: '||p.proname,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon is' else 'csak authenticated' end,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public'
   and p.proname in ('echo_course_list','echo_course_get','echo_course_students',
                     'echo_course_options','echo_course_save','echo_course_delete',
                     'echo_course_teacher_set','echo_course_enroll',
                     'echo_course_document_add','echo_course_document_remove')
union all
select 'kurzus / felev / beiratkozas (elo adat)',
       (select count(*)::text from echo.course)||' kurzus, '||
       (select count(distinct term)::text from echo.course)||' felev, '||
       (select count(*)::text from echo.enrollment)||' beiratkozas',
       'INFO';
