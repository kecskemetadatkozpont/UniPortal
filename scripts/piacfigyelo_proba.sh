#!/usr/bin/env bash
# ============================================================
# piacfigyelo_proba.sh — végigméri a betöltési láncot Apify NÉLKÜL
#
# MIÉRT: az Actor kiválasztása előtt is tudni akarjuk, hogy a lánc
#   Edge Function → mi_ingest → képernyő
# végigmegy-e. A függvény a kész köteget leképezés nélkül is fogadja, tehát
# egy kézzel írt minta elég hozzá.
#
# NEM SZENNYEZI A VALÓDI ADATOT: mindent egy külön TESZT forrásba tölt
# (alapértelmezett kulcs: teszt-forras). A valódi intézmények számai nem
# keverednek kitalált értékekkel — a végén egy kattintással törölhető.
#
# ELŐKÉSZÜLET (egyszer)
#   A felületen: Piacfigyelő → Források → Új forrás
#     Intézmény: TESZT (törölhető)
#     Csatorna:  Instagram
#     Kulcs:     teszt-forras
#
# HASZNÁLAT — a titok környezeti változóból jön, sehol nem tároljuk:
#   MI_SECRET='...' ./scripts/piacfigyelo_proba.sh
#   MI_SECRET='...' ./scripts/piacfigyelo_proba.sh teszt-forras
#
# TAKARÍTÁS UTÁNA
#   Források fül → a TESZT sor Törlés gombja (a pillanatképek és posztok
#   vele mennek), majd az SQL Editorban:
#     delete from mi.ad where intezmeny = 'TESZT (törölhető)';
# ============================================================
set -euo pipefail

PROJEKT="${MI_PROJEKT:-mdccyastwhzwtyukxlpk}"
URL="https://${PROJEKT}.supabase.co/functions/v1/market-intel-fetch"
FORRAS="${1:-teszt-forras}"

if [ -z "${MI_SECRET:-}" ]; then
  echo "HIÁNYZIK a MI_SECRET. Így futtasd:" >&2
  echo "  MI_SECRET='<a Supabase-be felvett MI_WEBHOOK_SECRET>' $0" >&2
  exit 1
fi

MA=$(date +%F)
HET=$(date -v-monday +%F 2>/dev/null || date -d 'last monday' +%F)

echo "== 1. A TERV — mit vár a rendszer (csak olvas) =="
curl -sS -X GET "${URL}?terv=1" -H "x-mi-secret: ${MI_SECRET}" \
  | python3 -c 'import sys,json
v=json.load(sys.stdin)
# A hibát KIMONDJUK: rossz titoknál a válasz {"error":"forbidden"}, és ha ezt
# csak üres listának néznénk, a szkript „0 aktív forrást" írna — az pedig
# egészen más hibára terelne.
if "error" in v:
    print("  HIBA:", v["error"])
    print("  (forbidden = rossz vagy hiányzó MI_SECRET)")
    raise SystemExit(1)
t=v.get("terv") or []
print(f"  {len(t)} aktív forrás:")
for s in t[:20]:
    print("   -", s["kulcs"], "·", s["intezmeny"], "·", s["platform"])
if not t:
    print("  (üres — lefutott a 114-es szkript?)")
    raise SystemExit(1)'

echo
echo "== 2. MINTAKÖTEG betöltése a(z) ${FORRAS} forrásba =="
KOTEG=$(cat <<JSON
{
  "forras": "${FORRAS}",
  "pillanatkep": { "nap": "${MA}", "kovetok": 1234, "poszt_db": 2, "bevonas": 310 },
  "posztok": [
    { "kulso_id": "teszt-1", "kelt": "${MA}T09:00:00Z", "formatum": "reel",
      "nyelv": "en", "bevonas": 210, "tema": "tandij",
      "url": "https://example.org/teszt-1" },
    { "kulso_id": "teszt-2", "kelt": "${MA}T10:00:00Z", "formatum": "kep",
      "nyelv": "hu", "bevonas": 100, "tema": "diakelet",
      "url": "https://example.org/teszt-2" }
  ],
  "hirdetesek": [
    { "kulso_id": "teszt-ad-1", "platform": "facebook", "intezmeny": "TESZT (törölhető)",
      "elso_latas": "${MA}", "utolso_latas": "${MA}",
      "orszagok": ["Nigeria", "India"], "tema": "osztondij",
      "landing_url": "https://example.org/apply",
      "kreativ": "TESZT hirdetés — nem valódi kampány" }
  ],
  "trend": [
    { "orszag": "Nigeria", "kulcsszo": "study in hungary", "het": "${HET}", "ertek": 68 }
  ],
  "ures": false
}
JSON
)
curl -sS -X POST "${URL}" \
  -H "x-mi-secret: ${MI_SECRET}" \
  -H 'content-type: application/json' \
  -d "${KOTEG}" \
  | python3 -c 'import sys,json
v=json.load(sys.stdin)
if v.get("ok"):
    print("  OK — betöltve:", (v.get("eredmeny") or {}).get("tetel_db"), "tétel, mód:", v.get("mod"))
else:
    print("  HIBA:", json.dumps(v, ensure_ascii=False)[:500])
    raise SystemExit(1)'

echo
echo "== 3. MIT NÉZZ MEG A FELÜLETEN =="
echo "  Piacfigyelő → Áttekintés: a Részesedés kártyán szám, az idősoron oszlop"
echo "  → Versenytársak: TESZT (törölhető) sor, 1234 követő, 2 poszt"
echo "  → Hirdetések: egy 'TESZT hirdetés' kártya Nigeria/India címkével"
echo "  → Országok: Nigeria sorban kereslet 68"
echo
echo "  TAKARÍTÁS: Források fül → TESZT sor Törlés, majd SQL Editorban:"
echo "    delete from mi.ad where intezmeny = 'TESZT (törölhető)';"
