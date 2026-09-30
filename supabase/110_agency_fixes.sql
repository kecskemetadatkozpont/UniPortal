-- ============================================================
-- 110_agency_fixes.sql — az ügynökségi portál teszthibái
-- (tesztmérnöki jegyzőkönyv, 2026-09-30)
-- ============================================================
-- MIT JAVÍT
--   1. DUPLIKÁTUM-VÉDELEM. Mérve: ugyanarra a jelentkezőre két folyamat
--      született (FV-01626 és FV-01627), mert az e-mail-cím ékezetben tért el.
--      Ráadásul ha a MÁSIK ügynökség adta hozzá ugyanazt a címet, a felület
--      szó nélkül továbblépett a jelentkezési folyamatra — olyan sorra,
--      amelyet az az ügynök nem is lát. Mostantól:
--        · ékezetes (nem ASCII) e-mail-címet nem fogadunk el — a gyakorlatban
--          ez elgépelés, és pont ez okozta a duplikálást;
--        · ha az élő jelentkezés MÁSIK ügynökséghez tartozik, a hívás HIBÁT
--          dob, nem adja vissza a sort.
--   2. MARKETINGANYAGOK LETÖLTÉSE. Mérve: az ügynök nem tudta letölteni
--      („A fájl most nem érhető el"), mert a documents tároló olvasási
--      szabálya csak a SAJÁT mappát engedi (első útvonalszegmens = auth.uid()),
--      a marketinganyagot pedig az iroda tölti fel. Új szabály: a
--      'marketing/' előtagú fájlokat MINDEN ügynökségi fiók olvashatja,
--      írni csak ügyintéző tud.
--
-- IDEMPOTENS. FÜGG: 08 (documents tároló), 29, 108.
-- ============================================================

-- ============================================================
-- 1. SZIGORÚBB JELENTKEZTETÉS
-- ============================================================
create or replace function public.agency_application_start(
  p_name text,
  p_email text,
  p_country text default null,
  p_program_ids jsonb default '[]'::jsonb,
  p_term text default null
) returns public.admission_processes
language plpgsql security definer set search_path = public
as $fn$
declare
  v_agency text := public.my_agency();
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_id     text;
  v_student text;
  v_sor    public.admission_processes;
begin
  if v_agency is null and not public.is_staff() then
    raise exception 'AGENCY_REQUIRED: csak ügynökségi fiók indíthat így jelentkezést.';
  end if;
  if v_email = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'EMAIL_INVALID: érvényes e-mail-cím kell a jelentkezőhöz.';
  end if;
  /* ÉKEZETES E-MAIL-CÍM: a gyakorlatban elgépelés (test.béla@… a test.bela@…
     helyett), és pont ez hozott létre két jelentkezést ugyanarra a diákra.
     Inkább megállunk, mint hogy duplikátum szülessen. */
  if v_email ~ '[^\x20-\x7E]' then
    raise exception 'EMAIL_NOT_ASCII: az e-mail-cím nem tartalmazhat ékezetes betűt — ellenőrizd az elgépelést.';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'NAME_REQUIRED: a jelentkező neve kötelező.';
  end if;

  -- Van-e már ÉLŐ (nem megszakított) folyamat erre a címre?
  select * into v_sor
    from public.admission_processes
   where lower(owner_email) = v_email
     and coalesce(data->>'_cancelled', 'false') <> 'true'
   order by (stage = 'student') desc, updated_at desc
   limit 1;

  if found then
    -- MÁSIK ÜGYNÖKSÉG diákja: ne lépjünk tovább egy nem látható sorra.
    if v_sor.agency_id is not null and v_agency is not null and v_sor.agency_id <> v_agency then
      raise exception 'EMAIL_TAKEN_BY_OTHER_AGENCY: erre az e-mail-címre már van jelentkezés, amelyet egy másik ügynökség indított. Egyeztess a felvételi irodával.';
    end if;
    -- Saját (vagy még ügynökséghez nem kötött) sor: kössük és adjuk vissza.
    if v_sor.agency_id is null and v_agency is not null then
      update public.admission_processes set agency_id = v_agency, updated_at = now()
       where id = v_sor.id returning * into v_sor;
    end if;
    return v_sor;
  end if;

  select id into v_student from public.students where lower(email) = v_email limit 1;
  if v_student is null then
    v_student := 'S-' || substr(md5(v_email || clock_timestamp()::text), 1, 10);
    insert into public.students (id, name, email, "agentId", status, "appliedAt", country)
    values (v_student, btrim(p_name), v_email, v_agency, 'Draft',
            to_char(now(), 'YYYY-MM-DD'), nullif(btrim(coalesce(p_country, '')), ''))
    on conflict (id) do nothing;
  elsif v_agency is not null then
    update public.students
       set "agentId" = coalesce("agentId", v_agency),
           name = coalesce(nullif(btrim(name), ''), btrim(p_name)),
           country = coalesce(country, nullif(btrim(coalesce(p_country, '')), ''))
     where id = v_student;
  end if;

  v_id := 'APP-' || substr(md5(v_email || clock_timestamp()::text), 1, 12);
  insert into public.admission_processes
    (id, owner_email, applicant_name, stage, student_step, step, max_reached, done,
     agency_id, created_at, updated_at, program_id, data)
  values
    (v_id, v_email, btrim(p_name), 'student', 0, 0, 0, false,
     v_agency, to_char(now(), 'YYYY-MM-DD'), now(),
     nullif(p_program_ids->>0, ''),
     jsonb_build_object(
       'program_ids', coalesce(p_program_ids, '[]'::jsonb),
       'term', nullif(btrim(coalesce(p_term, '')), ''),
       'personal', jsonb_build_object('name', btrim(p_name), 'email', v_email,
                                      'country', nullif(btrim(coalesce(p_country, '')), '')),
       'docs', '{}'::jsonb,
       '_agency_started', jsonb_build_object('agency_id', v_agency, 'at', to_char(now(), 'YYYY-MM-DD'))
     ))
  returning * into v_sor;

  return v_sor;
end
$fn$;

revoke all on function public.agency_application_start(text, text, text, jsonb, text) from public, anon;
grant execute on function public.agency_application_start(text, text, text, jsonb, text) to authenticated;

-- ============================================================
-- 2. MARKETINGANYAGOK: A 'marketing/' ELŐTAG MINDEN ÜGYNÖKSÉGNEK OLVASHATÓ
-- ============================================================
do $mkt$
begin
  begin
    execute $p$drop policy if exists "documents_read_marketing" on storage.objects$p$;
    execute $p$create policy "documents_read_marketing" on storage.objects
              for select to authenticated
              using (
                bucket_id = 'documents'
                and (storage.foldername(name))[1] = 'marketing'
                and (public.is_staff() or public.my_agency() is not null)
              )$p$;

    execute $p$drop policy if exists "documents_write_marketing" on storage.objects$p$;
    execute $p$create policy "documents_write_marketing" on storage.objects
              for insert to authenticated
              with check (
                bucket_id = 'documents'
                and (storage.foldername(name))[1] = 'marketing'
                and public.is_staff()
              )$p$;

    execute $p$drop policy if exists "documents_delete_marketing" on storage.objects$p$;
    execute $p$create policy "documents_delete_marketing" on storage.objects
              for delete to authenticated
              using (
                bucket_id = 'documents'
                and (storage.foldername(name))[1] = 'marketing'
                and public.is_staff()
              )$p$;
  exception when others then
    raise notice 'A marketing tarolo-szabalyok kihagyva (%). Allitsd be kezzel: Storage -> documents -> Policies.', sqlerrm;
  end;
end
$mkt$;

-- ============================================================
-- 3. ZÁRÓ ELLENŐRZÉS
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'agency_application_start') then
    raise exception 'Hianyzik az agency_application_start fuggveny.';
  end if;
  raise notice 'Rendben: 110 — szigorubb jelentkeztetes + marketinganyag-letoltes.';
end $$;

select polname as tarolo_szabaly
  from pg_policy
 where polname like 'documents_%marketing%'
 order by polname;
