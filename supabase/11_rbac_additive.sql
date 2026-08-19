-- ============================================================
-- UniPortal Pro — Szerepkör-alapú RLS, 1. fázis: ADDITÍV (Step 13a)
-- Változat: 2026-08-18, ÉLŐ POSTGRES-REPLIKÁN MÉRVE ÉS JAVÍTVA
-- ============================================================
--
-- MIT CSINÁL:
--   • Létrehoz jogosultság-vizsgáló SECURITY DEFINER függvényeket
--     (my_role, my_email, my_agency, my_student_id, my_student_name,
--      my_display_name, has_role, is_admin, is_student, is_agent,
--      is_admissions, is_finance, is_my_agency_student_email) a 07/08-as
--     migráció mintájára.
--   • Létrehoz a 22 UniPortal adattáblán egy teljes, szerepkör-alapú
--     policy-készletet "rbac_" előtaggal (rbac_students_select, …).
--     Összesen 86 policy: 21 tábla × 4 (SELECT/INSERT/UPDATE/DELETE) +
--     auditLogs × 2 (az szándékosan append-only).
--   • Felteszi a 10. szakasz NÉGY integritás-triggerét, amelyek azt fogják
--     meg, amit az RLS elvileg sem tud: hogy KI MELYIK OSZLOPOT írhatja.
--
-- MIT NEM CSINÁL — ÉS EZ A LÉNYEG:
--   • NEM dobja el a 07-es migráció "approved_all" policy-jét.
--   • NEM módosít adatot, NEM ad hozzá oszlopot, NEM nyúl a profiles
--     táblához, és nem érinti az ugyanebben a sémában élő MÁSIK alkalmazás
--     tábláit (prefs, publications, publication_files) — azok egyetlen
--     táblalistában sem szerepelnek.
--
-- MIÉRT BIZTONSÁGOS MOST LEFUTTATNI:
--   A Postgres a permisszív policy-ket VAGY-olja: egy sor akkor látszik /
--   írható, ha LEGALÁBB EGY policy átengedi. Az "approved_all" ma minden
--   jóváhagyott fióknak mindent enged, és mind a 14 fiók 'approved'.
--   Az új, szűkebb rbac_ policy-k hozzáadása ezért a LÁTHATÓSÁGOT nem
--   változtatja meg — replikán, szerepkörönként, sorszám szerint lemérve.
--   Az új szabályok CSAK akkor lépnek életbe, amikor a 12_rbac_flip.sql
--   eldobja az approved_all-t.
--
--   EGY DOLOG MÉGIS AZONNAL VÁLTOZIK, és ez tudatos: a 10. szakasz
--   integritás-triggerei a flip előtt is élnek. Ezek nem tiltanak semmit
--   (nem dobnak hibát), csak visszaírják az eredeti / hiteles értéket olyan
--   oszlopokban, amelyeket a hívónak nem szabadna írnia. Ha a flipig
--   halasztani akarod, a 10. szakaszt vágd ki — de akkor a lentebb leírt
--   névhamisítás addig NYITVA marad. MA IS kihasználható, nem csak a flip után.
--
-- ============================================================
-- MI VÁLTOZOTT AZ ELŐZŐ VÁLTOZATHOZ KÉPEST (mind mérés alapján)
-- ============================================================
--   1. KATALÓGUS: a programs / kb_documents SELECT policy-je már NEM
--      "to anon, authenticated using (true)". A régi alak a bejelentkezés
--      nélküli látogatónak azonnal megnyitotta a 17 programs és 9
--      kb_documents sort (mérve: anon 0 → 17 és 0 → 9), holott a fájl azt
--      ígérte, hogy semmi nem változik. Most: "to authenticated using
--      (public.is_approved())" — betűre az, amit az approved_all ad.
--   2. HALLGATÓI NÉVHAMISÍTÁS (blokkoló volt): a students UPDATE policy a
--      saját sor MINDEN oszlopát engedte, a payments/invoices tulajdonlás
--      viszont NÉVEGYEZÉSEN alapul. Mérve: a hallgató átírta a saját
--      students.name mezőjét 'Elena Rodriguez'-re, és onnantól MÁS fizetési
--      és számlasorait látta, sőt a nevére hamis "Paid" fizetést szúrt be.
--      Javítva: 10.1 students_protect_identity trigger.
--   3. IDŐSÁV-FOGLALÁS MÁS NEVÉRE (blokkoló volt): mérve, hogy nem csak a
--      hallgató, hanem az AGENT is le tudott foglalni szabad idősávot idegen
--      studentId/studentName értékkel. Javítva: 10.2 trigger + az UPDATE
--      policy már csak ügyintézőt és HALLGATÓT enged, ügynököt nem.
--   4. PÉNZÜGYI BESZÚRÁS NÉVVEL: a hallgatói payments INSERT most triggerrel
--      is a saját nevére kényszerül (10.3), nem csak policy-vel.
--   5. NAPLÓHAMISÍTÁS: mérve, hogy bármely jóváhagyott fiók tetszőleges
--      "user" értékkel gyárthatott auditLogs sort. Javítva: 10.4 trigger
--      (az ügyintézőt szándékosan kihagyja, mert az app.jsx:301 a
--      'System (WhatsApp)' értéket írja be, és azt nem szabad elrontani).
--   6. RENDEZVÉNY-REGISZTRÁCIÓ: mérve, hogy az event_rsvps / ticket_claims
--      INSERT-jét MÉG A SUPERADMIN SEM tudta más nevére kiadni (42501 mind a
--      hét szerepkörnél). Javítva: a with check kapott is_staff() ágat.
--   7. ADMISSIONS ↔ PÉNZÜGY: mérve, hogy a flip után az ADMISSIONS 7 → 0
--      payments és 3 → 0 invoices sort látott volna. Most OLVASÁSI jogot kap
--      mindkét táblára (írásit NEM). Ha ez nem kell, a 4. szakaszban egy-egy
--      "or public.is_admissions()" törlése visszaveszi.
--   8. ÜGYNÖKI LÁNC: az AGENT olvasási ága bekerült az admission_processes
--      és program_applications táblára is (a saját ügynökségéhez tartozó
--      jelentkezők e-mail-címe alapján). Ez MA nulla sort ad, mert az adat
--      törött (lásd (A) pont), de az adat rendezésekor magától életre kel.
--   9. ELŐELLENŐRZÉS a 0. szakaszban: a másik alkalmazással való
--      függvénynév-ütközés kiszűrésére.
--
-- ============================================================
-- NÉGY DOLOG, AMIT A 12-ES FLIP ELŐTT EL KELL DÖNTENI
-- ============================================================
--
-- (A) AZ ÜGYNÖK→HALLGATÓ LÁNC MA TÖRÖTT — MÉRVE.
--     agencies: 0 sor. A students táblán nincs "agencyId" oszlop, csak
--     "agentId", értékei 'A1'(5 hallgató), 'A2'(3), 'A3'(2), NULL(1).
--     A profiles."agencyId" egyetlen kitöltött értéke 'AG1'. Az egyenlőség
--     SOHA nem áll fenn, tehát az ügynök a flip után 0 hallgatót lát.
--     Mérve az is, mennyit érne a javítás: ha az agencies feltöltve
--     (AG1/AG2/AG3) és az agentId 'A*' → 'AG*' átírva, az AGENT 0 helyett
--     5 hallgatót lát. A 13. szakaszban ott az adatjavító blokk — KOMMENTBEN,
--     mert ez adatmódosítás, és külön döntés.
--     (A frontend app.jsx:929-931 ráadásul egy nem létező s.agencyId mezőre
--     szűr, ezért az Ügynök portál MA IS üres — ez nem az RLS hibája.)
--
-- (B) A PÉNZÜGYI TÁBLÁK NÉVVEL AZONOSÍTJÁK A JELENTKEZŐT.
--     A payments és invoices táblán a hallgatóra KIZÁRÓLAG a "studentName"
--     szövegmező mutat. A 10.1 és 10.3 trigger a hamisítást megfogja, de a
--     modell attól még törékeny: két azonos nevű jelentkező látná egymás
--     sorait. (Mérve: ma nincs két azonos nevű hallgató.) Végleges megoldás
--     a 13. szakaszban: "studentId" oszlop felvétele mindkét táblára.
--
-- (C) A HALLGATÓI LÁNC SZINTE ÜRES — MÉRVE.
--     9 STUDENT profil van, de csak 1 köthető students sorhoz (chen@test.com
--     ↔ S2). A flip után a másik 8 fiók a students / payments / invoices
--     táblán 0 sort lát. Ez nem hiba a policy-ben — ez hiányzó adat.
--     Rendezés: profiles."studentId" feltöltése, vagy a students.email
--     összehangolása a profiles.email-lel.
--
-- (D) A FRONTEND CSENDBEN LENYELI AZ RLS-MEGTAGADÁST.
--     A features/data-layer.jsx dlInsert/dlUpdate (63-91. sor) minden hibát
--     elkap és localStorage-ra vált: egy megtagadott írás a felületen
--     SIKERESNEK látszik. A flip után ezért NEM elég kattintgatni — a
--     Supabase logban vagy a hálózati fülön kell nézni a 401/403 válaszokat.
--     (A régebbi sbInsert/sbUpdate — app.jsx:241-250 — ezzel szemben dob.)
--
-- FUTTATÁS: Supabase dashboard → SQL Editor → New query → beilleszt → Run.
-- Idempotens, egyetlen beillesztéssel lefut, nincs benne psql meta-parancs.
-- ============================================================


-- ============================================================
-- 0. SZAKASZ — ELŐELLENŐRZÉS: NÉVÜTKÖZÉS A MÁSIK ALKALMAZÁSSAL
-- ============================================================
-- A public sémát egy MÁSIK alkalmazás is használja (prefs / publications /
-- publication_files). Az alább bevezetett nevek közül több generikus:
-- has_role, is_admin, is_student, is_agent, my_role, my_email.
-- Ha a másik alkalmazás már definiált ilyet AZONOS szignatúrával, de ELTÉRŐ
-- visszatérési típussal, a lenti `create or replace function` hibára fut
-- ("cannot change return type of existing function"), és mivel a Supabase
-- SQL Editor a beillesztést EGY tranzakcióként futtatja, az EGÉSZ migráció
-- visszagördül. Eltérő szignatúránál pedig csendben túlterhelés keletkezik.
--
-- HA AZ ALÁBBI LEKÉRDEZÉS BÁRMILYEN SORT AD: állj meg és nézd meg, mi az.
-- Ütközésnél a legtisztább megoldás egy UniPortal-előtag (up_has_role, …).
-- Az is_staff() / is_approved() / is_superadmin() viszont MARADJON a régi
-- nevén — a 07/08/10-es migrációk és a storage policy-k rájuk épülnek.
-- Jelöld ki ezt a lekérdezést és futtasd külön, MIELŐTT a teljes fájlt
-- beilleszted. A fájl többi része nem függ tőle.
select
  p.oid::regprocedure            as letezo_fuggveny,
  pg_get_function_result(p.oid)  as visszateres,
  p.prosecdef                    as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('my_role', 'my_email', 'my_agency', 'my_student_id',
                    'my_student_name', 'my_display_name', 'has_role',
                    'is_admin', 'is_student', 'is_agent', 'is_admissions',
                    'is_finance', 'is_my_agency_student_email');


-- ============================================================
-- 1. SZAKASZ — JOGOSULTSÁG-VIZSGÁLÓ SEGÉDFÜGGVÉNYEK
-- ============================================================
-- Mind: STABLE, SECURITY DEFINER, set search_path = public — pontosan úgy,
-- mint a 07-es is_approved()/is_superadmin() és a 08-as is_staff().
-- A SECURITY DEFINER itt KÖTELEZŐ: ezek a függvények a public.profiles
-- táblát olvassák, és policy-kből hívjuk őket. Ha nem kerülnék meg a
-- profiles saját RLS-ét, végtelen rekurzió lenne
-- (policy → függvény → profiles → policy → …).
--
-- MIÉRT A PROFILES-BÓL ÉS NEM A JWT-BŐL: a JWT claim-ek a token
-- élettartama alatt nem frissülnek — egy visszavont szerepkör így még
-- órákig érvényes maradna. A profiles sor mindig az aktuális igazság, és a
-- 07-es profiles_protect_privileges trigger őrzi (mérve: a saját
-- role / approval_status / studentId / agencyId átírása csendben visszaíródik
-- mindenkinél, aki nem SUPERADMIN — az UPDATE „1 sor"-t jelent, de az érték
-- nem változik).

-- ---------- 1.1 a bejelentkezett felhasználó szerepköre ----------
-- Nyers érték, jóváhagyás-vizsgálat NÉLKÜL. Diagnosztikára való; policy-ben
-- a has_role()-t használjuk helyette, mert az a jóváhagyást is nézi.
create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

-- ---------- 1.2 a saját e-mail-cím, kisbetűsítve ----------
-- Öt tábla e-mail-lel azonosítja a tulajdonost (admission_processes,
-- process_messages, program_applications, event_rsvps, ticket_claims).
-- Mindig a profiles sorból olvassuk, NEM a JWT-ből: a tulajdonlás-ellenőrzés
-- nem függhet egy kliens által befolyásolható mezőtől. A lower() azért kell,
-- mert az adat vegyes kis/nagybetűs.
create or replace function public.my_email()
returns text language sql stable security definer set search_path = public as $$
  select lower(email) from public.profiles where id = auth.uid()
$$;

-- ---------- 1.3 a saját ügynökség azonosítója ----------
create or replace function public.my_agency()
returns text language sql stable security definer set search_path = public as $$
  select nullif("agencyId", '') from public.profiles where id = auth.uid()
$$;

-- ---------- 1.4 a saját hallgatói azonosító ----------
-- profiles."studentId" → students.id. Mérve: 14 profilból 1-ben van kitöltve,
-- ezért minden tulajdonlási feltételben van e-mail-alapú tartalék ág is.
create or replace function public.my_student_id()
returns text language sql stable security definer set search_path = public as $$
  select nullif("studentId", '') from public.profiles where id = auth.uid()
$$;

-- ---------- 1.5 a saját név a students táblában ----------
-- KIZÁRÓLAG a payments/invoices táblák miatt létezik (lásd (B) pont).
-- Először a megbízható úton (profiles."studentId" → students.id), és csak
-- utána e-mail-egyezésre esik vissza.
-- NULL, ha a fiókhoz nem tartozik students sor — mérve: 9 STUDENT fiókból
-- 8-nál NULL. A NULL = bármi → NULL → a policy nem enged. Ez a helyes irány,
-- a coalesce-t szándékosan kihagyjuk, nehogy két üres név egyezzen.
create or replace function public.my_student_name()
returns text language sql stable security definer set search_path = public as $$
  select s.name
  from public.students s
  where s.id = public.my_student_id()
     or lower(s.email) = public.my_email()
  order by (s.id = public.my_student_id()) desc nulls last
  limit 1
$$;

-- ---------- 1.6 megjelenítendő név (idősáv-foglaláshoz) ----------
-- A 10.2 trigger ezzel tölti ki az "interviewSlots"."studentName" mezőt.
-- Azért nem a my_student_name(), mert az 9-ből 8 hallgatónál NULL lenne,
-- és akkor a foglalás névtelen sort hagyna maga után.
create or replace function public.my_display_name()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    public.my_student_name(),
    nullif((select name from public.profiles where id = auth.uid()), ''),
    public.my_email()
  )
$$;

-- ---------- 1.7 szerepkör-ellenőrzés (a policy-k munkalova) ----------
-- Igaz, ha a fiók JÓVÁHAGYOTT ÉS a szerepköre a felsoroltak között van.
-- A jóváhagyás beépítése nem redundancia: így egyetlen hívás sem felejtheti
-- el, és egy 'pending' ADMIN sem ér el semmit.
create or replace function public.has_role(variadic p_roles text[])
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and approval_status = 'approved'
      and role = any (p_roles)
  )
$$;

-- ---------- 1.8 kényelmi burkolók ----------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('SUPERADMIN', 'ADMIN')
$$;

create or replace function public.is_student()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('STUDENT')
$$;

create or replace function public.is_agent()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('AGENT')
$$;

-- A felvételi oldal: ők szerkesztik a katalógust, a kampányt, a hírfolyamot.
create or replace function public.is_admissions()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('SUPERADMIN', 'ADMIN', 'ADMISSIONS')
$$;

-- A pénzügyi oldal: ők írják a payments/invoices sorokat.
create or replace function public.is_finance()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('SUPERADMIN', 'ADMIN', 'FINANCE')
$$;

-- ---------- 1.9 ügynöki tulajdonlás e-mail alapján ----------
-- Igaz, ha a megadott e-mail-cím a hívó ügynökségéhez tartozó jelentkezőé.
-- Azért külön SECURITY DEFINER függvény, és nem beágyazott alkérdés a
-- policy-ben: a policy kifejezésében hivatkozott public.students táblán is
-- érvényesülne az RLS, ami kereszthivatkozást és rekurziót okozna.
-- MÉRVE: ma minden hívásra false, mert a students."agentId" ('A1','A2','A3')
-- és a profiles."agencyId" ('AG1') nem találkozik. Lásd (A) pont.
create or replace function public.is_my_agency_student_email(p_email text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.my_agency() is not null
     and p_email is not null
     and exists (
           select 1 from public.students s
           where s."agentId" = public.my_agency()
             and lower(s.email) = lower(p_email)
         )
$$;

-- ---------- 1.10 is_staff(): VÁLTOZATLANUL újradefiniálva ----------
-- Az is_staff() MÁR LÉTEZIK a 08-as migrációból, és RÁÉPÜL a documents
-- bucket négy storage policy-je (08:57-84) meg a wa_contacts/wa_messages
-- policy (10:60-66). A törzse itt BETŰRE UGYANAZ, mint a 08-asban — csak
-- azért szerepel, hogy ez a fájl önmagában is futtatható legyen, ha valaki
-- sorrendet cserél. Ha valaha módosítod, a 08-as és 10-es viselkedése is
-- megváltozik: NE tedd egy szerepkör hozzáadása kedvéért.
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and approval_status = 'approved'
      and role in ('SUPERADMIN', 'ADMIN', 'ADMISSIONS', 'FINANCE')
  )
$$;

-- ---------- 1.11 grantok ----------
-- Csak authenticated: a 9.1 katalógus-policy már nem hív függvényt anon
-- szerepkörben, tehát az anon-nak semmit nem kell megadni.
grant execute on function public.my_role()                          to authenticated;
grant execute on function public.my_email()                         to authenticated;
grant execute on function public.my_agency()                        to authenticated;
grant execute on function public.my_student_id()                    to authenticated;
grant execute on function public.my_student_name()                  to authenticated;
grant execute on function public.my_display_name()                  to authenticated;
grant execute on function public.has_role(variadic text[])          to authenticated;
grant execute on function public.is_admin()                         to authenticated;
grant execute on function public.is_student()                       to authenticated;
grant execute on function public.is_agent()                         to authenticated;
grant execute on function public.is_admissions()                    to authenticated;
grant execute on function public.is_finance()                       to authenticated;
grant execute on function public.is_my_agency_student_email(text)   to authenticated;
grant execute on function public.is_staff()                         to authenticated;


-- ============================================================
-- 2. SZAKASZ — ELŐKÉSZÍTÉS: RLS bekapcsolva, régi rbac_ policy-k törölve
-- ============================================================
-- Az idempotencia miatt minden rbac_ policy-t ELŐSZÖR eldobunk. Így a fájl
-- akárhányszor újrafuttatható, és egy korábbi próbálkozás félkész policy-i
-- sem maradnak ott. Az "approved_all"-t itt NEM bántjuk — az a 12-es dolga.
-- A táblalista NEVESÍTETT (nincs "for all tables in schema"): a másik
-- alkalmazás táblái nem szerepelnek benne, tehát nem is érintheti őket.
do $rbac_clean$
declare
  t text;
  p text;
begin
  foreach t in array array[
    'users', 'students', 'payments', 'invoices', 'campaigns', 'auditLogs',
    'webhooks', 'interviewSlots', 'agencies', 'leads', 'marketingCampaigns',
    'scholarships', 'integrations', 'videoInterviewQuestions',
    'admission_processes', 'process_messages',
    'feed_posts', 'event_rsvps', 'ticket_claims',
    'programs', 'program_applications', 'kb_documents'
  ]
  loop
    if to_regclass(format('public.%I', t)) is null then
      raise notice 'Kihagyva (nincs ilyen tabla): %', t;
      continue;
    end if;

    execute format('alter table public.%I enable row level security', t);

    for p in
      select policyname from pg_policies
      where schemaname = 'public' and tablename = t and policyname like 'rbac\_%'
    loop
      execute format('drop policy if exists %I on public.%I', p, t);
    end loop;
  end loop;
end
$rbac_clean$;


-- ============================================================
-- 3. SZAKASZ — TÖRZSADAT ÉS MŰKÖDÉSI TÁBLÁK
-- ============================================================
-- Elv: ezeket a táblákat az intézmény tartja karban, nem a jelentkező.
-- Olvasás annyi szerepkörnek, amennyinek a munkájához tényleg kell;
-- írás a legszűkebb körnek, ami a felületen ténylegesen szerkeszti.
-- (Mérve: ezek a táblák ma mind ÜRESEK az éles adatbázisban — 0 sor —,
-- ezért a láthatóságuk a flip után sem változtat semmit a felületen.
-- A szabályokat ettől függetlenül felvitt próbasorokkal is lemértük,
-- hogy a "0 sor" valódi tiltást jelentsen, ne üres táblát.)

-- ---------- 3.1 users — belső felhasználói névsor ----------
-- Ez NEM az auth tábla, hanem a demo „kollégák" listája (01:20-36).
-- Jelentkező és ügynök semmit nem kezd vele → nem is látja.
-- Írás: csak admin (szerepkör-kiosztás jellegű adat).
create policy "rbac_users_select" on public."users"
  for select to authenticated using (public.is_staff());
create policy "rbac_users_insert" on public."users"
  for insert to authenticated with check (public.is_admin());
create policy "rbac_users_update" on public."users"
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "rbac_users_delete" on public."users"
  for delete to authenticated using (public.is_admin());

-- ---------- 3.2 agencies — ügynökségek ----------
-- Az ügynök a SAJÁT ügynökségének sorát látja (a felület a jutalékot és a
-- kapcsolattartót jeleníti meg belőle — app.jsx:945), másét nem.
-- Írás: admin. Jutalékkulcsot ügyintéző nem írhat át.
-- MÉRVE: a tábla ma 0 soros; felvitt próbasorral a szabály helyesen működik
-- (ADMISSIONS/FINANCE/AGENT/STUDENT UPDATE-je 0 sort érint, INSERT-je 42501).
create policy "rbac_agencies_select" on public."agencies"
  for select to authenticated
  using (
    public.is_staff()
    or (public.is_agent() and public.my_agency() is not null and id = public.my_agency())
  );
create policy "rbac_agencies_insert" on public."agencies"
  for insert to authenticated with check (public.is_admin());
create policy "rbac_agencies_update" on public."agencies"
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "rbac_agencies_delete" on public."agencies"
  for delete to authenticated using (public.is_admin());

-- ---------- 3.3 campaigns / marketingCampaigns — kampányok ----------
-- Belső marketingadat (költségkeret, elköltött összeg, konverziók).
-- Olvasás: ügyintéző. Írás: ADMISSIONS + ADMIN + SUPERADMIN.
-- (A FINANCE olvashatja a költségkeretet, de nem szerkeszti a kampányt.)
-- A policy-nevet lower(t)-vel képezzük, mert a "marketingCampaigns"
-- táblanév vegyes kis/nagybetűs — a policy-nevek maradjanak egységesek.
do $rbac_camp$
declare t text;
begin
  foreach t in array array['campaigns', 'marketingCampaigns']
  loop
    if to_regclass(format('public.%I', t)) is null then continue; end if;
    execute format(
      'create policy "rbac_%s_select" on public.%I for select to authenticated
         using (public.is_staff())', lower(t), t);
    execute format(
      'create policy "rbac_%s_insert" on public.%I for insert to authenticated
         with check (public.is_admissions())', lower(t), t);
    execute format(
      'create policy "rbac_%s_update" on public.%I for update to authenticated
         using (public.is_admissions()) with check (public.is_admissions())', lower(t), t);
    execute format(
      'create policy "rbac_%s_delete" on public.%I for delete to authenticated
         using (public.is_admin())', lower(t), t);
  end loop;
end
$rbac_camp$;

-- ---------- 3.4 scholarships — ösztöndíjak ----------
-- ELTÉR a többi törzsadattól: a jelentkezőnek LÁTNIA kell, mire pályázhat,
-- ezért az olvasás minden jóváhagyott fióknak jár. Írás: ADMISSIONS+ADMIN.
create policy "rbac_scholarships_select" on public."scholarships"
  for select to authenticated using (public.is_approved());
create policy "rbac_scholarships_insert" on public."scholarships"
  for insert to authenticated with check (public.is_admissions());
create policy "rbac_scholarships_update" on public."scholarships"
  for update to authenticated
  using (public.is_admissions()) with check (public.is_admissions());
create policy "rbac_scholarships_delete" on public."scholarships"
  for delete to authenticated using (public.is_admin());

-- ---------- 3.5 videoInterviewQuestions — interjúkérdések ----------
-- A jelentkező a felvételi folyamatban látja a kérdéseket → olvasás
-- minden jóváhagyottnak. Írás: ADMISSIONS+ADMIN.
create policy "rbac_videointerviewquestions_select" on public."videoInterviewQuestions"
  for select to authenticated using (public.is_approved());
create policy "rbac_videointerviewquestions_insert" on public."videoInterviewQuestions"
  for insert to authenticated with check (public.is_admissions());
create policy "rbac_videointerviewquestions_update" on public."videoInterviewQuestions"
  for update to authenticated
  using (public.is_admissions()) with check (public.is_admissions());
create policy "rbac_videointerviewquestions_delete" on public."videoInterviewQuestions"
  for delete to authenticated using (public.is_admin());

-- ---------- 3.6 integrations — fizetési/számlázási integrációk ----------
-- Szolgáltatók állapota és üzemmódja (Test/Live). A FINANCE-nek látnia kell,
-- de csak az admin kapcsolgathatja. ADMISSIONS/AGENT/STUDENT: semmi.
create policy "rbac_integrations_select" on public."integrations"
  for select to authenticated using (public.is_finance());
create policy "rbac_integrations_insert" on public."integrations"
  for insert to authenticated with check (public.is_admin());
create policy "rbac_integrations_update" on public."integrations"
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "rbac_integrations_delete" on public."integrations"
  for delete to authenticated using (public.is_admin());

-- ---------- 3.7 webhooks — kimenő integrációs végpontok ----------
-- A legérzékenyebb üzemeltetési tábla: egy webhook URL átírásával minden
-- „STUDENT_ENROLLED" esemény idegen szerverre irányítható. Csak admin,
-- olvasásra is. (Mérve: ADMISSIONS/FINANCE/AGENT/STUDENT INSERT-je 42501.)
create policy "rbac_webhooks_select" on public."webhooks"
  for select to authenticated using (public.is_admin());
create policy "rbac_webhooks_insert" on public."webhooks"
  for insert to authenticated with check (public.is_admin());
create policy "rbac_webhooks_update" on public."webhooks"
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "rbac_webhooks_delete" on public."webhooks"
  for delete to authenticated using (public.is_admin());

-- ---------- 3.8 interviewSlots — interjú-idősávok ----------
-- Itt a jelentkező NEM csak olvas: a foglalás az ő böngészőjéből írja a sort
-- (app.jsx:277 → sbUpdate('interviewSlots', …, {status:'Booked', studentId,
-- studentName, teamsMeetingUrl})). Ezért UPDATE-jogot is kap — de:
--   • csak SZABAD idősávra (status = 'Available'), tehát MÁS FOGLALÁSÁT nem
--     tudja elvenni (mérve: foglalt sávra 0 sor a nem-ügyintézőknek);
--   • és csak HALLGATÓ, nem bármely jóváhagyott fiók. MÉRVE az előző
--     változaton: az AGENT is le tudott foglalni idősávot, pedig semmi köze
--     hozzá. Az is_approved() helyére ezért is_student() került;
--   • a "studentId"/"studentName" mezőt a 10.2 trigger írja felül a hívó
--     saját adatára — RLS-ben oszlopszintű korlát nincs, ezért kell trigger.
--     MÉRVE az előző változaton: a hallgató 'Al-Farabi Ammar' / 'S1' értékkel
--     foglalt le szabad sávot; a triggerrel a sor tényleges tartalma a saját
--     neve és azonosítója lett.
-- Az olvasás mindenkinek kell, hogy lássa a szabad sávokat.
create policy "rbac_interviewslots_select" on public."interviewSlots"
  for select to authenticated using (public.is_approved());
create policy "rbac_interviewslots_insert" on public."interviewSlots"
  for insert to authenticated with check (public.is_staff());
create policy "rbac_interviewslots_update" on public."interviewSlots"
  for update to authenticated
  using (public.is_staff() or (public.is_student() and coalesce("status", 'Available') = 'Available'))
  with check (public.is_staff() or public.is_student());
create policy "rbac_interviewslots_delete" on public."interviewSlots"
  for delete to authenticated using (public.is_staff());


-- ============================================================
-- 4. SZAKASZ — PÉNZÜGY (payments, invoices)
-- ============================================================
-- ÍRÁS: FINANCE + ADMIN + SUPERADMIN (is_finance()).
-- OLVASÁS: is_finance() + ADMISSIONS + a saját sorok.
--
-- MIÉRT LÁT AZ ADMISSIONS: mérve, hogy az előző változat a flip után az
-- ADMISSIONS-nak 7 → 0 payments és 3 → 0 invoices sort adott volna. A
-- felvételi ügyintéző munkájához hozzátartozik, hogy lássa, befizetett-e a
-- jelentkező; a felület ma is mutatja neki. Írni továbbra sem tud
-- (mérve: UPDATE 0 sor, INSERT és DELETE 42501 / 0 sor).
--   HA MÉGSEM KELL: töröld a lenti két SELECT policy-ből az
--   "or public.is_admissions()" sort, és az ADMISSIONS 0 sort fog látni.
--
-- LÁSD A FEJLÉC (B) PONTJÁT: a jelentkezői tulajdonlás NÉVEGYEZÉSEN alapul
-- (lower("studentName") = lower(public.my_student_name())), mert nincs
-- studentId oszlop ezeken a táblákon. A my_student_name() NULL-t ad, ha a
-- fiókhoz nem tartozik students sor — és NULL = bármi → NULL → a policy NEM
-- enged. Ez a helyes (biztonságos) irány.

-- ---------- 4.1 payments ----------
-- INSERT a jelentkezőnek is kell: a fizetés-szimuláció és az utalási
-- igazolás feltöltése az ő böngészőjéből szúr be sort (app.jsx:294-297,
-- 3517-3541), sbInsert-tel, ami .insert(...).select().single() — tehát a
-- beszúrás UTÁN vissza is olvassa. Ezért kell a with check MELLÉ a saját
-- sorra vonatkozó SELECT-jog is, különben a hívás hibára fut.
-- A beszúrt "studentName" mezőt a 10.3 trigger a hívó saját nevére állítja.
-- Módosítani/törölni csak a pénzügy tud (státusz Paid-re állítása).
create policy "rbac_payments_select" on public."payments"
  for select to authenticated
  using (
    public.is_finance()
    or public.is_admissions()
    or lower("studentName") = lower(public.my_student_name())
  );
create policy "rbac_payments_insert" on public."payments"
  for insert to authenticated
  with check (
    public.is_finance()
    or lower("studentName") = lower(public.my_student_name())
  );
create policy "rbac_payments_update" on public."payments"
  for update to authenticated
  using (public.is_finance()) with check (public.is_finance());
create policy "rbac_payments_delete" on public."payments"
  for delete to authenticated using (public.is_finance());

-- ---------- 4.2 invoices ----------
-- A számlát mindig az intézmény állítja ki → a jelentkező CSAK olvas.
create policy "rbac_invoices_select" on public."invoices"
  for select to authenticated
  using (
    public.is_finance()
    or public.is_admissions()
    or lower("studentName") = lower(public.my_student_name())
  );
create policy "rbac_invoices_insert" on public."invoices"
  for insert to authenticated with check (public.is_finance());
create policy "rbac_invoices_update" on public."invoices"
  for update to authenticated
  using (public.is_finance()) with check (public.is_finance());
create policy "rbac_invoices_delete" on public."invoices"
  for delete to authenticated using (public.is_finance());


-- ============================================================
-- 5. SZAKASZ — JELENTKEZŐI ADAT
-- ============================================================

-- ---------- 5.1 students ----------
-- A platform legérzékenyebb táblája: útlevélszám, cím, ajánlólevelek,
-- vízumügy, értékelés.
--
-- HÁROM TULAJDONLÁSI ÁG:
--   ügyintéző → minden sor;
--   jelentkező → a saját sora, két úton azonosítva:
--        id = public.my_student_id()      (ha a profilhoz be van kötve),
--        lower(email) = public.my_email() (frissen regisztrált fióknál ez az
--                                          egyetlen kapocs);
--   ügynök → a hozzá tartozó sorok: "agentId" = public.my_agency().
--
-- MIÉRT ÍRHAT MIND A NÉGY ÜGYINTÉZŐI SZEREPKÖR (a FINANCE is): mérve az
-- alkalmazásban — az app.jsx:290 markPaymentPaid a fizetés jóváírásakor
-- `students.update({status:'Paid'}).eq('name', …)` hívást tesz, ami
-- pénzügyi művelet. Ha a FINANCE-tól elvennénk a students írását, a
-- fizetés-jóváírás CSENDBEN eltörne (lásd (D) pont). Ezért marad is_staff().
--
-- FIGYELEM (fejléc (A) pont): a students."agentId" ma 'A1','A2','A3', a
-- profiles."agencyId" viszont 'AG1' — az egyenlőség SOHA nem teljesül, tehát
-- az ügynök a flip után 0 jelentkezőt lát (mérve). Ez tudatos: inkább
-- semmit, mint mindenkiét. Amint az adat rendbe jön, a policy változtatás
-- nélkül életre kel (mérve: 5 sor).
create policy "rbac_students_select" on public."students"
  for select to authenticated
  using (
    public.is_staff()
    or id = public.my_student_id()
    or lower(email) = public.my_email()
    or (public.is_agent() and public.my_agency() is not null and "agentId" = public.my_agency())
  );

-- Új jelentkezői sort az ügyintéző visz fel (a self-service jelentkezés az
-- admission_processes / program_applications táblákba megy, nem ide).
create policy "rbac_students_insert" on public."students"
  for insert to authenticated with check (public.is_staff());

-- UPDATE: az ügyintézőn kívül a jelentkező is írhatja a SAJÁT sorát. Ez nem
-- kényelmi engedmény: a fizetési folyamat a jelentkező böngészőjéből állítja
-- a státuszt Paid-re (app.jsx:281, 290, 296) és a vízum-checklistet is innen
-- frissíti (app.jsx:293). Az ügynök NEM ír: a jutalék- és státuszadat nem az
-- ő kezében van.
-- AZ AZONOSSÁGÁT VISZONT A JELENTKEZŐ SEM ÍRHATJA ÁT — ezt a 10.1 trigger
-- őrzi. MÉRVE az előző változaton: a hallgató átírta a saját students.name
-- mezőjét, és attól kezdve MÁS fizetéseit és számláit látta. Trigger nélkül
-- ez a flip után nem szűkítés, hanem NAGYOBB kockázat lenne a mainál.
create policy "rbac_students_update" on public."students"
  for update to authenticated
  using (
    public.is_staff()
    or id = public.my_student_id()
    or lower(email) = public.my_email()
  )
  with check (
    public.is_staff()
    or id = public.my_student_id()
    or lower(email) = public.my_email()
  );

-- Törlés: csak admin. Egy jelentkezői sor törlése visszafordíthatatlan.
create policy "rbac_students_delete" on public."students"
  for delete to authenticated using (public.is_admin());

-- ---------- 5.2 admission_processes — felvételi folyamatok ----------
-- Tulajdonos: owner_email (app.jsx:5634, 5654). A jelentkező a sajátját
-- hozza létre és írja; az ügyintéző mindent lát és javít; az ügynök a saját
-- jelentkezőinek folyamatát OLVASSA (nem írja).
-- Az owner_email lehet gazdátlan: mérve, hogy a 15 sorból 6-hoz nem tartozik
-- profil (nincs1..6@sehol.hu) — azokat helyesen csak ügyintéző látja.
create policy "rbac_admission_processes_select" on public.admission_processes
  for select to authenticated
  using (
    public.is_staff()
    or lower(owner_email) = public.my_email()
    or public.is_my_agency_student_email(owner_email)
  );
create policy "rbac_admission_processes_insert" on public.admission_processes
  for insert to authenticated
  with check (public.is_staff() or lower(owner_email) = public.my_email());
create policy "rbac_admission_processes_update" on public.admission_processes
  for update to authenticated
  using (public.is_staff() or lower(owner_email) = public.my_email())
  with check (public.is_staff() or lower(owner_email) = public.my_email());
create policy "rbac_admission_processes_delete" on public.admission_processes
  for delete to authenticated
  using (public.is_admin() or lower(owner_email) = public.my_email());

-- MEGJEGYZÉS a 09-es nézethez: a public.admission_process_list nézet
-- security_invoker = on beállítással készült (09:26), tehát a HÍVÓ RLS-e
-- érvényesül rajta — a fenti policy-k automatikusan védik a nézetet is,
-- külön policy nem kell és nem is lehetséges rá.

-- ---------- 5.3 process_messages — folyamat-üzenetek ----------
-- Ugyanaz a tulajdonlási modell (owner_email = a jelentkező címe), de az
-- üzenetet az ügyintéző írja a jelentkezőnek. Ezért a jelentkező olvashat és
-- írhat (választ), de törölni csak ügyintéző tud — így a levelezés nem
-- tüntethető el egyik oldalról sem. Az ÜGYNÖK ide szándékosan nem lát bele:
-- a jelentkező és az intézmény levelezése kétoldalú.
create policy "rbac_process_messages_select" on public.process_messages
  for select to authenticated
  using (public.is_staff() or lower(owner_email) = public.my_email());
create policy "rbac_process_messages_insert" on public.process_messages
  for insert to authenticated
  with check (public.is_staff() or lower(owner_email) = public.my_email());
create policy "rbac_process_messages_update" on public.process_messages
  for update to authenticated
  using (public.is_staff() or lower(owner_email) = public.my_email())
  with check (public.is_staff() or lower(owner_email) = public.my_email());
create policy "rbac_process_messages_delete" on public.process_messages
  for delete to authenticated using (public.is_staff());


-- ============================================================
-- 6. SZAKASZ — MARKETING (leads)
-- ============================================================
-- Nyers érdeklődői adat: név, e-mail, telefon, UTM-forrás. GDPR-szempontból
-- ez idegenek személyes adata, akik még nem is felhasználói a rendszernek.
-- Ezért a legszűkebb kör: ADMISSIONS + ADMIN + SUPERADMIN. A FINANCE-nek
-- sincs köze hozzá, az ügynöknek és a jelentkezőnek pláne nincs.
create policy "rbac_leads_select" on public."leads"
  for select to authenticated using (public.is_admissions());
create policy "rbac_leads_insert" on public."leads"
  for insert to authenticated with check (public.is_admissions());
create policy "rbac_leads_update" on public."leads"
  for update to authenticated
  using (public.is_admissions()) with check (public.is_admissions());
create policy "rbac_leads_delete" on public."leads"
  for delete to authenticated using (public.is_admissions());


-- ============================================================
-- 7. SZAKASZ — NAPLÓ (auditLogs) — APPEND-ONLY
-- ============================================================
-- SZÁNDÉKOSAN NINCS rbac_auditlogs_update ÉS rbac_auditlogs_delete.
-- A 12-es flip után az auditLogs a böngészőből MÓDOSÍTHATATLAN és
-- TÖRÖLHETETLEN — még superadminnak is. MÉRVE: felvitt próbasoron mind a
-- hét szerepkör UPDATE-je és DELETE-je 0 sort érintett. Ez a naplózás
-- értelme: aki át tudja írni a naplót, arról a napló semmit nem bizonyít.
-- Ha valaha karbantartani kell (retenció), az SQL Editorból vagy service
-- role kulccsal történjen, ahol az RLS amúgy sem érvényesül.
--
-- SELECT: ügyintéző — ÉS NEM CSAK ADMIN. Tudatos eltérés a tervtől: a
-- naplóbeszúrás az app.jsx:246-250 sbInsert-jén megy, ami
-- `.insert(row).select().single()`, tehát azonnal vissza is olvassa a sort;
-- a ténylegesen létező hívó (app.jsx:301, sendWhatsAppMessage) bármelyik
-- ügyintéző lehet, és 'System (WhatsApp)' értéket ír a "user" mezőbe, tehát
-- „saját sor" alapon nem lenne visszaolvasható. Admin-only olvasás mellett
-- ez a hívás minden nem-admin ügyintézőnél hibára futna.
--   HA szigorúbb kell: előbb írd át az alkalmazást, hogy a naplóbeszúrás ne
--   olvasson vissza, és csak UTÁNA cseréld a lenti using-ot is_admin()-ra.
--
-- INSERT: minden jóváhagyott fiók — a napló akkor ér valamit, ha minden
-- érdemi művelet be tud kerülni, függetlenül attól, ki végezte. A "user"
-- mezőt viszont a 10.4 trigger hitelesíti nem-ügyintéző hívónál.
-- MÉRVE az előző változaton: bármely jóváhagyott fiók (hallgató is)
-- tetszőleges "user" névvel gyárthatott naplóbejegyzést („Admin Anna
-- törölte X-et") — egy hamisítható napló többet árt, mint amennyit használ.
create policy "rbac_auditlogs_select" on public."auditLogs"
  for select to authenticated using (public.is_staff());
create policy "rbac_auditlogs_insert" on public."auditLogs"
  for insert to authenticated with check (public.is_approved());


-- ============================================================
-- 8. SZAKASZ — KÖZÖSSÉGI (feed_posts, event_rsvps, ticket_claims)
-- ============================================================

-- ---------- 8.1 feed_posts — kampusz-hírfolyam ----------
-- Olvasás: minden jóváhagyott fiók (ez a jelentkezői élmény lényege).
-- Írás: ADMISSIONS + ADMIN + SUPERADMIN.
-- MIÉRT NINCS „szerző írhatja a sajátját": a táblában csak author_name van
-- (features/feed.jsx:62), ami megjelenítendő SZÖVEG ('Admissions Office',
-- 'Student Life'), nem felhasználó-azonosító. Szerzőség-alapú szabályt erre
-- építeni hamis biztonságérzet lenne — bárki beírhatná más nevét. Ha valaha
-- kell, előbb egy author_email (vagy author_id uuid) oszlop kell a táblára.
create policy "rbac_feed_posts_select" on public.feed_posts
  for select to authenticated using (public.is_approved());
create policy "rbac_feed_posts_insert" on public.feed_posts
  for insert to authenticated with check (public.is_admissions());
create policy "rbac_feed_posts_update" on public.feed_posts
  for update to authenticated
  using (public.is_admissions()) with check (public.is_admissions());
create policy "rbac_feed_posts_delete" on public.feed_posts
  for delete to authenticated using (public.is_admissions());

-- ---------- 8.2 event_rsvps / ticket_claims — jelentkezés és jegyigénylés ----------
-- Mindkét táblában van `email` oszlop, amit a felület a bejelentkezett
-- felhasználó címével tölt (features/feed.jsx:146, 151) → valódi tulajdonlás.
--   SELECT: a sajátját mindenki, az összeset az ügyintéző (létszámkövetés).
--   INSERT: a saját címére bárki — ÉS az ügyintéző bármely címre.
--           JAVÍTVA: az előző változat with check-je csak a saját címet
--           engedte, ami MÉRVE azt jelentette, hogy még a SUPERADMIN sem
--           tudott mást regisztrálni (42501 mind a hét szerepkörnél).
--           Biztonságilag rendben volt, működésileg nem: kézi javításra és
--           telefonos jelentkezés rögzítésére nem maradt út.
--   UPDATE: a sor csak azonosítót és időbélyeget hordoz, de az ügyintézőnek
--           meghagyjuk javításra.
--   DELETE: a saját lemondása + ügyintéző.
do $rbac_social$
declare t text;
begin
  foreach t in array array['event_rsvps', 'ticket_claims']
  loop
    if to_regclass(format('public.%I', t)) is null then continue; end if;
    execute format(
      'create policy "rbac_%s_select" on public.%I for select to authenticated
         using (public.is_staff() or lower(email) = public.my_email())', t, t);
    execute format(
      'create policy "rbac_%s_insert" on public.%I for insert to authenticated
         with check (public.is_staff()
                     or (public.is_approved() and lower(email) = public.my_email()))', t, t);
    execute format(
      'create policy "rbac_%s_update" on public.%I for update to authenticated
         using (public.is_staff()) with check (public.is_staff())', t, t);
    execute format(
      'create policy "rbac_%s_delete" on public.%I for delete to authenticated
         using (public.is_staff() or lower(email) = public.my_email())', t, t);
  end loop;
end
$rbac_social$;


-- ============================================================
-- 9. SZAKASZ — KATALÓGUS ÉS JELENTKEZÉSEK
-- ============================================================

-- ---------- 9.1 programs / kb_documents — katalógus ----------
-- Olvasás: MINDEN JÓVÁHAGYOTT, BEJELENTKEZETT fiók. Írás: ADMISSIONS+ADMIN.
--
-- JAVÍTVA — EZ VOLT A FÁJL EGYETLEN VALÓDI VISELKEDÉSVÁLTOZÁSA.
-- Az előző változat így szólt:
--     for select to anon, authenticated using (true)
-- MÉRVE: ettől a bejelentkezés nélküli látogató (anon szerepkör) azonnal
-- megkapta a 17 programs és 9 kb_documents sort, holott ma 0-t lát. Nem az
-- oszlopjog hiányzott — az anon-nak van SELECT GRANT-ja ezeken a táblákon —,
-- hanem az RLS zárta ki, mert az egyetlen mai policy (approved_all)
-- `to authenticated`. Egy „additív, semmit nem változtató" migráció nem
-- tehet nyilvánossá adatot mellékesen.
-- MOST: pontosan az, amit az approved_all is ad. Az anon marad 0 soron.
--
-- HA A NYILVÁNOS KATALÓGUS A SZÁNDÉK: legyen külön, visszavonható lépés
-- (14_public_catalog.sql), ilyen alakban — és akkor a 11.4 ellenőrző
-- lekérdezés is jogosan fog sort adni:
--     create policy "public_programs_select" on public.programs
--       for select to anon using (true);
--
-- FIGYELEM a 12-es flip előtt: a features/programs.jsx:153 szerint az
-- alkalmazás az ELSŐ megnyitáskor magától felviszi a hiányzó szakokat
-- (upsert, try/catch-be csomagolva). A flip után ez nem-ügyintézőnél
-- CSENDBEN nem fut le. Gondoskodj róla, hogy a seed egyszer, ügyintézői
-- fiókkal (vagy SQL-ből) megtörténjen, mielőtt eldobod az approved_all-t.
do $rbac_catalog$
declare t text;
begin
  foreach t in array array['programs', 'kb_documents']
  loop
    if to_regclass(format('public.%I', t)) is null then continue; end if;
    execute format(
      'create policy "rbac_%s_select" on public.%I for select to authenticated
         using (public.is_approved())', t, t);
    execute format(
      'create policy "rbac_%s_insert" on public.%I for insert to authenticated
         with check (public.is_admissions())', t, t);
    execute format(
      'create policy "rbac_%s_update" on public.%I for update to authenticated
         using (public.is_admissions()) with check (public.is_admissions())', t, t);
    execute format(
      'create policy "rbac_%s_delete" on public.%I for delete to authenticated
         using (public.is_admin())', t, t);
  end loop;
end
$rbac_catalog$;

-- ---------- 9.2 program_applications — szakra adott jelentkezések ----------
-- Tulajdonos: applicant_email (features/programs.jsx:660, 664).
-- A jelentkező a sajátját látja, hozza létre és szerkeszti (a felület
-- lépésenként menti a `data` JSONB-t). Az ügyintéző mindent lát és bírál el.
-- Az ügynök a saját jelentkezőiét OLVASSA (ma 0 sor — lásd (A) pont).
-- Törlés: csak ügyintéző — egy beadott jelentkezést a jelentkező ne
-- tüntethessen el, miután elbírálás alá került.
create policy "rbac_program_applications_select" on public.program_applications
  for select to authenticated
  using (
    public.is_staff()
    or lower(applicant_email) = public.my_email()
    or public.is_my_agency_student_email(applicant_email)
  );
create policy "rbac_program_applications_insert" on public.program_applications
  for insert to authenticated
  with check (public.is_staff() or (public.is_approved() and lower(applicant_email) = public.my_email()));
create policy "rbac_program_applications_update" on public.program_applications
  for update to authenticated
  using (public.is_staff() or lower(applicant_email) = public.my_email())
  with check (public.is_staff() or lower(applicant_email) = public.my_email());
create policy "rbac_program_applications_delete" on public.program_applications
  for delete to authenticated using (public.is_staff());


-- ============================================================
-- 10. SZAKASZ — INTEGRITÁS-TRIGGEREK (amit az RLS elvileg sem tud)
-- ============================================================
-- A Postgres RLS SORSZINTŰ: eldönti, hogy egy sort szabad-e írni, de nem
-- tudja megmondani, hogy MELYIK OSZLOPÁT. A négy alábbi trigger pontosan ezt
-- a hiányt tölti ki. Egyik sem dob hibát — visszaírják az eredeti (vagy a
-- hiteles) értéket, tehát a felület nem törik el tőlük, csak a hamisítás
-- marad hatástalan. (Ez a Supabase REST hívásoknál is így viselkedik: a
-- PATCH „sikeres", csak a hamisított oszlop nem változik.)
--
-- MINDEGYIK KIHAGYJA:
--   • az ügyintézőt (is_staff(), a payments-nél is_finance()) — ő a
--     felületen jogosan javít;
--   • a service role / SQL Editor hívást (auth.uid() is null) — az Edge
--     Function és a karbantartó szkriptek működése nem változhat.
--
-- Ezek a triggerek a flip ELŐTT is élnek. Ez az egyetlen azonnali
-- viselkedésváltozás a fájlban, és szándékos: a lentebb leírt névhamisítás
-- MA IS kihasználható, nem csak a flip után.

-- ---------- 10.1 students: az azonosság nem írható át ----------
-- MÉRT TÁMADÁS (chen@test.com, STUDENT szerepkör, sima Supabase REST hívás,
-- a felület megkerülése nélkül — PATCH /students?id=eq.S2 elég hozzá):
--   1. update students set name='Elena Rodriguez' where id='S2'  → sikerült
--   2. ettől a látott payments 'P2: Chen Wei' helyett 'P7: Elena Rodriguez'
--      lett, a látott invoices pedig 'INV-1001: Elena Rodriguez'
--   3. insert into payments(…,'Elena Rodriguez',…,'Paid')        → sikerült
--   4. update students set email='hallgato9@mail.com' where id='S2' → sikerült
-- A payments/invoices tulajdonlás névegyezésen alapul, a nevet pedig maga a
-- támadó választotta meg. A triggerrel az 1. lépés továbbra is „1 sor"-t
-- jelent vissza, de a tényleges név 'Chen Wei' marad, és a 2-4. lépés nem
-- következik be (mérve).
-- A status, a visaChecklist, a cím stb. továbbra is írható — az app.jsx
-- fizetési és vízumfolyamata változatlanul működik (mérve:
-- update students set status='Paid' where id='S2' → sikerült).
create or replace function public.students_protect_identity()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_staff() or auth.uid() is null then
    return new;
  end if;
  -- a jelentkező az azonosságát és a pénzügyi paramétereit NEM írhatja
  new.id           := old.id;
  new.name         := old.name;
  new.email        := old.email;
  new."agentId"    := old."agentId";
  new."tuitionFee" := old."tuitionFee";
  new.evaluation   := old.evaluation;
  -- A felvételi DÖNTÉS és a fizetési link sem a jelentkezőé: a status mezőn
  -- keresztül a jelentkező felvetetné magát ('Accepted'), ami a
  -- sendConditionalAdmission (app.jsx:274) ügyintézői művelete.
  -- Mérve: e két sor nélkül a "update students set status='Accepted'" SIKERÜL.
  -- A FINANCE benne van az is_staff()-ban, tehát a fizetés jóváírásakor futó
  -- students.update({status:'Paid'}) (app.jsx:290) változatlanul működik.
  new.status        := old.status;
  new."paymentLink" := old."paymentLink";
  return new;
end
$$;

drop trigger if exists students_protect_identity_trg on public."students";
create trigger students_protect_identity_trg
  before update on public."students"
  for each row execute function public.students_protect_identity();

-- ---------- 10.2 interviewSlots: a foglalás mindig a hívóé ----------
-- MÉRT TÁMADÁS: egy hallgató — és mérve: az AGENT is — szabad idősávot
-- foglalt le idegen "studentId"/"studentName" értékkel:
--   update "interviewSlots" set status='Booked', "studentId"='S1',
--          "studentName"='Al-Farabi Ammar' where id='IS-FREE'   → sikerült
-- A triggerrel a sor tényleges tartalma a hívó saját adata lesz (mérve).
-- Foglalt sávot amúgy sem lehetett elvenni (using … status='Available').
create or replace function public.interviewslots_force_owner()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_staff() or auth.uid() is null then
    return new;
  end if;
  new."studentId"   := public.my_student_id();
  new."studentName" := public.my_display_name();
  return new;
end
$$;

drop trigger if exists interviewslots_force_owner_trg on public."interviewSlots";
create trigger interviewslots_force_owner_trg
  before update on public."interviewSlots"
  for each row execute function public.interviewslots_force_owner();

-- ---------- 10.3 payments: a beszúrt sor mindig a hívó nevére szól ----------
-- Kiegészítő védelem a 10.1 mellé: a hallgatói fizetés-szimuláció
-- (app.jsx:294-297) beszúrhat sort, de nem választhat hozzá nevet.
-- Ha a fiókhoz nem tartozik students sor, a my_student_name() NULL, és a
-- rbac_payments_insert with check-je 42501-gyel elutasítja — ez a helyes
-- viselkedés (mérve: a nem linkelt hallgató beszúrása 42501-gyel bukik).
create or replace function public.payments_force_owner()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_finance() or auth.uid() is null then
    return new;
  end if;
  new."studentName" := public.my_student_name();
  return new;
end
$$;

drop trigger if exists payments_force_owner_trg on public."payments";
create trigger payments_force_owner_trg
  before insert on public."payments"
  for each row execute function public.payments_force_owner();

-- ---------- 10.4 auditLogs: a naplóbejegyzés szerzője nem hamisítható ----------
-- MÉRT TÁMADÁS: bármely jóváhagyott fiók — hallgató is — tetszőleges "user"
-- értékkel szúrhatott be naplósort, pl. „Admin Anna törölte X-et".
-- Egy csak-hozzáfűzhető napló, amibe bárki bármit hamisíthat, kevesebbet ér,
-- mint amennyi bizalmat kelt.
-- AZ ÜGYINTÉZŐT SZÁNDÉKOSAN KIHAGYJA: az app.jsx:301 a 'System (WhatsApp)'
-- értéket írja a mezőbe, és a WhatsApp-felületet ügyintéző használja — ha ezt
-- felülírnánk, a napló olvashatatlanná válna. Ha az ügyintézőt is
-- hitelesíteni akarod, ahhoz külön actor_email oszlop kell (ez a fájl
-- szándékosan nem ad hozzá oszlopot).
create or replace function public.auditlogs_force_actor()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_staff() or auth.uid() is null then
    return new;
  end if;
  new."user" := coalesce(public.my_email(), 'unknown');
  return new;
end
$$;

drop trigger if exists auditlogs_force_actor_trg on public."auditLogs";
create trigger auditlogs_force_actor_trg
  before insert on public."auditLogs"
  for each row execute function public.auditlogs_force_actor();

-- ============================================================
-- 11. SZAKASZ — ELLENŐRZŐ LEKÉRDEZÉSEK
-- ============================================================
-- Mind csak OLVAS. A Supabase SQL Editor az utolsó lekérdezés eredményét
-- mutatja, ezért érdemes őket egyesével kijelölve futtatni (Run selection).

-- ---------- 11.1 létrejött-e minden segédfüggvény? ----------
-- Elvárás: mind a 14 sor 'OK', security_definer = true, volatilitás = 's'.
select
  v.fn                                                   as fuggveny,
  case when p.oid is null then 'HIANYZIK' else 'OK' end  as allapot,
  p.prosecdef                                            as security_definer,
  p.provolatile                                          as volatilitas
from (values
  ('my_role'), ('my_email'), ('my_agency'), ('my_student_id'),
  ('my_student_name'), ('my_display_name'), ('has_role'), ('is_admin'),
  ('is_student'), ('is_agent'), ('is_admissions'), ('is_finance'),
  ('is_my_agency_student_email'), ('is_staff')
) as v(fn)
left join pg_proc p
       on p.proname = v.fn
      and p.pronamespace = 'public'::regnamespace
order by allapot desc, v.fn;

-- ---------- 11.2 fent van-e mind a négy integritás-trigger? ----------
-- Elvárás: 4 sor, mindegyik 'OK'.
select
  v.trg                                                   as trigger_nev,
  case when t.oid is null then 'HIANYZIK' else 'OK' end   as allapot,
  t.tgrelid::regclass                                     as tabla
from (values
  ('students_protect_identity_trg'), ('interviewslots_force_owner_trg'),
  ('payments_force_owner_trg'), ('auditlogs_force_actor_trg')
) as v(trg)
left join pg_trigger t on t.tgname = v.trg and not t.tgisinternal
order by allapot desc, v.trg;

-- ---------- 11.3 táblánként hány rbac_ policy készült? ----------
-- Elvárás: mind a 22 tábla szerepel, kimaradt = false, minden sorban
-- select_db >= 1 ÉS iras_db >= 1 — KIVÉVE az auditLogs-t, ahol
-- iras_db = 1 (csak INSERT), mert a tábla szándékosan append-only.
with t(tabla) as (
  values
    ('users'), ('students'), ('payments'), ('invoices'), ('campaigns'),
    ('auditLogs'), ('webhooks'), ('interviewSlots'), ('agencies'), ('leads'),
    ('marketingCampaigns'), ('scholarships'), ('integrations'),
    ('videoInterviewQuestions'), ('admission_processes'), ('process_messages'),
    ('feed_posts'), ('event_rsvps'), ('ticket_claims'), ('programs'),
    ('program_applications'), ('kb_documents')
)
select
  t.tabla,
  count(p.policyname)                                              as rbac_db,
  count(*) filter (where p.cmd = 'SELECT')                         as select_db,
  count(*) filter (where p.cmd in ('INSERT', 'UPDATE', 'DELETE'))  as iras_db,
  (count(p.policyname) = 0)                                        as kimaradt,
  string_agg(p.policyname, ', ' order by p.policyname)             as policy_nevek
from t
left join pg_policies p
       on p.schemaname = 'public'
      and p.tablename  = t.tabla
      and p.policyname like 'rbac\_%'
group by t.tabla
order by kimaradt desc, t.tabla;

-- ---------- 11.4 nem szivárog-e adat az anon szerepkörnek? ----------
-- Elvárás: NULLA sor. Ha bármelyik rbac_ policy az anon-nak (vagy a
-- `public` pszeudo-szerepkörnek) szól, az azonnali, bejelentkezés nélküli
-- olvasást jelent — pontosan ez volt az előző változat hibája a
-- programs / kb_documents táblán.
select tablename as tabla, policyname, cmd as parancs, roles as szerepkorok
from pg_policies
where schemaname = 'public'
  and policyname like 'rbac\_%'
  and (roles && array['anon', 'public']::name[])
order by tablename, policyname;

-- ---------- 11.5 érintetlen-e a másik alkalmazás és a profiles? ----------
-- Elvárás: a prefs / publications / publication_files / profiles /
-- wa_contacts / wa_messages táblán NULLA rbac_ policy.
select tablename as tabla, count(*) as rbac_policy
from pg_policies
where schemaname = 'public'
  and policyname like 'rbac\_%'
  and tablename in ('prefs', 'publications', 'publication_files',
                    'profiles', 'wa_contacts', 'wa_messages')
group by tablename
order by tablename;

-- ---------- 11.6 FIGYELMEZTETÉS: hol van MÉG mindig approved_all? ----------
-- A 11-es UTÁN ez normális: mind a 22 táblán ott kell lennie — pontosan ez
-- teszi kockázatmentessé a telepítést. A 12-es flip UTÁN viszont ennek a
-- lekérdezésnek NULLA sort kell adnia.
select
  tablename                                    as tabla,
  policyname,
  cmd                                          as parancs,
  'MEG NYITVA (a 12-es flip fogja eldobni)'    as megjegyzes
from pg_policies
where schemaname = 'public'
  and policyname = 'approved_all'
order by tablename;

-- ---------- 11.7 összefoglaló egy sorban ----------
-- Elvárt értékek az éles adatbázison a 11-es után:
--   rbac_policy_osszesen = 86, erintett_tablak = 22,
--   meg_nyitott_tablak = 22, integritas_trigger = 4,
--   anon_policy = 0, jovahagyott_fiok = 14, nem_jovahagyott_fiok = 0.
select
  (select count(*) from pg_policies
    where schemaname = 'public' and policyname like 'rbac\_%')      as rbac_policy_osszesen,
  (select count(distinct tablename) from pg_policies
    where schemaname = 'public' and policyname like 'rbac\_%')      as erintett_tablak,
  (select count(*) from pg_policies
    where schemaname = 'public' and policyname = 'approved_all')    as meg_nyitott_tablak,
  (select count(*) from pg_trigger
    where not tgisinternal and tgname in (
      'students_protect_identity_trg', 'interviewslots_force_owner_trg',
      'payments_force_owner_trg', 'auditlogs_force_actor_trg'))      as integritas_trigger,
  (select count(*) from pg_policies
    where schemaname = 'public' and policyname like 'rbac\_%'
      and roles && array['anon', 'public']::name[])                  as anon_policy,
  (select count(*) from public.profiles where approval_status = 'approved')  as jovahagyott_fiok,
  (select count(*) from public.profiles where approval_status <> 'approved') as nem_jovahagyott_fiok;

-- ---------- 11.8 a KÉT TÖRÖTT LÁNC mérése ----------
-- Ez a lekérdezés adja meg számokkal, hogy megéri-e most flippelni.
-- MÉRT ÉRTÉKEK az éles adatbázison (2026-08-18):
--   hallgatoi_profil = 9, ebbol_bekotott = 1
--   agency_sor = 0, agent_profil = 1, illeszkedo_hallgato = 0
select
  (select count(*) from public.profiles where role = 'STUDENT')               as hallgatoi_profil,
  (select count(*) from public.profiles p where p.role = 'STUDENT'
     and (nullif(p."studentId", '') is not null
          or exists (select 1 from public.students s
                     where lower(s.email) = lower(p.email))))                 as ebbol_bekotott,
  (select count(*) from public.agencies)                                      as agency_sor,
  (select count(*) from public.profiles where role = 'AGENT')                 as agent_profil,
  (select count(*) from public.students s
     where s."agentId" in (select nullif("agencyId", '') from public.profiles
                           where role = 'AGENT'))                             as illeszkedo_hallgato;


-- ============================================================
-- 12. SZAKASZ — SZEREPKÖR-SZIMULÁCIÓ (másold külön lapra)
-- ============================================================
-- Az alábbi minták KOMMENTBEN vannak. Mindegyik `begin` … `rollback` közé
-- van zárva: SEMMI nem marad meg belőlük, még az ideiglenesen eldobott
-- policy sem (a Postgresben a DDL is tranzakcionális — ez a trükk lelke).
--
-- MIÉRT KELL AZ IDEIGLENES DROP: amíg az "approved_all" él, minden
-- jóváhagyott fiók mindent lát, tehát a puszta szerepkör-szimuláció mindig
-- „engedélyezve" eredményt adna. A tranzakción belül eldobjuk, megnézzük,
-- mit engednének CSAK az rbac_ policy-k, majd visszagörgetünk.
--
-- Az uuid-ket a 11.7 alatti lekérdezésből, vagy ebből szedd:
--   select id, email, role, approval_status from public.profiles order by role;
--
-- ------------------------------------------------------------
-- MINTA A — mit LÁTNA egy STUDENT a students táblából?
--   Elvárás: 1 sor a bekötött fióknál, 0 a többi 8-nál.
-- ------------------------------------------------------------
-- begin;
--   drop policy if exists "approved_all" on public.students;
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<STUDENT-UUID>","role":"authenticated"}';
--   select id, name, email, program, status from public.students order by id;
-- rollback;
--
-- ------------------------------------------------------------
-- MINTA B — pénzügy: FINANCE mindent, ADMISSIONS mindent (csak olvasva),
--            STUDENT csak a sajátját.
-- ------------------------------------------------------------
-- begin;
--   drop policy if exists "approved_all" on public.payments;
--   drop policy if exists "approved_all" on public.invoices;
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<FINANCE-UUID>","role":"authenticated"}';
--   select 'FINANCE' as ki, count(*) as payments_lat from public.payments;
--   set local request.jwt.claims = '{"sub":"<ADMISSIONS-UUID>","role":"authenticated"}';
--   select 'ADMISSIONS' as ki, count(*) as payments_lat from public.payments;
--   set local request.jwt.claims = '{"sub":"<STUDENT-UUID>","role":"authenticated"}';
--   select 'STUDENT' as ki, count(*) as payments_lat from public.payments;
-- rollback;
--
-- ------------------------------------------------------------
-- MINTA C — a szerepkör-függvények mit mondanak egy fiókról?
--   Ehhez NEM kell policy-t dobni. Ha a my_student_name() NULL egy
--   jelentkezőnél, az a fiók a flip után 0 fizetést és 0 számlát lát.
-- ------------------------------------------------------------
-- begin;
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<UUID>","role":"authenticated"}';
--   select public.my_role() as szerepkor, public.my_email() as email,
--          public.my_agency() as agency_id, public.my_student_id() as student_id,
--          public.my_student_name() as student_nev, public.my_display_name() as megjelenitett_nev,
--          public.is_approved() as jovahagyott, public.is_staff() as ugyintezo,
--          public.is_admin() as admin, public.is_agent() as ugynok,
--          public.is_student() as jelentkezo;
-- rollback;
--
-- ------------------------------------------------------------
-- MINTA D — a névhamisítás tényleg be van zárva? (10.1 trigger próbája)
--   Elvárás: az UPDATE „1 sor"-t jelent, de a név NEM változik.
-- ------------------------------------------------------------
-- begin;
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<STUDENT-UUID>","role":"authenticated"}';
--   update public.students set name = 'Valaki Mas' where id = '<SAJAT-STUDENT-ID>';
-- rollback;
--   -- majd KÜLÖN utasításban, superuserként:
--   -- select id, name from public.students where id = '<SAJAT-STUDENT-ID>';
--   -- FONTOS: a visszaolvasás ugyanabban az utasításban régi pillanatképet
--   -- látna, ezért kell külön lépésben nézni.
--
-- ------------------------------------------------------------
-- MINTA E — az ügynöki lánc mérése (a fejléc (A) pontja)
--   Elvárás MA: 0. Ha az adatot rendezed, 5-nek kell lennie.
-- ------------------------------------------------------------
-- begin;
--   drop policy if exists "approved_all" on public.students;
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<AGENT-UUID>","role":"authenticated"}';
--   select count(*) as agent_altal_latott_hallgato from public.students;
-- rollback;
--
-- ------------------------------------------------------------
-- HA A SZIMULÁCIÓ NEM MŰKÖDIK
--   Egyes Supabase projekteken a `set local role authenticated`
--   jogosultsághoz kötött. Szerepkörváltás nélkül csak a FÜGGVÉNYEKET
--   (Minta C) tudod próbálni:
--     select set_config('request.jwt.claims',
--                       '{"sub":"<UUID>","role":"authenticated"}', true);
--   A policy-k valódi próbájához `set local role`, vagy valódi bejelentkezés
--   kell a felületről.


-- ============================================================
-- 13. SZAKASZ — A KÖVETKEZŐ LÉPÉSEK VÁZLATA (csak komment)
-- ============================================================
-- Ezek NEM itt futnak. Külön fájlba kerülnek, hogy a 11-es bármikor,
-- kockázat nélkül újrafuttatható maradjon.
--
-- ------------------------------------------------------------
-- (i) ADATJAVÍTÁS — ÜGYNÖKI LÁNC. Mérve: enélkül az AGENT 0 hallgatót lát,
--     ezzel 5-öt. DÖNTÉS KÉRDÉSE, ezért komment.
-- ------------------------------------------------------------
--   insert into public.agencies (id, name, "commissionRate", "contactPerson", email, status)
--   values ('AG1','Global Study',10,'-','agent@globalstudy.com','Active'),
--          ('AG2','Agency 2',10,'-','-','Active'),
--          ('AG3','Agency 3',10,'-','-','Active')
--   on conflict (id) do nothing;
--   update public.students set "agentId" = 'AG' || substring("agentId" from 2)
--    where "agentId" ~ '^A[0-9]+$';
--   -- és a frontend app.jsx:929-931 szűrőjét s.agencyId → s.agentId-re kell írni,
--   -- különben az Ügynök portál az adatjavítás után is üres marad.
--
-- ------------------------------------------------------------
-- (ii) ADATJAVÍTÁS — HALLGATÓI LÁNC. Mérve: 9 STUDENT profilból 1 kötött.
-- ------------------------------------------------------------
--   update public.profiles p set "studentId" = s.id
--     from public.students s
--    where lower(s.email) = lower(p.email)
--      and p.role = 'STUDENT' and nullif(p."studentId",'') is null;
--   -- a maradékhoz kézi párosítás kell (vagy fogadd el, hogy üres a portáljuk).
--
-- ------------------------------------------------------------
-- (iii) VÉGLEGES PÉNZÜGYI KAPOCS — a névegyezés kiváltása.
-- ------------------------------------------------------------
--   alter table public.payments add column if not exists "studentId" text;
--   alter table public.invoices add column if not exists "studentId" text;
--   update public.payments p set "studentId" = s.id from public.students s
--    where s.name = p."studentName";
--   update public.invoices i set "studentId" = s.id from public.students s
--    where s.name = i."studentName";
--   -- majd a rbac_payments_select/_insert és rbac_invoices_select feltételében
--   --   lower("studentName") = lower(public.my_student_name())
--   -- helyett:  "studentId" = public.my_student_id()
--
-- ------------------------------------------------------------
-- (iv) 12_rbac_flip.sql — VÁZLAT
-- ------------------------------------------------------------
--   do $$
--   declare t text;
--   begin
--     foreach t in array array[
--       'users', 'students', 'payments', 'invoices', 'campaigns', 'auditLogs',
--       'webhooks', 'interviewSlots', 'agencies', 'leads', 'marketingCampaigns',
--       'scholarships', 'integrations', 'videoInterviewQuestions',
--       'admission_processes', 'process_messages',
--       'feed_posts', 'event_rsvps', 'ticket_claims',
--       'programs', 'program_applications', 'kb_documents'
--     ]
--     loop
--       if to_regclass(format('public.%I', t)) is null then continue; end if;
--       -- BIZTONSÁGI FÉK: ne dobjuk el a régit, ha nincs mit a helyére tenni.
--       if not exists (select 1 from pg_policies
--                      where schemaname = 'public' and tablename = t
--                        and policyname like 'rbac\_%') then
--         raise exception 'A(z) % tablan nincs rbac_ policy — eloszor futtasd a 11-est!', t;
--       end if;
--       execute format('drop policy if exists "approved_all" on public.%I', t);
--     end loop;
--   end $$;
--   -- Ellenőrzés: a 11.6 lekérdezésnek NULLA sort kell adnia.
--
-- ------------------------------------------------------------
-- (v) 13_rbac_rollback.sql — VÁZLAT (vészvisszaállás)
-- ------------------------------------------------------------
--   -- A permisszív policy-k VAGY-olódnak, tehát az approved_all visszatétele
--   -- önmagában újra mindent megenged a jóváhagyottaknak; az rbac_ policy-ket
--   -- nem kell eldobni. A 10. szakasz triggereit sem — azok nem a
--   -- szerepkör-modellhez tartoznak, hanem valódi hibákat zárnak be.
--   do $$
--   declare t text;
--   begin
--     foreach t in array array[ /* ugyanaz a 22 tábla */ ]
--     loop
--       if to_regclass(format('public.%I', t)) is null then continue; end if;
--       execute format('drop policy if exists "approved_all" on public.%I', t);
--       execute format(
--         'create policy "approved_all" on public.%I for all to authenticated
--            using (public.is_approved()) with check (public.is_approved())', t);
--     end loop;
--   end $$;
--
-- ------------------------------------------------------------
-- AMIT EZ A MIGRÁCIÓ NEM ÉRINT
--   • public.profiles — a 07-es profiles_select/insert/update marad.
--     TUDNI KELL RÓLA (mérve): a profiles_select ma és a flip után is mind a
--     14 profilt megmutatja, e-mail-lel együtt, MINDEN jóváhagyott fióknak —
--     a hallgatónak és az ügynöknek is. Ez a legnagyobb megmaradó
--     adatvédelmi felület. Szűkítése (id = auth.uid() or is_staff()) külön
--     migráció, mert a táblát a MÁSIK alkalmazás is használja.
--     Ugyanitt: a profiles_update using ága `id = auth.uid() or
--     is_superadmin()` — tehát az ADMIN egyetlen más profilt sem tud
--     jóváhagyni vagy szerkeszteni (mérve: 0 sor). Ha van admin
--     jóváhagyó képernyő, az ma is csak SUPERADMIN-nal működik.
--   • storage.objects (08-as documents bucket) és a wa_* táblák (10-es) —
--     ezek már ma is is_staff()/saját-mappa alapon védettek (mérve:
--     ügyintéző 2/2 sor, ügynök és hallgató 0/0).
--   • prefs / publications / publication_files — a MÁSIK alkalmazás táblái.
--     Egyetlen táblalistában sem szerepelnek.
--   • A service role kulcs (Edge Function) az RLS-t megkerüli, tehát a
--     WhatsApp-integráció működését egyik lépés sem befolyásolja.
--
-- ============================================================
-- VÉGE — 11_rbac_additive.sql
-- ============================================================
