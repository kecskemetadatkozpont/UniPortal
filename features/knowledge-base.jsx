/* ============================================================
   UniPortal Pro — AI Assistant knowledge base
   Seeded from the university's public English website content
   (nje.hu/en). Admins can add more documents (text / PDF) at
   runtime; everything is retrieved to ground the AI answers.
   ============================================================ */

const KB_LS = 'uni_kb';
const KB_TABLE = 'kb_documents';

// Public-site derived seed. Each doc carries a source URL so the
// assistant can cite the right page in its answers.
function KB_seed() {
  const now = todayStr();
  const mk = (id, title, url, content) => ({ id, title, source: 'website', url, content, created_at: now });
  return [
    mk('kb-about', 'About John von Neumann University (NJE)',
      'https://nje.hu/en',
      'John von Neumann University (Neumann János Egyetem, NJE) is a state university based in Kecskemét, Hungary, with faculties in engineering & computer science (GAMF), economics & business, horticulture & rural development, pedagogy and health sciences. It offers a growing portfolio of full degree programmes taught entirely in English for international students, combining strong industry links (notably automotive and IT) with a compact, affordable campus city about one hour from Budapest.'),
    mk('kb-programmes', 'Degree programmes taught in English',
      'https://nje.hu/en/study-programmes/in-english',
      'NJE offers English-taught programmes at every level. Preparatory: Preparatory English and Mathematics course (2 semesters). Bachelor (BSc): Computer Science Engineering, Mechanical Engineering, Vehicle Engineering, Logistics Engineering, Business Administration and Management, International Business Economics, Tourism and Catering, Horticultural Engineering. Master (MA/MBA): Regional and Environmental Economics MA, Master of Business Administration (MBA). Doctoral (PhD): Doctoral School of Management and Business Administration Sciences. Applications are submitted online through the university application portal (apply.nje.hu). Each programme has its own entry requirements, tuition fee and intake deadline — see the Programs section of this portal for live details.'),
    mk('kb-apply', 'Application process — step by step',
      'https://nje.hu/en/education/application-guideline',
      'The admission process for international applicants has these stages: 1) Prepare your documents (passport, secondary-school certificate or previous degree with transcripts, proof of English proficiency, motivation letter, and — for some programmes — a CV or portfolio). 2) Apply online via apply.nje.hu and choose your programme(s). 3) Submit your application and upload the documents. 4) Take part in the online entrance procedure: an interview and, for engineering and preparatory programmes, a mathematics entrance/placement test. 5) If successful you receive a Conditional Admission Letter (CAL). 6) Pay the application fee and, if requested, the dormitory deposit. 7) You then receive the Final Admission Letter (FAL). 8) Use the FAL to apply for a student visa / residence permit at the Hungarian consulate. 9) Travel to Kecskemét, register and enrol at the start of the semester.'),
    mk('kb-fees', 'Fees and payments',
      'https://nje.hu/en/education/application-guideline',
      'International applicants pay a one-time, non-refundable application/registration fee of EUR 200. A dormitory deposit of EUR 750 may be requested to reserve a room in university accommodation. Tuition fees are charged per semester and depend on the programme (typically in the EUR 1,800–3,900 per semester range for self-financed students); the exact tuition for each programme is shown in the Programs section of this portal. Payments are made by bank transfer or card after the Conditional Admission Letter is issued. Fees are subject to change each academic year.'),
    mk('kb-scholarships', 'Scholarships and funding',
      'https://nje.hu/en/study-programmes/in-english',
      'Several scholarship routes can cover tuition and living costs. Stipendium Hungaricum is the Hungarian government scholarship for international students and covers tuition, a monthly stipend, dormitory or housing contribution and medical insurance; applicants apply through their home country and the Tempus Public Foundation. The Programme for Hungarian Diaspora (Diaspora Scholarship) targets students of Hungarian origin. The Pannónia Scholarship supports student mobility. NJE also offers early-bird and merit-based tuition discounts from time to time — watch the Feed in this portal for current offers.'),
    mk('kb-entrance', 'Entrance interview and mathematics test',
      'https://nje.hu/en/education/application-guideline',
      'After submitting your application you attend a short online interview (usually via Microsoft Teams) with the admissions committee. Engineering and preparatory applicants also complete a mathematics placement test covering basic algebra (systems of equations, evaluating expressions, quadratic functions) and elementary logarithms and trigonometry. The test is used to confirm you can follow the programme; preparatory options exist for applicants who need to strengthen their maths or English first.'),
    mk('kb-visa', 'Visa and residence permit',
      'https://nje.hu/en/education/application-guideline',
      'Non-EU students need a student residence permit (type D visa) to study in Hungary. Once you receive the Final Admission Letter (FAL) you book an appointment at the Hungarian embassy or consulate in your country and submit: the FAL, a valid passport, proof of accommodation, proof of sufficient funds, health insurance and the visa application form. Apply as early as possible — processing can take several weeks. After arrival you register your address and finalise your residence permit with the National Directorate-General for Aliens Policing.'),
    mk('kb-accommodation', 'Accommodation and living in Kecskemét',
      'https://nje.hu/en',
      'The university offers dormitory places for international students; a EUR 750 deposit is used to reserve a room. Private rented flats are also widely available in Kecskemét at lower cost than Budapest. Kecskemét is a mid-sized Hungarian city with good rail and bus connections to Budapest (about one hour). Living costs are moderate compared with Western Europe.'),
    mk('kb-contact', 'Contact — International Relations / Admissions Office',
      'https://nje.hu/en',
      'For admissions questions contact the International Relations Office by email at admission@nje.hu. Use this address for questions about programmes, documents, deadlines, the entrance procedure, tuition and scholarships. Include your full name and, if you have one, your application ID so staff can find your file.'),
  ];
}

async function KB_load() {
  return dlSelect(KB_TABLE, KB_LS, KB_seed, 'created_at', true);
}
async function KB_add(doc) {
  const row = { id: uid('KB'), source: 'upload', url: '', created_at: todayStr(), ...doc };
  return dlInsert(KB_TABLE, row, KB_LS);
}
async function KB_remove(id) { return dlDelete(KB_TABLE, id, KB_LS); }

// text / PDF ingestion for admin uploads
async function KB_extractPdf(dataUrl) {
  try {
    const pdfjs = await import('https://cdn.jsdelivr.net/npm/pdfjs-dist@4.7.76/build/pdf.min.mjs');
    pdfjs.GlobalWorkerOptions.workerSrc = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@4.7.76/build/pdf.worker.min.mjs';
    const b64 = (dataUrl || '').split(',')[1] || '';
    const bin = atob(b64); const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const pdf = await pdfjs.getDocument({ data: bytes }).promise;
    let text = ''; const pages = Math.min(pdf.numPages, 20);
    for (let n = 1; n <= pages; n++) { const page = await pdf.getPage(n); const tc = await page.getTextContent(); text += tc.items.map(it => it.str).join(' ') + '\n'; }
    return text.replace(/\s+/g, ' ').trim().slice(0, 20000);
  } catch (e) { return ''; }
}
function KB_readFileAsDataUrl(file) {
  return new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = rej; r.readAsDataURL(file); });
}
function KB_readFileAsText(file) {
  return new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = rej; r.readAsText(file); });
}
async function KB_ingestFile(file) {
  const name = file.name || 'document';
  if (/\.pdf$/i.test(name) || file.type === 'application/pdf') {
    const dataUrl = await KB_readFileAsDataUrl(file);
    const content = await KB_extractPdf(dataUrl);
    return { title: name.replace(/\.pdf$/i, ''), content, ok: !!content };
  }
  const content = await KB_readFileAsText(file);
  return { title: name.replace(/\.(txt|md|csv|json)$/i, ''), content: (content || '').slice(0, 20000), ok: !!content };
}

/* ---------- retrieval ---------- */
const KB_STOP = new Set(['the','a','an','and','or','of','to','in','for','on','is','are','do','does','how','what','when','where','which','can','i','my','me','you','your','with','at','be','it','this','that','as','from','about','if','need','want']);
function KB_tok(s) {
  return (s || '').toLowerCase().replace(/[^a-z0-9\u00c0-\u017f\s]/g, ' ').split(/\s+/).filter(w => w.length > 2 && !KB_STOP.has(w));
}
function KB_rank(docs, query) {
  const q = KB_tok(query);
  if (!q.length) return docs.slice(0, 4);
  return docs.map(d => {
    const title = (d.title || '').toLowerCase();
    const body = (d.content || '').toLowerCase();
    let score = 0;
    for (const w of q) { if (title.includes(w)) score += 3; const m = body.split(w).length - 1; score += Math.min(m, 4); }
    return { d, score };
  }).filter(x => x.score > 0).sort((a, b) => b.score - a.score).map(x => x.d);
}
// Build a grounded context string within a char budget, plus the source list.
function KB_context(docs, query, budget = 7000) {
  const ranked = KB_rank(docs, query);
  const chosen = (ranked.length ? ranked : docs).slice(0, 6);
  let out = '', used = [];
  for (const d of chosen) {
    const chunk = '### ' + d.title + (d.url ? ' (' + d.url + ')' : '') + '\n' + (d.content || '') + '\n\n';
    if (out.length + chunk.length > budget) break;
    out += chunk; used.push(d);
  }
  return { context: out.trim(), sources: used };
}
