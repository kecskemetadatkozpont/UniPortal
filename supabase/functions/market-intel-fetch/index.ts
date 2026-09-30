// ============================================================
// market-intel-fetch — a piacfigyelő betöltője (112_market_intel.sql)
//
// MIÉRT EDGE FUNCTION: a betöltés nem felhasználói művelet, és a service_role
// kulcs soha nem kerülhet a böngészőbe. A mi sémába írni csak a service_role
// tud (public.mi_ingest), a felület pedig csak olvasni tud a mi_* RPC-ken.
//
// HOGYAN HÍVJUK
//   1. APIFY WEBHOOK (ez a szokásos): az Actor futás végén meghívja ezt az
//      URL-t. A törzsből a defaultDatasetId kell; a függvény onnan tölti le a
//      tételeket az Apify API-ról, leképezi és beírja.
//        POST .../market-intel-fetch?kulcs=<MI_WEBHOOK_SECRET>&forras=<mi.source.kulcs>
//        { "eventType": "ACTOR.RUN.SUCCEEDED",
//          "resource": { "defaultDatasetId": "abc123", "actId": "..." } }
//
//   2. KÉSZ KÖTEG (teszthez, más gyűjtőhöz): a kanonikus alakot közvetlenül
//      átadjuk, leképezés nélkül.
//        { "forras": "obuda-instagram", "pillanatkep": {...}, "posztok": [...] }
//
//   3. TERV LEKÉRÉSE (az Actor beállításához): GET ...?kulcs=...&terv=1
//      → mit figyelünk, milyen címen, milyen mezőtérképpel.
//
// MEZŐTÉRKÉP — EZ A LÉNYEG
//   Nem tudjuk előre, melyik Apify Actort választjuk, és mindegyik más
//   mezőneveket ad. Ezért a leképezés ADAT, nem kód: a mi.source.mezo_terkep
//   jsonb mondja meg, melyik Actor-mező melyik kanonikus mezőnk.
//     { "kovetok": "followersCount", "bevonas": "likesCount", "kelt": "timestamp" }
//   Ha nincs térkép, az alábbi ALIAS-listák próbálkoznak. Ami egyikkel sem
//   megy, az null marad — TALÁLGATNI NEM SZABAD, a hiányzó adat jobb, mint a
//   kitalált.
//
// TITKOK (Supabase secretbe, kódba SOHA)
//   APIFY_TOKEN         — az Apify személyes API tokenje
//   MI_WEBHOOK_SECRET   — amit a webhook URL-jébe teszünk (?kulcs=...)
//
// Deploy: supabase functions deploy market-intel-fetch --no-verify-jwt
//         (a --no-verify-jwt azért kell, mert az Apify nem küld Supabase JWT-t;
//          a hívót a MI_WEBHOOK_SECRET azonosítja)
// ============================================================
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { kotegKeszit, csoportosit } from './terkep.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-mi-secret',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  ?? Deno.env.get('SUPABASE_SECRET_KEY') ?? '';
// A titok nevét kézzel veszik fel a felületen, és a Deno env KIS-NAGYBETŰ-
// ÉRZÉKENY: az 'APIFY_Token' néven felvett titkot az 'APIFY_TOKEN' olvasás
// csendben undefined-ként kapná, és a betöltés „hiányzik a token" hibával
// állna meg. Ezért több írásmódot is elfogadunk — élesben pont ez történt.
const APIFY_TOKEN = Deno.env.get('APIFY_TOKEN')
  ?? Deno.env.get('APIFY_Token')
  ?? Deno.env.get('APIFY_API_TOKEN')
  ?? Deno.env.get('apify_token') ?? '';
const WEBHOOK_SECRET = Deno.env.get('MI_WEBHOOK_SECRET')
  ?? Deno.env.get('MI_Webhook_Secret') ?? '';

// A LEKÉPEZÉS külön modulban él, mert az tesztelhető hálózat nélkül:
// scripts/terkep_proba.mjs valódi alakú Actor-mintákkal futtatja.
async function apifyTetelek(datasetId: string): Promise<Record<string, unknown>[]> {
  if (!APIFY_TOKEN) throw new Error('Hiányzik az APIFY_TOKEN secret.');
  const url = `https://api.apify.com/v2/datasets/${encodeURIComponent(datasetId)}/items`
    + `?token=${encodeURIComponent(APIFY_TOKEN)}&clean=true&format=json&limit=1000`;
  const r = await fetch(url, { headers: { accept: 'application/json' } });
  if (!r.ok) throw new Error(`Apify dataset HTTP ${r.status}`);
  const j = await r.json();
  return Array.isArray(j) ? j : [];
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const u = new URL(req.url);
  // A titkot kézzel másolják be a Supabase felületén és a webhook URL-jébe.
  // Egy odaragadt sortörés vagy szóköz miatt a szigorú egyenlőség 403-at ad,
  // és a hiba semmit nem árul el arról, hogy MIÉRT — ezért mindkét oldalt
  // levágjuk. A titok így sem lesz gyengébb, csak a gépelés bocsánatosabb.
  const titok = (req.headers.get('x-mi-secret') ?? u.searchParams.get('kulcs') ?? '').trim();
  const vart = WEBHOOK_SECRET.trim();
  if (!vart || titok !== vart) {
    // A válasz szándékosan szűkszavú kívülről, de a naplóban látszik, melyik
    // eset állt elő — enélkül a hibakeresés találgatás.
    console.log(vart
      ? `market-intel: rossz titok (kapott ${titok.length}, várt ${vart.length} karakter)`
      : 'market-intel: NINCS beállítva MI_WEBHOOK_SECRET');
    return json({ error: 'forbidden' }, 403);
  }
  if (!SUPABASE_URL || !SERVICE_KEY) return json({ error: 'nincs service kulcs' }, 500);
  const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

  // A terv: mit figyelünk, milyen címen, milyen mezőtérképpel.
  if (u.searchParams.get('terv')) {
    const { data, error } = await sb.rpc('mi_ingest_plan');
    if (error) return json({ error: error.message }, 500);
    return json({ terv: data });
  }

  let torzs: Record<string, unknown> = {};
  try { torzs = await req.json(); } catch { torzs = {}; }

  // 2. eset: kész köteg.
  if (torzs.forras && (torzs.posztok || torzs.pillanatkep || torzs.hirdetesek || torzs.web || torzs.trend)) {
    const { data, error } = await sb.rpc('mi_ingest', { p: torzs });
    if (error) return json({ error: error.message }, 400);
    await sb.rpc('mi_detect_alerts');
    return json({ ok: true, mod: 'kesz-koteg', eredmeny: data });
  }

  // 1. eset: Apify webhook. Kétféleképp címezhető:
  //   ?forras=obuda-instagram   — EGY forrás (egy profil egy futásban)
  //   ?platform=instagram       — a platform MINDEN aktív forrása egy futásból;
  //                               a tételeket a kezelőnevük alapján osztjuk szét.
  // A második azért van, mert forrásonként külön futással 13 Apify-feladatot
  // és 13 ütemezést kellene kézzel karbantartani.
  const forrasKulcs = String(torzs.forras ?? u.searchParams.get('forras') ?? '');
  const platform = String(u.searchParams.get('platform') ?? torzs.platform ?? '');
  if (!forrasKulcs && !platform) {
    return json({ error: 'hiányzik a cím: ?forras=<kulcs> vagy ?platform=<instagram|tiktok|facebook|ads|web|trends>' }, 400);
  }

  const resource = (torzs.resource ?? {}) as Record<string, unknown>;
  const datasetId = String(resource.defaultDatasetId ?? torzs.datasetId ?? u.searchParams.get('dataset') ?? '');
  if (!datasetId) return json({ error: 'hiányzik a defaultDatasetId' }, 400);

  const { data: terv, error: tervHiba } = await sb.rpc('mi_ingest_plan');
  if (tervHiba) return json({ error: tervHiba.message }, 500);
  const mind = (terv as Record<string, string>[]) ?? [];

  const celok = forrasKulcs
    ? mind.filter(x => x.kulcs === forrasKulcs)
    : mind.filter(x => x.platform === platform);
  if (celok.length === 0) {
    return json({ error: forrasKulcs ? `ismeretlen forrás: ${forrasKulcs}` : `nincs aktív forrás erre: ${platform}` }, 400);
  }

  try {
    const tetelek = await apifyTetelek(datasetId);
    const { csoportok, arvak } = csoportosit(celok as never, tetelek);

    const eredmeny: Record<string, unknown>[] = [];
    for (const cs of csoportok) {
      // Amelyik forráshoz semmi nem jött, az ÜRES futást kap: így két nap
      // után riasztás lesz belőle, nem néma nulla a grafikonon.
      const koteg = kotegKeszit(cs.forras, cs.tetelek);
      const { data, error } = await sb.rpc('mi_ingest', { p: koteg });
      eredmeny.push({ forras: cs.forras.kulcs, tetel: cs.tetelek.length,
                      ok: !error, hiba: error ? error.message : undefined,
                      betoltve: data });
    }
    await sb.rpc('mi_detect_alerts');

    // Az árva tételeket KIMONDJUK: egy elgépelt cím így azonnal látszik,
    // nem három hét múlva egy üres oszlopból.
    return json({
      ok: eredmeny.every(x => x.ok), mod: 'apify', tetel: tetelek.length,
      forrasok: eredmeny,
      arva: arvak.length,
      arva_minta: arvak.slice(0, 3).map(x => ({
        username: (x as Record<string, unknown>).username ?? null,
        url: (x as Record<string, unknown>).url ?? null,
      })),
    });
  } catch (e) {
    // Ez a fetch-hiba ága: a gyűjtő nem ért el hozzánk adatot. Minden célzott
    // forrást üres futással jelölünk, hogy a némaság látszódjon.
    for (const cs of celok) {
      await sb.rpc('mi_ingest', { p: { forras: cs.kulcs, ures: true } }).catch(() => {});
    }
    return json({ error: String((e as Error).message ?? e) }, 502);
  }
});
