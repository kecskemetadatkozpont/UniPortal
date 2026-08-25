# 32. migráció — Egy jelentkező, több program (II/4)

**Előfeltétel:** a `RUN_ALL_27_31.sql` már lefutott.

## Futtatás

Illeszd be egyben a Supabase SQL Editorba:

```
supabase/RUN_ALL_32.sql
```

Idempotens, többször is beilleszthető. Az „Exposed schemas" alatt **nincs
teendő** — minden a `public` sémába dolgozik.

---

## Mit old meg

A kollégák észrevétele (8. tétel):

> A személyhez tartozó lépések — dokumentum-ellenőrzés, matek, interjú —
> egyszer történjenek, a programhoz tartozók programonként.

A lépések szétválása:

| lépés | szint | hol él |
|---|---|---|
| `programs` | **program** | `student_program` sor szakonként |
| `documents`, `check`, `interview`, `math` | **személy** | `students.status` — egyetlen példány |
| `letter` | **program** | `student_program.letter_state` szakonként |

Mérve a teljes sémán: egy jelentkező két szakkal →
**2 jelentkezés, 1 személy-státusz, 1 interjú.**

---

## Amit szándékosan NEM bántunk

**A `students.program` mező megmarad.** A felület húsz helyen olvassa.
Trigger tartja szinkronban az első helyen jelölt szak nevével, tehát minden
meglévő képernyő végig helyes értéket lát. Mérve: az 1. hely visszalépése
után a mező automatikusan a 2. helyre vált.

**A személy-szintű állapotgép sem változik.** A 25-ös migráció
`students_enrollment_guard` őre továbbra is csak `Accepted` fő státusz mellett
engedi a beiratkozási dátumot — a 32-es igazodik hozzá, nem kerüli meg.

---

## Nyitott intézményi kérdés: kettős felvétel

**Erre még nem kaptunk választ a kollégáktól**, ezért nem égettük be. A szabály
a `student_program_setting` táblában áll, és kód nélkül átállítható:

```sql
update public.student_program_setting
   set value = 'first_preference_wins'      -- vagy 'both_allowed'
 where key = 'dual_admission_policy';
```

| érték | mit csinál | mérve |
|---|---|---|
| `applicant_chooses` *(alapértelmezés)* | a jelentkező választ egyet, a többi `Withdrawn` lesz | 1. hely → Withdrawn, 2. hely → ★beiratkozott |
| `first_preference_wins` | csak az 1. helyen jelölt szakra lehet beiratkozni | a 2. helyre elutasítja, magyar üzenettel |
| `both_allowed` | párhuzamosan több szakra is beiratkozhat | mindkettő megmarad |

Az alapértelmezés a legelterjedtebb egyetemi gyakorlat, és **visszafordítható**:
a `Withdrawn` sorok megmaradnak, nem törlődnek.

A szakok darabszáma is beállítás:

```sql
update public.student_program_setting
   set value = '5'  -- 0 = korlátlan
 where key = 'max_programs_per_applicant';
```

Jelenlegi alapértelmezés: **3**.

---

## A meglévő adat átemelése

A migráció minden jelentkező mostani szakját 1. helyen jelölt jelentkezéssé
alakítja, és kiírja, mi történt:

```
NOTICE: Átemelve: 8 jelentkezés a katalógushoz kötve, 3 csak szöveges címkével.
```

A `students.program` ma **szabad szöveg** („BSc Business Admin"), ami nem
feltétlenül illeszkedik a `programs` katalógushoz. Ahol nincs találat, a sor a
szöveggel jön létre — **egyetlen jelentkezés sem vész el**. Ezek a felületen
„Nincs katalógushoz kötve" jelzéssel látszanak, és utólag összeköthetők:

```sql
select public.student_program_link('<jelentkezés id>', '<program id>');
```

**Érdemes átnézni a NOTICE sorokat futtatás után**, és a szöveges címkéket
hozzákötni a katalógushoz — enélkül a szakonkénti statisztikák hiányosak.

---

## Hol látszik a felületen

A jelentkező adatlapján, közvetlenül a „Felvételi állapot" fölött:
**Megjelölt szakok**. Szakonként a jelölési sorszám, a döntés, a levél
állapota és a beiratkozás. Szerkeszteni `SUPERADMIN`, `ADMIN` és `ADMISSIONS`
szerepkör tud; a jelentkező a sajátját látja.

---

## Ha vissza kell vonni

```sql
select public.multi_program_rollback();
```

Csak szuperadmin futtathatja. A `students.program` mező érintetlen marad.
