// ============================================================
// grants-ai — szolgáltató-független modellréteg a pályázati modulhoz
//
// MIÉRT EGY RÉTEG: az indulás Gemini-kulccsal történik, a későbbi váltás
// Claude-ra ne átírás legyen, hanem beállítás. Ezért a függvény EGYETLEN belső
// szerződést tart: bemenet egy feladattípus + egy adatcsomag + egy JSON-séma,
// kimenet a sémának megfelelő objektum. A szolgáltatót és a modellt a hívó
// (vagy később a grants.setting) adja meg.
//
// AMIT SOSEM KÜLD EL: e-mail, születési adat, bér- vagy HR-adat, ECHO-eredmény,
// hallgatói adat. A promptba csak az kerül, amit a hívó átad — ezért a hívó
// oldalon (RPC/Edge Function) kell szűrni, és ezt a modul úgy építjük, hogy a
// szűrés ott meg is történjen.
//
// FELADATOK
//   { "feladat": "illesztes_indoklas", "adat": {...} }  — miért illik egy
//        felhívás egy kutatóra: erősségek, hiányok, javasolt szerep, kockázat
//   { "feladat": "kutatoi_portre", "adat": {...} }      — egy bekezdés angol
//        kutatói portré a publikációs adatokból (PISZKOZAT, a kutató hagyja jóvá)
//   { "feladat": "partner_level", "adat": {...} }       — angol partnerkereső
//        levél piszkozata
//
// MÉRŐMÓDOK (kulcs- és modellellenőrzéshez, tartalomgenerálás nélkül)
//   { "probe": "modellek" } — mely modellek érhetők el a beállított kulccsal
//   { "probe": "teszt" }    — egyetlen rövid, strukturált válasz kérése
//
// Titkok: GEMINI_API_KEY és/vagy ANTHROPIC_API_KEY (Supabase secret).
// Deploy:  supabase functions deploy grants-ai
// ============================================================
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const CRON_SECRET = Deno.env.get('GRANTS_CRON_SECRET') ?? '';

const GEMINI_KEY = Deno.env.get('GEMINI_API_KEY') ?? '';
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';

// Alapértelmezett modellek. NEM végleges döntés: a hívó felülírhatja, és a
// modellnevek gyorsabban változnak, mint ahogy migrációt írunk — ezért van a
// { "probe": "modellek" } mérőmód, ami megmondja, mi érhető el ma.
// Alapértelmezett: gemini-3.5-flash. Mérve 2026-09-24-én ezen a kulcson
// hibátlanul válaszol strukturált sémával (ahogy a gemini-2.5-flash és a
// gemini-3.8-flash is). A beállításból felülírható.
const GEMINI_ALAP = Deno.env.get('GRANTS_GEMINI_MODEL') ?? 'gemini-3.5-flash';
const ANTHROPIC_ALAP = Deno.env.get('GRANTS_ANTHROPIC_MODEL') ?? 'claude-sonnet-5';

/* ---------- feladatok: rendszerutasítás + válaszséma ---------- */
const FELADATOK: Record<string, { utasitas: string; sema: unknown }> = {
  illesztes_indoklas: {
    utasitas:
      'Te egy egyetemi pályázati iroda szakértő munkatársa vagy. Egy kutató szakmai profilját és egy '
      + 'pályázati felhívás adatait kapod. Mondd meg, MIÉRT illik vagy nem illik a kettő egymáshoz. '
      + 'Csak a megadott adatokra támaszkodj: ne találj ki publikációt, infrastruktúrát vagy határidőt. '
      + 'A jogosultságról NE nyilatkozz — azt szabály dönti el. Magyarul válaszolj, tárgyilagosan.',
    sema: {
      type: 'object',
      properties: {
        illeszkedes: { type: 'string', enum: ['erős', 'közepes', 'gyenge'] },
        indoklas: { type: 'string' },
        erossegek: { type: 'array', items: { type: 'string' } },
        hianyok: { type: 'array', items: { type: 'string' } },
        javasolt_szerep: { type: 'string', enum: ['koordinátor', 'partner', 'munkacsomag-vezető', 'nem javasolt'] },
        kockazat: { type: 'string' },
      },
      required: ['illeszkedes', 'indoklas', 'erossegek', 'hianyok', 'javasolt_szerep', 'kockazat'],
    },
  },
  kutatoi_portre: {
    utasitas:
      'Te tudományos szakmai szövegíró vagy. Egy kutató publikációs adataiból írj egy bekezdéses, '
      + 'angol nyelvű szakmai portrét, amit pályázati partnerkeresésben lehet használni. Csak a megadott '
      + 'adatokra támaszkodj. Ne írj méltató jelzőket és ne becsüld meg a kutató „színvonalát".',
    sema: {
      type: 'object',
      properties: {
        portre_en: { type: 'string' },
        kulcsfogalmak: { type: 'array', items: { type: 'string' } },
      },
      required: ['portre_en', 'kulcsfogalmak'],
    },
  },
  partner_level: {
    utasitas:
      'Te egy egyetemi pályázati iroda munkatársa vagy. Írj rövid, tárgyilagos angol partnerkereső '
      + 'levelet: mit tud az egyetem, mit keres, és mi a következő lépés. Semmit ne ígérj, amit az adat '
      + 'nem támaszt alá.',
    sema: {
      type: 'object',
      properties: {
        targy: { type: 'string' },
        level_en: { type: 'string' },
      },
      required: ['targy', 'level_en'],
    },
  },
  teszt: {
    utasitas: 'Ellenőrző hívás. Válaszolj a sémának megfelelően, magyarul.',
    sema: {
      type: 'object',
      properties: { rendben: { type: 'boolean' }, uzenet: { type: 'string' } },
      required: ['rendben', 'uzenet'],
    },
  },
};

/* ---------- Gemini ---------- */
async function geminiHivas(model: string, utasitas: string, prompt: string, sema: unknown) {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`;
  const valasz = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-goog-api-key': GEMINI_KEY },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: utasitas }] },
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      // A strukturált válasz KÉRÉS, nem remény: így a felület mezőnként tud
      // megjeleníteni, és a szabad szöveg nem tud állapotot felülírni.
      generationConfig: { responseMimeType: 'application/json', responseSchema: sema, temperature: 0.2 },
    }),
  });
  const nyers = await valasz.text();
  if (!valasz.ok) throw new Error(`Gemini ${valasz.status}: ${nyers.slice(0, 400)}`);
  const d = JSON.parse(nyers);
  const szoveg = d?.candidates?.[0]?.content?.parts?.map((p: { text?: string }) => p.text ?? '').join('') ?? '';
  const hasznalat = d?.usageMetadata ?? {};
  return { szoveg, tokenek: { be: hasznalat.promptTokenCount ?? null, ki: hasznalat.candidatesTokenCount ?? null } };
}

/* ---------- Anthropic (Claude) ---------- */
async function anthropicHivas(model: string, utasitas: string, prompt: string, sema: unknown) {
  const valasz = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': ANTHROPIC_KEY,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model,
      max_tokens: 2048,
      temperature: 0.2,
      system: utasitas + '\n\nKIZÁRÓLAG egyetlen JSON objektummal válaszolj, e séma szerint: '
              + JSON.stringify(sema),
      messages: [{ role: 'user', content: prompt }],
    }),
  });
  const nyers = await valasz.text();
  if (!valasz.ok) throw new Error(`Anthropic ${valasz.status}: ${nyers.slice(0, 400)}`);
  const d = JSON.parse(nyers);
  const szoveg = (d?.content ?? []).map((c: { text?: string }) => c.text ?? '').join('');
  return { szoveg, tokenek: { be: d?.usage?.input_tokens ?? null, ki: d?.usage?.output_tokens ?? null } };
}

/* A modell válasza néha kódkerítésben jön; ezt le kell hámozni, mielőtt
   JSON-ként értelmezzük. Ha mégsem értelmezhető, NEM tippelünk: hibát adunk,
   és a hívó a számított pontszámmal működik tovább. */
function jsonBol(szoveg: string) {
  const t = szoveg.trim().replace(/^```(?:json)?\s*/i, '').replace(/```$/i, '').trim();
  return JSON.parse(t);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ hiba: 'Csak POST.' }, 405);

  let test: Record<string, unknown> = {};
  try { test = await req.json(); } catch { /* üres törzs is jó */ }

  // --- ki hívhatja: pályázati irodai jog VAGY az ütemező titka ---
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  const utemezo = CRON_SECRET !== '' && (req.headers.get('x-grants-cron') ?? '') === CRON_SECRET;
  if (!utemezo) {
    if (!token) return json({ hiba: 'Hiányzó Authorization fejléc.' }, 401);
    const hivo = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data, error } = await hivo.rpc('grants_context');
    if (error) return json({ hiba: 'A jogosultság nem ellenőrizhető: ' + error.message }, 401);
    if (!data || data.kezelo !== true) {
      return json({ hiba: 'Ehhez pályázati irodai jogosultság kell (grants_office).' }, 403);
    }
  }

  const szolgaltato = String(test.szolgaltato ?? 'gemini');
  const kulcsVan = szolgaltato === 'anthropic' ? ANTHROPIC_KEY !== '' : GEMINI_KEY !== '';
  const model = String(test.model ?? (szolgaltato === 'anthropic' ? ANTHROPIC_ALAP : GEMINI_ALAP));

  // --- mérőmód: milyen modellek érhetők el a beállított kulccsal ---
  if (test.probe === 'modellek') {
    if (szolgaltato !== 'gemini') return json({ hiba: 'A modell-lista jelenleg csak Geminire kérdezhető.' }, 400);
    if (!GEMINI_KEY) return json({ ok: false, hiba: 'Nincs beállítva GEMINI_API_KEY secret.' }, 500);
    const v = await fetch('https://generativelanguage.googleapis.com/v1beta/models', {
      headers: { 'x-goog-api-key': GEMINI_KEY },
    });
    const nyers = await v.text();
    if (!v.ok) return json({ ok: false, hiba: `Gemini ${v.status}: ${nyers.slice(0, 300)}` }, 502);
    const d = JSON.parse(nyers);
    const modellek = (d.models ?? [])
      .filter((m: { supportedGenerationMethods?: string[] }) =>
        (m.supportedGenerationMethods ?? []).includes('generateContent'))
      .map((m: { name: string; displayName?: string; inputTokenLimit?: number }) => ({
        nev: String(m.name).replace(/^models\//, ''),
        megnevezes: m.displayName ?? null,
        bemeneti_korlat: m.inputTokenLimit ?? null,
      }));
    return json({ ok: true, szolgaltato: 'gemini', kulcs_mukodik: true,
                  modell_db: modellek.length, alapertelmezett: GEMINI_ALAP, modellek });
  }

  // --- tényleges feladat ---
  const feladatKulcs = String(test.probe === 'teszt' ? 'teszt' : (test.feladat ?? ''));
  const feladat = FELADATOK[feladatKulcs];
  if (!feladat) {
    return json({ hiba: 'Ismeretlen feladat: "' + feladatKulcs + '". Lehetséges: '
                        + Object.keys(FELADATOK).join(', ') }, 400);
  }
  if (!kulcsVan) {
    return json({ ok: false, hiba: `Nincs beállítva a ${szolgaltato === 'anthropic'
      ? 'ANTHROPIC_API_KEY' : 'GEMINI_API_KEY'} secret.` }, 500);
  }

  const prompt = test.probe === 'teszt'
    ? 'Válaszolj annyit, hogy a kapcsolat rendben van.'
    : JSON.stringify(test.adat ?? {}, null, 1);

  const kezdet = Date.now();
  try {
    const r = szolgaltato === 'anthropic'
      ? await anthropicHivas(model, feladat.utasitas, prompt, feladat.sema)
      : await geminiHivas(model, feladat.utasitas, prompt, feladat.sema);
    let eredmeny: unknown;
    try {
      eredmeny = jsonBol(r.szoveg);
    } catch (_e) {
      return json({ ok: false, szolgaltato, model,
        hiba: 'A modell válasza nem volt értelmezhető JSON.',
        nyers: r.szoveg.slice(0, 500), masodperc: Math.round((Date.now() - kezdet) / 1000) }, 502);
    }
    return json({ ok: true, szolgaltato, model, feladat: feladatKulcs,
                  tokenek: r.tokenek, masodperc: Math.round((Date.now() - kezdet) / 1000),
                  eredmeny });
  } catch (e) {
    const uzenet = e instanceof Error ? e.message : String(e);
    return json({ ok: false, szolgaltato, model, hiba: uzenet,
                  masodperc: Math.round((Date.now() - kezdet) / 1000) }, 502);
  }
});
