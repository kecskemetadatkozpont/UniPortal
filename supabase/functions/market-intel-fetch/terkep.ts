// ============================================================
// terkep.ts — az Apify-kimenet leképezése a 112-es szerződésre
//
// KÜLÖN MODUL, hogy TESZTELHETŐ legyen: az index.ts hálózatot és Supabase-t
// hív, ez viszont tiszta függvény. A scripts/terkep_proba.mjs valódi alakú
// mintákkal futtatja — így nem az első éles gyűjtésnél derül ki, hogy egy
// mező máshol van, mint hittük.
//
// ALAPELV: ami nem jön meg, az null marad. Találgatni nem szabad — a kitalált
// szám rosszabb, mint a hiányzó.
// ============================================================

// A mezőnév-aliasok. Csak akkor játszanak, ha a forráshoz nincs mezo_terkep.
// A neveket a boltban közzétett kimenetek alapján vettük fel (2026-09-30).
export const ALIAS: Record<string, string[]> = {
  kovetok:   ['followersCount', 'followers', 'subscriberCount', 'fans',
              'authorMeta.fans', 'authorMeta.followers'],
  poszt_db:  ['postsCount', 'videosCount', 'mediaCount', 'authorMeta.video'],
  bevonas:   ['engagement', 'engagementCount', 'totalEngagement'],
  kulso_id:  ['id', 'postId', 'videoId', 'shortCode',
              'adArchiveId', 'adArchiveID', 'adId'],
  kelt:      ['timestamp', 'createTimeISO', 'createTime', 'publishedAt', 'time', 'date', 'postedAt'],
  url:       ['url', 'postUrl', 'webVideoUrl', 'link'],
  formatum:  ['type', 'mediaType', 'productType'],
  nyelv:     ['language', 'lang'],
  tema:      ['category', 'topic'],
  // hirdetés
  elso_latas:   ['startDateFormatted', 'startDate', 'adDeliveryStartTime', 'firstSeen'],
  utolso_latas: ['endDateFormatted', 'endDate', 'adDeliveryStopTime', 'lastSeen'],
  orszagok:     ['targetedOrReachedCountries', 'countries', 'targetCountries', 'reachedCountries'],
  landing_url:  ['snapshot.linkUrl', 'landingUrl', 'linkUrl', 'ctaUrl'],
  kreativ:      ['snapshot.body.text', 'adText', 'body', 'headline', 'caption', 'text'],
  hirdeto:      ['pageName', 'snapshot.pageName'],
  // weboldal-figyelés
  mezo: ['field', 'key'],
  uj:   ['value', 'newValue', 'current'],
  regi: ['oldValue', 'previous'],
};

// Pontozott útvonal: 'snapshot.body.text' vagy 'authorMeta.fans'. A boltban
// árult Actorok fele beágyazva adja a lényeget, és enélkül a mezőtérkép csak
// a legfelső szintre látna.
export function ut(obj: unknown, utvonal: string): unknown {
  if (!utvonal) return null;
  let cur: unknown = obj;
  for (const resz of utvonal.split('.')) {
    if (cur === null || cur === undefined || typeof cur !== 'object') return null;
    cur = (cur as Record<string, unknown>)[resz];
  }
  return cur === undefined ? null : cur;
}

export function mezo(item: Record<string, unknown>, nev: string, terkep?: Record<string, string>): unknown {
  const kulcs = terkep && terkep[nev];
  if (kulcs) {
    const v = ut(item, kulcs);
    if (v !== null && v !== undefined) return v;
  }
  for (const a of (ALIAS[nev] ?? [])) {
    const v = ut(item, a);
    if (v !== null && v !== undefined && v !== '') return v;
  }
  return null;
}

export const szam = (v: unknown): number | null => {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};
export const szoveg = (v: unknown): string | null => {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s === '' ? null : s.slice(0, 500);
};
// Bármilyen dátumalakból ISO. Ami nem értelmezhető, az null marad.
export const datum = (v: unknown): string | null => {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  // A TikTok createTime MÁSODPERC alapú epoch; ezredmásodpercre váltjuk.
  const d = Number.isFinite(n) && String(v).length <= 13
    ? new Date(n < 1e12 ? n * 1000 : n)
    : new Date(String(v));
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
};
export const nap = (v: unknown): string | null => {
  const d = datum(v);
  return d ? d.slice(0, 10) : null;
};
export const tomb = (v: unknown): string[] => {
  if (Array.isArray(v)) return v.map(x => String(x)).filter(Boolean);
  if (typeof v === 'string' && v.trim() !== '') return v.split(/[,;]/).map(x => x.trim()).filter(Boolean);
  return [];
};

export interface Forras {
  kulcs: string;
  platform: string;
  intezmeny: string;
  orszag?: string | null;
  mezo_terkep?: Record<string, string>;
}

// Az Actor tételeiből a 112-es szerződés szerinti köteg.
export function kotegKeszit(forras: Forras, tetelek: Record<string, unknown>[]) {
  const t = forras.mezo_terkep ?? {};
  const koteg: Record<string, unknown> = { forras: forras.kulcs, ures: tetelek.length === 0 };

  if (forras.platform === 'ads') {
    koteg.hirdetesek = tetelek.map(it => ({
      kulso_id: szoveg(mezo(it, 'kulso_id', t)),
      platform: szoveg(it.platform) ?? 'facebook',
      intezmeny: szoveg(mezo(it, 'hirdeto', t)) ?? forras.intezmeny,
      elso_latas: nap(mezo(it, 'elso_latas', t)),
      utolso_latas: nap(mezo(it, 'utolso_latas', t)) ?? new Date().toISOString().slice(0, 10),
      orszagok: tomb(mezo(it, 'orszagok', t)),
      tema: szoveg(mezo(it, 'tema', t)),
      landing_url: szoveg(mezo(it, 'landing_url', t)),
      kreativ: szoveg(mezo(it, 'kreativ', t)),
    })).filter(x => x.kulso_id);
    koteg.ures = (koteg.hirdetesek as unknown[]).length === 0;
    return koteg;
  }

  if (forras.platform === 'web') {
    koteg.web = tetelek.map(it => ({
      mezo: szoveg(mezo(it, 'mezo', t)),
      regi: szoveg(mezo(it, 'regi', t)),
      uj: szoveg(mezo(it, 'uj', t)),
    })).filter(x => x.mezo && x.uj);
    koteg.ures = (koteg.web as unknown[]).length === 0;
    return koteg;
  }

  if (forras.platform === 'trends') {
    const sorok: Record<string, unknown>[] = [];
    for (const it of tetelek) {
      const kulcsszo = szoveg(it.searchTerm ?? it.keyword ?? it.term);
      const orszag = szoveg(it.geo ?? it.country ?? it.geoName) ?? forras.orszag ?? null;
      // A Google Trends Actor EGY tételben adja a teljes idősort — szét kell
      // bontani hetekre, különben egyetlen sor lenne belőle.
      const idosor = it.interestOverTime_timelineData ?? it.timelineData ?? null;
      if (Array.isArray(idosor)) {
        for (const p of idosor as Record<string, unknown>[]) {
          const het = nap(p.time ?? p.formattedAxisTime ?? p.date);
          const ertek = szam(Array.isArray(p.value) ? (p.value as unknown[])[0] : p.value);
          if (het && kulcsszo && orszag) sorok.push({ orszag, kulcsszo, het, ertek });
        }
      } else {
        const het = nap(it.week ?? it.date ?? it.time);
        if (het && kulcsszo && orszag) {
          sorok.push({ orszag, kulcsszo, het, ertek: szam(it.value ?? it.index) });
        }
      }
    }
    koteg.trend = sorok;
    koteg.ures = sorok.length === 0;
    return koteg;
  }

  // Közösségi oldal. Az Actorok kétféleképp adják: vagy egy profil-objektum a
  // posztok tömbjével (Instagram Profile Scraper: latestPosts), vagy csak
  // poszt/videó tételek, amelyekben a profil beágyazva ül (TikTok: authorMeta).
  const profil = tetelek.find(x => mezo(x, 'kovetok', t) !== null) ?? {};
  const beagyazott = (profil as Record<string, unknown>).latestPosts;
  const posztForras = Array.isArray(beagyazott)
    ? beagyazott as Record<string, unknown>[]
    : tetelek.filter(x => mezo(x, 'kulso_id', t) !== null);

  const posztok = posztForras.map(it => {
    const like = szam(it.likesCount ?? it.diggCount ?? it.likes) ?? 0;
    const komment = szam(it.commentsCount ?? it.commentCount ?? it.comments) ?? 0;
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

// ============================================================
// TÖBB FORRÁS EGY FUTÁSBÓL
// ============================================================
// Egy Apify-futásba több profil is betehető, a webhook viszont egy URL. Ha
// forrásonként külön futást kérnénk, 13 feladatot és 13 ütemezést kellene
// kézzel karbantartani — és mindegyiket külön elrontani. Ezért a betöltő maga
// osztja szét a tételeket: minden tételt ahhoz a forráshoz köt, amelyiknek a
// CÍMÉBEN szereplő kezelőnevet hordozza.

// A kezelőnév a figyelt címből: instagram.com/obudaiegyetem/ -> obudaiegyetem,
// tiktok.com/@obudai.egyetem -> obudai.egyetem.
export function kezelo(cim?: string | null): string | null {
  if (!cim) return null;
  const tiszta = String(cim).trim()
    .replace(/^https?:\/\//i, '')
    .replace(/^www\./i, '')
    .replace(/\?.*$/, '');
  const reszek = tiszta.split('/').filter(Boolean);
  if (reszek.length < 2) return null;          // csak a domain — nincs kezelőnév
  const nev = reszek[1].replace(/^@/, '').toLowerCase();
  return nev || null;
}

// Egy tétel LEHETSÉGES kezelőnevei. Actoronként más mező hordozza.
export function tetelKezeloi(it: Record<string, unknown>): string[] {
  const jeloltek = [
    it.username, it.ownerUsername, it.pageName, it.name,
    ut(it, 'authorMeta.name'), ut(it, 'authorMeta.uniqueId'), ut(it, 'author.uniqueId'),
  ].filter(Boolean).map(x => String(x).replace(/^@/, '').toLowerCase());

  // A tételben lévő URL-ekből is kiolvassuk — sok Actor csak ott adja meg.
  for (const u of [it.inputUrl, it.url, it.webVideoUrl, it.postUrl, it.facebookUrl, it.profileUrl]) {
    const k = kezelo(u as string | null);
    if (k) jeloltek.push(k);
  }
  return [...new Set(jeloltek)];
}

export interface Csoport { forras: Forras; tetelek: Record<string, unknown>[]; }

/* Szétosztás. Az ÁRVA tételeket (amelyik egyik forráshoz sem köthető) NEM
   dobjuk el némán: visszaadjuk, és a válasz kiírja. Egy elgépelt cím így
   azonnal látszik, nem három hét múlva egy üres oszlopból. */
export function csoportosit(forrasok: Forras[], tetelek: Record<string, unknown>[]) {
  const terkep = new Map<string, Csoport>();
  const kezeloRe = new Map<string, string>();   // kezelőnév -> forras.kulcs
  // Az intézménynév a MÁSODIK esély: a hirdetéskönyvtár tételei nem
  // kezelőnevet hordoznak, hanem a hirdető nevét (pageName). Csak akkor
  // használjuk, ha a név EGYÉRTELMŰ a csoporton belül — Dunaújvárosnak például
  // két Instagram-oldala van (magyar és angol), ott a cím dönt.
  const nevRe = new Map<string, string | null>();
  const norm = (x: unknown) => String(x ?? '')
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .toLowerCase().replace(/[^a-z0-9]/g, '');

  for (const f of forrasok) {
    terkep.set(f.kulcs, { forras: f, tetelek: [] });
    const k = kezelo((f as Forras & { cim?: string }).cim);
    if (k) kezeloRe.set(k, f.kulcs);
    const n = norm(f.intezmeny);
    if (n) nevRe.set(n, nevRe.has(n) ? null : f.kulcs);   // null = többértelmű
  }

  const arvak: Record<string, unknown>[] = [];
  for (const it of tetelek) {
    let talalt: string | undefined;
    for (const k of tetelKezeloi(it)) {
      const kulcs = kezeloRe.get(k);
      if (kulcs) { talalt = kulcs; break; }
    }
    if (!talalt) {
      for (const jelolt of [it.pageName, it.name, it.intezmeny, ut(it, 'snapshot.pageName')]) {
        const kulcs = nevRe.get(norm(jelolt));
        if (kulcs) { talalt = kulcs; break; }
      }
    }
    // Egyetlen forrás esetén nincs mit eltéveszteni: oda tesszük.
    if (!talalt && forrasok.length === 1) talalt = forrasok[0].kulcs;
    if (talalt) terkep.get(talalt)!.tetelek.push(it);
    else arvak.push(it);
  }
  return { csoportok: [...terkep.values()], arvak };
}
