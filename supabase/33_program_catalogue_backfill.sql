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
