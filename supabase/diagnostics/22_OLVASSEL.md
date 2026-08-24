# ECHO 1. fázis — futtatási kísérő (22 · 23 · 24)

Neumann János Egyetem · OMHV · 28/2023. (VIII.31.) szenátusi határozat

Ez a fájl az 1. fázis három új migrációjához tartozik, és három kérdésre válaszol:
**mit futtass, milyen sorrendben** · **mit fogsz látni a felületen** · **mit mértünk**.

Az ellenőrzés dátuma: 2026-08-24. Minden alábbi szám a helyi `fresh` replikán MÉRT
eredmény, nem becslés. Amit nem mértünk, arról ez a fájl nem állít semmit.

---

## 1. Mit futtass — a SORREND KÖTELEZŐ

A 21-es fájl feladata, hogy az `echo_submit()` végrehajtási jogát **anon**-ra
szűkítse. A 23-as fájl ÚJRAÍRJA az `echo_submit()`-et, tehát a platform
alapértelmezett jogosztása visszaadhatná az `authenticated` jogot — ezért a
**21-es MINDIG az utolsó**.

```
... 20_echo_report_fix.sql        (már fut)
    22_echo_draft.sql             <- ÚJ: piszkozat-mentés (1.1)
    23_echo_form_rules.sql        <- ÚJ: kitöltési szabályok szerveroldalon (1.2, 1.3)
    24_echo_form_v3.sql           <- ÚJ: a célmeghatározó 2 bevezető kérdése (1.2)
    21_echo_harden_submit.sql     <- ÚJRA, MINDIG AZ UTOLSÓ
```

```bash
export PGHOST=/tmp/upg2 PGPORT=55432 PGUSER=postgres
cd .../uniportal-demo/supabase
for f in 22_echo_draft.sql 23_echo_form_rules.sql 24_echo_form_v3.sql 21_echo_harden_submit.sql; do
  psql -d fresh -v ON_ERROR_STOP=1 -f "$f" || break
done
```

**A 20_echo_report_fix.sql NEM futhat a 24 után.** A 24 felülírja az
`echo.results_build()`-ot (a 20-as változata + a part1-kizárás). A 20
újrafuttatása csendben visszavenné a kizárást, és a célmeghatározás két
bevezető kérdése `n=0`-val megjelenne az oktatói eredménynézetben. Ha a 20-at
bármiért újra kell futtatni, futtasd utána a 24-et is — idempotens.

Mind a négy fájl **idempotens**: kétszer egymás után lefuttatva `exit=0`,
hibaüzenet nélkül (mérve). A 22 és a 23 a végén önellenőrző táblázatot ír ki;
mind a 9, illetve 4 sor `OK`-t kell adjon.

---

## 2. A NYITOTT KÉRDÉS, amit a migráció SZÁNDÉKOSAN nem old meg

> **A célmeghatározó két bevezető kérdése ma NEM jut el a hallgatóhoz.**

Mérve: a `fresh` replikán a kérdőívnek három verziója van.

| verzió | állapot | part1 szakasz | part1 kérdés |
|--------|---------|---------------|--------------|
| 1 | closed | 0 | 0 |
| 2 | **live** | 0 | 0 |
| 3 | **draft** | 1 | **2** |

A nyitott kampány (`OMHV-2025-26-2`) a **2. verzióra** van kötve, abban pedig
nulla part1 kérdés van. Következmény, mérve a nyitott kampányon:

```
echo_save_goals(<kampány>,<kurzus>,'["cél"]','["elvárás"]',
                '{"goals_discussed":"reszletesen","req_clear":"teljesen"}')
  -> {"ok": true, "goals": 1, "expectations": 1, "intro": {}}
                                                 ^^^^^^^^^^^ ÜRES
```

Ez **nem hiba, hanem a védelem működése**: az `echo_save_goals()` az `intro`
kulcsait a kampány kérdőív-verziójának part1 kérdés-ID-jeihez méri, és amit nem
talál, azt eldobja. Így nem lehet tetszőleges kulcsot betölteni a hallgatóhoz
kötött sorba.

**Bizonyítva, hogy a vezeték ép.** Egy külön replikán a 3. verziót élesítettük és
a kampányt átkötöttük rá — ezután ugyanaz a hívás:

```
-> {"ok": true, "goals": 1, "expectations": 1,
    "intro": {"req_clear": "teljesen", "goals_discussed": "reszletesen"}}
```

és a szabályok is élnek:
* hiányzó kötelező bevezető válasz → `ECHO_INTRO_REQUIRED`
* a felkínált opciók közt nem szereplő érték → `ECHO_BAD_INTRO`

### Miért nem élesíti a migráció automatikusan

Mert **visszafordíthatatlan és rontana**:

1. Egy kampány egy kérdőív-verzió. A válaszsorok a saját verziójuk kérdés-ID-jeit
   őrzik; a futó kampány átkötése után a riport a régi válaszokat rossz
   kulcsokkal keresné.
2. Az élesítés a 2. verziót `closed`-ra zárja (egy sablonnak egy élő verziója
   lehet). Ez végleges.
3. A két bevezető kérdés szövege **rekonstrukció** a prototípusból — MIR-jóváhagyás
   kell rá, mielőtt hallgató elé kerül.

### A kézi lépések, ha élesíteni akarod

```sql
-- 1) Nézd át a szerkesztőben: ECHO -> Kérdőívek -> OMHV alapkérdőív -> a 3. verzió.
-- 2) Élesítés admin munkamenetben, EGYESÉVEL (a draft->approved ugrást trigger tiltja):
select public.echo_template_validate('<v3_id>');
select public.echo_template_transition('<v3_id>', 'review');
select public.echo_template_transition('<v3_id>', 'approved');
select public.echo_template_transition('<v3_id>', 'live');
-- 3) ÚJ kampány kell az új verzióval. A futó kampányt NE kösd át.
```

Amíg ez nem történik meg, az 1.2-ből a **„legalább egy cél kötelező" rész ÉL**
(az nem verziófüggő), a **két bevezető kérdés viszont nem látszik**.

---

## 3. Mit fogsz látni a felületen

**Piszkozat (1.1).** A kitöltő minden mezőelhagyáskor (`onBlur`, nem
billentyűleütésenként) ment. A fejlécben „Mentve …" jelzés; ha a mentés
elszáll, „nem sikerült menteni" — a kitöltés **nem áll meg**, a válaszok a
memóriában élnek tovább. A kurzuslistán a félbehagyott kurzus **„Félbehagyott"**
címkét kap, „a 3. lépésnél abbahagyva" felirattal. Visszatéréskor nem az üres
űrlap jön, hanem egy felajánló képernyő: **Folytatás** / **Újrakezdés üres
űrlappal**. A régi „a válaszaid nem mentődnek" mondat eltűnt a kódból (mérve: 0
találat).

A felajánló képernyőn ott áll a **kompromisszum kimondva**: a mentett piszkozat
a beküldésig visszakereshető a hallgatóhoz, és a beküldés pillanatában szakad el
ez a kapcsolat. Ez a mondat maradjon ott — a piszkozat tényleg nem anonim.

**Célmeghatározó (1.2).** Üres célmentés már nem megy át: a felület tiltja, és a
szerver is (`ECHO_GOALS_REQUIRED`). A két bevezető kérdés csak akkor jelenik meg,
ha a kampány egy part1 kérdéseket tartalmazó verzióra van kötve (lásd 2. pont).

**„Egyéb" (1.3).** Ha bejelölöd az „Egyéb"-et és nem írsz mellé szöveget, a
Tovább gomb blokkol, és a beküldés előtti végső ellenőrzés is megfogja. Csak
`multi` típusú kérdésre vonatkozik — a felület és a szerver ugyanígy.

**Kérdőív nyelve (1.4).** A kérdőív a **kurzus** képzési nyelvén jelenik meg
(`echo.course.lang`), nem a fejléc nyelvválasztója szerint. Ha a kurzus nyelvén
nincs jóváhagyott fordítás, magyarra esünk vissza, és ezt a felület **kiírja**
(borostyán sávban), hogy az angol nyelvű képzés hallgatója ne higgye, elrontott
valamit. A staff-felületek (kampányok, oktatói nézet, moderálás, szerkesztő)
továbbra is a fejléc nyelvét követik — ez helyes, azok nem kérdőívszövegek.

**Behelyettesítés (1.5).** Az „[Oktató neve] erősségei" a valódi kitöltésben is
feloldódik. Mérve, az élő kérdőív valódi kérdésén, a szállított
`ECHO_resolveTokens`-szel:

```
NYERS    : Mik voltak leginkább [Oktató neve] erősségei?
FELOLDVA : Mik voltak leginkább Kovacs Andrea erősségei?
NYERS    : What were the main strengths of [Teacher name]?
FELOLDVA : What were the main strengths of Kovacs Andrea?
```

Az opciócímkék és a súgó is feloldódik; az opciók **`value` mezője
szándékosan NEM** — a beküldött érték a compiled szerinti nyers `value`, különben
a riport nem találna rá.

---

## 4. Mit mértünk

### Végigjátszás a `fresh` replikán

| # | Amit néztünk | Eredmény |
|---|---|---|
| a | piszkozat mentés → visszaolvasás | `{"ok":true}` → a payload hiánytalanul visszajön, `step`-pel együtt |
| a | beküldés → a piszkozat eltűnt? | a beküldés önmagában **nem** törli (1 sor marad); az azonosított `echo_draft_drop()` törli: `{"ok":true,"torolve":1}` → 0 sor |
| b | MÁS hallgató piszkozata | `echo_draft_get` → `{"van": false}`; közvetlen tábla-olvasás → `permission denied for schema echo` |
| c | MIR/admin látja a TARTALMAT? | `echo_draft_get` superadminként → `{"van": false}`. Csak `echo_draft_stats` van, az pedig **darabszám**: `{"kuszob":3,"osszesen":1,"kurzusonkent":[]}`. Hallgatóként hívva: `ECHO_FORBIDDEN` |
| d | „legalább egy cél" szerveroldalon | üres lista → `ECHO_GOALS_REQUIRED`; csak elvárás, cél nélkül → `ECHO_GOALS_REQUIRED`; `["", "   "]` → `ECHO_GOALS_REQUIRED` |
| d | a két bevezető kérdés mentődik? | a nyitott kampányon `intro: {}` (a v2-ben nincs part1) — v3-ra kötött kampányon **mentődik**, lásd 2. pont |
| e | csupasz „Egyéb" a NYERS API-n | `ECHO_OTHER_TEXT_REQUIRED: … (course_strengths_p)`; szöveggel együtt: `{"ok":true,"rows":1}` |
| f | a kurzus nyelve dönt? | `echo_get_form(...)->'course'->>'lang'` = `en` egy EN kurzuson; mindhárom verzióban 0 hiányzó angol szakaszcím és 0 hiányzó angol kérdés → nincs visszaesés |
| g | token-behelyettesítés valódi kitöltésben | feloldva, 0 maradék `[Oktató neve]` / `[Teacher name]` (lásd fent) |

### Anonimitás-regresszió — egyik sem romlott el

| Amit néztünk | Mért eredmény |
|---|---|
| `echo_submit` jogosultsága | `postgres=X/postgres anon=X/postgres` — **csak anon**. `echo_issue_ticket`: csak authenticated |
| időbélyeg a válaszsoron | `echo.response` oszlopai: `id, campaign_id, course_id, teacher_id, template_version_id, scope, attendance_band, answers` — **0 db timestamp típusú oszlop** |
| a kulcs uuid v4 | 2/2 soron a verzió-nibble `4`, a variáns `8/9/a/b` |
| az `echo` séma zárva | `has_schema_privilege` anon / authenticated / service_role → mind **false** |
| napló ↔ válasz xmin-korreláció | 2 válaszsor, 42 naplósor, **0 xmin-egyezés** |
| a jegykiadás a kohorszot érinti | kurzusonként 10 naplósor, **1 különböző xmin** — a kiadás az egész kohorszot egy tranzakcióban írja |
| k-küszöbök CHECK-kel védve | `k_text`-et 2-re állítva: `violates check constraint "echo_setting_k_floor_chk"` |
| a piszkozat nyit-e új utat a válaszhalmazhoz | **nem.** `echo.draft`: RLS be **és** kényszerítve, **0 policy**, a tábla ACL-je csak `postgres`. Nincs `response`-ra mutató oszlopa. Se séma-, se tábla-, se RPC-úton nem érhető el más tartalma |

### A piszkozat-RPC-k védelmei (mind mérve, mind hibát dob)

| Próba | Eredmény |
|---|---|
| idegen kurzusra mentés | `ECHO_NOT_ELIGIBLE` |
| zárt kampányba mentés | `ECHO_CAMPAIGN_CLOSED` |
| 70 000 bájtos payload | `ECHO_PAYLOAD_TOO_LARGE` (a korlát 64 KB, ugyanaz, mint a beküldésen) |
| lejárt piszkozat visszaolvasása | `{"van": false}` — a lejárat **olvasáskor** érvényesül, nem a takarítótól függ |
| kampányzárás | `echo_draft_purge_on_close` trigger: 1 piszkozat → **0** |

### Part1-szivárgás — a levágás működik

A nyers API-n át beküldött payloadba szándékosan beírtuk a part1 kérdések
válaszait, az `intro`-t, a `goal_count`-ot és a `student_key`-t. A tárolt
válaszsoron ez maradt:

```json
{ "goals_met": "teljesult", "attendance": "76-100%", "overall_course_p": 5 }
```

Minden azonosításra alkalmas kulcs levágva. A part1 ID-k listája a kérdőívből
jön (`echo.part1_question_ids`), nem beégetve — új part1 kérdés esetén a levágás
magától követi.

### Ütközés és build

A két munkacsomag ugyanahhoz a `features/echo.jsx`-hez nyúlt. Mérve:

* `npm run build` → **sikeres**; `node --check` a bundle-on OK. (A bundle mérete
  az ellenőrzés alatt 1907.6 kB-ról 1938.7 kB-ra nőtt, mert egy MÁSIK, ECHO-n
  kívüli munkacsomag közben módosította az `assistant.jsx` / `feed.jsx` /
  `programs.jsx` / `index.html` fájlokat és felvett egy `25_status_model.sql`-t.
  A `features/echo.jsx` ez alatt **változatlan** maradt, 5061 sor.)
* **0 merge-marker**
* **0 duplikált** `ECHO_*` top-level definíció (minden név pontosan egyszer)
* mind a **7 nézet** megvan (`ECHO_StudentView`, `ECHO_AdminView`,
  `ECHO_TeacherView`, `ECHO_Editor`, `ECHO_ModerationView`, `ECHO_CampaignsPanel`,
  `ECHO_RolesPanel`), és az `app.jsx` routolja őket
* egy `ECHO_api`, egy `ECHO_anonClient`
* 31 publikus `echo_*` RPC (a korábbi 27 + a 4 piszkozat-RPC)
* mind SECURITY DEFINER, mind **rögzített `search_path`**-tal
* a bundle a nem-ASCII karaktereket `\xE9` alakban escape-eli (esbuild
  alapértelmezés) — ez normális, a szövegek megvannak

---

## 5. Két apróság, amit érdemes tudni

**A `submitted` jelző csak a kampányzáráskor kerül fel.** Az `echo_submit()` anon
jogon fut, és szándékosan nem tudja, ki küldött be — a `participation.submitted`-et
a kötegelt `echo.mark_submitted()` teszi fel a `closed → processing` átmenetnél.
Következmény: a nyitott ablak alatt az `echo_draft_save()` `ECHO_ALREADY_SUBMITTED`
ága gyakorlatilag nem sül el. Ha a beküldés utáni `echo_draft_drop()` hívás
elszáll (a felület csendben nyeli), a hallgató továbbra is „Félbehagyott"-nak
látja a kurzust, és a második jegyével (`max_tickets_per_course = 2`) újra be
tudna küldeni. Ez a lehetőség **nem új** — a két jegy szándékos, épp a
félbehagyott kitöltés miatt —, de a piszkozat láthatóbbá teszi. Ha zavaró, a
`max_tickets_per_course` 1-re állítása szünteti meg, cserébe egy hálózati hiba
végleg kizárja a hallgatót.

**A `gc_draft()` takarítót semmi nem hívja automatikusan.** A `draft_ttl_days = 14`
ígéretét *funkcionálisan* az olvasás tartja be (`echo_draft_get` és
`echo_my_courses` egyaránt szűr `expires_at >= now()`-ra, mérve), tehát lejárt
piszkozat nem folytatható és nem is látszik. A **sor** viszont a táblában marad,
amíg a kampány le nem zárul. Mivel ez a rendszer legérzékenyebb táblája, érdemes
a `gc_draft()`-ot ütemezni (cron), hogy a tárolt tartalom se éljen túl a 14 napot.
