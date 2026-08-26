# -*- coding: utf-8 -*-
"""
A teszt-adatbázis SQL feldarabolása a Supabase SQL Editorhoz.

MIÉRT KELL
  Az egyben előállított fájl 800 kB. A SQL Editor ekkora beillesztést nem
  megbízhatóan nyel le — csendben elszállhat, és pontosan ez történt: az
  ellenőrzés 0 teszt-fiókot talált.

HOGYAN VÁG
  Csak UTASÍTÁSHATÁRON. A "do $$ ... end $$;" blokkokat nem szeli ketté;
  ha egy ilyen blokk önmagában túl nagy, a benne lévő INSERT-eket több
  külön do-blokkba osztja.

  Minden rész ÖNÁLLÓAN futtatható és idempotens, a sorrend viszont számít:
  a 2. rész a fiókokra épül, a 3. a kurzusokra.
"""
import re, sys

BE  = '/Users/lorant/Downloads/teszt_adatbazis.sql'
KI  = '/Users/lorant/Downloads/teszt_adatbazis_{n}resz.sql'
CEL = 190_000          # rész-célméret bájtban


def blokkokra(sql):
    """Utasításokra bont: a do $$...$$; blokk egyben marad."""
    ki, i, n = [], 0, len(sql)
    while i < n:
        d = sql.find('do $$', i)
        if d < 0:
            ki.append(sql[i:]); break
        if d > i:
            ki.append(sql[i:d])
        v = sql.find('end $$;', d)
        if v < 0:
            ki.append(sql[d:]); break
        ki.append(sql[d:v + 7])
        i = v + 7
    return [b for b in ki if b.strip()]


def do_blokkot_bont(blokk, meret):
    """Egy túl nagy do-blokkot több do-blokkra oszt, az INSERT-ek mentén."""
    m = re.match(r'(do \$\$.*?begin\s*\n)(.*)(\nend \$\$;)$', blokk, re.S)
    if not m:
        return [blokk]
    fej, torzs, lab = m.groups()
    # Az utasítások ";" + üres sor mentén válnak el; a deklarációt megtartjuk.
    darabok = re.split(r'(?<=;)\n(?=\s*insert into)', torzs)
    ki, akt, h = [], [], 0
    for d in darabok:
        akt.append(d); h += len(d)
        if h >= meret:
            ki.append(fej + '\n'.join(akt) + lab); akt, h = [], 0
    if akt:
        ki.append(fej + '\n'.join(akt) + lab)
    return ki


def main():
    sql = open(BE, encoding='utf-8').read()
    fej_veg = sql.index('begin;')
    fejlec  = sql[:fej_veg]

    blokkok = []
    for b in blokkokra(sql[fej_veg:]):
        if b.lstrip().startswith('do $$'):
            blokkok += do_blokkot_bont(b, CEL // 2) if len(b) > CEL else [b]
        elif len(b) > CEL:
            # Sima SQL-szöveg: utasításhatáron vágjuk. A ";" sorvégen zár,
            # és a következő utasítás új sorban kezdődik — a $$-testeket a
            # blokkokra() már kiemelte, tehát itt nincs mibe belevágni.
            reszdarabok = re.split(r'(?<=;)\n(?=[a-zA-Z-])', b)
            akt2, h2 = [], 0
            for d in reszdarabok:
                akt2.append(d); h2 += len(d)
                if h2 >= CEL:
                    blokkok.append('\n'.join(akt2)); akt2, h2 = [], 0
            if akt2:
                blokkok.append('\n'.join(akt2))
        else:
            blokkok.append(b)

    reszek, akt, h = [], [], 0
    for b in blokkok:
        akt.append(b); h += len(b)
        if h >= CEL:
            reszek.append(''.join(akt)); akt, h = [], 0
    if akt:
        reszek.append(''.join(akt))

    db = len(reszek)
    for i, r in enumerate(reszek, 1):
        fej = (fejlec.rstrip() + '\n\n'
               f'-- >>> {i}. RÉSZ a {db}-ból.\n'
               f'--     A részek SORRENDBEN futtatandók. Mindegyik idempotens,\n'
               f'--     tehát egy megismételt futtatás nem csinál kárt.\n\n')
        # A commit/begin párokat részenként lezárjuk.
        torzs = r if r.lstrip().startswith('begin;') else 'begin;\n' + r
        if not torzs.rstrip().endswith('commit;'):
            torzs = torzs.rstrip() + '\ncommit;\n'
        open(KI.format(n=i), 'w', encoding='utf-8').write(fej + torzs)
        print(f'  {i}. rész: {len(fej+torzs)/1024:.0f} kB')
    print(f'\n  összesen {db} rész')


if __name__ == '__main__':
    main()
