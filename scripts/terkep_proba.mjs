// ============================================================
// terkep_proba.mjs — a leképezés mérése VALÓDI alakú Actor-mintákkal
//
// MIÉRT: az Apify Actorok kimenetének alakját a boltban közzétett
// mezőlisták adják (2026-09-30). Ha a leképezés nem illeszkedik, azt NEM az
// első éles gyűjtésnél akarjuk megtudni, hanem itt.
//
// Futtatás:  node scripts/terkep_proba.mjs
// ============================================================
import { build } from 'esbuild';
import { writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const ki = join(tmpdir(), 'mi_terkep_' + Date.now() + '.mjs');
await build({
  entryPoints: ['supabase/functions/market-intel-fetch/terkep.ts'],
  outfile: ki, format: 'esm', platform: 'neutral', bundle: false, logLevel: 'silent',
});
const { kotegKeszit } = await import('file://' + ki);

let hibak = 0;
const ell = (cim, felt, extra) => {
  console.log(`    ${felt ? 'OK   ' : 'HIBA '} ${cim}` + (!felt && extra !== undefined ? `   → ${JSON.stringify(extra)}` : ''));
  if (!felt) hibak++;
};

// ---- 1. Instagram Profile Scraper (apify/instagram-profile-scraper) ----
// Egy tétel profilonként, a posztok a latestPosts tömbben.
const ig = [{
  username: 'obudaiegyetem', followersCount: 9100, followsCount: 120, postsCount: 640,
  latestPosts: [
    { shortCode: 'C1abc', timestamp: '2026-09-28T10:00:00.000Z', type: 'Video',
      likesCount: 310, commentsCount: 12, url: 'https://www.instagram.com/p/C1abc/' },
    { shortCode: 'C2def', timestamp: '2026-09-25T08:00:00.000Z', type: 'Sidecar',
      likesCount: 140, commentsCount: 3, url: 'https://www.instagram.com/p/C2def/' },
  ],
}];
const k1 = kotegKeszit({ kulcs: 'obuda-instagram', platform: 'instagram', intezmeny: 'Óbudai Egyetem' }, ig);
console.log('\n== Instagram Profile Scraper — mezőtérkép NÉLKÜL ==');
ell('követőszám átjön', k1.pillanatkep?.kovetok === 9100, k1.pillanatkep);
ell('két poszt lett', k1.posztok?.length === 2, k1.posztok?.length);
ell('a poszt azonosítója a shortCode', k1.posztok?.[0].kulso_id === 'C1abc', k1.posztok?.[0]);
ell('a dátum ISO lett', k1.posztok?.[0].kelt?.startsWith('2026-09-28'), k1.posztok?.[0].kelt);
ell('a bevonás like+komment', k1.posztok?.[0].bevonas === 322, k1.posztok?.[0].bevonas);
ell('a formátum átjön', k1.posztok?.[0].formatum === 'Video', k1.posztok?.[0].formatum);
ell('nem üres', k1.ures === false, k1.ures);

// ---- 2. TikTok Scraper (clockworks/tiktok-scraper) ----
// Videónkénti tételek, a profil BEÁGYAZVA (authorMeta) — ehhez kell a pontozott út.
const tt = [
  { id: '7412345', createTime: 1790000000, webVideoUrl: 'https://www.tiktok.com/@x/video/7412345',
    diggCount: 1200, commentCount: 40, shareCount: 25, playCount: 30000,
    authorMeta: { name: 'obudai.egyetem', fans: 15400, video: 210 } },
  { id: '7412399', createTime: 1790086400, webVideoUrl: 'https://www.tiktok.com/@x/video/7412399',
    diggCount: 300, commentCount: 5, shareCount: 2, playCount: 8000,
    authorMeta: { name: 'obudai.egyetem', fans: 15400, video: 210 } },
];
const k2 = kotegKeszit({ kulcs: 'obuda-tiktok', platform: 'tiktok', intezmeny: 'Óbudai Egyetem' }, tt);
console.log('\n== TikTok Scraper — a profil beágyazva (authorMeta) ==');
ell('a beágyazott követőszám átjön', k2.pillanatkep?.kovetok === 15400, k2.pillanatkep);
ell('két videó lett', k2.posztok?.length === 2, k2.posztok?.length);
ell('a másodperc-alapú epoch dátummá vált', k2.posztok?.[0].kelt?.startsWith('2026-'), k2.posztok?.[0].kelt);
ell('a bevonás digg+komment+megosztás', k2.posztok?.[0].bevonas === 1265, k2.posztok?.[0].bevonas);

// ---- 3. Facebook Posts Scraper (apify/facebook-posts-scraper) ----
const fb = [
  { postId: '1122', time: '2026-09-27T12:00:00Z', url: 'https://facebook.com/p/1122',
    likes: 88, comments: 9, shares: 4, text: 'Nyílt nap' },
];
const k3 = kotegKeszit({ kulcs: 'obuda-facebook', platform: 'facebook', intezmeny: 'Óbudai Egyetem' }, fb);
console.log('\n== Facebook Posts Scraper — nincs követőszám a kimenetben ==');
ell('a poszt átjön', k3.posztok?.length === 1, k3.posztok);
ell('a bevonás 101', k3.posztok?.[0].bevonas === 101, k3.posztok?.[0].bevonas);
ell('követőszám nélkül is van pillanatkép', k3.pillanatkep?.kovetok === null, k3.pillanatkep);
ell('NEM jelenti üresnek', k3.ures === false, k3.ures);

// ---- 4. Facebook Ads Library (apify/facebook-ads-scraper) ----
// A kreatív és a landing BEÁGYAZVA (snapshot.*), az azonosító nagy D-vel.
const ads = [
  { adArchiveID: '998877', pageName: 'Óbudai Egyetem',
    startDateFormatted: '2026-08-20', endDateFormatted: '2026-09-29',
    targetedOrReachedCountries: ['NG', 'IN'], isActive: true,
    snapshot: { body: { text: 'Apply now for the autumn intake' }, linkUrl: 'https://uni-obuda.hu/apply' } },
];
const k4 = kotegKeszit({ kulcs: 'obuda-ads', platform: 'ads', intezmeny: 'Óbudai Egyetem' }, ads);
console.log('\n== Facebook Ads Library — beágyazott kreatív, adArchiveID ==');
ell('az azonosító átjön (nagy D is)', k4.hirdetesek?.[0].kulso_id === '998877', k4.hirdetesek?.[0]);
ell('a futamidő két vége megvan',
  k4.hirdetesek?.[0].elso_latas === '2026-08-20' && k4.hirdetesek?.[0].utolso_latas === '2026-09-29',
  k4.hirdetesek?.[0]);
ell('a célországok átjönnek', JSON.stringify(k4.hirdetesek?.[0].orszagok) === '["NG","IN"]', k4.hirdetesek?.[0].orszagok);
ell('a beágyazott kreatív-szöveg átjön',
  k4.hirdetesek?.[0].kreativ === 'Apply now for the autumn intake', k4.hirdetesek?.[0].kreativ);
ell('a beágyazott landing URL átjön',
  k4.hirdetesek?.[0].landing_url === 'https://uni-obuda.hu/apply', k4.hirdetesek?.[0].landing_url);
ell('a hirdető neve az intézmény', k4.hirdetesek?.[0].intezmeny === 'Óbudai Egyetem', k4.hirdetesek?.[0].intezmeny);

// ---- 5. Google Trends (emastra/google-trends-scraper) ----
// EGY tétel tartalmazza a teljes idősort — hetekre kell bontani.
const gt = [{
  searchTerm: 'study in hungary', geo: 'NG',
  interestOverTime_timelineData: [
    { time: '2026-09-14T00:00:00.000Z', value: [61], hasData: [true] },
    { time: '2026-09-21T00:00:00.000Z', value: [68], hasData: [true] },
  ],
}];
const k5 = kotegKeszit({ kulcs: 'trends-ng', platform: 'trends', intezmeny: 'Google Trends', orszag: 'Nigeria' }, gt);
console.log('\n== Google Trends — egy tétel, benne a teljes idősor ==');
ell('két heti sor lett belőle', k5.trend?.length === 2, k5.trend);
ell('az érték a tömbből jön ki', k5.trend?.[1].ertek === 68, k5.trend?.[1]);
ell('a hét dátuma megvan', k5.trend?.[0].het === '2026-09-14', k5.trend?.[0]);

// ---- 6. MEZŐTÉRKÉP felülír, és ÜRES kimenet ----
const egyedi = [{ kovetoim: 777, sajat_id: 'x1', mikor: '2026-09-20T00:00:00Z' }];
const k6 = kotegKeszit(
  { kulcs: 'egyedi', platform: 'instagram', intezmeny: 'X',
    mezo_terkep: { kovetok: 'kovetoim', kulso_id: 'sajat_id', kelt: 'mikor' } }, egyedi);
console.log('\n== Mezőtérkép és üres kimenet ==');
ell('a mezőtérkép felülírja az aliasokat', k6.pillanatkep?.kovetok === 777, k6.pillanatkep);
const k7 = kotegKeszit({ kulcs: 'ures', platform: 'instagram', intezmeny: 'X' }, []);
ell('üres kimenet -> ures:true (ebből lesz riasztás)', k7.ures === true, k7);

// ---- 7. TÖBB FORRÁS EGY FUTÁSBÓL ----
const { csoportosit, kezelo } = await import('file://' + ki);
console.log('\n== Szétosztás: egy futás, több profil ==');
ell('a kezelőnév kijön a címből', kezelo('https://www.instagram.com/obudaiegyetem/') === 'obudaiegyetem');
ell('a TikTok @ jele lekerül', kezelo('https://www.tiktok.com/@obudai.egyetem') === 'obudai.egyetem');
ell('puszta domain -> nincs kezelőnév', kezelo('https://nje.hu') === null);

const forrasok = [
  { kulcs: 'obuda-instagram', platform: 'instagram', intezmeny: 'Óbudai Egyetem', cim: 'https://www.instagram.com/obudaiegyetem/' },
  { kulcs: 'nje-instagram', platform: 'instagram', intezmeny: 'NJE', cim: 'https://www.instagram.com/uni_neumann/' },
];
const vegyes = [
  { username: 'obudaiegyetem', followersCount: 9100, latestPosts: [] },
  { username: 'uni_neumann', followersCount: 1900, latestPosts: [] },
  { username: 'valaki_mas', followersCount: 50, latestPosts: [] },
];
const cs = csoportosit(forrasok, vegyes);
ell('mindkét profil a saját forrásához került',
  cs.csoportok[0].tetelek[0].username === 'obudaiegyetem' && cs.csoportok[1].tetelek[0].username === 'uni_neumann',
  cs.csoportok.map(c => [c.forras.kulcs, c.tetelek.length]));
ell('az ODA NEM ILLŐ tétel árva lett, nem tűnt el némán',
  cs.arvak.length === 1 && cs.arvak[0].username === 'valaki_mas', cs.arvak);

// TikTok: a kezelőnév az authorMeta-ban
const ttF = [{ kulcs: 'obuda-tiktok', platform: 'tiktok', intezmeny: 'Óbudai Egyetem', cim: 'https://www.tiktok.com/@obudai.egyetem' }];
const cs2 = csoportosit(ttF, [{ id: '1', authorMeta: { name: 'obudai.egyetem', fans: 15400 } }]);
ell('a TikTok tétel a beágyazott névvel talál forrást', cs2.csoportok[0].tetelek.length === 1 && cs2.arvak.length === 0, cs2.arvak);

// Hirdetéskönyvtár: a tétel a HIRDETŐ nevét hordozza, nem kezelőnevet
const adsF = [
  { kulcs: 'ads-obuda', platform: 'ads', intezmeny: 'Óbudai Egyetem', cim: null },
  { kulcs: 'ads-nje',   platform: 'ads', intezmeny: 'Neumann János Egyetem', cim: null },
];
const csAds = csoportosit(adsF, [
  { adArchiveID: '1', pageName: 'Óbudai Egyetem' },
  { adArchiveID: '2', pageName: 'Neumann János Egyetem' },
]);
ell('a hirdetés a hirdető NEVE alapján talál forrást',
  csAds.csoportok[0].tetelek.length === 1 && csAds.csoportok[1].tetelek.length === 1 && csAds.arvak.length === 0,
  csAds.csoportok.map(c => [c.forras.kulcs, c.tetelek.length]));

// Többértelmű név: Dunaújvárosnak KÉT Instagram-oldala van -> a cím dönt
const dufF = [
  { kulcs: 'duf-instagram', platform: 'instagram', intezmeny: 'Dunaújvárosi Egyetem', cim: 'https://www.instagram.com/dunaujvarosiegyetem/' },
  { kulcs: 'duf-instagram-intl', platform: 'instagram', intezmeny: 'Dunaújvárosi Egyetem', cim: 'https://www.instagram.com/universityofdunaujvaros/' },
];
const csDuf = csoportosit(dufF, [
  { username: 'universityofdunaujvaros', followersCount: 3000, latestPosts: [] },
  { pageName: 'Dunaújvárosi Egyetem' },
]);
ell('a két azonos nevű oldalt a CÍM választja szét',
  csDuf.csoportok[1].tetelek.length === 1 && csDuf.csoportok[0].tetelek.length === 0,
  csDuf.csoportok.map(c => [c.forras.kulcs, c.tetelek.length]));
ell('a többértelmű nevű tétel árva marad, nem kerül rossz helyre',
  csDuf.arvak.length === 1, csDuf.arvak);

// Egyetlen forrásnál nincs mit eltéveszteni
const cs3 = csoportosit([forrasok[0]], [{ valami: 'ismeretlen alak' }]);
ell('egyetlen forrásnál a tétel oda kerül', cs3.csoportok[0].tetelek.length === 1, cs3);

rmSync(ki, { force: true });
console.log('\nEREDMÉNY: ' + (hibak ? hibak + ' hiba' : 'minden rendben'));
process.exit(hibak ? 1 : 0);
