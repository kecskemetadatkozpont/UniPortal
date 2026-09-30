-- ============================================================
-- 115_market_intel_ads.sql — HIRDETÉSKÖNYVTÁR-FORRÁSOK
-- ============================================================
-- MIÉRT: a 114-es gyári lista csak közösségi oldalakat vett fel. A
-- hirdetéskönyvtár viszont külön forrástípus ('ads'), és önálló sor kell hozzá
-- intézményenként — ez mondja meg a betöltőnek, hogy a Meta Ad Library
-- tételeit kihez kösse.
--
-- MIÉRT ÉRDEMES ezzel kezdeni a fizetett részt: a hirdetéskönyvtár az egyetlen
-- forrás, ami megmutatja, MIRE TESZNEK PÉNZT — kreatív, futamidő, célország.
-- Egy 30 napig futó hirdetés többet mond, mint három organikus poszt. Ráadásul
-- jogilag ez a legtisztább: hivatalos, nyilvános hirdetéstár.
--
-- CÍM NINCS: a hirdetéseket nem kezelőnév, hanem a HIRDETŐ NEVE köti ide
-- (pageName), és a betöltő ez alapján osztja szét őket. Ezért az intézménynév
-- pontosan egyezzen a közösségi soroknál használttal — a 114 ugyanezeket írja.
--
-- IDEMPOTENS, nem ír felül semmit. FÜGG: 112, 114.
-- ============================================================

insert into mi.source (kulcs, intezmeny, platform, cim, kor, sajat, aktiv, megjegyzes) values
  ('ads-nje',      'Neumann János Egyetem',          'ads', null, 'szuk', true,  true,
   'Saját hirdetéseink — ehhez mérjük, mennyivel vagyunk jelen.'),
  ('ads-obuda',    'Óbudai Egyetem',                 'ads', null, 'szuk', false, true, null),
  ('ads-duf',      'Dunaújvárosi Egyetem',           'ads', null, 'szuk', false, true, null),
  ('ads-metu',     'Budapesti Metropolitan Egyetem', 'ads', null, 'szuk', false, true,
   'Agresszív fizetett hirdetés — itt várható a legtöbb tétel.'),
  ('ads-debrecen', 'Debreceni Egyetem',              'ads', null, 'bo',   false, true, null)
on conflict (kulcs) do nothing;

do $chk$
declare v_n integer;
begin
  select count(*) into v_n from mi.source where platform = 'ads' and aktiv;
  if v_n = 0 then raise exception 'MI: nem jött létre hirdetés-forrás.'; end if;
  raise notice 'MI 115 OK: % hirdetéskönyvtár-forrás.', v_n;
end $chk$;
