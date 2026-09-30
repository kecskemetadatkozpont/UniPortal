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
