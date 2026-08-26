# 35–36. migráció — 7 napos oktatói észrevétel és központi kérdésbank (III/2)

**Előfeltétel:** a `RUN_ALL_34.sql` már lefutott.

## Futtatás

```
supabase/RUN_ALL_35_36.sql
```

**Ez a csomag a végén magát ellenőrzi.** A SQL Editor csak az utolsó eredményt
mutatja, ezért a modul saját ellenőrző lekérdezése zárja a beillesztést: egy
tábla, benne a modul **és** az anonimitás állapota. Külön futtatásra nincs
szükség. Minden sor `OK` kell legyen.

Az `echo` séma **rejtett marad** — a Data API beállításához nem kell nyúlni.

---

## 35 · A 7 napos észrevétel (6. § (7))

### A határidő az ÁTVÉTELTŐL indul

Ez a modul lényege. A 7 nap **nem** a kampány zárásától számít, hanem attól,
hogy az oktató ténylegesen megkapta a jegyzőkönyvet. Enélkül a határidő nem
számolható, és vitában nem védhető meg.

Amíg nincs rögzített átvétel:

* `echo.comment_deadline()` **NULL**-t ad — az óra el sem indult,
* az észrevétel beadását a szerver `ECHO_NO_HANDOVER`-rel utasítja el,
* a felület nem hazudik határidőt, hanem kiírja: *„a 7 napos határidő még el
  sem indult".*

Az átvétel rögzítése (admin):

```sql
select public.echo_protocol_handover('<kampány>', '<oktató>', 'szemelyes');
```

Módok: `rendszer`, `email`, `szemelyes`, `posta`.

> **Nyitott intézményi kérdés.** Azt, hogy jogilag mi számít „átvételnek", még
> nem kaptuk meg. A migráció ezért a **mechanizmust** építi meg, a jelentést
> nyitva hagyja. Amikor a definíció megvan, elég a megengedett módok listáját
> szűkíteni — az adat és a számítás marad.

### A késett észrevételt befogadjuk, nem dobjuk el

A határidőn túli beadást a rendszer **elfogadja**, csak megjelöli
(`late = true`). Egy elutasított észrevétel nyomtalanul eltűnne; egy megjelölt
ott marad, és a címzett dönt róla. A felület ezt őszintén ki is írja.

### Ki a címzett?

Az oktató szervezeti egységéből indulunk, és **felfelé lépkedünk**
(tanszék → intézet → kar → egyetem). A lépcső:

```
TANSZEKVEZETO → DEKAN → MIR
```

Mérve, ugyanazon az oktatón, fokozatosan kinevezve:

| kinevezve | címzett |
|---|---|
| senki | nincs címzett |
| egyetem-szintű MIR | `MIR` |
| + DÉKÁN a karon | `DEKAN` |
| + TANSZÉKVEZETŐ a tanszéken | `TANSZEKVEZETO` |

A lépcső átírható:

```sql
update echo.setting set value = 'TANSZEKVEZETO,MIR'
 where key = 'comment_recipient_chain';
```

Ugyanígy az ablak hossza (`comment_window_days`, alapértelmezés `7`).

### Ki látja az észrevételt

| néző | mit lát |
|---|---|
| admin | mindent |
| az oktató | a sajátjait |
| a címzett | a neki szólókat |
| bárki más | **semmit** — üres listát, nem hibaüzenetet |

Mérve: egy másik oktató **0**-t lát, egy kívülálló dékán **0**-t, a címzett
tanszékvezető viszont látja a neki szólókat — pedig **nem admin**. A
jogosultság tehát valóban a címzettségen múlik, nem admin-jogon.

---

## 36 · Központi kérdésbank

Ma minden sablonváltozat a saját kérdéseit tartalmazza. A bank ezt oldja:
a kérdéstételek egy helyen élnek, a sablonok hivatkoznak rájuk.

### Amit szándékosan NEM csinál

**A kiadott sablonokat nem írja át.** Egy lezárt kampány kérdései nem
változhatnak utólag attól, hogy valaki a bankban javít egy szót. A bank a
**szerkesztést** segíti; a kiadott sablon önhordó marad.

**Aktív tétel kódja zárolt.** Ha egy kérdés `active`, a kódja nem írható át —
sablonok hivatkozhatnak rá. Vissza kell vonni (`retired`), és újat létrehozni.

**Törlés helyett visszavonás.** Amire kampányok hivatkoznak, azt nem szabad
kitörölni: a hivatkozás elszakadna.

### Mért megszorítások

| eset | eredmény |
|---|---|
| skála `min`/`max` nélkül | blokkolva (`question_bank_scale_ck`) |
| választós opciólista nélkül | blokkolva (`question_bank_options_ck`) |
| kód szóközzel | blokkolva (`question_bank_code_shape_ck`) |
| aktív tétel kódjának átírása | `ECHO_CODE_LOCKED` |

### Sablonba illesztés

```sql
select public.echo_question_bank_as_item('<tétel id>');
```

Pontosan a sablon kérdés-alakját adja vissza, `bank_id`-vel kiegészítve — ez
köti össze a sablont a bankkal a későbbi trendszámításhoz.

---

## A felületen

Az ECHO eredménynézetben, a kurzusszintű riport és az export alatt:
**Észrevétel a jegyzőkönyvre**. Három állapotot tud, és mindhárom mérve van
böngészőben:

* **nyitva** — átvétel dátuma, határidő, hátralévő idő (`2 nap 2 óra`)
* **lejárt** — pirosan „Lejárt", és a figyelmeztetés, hogy a beküldés még
  befogadásra kerül, csak késettként jelölve
* **nincs átvétel** — *„a 7 napos határidő még el sem indult"*, beviteli mező
  nélkül

A panel magát rejti el, ha a fiók nem oktatói sorhoz kötött.

**A kérdésbanknak még nincs felülete** — az RPC-k készen állnak, a szerkesztő
képernyő a következő kör.

---

## Ha vissza kell vonni

```sql
select public.echo_comment_rollback();        -- 35
select public.echo_question_bank_rollback();  -- 36
```

Csak szuperadmin. A 35 visszavonása a **beadott észrevételeket és az átvételi
eseményeket meghagyja** — mindkettő jogilag számít, nem a modul tartozéka.
