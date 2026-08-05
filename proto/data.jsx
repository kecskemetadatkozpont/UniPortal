/* ============================================================
   UniPortal — Felvételi prototípus · TÖRZSADATOK & LOGIKA
   Szakok (Courses.pdf), dokumentum-típusok, matek-generátor,
   mock jelentkezők (duplicate finder), díjak (CAL minta).
   ============================================================ */

/* ---- Szakok (forrás: Courses.pdf) ---- */
const PROGRAMS = [
  { id: 'ibe',      code: 'BSc', name: 'International Business Economics',           faculty: 'Faculty of Economics and Business',       level: 'undergraduate', mode: 'full-time', tuition: 3000, semesters: 8, ects: 240 },
  { id: 'ibe-on',   code: 'BSc', name: 'International Business Economics — ONLINE',  faculty: 'Faculty of Economics and Business',       level: 'undergraduate', mode: 'e-learning', tuition: 2600, semesters: 8, ects: 240 },
  { id: 'tour',     code: 'BSc', name: 'Tourism and Catering',                      faculty: 'Faculty of Economics and Business',       level: 'undergraduate', mode: 'full-time', tuition: 3000, semesters: 8, ects: 240 },
  { id: 'bam',      code: 'BSc', name: 'Business Administration and Management',     faculty: 'Faculty of Economics and Business',       level: 'undergraduate', mode: 'full-time', tuition: 3000, semesters: 8, ects: 240 },
  { id: 'cse',      code: 'BSc', name: 'Computer Science Engineering',              faculty: 'Faculty of Engineering and Computer Science', level: 'undergraduate', mode: 'full-time', tuition: 3400, semesters: 7, ects: 210 },
  { id: 'mech',     code: 'BSc', name: 'Mechanical Engineering',                    faculty: 'Faculty of Engineering and Computer Science', level: 'undergraduate', mode: 'full-time', tuition: 3400, semesters: 7, ects: 210 },
  { id: 'veh',      code: 'BSc', name: 'Vehicle Engineering',                       faculty: 'Faculty of Engineering and Computer Science', level: 'undergraduate', mode: 'full-time', tuition: 3400, semesters: 7, ects: 210 },
  { id: 'log',      code: 'BSc', name: 'Logistics Engineering',                     faculty: 'Faculty of Engineering and Computer Science', level: 'undergraduate', mode: 'full-time', tuition: 3400, semesters: 7, ects: 210 },
  { id: 'hort',     code: 'BSc', name: 'Horticultural Engineering',                 faculty: 'Faculty of Horticulture and Rural Development', level: 'undergraduate', mode: 'full-time', tuition: 3200, semesters: 7, ects: 210 },
  { id: 'ree',      code: 'MA',  name: 'Regional and Environmental Economics',      faculty: 'Faculty of Economics and Business',       level: 'graduate', mode: 'full-time', tuition: 3600, semesters: 4, ects: 120 },
  { id: 'mba',      code: 'MBA', name: 'Master of Business Administration',         faculty: 'Faculty of Economics and Business',       level: 'graduate', mode: 'full-time', tuition: 4200, semesters: 4, ects: 120 },
  { id: 'mba-dd',   code: 'MBA', name: 'MBA — Double Degree',                       faculty: 'Faculty of Economics and Business',       level: 'graduate', mode: 'full-time', tuition: 4800, semesters: 4, ects: 120 },
  { id: 'phd',      code: 'PhD', name: 'Doctoral Program in Management & Business',  faculty: 'Doctoral School of Management and Business', level: 'graduate', mode: 'full-time', tuition: 5000, semesters: 8, ects: 240 },
  { id: 'prep',     code: 'PC',  name: 'Preparatory English and Math course',       faculty: 'Preparatory Program',                     level: 'preparatory', mode: 'full-time', tuition: 1800, semesters: 2, ects: 60 },
];

/* ---- Kötelező dokumentumok (forrás: jegyzet) ---- */
const DOC_TYPES = [
  { id: 'school',     label: 'Iskolai tanulmányi adatok', hint: 'Bizonyítvány / diploma / leckekönyv', icon: 'GraduationCap', accept: '.pdf,.jpg,.png', ocr: false },
  { id: 'passport',   label: 'Útlevél',                   hint: 'Érvényes úti okmány adatoldala',       icon: 'BookUser',      accept: '.pdf,.jpg,.png', ocr: true },
  { id: 'language',   label: 'Nyelvvizsga',               hint: 'Angol nyelvtudás igazolása (B2+)',     icon: 'Languages',     accept: '.pdf,.jpg,.png', ocr: false },
  { id: 'motivation', label: 'Motivációs levél',          hint: 'Min. 1 oldal, angol nyelven',          icon: 'PenLine',       accept: '.pdf,.docx',     ocr: false },
  { id: 'internship', label: 'Szakmai gyakorlat',         hint: 'Igazolás (ha releváns)',               icon: 'Briefcase',     accept: '.pdf,.jpg,.png', ocr: false, optional: true },
];

/* ---- Mock létező jelentkezők (Duplicate Finder) ---- */
const EXISTING_APPLICANTS = [
  { name: 'Ahmed Hassan',   passport: 'A09918273', birth: '1999-04-12', email: 'ahmed@test.com' },
  { name: 'Chen Wei',       passport: 'E88123456', birth: '2001-11-02', email: 'chen@test.com' },
  { name: 'Mohammed Khan',  passport: 'X1234567',  birth: '2000-01-15', email: 'm.khan@mail.com' },
];

/* ---- Díjak (forrás: CAL_TC-IBE.docx) ---- */
const FEES = {
  application: 200,
  dormitorySemester: 1000,
  dormitoryDeposit: 450,
  currency: 'EUR',
  bank: { name: 'MBH Bank Nyrt.', iban: 'HU10103000021327841900014888', swift: 'MKKBHUHB', account: '10300002-13278419-00014888' },
};

/* ============================================================
   MATEK-GENERÁTOR — random feladatok (forrás: Math placement test)
   Minden feladat numerikusan, automatikusan pontozható.
   ============================================================ */
const rnd = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;
const nz  = (min, max) => { let v = 0; while (v === 0) v = rnd(min, max); return v; };

/* 1) Lineáris egyenletrendszer — egész megoldással */
function genSystem() {
  const x = rnd(-5, 5), y = rnd(-5, 5);
  let a1 = nz(1, 5), b1 = nz(1, 5), a2, b2;
  do { a2 = nz(1, 5); b2 = nz(1, 5); } while (a1 * b2 - a2 * b1 === 0); // ne legyen párhuzamos
  const c1 = a1 * x + b1 * y, c2 = a2 * x + b2 * y;
  return {
    type: 'system',
    title: 'Egyenletrendszer',
    prompt: 'Oldd meg a következő egyenletrendszert!',
    lines: [`${a1}x + ${b1}y = ${c1}`, `${a2}x + ${b2}y = ${c2}`],
    fields: [{ key: 'x', label: 'x =' }, { key: 'y', label: 'y =' }],
    answer: { x, y },
    check: (v) => Number(v.x) === x && Number(v.y) === y,
    solutionText: `x = ${x},  y = ${y}`,
  };
}

/* 2) Kifejezés egyszerűsítése + behelyettesítés */
function genEvaluate() {
  const a = rnd(1, 5), b = rnd(1, 4), k = rnd(2, 4);
  const val = Math.pow(a - k * b, 2) + a * b;
  return {
    type: 'evaluate',
    title: 'Kifejezés kiértékelése',
    prompt: `Egyszerűsítsd, majd értékeld ki a kifejezést, ha a = ${a} és b = ${b}!`,
    lines: [`(a − ${k}b)² + a·b`],
    fields: [{ key: 'r', label: 'Érték =' }],
    answer: { r: val },
    check: (v) => Number(v.r) === val,
    solutionText: `(${a} − ${k}·${b})² + ${a}·${b} = ${val}`,
  };
}

/* 3) Másodfokú függvény — helyettesítési érték */
function genQuadratic() {
  const b = nz(-4, 4), c = rnd(-6, 6), k = rnd(-3, 3);
  const val = k * k + b * k + c;
  const bs = b < 0 ? `− ${-b}x` : `+ ${b}x`;
  const cs = c < 0 ? `− ${-c}` : `+ ${c}`;
  return {
    type: 'quadratic',
    title: 'Másodfokú függvény',
    prompt: `Adott az f(x) = x² ${bs} ${cs} függvény. Mennyi f(${k}) értéke?`,
    lines: [`f(x) = x² ${bs} ${cs}`],
    fields: [{ key: 'r', label: `f(${k}) =` }],
    answer: { r: val },
    check: (v) => Number(v.r) === val,
    solutionText: `f(${k}) = ${k}² ${bs.replace('x', '·' + k)} ${cs} = ${val}`,
  };
}

/* 4) Logaritmus + szögfüggvény kiértékelése */
function genLogTrig() {
  const n = rnd(2, 5);
  const pow = Math.pow(2, n);
  const trigs = [
    { txt: 'sin 30°', v: 0.5 }, { txt: 'sin 90°', v: 1 },
    { txt: 'cos 60°', v: 0.5 }, { txt: 'cos 0°',  v: 1 },
    { txt: 'sin 0°',  v: 0 },
  ];
  const t = trigs[rnd(0, trigs.length - 1)];
  const val = n + t.v;
  return {
    type: 'logtrig',
    title: 'Logaritmus és szögfüggvény',
    prompt: 'Értékeld ki a következő kifejezést!',
    lines: [`log₂(${pow}) + ${t.txt}`],
    fields: [{ key: 'r', label: 'Érték =' }],
    answer: { r: val },
    check: (v) => Math.abs(Number(v.r) - val) < 1e-6,
    solutionText: `log₂(${pow}) + ${t.txt} = ${n} + ${t.v} = ${val}`,
  };
}

/* Teljes teszt generálása (4 feladat, random) */
function generateMathTest() {
  return [genSystem(), genEvaluate(), genQuadratic(), genLogTrig()];
}

/* ---- Mock AI OCR az útlevélből ---- */
function mockPassportOCR(applicant) {
  // véletlen, ütközésmentes útlevélszám a happy path-hoz
  const letters = 'ABCDEFGHJKMNPRTVWX';
  const L = letters[rnd(0, letters.length - 1)] + letters[rnd(0, letters.length - 1)];
  const num = String(rnd(1000000, 9999999));
  return {
    name: applicant.name || 'GUEST APPLICANT',
    passportNumber: L + num,
    country: applicant.country || 'Nigeria',
    birthDate: applicant.birthDate || '2002-06-21',
    confidence: rnd(94, 99),
  };
}

/* ---- Iktatószám ---- */
function makeFileNumber(kind) {
  const seq = String(rnd(1, 9999)).padStart(4, '0');
  return `NJE/2026/${kind}/${seq}`;
}

/* ---- Országlista (combobox) ---- */
const COUNTRIES = ['Afghanistan','Albania','Algeria','Angola','Argentina','Armenia','Australia','Austria','Azerbaijan','Bahrain','Bangladesh','Belarus','Belgium','Benin','Bolivia','Bosnia and Herzegovina','Brazil','Bulgaria','Burkina Faso','Cambodia','Cameroon','Canada','Chad','Chile','China','Colombia','Congo','Costa Rica','Côte d’Ivoire','Croatia','Cuba','Cyprus','Czech Republic','Denmark','Dominican Republic','Ecuador','Egypt','El Salvador','Estonia','Ethiopia','Finland','France','Gabon','Georgia','Germany','Ghana','Greece','Guatemala','Guinea','Honduras','Hungary','Iceland','India','Indonesia','Iran','Iraq','Ireland','Israel','Italy','Jamaica','Japan','Jordan','Kazakhstan','Kenya','Kosovo','Kuwait','Kyrgyzstan','Laos','Latvia','Lebanon','Liberia','Libya','Lithuania','Luxembourg','Madagascar','Malawi','Malaysia','Mali','Malta','Mauritius','Mexico','Moldova','Mongolia','Montenegro','Morocco','Mozambique','Myanmar','Namibia','Nepal','Netherlands','New Zealand','Nicaragua','Niger','Nigeria','North Macedonia','Norway','Oman','Pakistan','Palestine','Panama','Paraguay','Peru','Philippines','Poland','Portugal','Qatar','Romania','Russia','Rwanda','Saudi Arabia','Senegal','Serbia','Sierra Leone','Singapore','Slovakia','Slovenia','Somalia','South Africa','South Korea','South Sudan','Spain','Sri Lanka','Sudan','Sweden','Switzerland','Syria','Taiwan','Tajikistan','Tanzania','Thailand','Togo','Tunisia','Turkey','Turkmenistan','Uganda','Ukraine','United Arab Emirates','United Kingdom','United States','Uruguay','Uzbekistan','Venezuela','Vietnam','Yemen','Zambia','Zimbabwe'];

Object.assign(window, {
  PROGRAMS, DOC_TYPES, EXISTING_APPLICANTS, FEES, COUNTRIES,
  generateMathTest, mockPassportOCR, makeFileNumber,
});
