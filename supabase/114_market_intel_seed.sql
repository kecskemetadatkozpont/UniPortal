-- ============================================================
-- 114_market_intel_seed.sql — GYÁRI FORRÁSLISTA a piacfigyelőhöz
-- ============================================================
-- MIÉRT: a 112 üres forráslistával indul, és kézzel felvenni tizenhárom
-- oldalt hosszú. Ez a szkript berakja a teszteléshez elegendő kiinduló
-- készletet — a SAJÁT csatornáinkat referenciának, mellé négy intézményt.
--
-- AZ OLDALCÍMEK 2026-09-30-án KERESÉSSEL ELLENŐRIZVE. Ez nem formalitás:
-- egy elgépelt kezelőnév hetekig üres adatot ad, és a felületen az látszik,
-- mintha az intézmény nem csinálna semmit. Ha valamelyik oldal átkerül,
-- a Források fülön írható át — a kulcs marad, a betöltés nem törik el.
--
-- MIÉRT EZEK
--   • NJE (sajat = true): ehhez mérjük a részesedést. E nélkül a „Részesedés"
--     kártya üresen marad, mert nincs mihez viszonyítani.
--   • Óbudai Egyetem: ugyanaz a műszaki közönség, nagy angol nyelvű kínálat.
--   • Dunaújvárosi Egyetem: a legközelebbi profil (hasonló méret, műszaki
--     kínálat, erős nemzetközi toborzás) — a külön ANGOL NYELVŰ oldaluk
--     szándékosan külön sor, mert az szól a mi jelentkezőinkhez.
--   • Budapesti Metropolitan: agresszív fizetett hirdetés, erős rövidvideó.
--   • Debreceni Egyetem (bő kör): a legnagyobb magyar nemzetközi toborzó —
--     ő szabja a mezőnyt, de nem a közvetlen versenytársunk.
--
-- MEGJEGYZÉS, AMI MAGÁBAN IS EREDMÉNY: a keresés NEM talált külön angol
-- nyelvű NJE közösségi oldalt, miközben Debrecennek és Dunaújvárosnak van.
-- Ez marketingdöntés kérdése, nem a rendszeré — de a modul ezt fogja mutatni.
--
-- NEM ÍR FELÜL SEMMIT: `on conflict (kulcs) do nothing`. Ha egy sort már
-- felvettél vagy átírtál, az érintetlen marad. Kétszer lefuttatva ugyanaz.
-- FÜGG: 112 (és a 113 javítás).
-- ============================================================

insert into mi.source (kulcs, intezmeny, platform, cim, kor, sajat, aktiv, megjegyzes) values
  -- ---- A MI CSATORNÁINK — referencia ----
  ('nje-facebook',  'Neumann János Egyetem', 'facebook',
   'https://www.facebook.com/neumann.egyetem/', 'szuk', true, true,
   'Saját fő oldal. Ehhez mérjük a részesedést.'),
  ('nje-instagram', 'Neumann János Egyetem', 'instagram',
   'https://www.instagram.com/uni_neumann/', 'szuk', true, true,
   'Saját. 2026-09-30-án ~1,9 ezer követő.'),
  ('nje-tiktok',    'Neumann János Egyetem', 'tiktok',
   'https://www.tiktok.com/@uni_neumann', 'szuk', true, true,
   'Saját. 2026-09-30-án ~2,3 ezer követő.'),

  -- ---- SZŰK KÖR: ugyanarra a diákra pályáznak ----
  ('obuda-facebook',  'Óbudai Egyetem', 'facebook',
   'https://www.facebook.com/ObudaiEgyetem/', 'szuk', false, true,
   'Műszaki közönség, nagy angol nyelvű kínálat.'),
  ('obuda-instagram', 'Óbudai Egyetem', 'instagram',
   'https://www.instagram.com/obudaiegyetem/', 'szuk', false, true, null),
  ('obuda-tiktok',    'Óbudai Egyetem', 'tiktok',
   'https://www.tiktok.com/@obudai.egyetem', 'szuk', false, true,
   'Aktív felvételi tartalom, „Miért jelentkezz" lejátszási listával.'),

  ('duf-instagram',      'Dunaújvárosi Egyetem', 'instagram',
   'https://www.instagram.com/dunaujvarosiegyetem/', 'szuk', false, true,
   'Magyar nyelvű fő oldal.'),
  ('duf-instagram-intl', 'Dunaújvárosi Egyetem', 'instagram',
   'https://www.instagram.com/universityofdunaujvaros/', 'szuk', false, true,
   'ANGOL nyelvű oldal — ez szól a mi jelentkezőinkhez. Külön sor, hogy a két közönség ne keveredjen.'),
  ('duf-tiktok',         'Dunaújvárosi Egyetem', 'tiktok',
   'https://www.tiktok.com/@dunaujvarosiegyetem', 'szuk', false, true, null),

  ('metu-instagram', 'Budapesti Metropolitan Egyetem', 'instagram',
   'https://www.instagram.com/metropolitanbudapest/', 'szuk', false, true, null),
  ('metu-tiktok',    'Budapesti Metropolitan Egyetem', 'tiktok',
   'https://www.tiktok.com/@metropolitanbudapest', 'szuk', false, true,
   'Erős rövidvideós jelenlét — formátum-összehasonlításra a legjobb minta.'),

  -- ---- BŐ KÖR: az országképet viszi ----
  ('debrecen-instagram', 'Debreceni Egyetem', 'instagram',
   'https://www.instagram.com/universityofdebrecen_official/', 'bo', false, true,
   'Angol nyelvű, 2026-09-30-án ~40 ezer követő. A legnagyobb magyar nemzetközi toborzó.'),
  ('debrecen-tiktok',    'Debreceni Egyetem', 'tiktok',
   'https://www.tiktok.com/@universityofdebrecen', 'bo', false, true,
   'Angol nyelvű, 2026-09-30-án ~13 ezer követő.')
on conflict (kulcs) do nothing;


-- ============================================================
-- ÖNELLENŐRZÉS
-- ============================================================
do $chk$
declare v_ossz integer; v_sajat integer;
begin
  select count(*) into v_ossz  from mi.source;
  select count(*) into v_sajat from mi.source where sajat;

  if v_sajat = 0 then
    raise exception 'MI: nincs SAJÁT csatorna — a részesedés-számítás enélkül üresen marad.';
  end if;
  if v_ossz < 13 then
    raise warning 'MI: % forrás van (vártunk legalább 13-at). Ha korábban töröltél sorokat, ez rendben van.', v_ossz;
  end if;

  raise notice 'MI 114 OK: % forrás, ebből % saját.', v_ossz, v_sajat;
end $chk$;
