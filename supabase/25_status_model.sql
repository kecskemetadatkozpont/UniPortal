-- ============================================================================
-- 25_status_model.sql — A felvételi státuszmodell: katalógus + állapotgép
-- ============================================================================
--
-- FÁJLNÉV: a munkacsomag eredetileg 23_status_model.sql-t kért, de a 23-as és
-- a 24-es sorszámot időközben az ECHO-ág foglalta el (23_echo_form_rules.sql,
-- 24_echo_form_v3.sql). Két azonos sorszámú migráció a betöltési sorrendet
-- tenné kiszámíthatatlanná, ezért ez a fájl a 25-ös. Tartalmilag változatlan.
--
-- ---------------------------------------------------------------------------
-- MIÉRT
-- ---------------------------------------------------------------------------
-- A students."status" ma szabad szöveg: bármit bele lehet írni, és bárhonnan
-- bárhová át lehet ugrani. MÉRVE a 'fresh' replikán a migráció ELŐTT:
--
--     Accepted 3 | Draft 1 | Missing Info 2 | Paid 3 | Submitted 2   (11 sor)
--
-- Ez a hét érték (a 'Rejected' és a 'Failed' az app.jsx-ben él, az adatban
-- nem) három különböző dolgot kever össze egyetlen mezőben: a jelentkezés
-- előrehaladását, a dokumentumok hiányát és a pénzügyi teljesítést.
--
-- ---------------------------------------------------------------------------
-- A FŐ LÁNC (C1 · D1 döntés)
-- ---------------------------------------------------------------------------
--     Draft → Submitted → Documents checked → Nominated
--                                              ├─→ Failed                (vég)
--                                              └─→ Conditionally accepted
--                                                        ├─→ Accepted    (vég)
--                                                        └─→ Failed      (vég)
--
-- A 'Failed' VÉGÁLLAPOT, nem láncszem: a bírálat utáni elágazás egyik ága.
-- Kilépni belőle csak explicit újranyitással lehet (Failed → Nominated),
-- amit a lenti tábla is_backward = true sorként tart nyilván.
--
-- ---------------------------------------------------------------------------
-- A BEIRATKOZÁS UTÁNI HÁROM SÁV (C2 · D2 döntés)
-- ---------------------------------------------------------------------------
-- A beiratkozás után NEM folytatódik a lánc. A fő státusz 'Accepted' marad,
-- és mellé három EGYMÁSTÓL FÜGGETLEN mező kerül:
--
--     visa_state     : null | waiting | accepted | rejected
--     deferral_state : null | requested | letter_sent
--     refund_state   : null | requested | bank_details_needed
--                           | bank_details_provided | forwarded_to_finance
--                           | processed
--
-- INDOK: egy hallgató kérhet halasztást ÉS várhat visszatérítést egyszerre,
-- miközben a vízuma is elbírálás alatt van. Egyetlen státuszmezőben ez a
-- három párhuzamos tény ábrázolhatatlan lenne — vagy elveszne belőle kettő,
-- vagy kombinatorikus státuszrobbanás lenne (3 × 2 × 5 = 30 érték).
--
-- ---------------------------------------------------------------------------
-- A MEGLÉVŐ ÉRTÉKEK ÁTVEZETÉSE — ÉS AZ INDOKA
-- ---------------------------------------------------------------------------
--  'Missing Info' → 'Submitted'
--      A hiányzó dokumentum nem a jelentkezés állapota, hanem a
--      dokumentumoké: a students."visaChecklist" és az admission_processes
--      .data.docs tartja nyilván darabonként. Aki hiánypótlásra vár, az
--      pontosan ugyanott áll, mint bárki más beadás után: a
--      dokumentum-ellenőrzés még nem zárult le. Ezért 'Submitted'.
--
--  'Paid' → 'Accepted'
--      A fizetés pénzügyi tény, nem felvételi döntés — a payments/invoices
--      táblák tartják nyilván, és a C2 sávok mellé illeszkedik. A régi kód
--      (app.jsx api.processPayment / verifyPayment) a fizetéskor a
--      students.status-t 'Paid'-re írta, ami FELÜLÍRTA a felvételi döntést:
--      egy 'Nominated' jelentkezőből a díj beérkezésétől 'Paid' lett, és a
--      bírálati állapot NYOMTALANUL ELVESZETT. Aki fizetett, azt korábban
--      felvették, tehát 'Accepted'.
--
--  'Rejected' → 'Failed'
--      A D1 döntés szerint az elutasítás egyetlen neve 'Failed'. A 'Rejected'
--      az adatban ma 0 sor (mérve), az app.jsx-ben viszont előfordult; a
--      leképezés így a jövőbeni beszivárgás ellen is véd.
--
-- VISSZAFORDÍTHATÓSÁG: a students kap egy "status_legacy" oszlopot, amibe a
-- migráció EGYSZER beírja az eredeti értéket (csak ha még NULL). A visszaút:
--     update public.students set status = status_legacy
--       where status_legacy is not null;      -- előbb a triggert kikapcsolva
-- A fájl végén szereplő public.status_model_rollback() ezt meg is teszi.
--
-- ---------------------------------------------------------------------------
-- JOGOSULTSÁG
-- ---------------------------------------------------------------------------
-- Épít a 11_rbac_additive.sql students_protect_identity triggerére: az NEM
-- ügyintézőnek már ma visszaírja a status és a tuitionFee régi értékét, tehát
-- a jelentkező a fő láncot nem tudja mozgatni. A triggerek nevei úgy vannak
-- megválasztva, hogy a PostgreSQL ábécésorrendje a helyes sorrendet adja:
--     students_protect_identity_trg  (11) → a status visszaáll nem-ügyintézőnél
--     students_protect_tracks_trg    (25) → a három sáv visszaáll ugyanígy
--     students_status_guard_trg      (25) → a fő lánc átmenetellenőrzése
--     students_track_guard_trg       (25) → a három sáv átmenetellenőrzése
--
-- IDEMPOTENS: kétszer lefuttatva ugyanaz az eredmény (mérve, ON_ERROR_STOP=1).
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. A triggerek eldobása a fájl elején
-- ---------------------------------------------------------------------------
-- Az adatátvezetés (3. szakasz) maga is UPDATE a students táblán, és a régi
-- értékekből ('Paid', 'Missing Info') nem vezet megengedett átmenet. A guard
-- triggereket ezért az átvezetés ELŐTT dobjuk el, és csak utána hozzuk létre.
-- Újrafuttatáskor ugyanez történik, az átvezetés viszont már 0 sort érint.
drop trigger if exists students_status_guard_trg   on public."students";
drop trigger if exists students_track_guard_trg    on public."students";
drop trigger if exists students_protect_tracks_trg on public."students";
drop trigger if exists students_status_insert_trg  on public."students";

-- ---------------------------------------------------------------------------
-- 1. A megengedett státuszok KATALÓGUSA
-- ---------------------------------------------------------------------------
-- Tábla és nem CHECK constraint: új állapotot (pl. 'Withdrawn') egy INSERT-tel
-- fel lehet venni, migráció és táblaátírás nélkül. A felület ugyanebből a
-- sorrendből és címkékből dolgozik (app.jsx STUDENT_STATUSES).
create table if not exists public.student_status (
  code        text primary key,
  label_hu    text    not null,
  label_en    text    not null,
  sort_order  integer not null,
  is_terminal boolean not null default false,  -- nincs előrefelé átmenet
  tone        text    not null default 'slate', -- felületi színkulcs
  note        text
);

insert into public.student_status (code, label_hu, label_en, sort_order, is_terminal, tone, note) values
  ('Draft',                  'Piszkozat',                  'Draft',                  1, false, 'slate',   'A jelentkező elkezdte, de még nem adta be.'),
  ('Submitted',              'Beadva',                     'Submitted',              2, false, 'indigo',  'Dokumentum-ellenőrzésre vár — ez a napi munka bemenete.'),
  ('Documents checked',      'Dokumentumok ellenőrizve',   'Documents checked',      3, false, 'sky',     'A dokumentumok rendben, mehet a bírálatra.'),
  ('Nominated',              'Bírálatra jelölve',          'Nominated',              4, false, 'violet',  'A bírálat előtt/alatt. Innen ágazik el a döntés.'),
  ('Conditionally accepted', 'Feltételesen felvéve',       'Conditionally accepted', 5, false, 'amber',   'Feltételes felvételi levél kiállítva.'),
  ('Accepted',               'Felvéve',                    'Accepted',               6, true,  'emerald', 'Végleges felvétel. A beiratkozás utáni sávok innen indulnak.'),
  ('Failed',                 'Elutasítva',                 'Failed',                 7, true,  'red',     'VÉGÁLLAPOT (D1). Csak explicit újranyitással hagyható el.')
on conflict (code) do update set
  label_hu    = excluded.label_hu,
  label_en    = excluded.label_en,
  sort_order  = excluded.sort_order,
  is_terminal = excluded.is_terminal,
  tone        = excluded.tone,
  note        = excluded.note;

-- ---------------------------------------------------------------------------
-- 2. A megengedett ÁTMENETEK
-- ---------------------------------------------------------------------------
-- is_backward = true: hibajavító visszalépés. Megengedett, de CSAK
-- ügyintézőnek, és minden ilyen lépés bekerül az "auditLogs"-ba.
create table if not exists public.student_status_transition (
  from_code   text    not null references public.student_status(code) on update cascade on delete cascade,
  to_code     text    not null references public.student_status(code) on update cascade on delete cascade,
  is_backward boolean not null default false,
  note        text,
  primary key (from_code, to_code)
);

insert into public.student_status_transition (from_code, to_code, is_backward, note) values
  -- előre
  ('Draft',                  'Submitted',              false, 'A jelentkező beadja.'),
  ('Submitted',              'Documents checked',      false, 'Az ügyintéző lezárja a dokumentum-ellenőrzést.'),
  ('Documents checked',      'Nominated',              false, 'Bírálatra jelölés.'),
  ('Nominated',              'Conditionally accepted', false, 'A bírálat pozitív ága (D1).'),
  ('Nominated',              'Failed',                 false, 'A bírálat elutasító ága (D1) — végállapot.'),
  ('Conditionally accepted', 'Accepted',               false, 'A feltétel teljesült, végleges felvétel.'),
  ('Conditionally accepted', 'Failed',                 false, 'A feltétel nem teljesült — végállapot.'),
  -- vissza (hibajavítás, ügyintézőnek, naplózva)
  ('Submitted',              'Draft',                  true,  'Tévesen beadottnak jelölt jelentkezés visszanyitása.'),
  ('Documents checked',      'Submitted',              true,  'Az ellenőrzés újranyitása (utólag kiderült hiány).'),
  ('Nominated',              'Documents checked',      true,  'A jelölés visszavonása.'),
  ('Conditionally accepted', 'Nominated',              true,  'A feltételes döntés visszavonása.'),
  ('Accepted',               'Conditionally accepted', true,  'A végleges felvétel visszavonása.'),
  ('Failed',                 'Nominated',              true,  'A D1 szerinti EXPLICIT ÚJRANYITÁS — csak így hagyható el a Failed.')
on conflict (from_code, to_code) do update set
  is_backward = excluded.is_backward,
  note        = excluded.note;

-- ---------------------------------------------------------------------------
-- 3. Az oszlopok és a MEGLÉVŐ ÉRTÉKEK ÁTVEZETÉSE
-- ---------------------------------------------------------------------------
alter table public."students" add column if not exists "status_legacy"  text;
alter table public."students" add column if not exists "visa_state"     text;
alter table public."students" add column if not exists "deferral_state" text;
alter table public."students" add column if not exists "refund_state"   text;

comment on column public."students"."status_legacy" is
  'A 25_status_model.sql előtti eredeti status érték. Csak egyszer íródik (ha NULL). A visszaút: public.status_model_rollback().';

-- Az eredeti érték mentése — kizárólag azoknál, ahol még nincs mentés.
-- Újrafuttatáskor ez 0 sort érint, tehát a mentés nem íródik felül a
-- már átvezetett értékkel.
update public."students"
   set "status_legacy" = "status"
 where "status_legacy" is null;

-- A leképezés. Az indoklás a fájl fejlécében.
update public."students" set "status" = 'Submitted' where "status" = 'Missing Info';
update public."students" set "status" = 'Accepted'  where "status" = 'Paid';
update public."students" set "status" = 'Failed'    where "status" = 'Rejected';

-- Bármi más ismeretlen érték (elgépelés, régi kísérlet) 'Draft'-ra esik, hogy
-- a katalógus zárt maradjon. A status_legacy megőrzi az eredetit.
update public."students" s
   set "status" = 'Draft'
 where "status" is null
    or not exists (select 1 from public.student_status c where c.code = s."status");

-- ---------------------------------------------------------------------------
-- 4. A HÁROM SÁV katalógusa és átmenetei (C2 · D2)
-- ---------------------------------------------------------------------------
-- Egy közös táblapár, 'track' oszloppal kulcsolva — a három sáv szerkezete
-- azonos (lineáris lánc), csak a hossza más. A "nincs sáv" (NULL) állapotot a
-- táblákban az üres sztring képviseli, mert a NULL nem lehet elsődleges kulcs
-- része; a triggerek coalesce(...,'')-lel normalizálnak.
create table if not exists public.student_track_state (
  track       text    not null,
  code        text    not null,
  label_hu    text    not null,
  label_en    text    not null,
  sort_order  integer not null,
  is_terminal boolean not null default false,
  tone        text    not null default 'slate',
  primary key (track, code)
);

create table if not exists public.student_track_transition (
  track       text    not null,
  from_code   text    not null default '',   -- '' = a sáv még nem indult (NULL)
  to_code     text    not null,              -- '' = a sáv törlése
  is_backward boolean not null default false,
  note        text,
  primary key (track, from_code, to_code)
);

insert into public.student_track_state (track, code, label_hu, label_en, sort_order, is_terminal, tone) values
  -- vízum
  ('visa',     'waiting',               'Vízumra vár',            'Waiting for visa',      1, false, 'amber'),
  ('visa',     'accepted',              'Vízum megadva',          'Visa accepted',         2, true,  'emerald'),
  ('visa',     'rejected',              'Vízum elutasítva',       'Visa rejected',         3, true,  'red'),
  -- halasztás
  ('deferral', 'requested',             'Halasztást kért',        'Deferral requested',    1, false, 'amber'),
  ('deferral', 'letter_sent',           'Halasztási levél kiküldve','Deferral letter sent',2, true,  'emerald'),
  -- visszatérítés
  ('refund',   'requested',             'Visszatérítést kért',    'Refund requested',      1, false, 'amber'),
  ('refund',   'bank_details_needed',   'Bankadat bekérve',       'Bank details requested',2, false, 'amber'),
  ('refund',   'bank_details_provided', 'Bankadat megadva',       'Bank details provided', 3, false, 'sky'),
  ('refund',   'forwarded_to_finance',  'Pénzügyre továbbítva',   'Forwarded to finance',  4, false, 'violet'),
  ('refund',   'processed',             'Kifizetve',              'Refund processed',      5, true,  'emerald')
on conflict (track, code) do update set
  label_hu    = excluded.label_hu,
  label_en    = excluded.label_en,
  sort_order  = excluded.sort_order,
  is_terminal = excluded.is_terminal,
  tone        = excluded.tone;

insert into public.student_track_transition (track, from_code, to_code, is_backward, note) values
  -- vízum
  ('visa',     '',                      'waiting',               false, 'A sáv indítása: beadott vízumkérelem.'),
  ('visa',     'waiting',               'accepted',              false, null),
  ('visa',     'waiting',               'rejected',              false, null),
  ('visa',     'accepted',              'waiting',               true,  'Tévesen rögzített döntés visszavonása.'),
  ('visa',     'rejected',              'waiting',               true,  'Fellebbezés / új kérelem.'),
  ('visa',     'waiting',               '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('visa',     'accepted',              '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('visa',     'rejected',              '',                      true,  'A sáv törlése (tévesen nyitva).'),
  -- halasztás
  ('deferral', '',                      'requested',             false, 'A sáv indítása: halasztási kérelem érkezett.'),
  ('deferral', 'requested',             'letter_sent',           false, null),
  ('deferral', 'letter_sent',           'requested',             true,  'A levél visszavonása.'),
  ('deferral', 'requested',             '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('deferral', 'letter_sent',           '',                      true,  'A sáv törlése (tévesen nyitva).'),
  -- visszatérítés
  ('refund',   '',                      'requested',             false, 'A sáv indítása: visszatérítési kérelem.'),
  ('refund',   'requested',             'bank_details_needed',   false, null),
  ('refund',   'bank_details_needed',   'bank_details_provided', false, 'EZT a lépést a jelentkező is megteheti.'),
  ('refund',   'bank_details_provided', 'forwarded_to_finance',  false, null),
  ('refund',   'forwarded_to_finance',  'processed',             false, null),
  ('refund',   'bank_details_needed',   'requested',             true,  null),
  ('refund',   'bank_details_provided', 'bank_details_needed',   true,  'Hibás bankadat — újra bekérve.'),
  ('refund',   'forwarded_to_finance',  'bank_details_provided', true,  null),
  ('refund',   'processed',             'forwarded_to_finance',  true,  'Téves kifizetés visszavonása.'),
  ('refund',   'requested',             '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('refund',   'bank_details_needed',   '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('refund',   'bank_details_provided', '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('refund',   'forwarded_to_finance',  '',                      true,  'A sáv törlése (tévesen nyitva).'),
  ('refund',   'processed',             '',                      true,  'A sáv törlése (tévesen nyitva).')
on conflict (track, from_code, to_code) do update set
  is_backward = excluded.is_backward,
  note        = excluded.note;

-- ---------------------------------------------------------------------------
-- 5. Naplózó segédfüggvény
-- ---------------------------------------------------------------------------
-- Az "auditLogs" sémája a 01_schema_and_seed.sql-ből: id/timestamp/user/
-- action/target/changes, mind text. A seed 'LOG-2' sora pontosan ilyen
-- státuszváltást rögzít ('Submitted -> Accepted'), tehát a formátum adott.
create or replace function public.log_status_event(
  p_action  text,
  p_target  text,
  p_changes text
) returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public."auditLogs" ("id", "timestamp", "user", "action", "target", "changes")
  values (
    'LOG-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12),
    to_char(now(), 'YYYY.MM.DD HH24:MI'),
    coalesce(nullif(public.my_email(), ''), 'system (SQL)'),
    p_action,
    p_target,
    p_changes
  );
exception when others then
  -- A naplózás soha ne buktassa el a felvételi műveletet.
  null;
end
$$;

-- ---------------------------------------------------------------------------
-- 6. A FŐ LÁNC állapotgépe
-- ---------------------------------------------------------------------------
create or replace function public.students_status_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_from     text := coalesce(old."status", 'Draft');
  v_backward boolean;
  v_found    boolean := false;
  v_allowed  text;
begin
  if new."status" is not distinct from old."status" then
    return new;
  end if;

  -- 6.1 a célállapot benne van-e a katalógusban
  if new."status" is null
     or not exists (select 1 from public.student_status c where c.code = new."status") then
    raise exception
      'Ismeretlen felvételi státusz: "%". A megengedett értékek: %.',
      coalesce(new."status", '<NULL>'),
      (select string_agg(code, ', ' order by sort_order) from public.student_status)
      using errcode = '23514',
            hint    = 'A státuszok katalógusa: public.student_status.';
  end if;

  -- 6.2 megengedett-e az átmenet
  select true, t.is_backward
    into v_found, v_backward
    from public.student_status_transition t
   where t.from_code = v_from and t.to_code = new."status";

  if not coalesce(v_found, false) then
    select coalesce(string_agg(c.label_en || ' (' || c.code || ')', ', ' order by c.sort_order), '')
      into v_allowed
      from public.student_status_transition t
      join public.student_status c on c.code = t.to_code
     where t.from_code = v_from;

    raise exception
      'Tiltott státuszátmenet: "%" → "%". A(z) "%" állapotból ezek engedettek: %',
      v_from, new."status", v_from,
      case when v_allowed = '' or v_allowed is null
           then 'egy sem — ez végállapot, csak explicit újranyitással hagyható el.'
           else v_allowed end
      using errcode = '23514',
            hint    = 'A megengedett átmenetek: public.student_status_transition.';
  end if;

  -- 6.3 visszalépés: csak ügyintéző, és mindig naplózva
  if v_backward then
    if auth.uid() is not null and not public.is_staff() then
      raise exception
        'A visszalépés ("%" → "%") csak ügyintézői jogosultsággal végezhető.',
        v_from, new."status"
        using errcode = '42501';
    end if;
    perform public.log_status_event(
      'STUDENT_STATUS_ROLLBACK',
      coalesce(new."name", new."id"),
      v_from || ' -> ' || new."status" || ' (visszalépés / hibajavítás)'
    );
  else
    perform public.log_status_event(
      'STUDENT_STATUS_CHANGE',
      coalesce(new."name", new."id"),
      v_from || ' -> ' || new."status"
    );
  end if;

  return new;
end
$$;

-- Az INSERT is a katalógusra korlátozódik. Az app.jsx api.addStudent status
-- nélkül szúr be (app.jsx:283) — az ilyen sor 'Draft'-ként indul.
create or replace function public.students_status_insert_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new."status" is null or new."status" = '' then
    new."status" := 'Draft';
  end if;
  if not exists (select 1 from public.student_status c where c.code = new."status") then
    raise exception
      'Ismeretlen felvételi státusz új jelentkezőnél: "%". A megengedett értékek: %.',
      new."status",
      (select string_agg(code, ', ' order by sort_order) from public.student_status)
      using errcode = '23514';
  end if;
  -- Új jelentkezés csak a lánc elejéről indulhat.
  if new."status" not in ('Draft', 'Submitted') then
    raise exception
      'Új jelentkező csak "Draft" vagy "Submitted" állapotban hozható létre, nem "%"-ként.',
      new."status"
      using errcode = '23514';
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- 7. A HÁROM SÁV állapotgépe
-- ---------------------------------------------------------------------------
create or replace function public.check_track_transition(
  p_track  text,
  p_old    text,
  p_new    text,
  p_name   text
) returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_from    text := coalesce(p_old, '');
  v_to      text := coalesce(p_new, '');
  v_back    boolean;
  v_found   boolean := false;
  v_allowed text;
begin
  if v_from = v_to then
    return false;
  end if;

  if v_to <> '' and not exists (
       select 1 from public.student_track_state s where s.track = p_track and s.code = v_to) then
    raise exception
      'Ismeretlen "%" sáv-állapot: "%". A megengedett értékek: %.',
      p_track, v_to,
      (select string_agg(code, ', ' order by sort_order)
         from public.student_track_state where track = p_track)
      using errcode = '23514';
  end if;

  select true, t.is_backward
    into v_found, v_back
    from public.student_track_transition t
   where t.track = p_track and t.from_code = v_from and t.to_code = v_to;

  if not coalesce(v_found, false) then
    select coalesce(string_agg(case when t.to_code = '' then '(sáv törlése)' else t.to_code end,
                               ', ' order by t.to_code), '')
      into v_allowed
      from public.student_track_transition t
     where t.track = p_track and t.from_code = v_from;

    raise exception
      'Tiltott átmenet a "%" sávban: "%" → "%". Innen ezek engedettek: %',
      p_track,
      case when v_from = '' then '(nincs sáv)' else v_from end,
      case when v_to = ''   then '(sáv törlése)' else v_to end,
      case when v_allowed = '' or v_allowed is null then 'egy sem.' else v_allowed end
      using errcode = '23514',
            hint    = 'A sávok átmenetei: public.student_track_transition.';
  end if;

  perform public.log_status_event(
    case when v_back then 'STUDENT_TRACK_ROLLBACK' else 'STUDENT_TRACK_CHANGE' end,
    coalesce(p_name, '?'),
    p_track || ': ' ||
      case when v_from = '' then '(nincs)' else v_from end || ' -> ' ||
      case when v_to   = '' then '(nincs)' else v_to   end
  );
  return v_back;
end
$$;

create or replace function public.students_track_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_name text := coalesce(new."name", new."id");
begin
  -- D2: a vízum- és a halasztási sáv a beiratkozás utáni szakasz, tehát csak
  -- 'Accepted' fő státusz mellett nyitható. A visszatérítés ettől független
  -- (elutasított jelentkező is kérheti vissza a jelentkezési díjat).
  if coalesce(new."visa_state", '') <> coalesce(old."visa_state", '')
     and coalesce(new."visa_state", '') <> ''
     and new."status" <> 'Accepted' then
    raise exception
      'A vízum-sáv csak "Accepted" fő státusz mellett használható (a jelenlegi: "%").',
      new."status" using errcode = '23514';
  end if;
  if coalesce(new."deferral_state", '') <> coalesce(old."deferral_state", '')
     and coalesce(new."deferral_state", '') <> ''
     and new."status" <> 'Accepted' then
    raise exception
      'A halasztási sáv csak "Accepted" fő státusz mellett használható (a jelenlegi: "%").',
      new."status" using errcode = '23514';
  end if;

  perform public.check_track_transition('visa',     old."visa_state",     new."visa_state",     v_name);
  perform public.check_track_transition('deferral', old."deferral_state", new."deferral_state", v_name);
  perform public.check_track_transition('refund',   old."refund_state",   new."refund_state",   v_name);

  -- Az üres sztringet NULL-ra normalizáljuk: a felület "nincs sáv"-ként
  -- mindkettőt küldheti, az adatban viszont egyféle "nincs" legyen.
  if new."visa_state"     = '' then new."visa_state"     := null; end if;
  if new."deferral_state" = '' then new."deferral_state" := null; end if;
  if new."refund_state"   = '' then new."refund_state"   := null; end if;
  return new;
end
$$;

-- A három sáv ügyintézői döntés — a jelentkező nem írhatja. Egy kivétel: a
-- saját bankszámlaszámát ő adja meg, tehát a
-- bank_details_needed → bank_details_provided lépést megteheti.
-- Ugyanaz a minta, mint a 11-es students_protect_identity: nem hibát dobunk,
-- hanem visszaírjuk a régi értéket (a PATCH "1 sor"-t jelent vissza, de nem
-- változtat semmit).
create or replace function public.students_protect_tracks()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_staff() or auth.uid() is null then
    return new;
  end if;
  new."status_legacy"  := old."status_legacy";
  new."visa_state"     := old."visa_state";
  new."deferral_state" := old."deferral_state";
  if not (coalesce(old."refund_state", '') = 'bank_details_needed'
          and coalesce(new."refund_state", '') = 'bank_details_provided') then
    new."refund_state" := old."refund_state";
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- 8. A triggerek felkötése
-- ---------------------------------------------------------------------------
-- A nevek ábécésorrendje adja a helyes végrehajtási sorrendet, lásd a fejléc
-- "JOGOSULTSÁG" szakaszát.
create trigger students_protect_tracks_trg
  before update on public."students"
  for each row execute function public.students_protect_tracks();

create trigger students_status_guard_trg
  before update on public."students"
  for each row execute function public.students_status_guard();

create trigger students_track_guard_trg
  before update on public."students"
  for each row execute function public.students_track_guard();

create trigger students_status_insert_trg
  before insert on public."students"
  for each row execute function public.students_status_insert_guard();

-- ---------------------------------------------------------------------------
-- 9. RLS a katalógustáblákon
-- ---------------------------------------------------------------------------
-- A katalógus nyilvános olvasmány (a felület legördülői ebből épülnek), írni
-- viszont csak adminisztrátor tud. A 11-es is_admin() a SUPERADMIN/ADMIN.
alter table public.student_status             enable row level security;
alter table public.student_status_transition  enable row level security;
alter table public.student_track_state        enable row level security;
alter table public.student_track_transition   enable row level security;

do $$
declare t text;
begin
  foreach t in array array['student_status', 'student_status_transition',
                           'student_track_state', 'student_track_transition']
  loop
    execute format('drop policy if exists %I on public.%I', t || '_read',  t);
    execute format('drop policy if exists %I on public.%I', t || '_write', t);
    execute format(
      'create policy %I on public.%I for select to anon, authenticated using (true)',
      t || '_read', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())',
      t || '_write', t);
    execute format('grant select on public.%I to anon, authenticated', t);
  end loop;
end
$$;

grant execute on function public.log_status_event(text, text, text)                 to authenticated;
grant execute on function public.check_track_transition(text, text, text, text)     to authenticated;

-- ---------------------------------------------------------------------------
-- 10. VISSZAÚT
-- ---------------------------------------------------------------------------
-- A leképezés visszafordítása: kikapcsolja a guard-ot, visszaírja a mentett
-- értékeket, majd visszakapcsol. A sáv-oszlopokat MEGHAGYJA (adatvesztés
-- nélkül), csak a fő láncot állítja vissza a migráció előtti állapotra.
create or replace function public.status_model_rollback()
returns integer language plpgsql security definer set search_path = public as $$
declare v_rows integer;
begin
  alter table public."students" disable trigger students_status_guard_trg;
  update public."students"
     set "status" = "status_legacy"
   where "status_legacy" is not null
     and "status" is distinct from "status_legacy";
  get diagnostics v_rows = row_count;
  alter table public."students" enable trigger students_status_guard_trg;
  perform public.log_status_event('STATUS_MODEL_ROLLBACK', 'students',
                                  v_rows || ' sor visszaállítva a status_legacy oszlopból');
  return v_rows;
end
$$;

revoke all on function public.status_model_rollback() from public, anon, authenticated;

commit;
