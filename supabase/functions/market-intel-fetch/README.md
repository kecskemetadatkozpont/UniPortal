# Piacfigyelő betöltés — mi kell az Apify oldaláról

A UniPortal-oldal kész: a `112_market_intel.sql` migráció és a
`features/market-intel.jsx` képernyő adat nélkül is működik (a **Források**
fülön fel lehet venni, mely intézmény mely csatornáját figyeljük). Ez a
dokumentum azt írja le, mi hiányzik még, és milyen alakban kell megérkeznie.

## 1. Amit be kell állítani (egyszeri)

| Mi | Hol | Megjegyzés |
| --- | --- | --- |
| Apify-fiók | apify.com | Fizetős sáv kell az ütemezett futáshoz |
| `APIFY_TOKEN` | Supabase secret | Personal API token. **Kódba, repóba soha** |
| `MI_WEBHOOK_SECRET` | Supabase secret | Amit a webhook URL-jébe teszünk (`?kulcs=…`) |
| Actor-választás | Apify Store | Platformonként egy; a kimenet mezőnevei kellenek |
| Ütemezés | Apify Schedule | Napi egy futás forrásonként, ajánlott 03:00 |
| Webhook | Apify Actor → Webhooks | `ACTOR.RUN.SUCCEEDED` → a lenti URL |

Webhook URL:

```
https://<projekt>.supabase.co/functions/v1/market-intel-fetch?kulcs=<MI_WEBHOOK_SECRET>&forras=<mi.source.kulcs>
```

A `forras` a **Források** fülön megadott kulcs (például `obuda-instagram`).
Egy Actor-futás = egy forrás. A függvény a webhook törzséből a
`resource.defaultDatasetId`-t használja, és onnan tölti le a tételeket.

Telepítés:

```bash
supabase functions deploy market-intel-fetch --no-verify-jwt
```

A `--no-verify-jwt` kötelező: az Apify nem küld Supabase JWT-t. A hívót a
`MI_WEBHOOK_SECRET` azonosítja.

## 2. Milyen mezőkre van szükségünk

Ez a lényegi kérdés: az Actor kimenetében ezeknek kell szerepelniük. A nevük
mindegy — a **Források** fül `mezo_terkep` mezőjében meg lehet adni, melyik
Actor-mező melyik a miénk. Ami nem jön meg, az `null` marad; **találgatni nem
szabad**.

### Közösségi oldal (Facebook, Instagram, TikTok, YouTube, LinkedIn)

| Amire szükségünk van | Mire használjuk | Kötelező |
| --- | --- | --- |
| követőszám | Követő Δ, részesedés | igen |
| poszt azonosítója | ne duplikáljunk | igen |
| poszt dátuma | idősor, „utolsó poszt” | igen |
| like / komment / megosztás (vagy kész bevonás-szám) | átlagos bevonás | igen |
| formátum (reel, videó, karusszel, kép) | tartalmi döntés | ajánlott |
| nyelv | kinek beszél valójában | ajánlott |
| poszt URL | visszakereshetőség | ajánlott |

**Amit nem kérünk és nem is tárolunk:** a poszt szövege, a kommentek, a
kommentelők és a követők adatai.

### Hirdetéskönyvtár (Meta Ad Library, TikTok, Google)

| Amire szükségünk van | Mire használjuk |
| --- | --- |
| hirdetés azonosítója | egyediség |
| első és utolsó megjelenés dátuma | futamidő — ami 30 napnál tovább fut, az náluk működik |
| célországok | országtábla, „hova tolnak pénzt” |
| hirdető neve | melyik intézményhez tartozik |
| kreatív főcíme vagy rövid szövege | téma-kategória |
| landing URL | mire viszi a jelentkezőt |

Becsült költést **nem** kérünk: a hirdetéskönyvtár nem ad összeget.

### Weboldal-figyelés

| Amire szükségünk van | Példa |
| --- | --- |
| mező neve | `tandij`, `hatarido`, `kinalat` |
| aktuális érték | `2700 EUR` |

A változást mi számoljuk: ha az érték más, mint a legutóbbi, bekerül a
naplóba és riasztás lesz belőle. Az Actornak elég a mindenkori értéket küldeni.

### Keresleti index (Google Trends)

ország · kulcsszó · hét (ISO dátum) · index (0–100).

## 3. A kanonikus köteg

Ha valaki más gyűjtővel dolgozik (nem Apify), elég ezt az alakot POST-olni
ugyanarra az URL-re — leképezés nélkül beérkezik:

```json
{
  "forras": "obuda-instagram",
  "pillanatkep": { "nap": "2026-09-30", "kovetok": 9100, "poszt_db": 6, "bevonas": 2700 },
  "posztok": [
    { "kulso_id": "o2", "kelt": "2026-09-29T10:00:00Z", "url": "https://…",
      "formatum": "reel", "nyelv": "en", "bevonas": 1200, "tema": "tandij" }
  ],
  "hirdetesek": [
    { "kulso_id": "ad1", "platform": "facebook", "intezmeny": "Óbudai Egyetem",
      "elso_latas": "2026-08-20", "utolso_latas": "2026-09-30",
      "orszagok": ["Nigeria", "India"], "tema": "osztondij",
      "landing_url": "https://…", "kreativ": "Apply now for the autumn intake" }
  ],
  "web":   [ { "mezo": "tandij", "uj": "2700 EUR" } ],
  "trend": [ { "orszag": "Nigeria", "kulcsszo": "study in hungary",
               "het": "2026-09-28", "ertek": 68 } ],
  "ures": false
}
```

`"ures": true` azt jelenti, hogy a gyűjtő **nem talált semmit** (a forrásoldal
átalakult, a szelektor nem fog). Ilyenkor nem frissítjük a forrás „utolsó
adat” bélyegét, és két nap után riasztás lesz belőle — enélkül a felület
csendben nullát mutatna, ami rosszabb, mint a hibajelzés.

A betöltés idempotens: ugyanaz a köteg kétszer lefuttatva nem duplikál.

## 4. Mit lehet ellenőrizni deploy előtt

A terv lekérdezhető, és megmutatja, mit vár a rendszer:

```
GET .../market-intel-fetch?kulcs=<MI_WEBHOOK_SECRET>&terv=1
```

Válasz: a **Források** fülön felvett sorok — kulcs, intézmény, csatorna, cím,
mezőtérkép. Ezt kell az Actor bemenetévé tenni.

## 5. Jogi keret

A gyűjtés csak nyilvános intézményi kommunikációra és hivatalos
hirdetéskönyvtárakra terjed ki. Bejelentkezés mögötti tartalmat, privát
csoportot, álprofilt nem használunk. A Facebook- és Instagram-oldalak
poszt-metrikájára a tiszta út a **Meta Content Library** kutatói hozzáférése
(egyetemi kutatói státusz kell); amíg ez nincs meg, a hirdetéskönyvtár, a
weboldal-figyelés és a Trends önmagában is működik — ezekhez nem kell külön
engedély.
