# ECHO (OMHV) — 1. szelet: telepítés és kipróbálás

Neumann János Egyetem, 28/2023. szenátusi határozat
Változat: 2026-08-19 (az ellenőrzés megállapításainak átvezetése után)

Ez a kísérő a `15_echo_core.sql` migrációhoz és a hozzá tartozó frontend-szelethez szól.
Mindent, ami itt „mérve” szerepel, egy helyi Postgres 16 replikán tényleg lefuttattunk —
nincs benne feltételezés.

---

## 1. Mit kell futtatnod

### 1.1 Az SQL

Supabase Dashboard → **SQL Editor** → *New query* → a `15_echo_core.sql` teljes tartalmát
beilleszted → **Run**.

- A fájl **idempotens**: bátran lefuttatható többször is. Mérve: tiszta lapról kétszer,
  majd már meglévő válasz- és naplóadattal is — mindannyiszor hibátlanul, és a korábbi
  adat sértetlenül megmaradt.
- Nincs benne `psql` meta-parancs, tehát tényleg bemásolható úgy, ahogy van.
- Egyetlen tranzakcióban is lefut.
- A végén kiír egy **19 soros ellenőrző táblázatot**. Mind a 19 sor `OK` kell legyen.
  Ha bármelyik `HIBA`, ne menj tovább — szólj.

### 1.2 A Dashboard-beállítás — EZT NE HAGYD KI

**Project Settings** (fogaskerék) → **API** → „Data API” szakasz → **Exposed schemas**

> Ebben a mezőben az **`echo` NE szerepeljen**. Alapértelmezésben `public` és
> `graphql_public` áll benne — így is kell maradnia.

**Miért:** ha az `echo` bekerül a listára, a PostgREST közvetlen tábla-végpontot nyit rá
(`/rest/v1/response?select=*`). A séma jogai ettől még zárva vannak, de a végpont létrejön,
és onnantól bármelyik későbbi, véletlen `grant` azonnal kifelé nyílik. A séma kihagyása a
**második védvonal** — nem helyettesíti a jogosultság-visszavonásokat, hanem kiegészíti.

**Ugyanitt, Database → Replication → `supabase_realtime` → Tables:**
az ECHO egyetlen táblája sem kerülhet be. A realtime a WAL-folyamot a beérkezés
**sorrendjében** küldi, ami önmagában deanonimizálja a válaszokat. A migráció nem teszi be
őket — csak arra vigyázz, hogy kézzel se kerüljenek oda.

### 1.3 A frontend

A három bekötési pont már meg van csinálva (`build.mjs`, `app.html`, `app.jsx`).
Neked csak buildelned kell:

```
cd uniportal-demo && npm run build
```

Mérve: hibátlan, `app.bundle.js` = **1797,7 kB**.

### 1.4 Amit érdemes ütemezned (nem kötelező az első körben)

`echo.shuffle_responses('<kampány-uuid>')` — **naponta egyszer, éjszaka**, amíg a kampány
nyitva van, és **kötelezően** a lepecsételéskor.

Ez nem szépészeti lépés. A Postgres minden sorban tárolja a létrehozó tranzakció
azonosítóját (`xmin` rendszeroszlop) és a sorok fizikai sorrendjét (`ctid`) — mindkettő
olvasható, és mindkettő időbélyeg nélkül is árulkodik. A keverés ezeket normalizálja.
(A kód emellett külön is véd ellene, lásd 3. pont.) Kizárólagos zárat kér a táblán, ezért
nem fut automatikusan.

---

## 2. Mi működik már

- **Teljes hallgatói kitöltés**, végigmérve: kurzuslista → kérdőív + alkalmas oktatók →
  kitöltési jegy → **anonim** beküldés → visszajelzés.
- **Kettéválasztott adattárolás.** A *részvételi napló* (ki próbálkozott) és a
  *válaszhalmaz* (mit válaszolt) két külön tábla, **közös oszlop nélkül** — nincs mire
  joinolni. A válaszsoron nincs időbélyeg, a kulcsa véletlen uuid v4.
- **Az `echo` séma zárt.** Sem az `anon`, sem az `authenticated` szerepkör nem kap rá
  semmilyen jogot; minden a `public` sémás RPC-ken megy. Mérve: közvetlen olvasás
  → *permission denied for schema echo*.
- **A beküldés csak `anon` joggal megy.** Bejelentkezett (JWT-s) hívás szándékosan
  42501-gyel bukik — így a hallgató azonosítója egyetlen szerveroldali naplóban sem kerül
  a válasza mellé.
- **Szerveroldali tisztítás.** A célok szövege, számossága, e-mail, időbélyeg — ha a kliens
  beleteszi is a beküldésbe, a szerver levágja.
- **Alkalmassági motor** kizárási naplóval: 3 fő alatti kurzus, vizsgakurzus és 25% alatti
  óraarányú oktató automatikusan kimarad, okkal dokumentálva.
- **Félév eleji célmeghatározás** (ez szándékosan *nem* anonim) és félév végi értékelés.
- **Admin nézet**: kampányok, kitöltési arányok — kizárólag darabszámok, egyetlen válasz
  tartalma sem látszik menet közben.

---

## 3. Mit javítottunk ebben a körben

Az ellenőrzés két blokkoló hibát talált; mindkettő javítva és **újra lemérve**.

**(1) Többszörös beküldés és emiatt hamis „beküldte” jelölés.**
Korábban egy hallgató korlátlanul kérhetett jegyet és küldhetett be. Ettől a kötegelt
jelölő függvény *más*, soha be nem küldő hallgatót is „beküldött”-nek jelölt, aki így
véglegesen kizárta magát a kitöltésből. Javítás: kurzusonként legfeljebb **2 jegy**
(`max_tickets_per_course`), és a jelölés mostantól a **kiadott jegyek** számához hasonlít,
nem a hallgatókéhoz. Mérve: a hibás helyzet többé nem áll elő, a szabályos kitöltés
viszont továbbra is helyesen jelölődik.

**(2) A napló és a válasz összefésülhető volt az `xmin` rendszeroszloppal.**
Mivel a jegykiadás és a beküldés két egymást követő tranzakció, a válaszsor `xmin`-je
pontosan eggyel nagyobb volt a naplósorénál — egy hatsoros lekérdezés minden válaszhoz
visszaadta a kitöltő e-mail címét. Javítás: a jegykiadás ugyanabban a tranzakcióban
a kurzus **teljes kohorszának** sorverzióját frissíti, így mindenki azonos `xmin`-t kap.
Mérve: a támadó lekérdezés 1 helyett a teljes, 14 fős kohorszot adja vissza, keverés után
pedig egyetlen választ sem tud naplósorhoz kötni.

Ezeken felül: az óralátogatási sáv többé nem íródik rá az oktatói sorokra (adatbázis-szintű
kényszerrel is kikötve), a jegy lejárati mezője napi felbontású (óra pontosságú érkezési idő
nem számolható vissza), a keverő függvény kampányra szűkíthető, a migráció újrafuttatása nem
nyit újra lepecsételt kampányt, a két admin RPC kapuja szűkebb lett (a menüvel egyezően),
a külsős AGENT szerepkör kikerült a kitöltők közül, és a felület már nem ígér
„kitöltés folytatását”, mert piszkozat-mentés nincs.

---

## 4. Hogyan próbáld ki, lépésről lépésre

### 4.1 Hallgatói oldal — a kitöltő

1. Lépj be egy **STUDENT** (vagy bármely belső) fiókkal.
2. Bal oldali menü → **„Kurzusértékelés”**.
3. Három kurzust látsz kártyaként, állapotjelzővel:
   `Nem kezdett` / `Célkitűzés` / `Kész`. A demó seed 5 kurzust hoz létre, de kettő
   szándékosan kimarad — az egyik vizsgakurzus, a másikon 3 fő alatt van a létszám.
   Ez a kizárási motor működését mutatja.
4. Kattints az **„Értékelés kitöltése”** gombra.
5. A varázsló végigvezet: **óralátogatás → célteljesülés → szöveges élmények →
   kurzusértékelés → oktatónkénti értékelés → összegzés**. Oktatót ki lehet hagyni
   indoklással. Az utolsó lépés egy **áttekintő**, ahol a saját válaszaid visszanézhetők.
6. **Beküldés.** A visszaigazoló képernyő elmondja, hogy a válaszok névtelenül érkeztek be.
7. Menj vissza a listára: a kurzus állapota **`Kész`** lesz, és újra kitölteni nem tudod.

> **Figyelem — ez most még szándékosan így van:** a kitöltés közben **nincs piszkozat-mentés**.
> Ha kilépsz, a válaszok elvesznek — a felület ezt ki is írja. A piszkozat a hallgató gépére
> tenné a kitöltés tartalmát, ami külön adatvédelmi döntés; ezt neked kell meghoznod.

### 4.2 Félév eleji célmeghatározás

Ugyanezen a kártyán, ha a célmeghatározási ablak nyitva van, a **„Célok megadása”** gombbal
1–3 saját cél és 1–3 oktatói elvárás rögzíthető. Ez **szándékosan nem anonim** — a hallgató
sajátja, ő is látja később. A célok *szövege* soha nem kerül át az anonim válaszhalmazba,
csak az, hogy a célok teljesültek-e.

### 4.3 Admin oldal — a kampány

1. Lépj be **SUPERADMIN** vagy **ADMIN** fiókkal.
2. Menü → **„ECHO kampányok”**.
3. Látod a `DEMO-2025-26-2` kampányt: állapot, ablak, véleményezhető kurzusok és párok
   száma, jegyet kérők száma, beérkezett válaszok, **kitöltési arány**.
4. Megnézheted a kérdőív **előnézetét** (6 szakasz, 13 kérdés), és újra lefuttathatod az
   **alkalmassági motort**.

> Itt **nem látsz és nem is fogsz látni válasz-tartalmat** menet közben — ez tudatos.
> A kitöltésre buzdító kommunikációnak kell egy szám, az eredménynek viszont nem szabad
> a nyitott ablak alatt látszania.

### 4.4 Amit érdemes külön kipróbálnod

- Lépj be **AGENT** fiókkal: a „Kurzusértékelés” menüpont **nem jelenik meg** — külsős
  partnerügynökség nem véleményez oktatót.
- Lépj be **ADMISSIONS** vagy **FINANCE** fiókkal: az „ECHO kampányok” nem látszik, és az
  API sem engedi be — a felület és a jogosultság most már ugyanazt mondja.

---

## 5. Mit mértünk

| Mérés | Eredmény |
|---|---|
| Migráció tiszta lapról, `ON_ERROR_STOP=1` | exit 0, mind a **19** ellenőrző sor `OK` |
| Ugyanaz másodszor (idempotencia) | exit 0, 19/19 `OK`, a meglévő adat sértetlen |
| Egyetlen tranzakcióban (`psql -1`) | exit 0 |
| Teljes végigjátszás, 14 hallgató, 1 kurzus | 14 jegy → 14 válasz → mind a 14 helyesen „beküldött” |
| Ismételt jegykérés beküldés után | `ECHO_ALREADY_SUBMITTED` |
| 3. jegykérés ugyanarra a kurzusra | `ECHO_TICKET_LIMIT` (a korlát 2) |
| Hamis „beküldött” jelölés (a régi hiba) | többé nem áll elő |
| `xmin`-alapú deanonimizálás | javítás előtt **1** gyanúsított/válasz, utána **14** (a teljes kohorsz), keverés után **0 találat** |
| Óralátogatási sáv oktatói soron | adatbázis-kényszer utasítja vissza |
| 8 párhuzamos jegykérés egy kurzusra | mind a 8 sikeres, **0 holtpont** |
| `npm run build` | hibátlan, `app.bundle.js` = **1797,7 kB** |

---

## 6. Mi jön a következő körben

1. **A kérdőív valódi tartalma.** Ez a legfontosabb. A 13 kérdés **szövege** és a kizárási
   szabályok §-hivatkozásai jelenleg **rekonstrukciók** — a feladatban megadott ECHO
   prototípus-fájl ebben a környezetben nem található meg (ellenőriztük). A *szerkezet*
   használható és stabil, a *szöveg* még nem éles. Ha előkerül a prototípus, a szövegek
   egyetlen új kérdőív-verzióval kicserélhetők; a már élő verziót nem írjuk felül (a
   rendszer meg is akadályozza). **Kollégák elé csak azután vidd, hogy ezt tisztáztuk.**
2. **Hallgatói tömeges regisztráció és a Neptun-szinkron.** A törzsadat-táblák (kurzus,
   oktató, felvétel) külső azonosítóval készültek, tehát a szinkron beköthető. Addig a demó
   seed minden jóváhagyott, nem-AGENT fiókot felvesz 4 kurzusra.
3. **A szöveges válaszok moderálása.** A kérdéseken már ott a `moderated` jelző, de a
   moderálási folyamat még nincs megírva. Szabad szöveg egyedi utalással azonosíthat.
4. **Eredményközlés és pecsételés.** A kampány `closed → processing → sealed → published`
   útja megvan az adatmodellben, a hozzá tartozó felület még nem.
5. **Ütemezés.** A `pg_cron` jelenleg nincs telepítve, ezért a napi keverés és a kötegelt
   jelölés egyelőre kézi (vagy külső ütemező) — érdemes bekapcsolni.
6. **Piszkozat-mentés** — csak ha adatvédelmileg vállalod (lásd 4.1).

---

## 7. Amit őszintén ki kell mondani

- **Közös projekt.** Az ECHO ugyanabban az adatbázisban él, mint az UniPortal. Aki
  `postgres` vagy `service_role` jogot szerez — például a **Dashboard SQL Editorán** át —,
  az technikailag mindent lát. Ezt séma-elválasztással nem lehet megoldani, csak külön
  projekttel. Te tudatosan az egy-projekt felállást választottad; ezért a **Dashboard-hozzáférés
  korlátozása itt valódi adatvédelmi kontroll**, nem csak üzemeltetési kérdés.
- **Mentés / PITR.** A WAL-archívum megőrzi a tranzakciók sorrendjét, tehát egy időben
  szeletelt visszaállítás akkor is megmutatja a beérkezés sorrendjét, ha az élő táblát
  azóta megkevertük. Ez ellen csak a mentések hozzáférés-korlátozása véd.
- **Kis elemszám.** 3-4 fős kurzuson semmilyen technika nem segít: a válasz tartalma
  önmagában azonosít. Ezért van a 3 fős küszöb — az anonimitás első védvonala nem
  technikai, hanem az, hogy kis csoportot nem kérdezünk.
