// ============================================================
// parser.js — az EU referencia-állomány FOLYAMATOS feldolgozása
//
// MIÉRT SAJÁT PARSZER: a forrásállomány 2026-09-23-án 130 MB volt, 11 162
// tétellel. Ezt egészben memóriába olvasni egy Edge Functionben nem járható:
// ezért a fájlt darabokban olvassuk, és a `GrantTenderObj` tömb elemeit
// egyenként vágjuk ki egy zárójel-mélységet követő szkennerrel. A memória így
// egyetlen tételnyi + egy darabnyi, nem 130 MB.
//
// MIÉRT KÜLÖN FÁJL, ÉS MIÉRT .js: ez a fájl a modul legkockázatosabb része
// (string-határok, escape-elés, darabhatáron félbevágott objektum), ezért
// tesztelhetőnek kell lennie. Így Node-ból is futtatható teszt nélkül
// fordítási lépés, és a Deno is közvetlenül importálja.
// ============================================================

/** Ennyi napra visszamenőleg hozzuk be a LEZÁRT felhívásokat is. */
export const FRISS_ZART_NAP = 90;

/** A portál nyilvános témalapja — a felhívás leírása ott olvasható. */
export const TOPIC_URL =
  'https://ec.europa.eu/info/funding-tenders/opportunities/portal/screen/opportunities/topic-details/';

/**
 * Darabokban érkező JSON-ból kivágja a GrantTenderObj tömb elemeit.
 * Használat: `const sz = createScanner(); for (...) out = sz.push(chunk);`
 */
export function createScanner() {
  let buf = '';
  let pos = 0;            // eddig szkenneltük a puffert
  let started = false;    // megtaláltuk-e a tömb nyitó szögletes zárójelét
  let done = false;       // a tömb véget ért
  let depth = 0;
  let objStart = -1;
  let inStr = false;
  let esc = false;
  let hibas = 0;          // értelmezhetetlen tételek száma

  return {
    get hibasDb() { return hibas; },
    get vege() { return done; },

    /** @param {string} chunk @returns {object[]} a darabban befejeződött tételek */
    push(chunk) {
      const ki = [];
      if (done) return ki;
      buf += chunk;

      if (!started) {
        const k = buf.indexOf('"GrantTenderObj"');
        if (k < 0) {
          // A kulcs még nem jött meg. Ne nőjön a puffer korlátlanul: a kulcs
          // hossza a felső korlát, amit meg kell tartanunk.
          if (buf.length > 4096) buf = buf.slice(-64);
          return ki;
        }
        const b = buf.indexOf('[', k);
        if (b < 0) return ki;
        buf = buf.slice(b + 1);
        pos = 0;
        started = true;
      }

      let i = pos;
      while (i < buf.length) {
        const ch = buf[i];
        if (inStr) {
          if (esc) esc = false;
          else if (ch === '\\') esc = true;
          else if (ch === '"') inStr = false;
          i++;
          continue;
        }
        if (ch === '"') { inStr = true; i++; continue; }
        if (ch === '{') {
          if (depth === 0) objStart = i;
          depth++;
          i++;
          continue;
        }
        if (ch === '}') {
          depth--;
          if (depth === 0 && objStart >= 0) {
            const szoveg = buf.slice(objStart, i + 1);
            try {
              ki.push(JSON.parse(szoveg));
            } catch (_e) {
              hibas++;   // egy hibás tétel ne buktassa el az egész futást
            }
            buf = buf.slice(i + 1);
            i = 0;
            pos = 0;
            objStart = -1;
            continue;
          }
          i++;
          continue;
        }
        if (ch === ']' && depth === 0) { done = true; buf = ''; pos = 0; return ki; }
        i++;
      }

      pos = buf.length;
      // Memóriakorlát: a félbevágott tételt megtartjuk, az előtte lévő
      // vesszőket és szóközöket eldobjuk.
      if (depth > 0 && objStart > 0) {
        buf = buf.slice(objStart);
        pos = buf.length;
        objStart = 0;
      } else if (depth === 0) {
        buf = '';
        pos = 0;
      }
      return ki;
    },
  };
}

/** Az EU-állapotból a katalógus állapota. */
export function allapotra(abbr) {
  switch (abbr) {
    case 'Open': return 'nyitott';
    case 'Forthcoming': return 'hamarosan';
    case 'Closed': return 'zart';
    default: return 'ismeretlen';
  }
}

/**
 * Betöltjük-e ezt a tételt?
 *  • csak PÁLYÁZAT (type === 1) — a type 0 közbeszerzés, 2026-09-23-án 999 db,
 *    és kutatói pályázatfigyelésben csak zajt csinálna;
 *  • nyitott vagy hamarosan nyíló — ez a haszon;
 *  • nemrég lezárt is: enélkül egy nálunk nyitottként betöltött felhívás
 *    örökre nyitott maradna, mert a lezárt tételek kimaradnának a kötegből.
 */
export function kell(o, mostMs = Date.now(), frissZartNap = FRISS_ZART_NAP) {
  if (!o || o.type !== 1) return false;
  const st = o.status && o.status.abbreviation;
  if (st === 'Open' || st === 'Forthcoming') return true;
  if (st !== 'Closed') return false;
  const hat = (o.deadlineDatesLong || []).filter((h) => typeof h === 'number');
  if (!hat.length) return false;
  return Math.max(...hat) >= mostMs - frissZartNap * 86400000;
}

const iso = (ms) => (typeof ms === 'number' && ms > 0 ? new Date(ms).toISOString() : null);

/** Egy EU-tétel → a grants_call_upsert mezőkészlete. */
export function mapItem(o) {
  const hat = (o.deadlineDatesLong || [])
    .filter((h) => typeof h === 'number' && h > 0)
    .sort((a, b) => a - b)
    .map(iso);

  // A programDivision hierarchia: az UTOLSÓ elem a legpontosabb
  // (HORIZON → HORIZON.3 Innovative Europe → …).
  const div = Array.isArray(o.programmeDivision) ? o.programmeDivision : [];
  const utolsoDiv = div.length ? div[div.length - 1] : null;

  const akcio = Array.isArray(o.topicActions) && o.topicActions.length ? o.topicActions[0] : null;
  const tipus = akcio
    ? (akcio.abbreviation || akcio.description || null)
    : (((o.actions || [])[0] || {}).types || [{}])[0].typeOfAction || null;

  // Leírás NINCS ebben az állományban (a témalapon olvasható, arra hivatkozunk).
  // A címkék viszont keresésre és szűrésre használhatók, ezért azok kerülnek ide.
  const cimkek = [].concat(o.tags || [], o.keywords || []).filter((t) => typeof t === 'string');
  const kivonat = cimkek.length ? 'Címkék: ' + cimkek.slice(0, 12).join(', ') : null;

  return {
    azonosito: o.identifier,
    cim: o.title,
    program: (o.frameworkProgramme || {}).abbreviation || null,
    alprogram: utolsoDiv ? (utolsoDiv.description || utolsoDiv.abbreviation) : null,
    tipus,
    felhivas_azonosito: o.callIdentifier || null,
    felhivas_cim: o.callTitle || null,
    allapot: allapotra(o.status && o.status.abbreviation),
    nyitas: iso(o.plannedOpeningDateLong),
    hataridok: hat,
    kivonat,
    url: o.identifier ? TOPIC_URL + String(o.identifier).toLowerCase() : null,
    partnerkereses: o.allowPartnerSearch === true,
    // A nyers payloadból CSAK az értelmes rész: a latestInfos HTML-hírfolyama
    // és a links tömb tételenként több kilobájt, és semmit nem adnak hozzá.
    payload: {
      identifier: o.identifier,
      ccm2Id: o.ccm2Id,
      type: o.type,
      status: o.status || null,
      frameworkProgramme: o.frameworkProgramme || null,
      programmeDivision: div,
      topicActions: o.topicActions || [],
      topicMGAs: o.topicMGAs || [],
      callIdentifier: o.callIdentifier || null,
      deadlineDatesLong: o.deadlineDatesLong || [],
      plannedOpeningDateLong: o.plannedOpeningDateLong || null,
      publicationDateLong: o.publicationDateLong || null,
      tags: o.tags || [],
      keywords: o.keywords || [],
      sme: o.sme === true,
      allowPartnerSearch: o.allowPartnerSearch === true,
      _forras: 'eu_portal/grantsTenders.json',
      _betoltve: new Date().toISOString(),
    },
  };
}
