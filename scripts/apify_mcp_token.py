#!/usr/bin/env python3
"""
apify_mcp_token.py — az Apify MCP-szerver bekötése tokennel.

MIÉRT SZKRIPT: a ~/.claude.json nagy fájl, kézzel szerkeszteni kockázatos, a
tokent pedig nem szabad se a parancssorba, se a shell-előzményekbe írni. Ez a
szkript REJTETT bekérést használ (nem látszik gépelés közben), biztonsági
másolatot készít, és csak az 'apify' bejegyzést írja át.

A TOKEN SEHOVA NEM KERÜL, csak a ~/.claude.json-be — abba a fájlba, ahol a
kliens a többi beállítást is tartja. A projekt repójába SEMMIKÉPP.

Futtatás:
    python3 scripts/apify_mcp_token.py

Visszavonás (OAuth-ra váltás vagy törlés):
    python3 scripts/apify_mcp_token.py --torol
"""
import json, os, sys, shutil, datetime, getpass

UTVONAL = os.path.expanduser('~/.claude.json')
URL = 'https://mcp.apify.com/'


def mentes(p):
    m = p + '.backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    shutil.copy2(p, m)
    return m


def main():
    if not os.path.exists(UTVONAL):
        print('Nincs meg a konfigurációs fájl:', UTVONAL); return 1

    d = json.load(open(UTVONAL))
    srv = d.setdefault('mcpServers', {})

    if '--torol' in sys.argv:
        m = mentes(UTVONAL)
        srv['apify'] = {'type': 'http', 'url': URL}   # vissza OAuth-ra
        json.dump(d, open(UTVONAL, 'w'), indent=2, ensure_ascii=False)
        print('A token eltávolítva, a bejegyzés maradt OAuth-osként.')
        print('Biztonsági másolat:', m)
        return 0

    # A környezeti változó az automatizált útvonal; enélkül rejtett bekérés.
    token = (os.environ.get('APIFY_TOKEN') or '').strip()
    if not token:
        token = getpass.getpass('Apify token (gépelés közben nem látszik): ').strip()
    if not token:
        print('Nem adtál meg tokent — nem változtattam semmit.'); return 1
    if ' ' in token or '\n' in token:
        print('A tokenben szóköz vagy sortörés van — másold be újra.'); return 1

    m = mentes(UTVONAL)
    srv['apify'] = {
        'type': 'http',
        'url': URL,
        'headers': {'Authorization': 'Bearer ' + token},
    }
    json.dump(d, open(UTVONAL, 'w'), indent=2, ensure_ascii=False)
    os.chmod(UTVONAL, 0o600)

    # Ellenőrzés — a tokent NEM írjuk ki, csak a hosszát és a szerkezetet.
    ujra = json.load(open(UTVONAL))['mcpServers']['apify']
    fej = ujra.get('headers', {}).get('Authorization', '')
    print('Kész. Bejegyzés:', json.dumps({'type': ujra['type'], 'url': ujra['url'],
                                          'headers': {'Authorization': 'Bearer <%d karakter>' % (len(fej) - 7)}},
                                         ensure_ascii=False))
    print('Biztonsági másolat:', m)
    print('\nMost indítsd újra a klienst: Cmd+Shift+P -> Developer: Reload Window')
    return 0


if __name__ == '__main__':
    sys.exit(main())
