# 25_OLVASSEL.md — a státuszmodell és a tesztelői kör átvételi leírása

> **A fájlnévről.** A munkacsomag `23_status_model.sql`-t és `23_OLVASSEL.md`-t kért.
> A 23-as és a 24-es sorszámot időközben az ECHO-ág foglalta el
> (`23_echo_form_rules.sql`, `24_echo_form_v3.sql`), ezért a migráció **25**-ös lett,
> és ez a kísérő is ahhoz igazodik. Két azonos sorszámú migráció a betöltési
> sorrendet tenné kiszámíthatatlanná. Tartalmilag semmi nem változott.

---

## 1. Mit futtass

Sorrendben, a projekt gyökeréből.

```bash
cd /Users/lorant/Documents/AntigravityProjects/UniPortal/uniportal-demo

# 1) A frontend újraépítése
npm run build
#    Várt kimenet:  app.bundle.js  ~1994 kB   (hibaüzenet nélkül)

# 2) A migráció betöltése a helyi replikára
export PGHOST=/tmp/upg2 PGPORT=55432 PGUSER=postgres
psql -d fresh -v ON_ERROR_STOP=1 -f supabase/25_status_model.sql
#    Várt: egyetlen ERROR sem. A migráció IDEMPOTENS — nyugodtan futtasd újra.

# 3) Az ellenőrző lekérdezés
psql -d fresh -f supabase/diagnostics/25_ellenorzes.sql
#    Várt: mind a 18 sor "OK" jelzéssel.

# 4) A nyelvi lefedettség mérése (a szótárat magától újragenerálja)
node supabase/diagnostics/i18n/covcheck.mjs
#    Várt: "A2 LEFEDETTSÉG: 584/585 = 99.8%"
```

Éles Supabase-re a 2. lépés a `25_status_model.sql` tartalmának beillesztése az
SQL editorba. **Előtte** érdemes a 3. lépést a replikán lefuttatni.

---

## 2. Mit fogsz látni

### A felvételi lista (Jelentkezés és Felvételi)

- A lista fölött megjelent egy **státusz-szűrő sáv** (B1): balra egy kiemelt
  gyorsgomb („Dokumentum-ellenőrzésre vár"), mellette az „Összes", majd
  státuszonként egy-egy gomb, mindegyiken a **darabszámmal**. A gyorsgomb azért
  külön, mert a napi munka bemenete az, hogy ki vár ellenőrzésre.
- Az „Action" oszlop neve **„Műveletek"** (B2). A korábbi, magában álló szem-ikon
  helyén most feliratos gomb áll: **„Részletek megnyitása"**, tooltipben pedig
  „A jelentkező adatlapja: státusz, szak, pénzügy és a beiratkozás utáni sávok."
  A tesztelői észrevétel pontosan az volt, hogy a puszta ikonról nem derült ki,
  mit csinál.
- A **Conditional** gomb csak `Bírálatra jelölve` állapotban jelenik meg — a
  feltételes felvételi levél a bírálat UTÁN esedékes, nem beadás után.

### A jelentkezői adatlap (a sor megnyitásakor)

- **Felvételi állapot**: a teljes lánc egy pillantásra, a mai állapot kiemelve,
  a már megtett lépések pipával. Alatta egy legördülő, ami **csak a megengedett
  következő állapotokat** kínálja (`→` előre, `↩` visszalépés).
- **Beiratkozás utáni sávok** (C2): három egymástól független doboz — Vízum,
  Halasztás, Visszatérítés. Mindhárom külön halad, egyszerre is futhatnak, és a
  fő státusz közben végig „Felvéve" marad.
- Nem-ügyintéző szerepkörnek a legördülő helyett ez látszik:
  „A státuszt csak felvételi ügyintéző módosíthatja."

### A hallgatói portál

- **Fizetési tudnivalók** (H1): a jelentkezési azonosító külön, kiemelt dobozban,
  monospace betűvel, **egy kattintással vágólapra másolható** („Másolás" →
  „Másolva"), alatta a magyarázat: „Ezt írd az átutalás közlemény rovatába."
- **AI interjú-gyakorlás** (I1): a szöveg egyértelműsíti, hogy *„Ez gyakorlás,
  nem a valódi felvételi interjú"*, a felvétel a böngészőben marad
  (`localStorage`), és a bírálati nézetben külön ki van írva, hogy szándékosan
  nem jelenik meg ott.

### A demó belépő

- A **Student** gomb az első, kiemelt színnel és „· default" jelöléssel (A1).

---

## 3. Mit mértünk

Minden szám mérés, nem becslés. A módszer a `diagnostics/i18n/` szkriptekben és a
`25_ellenorzes.sql`-ben visszajátszható.

### Build és ütközés

| Mit | Eredmény |
|---|---|
| `npm run build` | exit 0, `app.bundle.js` 1994,8 kB |
| Merge-marker (`<<<<`/`>>>>`) | **0** az app.jsx / index.html / features / 25_status_model.sql fájlokban |
| Duplikált legfelső szintű definíció | **0** |
| Menüpontok száma | **20** (17 + 3 ECHO) — karakterre azonos a kiindulási állapottal |
| `features/echo.jsx` | **érintetlen** (utolsó írás 10:10, a mi körünk 11:05-kor indult) |
| ECHO SQL 15–24 | **érintetlen** |

A három munkacsomag nem írta felül egymást: mindegyik külön régióhoz nyúlt, az
i18n-csomag pedig szándékosan `Object.assign(HU_EN, {...})` blokkokkal dolgozott
a nagy szótárliterál szerkesztése helyett, hogy kicsi legyen az ütközési felület.

### SQL — 25_status_model.sql

Tiszta adatbázison (01→14 betöltve, majd a migráció **háromszor** egymás után):

| Mit | Eredmény |
|---|---|
| 1., 2., 3. futás | exit 0, **0 db ERROR** — idempotens |
| Katalógus | 7 státusz, **13** fő átmenet (ebből 6 visszalépés), 10 sáv-állapot, **27** sáv-átmenet |
| Érvénytelen státuszú `students` sor | **0** |
| `status_legacy` kitöltetlen sor | **0** |

Az átvezetés (11 sor, mérve a migráció előtt és után):

| Eredeti | Új | Sor | Indok |
|---|---|---|---|
| `Accepted` | `Accepted` | 3 | változatlan |
| `Draft` | `Draft` | 1 | változatlan |
| `Submitted` | `Submitted` | 2 | változatlan |
| `Missing Info` | `Submitted` | 2 | a hiánypótlás a dokumentumoké, nem a jelentkezésé |
| `Paid` | `Accepted` | 3 | a fizetés pénzügyi tény; korábban FELÜLÍRTA a bírálati döntést |

> A `fresh` replikán egy sor `Draft → Nominated` eltérést mutat. Ez **nem** az
> átvezetés hibája: korábbi kézi átmenet-teszt maradványa. Tiszta adatbázison az
> átvezetés a fenti táblázat szerint pontos.

Az állapotgép viselkedése (mérve):

| Teszt | Eredmény |
|---|---|
| `Draft → Accepted` (tiltott ugrás) | **elbukik**, és felsorolja, mi engedett |
| Ismeretlen státusz (`'Banana'`) | **elbukik**, felsorolja a katalógust |
| `Draft → Submitted` (szabályos) | átmegy |
| INSERT `Nominated` státusszal | **elbukik** — új jelentkezés csak a lánc elejéről indulhat |
| `Failed → Accepted` | **elbukik** — a `Failed` végállapot (D1) |
| `Failed → Nominated` (explicit újranyitás) | átmegy, **`STUDENT_STATUS_ROLLBACK`-ként naplózva** |
| Előrelépés | `STUDENT_STATUS_CHANGE`-ként naplózva |

A három sáv (D2) egyszerre futtatva: `visa=waiting` + `deferral=requested` +
`refund=requested` egy soron, a fő státusz közben végig `Accepted`. A refund sáv
két lépés után `bank_details_provided`; a `requested → processed` ugrás **elbukik**,
és a `visa_state='letter_sent'` (átszivárgás másik sávból) is **elbukik**.

### Jogosultság — nem romlott el

| Szerepkör | Művelet | Eredmény |
|---|---|---|
| STUDENT (saját sor) | `status`, `tuitionFee`, `visa_state`, `refund_state` átírása | **mind visszaáll** az eredetire (oszlopvédő trigger) |
| ADMISSIONS | `visa_state` átírása | **átmegy** |

A 11-es migráció `students_protect_identity_trg` triggere a helyén van, és a
C2 új oszlopait is védi a `students_protect_tracks_trg`. Fontos részlet: a
védőtrigger **nem hibát dob, hanem visszaállítja** a régi értéket — ezért az
`UPDATE 1` válasz önmagában nem jelenti, hogy a mező meg is változott.

### Nyelvi lefedettség (A2)

| Mit | Előtte (HEAD) | Utána |
|---|---|---|
| Szótári tételek | **250** | **1084** |
| Kifejezés-regexek | **25** | **40** |
| Fordítható magyar felületi szöveg | 446 | 585 |
| Ebből lefordítva | **120 (26,9 %)** | **584 (99,8 %)** |
| Lefordítatlan | **326** | **1** |

Az egyetlen maradék a `Dr. Kovács István` személynév — helyesen nem fordítjuk.
A feature-modulok (`programs`, `feed`, `assistant`, `registrations`) 100 %-on állnak.

### Az ECHO kérdőív védelme — nem sérült

| Mit | Eredmény |
|---|---|
| `ECHO_Src` burkoló | a helyén (`features/echo.jsx:109`) |
| `data-echo-noi18n` render-hely | **60** |
| `NO_I18N` + `FILTER_REJECT` ág a `setupI18n`-ben | a helyén |
| Kérdőív-szöveg burkolat nélkül | **0** (minden `q.label` / `o.label` `ECHO_Src`-ben) |
| Magyar kérdőív-szöveg az élő sablonban | 18 |
| Ebből szótári kulcsütközés | **0** |
| Ebből kifejezés-regex találat | **0** |

Kettős védelem: még ha a `[data-echo-noi18n]` ág ki is esne, a fordító
**egyetlen** kérdőív-szöveget sem írna át, mert egyik sem szerepel kulcsként és
egyik sem illeszkedik regexre.

---

## 4. Amit javítottunk ebben a körben

**1. Néma hiba a „Felvételi levelek" fülön (major).**
A `renderOffers()` „Generálás & Küldés" gombja bármelyik kiválasztott
jelentkezőre `Conditionally accepted`-re állította a státuszt. Az állapotgép ezt
minden `Nominated`-en kívüli állapotból elutasítja — a hibaüzenet viszont csak a
„Jelentkezések" alnézetben volt kirajzolva, így ezen a fülön **nyomtalanul
elveszett**: a felhasználó annyit látott, hogy a gomb nem csinál semmit.
Javítva: a gomb `Nominated`-en kívül **tiltott**, tooltipben és a gomb alatt
megindokolva, és a státuszhiba-sáv ezen a fülön is megjelenik.
A jelentkezési listán lévő testvérgomb már eddig is helyesen volt őrizve — ez a
C1 fél-átvezetésének tipikus maradéka volt.

**2. A javításhoz tartozó két új szöveg** bekerült a `STATUS_I18N` szótárba, hogy
a lefedettség ne csökkenjen.

A „Végleges Felvételi (Unconditional)" kártya gombjának nincs `onClick`-je —
tiszta látványelem, nem tud elbukni, ezért nem nyúltunk hozzá.

---

## 5. Ami a következő körre marad

1. **Hét ütköző szótárkulcs** (mind kozmetikai, egyik sem hagy szöveget
   lefordítatlanul). A későbbi értékadás nyer:
   `Összes` → „All", `Egyéni jelentkező` → „Direct applicant",
   `Tandíj` → „Tuition" (a pontosabb „Tuition fee" helyett),
   `Folyamatban` → „In Progress" (máshol „In progress" — nagybetűzés),
   `Képzés neve` → „Programme name", `Nincs elkezdve` → „Not started",
   és egy fizetési mondat két megfogalmazása. Érdemes egyszer végigvinni egy
   egységes nagybetűzési szabályt. A `build.mjs` jelenleg elnyomja ezt a
   figyelmeztetést (`logOverride: duplicate-object-key`) — a takarítás után ezt
   is vissza lehetne kapcsolni.
2. **A demó belépő e-mail mezőjének helyőrzője** még `admin@uni.hu`-t javasol,
   pedig már a Student az alapértelmezett (A1). Egysoros igazítás.
3. **A `fresh` replika `students` táblájára nincs `authenticated` GRANT**, ezért a
   szerepkör-szimuláció önmagában „permission denied"-ot ad. Ez a replika hiánya,
   nem a migrációé (a 25-ös nem nyúl a students jogosultságaihoz) — de a
   jogosultsági teszteléshez a bootstrapet érdemes kiegészíteni.
4. **A 15_echo_core.sql nulláról nem fut le** (`ECHO_SEAL_IRREVERSIBLE`), ezért a
   teljes 01→25 lánc tiszta adatbázison megszakad. Az ECHO-ág területe, nem
   nyúltunk hozzá — de a következő tiszta telepítés előtt rendezni kell.
5. **D3–D6** (több programra jelentkezés, levélsablon-motor, CEFR nyelvi
   készségek, ügynökségi jóváhagyás) szándékosan nem része ennek a csomagnak.

---

## 6. Visszaút

A migráció visszafordítható. A `students.status_legacy` oszlop az eredeti
értéket őrzi, és a `public.status_model_rollback()` vissza is írja:

```sql
select public.status_model_rollback();
```

A függvényt csak a `postgres` szerep hívhatja
(`revoke all ... from public, anon, authenticated`).
