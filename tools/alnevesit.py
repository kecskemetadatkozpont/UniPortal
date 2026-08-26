# -*- coding: utf-8 -*-
"""
Neptun-kivonat álnevesítése.

ALAPELVEK
  1. A leképezés a NEPTUN-KÓDRA épül, nem a névre. A forrásban 106 név
     tartozik több hallgatóhoz; név szerint képezve különböző embereket
     olvasztanánk össze.
  2. Oszloponként KÖVETKEZETES 1:1 leképezés. A kapcsolatok attól maradnak
     épek, hogy az együtt előforduló értékek együtt is maradnak — nem attól,
     hogy a kódok belső szerkezetét utánozzuk.
  3. A sorok száma és sorrendje VÁLTOZATLAN.
  4. Determinisztikus: rögzített mag mellett újrafuttatva ugyanazt adja.
"""
import sys, random, re, hashlib
import pandas as pd
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import nevek

MAG = 20260825          # rögzített mag — az újrafuttathatóság miatt
NAPELTOLAS = 137        # minden időbélyeg ennyi nappal tolódik

FORRAS = '/Users/lorant/Downloads/li.xlsx'

# --- oszlopnevek ---
NK   = 'Hallgató Neptun kód'
OA   = 'Egyén oktatási azonosító'
NEV  = 'Hallgató Nyomtatási név'
OKT  = 'Kurzus oktatók'
TNEV = 'Tárgynév'
TKOD = 'Tárgykód'
KKOD = 'Kurzuskód'
MNEV = 'Modul neve'
MKOD = 'Modulkód'
DAT  = 'Jelentkezés dátuma'


def uj_neptun(rnd, hasznalt):
    """6 karakteres, nagybetűs alfanumerikus — a Neptun-kód alakja."""
    abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    while True:
        k = ''.join(rnd.choice(abc) for _ in range(6))
        if k not in hasznalt:
            hasznalt.add(k)
            return k


def uj_oktazon(rnd, hasznalt):
    """11 jegyű szám, a valódi oktatási azonosító alakja."""
    while True:
        k = str(rnd.randint(70000000000, 79999999999))
        if k not in hasznalt:
            hasznalt.add(k)
            return k


def uj_szemely(rnd, titulussal=False, tilt=frozenset(), hasznalt=None):
    """Új személynév.

    A `tilt` a FORRÁSBAN szereplő valódi nevek halmaza. Enélkül a generált
    nevek véletlenül eltalálnak létező neveket — az első futásnál 127 valódi
    hallgatónév maradt bent. Egy ilyen név akkor is szivárgás, ha közben más
    emberhez tartozik: az olvasó azt hiheti, hogy az illetőről van szó.
    """
    for _ in range(4000):
        vez = rnd.choice(nevek.VEZETEKNEV)
        ker = rnd.choice(nevek.FERFI if rnd.random() < 0.5 else nevek.NOI)
        # a forrásban gyakori a kéttagú keresztnév
        if rnd.random() < 0.30:
            ker += ' ' + rnd.choice(nevek.FERFI + nevek.NOI)
        n = f'{vez} {ker}'
        if titulussal:
            t = rnd.choice(nevek.TITULUS)
            if t:
                n = f'{n} {t}' if t == 'Dr.' else f'{t} {n}'
        if n in tilt:
            continue
        if hasznalt is not None and n in hasznalt:
            continue
        if hasznalt is not None:
            hasznalt.add(n)
        return n
    raise RuntimeError('Kifogytak a szabad névkombinációk.')


def uj_targy(rnd, hasznalt):
    for _ in range(400):
        n = (rnd.choice(nevek.TARGY_ELO) + ' ' + rnd.choice(nevek.TARGY_FO)
             + rnd.choice(nevek.TARGY_UTO)).replace('_', ' ')
        if n not in hasznalt:
            hasznalt.add(n)
            return n
    n = f'Tantárgy {len(hasznalt) + 1}'
    hasznalt.add(n)
    return n


def alak_kod(rnd, minta, hasznalt):
    """Ugyanolyan ALAKÚ kódot ad: betű->betű, szám->szám, egyéb marad.
       Így a kötőjeles tagolás és a hossz megmarad, a tartalom nem."""
    betuk = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    for _ in range(600):
        ki = []
        for ch in str(minta):
            if ch.isalpha():
                ki.append(rnd.choice(betuk))
            elif ch.isdigit():
                ki.append(rnd.choice('0123456789'))
            else:
                ki.append(ch)
        k = ''.join(ki)
        if k not in hasznalt:
            hasznalt.add(k)
            return k
    k = str(minta) + '-' + str(len(hasznalt))
    hasznalt.add(k)
    return k


def main():
    rnd = random.Random(MAG)
    print('Beolvasás…')
    df = pd.read_excel(FORRAS, dtype=str)
    eredeti_alak = df.shape
    print(f'  {eredeti_alak[0]} sor × {eredeti_alak[1]} oszlop')

    terkep = {}          # oszlop -> {régi: új}

    # --- 1. Hallgatók: a NEPTUN-KÓD a kulcs ---------------------------------
    hallgatok = (df[[NK, OA, NEV]].drop_duplicates(subset=[NK])
                   .sort_values(NK).reset_index(drop=True))
    print(f'Hallgatók: {len(hallgatok)}')
    hk, ho = set(), set()
    m_nk, m_oa = {}, {}
    for _, r in hallgatok.iterrows():
        m_nk[r[NK]] = uj_neptun(rnd, hk)
        m_oa[r[OA]] = uj_oktazon(rnd, ho)
    terkep[NK], terkep[OA] = m_nk, m_oa

    # --- 1b. Nevek: a NÉVROKONSÁG a valós arány szerint --------------------
    #
    # A forrásban 106 névrokon-csoport van (87 kettes, 13 hármas, 5 négyes,
    # 1 ötös), 238 érintett hallgatóval. Ez nem mellékes részlet: a rendszernek
    # helyesen kell kezelnie, ha két hallgatót ugyanúgy hívnak. Ezért NEM a
    # véletlenre bízzuk — az első futásnál 478 csoport jött ki, ami irreális —,
    # hanem pontosan reprodukáljuk az eloszlást.
    valodi_nevek = frozenset(df[NEV].dropna().astype(str))
    kodok = list(hallgatok[NK])
    rnd.shuffle(kodok)

    csoportok = []                       # [(méret), ...] a forrás szerint
    g = (df[[NK, NEV]].drop_duplicates(subset=[NK])
           .groupby(NEV)[NK].nunique())
    for meret in g[g > 1].values:
        csoportok.append(int(meret))
    csoportok.sort(reverse=True)

    m_nev = {}
    hasznalt_nev = set()
    i = 0
    for meret in csoportok:              # előbb a névrokon-csoportok
        if i + meret > len(kodok):
            break
        nev = uj_szemely(rnd, tilt=valodi_nevek, hasznalt=hasznalt_nev)
        for _ in range(meret):
            m_nev[kodok[i]] = nev
            i += 1
    for k in kodok[i:]:                  # a többiek egyedi nevet kapnak
        m_nev[k] = uj_szemely(rnd, tilt=valodi_nevek, hasznalt=hasznalt_nev)

    # --- 2. Oktatók: cellánként vesszővel elválasztva ------------------------
    egyeni = set()
    for cella in df[OKT].dropna().unique():
        for r in re.split(r'\s*,\s*', str(cella)):
            if r.strip():
                egyeni.add(r.strip())
    print(f'Oktatók: {len(egyeni)}')
    valodi_okt = frozenset(egyeni) | valodi_nevek
    # Az oktatók sem kaphatnak valódi nevet — és a hallgatói álnevekkel
    # sem ütközhetnek, különben egy oktató és egy hallgató összemosódna.
    m_okt = {o: uj_szemely(rnd, titulussal=True, tilt=valodi_okt,
                           hasznalt=hasznalt_nev)
             for o in sorted(egyeni)}
    terkep['Oktató (egyenként)'] = m_okt

    # --- 3. Tárgy: a TÁRGYKÓD a kulcs a névhez -------------------------------
    #     A forrásban a tárgykód -> tárgynév 1:1, de ugyanaz a NÉV több kódon
    #     is szerepel (ugyanaz a tárgy több szakon). A nevet ezért a NÉV
    #     szerint képezzük le, hogy ez az egybeesés megmaradjon.
    hasznalt_targy = set()
    m_tnev = {t: uj_targy(rnd, hasznalt_targy) for t in sorted(df[TNEV].dropna().unique())}
    terkep[TNEV] = m_tnev

    # --- 4. Kódok: alaktartó csere ------------------------------------------
    for oszlop in (TKOD, KKOD, MKOD):
        h = set()
        terkep[oszlop] = {v: alak_kod(rnd, v, h)
                          for v in sorted(df[oszlop].dropna().unique())}
        print(f'{oszlop}: {len(terkep[oszlop])}')

    # --- 5. Modul neve -------------------------------------------------------
    hm = set()
    m_mnev = {}
    for v in sorted(df[MNEV].dropna().unique()):
        for _ in range(200):
            n = (rnd.choice(nevek.MODUL_ELO) + ' '
                 + rnd.choice(nevek.MODUL_FO)).replace('_', ' ')
            if n not in hm:
                hm.add(n); m_mnev[v] = n; break
        else:
            m_mnev[v] = f'Modul {len(hm) + 1}'; hm.add(m_mnev[v])
    terkep[MNEV] = m_mnev

    # --- 6. Alkalmazás -------------------------------------------------------
    print('Csere…')
    ki = df.copy()
    ki[NEV] = df[NK].map(m_nev)          # ELŐBB a név (a régi kód alapján)
    ki[NK]  = df[NK].map(m_nk)
    ki[OA]  = df[OA].map(m_oa)
    ki[OKT] = df[OKT].map(
        lambda c: c if pd.isna(c) else
        ', '.join(m_okt.get(r.strip(), r.strip())
                  for r in re.split(r'\s*,\s*', str(c)) if r.strip()))
    for oszlop, m in ((TNEV, m_tnev), (TKOD, terkep[TKOD]),
                      (KKOD, terkep[KKOD]), (MKOD, terkep[MKOD]), (MNEV, m_mnev)):
        ki[oszlop] = df[oszlop].map(lambda v: m.get(v, v))

    # Időbélyeg: EGYETLEN állandó eltolás. A relatív sorrend és a közök
    # megmaradnak, tehát az időfüggő logika tesztelhető marad.
    d = pd.to_datetime(df[DAT], errors='coerce')
    ki[DAT] = (d + pd.Timedelta(days=NAPELTOLAS)).dt.strftime('%Y-%m-%d %H:%M:%S')
    ki.loc[d.isna(), DAT] = df.loc[d.isna(), DAT]

    return df, ki, terkep, m_nev, eredeti_alak


def ellenoriz(df, ki, m_nev):
    """Amit nem mérünk meg, arról nem tudjuk, hogy igaz."""
    hibak, jok = [], []

    def t(felt, szoveg):
        (jok if felt else hibak).append(szoveg)

    # a) számosság
    t(df.shape == ki.shape, f'alak változatlan: {ki.shape}')
    t(len(df) == len(ki), f'sorok száma azonos: {len(ki)}')

    # b) oszloponkénti egyediség — a szerkezet megmaradt?
    for c in df.columns:
        a, b = df[c].nunique(dropna=True), ki[c].nunique(dropna=True)
        t(a == b, f'{c[:26]}: {a} → {b} egyedi')

    # c) SEMMI valódi azonosító nem maradhat bent
    for c, nev in ((NK, 'Neptun-kód'), (OA, 'oktatási azonosító'),
                   (NEV, 'hallgatónév'), (TNEV, 'tárgynév')):
        atfedes = set(df[c].dropna()) & set(ki[c].dropna())
        t(not atfedes, f'{nev}: nincs átfedés a forrással'
          + ('' if not atfedes else f' — MARADT {len(atfedes)}'))

    # oktatók külön, mert cellán belül több is lehet
    def bont(s):
        ki_ = set()
        for cella in s.dropna().unique():
            for r in re.split(r'\s*,\s*', str(cella)):
                if r.strip():
                    ki_.add(r.strip())
        return ki_
    at = bont(df[OKT]) & bont(ki[OKT])
    t(not at, 'oktatónév: nincs átfedés a forrással'
      + ('' if not at else f' — MARADT {len(at)}'))

    # d) KÖVETKEZETESSÉG: egy hallgató mindenhol ugyanaz maradt?
    parok = ki.groupby(NK)[NEV].nunique()
    t((parok > 1).sum() == 0, 'minden álnév-kódhoz pontosan egy név tartozik')
    vissza = df.groupby(NK).size().sort_index().values
    elore  = ki.groupby(NK).size().sort_values().values
    t(sorted(df.groupby(NK).size()) == sorted(ki.groupby(NK).size()),
      'hallgatónkénti sorszám-eloszlás változatlan')

    # e) a NÉVROKONOK megmaradtak? (a valósághűség próbája)
    er = (df.groupby(NEV)[NK].nunique() > 1).sum()
    uj = (ki.groupby(NEV)[NK].nunique() > 1).sum()
    jok.append(f'névrokonok: {er} → {uj} (természetes ütközésből)')

    # f) kapcsolatok: hallgató↔kurzus, oktató↔kurzus
    t(df.groupby(KKOD)[NK].nunique().sort_values().tolist()
      == ki.groupby(KKOD)[NK].nunique().sort_values().tolist(),
      'kurzusonkénti hallgatószám-eloszlás változatlan')
    return jok, hibak


if __name__ == '__main__':
    df, ki, terkep, m_nev, alak = main()

    print('\nEllenőrzés…')
    jok, hibak = ellenoriz(df, ki, m_nev)
    for s in jok:   print('  ✓', s)
    for s in hibak: print('  ✗', s)

    if hibak:
        print(f'\n{len(hibak)} HIBA — nem írok ki fájlt.')
        sys.exit(1)

    KI_ANON = '/Users/lorant/Downloads/li_teszt_alnevesitett.xlsx'
    KI_MAP  = '/Users/lorant/Downloads/li_visszafejto_kulcs.xlsx'

    print(f'\nÍrás: {KI_ANON}')
    ki.to_excel(KI_ANON, index=False)

    print(f'Írás: {KI_MAP}')
    with pd.ExcelWriter(KI_MAP) as w:
        # Hallgatók: egy lapon minden, ami egy személyhez tartozik
        h = df[[NK, OA, NEV]].drop_duplicates(subset=[NK]).sort_values(NK)
        pd.DataFrame({
            'Eredeti Neptun kód':   h[NK].values,
            'Új Neptun kód':        [terkep[NK][v] for v in h[NK]],
            'Eredeti oktatási az.': h[OA].values,
            'Új oktatási az.':      [terkep[OA][v] for v in h[OA]],
            'Eredeti név':          h[NEV].values,
            'Új név':               [m_nev[v] for v in h[NK]],
        }).to_excel(w, sheet_name='Hallgatok', index=False)

        for lap, oszlop in (('Oktatok', 'Oktató (egyenként)'), ('Targynevek', TNEV),
                            ('Targykodok', TKOD), ('Kurzuskodok', KKOD),
                            ('Modulnevek', MNEV), ('Modulkodok', MKOD)):
            m = terkep[oszlop]
            pd.DataFrame({'Eredeti': list(m.keys()), 'Új': list(m.values())}) \
              .to_excel(w, sheet_name=lap, index=False)

        pd.DataFrame({
            'Beállítás': ['Véletlen mag', 'Időbélyeg-eltolás (nap)', 'Forrásfájl',
                          'Sorok száma', 'Hallgatók', 'Oktatók'],
            'Érték': [MAG, NAPELTOLAS, FORRAS, len(df),
                      df[NK].nunique(), len(terkep['Oktató (egyenként)'])],
        }).to_excel(w, sheet_name='Beallitasok', index=False)

    print('\nKÉSZ.')
