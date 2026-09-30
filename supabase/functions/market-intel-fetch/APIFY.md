# Apify beállítás — négy feladat, négy webhook

A betöltő egy futásból **több forrást is szét tud osztani**, ezért nem kell
forrásonként külön feladat: platformonként egy elég. A tételeket a kezelőnevük
(illetve a hirdetőnevük) alapján kötjük a megfelelő forráshoz; ami egyikhez
sem köthető, azt a válasz `arva` mezője kimondja — nem tűnik el némán.

A webhook URL mindig ilyen alakú:

```
https://mdccyastwhzwtyukxlpk.supabase.co/functions/v1/market-intel-fetch?kulcs=<MI_WEBHOOK_SECRET>&platform=<platform>
```

Minden feladatnál: **Integrations → Webhooks → Add webhook**, esemény
`ACTOR.RUN.SUCCEEDED`, a payload sablon maradhat az alapértelmezett (abban van
a `defaultDatasetId`, ebből tölti le a függvény a tételeket).

---

## 1. Instagram — `apify/instagram-profile-scraper`

Egy találat profilonként, és **benne jön az utolsó 12 poszt a metrikáikkal** —
ezért ez adja a legtöbb adatot a legkevesebb pénzért. Mezőtérkép nem kell.

Bemenet:

```json
{
  "usernames": [
    "uni_neumann",
    "obudaiegyetem",
    "dunaujvarosiegyetem",
    "universityofdunaujvaros",
    "metropolitanbudapest",
    "universityofdebrecen_official"
  ]
}
```

Webhook: `…&platform=instagram` · Ütemezés: naponta 03:00

## 2. TikTok — `clockworks/tiktok-scraper`

Videónként fizet, ezért **heti 2–3 futás** elég, nem napi. A követőszám a
tételekbe ágyazva jön (`authorMeta.fans`) — ezt a betöltő olvassa.

Bemenet:

```json
{
  "profiles": [
    "uni_neumann",
    "obudai.egyetem",
    "dunaujvarosiegyetem",
    "metropolitanbudapest",
    "universityofdebrecen"
  ],
  "resultsPerPage": 15,
  "shouldDownloadVideos": false,
  "shouldDownloadCovers": false
}
```

A letöltés-kapcsolók azért vannak kikapcsolva, mert külön díjasak, és a
videófájlra nincs szükségünk — csak a számokra.

Webhook: `…&platform=tiktok` · Ütemezés: hétfő és csütörtök 03:00

## 3. Facebook hirdetéskönyvtár — `apify/facebook-ads-scraper`

Ez az egyetlen forrás, ami megmutatja, **mire tesznek pénzt**: kreatív,
futamidő, célország. Jogilag is a legtisztább — hivatalos, nyilvános
hirdetéstár. Tételenként a legdrágább, ezért **heti egy futás**.

A hirdetéseket a **hirdető neve** köti a forráshoz, ezért az intézménynévnek
egyeznie kell a Források fülön szereplővel (a 115-ös szkript ezt így vette fel).

Bemenet — hirdetőnként egy keresés, országkorlát nélkül:

```json
{
  "urls": [
    { "url": "https://www.facebook.com/ads/library/?active_status=all&ad_type=all&country=ALL&q=Neumann%20J%C3%A1nos%20Egyetem" },
    { "url": "https://www.facebook.com/ads/library/?active_status=all&ad_type=all&country=ALL&q=%C3%93budai%20Egyetem" },
    { "url": "https://www.facebook.com/ads/library/?active_status=all&ad_type=all&country=ALL&q=Duna%C3%BAjv%C3%A1rosi%20Egyetem" },
    { "url": "https://www.facebook.com/ads/library/?active_status=all&ad_type=all&country=ALL&q=Budapesti%20Metropolitan%20Egyetem" },
    { "url": "https://www.facebook.com/ads/library/?active_status=all&ad_type=all&country=ALL&q=Debreceni%20Egyetem" }
  ],
  "count": 50
}
```

Webhook: `…&platform=ads` · Ütemezés: hétfő 03:00

> A `count` korlát szándékos: enélkül egy nagy hirdető több száz tétellel is
> jöhet, és a számla a meglepetés része lenne.

## 4. Facebook posztok — `apify/facebook-posts-scraper` (ráér)

Követőszámot **nem ad**, csak poszt-metrikát, ezért csak félig tölti ki a
képet. Akkor érdemes bekapcsolni, ha az első három már fut.

Bemenet:

```json
{
  "startUrls": [
    { "url": "https://www.facebook.com/neumann.egyetem/" },
    { "url": "https://www.facebook.com/ObudaiEgyetem/" }
  ],
  "resultsLimit": 20
}
```

Webhook: `…&platform=facebook` · Ütemezés: hetente

---

## Ellenőrzés az első futás után

A webhook válasza megmondja, mi történt:

```json
{ "ok": true, "mod": "apify", "tetel": 6,
  "forrasok": [ { "forras": "obuda-instagram", "tetel": 1, "ok": true } ],
  "arva": 0 }
```

- **`arva` > 0** → van olyan tétel, amit egyik forráshoz sem tudtunk kötni.
  Az `arva_minta` megmutatja, melyik profilról van szó: valószínűleg elgépelt
  cím a Források fülön, vagy olyan profil került az Actor bemenetébe, ami
  nincs felvéve.
- **`tetel: 0` egy forrásnál** → az Actor nem hozott róla semmit. A rendszer
  ilyenkor üres futást jegyez, és két nap után riasztást ír ki — nem hallgat.
- A függvény naplója (Supabase → Edge Functions → market-intel-fetch → Logs)
  a titok-hibát is kimondja.

## Költség

Az Apify **ingyenes csomagja havi 5 dollár keretet** ad. A fenti ütemezéssel az
1. és 2. feladat ebbe belefér; a hirdetéskönyvtár már nem. Éles üzemre a
**Starter 19 dollár/hó**, plusz nagyságrendileg 5–10 dollár tényleges gyűjtés.

Egységárak (2026-09-30):
Instagram $2,30 / 1000 profil · TikTok $1,70 / 1000 videó ·
Ad Library $5,00 / 1000 hirdetés · Facebook posztok $2,00 / 1000 poszt ·
Google Trends $0,30 / 1000.

## Ami tudatosan kimaradt

**Google Trends**: a `trends` forrásokat nem vettük fel gyárilag, mert azokat a
ti tényleges forrásországaitokhoz kell igazítani — azt a Források fülön tudod
felvenni (csatorna: Keresleti index, ország kitöltve).

**Weboldal-figyelés** (tandíj, határidő): saját Actor-választást kíván, és a
`web` forrásokhoz mezőtérkép kell. Ez a következő kör.
