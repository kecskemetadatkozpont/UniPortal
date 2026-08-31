#!/bin/zsh
# ============================================================================
#  replika_ujraepites.sh — a helyi Postgres mérőreplika újraépítése
# ============================================================================
#  MIÉRT VAN: a fejlesztés közben minden állítást a valódi sémán mérünk, nem
#  fejből állítunk. A replika eddig /tmp/upg2 alatt élt — a macOS viszont
#  gépindításkor kiüríti a /tmp-t, és a replika nyomtalanul eltűnt. Ezért
#  költözik a HOME alá: ~/.uniportal-replica.
#
#  Használat:   ./tools/replika_ujraepites.sh          (teljes újraépítés)
#               ./tools/replika_ujraepites.sh start    (csak indítás)
#               ./tools/replika_ujraepites.sh stop
#
#  A csatlakozás ezután:   psql -h ~/.uniportal-replica/sock -U postgres -d vtest
# ============================================================================
set -e
export PATH=/opt/homebrew/opt/postgresql@16/bin:$PATH

GYOKER="$HOME/.uniportal-replica"
ADAT="$GYOKER/data"
SOCK="$GYOKER/sock"
NAPLO="$GYOKER/postgres.log"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LETOLT="$HOME/Downloads"

indit() {
  mkdir -p "$SOCK"
  pg_ctl -D "$ADAT" -l "$NAPLO" -o "-k $SOCK -h ''" start
  for i in $(seq 1 30); do
    pg_isready -h "$SOCK" -q && return 0
    sleep 0.4
  done
  echo "A szerver nem indult el. Napló: $NAPLO" >&2; exit 1
}

leallit() { pg_ctl -D "$ADAT" stop -m fast 2>/dev/null || true; }

case "${1:-teljes}" in
  start) indit; echo "Fut: $SOCK"; exit 0 ;;
  stop)  leallit; echo "Leállítva"; exit 0 ;;
esac

echo "== 1/5  Régi példány eltakarítása =="
leallit
rm -rf "$GYOKER"
mkdir -p "$ADAT" "$SOCK"

echo "== 2/5  initdb =="
initdb -D "$ADAT" -U postgres --encoding=UTF8 --locale=C >/dev/null
indit
createdb -h "$SOCK" -U postgres vtest

Q() { psql -h "$SOCK" -U postgres -d vtest -v ON_ERROR_STOP=1 -q "$@"; }

echo "== 3/5  Supabase-utánzat (auth, storage, sémák) =="
Q -f "$REPO/tools/sb_stub.sql"

echo "== 4/5  Migrációk =="
# A sorrend SZÁMOZÁS SZERINTI, a 18a/18b/18c betűs tagolásával együtt.
# A RUN_ALL_* fájlokat kihagyjuk: azok ugyanezeknek a kötegei, és kétszer
# lefuttatva csak zajt adnának (idempotensek, de fölöslegesen).
for f in $(ls "$REPO"/supabase/*.sql \
           | grep -vE '/(RUN_ALL_|00_setup_all|DIAG_|TESZT_)' \
           | sort -t/ -k9 -V); do
  printf '   %-42s' "$(basename $f)"
  if Q -f "$f" >/dev/null 2>"$GYOKER/hiba.txt"; then echo "ok"
  else echo "HIBA"; head -3 "$GYOKER/hiba.txt" | sed 's/^/      /'; fi
done

echo "== 5/5  Tesztadat =="
for r in 1 2 3 4 5; do
  F="$LETOLT/teszt_adatbazis_${r}resz.sql"
  [ -f "$F" ] || continue
  printf '   %-42s' "$(basename $F)"
  Q -f "$F" >/dev/null 2>&1 && echo "ok" || echo "HIBA"
done
[ -f "$REPO/tools/claude_teszt_fiok.sql" ] && Q -f "$REPO/tools/claude_teszt_fiok.sql" >/dev/null 2>&1 || true
[ -f "$REPO/tools/teszt_fiokok_javitas.sql" ] && Q -f "$REPO/tools/teszt_fiokok_javitas.sql" >/dev/null 2>&1 || true

echo
psql -h "$SOCK" -U postgres -d vtest -qtA -c "
select '  profil: '||count(*) from public.profiles
union all select '  kurzus: '||count(*)::text from echo.course
union all select '  beiratkozas: '||count(*)::text from echo.enrollment
union all select '  kampany: '||count(*)::text from echo.campaign
union all select '  kollegiumi epulet: '||count(*)::text from dorm.building"
echo
echo "KÉSZ.  psql -h $SOCK -U postgres -d vtest"
