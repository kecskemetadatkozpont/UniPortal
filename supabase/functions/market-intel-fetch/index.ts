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

// ---- mezőnév-aliasok. Csak akkor játszanak, ha nincs mezo_terkep. ----
const ALIAS: Record<string, string[]> = {
  kovetok:   ['followersCount', 'followers', 'followersCountNumeric', 'subscriberCount', 'fans', 'likes'],
  poszt_db:  ['postsCount', 'videosCount', 'mediaCount'],
  bevonas:   ['engagement', 'engagementCount', 'totalEngagement'],
  kulso_id:  ['id', 'postId', 'videoId', 'shortCode', 'adArchiveId', 'adId'],
  kelt:      ['timestamp', 'createTime', 'publishedAt', 'date', 'postedAt'],
  url:       ['url', 'postUrl', 'webVideoUrl', 'link'],
  formatum:  ['type', 'mediaType', 'productType'],
  nyelv:     ['language', 'lang'],
  tema:      ['category', 'topic'],
  // hirdetés
  elso_latas:   ['startDate', 'adDeliveryStartTime', 'firstSeen'],
  utolso_latas: ['endDate', 'adDeliveryStopTime', 'lastSeen'],
  orszagok:     ['countries', 'targetCountries', 'reachedCountries'],
  landing_url:  ['landingUrl', 'linkUrl', 'ctaUrl'],
  kreativ:      ['adText', 'body', 'headline', 'caption', 'text'],
  // weboldal-figyelés
  mezo: ['field', 'key'],
  uj:   ['value', 'newValue', 'current'],
  regi: ['oldValue', 'previous'],
};

// Egy kanonikus mező kiolvasása: előbb a térkép, aztán az aliasok.
function mezo(item: Record<string, unknown>, nev: string, terkep: Record<string, string>): unknown {
  const kulcs = terkep && terkep[nev];
  if (kulcs && item[kulcs] !== undefined) return item[kulcs];
  for (const a of (ALIAS[nev] ?? [])) {
    if (item[a] !== undefined && item[a] !== null) return item[a];
  }
  return null;
}
const szam = (v: unknown): number | null => {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};
const szoveg = (v: unknown): string | null => {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s === '' ? null : s.slice(0, 500);
};
// Bármilyen dátumalakból ISO. Ami nem értelmezhető, az null marad.
const datum = (v: unknown): string | null => {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  // Apify gyakran másodperc-alapú epoch-ot ad (TikTok createTime).
  const d = Number.isFinite(n) && String(v).length <= 13
    ? new Date(n < 1e12 ? n * 1000 : n)
    : new Date(String(v));
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
};
const nap = (v: unknown): string | null => {
  const d = datum(v);
  return d ? d.slice(0, 10) : null;
};
const tomb = (v: unknown): string[] => {
  if (Array.isArray(v)) return v.map(x => String(x)).filter(Boolean);
  if (typeof v === 'string' && v.trim() !== '') return v.split(/[,;]/).map(x => x.trim()).filter(Boolean);
  return [];
};

// Az Actor tételeiből a 112-es szerződés szerinti köteg.
function kotegKeszit(
  forras: { kulcs: string; platform: string; intezmeny: string; mezo_terkep?: Record<string, string> },
  tetelek: Record<string, unknown>[],
) {
  const t = forras.mezo_terkep ?? {};
  const koteg: Record<string, unknown> = { forras: forras.kulcs, ures: tetelek.length === 0 };

  if (forras.platform === 'ads') {
    koteg.hirdetesek = tetelek.map(it => ({
      kulso_id: szoveg(mezo(it, 'kulso_id', t)),
      platform: szoveg(it.platform) ?? 'facebook',
      intezmeny: szoveg(it.pageName) ?? forras.intezmeny,
      elso_latas: nap(mezo(it, 'elso_latas', t)),
      utolso_latas: nap(mezo(it, 'utolso_latas', t)) ?? new Date().toISOString().slice(0, 10),
      orszagok: tomb(mezo(it, 'orszagok', t)),
      tema: szoveg(mezo(it, 'tema', t)),
      landing_url: szoveg(mezo(it, 'landing_url', t)),
      kreativ: szoveg(mezo(it, 'kreativ', t)),
    })).filter(x => x.kulso_id);
    return koteg;
  }

  if (forras.platform === 'web') {
    koteg.web = tetelek.map(it => ({
      mezo: szoveg(mezo(it, 'mezo', t)),
      regi: szoveg(mezo(it, 'regi', t)),
      uj: szoveg(mezo(it, 'uj', t)),
    })).filter(x => x.mezo && x.uj);
    return koteg;
  }

  if (forras.platform === 'trends') {
    koteg.trend = tetelek.map(it => ({
      orszag: szoveg(it.country ?? it.geo) ?? forras.orszag,
      kulcsszo: szoveg(it.keyword ?? it.term),
      het: nap(it.week ?? it.date),
      ertek: szam(it.value ?? it.index),
    })).filter(x => x.orszag && x.kulcsszo && x.het);
    return koteg;
  }

  // Közösségi oldal: egy profil-tétel + posztok. Az Actorok kétféleképp adják:
  // vagy egy profil-objektum a posztok tömbjével, vagy csak posztok.
  const profil = tetelek.find(x => mezo(x, 'kovetok', t) !== null) ?? {};
  const posztForras = Array.isArray((profil as Record<string, unknown>).latestPosts)
    ? (profil as Record<string, unknown>).latestPosts as Record<string, unknown>[]
    : tetelek.filter(x => mezo(x, 'kulso_id', t) !== null && mezo(x, 'kovetok', t) === null);

  const posztok = posztForras.map(it => {
    const like = szam(it.likesCount ?? it.diggCount ?? it.likes) ?? 0;
    const komment = szam(it.commentsCount ?? it.comments) ?? 0;
    const megoszt = szam(it.sharesCount ?? it.shareCount ?? it.shares) ?? 0;
    const sajat = szam(mezo(it, 'bevonas', t));
    return {
      kulso_id: szoveg(mezo(it, 'kulso_id', t)),
      kelt: datum(mezo(it, 'kelt', t)),
      url: szoveg(mezo(it, 'url', t)),
      formatum: szoveg(mezo(it, 'formatum', t)),
      nyelv: szoveg(mezo(it, 'nyelv', t)),
      // Ha az Actor ad kész bevonás-számot, azt visszük; különben a három
      // nyilvános szám összege. Külön-külön nem tároljuk — nem kell.
      bevonas: sajat ?? (like + komment + megoszt),
      tema: szoveg(mezo(it, 'tema', t)),
    };
  }).filter(x => x.kulso_id);

  koteg.posztok = posztok;
  const kovetok = szam(mezo(profil, 'kovetok', t));
  if (kovetok !== null || posztok.length > 0) {
    koteg.pillanatkep = {
      nap: new Date().toISOString().slice(0, 10),
      kovetok,
      poszt_db: posztok.length || szam(mezo(profil, 'poszt_db', t)),
      bevonas: posztok.reduce((a, p) => a + (p.bevonas ?? 0), 0),
    };
  }
  koteg.ures = kovetok === null && posztok.length === 0;
  return koteg;
}

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
  const titok = req.headers.get('x-mi-secret') ?? u.searchParams.get('kulcs') ?? '';
  if (!WEBHOOK_SECRET || titok !== WEBHOOK_SECRET) {
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

  // 1. eset: Apify webhook.
  const forrasKulcs = String(torzs.forras ?? u.searchParams.get('forras') ?? '');
  if (!forrasKulcs) return json({ error: 'hiányzik a forrás kulcsa (?forras=...)' }, 400);

  const resource = (torzs.resource ?? {}) as Record<string, unknown>;
  const datasetId = String(resource.defaultDatasetId ?? torzs.datasetId ?? u.searchParams.get('dataset') ?? '');
  if (!datasetId) return json({ error: 'hiányzik a defaultDatasetId' }, 400);

  const { data: terv, error: tervHiba } = await sb.rpc('mi_ingest_plan');
  if (tervHiba) return json({ error: tervHiba.message }, 500);
  const forras = (terv as Record<string, string>[] ?? []).find(x => x.kulcs === forrasKulcs);
  if (!forras) return json({ error: `ismeretlen forrás: ${forrasKulcs}` }, 400);

  try {
    const tetelek = await apifyTetelek(datasetId);
    const koteg = kotegKeszit(forras as never, tetelek);
    const { data, error } = await sb.rpc('mi_ingest', { p: koteg });
    if (error) return json({ error: error.message, koteg }, 400);
    await sb.rpc('mi_detect_alerts');
    return json({ ok: true, mod: 'apify', tetel: tetelek.length, eredmeny: data });
  } catch (e) {
    // A hibát a mi_ingest naplózza, ha odáig eljutottunk; ez a fetch-hiba ága.
    await sb.rpc('mi_ingest', { p: { forras: forrasKulcs, ures: true } }).catch(() => {});
    return json({ error: String((e as Error).message ?? e) }, 502);
  }
});
