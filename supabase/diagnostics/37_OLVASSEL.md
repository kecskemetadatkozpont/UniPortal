# 37. migráció — a két jelentkezési folyamat összevonása

**Előfeltétel:** a `RUN_ALL_35_36.sql` már lefutott.

## Futtatás

```
supabase/RUN_ALL_37.sql
```

A csomag a végén **magát ellenőrzi** — az utolsó eredmény a hasznos tábla,
külön lekérdezés nem kell. Az „Exposed schemas" beállításhoz nem kell nyúlni.

---

## Mit old meg

Két bejelentés érkezett a kollégáktól, és **ugyanaz a problémájuk**:

> Nem jelenik meg a „Teszt Elek" profilja által indított képzésre való
> jelentkezés dokumentumai az admin oldalon, ezért nem tud tovább menni a
> jelentkezési folyamat.

> Miért kell a dupla lista *(nem hiba)*?

A második nem volt hiba a bejelentő szerint, pedig épp az okozta az elsőt.
Két külön jelentkezési folyamat élt egymás mellett:

```
hallgatói jelentkezés  →  program_applications   (features/programs.jsx)
ügyintézői ellenőrzés  →  admission_processes    (app.jsx, STEP_DEFS)
```

A hallgató a képzés oldaláról jelentkezett, az ügyintéző a felvételi
folyamatokat nézte. Nincs átjárás, ezért a jelentkezés meg sem jelent ott, ahol
dolgozni kellett volna vele.

**A jogosultság nem volt szűk keresztmetszet.** Ellenőriztük: az
`admission_processes` sorszintű szabálya engedi az ügyintézőnek mások sorait
is. A sor egyszerűen létre sem jött.

---

## Egy sor, két szakasz

Nem összekötöttük a két modellt, hanem **egyesítettük**. Az
`admission_processes` az egyetlen tábla, és a sor két szakaszon megy át:

| szakasz | ki dolgozik vele | számláló |
|---|---|---|
| `student` | a jelentkező tölti | `student_step` |
| `office` | az iroda ellenőrzi | `step` |

A két lépéssor nem ütközött, hanem kiegészíti egymást:

```
hallgató:  personal → documents → language → motivation → fee → review
iroda:                            check → interview → math → letter
```

A beadás átfordítja a sort a **`check`** lépésre — pontosan oda, ahol a 27/30-as
migráció interjúkapuja nyílik. A dupla lista magától megszűnik: az ügyintézői
lista már eddig is minden `admission_processes` sort mutatott.

### Mérve

Végigjátszva az adatbázisban, a felület útját követve:

```
1. jelentkezés létrehozása      →  szakasz = student
2. lépegetés + dokumentum       →  hallgatói lépés = 1, utlevel.pdf
3. beadás                       →  szakasz = office, lépés = 2
4. az ÜGYINTÉZŐ ezt látja:
   UJ-1 · Teszt Diák · szakasz=office · lépés=2
        · dok: utlevel.pdf · útvonal: diak/UJ-1/passport-abc.pdf
```

Az útvonal a lényeg: ezzel az admin **meg tudja nyitni** a fájlt aláírt
hivatkozással.

---

## A feltöltés mostantól valódi

Külön hiba volt, hogy a jelentkezési űrlap **nem töltötte fel a fájlt** — csak
a nevét és a dátumot jegyezte fel, maga a fájl eldobódott:

```js
// RÉGI — features/programs.jsx
setData({ docs: { ...docs, [id]: { fileName: file.name, at: todayStr() } } });
```

Mostantól ugyanazt a `DOC_upload` utat használja, mint az irodai oldal —
ugyanaz a tároló, ugyanaz az útvonalséma. A felület jelzi a feltöltés
folyamatát, és hiba esetén megmondja, mi történt.

---

## A beadás RPC-n megy, nem mezőírással

A hallgatói → irodai szakaszváltás **egyirányú**, és innen indul az ügyintézés.
Ezért nem sima `UPDATE`, hanem `application_submit()`:

* a jelentkező csak a **sajátját** adhatja be (mérve: más sorára
  `Csak a saját jelentkezését adhatja be`),
* kétszeri beadás nem írja felül a beadás idejét, hanem visszajelzi, hogy már
  megtörtént,
* jóváhagyásra váró fiók nem adhat be.

---

## Visszafordítható

**A `program_applications` tábla érintetlen marad.** Az átemelés másolat, nem
áthelyezés — az átemelt sorok azonosítója `APP-` előtaggal kezdődik.

```sql
select public.merge_flows_rollback();
```

Csak szuperadmin futtathatja. Törli az átemelt sorokat, az irodai úton indított
folyamatokhoz nem nyúl, és a régi felület azonnal újra használható lenne.

---

## Amit érdemes megnézni futtatás után

Az ellenőrző tábla „Felvételi folyamatok" sora megmutatja a hallgatói és irodai
szakaszban lévő folyamatok számát. Ha van `student` szakaszú sor, azok
félbehagyott jelentkezések — az iroda látja őket, de még nem kell velük
dolgozni.
