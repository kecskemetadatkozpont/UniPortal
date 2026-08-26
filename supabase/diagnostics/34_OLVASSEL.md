# 34. migráció — ECHO export k-küszöb-őrrel és export-naplóval (III/2)

**Előfeltétel:** a `RUN_ALL_33.sql` már lefutott.

## Futtatás

```
supabase/RUN_ALL_34.sql
```

Idempotens. **Az `echo` séma REJTETT marad** — a Data API „Exposed schemas"
beállításán nem kell változtatni. Az export a `public.echo_export_results()`
burkolón át érhető el, ahogy minden más ECHO-funkció.

---

## Miért ez a legkockázatosabb pont

Eddig exportálni **egyáltalán nem lehetett**. A kampányciklus lezárásához
viszont kell — és ez az a pont, ahol a k-anonimitás a legkönnyebben elfolyik.
Elég egyetlen „kényelmi" lekérdezés az `echo.response` táblára, és minden
védelem, amit a `results_build()` gondosan felépít, megkerülhető.

## A megoldás szerkezeti, nem ellenőrzés-alapú

Az `echo.export_rows()` bemenete a **már elnyomott** riport-JSON, amit a
`results_build()` ad vissza. A függvény `immutable`, és **nem olvas semmilyen
táblát** — nincs honnan kiszivárogtatnia. Amit a képernyőn elrejtettünk, azt
az export nem tudja megmutatni, mert hozzá sem fér.

Ez fontosabb, mint amilyennek hangzik: nem arról van szó, hogy *ellenőrizzük*,
nem szivárog-e. Arról, hogy **nincs mit ellenőrizni** — a szivárgás útja nem
létezik.

> **Aki később gyorsítani akarna az exporton egy közvetlen lekérdezéssel,
> az a védelmet szedi szét.** Az export soha ne kapjon saját adatutat.

### Mérés

Mind a nyolc rejtés-kombináció egy kérdésen (átlag × eloszlás × szöveg):

```
átlag=true eloszlás=true szöveg=true   ⟹  átlag ok / eloszlás ok / szöveg ok
… mind a 8 eset: egyetlen elrejtett mező sem került ki
```

A teszt nem vak — rejtetlen esetben az érték átjön (`átlag = 4.2`,
eloszlás, szöveg), tehát képes lenne bukni.

A legerősebb eset: egy `rejtve: true` riport, amiben **benne maradt** egy
`atlag: 4.9` → az export **nulla sort** ad ki. Még hibás bemenet sem szivárog.

---

## Export-napló

Az `access_log` a **megtekintést** rögzíti. Az export erősebb esemény: az adat
elhagyja a rendszert, és onnantól nem tudjuk követni. Ezért külön naplót kap:

```sql
select * from public.echo_export_log();            -- minden kampány
select * from public.echo_export_log('<kampány>'); -- egy kampány
```

Csak admin olvashatja. A `hidden_count` oszlop megmutatja, **hány cellát
nyomott el a k-küszöb** az adott állományban — utólag ebből derül ki, hogy egy
kivitt fájl mennyire volt szűrt.

A visszavonás a naplót **szándékosan meghagyja**: a megtörtént exportok ténye
auditnyom, nem a modul tartozéka.

---

## A felületen

Az ECHO eredménynézetben, a kurzusszintű riport alatt: **Kurzusszintű eredmény
kivitele** — CSV és JSON gomb.

A CSV Excel-barát: BOM-mal kezdődik (enélkül az Excel elrontja a magyar
ékezeteket), a pontosvesszőt tartalmazó szövegek idézőjelezve vannak, és a
beágyazott idézőjelek körbe-vissza helyesen olvashatók.

**A gomb mindig megmondja, mennyi maradt ki:**

```
14 sor kiírva — 3 cellát a k-küszöb elrejtett, ezek nincsenek benne.
```

Enélkül egy hiányos állomány teljesnek látszana, és a fogadó fél nem tudná,
hogy szűrt adatot kapott.

Ha az egész bontás küszöb alatt van, az export nem fájlt ad, hanem
magyarázatot — ez nem hiba, hanem a k-küszöb működése.

---

## Jogosultság

Ugyanaz, mint a képernyőn: **aki nem láthatja, nem is exportálhatja.**
A `echo_export_results()` jogosultság-ellenőrzése szó szerint azonos az
`echo_course_results()`-éval. Oktató csak a saját kurzusát, és a `teacher`
hatókörben csak saját magát viheti ki. `anon` sehol nem kap jogot.

Ha az egyik ellenőrzés változik, **a másikat is vele kell változtatni** —
különben az export és a képernyő szétcsúszik.

---

## Ha vissza kell vonni

```sql
select public.echo_export_rollback();
```

Csak szuperadmin. Az `echo.export_log` megmarad.
