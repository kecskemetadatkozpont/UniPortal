/* ============================================================
   Felvételi prototípus · LÉPÉSEK 4–7
   Dokumentum-check + Duplicate Finder · Matek-teszt ·
   Interjúfoglalás · Conditional Acceptance Letter
   ============================================================ */

/* ---------- 4. DOKUMENTUM-CHECK + DUPLICATE FINDER ---------- */
function CheckStep({ data, set, next, back }) {
  const c = data.check || {};
  const ex = data.extracted || {};
  const docs = data.docs || {};

  const runDuplicate = () => {
    const matches = [];
    EXISTING_APPLICANTS.forEach((e) => {
      if (ex.passportNumber && e.passport === ex.passportNumber) matches.push({ ...e, reason: 'Azonos útlevélszám' });
      else if (ex.name && e.name.toLowerCase() === (ex.name || '').toLowerCase()) matches.push({ ...e, reason: 'Azonos név' });
    });
    if (c.simulate) matches.push({ name: ex.name || 'Adaeze Okonkwo', passport: ex.passportNumber || '—', birth: ex.birthDate || '—', email: (data.account || {}).email || '—', reason: 'Korábbi jelentkezés ugyanezzel az útlevéllel' });
    set({ check: { ...c, duplicateChecked: true, duplicates: matches } });
  };

  const docStatuses = DOC_TYPES.map((d) => ({ ...d, up: !!(docs[d.id] && docs[d.id].fileName) }));
  const blocking = (c.duplicates || []).length > 0;

  return (
    <div>
      <StepHeader eyebrow="4. lépés · Felvételi munkatárs" title="Dokumentum-ellenőrzés"
        desc="A beadott dokumentumok átvizsgálása, csalásszűrés és belső jegyzetek. Ez a folyamat első kapuja." />
      <div className="grid lg:grid-cols-2 gap-6">
        {/* checklist */}
        <Card className="p-5">
          <div className="font-bold text-slate-900 mb-4 flex items-center gap-2"><Icon name="ListChecks" size={18} className="text-primary-500" /> Dokumentum-lista</div>
          <div className="space-y-2.5">
            {docStatuses.map((d) => (
              <div key={d.id} className="flex items-center gap-3 py-1.5">
                <Icon name={d.up ? 'CircleCheck' : d.optional ? 'MinusCircle' : 'CircleAlert'} size={18}
                  className={d.up ? 'text-emerald-500' : d.optional ? 'text-slate-300' : 'text-amber-500'} />
                <span className="text-sm font-medium text-slate-700 flex-1">{d.label}</span>
                <Badge tone={d.up ? 'green' : d.optional ? 'slate' : 'amber'}>{d.up ? 'rendben' : d.optional ? 'nincs' : 'hiányzik'}</Badge>
              </div>
            ))}
          </div>
          <div className="mt-5 pt-4 border-t border-slate-100">
            <div className="text-xs font-bold text-slate-500 uppercase tracking-wide mb-2">Belső jegyzet</div>
            <textarea value={c.notes || ''} onChange={(e) => set({ check: { ...c, notes: e.target.value } })}
              placeholder="Megjegyzés a jelentkezőhöz (csak munkatársaknak látható)…" rows={3}
              className="w-full px-3.5 py-2.5 rounded-xl border border-slate-300 text-sm focus:border-primary-500 focus:ring-2 focus:ring-primary-500/20 outline-none resize-none" />
          </div>
        </Card>

        {/* duplicate finder */}
        <Card className="p-5">
          <div className="flex items-center justify-between mb-3">
            <div className="font-bold text-slate-900 flex items-center gap-2"><Icon name="Fingerprint" size={18} className="text-primary-500" /> Duplicate Finder</div>
            <label className="flex items-center gap-2 text-xs text-slate-500 cursor-pointer select-none">
              <input type="checkbox" checked={!!c.simulate} onChange={(e) => set({ check: { ...c, simulate: e.target.checked, duplicateChecked: false, duplicates: [] } })} />
              Gyanús eset szimulálása
            </label>
          </div>
          <p className="text-xs text-slate-400 mb-4">Egyezés-keresés a korábbi jelentkezések között (útlevélszám, név). A szabályok Tündi átverés-példái alapján finomhangolhatók.</p>

          {!c.duplicateChecked ? (
            <Button variant="dark" icon="Search" onClick={runDuplicate}>Ellenőrzés futtatása</Button>
          ) : blocking ? (
            <div className="space-y-3">
              <div className="flex items-center gap-2 text-red-600 font-bold text-sm"><Icon name="TriangleAlert" size={16} /> {c.duplicates.length} lehetséges egyezés</div>
              {c.duplicates.map((m, i) => (
                <div key={i} className="rounded-xl border border-red-200 bg-red-50 p-3">
                  <div className="font-bold text-red-800 text-sm">{m.name}</div>
                  <div className="text-xs text-red-600 mt-0.5">Útlevél: {m.passport} · {m.email}</div>
                  <div className="text-xs text-red-700 font-semibold mt-1">⚠ {m.reason}</div>
                </div>
              ))}
              <Button variant="ghost" size="sm" icon="RefreshCw" onClick={() => set({ check: { ...c, duplicateChecked: false } })}>Újrafuttatás</Button>
            </div>
          ) : (
            <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-4 flex items-center gap-3">
              <Icon name="ShieldCheck" size={22} className="text-emerald-600" />
              <div><div className="font-bold text-emerald-800 text-sm">Nincs egyezés</div><div className="text-xs text-emerald-600">A jelentkezés egyedinek tűnik.</div></div>
            </div>
          )}
        </Card>
      </div>

      <StepNav onBack={back}
        onNext={() => { set({ check: { ...c, cleared: true } }); next(); }}
        nextDisabled={!c.duplicateChecked || blocking}
        nextLabel="Dokumentumok jóváhagyása"
        note={blocking ? 'Oldja fel az egyezést a folytatáshoz' : !c.duplicateChecked ? 'Futtassa a csalásszűrést' : 'Jóváhagyható'} />
    </div>
  );
}

/* ---------- 5. MATEMATIKA TESZT ---------- */
function MathStep({ data, set, next, back }) {
  const m = data.math || {};
  const valid = m.questions && typeof (m.questions[0] || {}).check === 'function';
  useEffect(() => { if (!valid) set({ math: { questions: generateMathTest(), answers: {}, submitted: false } }); }, []);
  if (!valid) return null;

  const setAns = (qi, key, v) => set({ math: { ...m, answers: { ...m.answers, [`${qi}.${key}`]: v } } });
  const grade = () => {
    let score = 0;
    m.questions.forEach((q, qi) => {
      const v = {}; q.fields.forEach((f) => { v[f.key] = m.answers[`${qi}.${f.key}`]; });
      if (q.check(v)) score++;
    });
    const passed = score >= 3;
    set({ math: { ...m, submitted: true, score, passed } });
  };
  const retry = () => set({ math: { questions: generateMathTest(), answers: {}, submitted: false } });
  const allFilled = m.questions.every((q, qi) => q.fields.every((f) => (m.answers[`${qi}.${f.key}`] || '') !== ''));

  return (
    <div>
      <StepHeader eyebrow="5. lépés" title="Matematika szintfelmérő"
        desc="Négy feladat, jelentkezőnként véletlenszerűen generálva. A megfeleléshez 4-ből legalább 3 helyes válasz szükséges." />
      <div className="space-y-4">
        {m.questions.map((q, qi) => {
          const v = {}; q.fields.forEach((f) => { v[f.key] = m.answers[`${qi}.${f.key}`]; });
          const ok = m.submitted && q.check(v);
          const bad = m.submitted && !q.check(v);
          return (
            <Card key={qi} className={`p-5 ${ok ? 'border-emerald-300 bg-emerald-50/40' : bad ? 'border-red-300 bg-red-50/40' : ''}`}>
              <div className="flex items-start gap-4">
                <span className="flex-none w-8 h-8 rounded-lg bg-slate-900 text-white font-bold flex items-center justify-center text-sm">{qi + 1}</span>
                <div className="flex-1 min-w-0">
                  <div className="text-xs font-bold uppercase tracking-wide text-primary-600 mb-1">{q.title}</div>
                  <p className="text-slate-800 font-medium">{q.prompt}</p>
                  <div className="mt-3 font-mono text-lg text-slate-900 bg-slate-100 rounded-xl px-4 py-3 inline-block leading-relaxed">
                    {q.lines.map((ln, i) => <div key={i}>{ln}</div>)}
                  </div>
                  <div className="flex flex-wrap gap-4 mt-4 items-end">
                    {q.fields.map((f) => (
                      <label key={f.key} className="flex items-center gap-2">
                        <span className="font-mono text-sm text-slate-600">{f.label}</span>
                        <input value={m.answers[`${qi}.${f.key}`] || ''} disabled={m.submitted}
                          onChange={(e) => setAns(qi, f.key, e.target.value)}
                          className="w-24 px-3 py-2 rounded-lg border border-slate-300 font-mono text-center focus:border-primary-500 focus:ring-2 focus:ring-primary-500/20 outline-none disabled:bg-slate-50" />
                      </label>
                    ))}
                    {ok && <Badge tone="green" icon="Check">Helyes</Badge>}
                    {bad && <Badge tone="red" icon="X">Helyes: {q.solutionText}</Badge>}
                  </div>
                </div>
              </div>
            </Card>
          );
        })}
      </div>

      {m.submitted && (
        <div className={`mt-6 rounded-2xl p-5 flex items-center gap-4 ${m.passed ? 'bg-emerald-50 border border-emerald-200' : 'bg-red-50 border border-red-200'}`}>
          <Icon name={m.passed ? 'PartyPopper' : 'RotateCcw'} size={28} className={m.passed ? 'text-emerald-600' : 'text-red-600'} />
          <div className="flex-1">
            <div className={`font-extrabold ${m.passed ? 'text-emerald-800' : 'text-red-800'}`}>{m.score} / 4 helyes — {m.passed ? 'Sikeres szintfelmérő!' : 'Nem érte el a 3 pontot'}</div>
            <div className={`text-sm ${m.passed ? 'text-emerald-600' : 'text-red-600'}`}>{m.passed ? 'A matematika feltétel teljesült.' : 'Próbálja újra — új feladatokat generálunk.'}</div>
          </div>
          {!m.passed && <Button variant="dark" icon="RefreshCw" onClick={retry}>Új teszt</Button>}
        </div>
      )}

      <StepNav onBack={back}
        onNext={m.submitted && m.passed ? next : grade}
        nextLabel={m.submitted && m.passed ? 'Tovább' : 'Beadás és pontozás'}
        nextDisabled={!m.submitted ? !allFilled : !m.passed}
        note={!m.submitted ? (allFilled ? 'Minden mező kitöltve' : 'Töltse ki az összes mezőt') : null} />
    </div>
  );
}

/* ---------- 6. INTERJÚFOGLALÁS ---------- */
const SLOTS = [
  { id: 's1', day: '2026. szept. 2.', time: '09:00', interviewer: 'Dr. Kovács István' },
  { id: 's2', day: '2026. szept. 2.', time: '10:30', interviewer: 'Dr. Kovács István' },
  { id: 's3', day: '2026. szept. 3.', time: '13:00', interviewer: 'Szabó Péter' },
  { id: 's4', day: '2026. szept. 4.', time: '11:00', interviewer: 'Szabó Péter' },
  { id: 's5', day: '2026. szept. 5.', time: '15:30', interviewer: 'Dr. Nagy Éva' },
];
function InterviewStep({ data, set, next, back }) {
  const iv = data.interview || {};
  const book = (slot) => set({ interview: { slotId: slot.id, slot, booked: true, teamsUrl: 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_' + Math.random().toString(36).slice(2, 11) } });
  return (
    <div>
      <StepHeader eyebrow="6. lépés" title="Online interjú foglalása"
        desc="A dokumentum-ellenőrzés és a szintfelmérő után foglalhat időpontot. A foglaláskor automatikusan létrejön a Microsoft Teams meeting." />
      {!iv.booked ? (
        <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-3">
          {SLOTS.map((s) => (
            <Card key={s.id} hover className="p-4" onClick={() => book(s)}>
              <div className="flex items-center gap-2 text-primary-600 font-bold"><Icon name="Calendar" size={16} /> {s.day}</div>
              <div className="text-2xl font-extrabold text-slate-900 mt-1">{s.time}</div>
              <div className="text-xs text-slate-400 mt-1">{s.interviewer}</div>
              <div className="mt-3"><Button variant="soft" size="sm" iconRight="ChevronRight" className="w-full">Foglalás</Button></div>
            </Card>
          ))}
        </div>
      ) : (
        <Card className="p-7 max-w-2xl">
          <div className="flex items-center gap-3 mb-5">
            <span className="w-12 h-12 rounded-2xl bg-emerald-50 text-emerald-600 flex items-center justify-center"><Icon name="CalendarCheck" size={26} /></span>
            <div><div className="font-extrabold text-slate-900 text-lg">Interjú lefoglalva</div><div className="text-sm text-slate-500">Megerősítő e-mailt küldtünk.</div></div>
          </div>
          <div className="grid sm:grid-cols-3 gap-4 mb-5">
            <div><div className="text-xs text-slate-400 font-bold uppercase">Időpont</div><div className="font-bold text-slate-900">{iv.slot.day}</div><div className="text-slate-600">{iv.slot.time}</div></div>
            <div><div className="text-xs text-slate-400 font-bold uppercase">Interjúztató</div><div className="font-bold text-slate-900">{iv.slot.interviewer}</div></div>
            <div><div className="text-xs text-slate-400 font-bold uppercase">Platform</div><div className="font-bold text-slate-900 flex items-center gap-1.5"><Icon name="Video" size={15} /> MS Teams</div></div>
          </div>
          <div className="rounded-xl bg-slate-50 border border-slate-200 p-3 flex items-center gap-3">
            <Icon name="Link" size={16} className="text-slate-400" />
            <span className="font-mono text-xs text-slate-500 truncate flex-1">{iv.teamsUrl}</span>
            <Badge tone="blue">automatikus</Badge>
          </div>
          <button onClick={() => set({ interview: {} })} className="text-xs text-slate-400 hover:text-slate-600 mt-4">Időpont módosítása</button>
        </Card>
      )}
      <StepNav onBack={back} onNext={next} nextDisabled={!iv.booked} nextLabel="Tovább a felvételi levélhez"
        note={iv.booked ? null : 'Válasszon egy időpontot'} />
    </div>
  );
}

Object.assign(window, { CheckStep, MathStep, InterviewStep });
