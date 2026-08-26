-- ============================================================================
--  46_readonly_rpc_fix.sql — UniPortal
--  "cannot execute INSERT in a read-only transaction"
-- ============================================================================
--
--  A TÜNET
--  Az ECHO kampánykezelés oldalán egy kampányra kattintva a rendszer ezt írta
--  ki: "cannot execute INSERT in a read-only transaction".
--
--  AZ OK
--  A PostgREST a STABLE és IMMUTABLE függvényeket CSAK OLVASHATÓ tranzakcióban
--  futtatja — ez a deklarált volatilitás értelme. Öt függvény viszont
--  STABLE-nek van jelölve, KÖZBEN hozzáférés-naplót ír (echo.log_access /
--  dorm.log_access, ami INSERT). A naplózás nem "olvasás", tehát a
--  volatilitás-jelölés volt hibás, nem a naplózás.
--
--  Ez RÉGI hiba (a 18a és a 26-os migrációból), nem most keletkezett. Eddig
--  azért nem tűnt fel, mert nem minden PostgREST-verzió kényszeríti ki a
--  csak-olvasható tranzakciót ugyanúgy.
--
--  A JAVÍTÁS
--  A törzsükhöz nem nyúlunk — csak a volatilitást írjuk át VOLATILE-ra. Ez
--  soha nem ronthat el semmit: a VOLATILE a legkevesebbet feltételező jelölés,
--  a tervező csak kevesebb rövidítést enged meg magának. A hívás módja nem
--  változik (a kliens POST-tal hív, nem GET-tel).
--
--  MIÉRT NEM A NAPLÓZÁST VESSZÜK KI: a hozzáférés-napló pont arra való, hogy
--  a LEKÉRDEZÉS is nyomot hagyjon. Egy kampány adatlapjának megnyitása
--  személyes adatokhoz való hozzáférés — ennek látszania kell.
--
--  Idempotens. Csak metaadatot módosít.
-- ============================================================================

do $fix$
declare f record; n int := 0;
begin
  for f in
    select p.oid, p.oid::regprocedure as sig, n.nspname||'.'||p.proname as nev
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('echo_campaign_get', 'dorm_free_beds', 'dorm_my_placement',
                         'dorm_occupancy_summary', 'dorm_open_issues')
       and p.provolatile in ('s', 'i')
  loop
    execute format('alter function %s volatile', f.sig);
    raise notice 'ECHO 46: % -> volatile', f.nev;
    n := n + 1;
  end loop;
  if n = 0 then
    raise notice 'ECHO 46: nem volt mit javitani (mar mind volatile).';
  end if;
end
$fix$;


-- ============================================================================
--  ELLENŐRZÉS — futtasd le, és küldd vissza a táblát
-- ============================================================================
select 'javitott fuggveny: '||p.proname as mit_ellenorzunk,
       case p.provolatile when 'v' then 'volatile'
                          when 's' then 'stable' else 'immutable' end as ertek,
       case when p.provolatile = 'v' then 'OK' else 'HIBA — meg mindig read-only' end as allapot
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public'
   and p.proname in ('echo_campaign_get','dorm_free_beds','dorm_my_placement',
                     'dorm_occupancy_summary','dorm_open_issues')
union all
select 'maradt-e IRO stable/immutable fuggveny barhol',
       count(*)::text||' db',
       case when count(*) = 0 then 'OK' else 'HIBA — lasd a nevet a kovetkezo sorokban' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where p.provolatile in ('s','i')
   and n.nspname not in ('pg_catalog','information_schema','extensions','graphql','pgbouncer')
   and exists (select 1 from unnest(string_to_array(p.prosrc, e'\n')) l
                where (l ~* '\mlog_access\M' or l ~* '\minsert into\M'
                       or l ~* '\mdelete from\M' or l ~* '^\s*update\s+\w')
                  and l !~ '^\s*--')
union all
select 'meg iro stable fuggveny: '||n.nspname||'.'||p.proname,
       case p.provolatile when 's' then 'stable' else 'immutable' end,
       'HIBA'
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where p.provolatile in ('s','i')
   and n.nspname not in ('pg_catalog','information_schema','extensions','graphql','pgbouncer')
   and exists (select 1 from unnest(string_to_array(p.prosrc, e'\n')) l
                where (l ~* '\mlog_access\M' or l ~* '\minsert into\M'
                       or l ~* '\mdelete from\M' or l ~* '^\s*update\s+\w')
                  and l !~ '^\s*--');
