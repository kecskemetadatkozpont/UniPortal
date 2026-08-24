-- ============================================================
-- 18b_echo_form_seed.sql — A VALÓDI OMHV-KÉRDŐÍV BEEMELÉSE
-- ============================================================
-- Neumann János Egyetem — ECHO (OMHV), 28/2023. (VIII.31.) szenátusi határozat
--
-- MIÉRT VAN EZ A FÁJL
-- -------------------
-- A 15_echo_core.sql 11.5 szakasza egy template_version-t seedel, aminek a
-- SZERKEZETE helyes, de a SZÖVEGEI rekonstrukciók: a seed írásakor a
-- prototípus forrása nem állt rendelkezésre (a saját meta mezője ki is
-- mondja: "forras_megjegyzes": "A kerdesszovegek REKONSTRUKCIOK...").
-- Mérve: a jelenlegi 1. verzió EGYETLEN mondata sem egyezik a prototípuséval.
--
-- Ez a migráció a prototípus FORM_SEED tömbjéből emeli be a VALÓDI kérdőívet:
-- 6 szakasz, 13 kérdés, a teljes opciólistákkal
--   COURSE_STRENGTHS (7), COURSE_IMPROVE (7), T_STRENGTHS (10),
--   T_IMPROVE (12), SKIP_REASONS (4), ATTENDANCE (4).
--
-- FORRÁSHŰSÉG — MI HONNAN VAN
--   • a MAGYAR szövegek: a prototípus FORM_SEED-jéből SZÓ SZERINT, az
--     ékezetekkel és a gondolatjelekkel együtt (a 15-ös seed ékezet nélkül
--     írt, itt nem tesszük — a szenátus által jóváhagyott szöveg pontos alakja
--     a jóváhagyás tárgya);
--   • az ANGOL szövegek: ahol a prototípusban volt en mező, onnan szó szerint;
--     ahol nem volt (az opciók túlnyomó része), ott MIR-FORDÍTÁS, amit
--     jóvá kell hagyatni. A meta.forditas_statusz mező ezt rögzíti.
--     Miért kell mégis kitölteni: az echo.template_validate() az angol
--     fordítás hiányát ÉLESÍTÉS-BLOKKOLÓ hibaként jelzi (hianyzo_angol_opcio),
--     tehát angol szöveg nélkül a verzió nem tud 'live' állapotba menni.
--
-- MIT NEM CSINÁL EZ A FÁJL
--   • NEM írja át a 15_echo_core.sql-t (az a felhasználónál már lefutott);
--   • NEM törli és NEM módosítja az 1. verziót — az 'live' marad, hogy a
--     hozzá kötött, már beérkezett válaszok (mérve: 42 sor) értelmezhetők
--     maradjanak. Élő verzió compiled mezőjét a
--     echo.template_version_guard() trigger amúgy sem engedné átírni;
--   • NEM köti át a futó kampányt. Azt a jóváhagyás után, kézzel kell —
--     lásd a fájl végén a KÉZI LÉPÉSEK szakaszt.
--
-- IDEMPOTENS: újrafuttatva nem hoz létre duplikátumot. Ha a verzió már
-- létezik és még 'draft', a compiled FRISSÜL erre a tartalomra; ha már
-- kilépett a draft állapotból, a fájl hozzá sem nyúl.
--
-- FUTTATÁS: Supabase SQL Editor, egyetlen blokként bemásolva.
-- ============================================================

set search_path = echo, public, extensions, pg_temp;

-- ------------------------------------------------------------
-- 1. ÓRALÁTOGATÁSI SÁVOK — ELŐFELTÉTEL, NEM KOZMETIKA
-- ------------------------------------------------------------
-- MÉRT PROBLÉMA: a prototípus sávjai ('0–32%', '33–59%', '60–84%',
-- '85–100%') NINCSENEK benne az echo.attendance_band szótárban (a szótár ma
-- a 15/16-os seed nyolc kódját tartalmazza, mind ASCII kötőjellel).
-- Az echo.attendance_low() FAIL-CLOSED: ami nincs a szótárban, az
-- ALACSONY óralátogatásnak számít. Ha a sávokat nem vennénk fel, az ÚJ
-- kérdőívvel érkező MINDEN válasz kikerülne a jegyzőkönyvi főstatisztikából
-- (3. § (9)), csendben.
--
-- FIGYELEM A KÖTŐJELRE: a prototípus GONDOLATJELET használ (U+2013, "–"),
-- nem ASCII mínuszt. A code mezőnek BETŰ SZERINT egyeznie kell a kérdőív
-- opciójának value mezőjével, különben a szótár nem talál rá.
-- A küszöb 33% (echo.setting.attendance_min_pct), ezért csak a legalsó sáv
-- számít alacsonynak.
insert into echo.attendance_band (code, name_hu, name_en, low, sort_order) values
  ('0–32%',   '0–32%',   '0–32%',   true,  15),
  ('33–59%',  '33–59%',  '33–59%',  false, 25),
  ('60–84%',  '60–84%',  '60–84%',  false, 35),
  ('85–100%', '85–100%', '85–100%', false, 45)
on conflict (code) do nothing;

-- ------------------------------------------------------------
-- 2. AZ ÚJ KÉRDŐÍV-VERZIÓ
-- ------------------------------------------------------------
-- SZERKEZETI IGAZÍTÁSOK a prototípus FORM_SEED-jéhez képest. Mindegyik azért
-- van, mert a MEGLÉVŐ kód (features/echo.jsx renderelő + 15/16-os RPC-k) így
-- várja. A szöveg egyikben sem változik.
--
--  (a) TÍPUSNEVEK. A renderelő öt típust ismer: single, multi, scale,
--      longtext, skip. A prototípus 'attendance' típusa -> 'single'
--      (a kérdés id-ja marad 'attendance', lásd (b)); a 'text' -> 'longtext'.
--
--  (b) KÉRDÉS-ID-K. Két id KÖTÖTT, nem szabad megváltoztatni:
--        'attendance' — az ECHO_buildPayload() ezt az egy id-t emeli a
--                       payload GYÖKERÉBE (v_att := p_payload->>'attendance');
--        'goals_met'  — az echo_submit() 4. lépése NÉV SZERINT ezt az egy
--                       célteljesülés-mezőt engedi át, minden más cél-adatot
--                       levág. Lásd a 3. pontot.
--      A TÖBBI kérdés ÚJ id-t kap ('_p' utótag = prototípus-szöveg). Ez
--      szándékos: a válaszok answers mezője kérdés-id -> érték leképezés,
--      tehát ha a megváltozott szövegű kérdés MEGTARTANÁ a régi id-t, az
--      1. verzió találgatott kérdésére adott válaszok és a 2. verzió valódi
--      kérdésére adott válaszok EGY kulcsba folynának, és egy hosszmetszeti
--      riport összeadná őket. Ugyanez az indoklás áll a 16_echo_reports.sql
--      echo.compiled_reid() függvénye mögött.
--      MEGJEGYZÉS az 'attendance'-hoz: az id kötött, de a SÁVOK ÉRTÉKEI
--      különböznek (0-25%/26-50%/... vs. 0–32%/33–59%/...), ezért az
--      óralátogatás-eloszlást verziónként kell nézni, nem összevonva.
--
--  (c) A KIHAGYÁS-KAPU. A prototípusban a "Biztos nem akarod értékelni?"
--      kérdés a lista UTÁN áll, cond: {qid:'q8', val:'__skip__'}. A meglévő
--      renderelőben a 'skip' típus maga A KAPU (ECHO_QSkip): alapból nincs
--      bejelölve semmi, és ha a hallgató bejelöli, akkor kér indokot. Ezért
--      itt ELÖL áll, cond nélkül, a két lista pedig
--      cond: {"teacher_skip_p": null} feltétellel jelenik meg — ez a
--      prototípus logikájának pontos megfelelője a meglévő kódban.
--      A prototípus required:true-ját ezért nem vesszük át: a kapu
--      kikapcsolt állapota az alapértelmezés, nem hiányzó válasz.
--
--  (d) SKÁLÁK. A prototípus {min:'Rossznak', max:'Kiemelkedőnek', points:7}
--      alakot használ (min/max = FELIRAT). A meglévő ECHO_QScale a min/max-ot
--      SZÁMKÉNT olvassa, a feliratot a min_hu/max_hu/min_en/max_en mezőkből.
--      A prototípus feliratai ezért a *_hu mezőkbe kerülnek, a min/max pedig
--      1 és a points értéke lesz. A szöveg nem változik.
--
--  (e) SZÖVEGES MEZŐK max ÉRTÉKE. A prototípusban a text kérdések max:1-et
--      írnak (= egy válasz). A renderelőben a longtext max a KARAKTERKORLÁT,
--      ezért itt 1500 áll, a 15-ös seeddel egyezően. Ha 1 maradna, a
--      hallgató egyetlen karaktert tudna beírni.
--
--  (f) OPCIÓ-ÉRTÉKEK. A value MINDENÜTT a magyar szöveg (a prototípus
--      opt(hu,en) helpere is így viselkedik: value = hu), kivéve a
--      célteljesülést és az "Igen/Nem" kérdést, ahol slug áll — előbbinél
--      azért, mert az echo_submit() CHECK-je nevesített értékeket vár
--      ('nem_teljesult','reszben','teljesult','tulteljesult'), utóbbinál
--      azért, mert egy kétértékű jelző riportban slugként olvasható.
--
--  (g) SZAKASZ-BEVEZETŐK. A prototípus EVAL_STEPS tömbjének lead szövegeit
--      lead_hu/lead_en mezőben hozzuk. A mai renderelő ezeket MÉG NEM
--      rajzolja ki — a mező azért van itt, hogy a jóváhagyandó tartalom
--      egyben legyen, és a felület később hozzájuk tudjon nyúlni.

--  (h) A CÉLKÉRDÉS FELTÉTELE. A prototípusban a célkérdés required:true és
--      nincs cond-ja. A 15-ös seed rekonstrukciója ide egy
--      cond: {"has_goals": true} feltételt tett. MÉRVE: az
--      echo.template_validate() ezt 'kotelezo_feltetel_mogott' kóddal
--      ÉLESÍTÉS-BLOKKOLÓ hibának jelzi (kötelező kérdés megjelenítési
--      feltétel mögött), tehát a verzió a feltétellel nem tudna 'live'
--      állapotba menni. A feltétel amúgy is felesleges: a repeat:"goal"
--      MAGA a kapu — az ECHO_buildSteps() célonként bont, tehát ha a
--      hallgatónak nincs célja, a lépés meg sem születik. Ezért itt
--      cond: null áll, required: true mellett — a prototípussal egyezően.
--

do $mig$
declare
  v_tpl uuid := 'e3000000-0000-4000-8000-000000000001';   -- OMHV-ALAP (15-ös seed)
  v_id  uuid := 'e3000000-0000-4000-8000-000000000003';   -- EZ a verzió, fix id
  v_ver integer;
  v_state text;
  v_compiled jsonb;
begin
  if not exists (select 1 from echo.template where id = v_tpl) then
    raise exception '18b: nincs meg az OMHV-ALAP sablon (%). Eloszor a 15_echo_core.sql-t kell lefuttatni.', v_tpl;
  end if;

  v_compiled := $json$
{
  "meta": {
    "code": "OMHV-ALAP",
    "version": 2,
    "title_hu": "Oktatói munka hallgatói véleményezése",
    "title_en": "Student evaluation of teaching",
    "legal_hu": "28/2023. (VIII.31.) szenátusi határozat",
    "forras": "ECHO prototípus, FORM_SEED — a magyar szövegek szó szerint innen valók.",
    "forditas_statusz": "Az angol szövegek egy része MIR-fordítás, jóváhagyásra vár. Ahol a prototípusban is volt en mező, ott az szerepel.",
    "elozmeny": "Az 1. verzió szövegei rekonstrukciók voltak; ez a verzió váltja ki. Az 1. verzió NEM törölhető, mert a hozzá kötött válaszok arra hivatkoznak."
  },
  "parts": [
    { "id": "part1", "hu": "Célmeghatározás (félév eleje)", "en": "Goal setting (start of term)" },
    { "id": "part2", "hu": "Értékelés (félév vége)",        "en": "Evaluation (end of term)" }
  ],
  "sections": [
    {
      "id": "s1", "part": "part2", "audience": [],
      "hu": "Bevezetés", "en": "Introduction",
      "lead_hu": "Egy kérdés arról, mennyit voltál jelen — ez dönti el, hogyan számít be a véleményed.",
      "lead_en": "One question about how much you attended — this decides how your opinion counts.",
      "questions": [
        { "id": "attendance", "type": "single",
          "hu": "Az órák hány százalékán vettél részt ezen a kurzuson?",
          "en": "What share of the classes did you attend?",
          "help": { "hu": "Önbevallás. 33% alatt a véleményed csak tájékoztató jellegű — 3. § (9).",
                    "en": "Self-declared. Below 33% the response is indicative only." },
          "options": [
            { "value": "0–32%",   "hu": "0–32%",   "en": "0–32%" },
            { "value": "33–59%",  "hu": "33–59%",  "en": "33–59%" },
            { "value": "60–84%",  "hu": "60–84%",  "en": "60–84%" },
            { "value": "85–100%", "hu": "85–100%", "en": "85–100%" }
          ],
          "required": true, "moderated": false, "randomize": false, "allowOther": false,
          "max": 1, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    },
    {
      "id": "s2", "part": "part2", "audience": [],
      "hu": "Célok teljesülése", "en": "Goal fulfilment",
      "lead_hu": "A félév elején ezeket fogalmaztad meg. Értékeld, mennyire teljesültek.",
      "lead_en": "You set these at the start of the term. Rate how far they were met.",
      "questions": [
        { "id": "goals_met", "type": "single",
          "hu": "Értékeld a korábban megfogalmazott célodat!",
          "en": "Rate the goal you set earlier.",
          "help": { "hu": "A félév elején megadott saját célok és oktatói elvárások egyenként jelennek meg.",
                    "en": "The goals and expectations you set at the start of term appear one by one." },
          "options": [
            { "value": "nem_teljesult", "hu": "Nem teljesült",     "en": "Not achieved" },
            { "value": "reszben",       "hu": "Részben teljesült", "en": "Partly achieved" },
            { "value": "teljesult",     "hu": "Teljesült",         "en": "Achieved" }
          ],
          "required": true, "moderated": false, "randomize": false, "allowOther": false,
          "max": 1, "repeat": "goal", "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    },
    {
      "id": "s3", "part": "part2", "audience": [],
      "hu": "Szöveges élmények", "en": "Open feedback",
      "lead_hu": "Két szabad kérdés — ezek a legértékesebb visszajelzések az oktatónak.",
      "lead_en": "Two open questions — these are the most valuable feedback for the teacher.",
      "questions": [
        { "id": "exp_positive_p", "type": "longtext",
          "hu": "Mi volt a kurzuson a legpozitívabb élményed?",
          "en": "What was your most positive experience?",
          "help": null, "options": null,
          "required": false, "moderated": true, "randomize": false, "allowOther": false,
          "max": 1500, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "exp_negative_p", "type": "longtext",
          "hu": "Mi volt a kurzuson a legzavaróbb élményed?",
          "en": "What was the most disturbing experience on the course?",
          "help": { "hu": "Személyre, magánéletre, meggyőződésre vonatkozó megjegyzés érvénytelen — 3. § (10).",
                    "en": "Remarks about a person, private life or beliefs are invalid — Art. 3 (10)." },
          "options": null,
          "required": false, "moderated": true, "randomize": false, "allowOther": false,
          "max": 1500, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    },
    {
      "id": "s4", "part": "part2", "audience": [],
      "hu": "Kurzus értékelése", "en": "Course evaluation",
      "lead_hu": "Erősségek és fejlődési lehetőségek, legfeljebb két-két állítás.",
      "lead_en": "Strengths and areas to improve, at most two statements each.",
      "questions": [
        { "id": "req_changed_p", "type": "single",
          "hu": "A félév elején meghatározott teljesítési követelmények a félév során változtak?",
          "en": "Did the course requirements change during the term?",
          "help": null,
          "options": [
            { "value": "igen", "hu": "Igen", "en": "Yes" },
            { "value": "nem",  "hu": "Nem",  "en": "No" }
          ],
          "required": true, "moderated": false, "randomize": false, "allowOther": false,
          "max": 1, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "course_strengths_p", "type": "multi",
          "hu": "Szerinted mik voltak a kurzus erősségei?",
          "en": "What were the strengths of the course?",
          "help": null,
          "options": [
            { "value": "A kurzuson elvárt munka nagyban hozzájárult a szakmai fejlődésemhez",
              "hu": "A kurzuson elvárt munka nagyban hozzájárult a szakmai fejlődésemhez",
              "en": "The work required on the course contributed greatly to my professional development" },
            { "value": "Sok új dolgot tudtam megtanulni a kurzus során",
              "hu": "Sok új dolgot tudtam megtanulni a kurzus során",
              "en": "I was able to learn a lot of new things during the course" },
            { "value": "Rendszeresen volt alkalom csoportmunkára",
              "hu": "Rendszeresen volt alkalom csoportmunkára",
              "en": "There were regular opportunities for group work" },
            { "value": "A kurzuson végzett tevékenységek sokszínűek voltak",
              "hu": "A kurzuson végzett tevékenységek sokszínűek voltak",
              "en": "The activities on the course were varied" },
            { "value": "Az eszközök és nyersanyagok elérhetőek voltak",
              "hu": "Az eszközök és nyersanyagok elérhetőek voltak",
              "en": "The tools and materials were available" },
            { "value": "Egyéb", "hu": "Egyéb", "en": "Other" },
            { "value": "A kurzusnak nem volt erőssége",
              "hu": "A kurzusnak nem volt erőssége",
              "en": "The course had no strengths" }
          ],
          "required": false, "moderated": false, "randomize": true, "allowOther": true,
          "max": 2, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "course_improve_p", "type": "multi",
          "hu": "Szerinted miben fejlődhetne a kurzus?",
          "en": "In what way could the course improve?",
          "help": null,
          "options": [
            { "value": "A kurzuson elvárt munka jobban hozzájárulhatna a szakmai fejlődésemhez",
              "hu": "A kurzuson elvárt munka jobban hozzájárulhatna a szakmai fejlődésemhez",
              "en": "The work required on the course could contribute more to my professional development" },
            { "value": "A kurzus során több új információt lehetne megtanulni",
              "hu": "A kurzus során több új információt lehetne megtanulni",
              "en": "More new information could be learned during the course" },
            { "value": "Lehetne több alkalom a csoportmunkára",
              "hu": "Lehetne több alkalom a csoportmunkára",
              "en": "There could be more opportunities for group work" },
            { "value": "A kurzuson végzett tevékenységek lehetnének sokszínűbbek",
              "hu": "A kurzuson végzett tevékenységek lehetnének sokszínűbbek",
              "en": "The activities on the course could be more varied" },
            { "value": "Az eszközöknek és nyersanyagoknak elérhetőbbnek kellene lennie",
              "hu": "Az eszközöknek és nyersanyagoknak elérhetőbbnek kellene lennie",
              "en": "The tools and materials should be more available" },
            { "value": "Egyéb", "hu": "Egyéb", "en": "Other" },
            { "value": "A kurzus nem tud miben fejlődni; így jó, ahogy van",
              "hu": "A kurzus nem tud miben fejlődni; így jó, ahogy van",
              "en": "There is nothing to improve; the course is good as it is" }
          ],
          "required": false, "moderated": false, "randomize": true, "allowOther": true,
          "max": 2, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    },
    {
      "id": "s5", "part": "part2", "audience": [],
      "hu": "Oktató értékelése", "en": "Teacher evaluation",
      "lead_hu": "Oktatónként külön, legfeljebb öt-öt állítás.",
      "lead_en": "Separately for each teacher, at most five statements each.",
      "questions": [
        { "id": "teacher_skip_p", "type": "skip",
          "hu": "Biztos nem akarod értékelni az oktatót?",
          "en": "Are you sure you do not want to evaluate this teacher?",
          "help": { "hu": "Csak akkor jelenik meg, ha a hallgató kihagyja az oktató értékelését. A kihagyás oka minőségjelzés.",
                    "en": "Shown only if the student skips the teacher. The reason for skipping is a quality signal." },
          "options": [
            { "value": "Igen, mert nem jártam be",            "hu": "Igen, mert nem jártam be",            "en": "Yes, because I did not attend" },
            { "value": "Igen, de nem akarom elmondani miért", "hu": "Igen, de nem akarom elmondani miért", "en": "Yes, but I do not want to say why" },
            { "value": "Igen, mert nem is tanított",          "hu": "Igen, mert nem is tanított",          "en": "Yes, because they did not teach me" },
            { "value": "Igen, és leírom miért",               "hu": "Igen, és leírom miért",               "en": "Yes, and I will write why" }
          ],
          "required": false, "moderated": false, "randomize": false, "allowOther": true,
          "max": 1, "repeat": "teacher", "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "teacher_strengths_p", "type": "multi",
          "hu": "Mik voltak leginkább [Oktató neve] erősségei?",
          "en": "What were the main strengths of [Teacher name]?",
          "help": { "hu": "Legfeljebb öt állítás jelölhető, oktatónként külön.",
                    "en": "At most five statements, separately for each teacher." },
          "options": [
            { "value": "Felkészülten tartotta meg az órát", "hu": "Felkészülten tartotta meg az órát", "en": "Came to class prepared" },
            { "value": "Tartotta magát a megállapodottakhoz", "hu": "Tartotta magát a megállapodottakhoz", "en": "Kept to what was agreed" },
            { "value": "Elmélyítette a meglévő érdeklődésemet", "hu": "Elmélyítette a meglévő érdeklődésemet", "en": "Deepened my existing interest" },
            { "value": "Bevonta a hallgatókat", "hu": "Bevonta a hallgatókat", "en": "Involved the students" },
            { "value": "Az órákat mindig megtartotta", "hu": "Az órákat mindig megtartotta", "en": "Always held the classes" },
            { "value": "Lelkiismeretes volt a hallgatókhoz való hozzáállásában", "hu": "Lelkiismeretes volt a hallgatókhoz való hozzáállásában", "en": "Was conscientious in their attitude towards students" },
            { "value": "Rendelkezésre állt a tanórán kívül is", "hu": "Rendelkezésre állt a tanórán kívül is", "en": "Was available outside class as well" },
            { "value": "Segítőkész volt problémák és kérdések esetén", "hu": "Segítőkész volt problémák és kérdések esetén", "en": "Was helpful with problems and questions" },
            { "value": "Jó segédanyagokat adott", "hu": "Jó segédanyagokat adott", "en": "Provided good learning materials" },
            { "value": "Rendszeresen adott visszajelzést", "hu": "Rendszeresen adott visszajelzést", "en": "Gave feedback regularly" }
          ],
          "required": false, "moderated": false, "randomize": true, "allowOther": false,
          "max": 5, "repeat": "teacher", "cond": { "teacher_skip_p": null }, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "teacher_improve_p", "type": "multi",
          "hu": "Miben kellene leginkább fejlődnie [Oktató neve]-nek?",
          "en": "In what way should [Teacher name] improve most?",
          "help": null,
          "options": [
            { "value": "Jobban fel kéne készülnie az órákra", "hu": "Jobban fel kéne készülnie az órákra", "en": "Should prepare better for classes" },
            { "value": "Jobban kéne tartania magát a megállapodottakhoz", "hu": "Jobban kéne tartania magát a megállapodottakhoz", "en": "Should keep better to what was agreed" },
            { "value": "Jobban kéne bevonnia a hallgatókat", "hu": "Jobban kéne bevonnia a hallgatókat", "en": "Should involve the students more" },
            { "value": "Az órákat mindig tartsa meg", "hu": "Az órákat mindig tartsa meg", "en": "Should always hold the classes" },
            { "value": "Lelkiismeretesebbnek kellene lennie a hallgatókhoz való hozzáállásában", "hu": "Lelkiismeretesebbnek kellene lennie a hallgatókhoz való hozzáállásában", "en": "Should be more conscientious in their attitude towards students" },
            { "value": "Jobban rendelkezésre kellene állnia a tanórán kívül", "hu": "Jobban rendelkezésre kellene állnia a tanórán kívül", "en": "Should be more available outside class" },
            { "value": "Segítőkészebbnek kellene lennie problémák esetén", "hu": "Segítőkészebbnek kellene lennie problémák esetén", "en": "Should be more helpful with problems" },
            { "value": "Alaposabban kellene végig kísérnie a tanulási folyamatomat", "hu": "Alaposabban kellene végig kísérnie a tanulási folyamatomat", "en": "Should follow my learning process more thoroughly" },
            { "value": "Jobb segédanyagokra van szükség", "hu": "Jobb segédanyagokra van szükség", "en": "Better learning materials are needed" },
            { "value": "Többször kellene visszajelzést adnia", "hu": "Többször kellene visszajelzést adnia", "en": "Should give feedback more often" },
            { "value": "A hallgatókkal egyenlőbben kellene bánnia", "hu": "A hallgatókkal egyenlőbben kellene bánnia", "en": "Should treat students more equally" },
            { "value": "Az oktató nem tud miben fejlődni; így jó, ahogy van", "hu": "Az oktató nem tud miben fejlődni; így jó, ahogy van", "en": "There is nothing to improve; the teacher is good as they are" }
          ],
          "required": false, "moderated": false, "randomize": true, "allowOther": false,
          "max": 5, "repeat": "teacher", "cond": { "teacher_skip_p": null }, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    },
    {
      "id": "s6", "part": "part2", "audience": [],
      "hu": "Zárás", "en": "Closing",
      "lead_hu": "Összegzés a kurzusról és a visszajelzés hatásáról.",
      "lead_en": "A summary of the course and of the impact of your feedback.",
      "questions": [
        { "id": "overall_course_p", "type": "scale",
          "hu": "Összességében milyennek értékeled a kurzust?",
          "en": "Overall, how do you rate the course?",
          "help": { "hu": "A jegyzőkönyv része — 6. § (5).", "en": "Part of the official report — Art. 6 (5)." },
          "options": null,
          "required": true, "moderated": false, "randomize": false, "allowOther": false,
          "max": 1, "repeat": null, "cond": null,
          "scale": { "min": 1, "max": 7, "points": 7,
                     "min_hu": "Rossznak", "max_hu": "Kiemelkedőnek",
                     "min_en": "Poor",     "max_en": "Outstanding" },
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "course_summary_p", "type": "longtext",
          "hu": "Kérjük összegezd, hogy milyen élmény volt számodra a kurzus!",
          "en": "Please summarise what the course was like for you.",
          "help": null, "options": null,
          "required": false, "moderated": true, "randomize": false, "allowOther": false,
          "max": 1500, "repeat": null, "cond": null, "scale": null,
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] },
        { "id": "feedback_impact_p", "type": "scale",
          "hu": "Mennyire érzed, hogy a visszajelzésed hatására változni fognak a dolgok?",
          "en": "How much do you feel that things will change as a result of your feedback?",
          "help": null, "options": null,
          "required": false, "moderated": false, "randomize": false, "allowOther": false,
          "max": 1, "repeat": null, "cond": null,
          "scale": { "min": 1, "max": 5, "points": 5,
                     "min_hu": "Nem lesz hatása", "max_hu": "Lesz változás",
                     "min_en": "It will have no effect", "max_en": "There will be change" },
          "audience": ["Alapképzés","Mesterképzés","Felsőoktatási szakképzés","Doktori","Nappali","Levelező","Angol nyelvű képzés"] }
      ]
    }
  ]
}
  $json$::jsonb;

  select state into v_state from echo.template_version where id = v_id;

  if v_state is null then
    -- Uj verzio. A sorszam a sablon eddigi legnagyobb verziojanal eggyel nagyobb,
    -- igy akkor sem utkozik, ha idokozben mas is keszitett verziot.
    select coalesce(max(version), 0) + 1 into v_ver
      from echo.template_version where template_id = v_tpl;

    insert into echo.template_version (id, template_id, version, state, compiled, notes)
    values (v_id, v_tpl, v_ver, 'draft', v_compiled,
            'A prototipus FORM_SEED valodi szovegei (18b_echo_form_seed.sql). '
            'Az angol forditas egy resze MIR-forditas, jovahagyasra var.');
    raise notice '18b: uj kerdoiv-verzio letrehozva, sorszam=%, allapot=draft, id=%', v_ver, v_id;

  elsif v_state = 'draft' then
    -- Idempotencia: mar letezik es meg piszkozat -> a tartalmat frissitjuk.
    update echo.template_version
       set compiled = v_compiled
     where id = v_id;
    raise notice '18b: a mar letezo % verzio (draft) compiled mezoje frissitve.', v_id;

  else
    -- Mar tullepett a piszkozaton (review/approved/live/closed) -> nem nyulunk hozza.
    raise notice '18b: a % verzio mar % allapotban van, a fajl nem modositja. '
                 'Ha uj szoveg kell, keszits kovetkezo verziot az echo_template_create() RPC-vel.',
                 v_id, v_state;
  end if;
end $mig$;

-- ------------------------------------------------------------
-- 3. MIÉRT NEM CÉLONKÉNT MEGY ÁT A CÉLTELJESÜLÉS
-- ------------------------------------------------------------
-- A goals_met kérdés repeat:"goal", tehát a KITÖLTŐBEN célonként külön sorban
-- jelenik meg (features/echo.jsx, ECHO_buildSteps). A BEKÜLDÖTT payloadba
-- viszont csak EGY összesített érték kerül, a course.goals_met kulcson.
--
-- Ez nem hiányosság, hanem a séma szándéka. Az echo_submit() 4. lépése
-- név szerint levágja a 'goals', 'goal_texts', 'goal_count', 'goals_count',
-- 'expectations', 'expectation_texts' kulcsokat, és a goals_met-en kívül
-- semmilyen cél-adatot nem enged be. Az ok a 15_echo_core.sql 1099. sora
-- körül áll: a célok SZÁMOSSÁGA kvázi-azonosító — az echo.student_goal
-- táblából (ami a hallgatóhoz van kötve) látszik, ki hány célt írt, tehát
-- egy "3 elemű célteljesülés-tömb" a névtelen válaszsoron leszűkítené a
-- lehetséges kitöltők körét. A szövegük még beszédesebb lenne.
--
-- Az összevonás szabálya (a kitöltőben, ECHO_buildPayload):
--   minden cél teljesült                  -> 'teljesult'
--   egy sem teljesült és nincs "részben"   -> 'nem_teljesult'
--   minden más (vegyes vagy részben)       -> 'reszben'
-- A 'tulteljesult' értéket a séma megengedi, de ez a kérdőív nem használja.

-- ------------------------------------------------------------
-- 4. ELLENŐRZÉS — ez a lekérdezés fut le a migráció végén
-- ------------------------------------------------------------
select tv.version,
       tv.state,
       jsonb_array_length(tv.compiled->'sections')                              as szakasz,
       (select count(*) from jsonb_array_elements(tv.compiled->'sections') s,
                             jsonb_array_elements(s.value->'questions') q)      as kerdes,
       jsonb_array_length(echo.template_validate(tv.compiled))                  as validator_talalat,
       echo.template_validate(tv.compiled)                                      as validator_reszletek
  from echo.template_version tv
 where tv.id = 'e3000000-0000-4000-8000-000000000003';

-- ============================================================
-- KÉZI LÉPÉSEK A MIGRÁCIÓ UTÁN — EZEKET A FÁJL SZÁNDÉKOSAN NEM TESZI MEG
-- ============================================================
-- 1) ÁTNÉZÉS A SZERKESZTŐBEN. ECHO -> Kérdőívek -> "OMHV alapkerdoiv (28/2023.)"
--    -> a most létrejött piszkozat verzió. Ellenőrizendő:
--       • a magyar szövegek egyeznek-e a szenátus által jóváhagyott alakkal;
--       • az ANGOL fordítások elfogadhatók-e (a fenti FORRÁSHŰSÉG szakasz
--         szerint egy részük MIR-fordítás).
--    A validátor eredményét a 4. pont lekérdezése is kiírja; élesítéshez
--    ÜRESNEK kell lennie (echo_template_transition ezt ellenőrzi).
--
-- 2) ÉLESÍTÉS. A szerkesztőből, vagy RPC-vel (admin munkamenetben):
--       select public.echo_template_validate('e3000000-0000-4000-8000-000000000003');
--       select public.echo_template_transition('e3000000-0000-4000-8000-000000000003', 'review');
--       select public.echo_template_transition('e3000000-0000-4000-8000-000000000003', 'approved');
--       select public.echo_template_transition('e3000000-0000-4000-8000-000000000003', 'live');
--
-- 3) A KAMPÁNY HOZZÁKÖTÉSE. KÉT ÚT VAN, és a választás nem technikai kérdés:
--
--    (a) ÚJ KAMPÁNY az új verzióval — EZ AZ AJÁNLOTT.
--        A már beérkezett válaszok az 1. verzióra hivatkoznak; ha a futó
--        kampányt átkötnénk, ugyanabban a kampányban kétféle kérdőívre adott
--        válasz keveredne, és a jegyzőkönyv nem lenne egységes.
--        (A kampánylétrehozó RPC a 18a_echo_campaign.sql-ben készül.)
--
--    (b) A FUTÓ DEMÓ KAMPÁNY ÁTKÖTÉSE — csak demó/teszt adatnál.
--        Éles kampányon NE. Kikommentelve, tudatos döntés után futtatandó:
--
--        -- update echo.campaign
--        --    set template_version_id = 'e3000000-0000-4000-8000-000000000003'
--        --  where id = 'e4000000-0000-4000-8000-000000000001'
--        --    and state in ('draft','open');
--
--        Ha ezt választod, a régi válaszok template_version_id-je NEM változik
--        (a response tábla a saját verzióját őrzi) — ez helyes, de azt jelenti,
--        hogy a kampány riportjait verziónként bontva kell nézni.
--
-- 4) AZ 1. VERZIÓ SORSA. Hagyd 'live' vagy tedd 'closed' állapotba, de NE
--    töröld: a echo.response.template_version_id idegen kulcs on delete
--    restrict, tehát a törlés amúgy is elbukna.
-- ============================================================
