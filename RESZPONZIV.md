# Reszponzív keret — összecsukható oldalsáv és dinamikus elrendezés

Ez a dokumentum azt írja le, mi változott a UniPortal keretén, mi történik az egyes
töréspontokon, és **mit mértünk meg ténylegesen** (nem becsültünk).

A mérés valódi böngészővel készült: Playwright + Chromium 151.0.7922.34, a lapot
`python3 -m http.server 8000` szolgálta ki, a bejelentkezés az alkalmazás SAJÁT
űrlapján, élő Supabase-háttérrel történt (`admin@uni.hu`, illetve a lebegő gomb
teszteléséhez `ammar@test.com`). Tehát nem csak a statikus szerkezetet néztük: a
teljes, bejelentkezett shell összes menüpontja mérve lett.

---

## 1. Mi változott

### Az oldalsáv (`app.jsx`)

Korábban egy fix, 288 px-es sáv volt beégetett `ml-72` bal margóval és **nulla**
töréspont a keretben — egy 390 px-es telefonon a tartalom ~102 px-es oszlopba szorult.

Most a sávnak három üzemmódja van, `matchMedia`-val figyelve (nem `resize`-eseménnyel,
mert az minden pixelnyi húzáskor újrarajzoltatná a teljes shellt):

| Töréspont | Üzemmód | A sáv | A tartalom bal margója |
|---|---|---|---|
| `< 768 px` | mobil | rejtve, hamburgerrel beúszó fiók | `ml-0` |
| `768–1279 px` | tablet | alapból **összecsukva** (80 px ikonsáv) | `ml-20` |
| `>= 1280 px` | asztali | alapból **kinyitva** (288 px) | `ml-72` |

### Az össze-/kinyitó gomb

Kerek, 40×40 px, a sáv **jobb szélén, függőlegesen középen**, félig rálógva — így
összecsukott állapotban is jól látható és kattintható. Ikonja `ChevronLeft` / `ChevronRight`.
`aria-label`, `aria-expanded`, `type="button"`, látható fókuszgyűrű, Enterrel működik.

### Állapot megőrzése

`localStorage` kulcs: `nje_sidebar` (`expanded` | `collapsed`). A felhasználó választása
**felülírja** a töréspont-alapértelmezést. Minden olvasás/írás `try/catch`-ben fut
(privát ablakban dobhat). A mobil fiók állapota szándékosan **nem** perzisztál.

### A tartalom újrarendeződése

A `<main>` bal margója követi a sáv állapotát, `transition: margin-left .3s ease`
átmenettel, `prefers-reduced-motion: reduce` esetén átmenet nélkül. A `min-w-0` engedi,
hogy a széles táblázatok és rácsok valóban zsugorodni tudjanak a flex-elrendezésben.

### Az ECHO alsó akciósávja és a lebegő gomb

A `features/echo.jsx` **érintetlen maradt** (tiltott volt hozzányúlni). Az ott fixen,
`left-72` értékkel pozicionált alsó akciósávot a `<body data-sidebar="...">` attribútum
alapján az `app.html` CSS-e igazítja (`collapsed` → `left: 5rem`, `hidden` → `left: 0`).
Ugyanez a CSS emeli a lebegő asszisztens-gombot a sáv fölé, amíg a kitöltő nyitva van.

---

## 2. Mit javítottunk a mérés alapján

A mérés három olyan hibát talált, ami statikus kódolvasással nem látszott:

**(a) Vízszintes lapgörgetés 360 és 390 px-en, az ECHO kampányok nézetben.**
`document.scrollingElement.scrollWidth` = 462 px egy 390 px-es viewporton. Az ok nem az
ECHO hibája volt — a táblázatait rendesen `overflow-x-auto` burkolja. A rács- és
flex-elemek CSS-alapértelmezett `min-width: auto` értéke a bűnös: ez megtiltja, hogy egy
elem a tartalma minimális szélessége alá zsugorodjon. A mért lánc:

```
span.truncate                min-content = 289 px
  -> a flex sor              min-content = 396 px
  -> .lg:col-span-2          min-content = 446 px
  -> a rács sávja 446 px lett egy 358 px-es dobozban  -> lapgörgetés
```

Javítás (`app.html`): `@media (max-width: 1023px) { main .grid > *, main .flex > * { min-width: 0 } }`.
A `flex-none` elemeket ez nem érinti, az ikonok és a rögzített vezérlők a helyükön maradnak.

**(b) Vízszintes görgetés 1024 px-en, kinyitott sávval, a Riportok nézetben.**
`scrollWidth` = 1043 px. Ekkor a `lg:grid-cols-3` rács 672 px-en három oszlopot nyit, így
egy kártya belső szélessége 158 px — a benne ülő `h4` leghosszabb szava viszont 209 px.
A magyar összetett szavak rendszeresen ilyen hosszúak. Javítás: `main { overflow-wrap: break-word; }`.
Ez csak azt a szót töri meg, amelyik másképp kilógna; a `truncate` / `nowrap` elemeket nem érinti.

**(c) A keresőmező kilógott 768 px-en, kinyitott sávval (Jelentkezés és Felvételi).**
Ott a tartalomsáv csak 432 px, a `md:` töréspont viszont a **viewportot** nézi, ezért már
egy sorba rendezte a címsort és a keresőt. Javítás: `md:flex-wrap` — ha a kettő nem fér
egy sorba, a kereső új sorba kerül ahelyett, hogy 0-ra nyomódna össze (a mező bal/jobb
belső margója ilyenkor is 56 px marad, ez tolta korábban 802 px-re a lapot).

**(d) A mobil fiók billentyűzetről gyakorlatilag elérhetetlen volt.**
Megnyitás után a fókusz a lap törzsében maradt — 10 Tab sem vitte be a menübe, mert az
oldalsáv a DOM-ban előbb áll, mint a tartalom. Javítás: nyitáskor a fókusz a bezáró
gombra kerül, a fiók `role="dialog" aria-modal="true"` lesz, a Tab körbejár benne
(fókuszcsapda), záráskor pedig a fókusz visszatér a hamburger gombra.

**(e) Az `aria-label` angol módban magyar maradt.**
Az i18n réteg a `title` és `placeholder` attribútumot fordította, az `aria-label`-t nem —
a képernyőolvasó viszont az `aria-label`-t részesíti előnyben. Így a vak felhasználó
angol módban is magyarul hallotta volna az oldalsáv gombjait. Az `attrs()` mostantól az
`aria-label`-t is fordítja.

---

## 3. A MÉRT eredmény

### Vízszintes görgetés és kilógó elemek

8 szélesség × 18 nézet × kétféle sávállapot, bejelentkezve, admin szerepkörrel.
A "kilógó elem" számlálásból kihagytuk a szándékosan vízszintesen görgethető
konténerek (`overflow-x: auto`) tartalmát.

| Szélesség | Alap üzemmód | Sáv | `<main>` | Vízszintes görgetés | Kilógó elem |
|---|---|---|---|---|---|
| 360 | hidden | – (fiók) | 360 px | nincs | 0 |
| 390 | hidden | – (fiók) | 390 px | nincs | 0 |
| 768 | collapsed | 80 px | 688 px | nincs | 0 |
| 1024 | collapsed | 80 px | 944 px | nincs | 0 |
| 1280 | expanded | 288 px | 992 px | nincs | 0 |
| 1440 | expanded | 288 px | 1152 px | nincs | 0 |
| 1920 | expanded | 288 px | 1632 px | nincs | 0 |
| 2560 | expanded | 288 px | 2272 px | nincs | 0 |

Átkapcsolt (a felhasználó által felülírt) sávállapotban ugyanígy: **egyetlen nézetben
sincs vízszintes görgetés és nincs kilógó elem**.

### Mennyivel nő a tartalom összecsukáskor

| Szélesség | Kinyitva | Összecsukva | Nyereség |
|---|---|---|---|
| 1280 | 992 px | 1200 px | **+208 px** |
| 1440 | 1152 px | 1360 px | **+208 px** |
| 1920 | 1632 px | 1840 px | **+208 px** |
| 2560 | 2272 px | 2480 px | **+208 px** |

A felszabaduló helyet a tartalom tényleg megkapja. A Riportok kártyarácsa mérve:

| Szélesség | Rács kinyitva | Rács összecsukva |
|---|---|---|
| 1280 | 3 oszlop / 928 px | 3 oszlop / **1136 px** |
| 1440 | 3 oszlop / 1088 px | 3 oszlop / **1296 px** |
| 1920 | 4 oszlop / 1568 px | 4 oszlop / 1656 px |
| 2560 | 4 oszlop / 1656 px | 4 oszlop / 1656 px |

2560 px-en a rács szélessége nem nő tovább: ott a `2xl:max-w-[1720px]` olvashatósági
korlát köt be, és a tartalom középre igazodik. Ez szándékos — a hosszú olvasószöveg
ne nyúljon a végtelenbe.

### Hozzáférhetőség

| Ellenőrzés | Mért eredmény |
|---|---|
| Gomb `aria-label` | „Menü összecsukása” / „Menü kinyitása” (angol módban „Collapse menu”) |
| Gomb `aria-expanded` | `true` kinyitva, `false` összecsukva |
| Érintési célpont | 40 × 40 px |
| Függőleges pozíció | `cy` = 450 px egy 900 px magas ablakban — pontosan középen |
| Billentyűzet | fókuszálható (`tabIndex` 0), **Enter kapcsol** (`collapsed` → `expanded`) |
| Látható fókusz | `box-shadow: 0 0 0 2px fehér, 0 0 0 4px #d06700`, `:focus-visible` illeszkedik |
| Állapot megőrzése | `localStorage` = `expanded`, újratöltés után is `expanded` |
| `prefers-reduced-motion` | a sáv és a `<main>` `transition-duration` értéke **0s** |
| Zárt mobil fiók | `visibility: hidden`, `aria-hidden="true"`, 30 Tab alatt **0×** kapott fókuszt |
| Nyitott mobil fiók | `role="dialog"`, `aria-modal="true"`, fókusz a bezáró gombon |
| Fókuszcsapda | 28 Tab és 10 Shift+Tab alatt **0×** szökött ki a fiókból |
| Esc | zárja a fiókot, és a fókuszt visszaadja a hamburgernek |
| Háttérre kattintás | zárja a fiókot |
| Háttérgörgés | nyitott fióknál `body.style.overflow = 'hidden'` |

### A lebegő gomb és az ECHO alsó akciósávja

Hallgatói fiókkal, megnyitott ECHO kitöltővel mérve:

| Szélesség | A sáv `left` értéke | Átfedés a gombbal | Takart gomb a sávban |
|---|---|---|---|
| 390 | 0 px | **nincs** | 0 |
| 768 | 80 px | **nincs** | 0 |
| 1024 | 80 px | **nincs** | 0 |
| 1216 | 80 px | **nincs** | 0 |
| 1440 | 288 px | **nincs** | 0 |

A lebegő gomb `bottom` értéke a kitöltőben 97 px — pontosan az akciósáv fölé emelkedik.

### Nem romlott el

- **A 20 menüpont sorrendje és láthatósága változatlan**, összecsukott sávban is mind a 20 elérhető
  (ott a felirat `title` attribútumként jelenik meg).
- **Az `features/echo.jsx` bájtra érintetlen** (`git diff` üres).
- **A landing (`index.html`)** mind a 8 szélességen tiszta: nincs vízszintes görgetés, 0 kilógó elem.
- **A nyelvváltás működik**: angol módban 20 menüpont, „FEED / PROGRAMS / DEGREES”.
- **`npm run build` fut** (`app.bundle.js`, ~2005 kB).

---

## 4. Amit nem mértünk / korlátok

- Csak **Chromium**mal mértünk. Safari és Firefox nem futott. A `matchMedia` régi
  `addListener` ága kódban kezelve van, de nem lett élőben tesztelve.
- Csak **admin** és **hallgató** szerepkörrel mértünk. A menüszűrés többi ága
  (ADMISSIONS, FINANCE, AGENT, OKTATÓ) kódszinten változatlan, de nem lett végigkattintva.
- Az `AI ASSZISZTENS` nézetet a körbejárás kihagyta, mert modális felületet nyit.
- A **valódi eszközökön** (iOS Safari dinamikus címsáv, Android billentyűzet) nem volt mérés.
- A méréskor a Recharts `ResponsiveContainer` átméretezés után ~2–3 másodpercig
  elavult szélességet jelenthet. Ez **átmeneti**: 6×1,5 s-os mintavétellel ellenőrizve
  a végállapot minden esetben helyes. A jelenség nem befolyásolja a valódi használatot.

---

## 5. Fájlok

| Fájl | Mi történt |
|---|---|
| `app.jsx` | oldalsáv-állapotgép, összecsukható sáv, mobil fiók + fókuszkezelés, keresőmező javítás, `aria-label` fordítás |
| `app.html` | keret-CSS: átmenetek, `data-sidebar` szabályok, ECHO alsó sáv igazítása, `min-width: 0`, `overflow-wrap` |
| `features/echo.jsx` | **érintetlen** |
| `RESZPONZIV.md` | ez a dokumentum |
