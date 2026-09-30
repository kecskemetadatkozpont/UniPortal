-- ============================================================
-- 109_program_optional_docs.sql — NEM MINDEN DOKUMENTUM KÖTELEZŐ
-- ============================================================
-- MIÉRT (külügyi iroda, 2026-09-30): a képzésnél felsorolt dokumentumok MIND
-- kötelezők voltak, a jelentkezés csak akkor lépett tovább, ha a jelentkező
-- mindet feltöltötte. Így egy alapképzésre jelentkezőtől is kutatási tervet
-- (research proposal) kért a rendszer, holott az csak doktori szinten kell.
--
-- A megoldás nem az, hogy kivesszük a listából: a dokumentum KÉRHETŐ marad,
-- csak nem AKADÁLY. Aki be tudja adni, adja be — akinek nincs, továbbléphet.
--
-- MIT TELEPÍT: egy oszlop a programs táblán, azoknak a dokumentumkulcsoknak,
-- amelyek a required_docs listában szerepelnek, de NEM kötelezők.
--
-- A FELÜLET ENÉLKÜL IS MŰKÖDIK: amíg ez nem fut le, a szerkesztő nem küldi el
-- a mezőt (ugyanaz a minta, mint a 85-ös célközönség-oszlopnál), és minden
-- dokumentum kötelező marad — vagyis a mai viselkedés.
--
-- IDEMPOTENS. FÜGG: 01/05 (programs), 58 (dokumentumtípusok).
-- ============================================================

alter table public.programs
  add column if not exists optional_docs jsonb not null default '[]'::jsonb;

comment on column public.programs.optional_docs is
  'A required_docs közül azok a kulcsok, amelyek KÉRHETŐK, de nem kötelezők: hiányukban is tovább lehet lépni (109).';

-- Biztonsági háló: csak tömb kerülhet bele.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'programs_optional_docs_ck') then
    alter table public.programs
      add constraint programs_optional_docs_ck
      check (jsonb_typeof(optional_docs) = 'array');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Záró ellenőrzés
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_name = 'programs' and column_name = 'optional_docs') then
    raise exception 'Hianyzik a programs.optional_docs oszlop.';
  end if;
  raise notice 'Rendben: 109 — a kepzesnel megjelolheto, mely dokumentum nem kotelezo.';
end $$;

select id, name, required_docs, optional_docs from public.programs order by name limit 20;
