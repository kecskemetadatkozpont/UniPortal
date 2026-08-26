# -*- coding: utf-8 -*-
"""
Teszt-adatbázis az álnevesített Neptun-kivonatból.

MIÉRT NEM AZ EGÉSZ ADAT MEGY BE
  A teljes kivonat 4510 hallgató és 53 775 felvétel. Ez SQL-ként 10–15 MB —
  a Supabase SQL Editor ezt nem bírja el, és manuális teszteléshez
  használhatatlan is: nem lehet benne megtalálni az érdekes eseteket.

  Helyette CÉLZOTT MINTA készül, ami a k-küszöbök mind a négy sávját lefedi:
    3–4 fő   -> a teljes riport rejtve (k_numeric = 5)
    5–9 fő   -> a számok látszanak, a szövegek nem (k_text = 10)
    10–29 fő -> minden látszik
    30+ fő   -> nagyobb elemszám

  A DEMO_HALLGATO darab kiemelt hallgató MINDEN kurzusa bekerül, hogy az ő
  felületük valósághűen tele legyen.
"""
import random, json, unicodedata
import pandas as pd

MAG = 20260825
FORRAS = '/Users/lorant/Downloads/li_teszt_alnevesitett.xlsx'
KI_SQL = '/Users/lorant/Downloads/teszt_adatbazis.sql'
KI_XLS = '/Users/lorant/Downloads/teszt_belepesi_adatok.xlsx'

JELSZO = 'Teszt1234!'
EMAIL_VEG = '@teszt.hu'

# Hány kurzus sávonként
SAVOK = [(3, 4, 4), (5, 9, 6), (10, 29, 8), (30, 999, 2)]
DEMO_HALLGATO = 12          # nekik MINDEN kurzusuk bekerül
MAX_HALLGATO = 400          # biztonsági felső korlát

NK, KK = 'Hallgató Neptun kód', 'Kurzuskód'
NEV, OKT = 'Hallgató Nyomtatási név', 'Kurzus oktatók'
TNEV, TKOD = 'Tárgynév', 'Tárgykód'
MNEV, MKOD = 'Modul neve', 'Modulkód'


def valaszt(df, rnd):
    """A minta kiválasztása: sávonként kurzusok, majd a kiemelt hallgatók."""
    meret = df.groupby(KK)[NK].nunique()
    tobb_oktato = set(df.groupby(KK)[OKT].first()
                        .pipe(lambda s: s[s.str.contains(',', na=False)]).index)

    kurzusok = []
    for lo, hi, db in SAVOK:
        jelolt = [k for k in meret[(meret >= lo) & (meret <= hi)].index]
        rnd.shuffle(jelolt)
        # a több oktatós kurzusok előre — azokat külön tesztelni kell
        jelolt.sort(key=lambda k: k not in tobb_oktato)
        kurzusok += jelolt[:db]

    reszhalmaz = df[df[KK].isin(kurzusok)]
    hallgatok = list(reszhalmaz[NK].unique())

    # Kiemelt hallgatók: nekik minden kurzusuk bekerül
    rnd.shuffle(hallgatok)
    demo = hallgatok[:DEMO_HALLGATO]
    plusz = df[df[NK].isin(demo)]
    kurzusok = sorted(set(kurzusok) | set(plusz[KK].unique()))

    ki = df[df[KK].isin(kurzusok)]
    if ki[NK].nunique() > MAX_HALLGATO:
        tart = set(demo) | set(ki[NK].value_counts().head(MAX_HALLGATO).index)
        ki = ki[ki[NK].isin(tart)]
    return ki.copy(), set(demo)


def q(v):
    """SQL-szövegliterál."""
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return 'null'
    return "'" + str(v).replace("'", "''") + "'"


def uuid5(rnd):
    h = '0123456789abcdef'
    s = ''.join(rnd.choice(h) for _ in range(32))
    return f'{s[:8]}-{s[8:12]}-{s[12:16]}-{s[16:20]}-{s[20:]}'


def email_slug(s):
    """Ékezet nélküli, kisbetűs, pontokkal tagolt e-mail-részlet."""
    t = unicodedata.normalize('NFKD', str(s))
    t = ''.join(c for c in t if not unicodedata.combining(c))
    t = ''.join(c if c.isalnum() else ' ' for c in t).split()
    return '.'.join(w.lower() for w in t)[:40]


def epit(ki, demo, rnd):
    """Azonosítók kiosztása minden szereplőnek."""
    import re
    # --- hallgatók ---
    h = (ki[[NK, NEV]].drop_duplicates(subset=[NK]).sort_values(NK)
           .reset_index(drop=True))
    hallgato = {}
    for _, r in h.iterrows():
        hallgato[r[NK]] = {
            'uid':   uuid5(rnd),
            'nev':   r[NEV],
            'kod':   r[NK],
            'email': r[NK].lower() + EMAIL_VEG,
            'demo':  r[NK] in demo,
        }

    # --- oktatók (cellán belül vesszővel) ---
    egyeni = []
    for cella in ki[OKT].dropna().unique():
        for x in re.split(r'\s*,\s*', str(cella)):
            if x.strip() and x.strip() not in egyeni:
                egyeni.append(x.strip())
    egyeni.sort()
    oktato = {}
    for i, nev in enumerate(egyeni, 1):
        kod = f'OKT{i:03d}'
        oktato[nev] = {
            'uid': uuid5(rnd), 'tid': uuid5(rnd),
            'nev': nev, 'kod': kod,
            'email': email_slug(nev.replace('Dr.', '').replace('Prof.', ''))
                     + EMAIL_VEG,
        }
    # e-mail-ütközés feloldása (névrokon oktatók)
    latott = {}
    for o in oktato.values():
        e = o['email']
        if e in latott:
            latott[e] += 1
            o['email'] = e.replace(EMAIL_VEG, f'.{latott[e]}{EMAIL_VEG}')
        else:
            latott[e] = 1

    # --- szervezeti egységek a modulokból ---
    org = {}
    for kod, nev in (ki[[MKOD, MNEV]].drop_duplicates().values):
        org[kod] = {'uid': uuid5(rnd), 'kod': kod, 'nev': nev}

    # --- kurzusok ---
    kurzus = {}
    for kk, g in ki.groupby(KK):
        e = g.iloc[0]
        kurzus[kk] = {
            'uid':   uuid5(rnd),
            'kod':   kk,
            'nev':   e[TNEV],
            'targy': e[TKOD],
            'org':   org[e[MKOD]]['uid'],
            'nyelv': {'magyar': 'hu', 'angol': 'en'}.get(str(e['Nyelv']).lower(), 'hu'),
            'letszam': int(g[NK].nunique()),
            'orarend': bool(pd.notna(e['Órarendi információ'])),
            'oktatok': [x.strip() for x in re.split(r'\s*,\s*', str(e[OKT])) if x.strip()],
        }
    return hallgato, oktato, org, kurzus


FEJ = """-- ============================================================================
-- teszt_adatbazis.sql — ECHO teszt-fiókok és kurzusok
--
-- MIT CSINÁL
--   Létrehozza a @teszt.hu végződésű bejelentkezési fiókokat, a hozzájuk
--   tartozó kurzusokat, oktatókat és felvételeket, végül egy NYITOTT
--   kampányt, amiben a kérdőívek kitölthetők.
--
-- AZ ADAT ÁLNEVESÍTETT. Valódi Neptun-kód, név és oktatási azonosító nincs
-- benne — a visszafejtő kulcs a li_visszafejto_kulcs.xlsx fájlban van.
--
-- MINDEN FIÓK JELSZAVA AZONOS:  {JELSZO}
--   Ez szándékos: külön jelszó fiókonként több száz bcrypt-számítást
--   jelentene, ami a SQL Editorban percekig futna. Teszt-adatbázisban a
--   közös jelszó a praktikus választás.
--
-- ELKÜLÖNÍTETT FÉLÉV: a teszt-kurzusok és a teszt-kampány a "2026/27/1"
--   félévre kerülnek. Az éles adatbázisban már van egy NYITOTT kampány a
--   2025/26/2 félévre, és félévenként csak egy aktív kampány lehet. Így a
--   teszt-adat egyetlen meglévő sort sem érint.
--
-- IDEMPOTENS: többször is lefuttatható, nem duplikál.
-- VISSZAVONÁS: a fájl végén, kikommentezve.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) Bejelentkezési fiókok
--    A profilt az on_auth_user_created trigger hozza létre a metaadatból —
--    nem kézzel szúrjuk be, hogy a rendszer saját útján menjen végig.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hash text := crypt({JELSZO_Q}, gen_salt('bf'));
begin
"""


def sql_fiokok(hallgato, oktato):
    s = []
    for d, szerep in ((hallgato, 'STUDENT'), (oktato, 'TEACHER')):
        for x in d.values():
            meta = json.dumps({'role': szerep, 'name': x['nev']}, ensure_ascii=False)
            s.append(f"""  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data)
  values ({q(x['uid'])}::uuid, '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated', 'authenticated', {q(x['email'])}, v_hash,
    now(), now(), now(),
    '{{"provider":"email","providers":["email"]}}'::jsonb,
    {q(meta)}::jsonb)
  on conflict (id) do nothing;""")
    return '\n'.join(s)


def sql_identity(hallgato, oktato):
    """GoTrue e-mail/jelszó belépéshez identity sor is kell."""
    s = []
    for d in (hallgato, oktato):
        for x in d.values():
            idata = json.dumps({'sub': x['uid'], 'email': x['email'],
                                'email_verified': True}, ensure_ascii=False)
            s.append(f"""  insert into auth.identities (
    id, user_id, provider, provider_id, identity_data,
    last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), {q(x['uid'])}::uuid, 'email', {q(x['uid'])},
    {q(idata)}::jsonb, null, now(), now())
  on conflict do nothing;""")
    return '\n'.join(s)


def sql_echo(hallgato, oktato, org, kurzus, ki):
    """Szervezet, oktatók, kurzusok, felvételek."""

    # Az oktatót ahhoz a szervezeti egységhez kötjük, ahol a legtöbb kurzusa
    # van. Ez a 35-ös migráció címzett-feloldásához kell: onnan lépked felfelé
    # a tanszék -> kar -> egyetem láncon.
    from collections import Counter
    okt_org = {}
    for k in kurzus.values():
        for nev in k['oktatok']:
            okt_org.setdefault(nev, Counter())[k['org']] += 1

    def org_of(o):
        c = okt_org.get(o['nev'])
        return (q(c.most_common(1)[0][0]) + '::uuid') if c else 'null'
    s = ["""
-- ---------------------------------------------------------------------------
-- 2) Minden teszt-fiók jóváhagyva
--    A trigger 'pending' állapotot ad; jóváhagyás nélkül a rendszer minden
--    ECHO-hívást ECHO_NOT_APPROVED-dal utasítana el.
-- ---------------------------------------------------------------------------
update public.profiles
   set approval_status = 'approved', approved_at = now()
 where email like '%@teszt.hu' and approval_status <> 'approved';

-- ---------------------------------------------------------------------------
-- 3) Szervezeti egységek
-- ---------------------------------------------------------------------------"""]

    egyetem = 'f0000000-0000-0000-0000-0000000000e1'
    s.append(f"""insert into echo.org_unit (id, parent_id, code, name_hu, kind, ext_source)
values ('{egyetem}'::uuid, null, 'NJE', 'Neumann János Egyetem', 'egyetem', 'teszt')
on conflict (id) do nothing;""")
    for o in org.values():
        s.append(f"""insert into echo.org_unit (id, parent_id, code, name_hu, kind, ext_source)
values ({q(o['uid'])}::uuid, '{egyetem}'::uuid, {q(o['kod'])}, {q(o['nev'])}, 'tanszek', 'teszt')
on conflict (id) do nothing;""")

    s.append("""
-- ---------------------------------------------------------------------------
-- 4) Oktatók — a profile_id köti őket a bejelentkezési fiókhoz
-- ---------------------------------------------------------------------------""")
    for o in oktato.values():
        s.append(f"""insert into echo.teacher (id, code, name, email, active, org_unit_id, profile_id, ext_source)
values ({q(o['tid'])}::uuid, {q(o['kod'])}, {q(o['nev'])}, {q(o['email'])},
        true, {org_of(o)}, {q(o['uid'])}::uuid, 'teszt')
on conflict (id) do update
  set profile_id = excluded.profile_id, org_unit_id = excluded.org_unit_id;""")

    # --- 4b. ECHO szerepkörök ------------------------------------------------
    # Az echo_my_teacher_courses() OKTATO grantot kér az echo.role_grant-ban.
    # Enélkül az oktató belép ugyan, de nulla kurzust lát: mérve
    # "ECHO_FORBIDDEN: nincs ervenyes OKTATO grantod".
    s.append("""
-- ---------------------------------------------------------------------------
-- 4b) ECHO szerepkörök
--     OKTATO grant nélkül az oktató belép, de EGYETLEN kurzust sem lát.
--     Mellé néhány vezetői szerep, hogy a 7 napos észrevétel címzett-
--     feloldása (35_echo_comment.sql) is kipróbálható legyen.
-- ---------------------------------------------------------------------------""")
    okt_lista = list(oktato.values())
    for o in okt_lista:
        s.append(f"""insert into echo.role_grant (person, role, scope_org, megjegyzes)
values ({q(o['uid'])}::uuid, 'OKTATO', null, 'teszt')
on conflict do nothing;""")
    # az első három oktató kap vezetői szerepet is
    org_lista = list(org.values())
    vezetoi = [('TANSZEKVEZETO', org_lista[0]['uid'] if org_lista else None),
               ('DEKAN', None), ('MIR', None)]
    for o, (szerep, scope) in zip(okt_lista[:3], vezetoi):
        sc = f"{q(scope)}::uuid" if scope else 'null'
        s.append(f"""insert into echo.role_grant (person, role, scope_org, megjegyzes)
values ({q(o['uid'])}::uuid, {q(szerep)}, {sc}, 'teszt — vezetői szerep')
on conflict do nothing;""")

    s.append("""
-- ---------------------------------------------------------------------------
-- 5) Kurzusok
-- ---------------------------------------------------------------------------""")
    for k in kurzus.values():
        s.append(f"""insert into echo.course (id, code, name_hu, term, lang, org_unit_id,
                          letszam, van_orarendi_info, vizsgakurzus, ext_source)
values ({q(k['uid'])}::uuid, {q(k['kod'])}, {q(k['nev'])}, '2026/27/1', {q(k['nyelv'])},
        {q(k['org'])}::uuid, {k['letszam']}, {str(k['orarend']).lower()}, false, 'teszt')
on conflict (id) do nothing;""")

    s.append("""
-- ---------------------------------------------------------------------------
-- 6) Ki melyik kurzust tanítja
--    A share_pct egyenlően oszlik; a min_share_pct = 25 küszöb miatt ez
--    számít: az alatta lévő oktató nem kap saját eredményt.
-- ---------------------------------------------------------------------------""")
    for k in kurzus.values():
        n = len(k['oktatok']) or 1
        share = round(100.0 / n, 2)
        for nev in k['oktatok']:
            o = oktato.get(nev)
            if not o:
                continue
            s.append(f"""insert into echo.course_teacher (course_id, teacher_id, share_pct, role, ext_source)
values ({q(k['uid'])}::uuid, {q(o['tid'])}::uuid, {share}, 'oktato', 'teszt')
on conflict do nothing;""")

    s.append("""
-- ---------------------------------------------------------------------------
-- 7) Felvételek — a student_key MAGA a bejelentkezési azonosító
--    Kötegelt beszúrás: soronkénti INSERT-tel ez a szakasz 700 kB lenne,
--    amit a SQL Editor nehezen nyel le.
-- ---------------------------------------------------------------------------""")
    sorok = []
    for kk, g in ki.groupby(KK):
        kid = kurzus[kk]['uid']
        for nk in g[NK].unique():
            h = hallgato.get(nk)
            if h:
                sorok.append('(' + q(kid) + '::uuid, ' + q(h['uid']) + '::uuid)')
    for i in range(0, len(sorok), 400):
        blokk = ',\n       '.join(sorok[i:i + 400])
        s.append('insert into echo.enrollment (id, course_id, student_key, status, ext_source)\n'
                 "select gen_random_uuid(), v.c, v.s, 'active', 'teszt'\n"
                 '  from (values ' + blokk + ') as v(c, s)\n'
                 ' where not exists (select 1 from echo.enrollment e\n'
                 '                    where e.course_id = v.c and e.student_key = v.s);')
    return '\n'.join(s)


SABLON = {
  "sections": [
    {"id": "s1", "hu": "Az oktatóról", "en": "About the lecturer", "questions": [
      {"id": "q_ertheto", "type": "scale", "min": 1, "max": 5, "required": True,
       "hu": "Az oktató érthetően magyarázott.",
       "en": "The lecturer explained the material clearly."},
      {"id": "q_felkeszult", "type": "scale", "min": 1, "max": 5, "required": True,
       "hu": "Az oktató felkészülten érkezett az órákra.",
       "en": "The lecturer came to class well prepared."},
      {"id": "q_elerheto", "type": "scale", "min": 1, "max": 5, "required": False,
       "hu": "Az oktató elérhető volt kérdésekkel.",
       "en": "The lecturer was available for questions."}]},
    {"id": "s2", "hu": "A kurzusról", "en": "About the course", "questions": [
      {"id": "q_hasznos", "type": "scale", "min": 1, "max": 5, "required": True,
       "hu": "A kurzus hasznos ismereteket adott.",
       "en": "The course provided useful knowledge."},
      {"id": "q_terheles", "type": "single", "required": True,
       "hu": "Milyennek találtad a kurzus terhelését?",
       "en": "How did you find the workload?",
       "options": [{"value": "keves", "hu": "Kevés", "en": "Light"},
                   {"value": "megfelelo", "hu": "Megfelelő", "en": "Adequate"},
                   {"value": "sok", "hu": "Sok", "en": "Heavy"}]},
      {"id": "attendance", "type": "single", "required": True,
       "hu": "Az órák hány százalékán vettél részt?",
       "en": "What share of classes did you attend?",
       "options": [{"value": "0-33", "hu": "0–33%", "en": "0–33%"},
                   {"value": "34-66", "hu": "34–66%", "en": "34–66%"},
                   {"value": "67-100", "hu": "67–100%", "en": "67–100%"}]}]},
    {"id": "s3", "hu": "Szöveges vélemény", "en": "Free text", "questions": [
      {"id": "q_jo", "type": "longtext", "required": False,
       "hu": "Mi volt a kurzus legjobb része?",
       "en": "What was the best part of the course?"},
      {"id": "q_fejleszt", "type": "longtext", "required": False,
       "hu": "Min lehetne javítani?", "en": "What could be improved?"}]}]}


def sql_kampany(rnd):
    tpl = 'f0000000-0000-0000-0000-0000000000t1'.replace('t', 'a')
    ver = 'f0000000-0000-0000-0000-0000000000v1'.replace('v', 'b')
    cmp_ = 'f0000000-0000-0000-0000-0000000000c1'.replace('c', 'd')
    j = json.dumps(SABLON, ensure_ascii=False)
    return f"""
-- ---------------------------------------------------------------------------
-- 8) Sablon és NYITOTT kampány
--    A kampány most nyílt és 60 nap múlva zár, tehát a kérdőívek azonnal
--    kitölthetők. Az eredmény SZÁNDÉKOSAN nem látszik nyitott kampányban —
--    ezt az echo.results_gate() zárja, és ez helyes viselkedés.
-- ---------------------------------------------------------------------------
insert into echo.template (id, code, name_hu)
values ({q(tpl)}::uuid, 'TESZT-TPL', 'Teszt kérdőív')
on conflict (id) do nothing;

insert into echo.template_version (id, template_id, version, state, compiled)
values ({q(ver)}::uuid, {q(tpl)}::uuid, 1, 'live', {q(j)}::jsonb)
on conflict (id) do update set compiled = excluded.compiled, state = 'live';

insert into echo.campaign (id, code, name_hu, term, template_version_id,
                           opens_at, closes_at, state)
values ({q(cmp_)}::uuid, 'TESZT-2026', 'Teszt kampány (elkülönített félév)', '2026/27/1',
        {q(ver)}::uuid, now() - interval '1 day', now() + interval '60 day', 'open')
on conflict (id) do update
  set state = 'open',
      opens_at = now() - interval '1 day',
      closes_at = now() + interval '60 day';

-- Jogosultsági mátrix felépítése a felvételekből.
select echo.eligibility_rebuild({q(cmp_)}::uuid);

commit;
"""


ELLENORZES = """
-- ---------------------------------------------------------------------------
-- 9) ELLENŐRZÉS — ez az utolsó eredmény, ezt fogod látni
-- ---------------------------------------------------------------------------
select 'Bejelentkezési fiók' as "mit", count(*)::text as "darab",
       'jelszó mindenhol: Teszt1234!' as "megjegyzés"
  from auth.users where email like '%@teszt.hu'
union all
select 'Ebből jóváhagyott', count(*)::text,
       case when count(*) = (select count(*) from auth.users where email like '%@teszt.hu')
            then 'OK' else '!! nem mind' end
  from public.profiles where email like '%@teszt.hu' and approval_status = 'approved'
union all
select 'Hallgató', count(*)::text, '' from public.profiles
 where email like '%@teszt.hu' and role = 'STUDENT'
union all
select 'Oktató (fiók)', count(*)::text, '' from public.profiles
 where email like '%@teszt.hu' and role = 'TEACHER'
union all
select 'Oktató (echo.teacher)', count(*)::text,
       case when count(*) filter (where profile_id is null) = 0
            then 'mind be van kötve' else '!! van bekötetlen' end
  from echo.teacher where ext_source = 'teszt'
union all
select 'Kurzus', count(*)::text, '' from echo.course where ext_source = 'teszt'
union all
select 'Felvétel', count(*)::text, '' from echo.enrollment where ext_source = 'teszt'
union all
select 'Kampány állapota', c.state,
       'zár: ' || to_char(c.closes_at, 'YYYY-MM-DD')
  from echo.campaign c where c.code = 'TESZT-2026'
union all
select 'Jogosult (hallgató×kurzus)', count(*)::text, ''
  from echo.participation p join echo.campaign c on c.id = p.campaign_id
 where c.code = 'TESZT-2026' and p.eligible
union all
select 'Kurzus a k-sávban ' || sav, db::text, magyarazat from (
  select case when n < 5 then '3-4 fo' when n < 10 then '5-9 fo'
              when n < 30 then '10-29 fo' else '30+ fo' end as sav,
         case when n < 5 then 'teljes riport rejtve'
              when n < 10 then 'szam igen, szoveg nem'
              else 'minden latszik' end as magyarazat,
         count(*) as db
    from (select course_id, count(*) as n from echo.enrollment
           where ext_source = 'teszt' group by course_id) x
   group by 1, 2) y
order by 1;
"""

VISSZAVONAS = """
-- ============================================================================
-- VISSZAVONÁS — ha törölni akarod a teszt-adatokat, futtasd ezt a blokkot.
-- ============================================================================
-- begin;
-- delete from echo.participation where campaign_id in
--   (select id from echo.campaign where code = 'TESZT-2026');
-- delete from echo.eligibility  where campaign_id in
--   (select id from echo.campaign where code = 'TESZT-2026');
-- delete from echo.response     where campaign_id in
--   (select id from echo.campaign where code = 'TESZT-2026');
-- delete from echo.campaign        where code = 'TESZT-2026';
-- delete from echo.template_version where template_id in
--   (select id from echo.template where code = 'TESZT-TPL');
-- delete from echo.template        where code = 'TESZT-TPL';
-- delete from echo.enrollment      where ext_source = 'teszt';
-- delete from echo.course_teacher  where ext_source = 'teszt';
-- delete from echo.course          where ext_source = 'teszt';
-- delete from echo.teacher         where ext_source = 'teszt';
-- delete from echo.org_unit        where ext_source = 'teszt';
-- delete from auth.users           where email like '%@teszt.hu';
-- commit;
"""


if __name__ == '__main__':
    rnd = random.Random(MAG)
    print('Beolvasás…')
    df = pd.read_excel(FORRAS, dtype=str)
    ki, demo = valaszt(df, rnd)
    print(f'  minta: {ki[KK].nunique()} kurzus, {ki[NK].nunique()} hallgató, {len(ki)} felvétel')

    hallgato, oktato, org, kurzus = epit(ki, demo, rnd)
    print(f'  oktató: {len(oktato)}, szervezeti egység: {len(org)}')

    reszek = [
        FEJ.replace('{JELSZO}', JELSZO).replace('{JELSZO_Q}', q(JELSZO)),
        sql_fiokok(hallgato, oktato),
        sql_identity(hallgato, oktato),
        'end $$;\n',
        sql_echo(hallgato, oktato, org, kurzus, ki),
        sql_kampany(rnd),
        ELLENORZES,
        VISSZAVONAS,
    ]
    sql = '\n'.join(reszek)
    open(KI_SQL, 'w', encoding='utf-8').write(sql)
    print(f'\nÍrás: {KI_SQL}  ({len(sql)/1024:.0f} kB)')

    # --- belépési adatok ---
    sorok = []
    for h in sorted(hallgato.values(), key=lambda x: (not x['demo'], x['email'])):
        sorok.append({'Szerep': 'Hallgató', 'Név': h['nev'],
                      'Neptun (teszt)': h['kod'], 'E-mail': h['email'],
                      'Jelszó': JELSZO,
                      'Kiemelt': 'igen — sok kurzusa van' if h['demo'] else ''})
    okt_lista = sorted(oktato.values(), key=lambda x: x['kod'])
    vez = {okt_lista[0]['kod']: 'TANSZEKVEZETO',
           okt_lista[1]['kod']: 'DEKAN',
           okt_lista[2]['kod']: 'MIR'} if len(okt_lista) >= 3 else {}
    for o in sorted(oktato.values(), key=lambda x: x['email']):
        sorok.append({'Szerep': 'Oktató', 'Név': o['nev'],
                      'Neptun (teszt)': o['kod'], 'E-mail': o['email'],
                      'Jelszó': JELSZO,
                      'Kiemelt': ('vezetői szerep: ' + vez[o['kod']])
                                 if o['kod'] in vez else ''})
    with pd.ExcelWriter(KI_XLS) as w:
        pd.DataFrame(sorok).to_excel(w, sheet_name='Belepesi_adatok', index=False)
        krz = [{'Kurzuskód': k['kod'], 'Tantárgy': k['nev'],
                'Létszám': k['letszam'], 'Oktatók': ', '.join(k['oktatok']),
                'k-sáv': ('3-4 fő — riport rejtve' if k['letszam'] < 5 else
                          '5-9 fő — szöveg rejtve' if k['letszam'] < 10 else
                          'minden látszik')}
               for k in sorted(kurzus.values(), key=lambda x: -x['letszam'])]
        pd.DataFrame(krz).to_excel(w, sheet_name='Kurzusok', index=False)
    print(f'Írás: {KI_XLS}')
    print('\nKÉSZ.')
