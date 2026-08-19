# 11_rbac_additive.sql — mit futtass, és mi történik

## Amit futtatni kell

**Supabase → SQL Editor → új query → a teljes `supabase/11_rbac_additive.sql` beillesztése → Run.**

Egyetlen, másolható blokk. Idempotens: ha kétszer futtatod, nem hibázik.

## Mit csinál

| | |
|---|---|
| Létrehoz | 13 jogosultság-vizsgáló függvényt (`my_email`, `has_role`, `is_admin`, …) |
| Létrehoz | **86 szerepkör-alapú policy-t 22 táblán**, `rbac_` előtaggal |
| Létrehoz | 5 integritás-triggert (oszlopvédelem, amit az RLS nem tud) |
| **Nem** dobja el | a jelenlegi `approved_all` policy-t — az mind a 22 táblán megmarad |
| **Nem** módosít | adatot, oszlopot, a `profiles` táblát |
| **Nem** érinti | a másik alkalmazás tábláit (`prefs`, `publications`, `publication_files`) |

## Miért biztonságos most lefuttatni — mérve, nem feltételezve

A Postgres a megengedő policy-ket **vagy**-olja: egy sor akkor látszik, ha legalább egy policy
átengedi. Az `approved_all` ma minden jóváhagyott fióknak mindent enged, és mind a 14 fiók
jóváhagyott. Az új, szűkebb szabályok hozzáadása ezért **nem szűkít semmit**.

Ez nem elmélet. Egy helyi Postgres replikán, amibe betöltöttük a `01`–`10` migrációt és
ráállítottuk az éles adat alakját (14 profil ugyanazzal a szerepkör-eloszlással, 11 hallgató,
üres `agencies`, 15 felvételi folyamat), lemértük a **8 szerepkör × 25 tábla = 200 cellás**
láthatósági mátrixot a migráció előtt és után:

```
200 cella, a migráció előtt és után:  BETŰRE AZONOS
két egymás utáni futás:               0 hiba mindkétszer
végállapot:  86 rbac_ policy · 22 tábla · approved_all 22 · anon-policy 0
```

## Mi történne a következő lépés (`12` flip) után

Ezt is lemértük: eldobtuk az `approved_all`-t a replikán, és újramértük a mátrixot.

| tábla | SUPER | ADMIN | ADMISS | FIN | AGENT | Hallgató (kötött) | Hallgató (kötetlen) |
|---|---|---|---|---|---|---|---|
| `students` | 11 | 11 | 11 | 11 | **0** | **1** | **0** |
| `payments` | 5 | 5 | 5 | 5 | **0** | **1** | **0** |
| `admission_processes` | 15 | 15 | 15 | 15 | **0** | **5** | **0** |
| `leads` | 4 | 4 | 4 | **0** | **0** | **0** | **0** |
| `users`, `campaigns`, `auditLogs` | teljes | teljes | teljes | teljes | **0** | **0** | **0** |
| `profiles` | 14 | 14 | 14 | 14 | 14 | 14 | 14 |

Az ügyintézői szerepkörök gyakorlatilag változatlanul dolgoznak. A szűkítés a hallgatói és
ügynöki oldalt érinti — és **itt van a két nyitott kérdés, amit a flip előtt el kell dönteni.**

## A két nyitott kérdés

**1. A hallgatói fiókok nincsenek bekötve.** Kilenc `STUDENT` profil van, de csak **egy**
köthető `students` sorhoz (e-mail vagy `studentId` alapján). A flip után a másik nyolc üres
Hallgatói Portált kapna. Megoldás: a `profiles."studentId"` feltöltése, vagy a `students.email`
egyeztetése a profilok e-mail címével.

**2. Az ügynöki lánc törött.** Az `agencies` tábla üres, a `students."agentId"` értékei
(`A1`/`A2`/`A3`) nem mutatnak sehova, és a frontend `app.jsx:930` a nem létező `s.agencyId`
mezőre szűr. Emiatt az Ügynök portál **ma is** üres. A flip ezen nem ront, de nem is javít.

## Amit a tesztelés zárt be

Az ellenőrzés négy valódi lyukat talált és javított. Mind reprodukálva és újramérve:

| Lyuk | Előtte | Utána |
|---|---|---|
| A hallgató átírta a `students.name`-jét, és onnantól más fizetéseit látta | sikerült | a név visszaáll |
| A hallgató `status='Accepted'`-re állította magát | **sikerült** | blokkolva |
| Bárki lefoglalt interjú-idősávot idegen névre | sikerült | blokkolva |
| Bárki hamis naplóbejegyzést gyártott más nevében | sikerült | `42501` hiba |

A pénzügyi folyamat közben végig működik: a `FINANCE` szerepkör továbbra is át tudja állítani
egy hallgató státuszát `Paid`-re (ezt is lemértük).

## Ami NEM változik ettől a migrációtól

Jogosultság-emelés (`profiles.role` átírása) ma sem megy — a `07`-es migráció triggere fogja.
A `documents` bucket és a WhatsApp-táblák védelme változatlan. Az Edge Functionök `service_role`
kulccsal futnak, ami megkerüli az RLS-t, tehát a WhatsApp-integrációt egyik lépés sem érinti.

## A következő lépés

1. Futtasd le ezt a fájlt. **Semmi nem változik** — utána kényelmesen tesztelhetsz.
2. Döntsd el a fenti két kérdést (hallgatói bekötés, ügynöki lánc).
3. Csak utána jön a `12_rbac_flip.sql`, ami eldobja az `approved_all`-t. Ekkor lépnek életbe
   az új szabályok. Készül hozzá `13_rbac_rollback.sql` is, ami egy lépésben visszaállít.

## Reprodukálhatóság

A mérés részletes jegyzőkönyve: [`11_meresi_jelentes.md`](11_meresi_jelentes.md).
A felderítő lekérdezés: [`00_felderites.sql`](00_felderites.sql).
