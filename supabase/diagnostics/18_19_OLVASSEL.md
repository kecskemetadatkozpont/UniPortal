# ECHO 0. fázis — mit futtass, és mit fogsz látni tőle

Neumann János Egyetem — ECHO (OMHV), 28/2023. (VIII.31.) szenátusi határozat
Készült: 2026-08-20. Minden szám ebben a leírásban **mérés**, nem becslés; ahol
becslés van, oda ki van írva, hogy becslés.

---

## 0. Egy percben

A 0. fázis négy hiányt pótol:

| tétel | mi hiányzott | melyik fájl adja |
|---|---|---|
| 0.1 | nem volt kampánylétrehozó és állapotváltó RPC → a riportmotor elérhetetlen volt | `18a_echo_campaign.sql` |
| 0.2 | a kérdőívszövegek találgatással készültek | `18b_echo_form_seed.sql` |
| 0.3 | a célonkénti (`repeat:'goal'`) kérdés soha nem jelent meg | `18b` + a már meglévő `features/echo.jsx` |
| 0.4 | `echo.teacher.profile_id` mind NULL → oktatóként minden RPC elutasított | `19_echo_roles.sql` |

Ehhez jött két javítás az ellenőrzés után:

| fájl | mit javít |
|---|---|
| `18c_echo_form_activate.sql` | **enélkül a 0.2 és a 0.3 nem jut el a hallgatóhoz.** A 18b a valódi kérdőívet piszkozatban hagyja, a futó kampány pedig a régi, rekonstruált szövegekre mutat. Ez a fájl élesíti az új verziót és átviszi rá a rendszert. |
| `20_echo_report_fix.sql` | az óralátogatás-kérdés a jegyzőkönyvben mindig `n=0`-val és hamis „kevés válasz" üzenettel jelent meg, pedig mindenki kitöltötte |

---

## 1. Mit futtass, milyen sorrendben

A Supabase **SQL Editor**ben, fájlonként egy-egy másolható blokként.
**A sorrend kötelező.** Mindegyik fájl idempotens: ha egy megakadt, nyugodtan
futtasd újra az egészet.

```
1.  supabase/18a_echo_campaign.sql        — kampány-életciklus (RPC-k, állapotgép, triggerek)
2.  supabase/18b_echo_form_seed.sql      — a valódi OMHV-kérdőív mint 2. verzió (piszkozat)
3.  supabase/18c_echo_form_activate.sql  — ÉLESÍTÉS + az új kampány   <<< EZ NÉLKÜL NEM LÁTSZIK SEMMI
4.  supabase/19_echo_roles.sql           — oktatói belépés, ECHO szerepkörök
5.  supabase/20_echo_report_fix.sql      — az óralátogatás hamis „kevés válasz" sora
```

Mindegyik fájl végén van egy ellenőrző `select` — az az eredmény jön vissza az
SQL Editorban. A 4. és az 5. lépés egymáshoz képest felcserélhető, a többi nem.

### Mielőtt a 3. lépést (18c) elindítod — olvasd el

A `18c` négy **visszafordíthatatlan** dolgot tesz. Mindegyik szándékos, de
egyik sem vonható vissza:

1. a valódi kérdőív (2. verzió) `live` lesz;
2. a régi, rekonstruált kérdőív (1. verzió) `closed` lesz — lezárt verzió
   nem nyitható újra (`echo.template_version_guard()`);
3. a futó `DEMO-2025-26-2` kampány `sealed` (lepecsételt) lesz — a pecsét után
   nincs visszalépés (`echo.campaign_seal_guard()`), és lefut az
   `echo.shuffle_responses()`, tehát a válaszok fizikai sorrendje elbomlik;
4. új kampány nyílik a valódi kérdőívvel.

**Miért kell a régit lepecsételni:** egy félévre egy aktív kampány lehet
(`echo_campaign_active_term_uidx`, illetve `ECHO_TERM_BUSY`), tehát az új
kampány csak a régi lezárása után jöhet létre.

**Miért új kampány, és miért nem a régit kötjük át:** az `echo.results_build()`
a *kampány* sablonverziójából veszi a kérdéslistát, a válaszsor viszont a
*saját* verzióját őrzi. Átkötésnél a régi válaszokat az új verzió kérdés-ID-jei
alapján keresné a riport, és minden kérdésre `n=0` jönne ki. Egy kampány =
egy kérdőív-verzió.

A meglévő 44 válasz **nem vész el**: az 1. verzióra hivatkoznak, és a
lepecsételt kampány jegyzőkönyve továbbra is lekérdezhető.

Ha nem akarod ezt: ne futtasd le a `18c`-t. A `18 + 18b + 19 + 20` magában is
konzisztens állapotot hagy — csak a valódi kérdőív marad piszkozatban, és
a hallgató továbbra is a rekonstruált szövegeket kapja.

---

## 2. Mit csinálj a felületen, hogy lásd a különbséget

Lépésről lépésre. A menüpontok neve pontosan az, ami itt szerepel.

### 2.1 Adminként — a két kampány

1. Menü: **ECHO kampányok** → **Kampányok** fül.
2. Két kampányt látsz:
   * `DEMO-2025-26-2` — állapota **lepecsételt**, ezt váltottuk le;
   * `OMHV-2025-26-2` — állapota **nyitott**, ez az új, a valódi kérdőívvel.
3. Kattints a lepecsételtre: az eredménynézet **megnyílik** (a kapu `closed`
   állapottól nyit), tehát a régi 44 válasz jegyzőkönyve olvasható marad.
4. Kattints az újra: 4 jogosultsági pár, 3 kurzus, 0 válasz — még senki nem
   töltötte ki.

### 2.2 Adminként — a kérdőív

1. **ECHO kampányok** → **Kérdőívszerkesztő** fül.
2. Az „OMHV alapkerdoiv (28/2023.)" sablonnál két verzió van:
   * 1. verzió — **lezárt**, ez volt a rekonstruált szöveg;
   * 2. verzió — **élő**, ez a prototípus szó szerinti szövege.
3. Nyisd meg a 2. verziót. Hat szakaszt látsz: *Bevezetés, Célok teljesülése,
   Szöveges élmények, Kurzus értékelése, Oktató értékelése, Zárás* — összesen
   13 kérdéssel.
4. **Nézd át az angol fordításokat.** Az opciószövegek nagy része MIR-fordítás,
   ez jóváhagyást igényel. Ha változtatni kell rajtuk, **nem itt** kell: az
   élő verzió szövege befagyott. Új (3.) verzió kell hozzá — a szerkesztőben
   „Új verzió" (`echo_template_create`), ami klónoz.

### 2.3 Hallgatóként — itt látszik a 0.2 és a 0.3

1. Jelentkezz be egy hallgatói fiókkal, menü: **Kurzusértékelés**.
2. A kurzusnál most **két sor** van: a régi kampány „lezárt" jelzéssel, az új
   „kitölthető" jelzéssel. Az újat nyisd meg.
3. **Először célokat kell rögzíteni.** Ez fontos: a célok **kampányonként**
   tárolódnak (`echo.student_goal`), tehát a régi kampányban felvett célok
   **nem öröklődnek át**. Írj be **legalább kettőt-hármat** (és ha van,
   egy elvárást is).
4. Indítsd el a kitöltést. Amit most látsz, és eddig nem:
   * a kérdések szövege a valódi OMHV-szöveg
     (pl. *„Az órák hány százalékán vettél részt ezen a kurzuson?"*),
     nem a korábbi rekonstrukció;
   * a **Célok teljesülése** szakasz **célonként külön lépésként** jelenik meg
     — ha 3 célt és 1 elvárást írtál, az **4 külön lépés**, mindegyiken a saját
     célod szövegével. Mérve: 3 cél + 1 elvárás → 11 lépéses kitöltés.
   * ha **egy célt sem** írtál, a szakasz **teljesen kimarad** (7 lépés).
5. Küldd be. A beküldés névtelen: külön, jegy alapú anon munkamenetben megy.

### 2.4 Oktatóként — a 0.4

1. Adminként: **ECHO kampányok** → **Szerepkörök** fül → kösd össze az oktatói
   sort egy fiókkal (`echo_teacher_link`). Ez automatikusan kiadja az
   `OKTATO` grantot is.
2. Jelentkezz be azzal a fiókkal: megjelenik az **Oktatói eredmények** menüpont.
3. Csak a **saját** eredményét látja. Másikét kérve:
   `ECHO_FORBIDDEN: oktatokent kizarolag a sajat eredmenyed kerheto le.`
   Kötetlen fióknál: `ECHO_FORBIDDEN: a fiok nincs oktatoi sorhoz kotve`.

### 2.5 Adminként — az eredmény (itt látszik a 20-as javítás)

1. Amikor a kitöltési ablak lejárt (vagy kényszerítéssel korábban), vidd a
   kampányt **nyitott → lezárt** állapotba. Az eredménykapu ekkor nyílik.
2. **ECHO kampányok** → válaszd a kurzust → jegyzőkönyv.
3. Amit **nem** fogsz látni: az „óralátogatás" kérdés `n=0`-val és
   „Keves valasz (0 < k_numeric=5)" üzenettel. Eddig ott volt, holott
   mindenki kitöltötte.
4. Az óralátogatás **továbbra is dolgozik**, csak nem kérdésként: a 3. § (9)
   szerinti fő/alacsony kettéosztást ő vezérli. Mérve: 14 beküldésből 3-an
   választották a `0–32%` sávot → a főstatisztika `n=11`, az „alacsony
   óralátogatás" blokk pedig **elrejtve** marad, mert 3 < k_low=5.

---

## 3. Mi működik ettől, ami eddig nem

* **Kampányt lehet létrehozni és léptetni.** Eddig 19 RPC volt, egyik sem
  tudott kampányt nyitni; ma 27 van. A teljes lánc végigjátszható:
  `draft → open → closed → processing → sealed → published`.
* **Az eredmény- és moderálási motor elérhető.** Eddig meg volt írva, de nem
  lehetett odáig eljutni, mert a kapu `closed` vagy későbbi állapotot követel,
  és nem volt mivel odavinni a kampányt.
* **A hallgató a valódi kérdőívet kapja.** Nem a fájlban, hanem az
  `echo_get_form()` által ténylegesen kiszolgált űrlapon mérve:
  **13/13 kérdésszöveg, 49/49 opciószöveg és 6/6 szakaszcím** betű szerint
  megvan a prototípus `FORM_SEED`-jében.
* **A célteljesülés célonként külön kérdezhető.** A `repeat:'goal'` kérdés
  eddig SOHA nem jelent meg, mert a kitöltő lépésgenerátora nem ismerte a
  goal-lépést, és a régi verzióban ilyen kérdés nem is volt.
* **Az oktató be tud lépni a saját eredményéhez** — és csak a sajátjához.
* **A jegyzőkönyv nem hazudik az óralátogatásról.**

---

## 4. Mit mértünk

Helyi Postgres 16 replikán, Supabase-utánzattal (auth séma, `auth.uid()` a
`request.jwt.claims`-ből, anon/authenticated/service_role szerepkörök,
alapértelmezett tábla-grantok).

### 4.1 Migrációk — hibamentesség és idempotencia

| terep | mit futtattunk | eredmény |
|---|---|---|
| tiszta alap (01–10 + 11 + 15 + 16 + 17) | `18, 18b, 18c, 19, 20` **háromszor**, `ON_ERROR_STOP=1` | mind rc=0. A sorszámok az 1., 2. és 3. futás után **betűre azonosak**: `camp=2 tv=2 resp=0 elig=8 log=5` |
| adatot tartalmazó replika (44 válasz) | ugyanaz **kétszer** | mind rc=0. Előtte `camp=1 tv=4 resp=44 elig=4`, utána `camp=2 tv=4 resp=44 elig=8 log=5` — és a 2. futás után **ugyanaz**. Egyetlen válasz sem veszett el, egyetlen sor sem duplázódott. |
| sorrenden kívüli futás (`18c` a `18b` előtt) | `18c` | nem hibázik és **nem változtat semmit**: `18c: a ... verzio nem letezik. Futtasd le eloszor a 18b-t.` |

### 4.2 A 18c hatása (mérve, a 44 választ tartalmazó replikán)

```
18c: a(z) DEMO-2025-26-2 kampany nyugdijazasa (open -> sealed).
18c:   processing — bekuldottnek jelolt: 0, erintett kurzus: 3, moderalasi sor uj: 0
18c:   sealed — megkevert valasz: 44 (VISSZAFORDITHATATLAN).
18c: a 2. verzio -> review / -> approved / -> live. Lezart korabbi elo verzio: 1.
18c: uj kampany: OMHV-2025-26-2. Jogosultsagi parok: 4. A kampany MEGNYITVA.
```

### 4.3 Végigjátszás az új kampányon

* 14 jogosult hallgató, mindegyik: célmentés → jegykiadás → **anon** beküldés.
  Eredmény: **14 kurzusszintű + 28 oktatószintű válaszsor, 0 hiba.**
* A szervertől ténylegesen visszakapott űrlapon lefuttatva a kitöltő
  kliensoldali logikáját (a `features/echo.jsx` mai függvényeivel, szó szerinti
  egyezés ellenőrizve): 3 cél + 1 elvárás → **4 külön goal-lépés**, összesen
  **11 lépés**. A régi lépésgenerátorral ugyanezen az űrlapon a
  `repeat:'goal'` kérdés **egyáltalán nem jelent meg**.
* Riport `closed` állapotban: 9 kérdés, `n=11`,
  `valaszadas = {arany: 78.6, jogosult: 14, valaszok: 11}`. Az „alacsony
  óralátogatás" blokk elrejtve (3 < k_low=5) — a k_low tehát fog.

### 4.4 Az óralátogatás-hiba — előtte/utána, ugyanazon az adaton

Ugyanabban az adatbázisban, ugyanarra a kurzusra:

* **javítás előtt** a jegyzőkönyvben:
  `{"id":"attendance","n":0,"rejtve":true,`
  `"uzenet":"Keves valasz (0 < k_numeric=5): errol a kerdesrol nem adunk vissza eredmenyt."}`
* **javítás után**: a kérdés nincs a listában; a kérdéslista
  `goals_met, best_experience, missing_experience, course_strengths,
  course_improve, overall_course, overall_teaching, impact, impact_text`.

Az ok szerkezeti volt: az `echo_submit()` az óralátogatást a payload
gyökeréből a **külön `echo.response.attendance_band` oszlopba** teszi
(szándékosan, mert az oktatói soron NULL-nak kell maradnia), a riportciklus
viszont az `answers -> 'attendance'` kifejezéssel kereste. A tárolás helye és a
keresés helye sosem esett egybe. **Adat nem veszett el.**

### 4.5 Build

`npm run build` → rc=0, `app.bundle.js 1896.4 kB`. A JSX ebben a körben nem
változott, a méret változatlan.

---

## 5. Mi marad a következő fázisra

1. **Az angol fordítások jóváhagyása.** A `18b` opciószövegeinek nagy része
   MIR-fordítás. A 2. verzió szövege élesben már befagyott; javításhoz
   3. verzió kell (`echo_template_create` klónoz).
2. **A régi kampány közzététele.** A `18c` `sealed` állapotig visz, tovább nem.
   A `sealed → published` lépés a felületről, a moderálási sor kiürítése után,
   tudatos döntéssel történjen — közzététel után az oktatók is látják a
   szöveges válaszokat.
3. **Az oktatói kötések feltöltése.** A `19` megadja a kötés eszközét, de a
   `echo.teacher.profile_id` mezőket kézzel (vagy Neptun-szinkronból) kell
   kitölteni. Ma a demóban 4 oktatói sor van.
4. **Az óralátogatás sáveloszlása a jegyzőkönyvben.** Ma sehol nem jelenik meg
   számszerűen (csak a fő/alacsony kettéosztást vezérli). Ha kell, az
   `attendance_band` oszlopból kell aggregálni, `echo.suppress_cells()`-lel,
   `k_dist` küszöbbel. A `20`-as fájl ezt **szándékosan nem** teszi meg: ez új
   közlési felület, amit előbb el kell dönteni, nem mellékesen bevezetni.
5. **A célkitűzési ablak időzítése.** A `18c` az új kampánynál a célablakot
   azonnal nyitja és a kitöltési ablakkal együtt zárja (most + 60 nap). Éles
   használatban a célkitűzésnek a félév ELEJÉN kell nyitnia, jóval a
   kitöltés előtt — ezt a Kampányok fülön kell beállítani.

---

## 6. Ellenőrző lekérdezés — bármikor lefuttatható

```sql
select c.code, c.term, c.state as kampany_allapot,
       tv.version as kerdoiv_verzio, tv.state as verzio_allapot,
       (select count(*) from echo.eligibility e where e.campaign_id = c.id) as jogosultsagi_par,
       (select count(*) from echo.response  r where r.campaign_id = c.id) as valasz,
       (select count(*) from jsonb_array_elements(tv.compiled->'sections') s,
                             jsonb_array_elements(s.value->'questions') q
         where q.value->>'repeat' = 'goal') as goal_kerdes
  from echo.campaign c
  join echo.template_version tv on tv.id = c.template_version_id
 order by c.created_at;
```

Sikeres futás után elvárt: a régi kampány `sealed` / 1. verzió `closed` /
`goal_kerdes = 0`; az új kampány `open` / 2. verzió `live` / `goal_kerdes = 1`.

---

*Nem lett commitolva és nem lett pusholva — a deployról te döntesz.*
