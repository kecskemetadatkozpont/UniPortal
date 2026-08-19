# 11_rbac_additive.sql — mérési jelentés élő replikán

**Mérés dátuma:** 2026-08-18
**Replika:** PostgreSQL 16.14, `PGHOST=/tmp/upg2 PGPORT=55432`, `uniportal` adatbázis,
Supabase-utánzattal (auth séma, `auth.uid()`, anon/authenticated szerepkörök).
**Migrációs fájl:** `11_rbac_additive.sql` (1019 sor, változatlanul futtatva).
**Módszer:** minden mérés `begin; set local role authenticated; set local request.jwt.claims = …; … rollback;`
blokkban, tehát valódi RLS-kiértékeléssel. A `postgres` superuser megkerülné az RLS-t, ezért egyetlen
számot sem mértünk superuserként.

**Mért fiókok**

| jelölés | szerepkör | e-mail | profiles."studentId" | profiles."agencyId" |
|---|---|---|---|---|
| SUPER | SUPERADMIN | kecskemet.adatkozpont@gmail.com | – | – |
| ADMIN | ADMIN | admin@nje.hu | – | – |
| ADMISS | ADMISSIONS | felveteli@nje.hu | – | – |
| FIN | FINANCE | penzugy@nje.hu | – | – |
| AGENT | AGENT | agent@globalstudy.com | – | AG1 |
| STU-L | STUDENT (linkelt) | chen@test.com | S2 | – |
| STU-U | STUDENT (nem linkelt) | hallgato2@mail.com | – | – |
| ANON | bejelentkezés nélkül | – | – | – |

---

## 0. Rövid ítélet

| kérdés | mért válasz |
|---|---|
| Lefut a 11-es hibátlanul? | **Igen.** 0 hiba, 86 `rbac_` policy, 22 táblán. Javítani nem kellett. |
| Idempotens? | **Igen.** Másodszor is 0 hiba, ugyanaz a 86 policy. |
| Tényleg additív (semmi nem változik)? | **NEM.** Az `anon` (bejelentkezés nélküli látogató) a 11-es után **17 `programs` + 9 `kb_documents` sort lát**, ma 0-t. |
| A 12-es flip után marad-e írási lyuk? | **Igen, három.** Lásd a 4. fejezetet. |

---

## 1. A három mátrix egymás mellett

Olvasás: `előtte` → **`11 után`** → **`flip után`**. Ahol egy szám áll, ott mindhárom állapot azonos.
A számok a `select count(*)` eredményei az adott szerepkör bőrében.

| tábla | SUPER | ADMIN | ADMISS | FIN | AGENT | STU-L | STU-U | ANON |
|---|---|---|---|---|---|---|---|---|
| `users` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `students` | 11 | 11 | 11 | 11 | 11 → **0** | 11 → **1** | 11 → **0** | 0 |
| `payments` | 7 | 7 | 7 → **0** | 7 | 7 → **0** | 7 → **1** | 7 → **0** | 0 |
| `invoices` | 3 | 3 | 3 → **0** | 3 | 3 → **0** | 3 → **1** | 3 → **0** | 0 |
| `campaigns` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `auditLogs` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `webhooks` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `interviewSlots` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `agencies` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `leads` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `marketingCampaigns` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `scholarships` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `integrations` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `videoInterviewQuestions` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `admission_processes` | 15 | 15 | 15 | 15 | 15 → **0** | 15 → **5** | 15 → **1** | 0 |
| `process_messages` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `feed_posts` | 6 | 6 | 6 | 6 | 6 | 6 | 6 | 0 |
| `event_rsvps` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `ticket_claims` | 1 | 1 | 1 | 1 | 1 → **0** | 1 | 1 → **0** | 0 |
| `programs` | 17 | 17 | 17 | 17 | 17 | 17 | 17 | 0 → **17** → **17** |
| `program_applications` | 5 | 5 | 5 | 5 | 5 → **0** | 5 → **2** | 5 → **1** | 0 |
| `kb_documents` | 9 | 9 | 9 | 9 | 9 | 9 | 9 | 0 → **9** → **9** |
| `profiles` | 14 | 14 | 14 | 14 | 14 | 14 | 14 | 0 |
| `wa_contacts` | 2 | 2 | 2 | 2 | 0 | 0 | 0 | 0 |
| `wa_messages` | 2 | 2 | 2 | 2 | 0 | 0 | 0 | 0 |
| `storage.objects` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
A 0-t mutató táblák (`users`, `campaigns`, `webhooks`, `leads`, `integrations`, `scholarships`,
`marketingCampaigns`, `videoInterviewQuestions`, `interviewSlots`, `agencies`, `event_rsvps`,
`process_messages`, `auditLogs`, `storage.objects`) **üresek** — ott a mátrix nem bizonyít semmit,
ezért ezeket külön, felvitt próbasorokkal mértük (4. fejezet).

---

## 2. A migráció futtatása

### 2.1 Első futás

```
psql -d uniportal -f 11_rbac_additive.sql   → exit 0, 0 db ERROR
```

A fájl saját 10.4-es összegző lekérdezése:

| rbac_policy_osszesen | erintett_tablak | meg_nyitott_tablak | jovahagyott_fiok | nem_jovahagyott_fiok |
|---|---|---|---|---|
| 86 | 22 | 22 | 14 | 0 |

86 = 21 tábla × 4 policy (SELECT/INSERT/UPDATE/DELETE) + `auditLogs` × 2 (szándékosan append-only).
**Semmit nem kellett javítani a fájlon** — se szintaktikai, se szemantikai hibára nem futott.

### 2.2 Idempotencia (második futás)

```
psql -d uniportal -f 11_rbac_additive.sql   → exit 0, 0 db ERROR, ismét 86 policy / 22 tábla
```

Működik: a 2. szakasz `$rbac_clean$` blokkja minden `rbac\_%` policy-t eldob, mielőtt újra létrehozná.

### 2.3 Az idegen alkalmazás táblái

A 22 tábla nevesített listával van megadva (nincs `for all tables in schema`), és a
`prefs` / `publications` / `publication_files` **egyik listában sem szerepel** — a migráció nem
érintheti őket. (A replikán ezek a táblák nincsenek is jelen, tehát ez név szerinti,
nem futás közbeni bizonyíték.) A `profiles`, `wa_contacts`, `wa_messages` policy-készlete a futás
után is változatlan: 3 / 1 / 1 policy, `rbac_` előtagú egy sem.

---

## 3. Eltérések a mátrixban — magyarázat

### 3.1 A 11-es után: BLOKKOLÓ eltérés az `anon` szerepkörnél

| tábla | anon előtte | anon a 11 után |
|---|---|---|
| `programs` | 0 | **17** |
| `kb_documents` | 0 | **9** |

**Ok.** A 9.1 szakasz `$rbac_catalog$` blokkja így hoz létre policy-t:

```sql
create policy "rbac_programs_select" on public.programs
  for select to anon, authenticated using (true);
```

Ma az egyetlen policy a `approved_all`, ami `to authenticated` — ezért az `anon`-t
eddig **az RLS zárta ki**, nem a tábla-jogosultság. Mérés: az `anon` szerepkörnek
`SELECT/INSERT/UPDATE/DELETE` **GRANT-ja is van** a `public.programs` és `public.kb_documents`
táblán (`information_schema.role_table_grants`), tehát amint egy `to anon … using (true)` policy
megjelenik, az adat azonnal nyilvános lesz.

Ez **ellentmond a fájl fejlécének** („a tényleges viselkedés BETŰRE UGYANAZ marad",
„nulla kockázattal telepíthető"). Nem katasztrofális — a két tábla tartalma tényleg publikus
jellegű —, de ez egy tudatos, dokumentálandó döntés, nem mellékhatás.

Írásra az `anon` **nem** kap semmit (mért eredmények):

| próba | anon |
|---|---|
| `insert into programs` | `HIBA 42501` (RLS) |
| `update programs` | 0 sor |
| `delete programs` | 0 sor |
| `insert into kb_documents` | `HIBA 42501` (RLS) |

**Javaslat (SQL).** Ha a katalógusnak nem kell nyilvánosnak lennie, a 9.1 blokk `select` ágát
cseréld erre:

```sql
    execute format(
      'create policy "rbac_%s_select" on public.%I for select to authenticated
         using (public.is_approved())', t, t);
```

Mérve a replikán: ezzel az `anon` visszaáll 0 `programs` sorra, a bejelentkezettek 17-en maradnak.
Ha viszont a nyilvános katalógus a **szándék**, akkor ezt a fejlécből vedd ki mint
„semmi nem változik" állítást, és tedd a 12-es flip alá — hogy a nyilvánossá tétel
egy külön, visszavonható lépés legyen.

### 3.2 A flip után: `ADMISSIONS` elveszti a teljes pénzügyet

| tábla | ADMISSIONS előtte | flip után |
|---|---|---|
| `payments` | 7 | **0** |
| `invoices` | 3 | **0** |

Szándékos: a 4. szakasz `rbac_payments_select` csak `has_role('SUPERADMIN','ADMIN','FINANCE')`-t
enged. Az `ADMISSIONS` viszont **teljes hozzáférést kap** a `students` (11 sor, írás is),
`admission_processes` (15 sor), `program_applications` (5 sor) táblához, mert azok `is_staff()`-fel
dolgoznak, és az `is_staff()` az ADMISSIONS-t is tartalmazza.
**Döntendő a flip előtt:** ha a felvételi ügyintézőnek a felületen látnia kell, befizetett-e a
jelentkező, ez a nulla működésképtelenséget okoz.

Tükörképe: a `FINANCE` viszont **teljes olvasó-író jogot kap a jelentkezői adatra**
(`students` 11 sor írással, `admission_processes` 15 sor írással, `program_applications`
beszúrás/módosítás) — mert az `is_staff()` a FINANCE-t is beleveszi. Ha ez nem szándék,
a `students` / `admission_processes` / `process_messages` / `program_applications`
`is_staff()` hívásait `has_role('SUPERADMIN','ADMIN','ADMISSIONS')`-ra kell cserélni.

### 3.3 A flip után: az `AGENT` mindenhol nullát lát

| tábla | AGENT előtte | flip után |
|---|---|---|
| `students` | 11 | **0** |
| `admission_processes` | 15 | **0** |
| `program_applications` | 5 | **0** |
| `ticket_claims` | 1 | **0** |
| `agencies` | 0 | 0 (a tábla üres) |

A fejléc (A) pontja **igazolódott, mérve**: `students."agentId"` ∈ {A1, A2, A3},
`profiles."agencyId"` = 'AG1', az egyenlőség soha nem áll fenn.

**Mennyit érne a javítás?** Külön tranzakcióban lemértük, mi történik, ha az adatot rendbe tesszük
(`agencies` feltöltve AG1/AG2/AG3, majd `update students set "agentId" = replace("agentId",'A','AG')`):

| AGENT látott sorok | javítás nélkül | adatjavítással |
|---|---|---|
| `students` | **0** | **5** |
| `agencies` | 1 (csak ha a tábla nem üres) | **1** (a sajátja) |
| `payments` | 0 | **0** |
| `admission_processes` | 0 | **0** |

Vagyis az adatjavítás a `students` láncot helyreteszi (5 hallgató az A1/AG1 ügynökhöz), de az
ügynök **így sem lát fizetést és felvételi folyamatot** — ezekre a táblákra egyáltalán nincs
AGENT-ág a policy-kben. Ha az Ügynök portálnak státuszt kell mutatnia, azt is meg kell tervezni.

### 3.4 A flip után: a hallgatói lánc — 9-ből 8 fiók semmit nem lát

Mind a 9 STUDENT fiókot lemértük a flip szimulációjában:

| e-mail | students | payments | invoices | admission_processes | program_applications | `my_student_name()` |
|---|---|---|---|---|---|---|
| chen@test.com | **1** | **1** | **1** | **5** | **2** | Chen Wei |
| hallgato2@mail.com | 0 | 0 | 0 | 1 | 1 | NULL |
| hallgato3@mail.com | 0 | 0 | 0 | 1 | 0 | NULL |
| hallgato4@mail.com | 0 | 0 | 0 | 1 | 0 | NULL |
| hallgato5@mail.com | 0 | 0 | 0 | 1 | 0 | NULL |
| hallgato6@mail.com | 0 | 0 | 0 | 0 | 0 | NULL |
| hallgato7@mail.com | 0 | 0 | 0 | 0 | 0 | NULL |
| hallgato8@mail.com | 0 | 0 | 0 | 0 | 0 | NULL |
| hallgato9@mail.com | 0 | 0 | 0 | 0 | 0 | NULL |

A fejléc (1) pontja **igazolódott**: 9-ből 8 fiók a `students`/`payments`/`invoices` táblán
nullát lát; négy fiók egyetlen `admission_processes` sort ér el, négy pedig semmit.

Ehhez kapcsolódó, eddig nem említett tény: a 15 `admission_processes` sorból **6 gazdátlan**
(`owner_email` = `nincs1..6@sehol.hu`, ilyen profil nincs). Ezek a flip után **csak ügyintézőnek**
látszanak — ez helyes, de tudni kell róla, hogy a 15-ből 9 az, amiért egyáltalán érdemes
tulajdonost keresni.

### 3.5 Ami NEM változott (és ez helyes)

`profiles` (14 sor mindenkinek), `wa_contacts` / `wa_messages` (2/2 az ügyintézőnek, 0 az
ügynöknek és a hallgatónak), `storage.objects` (0 — a bucket üres). A 11-es és a 12-es
egyaránt érintetlenül hagyja őket.

**Figyelemre méltó viszont:** a `profiles` a flip után is **mind a 14 sort megmutatja
minden jóváhagyott fióknak, e-mail-címmel együtt** — a hallgatónak és az ügynöknek is
(07-es `profiles_select`: `id = auth.uid() OR is_approved()`). Ez a legnagyobb megmaradó
adatvédelmi felület a flip után, és a 11-es szándékosan nem nyúl hozzá.

---

## 4. Írási próbák a flip szimulációján belül

40 + 17 próba, szerepkörönként, mindegyik saját `savepoint` … `rollback to savepoint` közé zárva,
tehát egyik próba sem szennyezi a következőt. Az üres táblákra (`interviewSlots`, `auditLogs`,
`process_messages`, `agencies`) a próba előtt vittünk fel sorokat, hogy a „0 sor módosult"
eredmény valódi tiltást jelentsen, ne üres táblát.

Jelölés: **IGEN** = sikerült (potenciális lyuk) · `nem/0` = a policy 0 sorra szűkített ·
`42501` = RLS `with check` megtagadás.

### 4.1 Teljes írási mátrix

| próba | SUPER | ADMIN | ADMISS | FIN | AGENT | STU-L | STU-U |
|---|---|---|---|---|---|---|---|
| A01_upd_masik_hallgato_sora | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | nem/0 | nem/0 |
| A02_upd_sajat_hallgato_sor | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | **IGEN 1 sor** | nem/0 |
| A03_upd_sajat_students_email_masra | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | **IGEN 1 sor** | nem/0 |
| A04_ins_uj_students_sor | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 |
| A05_del_students_sor | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 |
| B01_upd_masik_admission_process | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | nem/0 | nem/0 |
| B02_upd_masik_ap_chen | **IGEN 5 sor** | **IGEN 5 sor** | **IGEN 5 sor** | **IGEN 5 sor** | nem/0 | **IGEN 5 sor** | nem/0 |
| B03_ins_ap_masik_nevere | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 |
| B04_del_masik_ap | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 |
| C01_sajat_role_SUPERADMIN | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** |
| C02_sajat_approval_approved | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** |
| C03_sajat_agencyId_AG1 | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** |
| C04_sajat_studentId_S1 | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** |
| C05_masik_profil_role_STUDENT | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 |
| C06_masik_profil_email_atiras | **IGEN 1 sor** | nem/0 | nem/0 | **IGEN 1 sor** | nem/0 | nem/0 | nem/0 |
| D01_ins_webhooks | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 |
| D02_ins_leads | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 |
| D03_ins_integrations_hiba | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 |
| D04_upd_agencies | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 |
| D05_ins_agencies | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 |
| E01_ins_payments_masik_nevere | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 |
| E02_ins_payments_sajat_nevre | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | **IGEN 1 sor** | hiba 42501 | **IGEN 1 sor** | hiba 42501 |
| E03_upd_payments_status | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | **IGEN 1 sor** | nem/0 | nem/0 | nem/0 |
| E04_ins_invoices | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 |
| E05_del_payments | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | **IGEN 1 sor** | nem/0 | nem/0 | nem/0 |
| F01_ins_feed_posts | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 |
| F02_upd_programs | **IGEN 17 sor** | **IGEN 17 sor** | **IGEN 17 sor** | nem/0 | nem/0 | nem/0 | nem/0 |
| F03_ins_programs | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 |
| F04_ins_kb_documents | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 |
| G01_upd_auditlogs | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 |
| G02_del_auditlogs | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 | nem/0 |
| G03_ins_auditlogs | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** |
| H01_ins_ticket_claim_masik_emailre | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 | **IGEN 1 sor** | hiba 42501 |
| H02_ins_event_rsvp_masik_emailre | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 | hiba 42501 | **IGEN 1 sor** | hiba 42501 |
| H03_ins_program_app_masik_emailre | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | **IGEN 1 sor** | hiba 42501 |
| H04_upd_masik_program_app | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | **IGEN 1 sor** | nem/0 |
| I01_foglal_szabad_slotot_masik_nevere | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** |
| I02_lop_foglalt_slotot | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | nem/0 | nem/0 |
| J01_ins_process_messages_masik_owner | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | hiba 42501 | hiba 42501 | hiba 42501 |
| J02_del_process_messages | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | **IGEN 1 sor** | nem/0 | nem/0 | nem/0 |

*(`D04_upd_agencies` és `G01/G02_auditlogs` sorai külön, felvitt próbasorral is le lettek mérve —
lásd 4.4 és 4.5.)*

### 4.2 LYUK #1 (BLOKKOLÓ) — a hallgató átnevezi magát, és más pénzügyét látja

Ez a legsúlyosabb mért találat. A `rbac_students_update` tulajdonlást az `id`-vel is elfogadja:

```sql
using / with check ( is_staff() or id = my_student_id() or lower(email) = my_email() )
```

Mivel a sor `id`-je nem változik, a hallgató a **saját sorának bármelyik oszlopát** átírhatja —
így a `name` mezőt is. A `payments`/`invoices` tulajdonlás viszont **névegyezésen** alapul
(`lower("studentName") = lower(my_student_name())`), és a `my_student_name()` éppen ebből a
`students.name` mezőből olvas. A kör bezárul.

**Mért lefolyás** (chen@test.com = STUDENT, saját sora S2 / „Chen Wei"):

| lépés | eredmény |
|---|---|
| kiindulás | látott payments: `P2: Chen Wei` · invoices: `INV-1003` |
| `update students set name='Elena Rodriguez' where id='S2'` | **SIKERÜLT (1 sor)** |
| újramérés | látott payments: **`P7: Elena Rodriguez`** · invoices: **`INV-1001: Elena Rodriguez`** |
| `insert into payments(id,"studentName",amount,status) values ('HAMIS','Elena Rodriguez',1,'Paid')` | **SIKERÜLT (1 sor)** |
| `update students set email='hallgato9@mail.com' where id='S2'` | **SIKERÜLT (1 sor)** |

Tehát egyetlen `UPDATE`-tel, sima STUDENT jogosultsággal, a felület megkerülése nélkül
(a Supabase REST `PATCH /students?id=eq.S2` hívása elég) **bárki más pénzügyi sorait meg lehet
nyitni, és a nevére hamis „Paid" fizetést beszúrni**. A fájl fejlécének (B) pontja csak a
„két azonos nevű jelentkező véletlen egyezését" említi kockázatként — a valóság az, hogy a nevet
a támadó **szabadon megválasztja**.

Ugyanez a lyuk engedi a `students.email` és a `students.id` átírását is
(`O01_upd_sajat_students_id_atiras` → SIKERÜLT), ami adatintegritási kárt okoz.

**Javaslat (SQL) — mérve, hogy megfogja.** RLS-ben nincs oszlopszintű korlát, ezért trigger kell:

```sql
create or replace function public.students_protect_identity()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- SQL Editor / service role / ügyintéző: érintetlenül megy tovább
  if public.is_staff() or auth.uid() is null then
    return new;
  end if;
  -- jelentkező: az azonosságát és a pénzügyi paramétereit NEM írhatja
  new.id           := old.id;
  new.name         := old.name;
  new.email        := old.email;
  new."agentId"    := old."agentId";
  new."tuitionFee" := old."tuitionFee";
  new.evaluation   := old.evaluation;
  return new;   -- a status / visaChecklist / address stb. marad írható
end $$;

drop trigger if exists students_protect_identity_trg on public.students;
create trigger students_protect_identity_trg
  before update on public.students
  for each row execute function public.students_protect_identity();
```

Mérve a replikán, a triggerrel:

| próba | eredmény a triggerrel |
|---|---|
| `update students set name='Elena Rodriguez' where id='S2'` | „SIKERÜLT (1 sor)", de a **tényleges név `Chen Wei` marad** |
| újramért látott payments | **`P2: Chen Wei`** — a lyuk bezárult |
| `update students set status='Paid' where id='S2'` | **SIKERÜLT** — az app.jsx fizetési folyamata tovább működik |

**Igazi megoldás középtávon** (a fejléc (B) pontja is ezt írja): `studentId` oszlop a
`payments` / `invoices` táblára, és a policy átállítása rá:

```sql
alter table public.payments  add column if not exists "studentId" text;
alter table public.invoices  add column if not exists "studentId" text;
update public.payments p set "studentId" = s.id from public.students s where s.name = p."studentName";
update public.invoices i set "studentId" = s.id from public.students s where s.name = i."studentName";
-- majd a rbac_payments_select / _insert / rbac_invoices_select feltételében
--   lower("studentName") = lower(public.my_student_name())
-- helyett:
--   "studentId" = public.my_student_id()
```

### 4.3 LYUK #2 (BLOKKOLÓ) — bárki lefoglal egy interjú-idősávot más nevére

A fájl a 3.8 szakaszban ezt „maradék kockázatként" említi; a replikán **kimértük, hogy valóban
kihasználható, és nem csak hallgatóval**:

| szerepkör | `update "interviewSlots" set status='Booked', "studentId"='S1', "studentName"='Al-Farabi Ammar' where id='IS-FREE'` |
|---|---|
| SUPER / ADMIN / ADMISS / FIN | **SIKERÜLT** (ügyintéző — rendben) |
| **AGENT** | **SIKERÜLT** — pedig az ügynöknek semmi köze az interjúfoglaláshoz |
| **STU-L / STU-U** | **SIKERÜLT** — más nevére, más `studentId`-jével |

Már foglalt sávot viszont nem lehet elvenni (`I02_lop_foglalt_slotot` → 0 sor a nem-ügyintézőknek),
tehát a `using (… status = 'Available')` fele működik.

**Javaslat (SQL) — mérve, hogy megfogja:**

```sql
create or replace function public.interviewslots_force_owner()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_staff() or auth.uid() is null then
    return new;
  end if;
  new."studentId"   := public.my_student_id();
  new."studentName" := public.my_student_name();
  return new;
end $$;

drop trigger if exists interviewslots_force_owner_trg on public."interviewSlots";
create trigger interviewslots_force_owner_trg
  before update on public."interviewSlots"
  for each row execute function public.interviewslots_force_owner();
```

Mérve: a fenti támadó `UPDATE` után a sor tényleges tartalma `Chen Wei / S2` lett, nem
`Al-Farabi Ammar / S1`. Érdemes az `is_agent()`-et is kizárni a `rbac_interviewslots_update`
`using` ágából, ha az ügynöknek nem szabad foglalnia.

### 4.4 LYUK #3 (KÖZEPES) — az `auditLogs` beszúrás hamisítható

| próba | SUPER | ADMIN | ADMISS | FIN | AGENT | STU-L | STU-U |
|---|---|---|---|---|---|---|---|
| `update "auditLogs"` (felvitt sorra) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `delete "auditLogs"` (felvitt sorra) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `insert "auditLogs"(id,"user",action)` tetszőleges `"user"` értékkel | **IGEN** | **IGEN** | **IGEN** | **IGEN** | **IGEN** | **IGEN** | **IGEN** |

A append-only szándék **működik** — még a SUPERADMIN sem tud naplót módosítani vagy törölni,
ez a fájl deklarált célja, és mérve teljesül. Viszont a `rbac_auditlogs_insert` `is_approved()`-ot
kér, a `"user"` mezőbe pedig **bármit** be lehet írni: egy hallgató tetszőleges számú, tetszőleges
nevű naplóbejegyzést gyárthat („Admin Anna törölte X-et"). Egy csak-hozzáfűzhető napló, amibe
bárki bármit hamisíthat, kevesebbet ér, mint amennyi bizalmat kelt.

**Javaslat (SQL):** trigger, ami a `"user"` mezőt a hívó profiljából tölti:

```sql
create or replace function public.auditlogs_force_actor()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;   -- service role / Edge Function marad szabad
  new."user" := coalesce(public.my_email(), 'unknown');
  return new;
end $$;
drop trigger if exists auditlogs_force_actor_trg on public."auditLogs";
create trigger auditlogs_force_actor_trg
  before insert on public."auditLogs"
  for each row execute function public.auditlogs_force_actor();
```

Figyelem: ez elrontja az `app.jsx:301` `'System (WhatsApp)'` értékét. Ha az kell, tegyél kivételt
`is_staff()`-re, vagy vegyél fel egy külön `actor_email` oszlopot a hamisíthatatlan értéknek.

### 4.5 MŰKÖDÉSI HIÁNY — az ügyintéző nem tud senkit regisztrálni eseményre

| próba | SUPER | ADMIN | ADMISS | FIN | AGENT | STU-L | STU-U |
|---|---|---|---|---|---|---|---|
| `insert ticket_claims(… email='hallgato9@mail.com')` | 42501 | 42501 | 42501 | 42501 | 42501 | 42501 | 42501 |
| `insert event_rsvps(… email='hallgato9@mail.com')` | 42501 | 42501 | 42501 | 42501 | 42501 | 42501 | 42501 |

A 8.2 szakasz `with check`-je **nem tartalmaz `is_staff()` ágat**:

```sql
with check (public.is_approved() and lower(email) = public.my_email())
```

Tehát a jegyigénylés/RSVP kizárólag saját címre megy — **még a SUPERADMIN sem tud kézzel
javítani vagy más nevében regisztrálni**. Ez biztonságilag rendben van, működésileg valószínűleg nem.

**Javaslat (SQL):**

```sql
drop policy if exists "rbac_ticket_claims_insert" on public.ticket_claims;
create policy "rbac_ticket_claims_insert" on public.ticket_claims
  for insert to authenticated
  with check (public.is_staff() or (public.is_approved() and lower(email) = public.my_email()));

drop policy if exists "rbac_event_rsvps_insert" on public.event_rsvps;
create policy "rbac_event_rsvps_insert" on public.event_rsvps
  for insert to authenticated
  with check (public.is_staff() or (public.is_approved() and lower(email) = public.my_email()));
```

Mérve a javítással: az ADMISSIONS fiók sikeresen beszúrt `hallgato9@mail.com` nevére,
a hallgató továbbra is csak a saját címére tud.

### 4.6 AMI NEM SIKERÜLT — a jogosultság-emelés bezárt, de csendben

Ezt külön, két lépésben mértük, mert egyetlen `SELECT`-en belül a visszaolvasás régi
pillanatképet lát: előbb `wprobe()` végrehajtotta az `UPDATE`-et, majd **külön utasításban**
olvastuk vissza a tényleges értéket.

| próba | visszaadott eredmény | **tényleges érték utána** |
|---|---|---|
| STUDENT: `update profiles set role='SUPERADMIN' where id=auth.uid()` | „SIKERÜLT (1 sor)" | `STUDENT` — **nem változott** |
| STUDENT: `update profiles set "studentId"='S1' where id=auth.uid()` | „SIKERÜLT (1 sor)" | `S2` — **nem változott** |
| STUDENT: `update profiles set "agencyId"='A1' where id=auth.uid()` | „SIKERÜLT (1 sor)" | `NULL` — **nem változott** |
| AGENT / FINANCE / ADMISSIONS / ADMIN: ugyanez | „SIKERÜLT (1 sor)" | mind változatlan |
| SUPERADMIN: `"studentId"='S1'` | „SIKERÜLT (1 sor)" | `S1` — **tényleg megváltozott** (helyes) |
| ADMIN: `update profiles set approval_status='approved', role='ADMIN' where email='hallgato9@mail.com'` | „BLOKKOLVA (0 sor)" | `STUDENT` |
| SUPERADMIN: ugyanez | „SIKERÜLT (1 sor)" | `ADMIN` |

**Következtetés: a jogosultság-emelés nem lehetséges.** A 07-es
`profiles_protect_privileges_trg` BEFORE UPDATE trigger visszaírja a `role`, `approval_status`,
`requested_role`, `approved_at`, `approved_by`, `rejected_reason`, `agencyId`, `studentId` mezőket
az eredeti értékre mindenkinél, aki nem SUPERADMIN. Ez a 11-es migrációtól függetlenül,
már ma is így van.

Két megjegyzés mégis:

1. **Csendes hamis siker.** Az `UPDATE` `1 sor`-t jelent vissza, hibaüzenet nincs. A frontend
   (és a Supabase REST `PATCH … Prefer: return=representation`) ezt sikerként kezeli, holott
   semmi nem történt. Ha valahol van „szerepkör-igénylés" képernyő, az ártalmatlanul, de
   megtévesztően „mentve" állapotot fog mutatni.
2. **Az ADMIN nem tud felhasználót kezelni.** A `profiles_update` `using` ága
   `id = auth.uid() OR is_superadmin()` — az ADMIN szerepkörnek **nulla** joga van más profiljához.
   Ha van jóváhagyó képernyő az admin felületen, az a flip után (és ma is) csak a
   SUPERADMIN-nak működik. Ez a `profiles` táblát érinti, amit a 11-es szándékosan nem bánt —
   de a szerepkör-modell szempontjából ez most hiányzó ADMIN-jogosultság.

### 4.7 Ami helyesen bukott el (kivonat)

| próba | ki bukott el rajta |
|---|---|
| `insert into webhooks` | ADMISSIONS, FINANCE, AGENT, mindkét STUDENT — `42501` |
| `insert into leads` | FINANCE, AGENT, mindkét STUDENT — `42501` |
| `insert into integrations` / `agencies` | ADMISSIONS, FINANCE, AGENT, STUDENT-ek — `42501` |
| `insert into students` | AGENT, STUDENT-ek — `42501` |
| `update students … where id='S0'` (idegen sor) | AGENT, STUDENT-ek — 0 sor |
| `delete from students` | ADMISSIONS, FINANCE, AGENT, STUDENT-ek — 0 sor |
| `update admission_processes … owner_email='nincs1@sehol.hu'` | AGENT, STUDENT-ek — 0 sor |
| `insert into payments` (bármilyen névre) | ADMISSIONS, AGENT, nem-linkelt STUDENT — `42501` |
| `insert into payments` idegen névre | linkelt STUDENT — `42501` (a névhamisítás előtt!) |
| `update payments set status='Paid'` | ADMISSIONS, AGENT, STUDENT-ek — 0 sor |
| `insert into feed_posts` / `programs` / `kb_documents` | FINANCE, AGENT, STUDENT-ek — `42501` |
| `update program_applications` idegen sorra (PA-4) | AGENT, STUDENT-ek — 0 sor |
| `insert into program_applications` idegen e-mailre | AGENT, STUDENT-ek — `42501` |
| `insert into process_messages` idegen `owner_email`-lel | AGENT, STUDENT-ek — `42501` |
| `delete from process_messages` | AGENT, STUDENT-ek — 0 sor |
| `update agencies` (felvitt AG-SEED sorra) | ADMISSIONS, FINANCE, AGENT, STUDENT-ek — 0 sor |
| `update students set "agentId"` idegen sorra | AGENT, STUDENT-ek — 0 sor |
| `insert into payments` üres vagy NULL `studentName`-mel | **minden** nem-pénzügyi szerepkör — `42501` (a `NULL = NULL` helyesen nem enged) |

Ezek a mért eredmények azt mutatják, hogy a szerepkör-szétválasztás **működik** — a három
nevesített lyuk kivételével.

---

## 5. Hibák a migráció fájljában — összefoglaló, súlyozva

| # | súly | hol | mit mértünk | javasolt SQL |
|---|---|---|---|---|
| 1 | **BLOKKOLÓ** | 5.1 `rbac_students_update` | STUDENT átírja a `students.name`-jét → azonnal más `payments`/`invoices` sorát látja, és a nevére hamis „Paid" fizetést szúr be | 4.2: `students_protect_identity` trigger + hosszabb távon `studentId` oszlop a payments/invoices táblára |
| 2 | **BLOKKOLÓ** | 3.8 `rbac_interviewslots_update` | bármely jóváhagyott fiók (AGENT és STUDENT is) szabad idősávot foglal **más nevére és más `studentId`-jével** | 4.3: `interviewslots_force_owner` trigger |
| 3 | **BLOKKOLÓ (ígéret-szegés)** | 9.1 `$rbac_catalog$` | a fejléc szerint „a viselkedés BETŰRE UGYANAZ marad", de a 11-es önmagában **nyilvánossá teszi** a `programs` (17 sor) és `kb_documents` (9 sor) táblát az `anon` szerepkörnek | 3.1: `for select to authenticated using (public.is_approved())`, vagy tudatos döntésként átvinni a 12-esbe |
| 4 | KÖZEPES | 7. `rbac_auditlogs_insert` | bármely jóváhagyott fiók tetszőleges `"user"` értékkel gyárt naplóbejegyzést | 4.4: `auditlogs_force_actor` trigger |
| 5 | KÖZEPES | 8.2 `$rbac_social$` | az `event_rsvps` / `ticket_claims` INSERT-nek nincs `is_staff()` ága → **senki**, még a SUPERADMIN sem tud más nevében regisztrálni | 4.5: `with check (public.is_staff() or (…))` |
| 6 | KÖZEPES | 4. szakasz | az `ADMISSIONS` a flip után **0** `payments` és **0** `invoices` sort lát (ma 7-et és 3-at) | döntés kérdése: vagy hozzávenni az ADMISSIONS-t, vagy a felületen elrejteni |
| 7 | KÖZEPES | `is_staff()` használata | a `FINANCE` teljes írási jogot kap a `students` (11 sor), `admission_processes` (15 sor), `program_applications` táblán | ha nem szándék: `has_role('SUPERADMIN','ADMIN','ADMISSIONS')` az `is_staff()` helyett ezeken a táblákon |
| 8 | KÖZEPES | nem a 11-es hibája, de a flip után is fennáll | a `profiles` mind a 14 sora, e-mail-lel, látszik minden jóváhagyott fióknak (hallgatónak és ügynöknek is); az ADMIN nem tud más profilt szerkeszteni | külön migráció: `profiles_select` szűkítése `id = auth.uid() or is_staff()`-re, és az ADMIN felvétele a `profiles_update` `using` ágába |
| 9 | ALACSONY | 5.1 / általános | STUDENT átírhatja a saját `students.id` és `students.email` mezőjét (adatintegritási kár, jogosultság-nyereség nélkül) | ugyanaz a trigger, mint az 1-esnél |
| 10 | ALACSONY | fejléc „ELLENŐRIZVE" | a fájl 5 tesztmintája (A–E) **kommentben** van, uuid-helyőrzőkkel; élesben senki nem fogja lefuttatni | a jelentés 4. fejezetének próbáit érdemes külön `_teszt.sql`-be tenni, futtatható alakban |

**Nem találtunk hibát** ezekben: a fájl szintaxisa, az idempotencia, a `to_regclass` védelem,
a `$do$` blokkok idézőjelezése, a `lower(t)` a `campaigns`/`marketingCampaigns` policy-neveknél,
az idegen alkalmazás tábláinak érintetlensége, a `NULL`-kezelés a névegyezésnél
(a `coalesce` szándékos kihagyása helyes, mérve: üres/`NULL` névvel a beszúrás `42501`-gyel bukik),
és az append-only `auditLogs` UPDATE/DELETE tiltása (0 sor minden szerepkörnél, SUPERADMIN-t is beleértve).

---

## 6. Teendők a 12-es flip előtt — mért prioritási sorrend

1. **Tedd fel a `students_protect_identity` triggert** (4.2). Enélkül a flip **rontja** a helyzetet:
   ma minden hallgató mindent lát, de legalább nem tud célzottan más nevébe bújni; a flip után a
   névválasztás lesz a hozzáférés kulcsa.
2. **Tedd fel az `interviewslots_force_owner` triggert** (4.3).
3. **Döntsd el a katalógus nyilvánosságát** (3.1) — és ha nem kell, javítsd a 11-est, mielőtt élesben fut.
4. **Javítsd az ügynöki láncot vagy vedd tudomásul.** Mérve: adatjavítás nélkül az AGENT 0 hallgatót lát,
   javítással 5-öt. `payments` és `admission_processes` így is 0 marad — ha kell, külön AGENT-ág kell a policy-be.
5. **Kösd be a hallgatói fiókokat.** Ma 9-ből 1. A többi 8 fiók a flip után üres portált kap.
   Minimum: `profiles."studentId"` feltöltése, vagy a `students.email` egyeztetése a `profiles.email`-lel.
6. **Döntsd el az ADMISSIONS ↔ pénzügy és a FINANCE ↔ jelentkezői adat kérdést** (6. és 7. pont).
7. **Vidd fel az `event_rsvps`/`ticket_claims` ügyintézői ágát** (4.5).
8. Csak ezután futtasd a 12-est. A biztonsági fék (`raise exception`, ha nincs `rbac_` policy)
   a vázlatban helyes, tartsd meg.

---

## 7. Reprodukálhatóság

A méréshez használt fájlok ugyanebben a könyvtárban:

| fájl | mi |
|---|---|
| `_probe_fn.sql` | `public.rbac_probe()` — 26 tábla `count(*)`-ja a hívó jogosultságával |
| `_matrix.sh` | szerepkör × tábla mátrix generálása (opcionális prelude SQL-lel) |
| `_flip.sql` | a 12-es flip hatása: `approved_all` eldobása mind a 22 táblán |
| `_probes.txt`, `_probes2.txt` | a 40 + 17 írási próba |
| `_wrun.sh`, `_wrun2.sh` | az írási próbák futtatói (`savepoint`-onként izolálva) |
| `_matrix_before.csv`, `_matrix_after11.csv`, `_matrix_flip.csv` | nyers mérési adat |
| `_writes.csv`, `_writes2.csv`, `_writes3.csv` | nyers írási eredmények |
| `_run1.log`, `_run2.log` | a 11-es két futásának teljes kimenete |

A replika a mérés után abban az állapotban maradt, hogy a **11-es kétszer lefutott**
(86 `rbac_` policy + 22 `approved_all`), a flip és minden javítási kísérlet
`rollback`-kel eldobva. Két segédfüggvény (`public.rbac_probe()`, `public.wprobe(text)`)
maradt a replikán; élesbe ezek **ne** kerüljenek.
