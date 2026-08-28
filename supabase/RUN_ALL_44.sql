-- ============================================================================
-- RUN_ALL_44.sql — UniPortal
--
--   44_course_history.sql      a kurzus története: félévek, oktatók, változásnapló
--   21_echo_harden_submit.sql  ÚJRA — minden új migráció után kötelező
--   + a végén a MODUL SAJÁT ELLENŐRZÉSE
--
-- ELŐFELTÉTEL: a RUN_ALL_43.sql már lefutott.
-- Idempotens. Meglévő adatot nem módosít, csak naplózni kezdi a jövőbeli
-- változásokat — a migráció ELŐTTI módosításokra visszamenőleg nincs nyom.
-- ============================================================================


-- ============================================================================
--  44_course_history.sql — UniPortal / ECHO
--  A KURZUS TÖRTÉNETE: melyik félévben ki tanította, ki vette fel, mi változott
-- ============================================================================
--
--  MI AZ, AMI MÁR ADOTT VOLT
--  Az echo.course egy sora NEM tantárgy, hanem tantárgy EGY FÉLÉVBEN: a
--  (code, term) pár egyedi. Az oktatók (echo.course_teacher) és a beiratkozások
--  (echo.enrollment) is ehhez a félévhez kötődnek. A történet tehát szerkezetileg
--  már benne volt az adatban — csak nem volt összefűzve és nem látszott.
--  Az összefűzés kulcsa a KÓD: ugyanaz a kurzuskód félévről félévre visszatér.
--
--  MI HIÁNYZOTT
--  (1) A félévek összefűzése egy nézetbe.
--  (2) A metaadat-változások naplója. Ha valaki átírja a kurzus nevét vagy
--      kiveszi az órarendi jelölést, annak eddig nyoma sem maradt — pedig az
--      alkalmassági motor pont ezekből dönt, és egy régi kampány eredményét
--      utólag magyarázni ilyen nyom nélkül nem lehet.
--
--  ELŐFELTÉTEL: a RUN_ALL_43.sql már lefutott. Idempotens.
-- ============================================================================


-- ------------------------------------------------------------
-- 1. Változásnapló
-- ------------------------------------------------------------
-- MEZŐNKÉNT egy sor, nem soronként egy JSON. Így a "mikor lett ez
-- vizsgakurzus?" kérdés egy where-rel megválaszolható, nem jsonb-túrással.
create table if not exists echo.course_history (
  id          uuid primary key default gen_random_uuid(),
  course_id   uuid not null references echo.course(id) on delete cascade,
  mezo        text not null,
  regi        text,
  uj          text,
  actor_key   uuid,
  actor_email text,
  at          timestamptz not null default now()
);
create index if not exists course_history_course_idx on echo.course_history (course_id, at desc);
alter table echo.course_history enable row level security;


-- ------------------------------------------------------------
-- 2. A naplózó triggerek
-- ------------------------------------------------------------
-- A SECURITY DEFINER-t szándékosan NEM használjuk: a trigger azzal a joggal
-- fut, amivel az írás történt, és csak beszúr. Az auth.uid() lehet NULL (SQL
-- Editorból vagy service_role-lal írva) — ilyenkor a napló ezt üresen hagyja,
-- nem talál ki hamis szerzőt.
create or replace function echo.course_audit()
returns trigger language plpgsql
set search_path = echo, public, pg_temp
as $$
declare
  v_email text := (select email from public.profiles where id = auth.uid());
  v_mezok text[] := array['code','name_hu','name_en','term','lang','org_unit_id',
                          'letszam','van_orarendi_info','vizsgakurzus','leiras','leiras_en'];
  m       text;
  v_o     text;
  v_u     text;
begin
  if tg_op = 'INSERT' then
    insert into echo.course_history (course_id, mezo, regi, uj, actor_key, actor_email)
    values (new.id, 'letrehozas', null, new.code || ' · ' || new.term, auth.uid(), v_email);
    return new;
  end if;

  foreach m in array v_mezok loop
    execute format('select ($1).%I::text, ($2).%I::text', m, m)
       into v_o, v_u using old, new;
    if v_o is distinct from v_u then
      insert into echo.course_history (course_id, mezo, regi, uj, actor_key, actor_email)
      values (new.id, m, v_o, v_u, auth.uid(), v_email);
    end if;
  end loop;
  return new;
end $$;

drop trigger if exists course_audit_trg on echo.course;
create trigger course_audit_trg
  after insert or update on echo.course
  for each row execute function echo.course_audit();


-- Az oktatói kötés ugyanabba a naplóba megy: a "ki vitte a kurzust" kérdés
-- ugyanannak a történetnek a része, mint a "mi volt a neve".
create or replace function echo.course_teacher_audit()
returns trigger language plpgsql
set search_path = echo, public, pg_temp
as $$
declare
  v_email text := (select email from public.profiles where id = auth.uid());
  v_c     uuid := coalesce(new.course_id, old.course_id);
  v_nev   text := (select t.name from echo.teacher t
                    where t.id = coalesce(new.teacher_id, old.teacher_id));
begin
  -- MAGA A KURZUS tunik el? Akkor NE naplozzunk. A kurzus torlese kaszkadol az
  -- echo.course_teacher-re, ez a trigger pedig AFTER DELETE fut — a beszurt
  -- naplosor egy mar nem letezo kurzusra hivatkozna, es a course_history
  -- idegen kulcsa elhasalna. Az pedig nem csak a naplozast bukna el, hanem AZ
  -- EGESZ TORLEST. Merve: az echo_course_delete() minden oktatoval rendelkezo
  -- kurzuson elhasalt, amig ez a feltetel nem volt itt.
  -- A naplosor amugy is kaszkadolna a kurzussal egyutt, tehat nem veszik el
  -- semmi, ami megmaradt volna.
  if tg_op = 'DELETE' and not exists (select 1 from echo.course where id = v_c) then
    return old;
  end if;

  if tg_op = 'INSERT' then
    insert into echo.course_history (course_id, mezo, regi, uj, actor_key, actor_email)
    values (v_c, 'oktato', null, v_nev || ' · ' || new.share_pct::text || '%', auth.uid(), v_email);
  elsif tg_op = 'DELETE' then
    insert into echo.course_history (course_id, mezo, regi, uj, actor_key, actor_email)
    values (v_c, 'oktato', v_nev || ' · ' || old.share_pct::text || '%', null, auth.uid(), v_email);
  elsif new.share_pct is distinct from old.share_pct or new.role is distinct from old.role then
    insert into echo.course_history (course_id, mezo, regi, uj, actor_key, actor_email)
    values (v_c, 'oktato',
            v_nev || ' · ' || old.share_pct::text || '% · ' || old.role,
            v_nev || ' · ' || new.share_pct::text || '% · ' || new.role, auth.uid(), v_email);
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists course_teacher_audit_trg on echo.course_teacher;
create trigger course_teacher_audit_trg
  after insert or update or delete on echo.course_teacher
  for each row execute function echo.course_teacher_audit();


-- ------------------------------------------------------------
-- 3. A hallgatói névsor félévvel és az AKKORI oktatóval
-- ------------------------------------------------------------
-- A régi három paraméteres változatot EL KELL DOBNI: a 'create or replace'
-- eltérő paraméterszámmal ÚJ függvényt hozna létre a régi mellé, és a
-- PostgREST a névre illesztve nem tudná eldönteni, melyiket hívja.
drop function if exists public.echo_course_students(uuid, text, int);

create or replace function public.echo_course_students(
  p_course    uuid,
  p_q         text    default null,
  p_limit     int     default 500,
  p_all_terms boolean default false
) returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  v_q    text := nullif(btrim(coalesce(p_q, '')), '');
  v_lim  int  := least(greatest(coalesce(p_limit, 500), 1), 3000);
  v_code text;
  v_out  jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  if not echo.course_visible(p_course) then raise exception 'ECHO_FORBIDDEN'; end if;
  select code into v_code from echo.course where id = p_course;
  if v_code is null then raise exception 'ECHO_COURSE_NOT_FOUND'; end if;

  -- p_all_terms: a TANTARGY osszes feleve, nem csak ez az egy. Az osszefuzes
  -- kulcsa a kurzuskod: az echo.course egy sora tantargy EGY FELEVBEN, es a
  -- (code, term) par egyedi. Az oktatot mindig ANNAK a felevnek a sorabol
  -- vesszuk — ez a lenyeg: nem a mai oktato kerul a regi felev melle.
  select coalesce(jsonb_agg(x order by x->>'term' desc, x->>'nev'), '[]'::jsonb) into v_out
  from (
    select jsonb_build_object(
             'profile_id', p.id,
             'nev', coalesce(p.name, p.email),
             'email', p.email,
             'status', e.status,
             'tagozat', a.tagozat, 'kepzesi_szint', a.kepzesi_szint, 'szak', a.szak,
             'course_id', k.id,
             'term', k.term,
             'ez_a_felev', (k.id = p_course),
             'oktatok', (select coalesce(string_agg(
                                  t.name || ' (' || round(ct.share_pct)::text || '%)',
                                  ', ' order by ct.share_pct desc, t.name), '—')
                           from echo.course_teacher ct
                           join echo.teacher t on t.id = ct.teacher_id
                          where ct.course_id = k.id)) as x
      from echo.enrollment e
      join echo.course   k on k.id = e.course_id
      join public.profiles p on p.id = e.student_key
      left join public.student_attributes a on a.profile_id = p.id
     where (case when coalesce(p_all_terms, false)
                 then k.code = v_code
                 else k.id = p_course end)
       and (v_q is null or p.email ilike '%'||v_q||'%' or coalesce(p.name,'') ilike '%'||v_q||'%')
     order by k.term desc, coalesce(p.name, p.email)
     limit v_lim
  ) s;
  return v_out;
end $$;


-- ------------------------------------------------------------
-- 4. A kurzus története
-- ------------------------------------------------------------
-- Ket resze van, es a ketto mas kerdesre valaszol:
--   felevek    — hogyan alakult a tantargy felevrol felevre (letszam, oktatok)
--   valtozasok — mit irt at valaki es mikor, a TANTARGY osszes feleven
create or replace function public.echo_course_history(p_course uuid)
returns jsonb
language plpgsql stable security definer
set search_path = echo, public, extensions, pg_temp
as $$
declare
  k      echo.course%rowtype;
  v_ids  uuid[];
  v_out  jsonb;
begin
  if auth.uid() is null then raise exception 'ECHO_NOT_AUTHENTICATED'; end if;
  select * into k from echo.course where id = p_course;
  if not found then raise exception 'ECHO_COURSE_NOT_FOUND'; end if;
  if not echo.course_visible(p_course) then raise exception 'ECHO_FORBIDDEN'; end if;

  -- Az oktato CSAK a sajat kurzusait latja. A tantargy tobbi feleve mas
  -- oktatoe lehetett, ezert a tortenetet is arra szukitjuk, amit lathat;
  -- az ugyintezo mindent lat.
  select coalesce(array_agg(c.id), '{}'::uuid[]) into v_ids
    from echo.course c
   where c.code = k.code
     and (public.is_staff() or echo.teaches(c.id, auth.uid()));

  select jsonb_build_object(
    'course_id', k.id, 'code', k.code, 'term', k.term, 'name_hu', k.name_hu,
    'felev_szam', coalesce(array_length(v_ids, 1), 0),
    'teljes_felev_szam', (select count(*) from echo.course c where c.code = k.code),
    'felevek', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'course_id', c.id, 'term', c.term, 'name_hu', c.name_hu,
               'ez_a_felev', (c.id = p_course),
               'letszam', c.letszam,
               'vizsgakurzus', c.vizsgakurzus,
               'van_orarendi_info', c.van_orarendi_info,
               'hallgato', (select count(*) from echo.enrollment e
                             where e.course_id = c.id and e.status = 'active'),
               'oktatok', (select coalesce(jsonb_agg(jsonb_build_object(
                                    'nev', t.name, 'share_pct', ct.share_pct, 'role', ct.role)
                                  order by ct.share_pct desc, t.name), '[]'::jsonb)
                             from echo.course_teacher ct
                             join echo.teacher t on t.id = ct.teacher_id
                            where ct.course_id = c.id),
               'kampany', (select count(distinct el.campaign_id) from echo.eligibility el
                            where el.course_id = c.id))
             order by c.term desc), '[]'::jsonb)
        from echo.course c where c.id = any(v_ids)),
    'valtozasok', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'at', h.at, 'mezo', h.mezo, 'regi', h.regi, 'uj', h.uj,
               'ki', coalesce(h.actor_email, '(rendszer)'),
               'term', c.term)
             order by h.at desc), '[]'::jsonb)
        from echo.course_history h
        join echo.course c on c.id = h.course_id
       where h.course_id = any(v_ids))
  ) into v_out;
  return v_out;
end $$;


do $jog$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('echo_course_students','echo_course_history')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon',   f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end
$jog$;

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


-- ============================================================================
--  ELLENŐRZÉS — futtasd le, és küldd vissza a táblát
-- ============================================================================
select 'valtozasnaplo tabla' as mit_ellenorzunk,
       (select count(*)::text||' bejegyzes' from echo.course_history) as ertek,
       case when exists (select 1 from information_schema.tables
                          where table_schema='echo' and table_name='course_history')
            then 'OK' else 'HIBA' end as allapot
union all
select 'RLS a naplon',
       case when relrowsecurity then 'be' else 'ki' end,
       case when relrowsecurity then 'OK' else 'HIBA' end
  from pg_class where oid='echo.course_history'::regclass
union all
select 'trigger: '||tgname,
       case when tgenabled = 'O' then 'aktiv' else 'allapot='||tgenabled::text end,
       case when tgenabled = 'O' then 'OK' else 'HIBA' end
  from pg_trigger
 where tgname in ('course_audit_trg','course_teacher_audit_trg') and not tgisinternal
union all
select 'a nevsor tudja a felevet es az AKKORI oktatot',
       case when prosrc like '%p_all_terms%' and prosrc like '%k.code = v_code%'
            then 'megvan' else '(nincs)' end,
       case when prosrc like '%p_all_terms%' and prosrc like '%k.code = v_code%'
            then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_course_students'
union all
select 'nincs ket echo_course_students valtozat',
       count(*)::text||' valtozat',
       case when count(*) = 1 then 'OK' else 'HIBA — ketertelmu a PostgREST-nek' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='echo_course_students'
union all
select 'RPC: '||p.proname,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon is' else 'csak authenticated' end,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'OK' else 'HIBA' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('echo_course_students','echo_course_history')
union all
select 'a naplozas nem akadalyozza a kurzustorlest',
       case when prosrc like '%not exists (select 1 from echo.course where id = v_c)%'
            then 'megvan' else '(nincs)' end,
       case when prosrc like '%not exists (select 1 from echo.course where id = v_c)%'
            then 'OK' else 'HIBA — a torles elhasalna' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='echo' and p.proname='course_teacher_audit'
union all
select 'ugyanaz a kod tobb felevben (elo adat)',
       (select count(*)::text from (select code from echo.course
                                     group by code having count(distinct term) > 1) t)||' tantargy',
       'INFO — ennyi tantargynak van tobb feleve';
