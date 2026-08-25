# 27–31. migráció — futtatási útmutató

**Mit hoz:** interjú-kapu, interjú-foglalás (elérhetőség / ebédszünet / szabadság),
ügynökségi portál, és az interjú-ütközés adatbázis-szintű lezárása.

---

## Egyetlen lépés

Nyisd meg a **Supabase → SQL Editor**-t, és illeszd be **egyben** ezt a fájlt:

```
supabase/RUN_ALL_27_31.sql
```

Ez hat migrációt tartalmaz, a helyes sorrendben. Egyetlen lekérdezésként lefut,
és **többször is beilleszthető** — idempotens, nem csinál kárt, ha véletlenül
kétszer futtatod.

Nem kell külön futtatni a 27-, 28-, 29-, 30-, 31-es fájlokat: mind benne van.

---

## Miért van a 21-es a csomag VÉGÉN

A `21_echo_harden_submit.sql` **újra lefut a csomag végén**. Ez szándékos.

A Supabase alapértelmezett jogosztása minden új migráció után visszaadhatja az
`echo_submit` futtatási jogát az `authenticated` szerepnek. Ha ez megtörténik,
a kérdőív-kitöltés **már nem anonim**, mert a válasz a bejelentkezett
felhasználó nevében megy be.

Ezért érvényes az állandó szabály: **minden új migráció után a 21-es fut
utoljára.**

### Ellenőrzés futtatás után

```sql
select grantee, privilege_type
  from information_schema.routine_privileges
 where routine_name = 'echo_submit';
```

**Helyes eredmény:** csak `anon` (és a tulajdonos `postgres`).
Ha az `authenticated` megjelenik a listában, futtasd újra a
`21_echo_harden_submit.sql`-t önmagában.

---

## Nincs teendőd az „Exposed schemas" alatt

A 27–30 mind a `public` sémába dolgozik, tehát a Data API beállításán
**nem kell változtatni**. A korábban beállított állapot marad érvényes:

| séma | állapot | miért |
|------|---------|-------|
| `public` | látható | a rendszer törzse |
| `dorm` | **látható** | a kollégiumi felület közvetlenül olvassa |
| `echo` | **rejtett** | az anonimitás múlik rajta — ne tedd láthatóvá |

---

## Mit zár le a 30-as migráció

A 27/28-as kapu **működik**, de a nyers API-ról (PostgREST) két ponton
megkerülhető volt. Mindkettőt mértük.

**(1) Betűméret-érzékeny őrszem.** A kapu első sora `status <> 'Booked'`
szerint szűrt, az `interviewSlots.status` viszont szabad szöveg. Aki
kisbetűvel írta, annak a kapu meg sem szólalt:

```
-- SX jelentkező státusza: "Draft" (NEM foglalhatna)
insert into "interviewSlots"(..., status, "studentId") values (..., 'booked', 'SX');
→ bent maradt: TESTC/booked          ⚠ átment
```

A 30-as után mind a négy betűváltozat blokkolva:

```
✓ 'Booked' → blokkolva      ✓ 'BOOKED' → blokkolva
✓ 'booked' → blokkolva      ✓ 'bOoKeD' → blokkolva
```

**(2) A tulajdonos-kényszer csak módosításra futott.** A beszúrásnál semmi
nem kötötte a `studentId`-t a hívó saját jelentkezői sorához, így egy
bejelentkezett jelentkező **más nevében** is tudott időpontot foglalni.
A 30-as ezt beszúrásra is kikényszeríti.

---

## Mit véd a 31-es migráció

A 28-as foglalási kapuja először **olvas** (szabad-e a sáv), majd feltétel
nélkül **beszúr**. A Postgres alapértelmezett READ COMMITTED izolációja alatt
két egyszerre induló foglalás nem látja egymás még nem véglegesített sorát —
így **mindkettő szabadnak látja a sávot, és mindkettő beszúr.**

Ez nem elméleti aggály. A teljes sémán, két párhuzamos tranzakcióval mérve:

```
ellenorzes(A): SZABAD
ellenorzes(B): SZABAD
→ 2 foglalás ugyanazon a 10:00-as sávon: DIAK-A + DIAK-B
```

Ugyanez a mérés a 31-es után, háromszor egymás után:

```
#1 → 1 foglalás | A kért időpont ütközik egy már kiadott interjú-időponttal.
#2 → 1 foglalás | A kért időpont ütközik egy már kiadott interjú-időponttal.
#3 → 1 foglalás | A kért időpont ütközik egy már kiadott interjú-időponttal.
```

A jelentkező tehát a **rendes magyar üzenetet** kapja, nem nyers adatbázis-hibát.

Három réteg dolgozik együtt:

1. **Sorosítás** (`a_interviewslots_serialize_trg`) — a beszúrás előtt zárat vesz
   az (interjúztató, időpont) párra, így a második foglalás megvárja az elsőt,
   és mire sorra kerül, a kapu **már látja** a véglegesített sort.
2. **Kizárási megszorítás** (`interviewslots_no_overlap`) — végső védőháló:
   egy interjúztatónak nem lehet két átfedő, le nem mondott sávja.
3. **Egyedi index** (`interviewslots_one_live_per_student`) — egy jelentkezőnek
   egyszerre **egy** élő foglalása lehet. A lezajlott (`Completed`) interjú
   után újra foglalhat, a jövőbeli sávok halmozása viszont tilos.

### Meglévő ütközések

A 31-es **magától feloldja** a már bent lévő ütközéseket: a korábban rögzített
foglalás marad, a későbbi `Cancelled` státuszt kap. Minden ilyen esetet
kiír a futtatás naplójába, például:

```
NOTICE: Ütköző foglalás lemondva: IVxxx (jelentkező: S3, időpont: 2026-09-15 10:00) — megmarad: IVyyy
```

**Érdemes átnézni ezeket a sorokat futtatás után**, és értesíteni az érintett
jelentkezőket az új időpontról.

---

## Ha vissza kell vonni

```sql
select public.interview_integrity_rollback();      -- a 31-es ütközésvédelmét
select public.interview_gate_hardening_rollback(); -- a 30-as kapu-szigorítást
select public.interview_gate_rollback();        -- a 27-es kaput
select public.agency_module_rollback();         -- a 29-es ügynökségi modult
```

Mindhármat csak szuperadmin futtathatja.
