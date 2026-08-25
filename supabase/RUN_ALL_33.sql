-- ============================================================================
-- RUN_ALL_33.sql  —  UniPortal
-- EGYBEN BEILLESZTHETŐ a Supabase SQL Editorba.
--
--   33_program_catalogue_backfill.sql  a szakkatalógus feltöltése a valóságból
--   21_echo_harden_submit.sql          ÚJRA — minden új migráció után kötelező
--
-- ELŐFELTÉTEL: a RUN_ALL_32.sql már lefutott.
-- Idempotens: többször is beilleszthető.
--
-- MIT VÁRJ A KIMENETBEN: NOTICE sorokat arról, hány katalógus-tétel jött
-- létre és hány jelentkezés kötődött hozzájuk. A végén "Kötetlenül maradt: 0"
-- a jó eredmény.
-- ============================================================================


-- ===========================================================================
-- >>> 33_program_catalogue_backfill.sql
-- ===========================================================================
-- ============================================================================
-- 33_program_catalogue_backfill.sql — a szakkatalógus feltöltése a valóságból
-- ----------------------------------------------------------------------------
-- MIÉRT KELL
--   A 32-es migráció ellenőrzése éles adatbázison ezt adta:
--       Átemelt jelentkezések | katalógushoz kötve / címkével | 0 / 11
--
--   Az ok: a public.programs katalógust EGYETLEN migráció sem tölti — azt a
--   Programkezelés felületről kell feltölteni, és még üres. Így a jelentkezők
--   szakja csak szabad szövegként él (students.program), nincs mihez kötni.
--
--   Ennek két gyakorlati következménye van:
--     1) a szakonkénti statisztika üres marad;
--     2) a jelentkező adatlapján a "Szak hozzáadása" lista is üres, mert az
--        a katalógusból tölt.
--
-- MIT CSINÁL
--   A ténylegesen használt szaknevekből létrehozza a hiányzó katalógus-
--   tételeket, majd hozzájuk köti a jelentkezéseket. NEM talál ki adatot: a
--   nevek a meglévő jelentkezésekből jönnek. A tételek vázlatosak lesznek
--   (csak név + generált kód) — a kart, a tandíjat, a képzési szintet a
--   Programkezelés felületén lehet kitölteni.
--
-- IDEMPOTENS: többször is lefuttatható, meglévő tételt nem duplikál.
-- Visszavonás: nincs külön — a létrehozott tételek a Programkezelésben
--   ugyanúgy szerkeszthetők és törölhetők, mint a kézzel felvettek.
-- ============================================================================

begin;

do $$
declare
  v_letrehozott integer := 0;
  v_kotott      integer := 0;
  v_maradt      integer;
  v_sor         record;
begin
  -- 1) Hiányzó katalógus-tételek létrehozása a használt nevekből.
  for v_sor in
    select distinct btrim(sp.program_label) as nev
      from public.student_program sp
     where sp.program_id is null
       and nullif(btrim(coalesce(sp.program_label, '')), '') is not null
       and not exists (
         select 1 from public.programs p
          where lower(btrim(p.name)) = lower(btrim(sp.program_label))
       )
     order by 1
  loop
    insert into public.programs (id, code, name)
    values (
      left('PR' || replace(gen_random_uuid()::text, '-', ''), 22),
      -- Vázlatos kód a névből: "BSc Computer Science" -> "BSC-COMPUTER-SCIENCE"
      left(upper(regexp_replace(v_sor.nev, '[^a-zA-Z0-9]+', '-', 'g')), 40),
      v_sor.nev
    );
    v_letrehozott := v_letrehozott + 1;
    raise notice 'Katalógus-tétel létrehozva: "%"', v_sor.nev;
  end loop;

  -- 2) A jelentkezések hozzákötése a katalógushoz.
  update public.student_program sp
     set program_id = p.id,
         program_label = null
    from public.programs p
   where sp.program_id is null
     and lower(btrim(p.name)) = lower(btrim(sp.program_label));
  get diagnostics v_kotott = row_count;

  select count(*) into v_maradt
    from public.student_program where program_id is null;

  raise notice '---';
  raise notice 'Létrehozott katalógus-tétel: %', v_letrehozott;
  raise notice 'Hozzákötött jelentkezés:     %', v_kotott;
  raise notice 'Kötetlenül maradt:           %', v_maradt;
  raise notice '---';
  if v_letrehozott > 0 then
    raise notice 'A létrehozott tételek VÁZLATOSAK: csak nevük és generált kódjuk van.';
    raise notice 'A kart, a képzési szintet és a tandíjat a Programkezelés';
    raise notice 'felületén érdemes kitölteni.';
  end if;
end $$;

commit;


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

