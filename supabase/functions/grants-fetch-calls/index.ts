// ============================================================
// grants-fetch-calls — az EU Funding & Tenders portál betöltése
//
// MIÉRT EDGE FUNCTION: a betöltés nem felhasználói művelet, és a service_role
// kulcs soha nem kerülhet a böngészőbe. A katalógusba írni csak a service_role
// tud (77_grants_core.sql: grants_call_upsert / grants_etl_start / _finish).
//
// A FORRÁS (2026-09-23-án mérve, kulcs nélkül, sima GET):
//   https://ec.europa.eu/info/funding-tenders/opportunities/data/referenceData/grantsTenders.json
//   130 MB, 11 162 tétel. Ebből 10 163 pályázat (type=1) és 999 közbeszerzés
//   (type=0). Nyitott 208, hamarosan nyíló 278 — plusz a 90 napon belül
//   lezártak (203), hogy a nálunk nyitottként szereplő felhívás valóban
//   zárttá váljon. Betöltendő tétel így ~689.
//
// FUTTATÁS
//   • a felületről: sb.functions.invoke('grants-fetch-calls')  — a hívó
//     jogosultságát a grants_context() dönti el (grants_office kell)
//   • ütemezőből: Authorization: Bearer <service_role kulcs>
//   • próbamenet írás nélkül:  { "dry": true }
//   • korlátozott menet:       { "max": 50 }
//
// Deploy:  supabase functions deploy grants-fetch-calls
// Titkok:  nem kell hozzá új secret (a futtatókörnyezet adja a kulcsokat).
// ============================================================
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { createScanner, kell, mapItem } from './parser.js';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const FORRAS = 'eu_portal';
const URL_ALAP = Deno.env.get('GRANTS_EU_URL')
  ?? 'https://ec.europa.eu/info/funding-tenders/opportunities/data/referenceData/grantsTenders.json';
const UA = Deno.env.get('GRANTS_USER_AGENT')
  ?? 'UniPortal-NJE-grants/1.0 (+https://nje.hu)';

// Egy köteg mérete. 200 tételnél a kérés törzse néhány száz kilobájt, a
// tranzakció rövid — egy elhasalt köteg nem visz magával 700 tételt.
const KOTEG = 200;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ hiba: 'Csak POST.' }, 405);

  let test: Record<string, unknown> = {};
  try { test = await req.json(); } catch { /* üres törzs is jó */ }
  const dry = test.dry === true;
  const max = typeof test.max === 'number' && test.max > 0 ? test.max : 0;

  // --- ki hívhatja ---
  const fejlec = req.headers.get('Authorization') ?? '';
  const token = fejlec.replace(/^Bearer\s+/i, '');
  const utemezo = token === SERVICE_KEY;

  if (!utemezo) {
    if (!token) return json({ hiba: 'Hiányzó Authorization fejléc.' }, 401);
    // A jogosultságot NEM itt találjuk ki: a grants_context() mondja meg, és az
    // ugyanazt a három szintet (szerepkör / csoport / egyéni) nézi, mint a menü.
    const hivo = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data, error } = await hivo.rpc('grants_context');
    if (error) return json({ hiba: 'A jogosultság nem ellenőrizhető: ' + error.message }, 401);
    if (!data || data.kezelo !== true) {
      return json({ hiba: 'Ehhez pályázati irodai jogosultság kell (grants_office).' }, 403);
    }
  }

  const svc = createClient(SUPABASE_URL, SERVICE_KEY);

  // --- futás nyitása ---
  let runId: number | null = null;
  if (!dry) {
    const { data, error } = await svc.rpc('grants_etl_start', { p_source: FORRAS });
    if (error) return json({ hiba: 'A futás nem indítható: ' + error.message }, 500);
    runId = data as number;
  }

  const szamok = { olvasott: 0, kivalasztott: 0, uj: 0, modosult: 0, valtozatlan: 0, hibas_tetel: 0, koteg: 0 };
  const kezdet = Date.now();

  const koteget_kuld = async (tetelek: unknown[]) => {
    if (!tetelek.length) return;
    szamok.koteg++;
    if (dry) return;
    const { data, error } = await svc.rpc('grants_call_upsert', {
      p_source: FORRAS, p_items: tetelek, p_run: runId,
    });
    if (error) throw new Error('Betöltési hiba: ' + error.message);
    szamok.uj += data?.uj ?? 0;
    szamok.modosult += data?.modosult ?? 0;
    szamok.valtozatlan += data?.valtozatlan ?? 0;
  };

  try {
    const valasz = await fetch(URL_ALAP, {
      headers: { 'User-Agent': UA, 'Accept': 'application/json', 'Accept-Encoding': 'gzip' },
    });
    if (!valasz.ok) throw new Error(`A forrás ${valasz.status} választ adott.`);
    if (!valasz.body) throw new Error('A forrás üres választ adott.');

    const olvaso = valasz.body.getReader();
    const dekoder = new TextDecoder('utf-8');
    const szkenner = createScanner();
    let puffer: unknown[] = [];
    const most = Date.now();

    while (true) {
      const { done, value } = await olvaso.read();
      if (done) break;
      const tetelek = szkenner.push(dekoder.decode(value, { stream: true }));
      for (const o of tetelek) {
        szamok.olvasott++;
        if (!kell(o, most)) continue;
        puffer.push(mapItem(o));
        szamok.kivalasztott++;
        if (max && szamok.kivalasztott >= max) break;
      }
      if (puffer.length >= KOTEG) {
        await koteget_kuld(puffer);
        puffer = [];
      }
      if (max && szamok.kivalasztott >= max) { await olvaso.cancel(); break; }
      if (szkenner.vege) break;
    }
    await koteget_kuld(puffer);
    szamok.hibas_tetel = szkenner.hibasDb;

    const reszletek = { ...szamok, masodperc: Math.round((Date.now() - kezdet) / 1000), dry, max };
    if (!dry) await svc.rpc('grants_etl_finish', { p_run: runId, p_ok: true, p_hiba: null, p_reszletek: reszletek });
    return json({ ok: true, forras: FORRAS, ...reszletek });

  } catch (e) {
    const uzenet = e instanceof Error ? e.message : String(e);
    if (!dry && runId !== null) {
      await svc.rpc('grants_etl_finish', {
        p_run: runId, p_ok: false, p_hiba: uzenet,
        p_reszletek: { ...szamok, masodperc: Math.round((Date.now() - kezdet) / 1000) },
      });
    }
    // A részeredmény megmarad: ami már betöltődött, az bent van, és a naplóban
    // látszik, hol állt meg. Így egy félbeszakadt futás nem kezdi elölről.
    return json({ ok: false, hiba: uzenet, ...szamok }, 500);
  }
});
