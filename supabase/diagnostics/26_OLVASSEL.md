# 26_OLVASSEL.md — a kollégiumi modul átvételi leírása

Ez a kísérő a **26_dorm.sql** migrációhoz és a hozzá tartozó három felületi
nézethez tartozik. Megmondja, mit futtass, mit fogsz látni, ki mit ér el, és
mit mértünk meg ténylegesen.

---

## ⚠️ KÖTELEZŐ DASHBOARD-BEÁLLÍTÁS — az SQL önmagában nem elég

**Supabase → Project Settings → API → „Data API" → Exposed schemas**

Vedd fel a `dorm` sémát a meglévők mellé:

```
public, graphql_public, dorm
```

**Miért kell.** A `dorm` séma — az `echo`-val ELLENTÉTBEN — szándékosan kitett.
Itt nem anonimitást védünk, hanem hozzáférést szabályozunk: az `anon` szerepkör
nulla jogot kap, az `authenticated` pedig csak azt látja, amit az RLS és a
hatókörös grant enged. A felület ezért közvetlenül olvassa a sémát
(`window.sb.schema('dorm')`), és csak az írási/összetett műveletekhez hív RPC-t.

**Ha ez a beállítás hiányzik**, a felület minden kollégiumi képernyőn ezt írja:

```
Invalid schema: dorm
```

**Az `echo` séma MARADJON KINT a listáról.** Ott a rejtés maga a védelem — a
válaszhalmaz a publikálható kulccsal sem lehet címezhető.

---

## 1. Mit futtass

```bash
cd /Users/lorant/Documents/AntigravityProjects/UniPortal/uniportal-demo

# 1) A frontend újraépítése
npm run build
#    Várt kimenet:  app.bundle.js  2176.0 kB   (hibaüzenet nélkül)
```

A migráció betöltése éles Supabase-re: a `supabase/26_dorm.sql` (4196 sor)
tartalmának beillesztése az SQL editorba, egyben.

```
supabase/26_dorm.sql
```

A migráció **IDEMPOTENS** — kétszer lefuttatva ugyanaz az eredmény.

> **A visszaút.** `select public.dorm_module_rollback('IGEN, TOROLD A DORM MODULT');`
> Ez a függvény `authenticated`-től és `anon`-tól **meg van vonva**, és a
> felület **soha nem hívja** — a `DORM_api` szándékosan nem is ismeri. Amit
> nem lehet leírni, azt nem lehet véletlenül elsütni sem.

### Fontos: a felület a migráció NÉLKÜL is működik

A bekötés **defenzív**. A `dorm_my_roles()` hívása try/catch-ben fut, és ha az
RPC még nem létezik, üres szerepkörlistát veszünk fel. Ezt **mérve** is
ellenőriztük: a 26-os migráció lefuttatása **előtt** mind a három nézet
megnyílik, nem dob hibát, és kiírja, hogy

> „A kollégiumi modul adatbázis-része még nincs telepítve ezen a példányon
> (26_dorm.sql)."

A meglévő 20 menüpont láthatósága **betűre változatlan** marad.

---

## 2. Mit fogsz látni

Három új menüpont került a menü végére (20 → 23):

| Menüpont | Ikon | Kinek |
|---|---|---|
| **Kollégium** | `Building2` | üzemeltetés |
| **Karbantartás** | `Wrench` | hibakezelés |
| **Szállásom** | `BedDouble` | maga a lakó |

### Kollégium — 7 fül

A lap tetején négy mérőszám: **kihasználtság** (`dorm_occupancy_summary`),
**szabad helyek** (`dorm_free_beds`), **nyitott hibák** (`dorm_open_issues`),
**lejáró szerződések** (`dorm_lease_alerts`).

1. **Épületek** — lista + űrlap (név, cím, saját/bérelt, férőhely, gondnok,
   státusz). A bérelt sor **„Bérlemény"** jelvényt kap.
2. **Szobák** — épület szerint szűrve: szoba, szint, típus, ágyszám,
   foglaltság, állapot.
3. **Lakók** — ki hol lakik, mettől meddig, szerződés, egyenleg.
4. **Be-/Kiköltözés** — jegyzőkönyv, kulcsátadás, leltár, kaució-elszámolás.
5. **Várólista** — várakozó kérelmek prioritással, egy kattintásos ajánlattétellel.
6. **Bérlemények** — csak külsős épületekre: bérleti szerződés, rezsi,
   lejáratfigyelés, bérbeadói kapcsolat. *(INGATLAN / ADMIN)*
7. **Szerepkörök** — `dorm_role_grant` kiosztása épület-hatókörrel +
   személy-összekötés. *(KOLI_SYSADMIN / ADMIN)*

A **kihasználtság nevezője a KIADHATÓ férőhely**, nem a nyilvántartott: a
nyilvántartott szám a fenntartóé, az üzemeltetés a kiadhatót ismeri, és a
kettő különbsége az, amit magyarázni kell.

### Karbantartás — 4 fül

Bejelentések · Munkalapok · Eszközök / leltár · Időszakos feladatok.

### Szállásom — 4 fül

A lakó saját nézete. Akinek nincs elhelyezése, annak a nézet **kimondja**,
hogy nincs — nem a menüből tűnik el.

---

## 3. Ki milyen szerepkörrel mit ér el

A jogosultság **nem** a `profiles.role` enumból jön, hanem a
`dorm_my_roles()` külön, épület-hatókörös grantjaiból. Ez szándékos: a
menüszűrő utolsó ága `return false`, ezért egy új `profiles.role` érték
(pl. `GONDNOK`) **nulla** menüpontot adna. A UniPortal-szerepkör tehát marad,
ami volt, és mellé jön nulla vagy több dorm-grant.

| Menüpont | Ki látja |
|---|---|
| **Kollégium** | SUPERADMIN, ADMIN, vagy `GONDNOK` / `KOLI_ADMIN` / `INGATLAN` / `KOLI_SYSADMIN` grant |
| **Karbantartás** | SUPERADMIN, ADMIN, vagy `KARBANTARTO` / `GONDNOK` / `KOLI_ADMIN` / `KOLI_SYSADMIN` grant |
| **Szállásom** | mindenki, **az AGENT kivételével** |

Az AGENT külsős partnerügynökség — nem hallgató, nem lakik kollégiumban.

A fülön belüli láthatóság ugyanebből következik: **Lakók** és
**Be-/Kiköltözés** a `GONDNOK` / `KOLI_ADMIN` / `KOLI_SYSADMIN` köré,
**Várólista** a `KOLI_ADMIN` / `KOLI_SYSADMIN` köré, **Bérlemények** az
`INGATLAN` köré, **Szerepkörök** a `KOLI_SYSADMIN` köré szűkül.

### Adatvédelem

A **KARBANTARTO a szobát és a hibát látja, a lakó NEVÉT NEM.** Ezt az
**adatbázis** kényszeríti ki, nem a felület — a felület nem is kerüli meg.
Ahol emiatt nincs név, ott a `DORM_Hidden` komponens **kimondja**, hogy az
adat adatvédelmi okból rejtett. Üresen hagyni félrevezető lenne: az olvasó
azt hinné, nincs ott adat, holott van, csak nem neki szól.

---

## 4. Mit mértünk

Playwright, Chromium, valós bejelentkezéssel (`admin@uni.hu`), a
`python3 -m http.server 8000` kiszolgálón, a **buildelt** `app.bundle.js`-en.

### 4.1 Reszponzivitás — 3 nézet × 4 szélesség = 12 mérés

| Nézet | Szélesség | Vízszintes lapgörgetés | Kilógó elem | Fülsáv | Érintési célpont |
|---|---|---|---|---|---|
| Kollégium | 390 px | **0 px** | 0 | 7 fül, 366/958, `overflow-x:auto` → **görgethető** | 44 px |
| Kollégium | 768 px | **0 px** | 0 | 7 fül, 648/648 → kifér | 44 px |
| Kollégium | 1280 px | **0 px** | 0 | 7 fül, 936/936 → kifér | 44 px |
| Kollégium | 1920 px | **0 px** | 0 | 7 fül, 1544/1544 → kifér | 44 px |
| Karbantartás | 390 px | **0 px** | 0 | 4 fül, 366/693, `auto` → **görgethető** | 44 px |
| Karbantartás | 768 px | **0 px** | 0 | 4 fül, 648/648 → kifér | 44 px |
| Karbantartás | 1280 px | **0 px** | 0 | 4 fül, 936/936 → kifér | 44 px |
| Karbantartás | 1920 px | **0 px** | 0 | 4 fül, 1544/1544 → kifér | 44 px |
| Szállásom | 390–1920 px | **0 px** | 0 | üres állapot (az adminnak nincs elhelyezése) | — |

**A lap törzse egyetlen szélességen sem görgött vízszintesen.** Kilógó elem
sehol nincs: a szélesebb tartalom mindenütt saját `overflow-x:auto`
konténerben ül. A fülsáv 390 px-en nem lóg ki, hanem **görgethető** — pontosan
a követelmény szerint. Konzolhiba és `pageerror`: **0**.

### 4.2 A meglévő menü — nem romlott el

| Fiók | Menüpont | Ebből kollégiumi |
|---|---|---|
| `admin@uni.hu` (ADMIN) | 19 + 3 | Kollégium, Karbantartás, Szállásom |
| `admissions@uni.hu` | 12 + 1 | Szállásom |
| `finance@uni.hu` | 8 + 1 | Szállásom |
| `agent@globalstudy.com` | 5 + 0 | *(egy sem — helyesen)* |
| `ammar@test.com` (STUDENT) | 5 + 1 | Szállásom |

Minden korábbi menüpont a helyén maradt, egyik fiók sem vesztett semmit, és
`pageerror` egyik szerepkörnél sem volt.

### 4.3 Amit a mérés NEM fedett le

A 26-os migráció ezen a Supabase-példányon **még nem futott le**, ezért a
nézetek a **védekező, üres állapotukat** mutatták (a fülek, a fülváltás, a
mérőszám-csempék és az elrendezés viszont valósak és mérhetőek voltak). A
táblázatok **feltöltött** adattal való viselkedése — sok soros lista, hosszú
nevek tördelése — csak a migráció lefuttatása után mérhető. Ezt érdemes
megismételni, amint a 26-os lement.

---

## 5. Egy hiba, amit a mérés fogott meg

A bekötés első mérése **fehér lapot** adott: a „Kollégium" menüpontra
kattintva a React fa a gyökérig lebomlott, és onnantól a shell sem élt.

**Ok:** a `DORM_Loading` a közös `SkeletonRows({ rows = 5, cols })` atomot
hívta `cols` nélkül. A `cols` propnak **nem volt alapértéke**, a törzse pedig
`cols.map(...)`-ot hív — így `TypeError: Cannot read properties of undefined
(reading 'map')`. Ráadásul a `SkeletonRows` `<tr>`-eket ad vissza, amit egy
sima `<div>`-be tenni érvénytelen HTML.

**Javítva két helyen:**

- `features/dorm.jsx` — a `DORM_Loading` már **nem** használja a
  `SkeletonRows`-t: saját, táblázattól független csíkokból áll, és semmilyen
  külső propot nem igényel.
- `app.jsx` — a `SkeletonRows` `cols` propja kapott alapértéket, hogy ez a
  hibafajta ne fordulhasson elő újra. A meglévő hívók mind adnak `cols`-t,
  nekik ez betűre semmit nem változtat.

Újraépítés és újramérés után: **0 hiba, 0 vízszintes görgetés.**

---

## 6. Amihez nem nyúltunk

- `features/echo.jsx` — **bájtra érintetlen** (`git diff --quiet` igazolja).
- ECHO SQL-migrációk (15–24) — érintetlenek.
- A `filteredMenuItems` `return false` ága — változatlan.
- A `profiles.role` enum — **nem** bővült.
- Nem történt commit és nem történt push.
