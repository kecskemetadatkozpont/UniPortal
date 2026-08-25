-- ============================================================================
-- 27_31_ellenorzes.sql — a 27–31 migráció leülésének ellenőrzése
-- Egyetlen lekérdezés, egy tábla. Minden sor "OK"-t kell mutasson.
-- ============================================================================
with elvart(sorrend, mit, nev, tipus) as (values
  (1,'Interjú: elérhetőség tábla','interview_availability','tabla'),
  (2,'Interjú: beállítás tábla','interview_setting','tabla'),
  (3,'Interjú: ebédszünet tábla','interview_break','tabla'),
  (4,'Interjú: szabadság tábla','interview_absence','tabla'),
  (5,'Interjú: interjúztatók','interview_interviewer','tabla'),
  (6,'Ügynökség: jutalék-tételek','agency_commission_item','tabla'),
  (7,'Ügynökség: jutalék-időszak','agency_commission_period','tabla'),
  (8,'Ügynökség: dokumentumok','agency_document','tabla'),
  (9,'Ügynökség: számlák','agency_invoice','tabla'),
  (10,'Foglalás RPC','interview_book','fuggveny'),
  (11,'Szabad sávok RPC','interview_free_slots','fuggveny'),
  (12,'Naptár RPC','interview_calendar','fuggveny'),
  (13,'Saját ügynökség','my_agency','fuggveny'),
  (14,'30: kapu-szigorítás visszavonó','interview_gate_hardening_rollback','fuggveny'),
  (15,'31: ütközésvédelem visszavonó','interview_integrity_rollback','fuggveny'),
  (16,'31: átfedés-tiltás','interviewslots_no_overlap','megszoritas'),
  (17,'31: egy élő foglalás / diák','interviewslots_one_live_per_student','index'),
  (18,'31: sorosító trigger','a_interviewslots_serialize_trg','trigger')
)
select
  e.mit                                     as "mit ellenőrzünk",
  e.nev                                     as "objektum",
  case when v.megvan then 'OK' else '!! HIÁNYZIK' end as "állapot"
from elvart e
cross join lateral (
  select case e.tipus
    when 'tabla'       then exists (select 1 from pg_tables
                                     where schemaname='public' and tablename=e.nev)
    when 'fuggveny'    then exists (select 1 from pg_proc p
                                     join pg_namespace n on n.oid=p.pronamespace
                                    where n.nspname='public' and p.proname=e.nev)
    when 'megszoritas' then exists (select 1 from pg_constraint where conname=e.nev)
    when 'index'       then exists (select 1 from pg_indexes
                                     where schemaname='public' and indexname=e.nev)
    when 'trigger'     then exists (select 1 from pg_trigger
                                    where tgname=e.nev and not tgisinternal)
  end as megvan
) v
order by e.sorrend;
