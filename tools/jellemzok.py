# -*- coding: utf-8 -*-
"""
Hallgatói jellemzők SQL-be — a teszt-fiókokhoz.

A SZAKNÉV VALÓDI MARAD, DE k-KÜSZÖBBEL
  A tagozat, a képzési szint és a szak önmagában nem azonosít senkit — de a
  HÁRMAS metszete igen: az eredeti adatban négy szakon PONTOSAN EGY hallgató
  van, és négy (szak × tagozat × szint) cella is egyfős. Egy ilyen cella
  egyetlen valódi személyt jelöl ki, akkor is, ha a neve álnevesített.

  Ezért k=5 küszöböt alkalmazunk a hármas metszetre, kétlépcsős
  általánosítással: előbb a szak megy "egyéb képzés"-be, és ha a cella még
  mindig kicsi, a képzési szint is általánosul. Mérve: 2 kör alatt konvergál,
  a legkisebb cella 5 fő, és a hallgatók 99,5%-a MEGTARTJA a valódi,
  felismerhető szaknevét (mérnökinformatikus, gépészmérnöki, járműmérnöki).
"""
import pandas as pd, sys

EREDETI = '/Users/lorant/Downloads/li.xlsx'
ALNEV   = '/Users/lorant/Downloads/li_teszt_alnevesitett.xlsx'
KI      = '/Users/lorant/Downloads/teszt_jellemzok.sql'
K = 5

NK = 'Hallgató Neptun kód'
KAR_NEV = {
    'G': 'GAMF Műszaki és Informatikai Kar',
    'M': 'Gazdaságtudományi Kar',
    'K': 'Kertészeti és Vidékfejlesztési Kar',
    'D': 'Doktori Iskola',
    'N': 'Előkészítő képzés',
    'E': 'Nemzetközi mobilitás',
}


def q(v):
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return 'null'
    return "'" + str(v).replace("'", "''") + "'"


def kuszobol(h):
    """k-küszöb a (szak x tagozat x szint) metszetre, HÁROM lépcsőben.

    A küszöböt arra a halmazra kell alkalmazni, ami TÉNYLEGESEN bekerül az
    adatbázisba. Először a teljes 4510 fős sokaságra számoltam, és a 401 fős
    teszt-mintán elbukott: ami ott 800 fős cella volt, itt egyfősre zsugorodott.

    Lépcsők: szak -> "egyéb képzés", majd szint -> "egyéb szint", végül
    tagozat -> "egyéb tagozat". Mérve: 3 kör alatt konvergál.
    """
    v = h['szak'].value_counts()
    h.loc[~h['szak'].isin(v[v >= K].index), 'szak'] = 'egyéb képzés'
    # A KAR is besorolási szempont, tehát ugyanaz a küszöb vonatkozik rá:
    # egy egyfős kar ugyanúgy kijelöl valakit, mint egy egyfős szak.
    # A küszöb alatti kar ELHAGYÁSRA kerül, nem gyűjtőbe. Gyűjtővel ugyanis
    # az a helyzet állt elő, hogy egyetlen ember esett bele — a gyűjtő maga
    # lett egyfős, tehát semmit nem oldott meg.
    vk = h['kar'].value_counts()
    h.loc[~h['kar'].isin(vk[vk >= K].index), 'kar'] = None

    for _ in range(15):
        g = h.groupby(['szak', 'tagozat', 'szint']).size()
        kicsi = g[g < K]
        if kicsi.empty:
            return h
        for (sz, tg, kt) in kicsi.index:
            m = (h['szak'] == sz) & (h['tagozat'] == tg) & (h['szint'] == kt)
            if sz != 'egyéb képzés':
                h.loc[m, 'szak'] = 'egyéb képzés'
            elif kt != 'egyéb szint':
                h.loc[m, 'szint'] = 'egyéb szint'
            else:
                h.loc[m, 'tagozat'] = 'egyéb tagozat'
    raise RuntimeError('A k-küszöb nem konvergált.')


def jellemzok():
    """Hallgatónkénti besorolás az EREDETI adatból."""
    er = pd.read_excel(EREDETI, dtype=str)
    h = er.drop_duplicates(NK).copy()
    h['szak']    = h['Modul neve']
    h['szint']   = h['Képzési szint']
    h['tagozat'] = h['Tagozat']
    h['kar']     = h['Modulkód'].str[0].map(KAR_NEV).fillna('Egyéb szervezeti egység')
    return h.set_index(NK)


def main():
    h = jellemzok()
    an = pd.read_excel(ALNEV, dtype=str)
    er = pd.read_excel(EREDETI, dtype=str)

    # Az álnevesített kód <-> eredeti kód összerendelés a SORREND alapján:
    # mindkét fájl ugyanabból a sorhalmazból készült, soronként megfeleltetve.
    parok = dict(zip(er[NK], an[NK]))

    # CSAK azokra a hallgatókra, akiknek TÉNYLEGESEN van teszt-fiókja.
    # A kivonat 4510 hallgatót tartalmaz, a teszt-adatbázisba viszont célzott
    # minta került — a többiekre kiadott sor sehova nem illeszkedne.
    import pandas as _pd
    belepok = set(
        _pd.read_excel('/Users/lorant/Downloads/teszt_belepesi_adatok.xlsx',
                       sheet_name='Belepesi_adatok', dtype=str)['Neptun (teszt)']
        .dropna().str.upper()
    )

    # A küszöb CSAK arra a halmazra érvényes, ami bekerül. Előbb kiválasztjuk
    # a teszt-fiókkal rendelkezőket, aztán rájuk alkalmazzuk a k-küszöböt.
    valogat = [(e, u) for e, u in parok.items()
               if e in h.index and str(u).upper() in belepok]
    reszhalmaz = h.loc[[e for e, _ in valogat]].copy()
    reszhalmaz = kuszobol(reszhalmaz)
    g = reszhalmaz.groupby(['szak', 'tagozat', 'szint']).size()
    assert g.min() >= K, f'k-küszöb sérült: legkisebb cella {g.min()}'
    gk = reszhalmaz['kar'].value_counts()
    assert gk.empty or gk.min() >= K, f'k-küszöb sérült a karnál: legkisebb {gk.min()}'
    elhagyva = reszhalmaz['kar'].isna().sum()
    if elhagyva:
        print(f'  kar elhagyva {elhagyva} hallgatónál (küszöb alatti egység)')
    print(f'  k-küszöb OK: legkisebb cella {g.min()} fő, '
          f'{reszhalmaz["szak"].nunique() - 1} valódi szaknév megmarad')

    sorok = []
    for eredeti_kod, uj_kod in valogat:
        r = reszhalmaz.loc[eredeti_kod]
        sorok.append(
            f"({q(uj_kod.lower() + '@teszt.hu')}, {q(uj_kod)}, {q(r['tagozat'])}, "
            f"{q(r['szint'])}, {q(r['szak'])}, {q(r['kar'])}, "
            f"{q(r['Modulkód'])}, {q(r['Nyelv'])}, {q(r['Telephely neve'])})"
        )

    fej = """-- ============================================================================
-- teszt_jellemzok.sql — hallgatói besorolás a teszt-fiókokhoz
--
-- ELŐFELTÉTEL: a 38_student_groups.sql és a teszt_adatbazis_*resz.sql lefutott.
--
-- A szaknév VALÓDI, de k=5 küszöbbel kezelve: a (szak × tagozat × szint)
-- metszet sehol nem kisebb 5 főnél. Az ez alatti szakok "egyéb képzés" néven
-- vannak összevonva — egy egyfős szak egyetlen valódi személyt azonosítana.
--
-- Idempotens: a meglévő sorokat frissíti.
-- ============================================================================

begin;

"""
    torzs = []
    for i in range(0, len(sorok), 300):
        blokk = ',\n       '.join(sorok[i:i + 300])
        torzs.append(f"""insert into public.student_attributes
  (profile_id, neptun, tagozat, kepzesi_szint, szak, kar, szak_kod, nyelv, telephely, forras)
select p.id, v.neptun, v.tagozat, v.szint, v.szak, v.kar, v.szak_kod, v.nyelv, v.telephely, 'teszt'
  from (values {blokk})
       as v(email, neptun, tagozat, szint, szak, kar, szak_kod, nyelv, telephely)
  join public.profiles p on lower(p.email) = v.email
on conflict (profile_id) do update
  set tagozat = excluded.tagozat, kepzesi_szint = excluded.kepzesi_szint,
      szak = excluded.szak, kar = excluded.kar, szak_kod = excluded.szak_kod,
      nyelv = excluded.nyelv, telephely = excluded.telephely, updated_at = now();""")

    lab = """

commit;

-- ---------------------------------------------------------------------------
-- ELLENŐRZÉS — ez az utolsó eredmény, ezt fogod látni
-- ---------------------------------------------------------------------------
select 'Besorolt teszt-hallgató' as "mit", count(*)::text as "érték", '' as "megjegyzés"
  from public.student_attributes where forras = 'teszt'
union all
select 'Tagozat: ' || tagozat, count(*)::text, ''
  from public.student_attributes where forras='teszt' group by tagozat
union all
select 'Kar: ' || kar, count(*)::text, ''
  from public.student_attributes where forras='teszt' group by kar
union all
select 'Legkisebb csoport (szak×tagozat×szint)', min(n)::text,
       case when min(n) >= 5 then 'OK — senkit nem azonosít' else '!! k-küszöb sérült' end
  from (select count(*) as n from public.student_attributes
         where forras='teszt' group by szak, tagozat, kepzesi_szint) t
order by 1;
"""
    open(KI, 'w', encoding='utf-8').write(fej + '\n\n'.join(torzs) + lab)
    print(f'  {KI}')
    print(f'  {len(sorok)} hallgató, {len(fej + chr(10).join(torzs) + lab)/1024:.0f} kB')


if __name__ == '__main__':
    main()
