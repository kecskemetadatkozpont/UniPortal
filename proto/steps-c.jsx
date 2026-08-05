/* ============================================================
   Felvételi prototípus · LÉPÉS 7
   Conditional Acceptance Letter — automatikus generálás
   (forrás: CAL_TC-IBE.docx), iktatószámmal és aláírás-blokkal
   ============================================================ */

function LetterStep({ data, set, back, onFinish }) {
  const L = data.letter || {};
  const selectedPrograms = (data.programs || []).map((id) => PROGRAMS.find((p) => p.id === id)).filter(Boolean);
  const admittedId = L.programId || (selectedPrograms[0] && selectedPrograms[0].id);
  const prog = PROGRAMS.find((p) => p.id === admittedId) || selectedPrograms[0];

  useEffect(() => { if (!L.fileNumber) set({ letter: { ...L, fileNumber: makeFileNumber('CAL'), issuedAt: '2026.06.29', programId: admittedId } }); }, []);
  if (!L.fileNumber || !prog) return null;

  const ex = data.extracted || {};
  const acc = data.account || {};
  const name = ex.name || acc.fullName || '—';
  const passport = ex.passportNumber || '—';
  const country = ex.country || acc.country || '—';

  const firstTwo = prog.tuition * 2;
  const total = firstTwo + FEES.application + FEES.dormitorySemester;
  const setProgram = (id) => set({ letter: { ...L, programId: id } });

  return (
    <div>
      <StepHeader eyebrow="7. lépés · automatikus generálás" title="Conditional Acceptance Letter"
        desc="A levél a jelentkező adataiból automatikusan, iktatószámmal generálódik. Az aláírás a Flintsign API-n keresztül kerül rá (későbbi integráció)." />

      {/* vezérlősáv (nem nyomtatódik) */}
      <div className="screen-only flex flex-wrap items-center gap-4 mb-5 bg-white border border-slate-200 rounded-2xl p-4">
        <div className="flex items-center gap-2">
          <span className="text-xs font-bold text-slate-500 uppercase">Felvett szak</span>
          <select value={admittedId} onChange={(e) => setProgram(e.target.value)}
            className="px-3 py-2 rounded-lg border border-slate-300 text-sm font-semibold focus:border-primary-500 outline-none">
            {selectedPrograms.map((p) => <option key={p.id} value={p.id}>{p.code} · {p.name}</option>)}
          </select>
        </div>
        <div className="flex-1" />
        <Badge tone="primary" icon="Hash">{L.fileNumber}</Badge>
        <Button variant="dark" icon="Printer" onClick={() => window.print()}>Nyomtatás / PDF</Button>
      </div>

      {/* a levél */}
      <div id="letter-doc" className="bg-white border border-slate-200 rounded-2xl shadow-sm mx-auto max-w-3xl">
        <div className="p-10 sm:p-14 text-slate-800" style={{ fontFamily: 'Newsreader, Georgia, serif' }}>
          {/* fejléc */}
          <div className="flex items-start justify-between pb-5 border-b-2 border-slate-900">
            <div className="flex items-center gap-3">
              <img src="nje-logo.svg" alt="NJE" style={{ height: 46 }} onError={(e) => { e.target.style.display = 'none'; }} />
              <div style={{ fontFamily: 'Inter, sans-serif' }}>
                <div className="font-extrabold text-slate-900 leading-tight">John von Neumann University</div>
                <div className="text-xs text-slate-500">Neumann János Egyetem · Kecskemét, Hungary</div>
              </div>
            </div>
            <div className="text-right text-xs text-slate-500" style={{ fontFamily: 'Inter, sans-serif' }}>
              <div className="font-bold text-slate-700">Iktatószám</div>
              <div className="font-mono">{L.fileNumber}</div>
            </div>
          </div>

          <h3 className="text-center text-xl font-bold tracking-[0.18em] uppercase mt-8 mb-7" style={{ fontFamily: 'Inter, sans-serif' }}>Conditional Acceptance Letter</h3>

          <div className="space-y-1.5 text-[15px] leading-relaxed">
            <p><strong>Date:</strong> {L.issuedAt}</p>
            <p><strong>Name:</strong> {name}</p>
            <p><strong>Passport number:</strong> {passport}</p>
            <p><strong>Country:</strong> {country}</p>
          </div>

          <p className="mt-6 text-[15px] leading-relaxed">Dear {name},</p>
          <p className="mt-3 text-[15px] leading-relaxed">Your application for admission to John von Neumann University has been reviewed. Your status is as follows:</p>

          <div className="my-4 pl-4 border-l-2 border-primary-400 text-[15px] leading-relaxed space-y-1">
            <p><strong>Academic program:</strong> [{prog.code}] {prog.name}</p>
            <p><strong>Tuition fee:</strong> EUR {prog.tuition.toLocaleString()} / semester</p>
            <p><strong>Length of the program:</strong> {prog.semesters} semesters ({prog.ects} ECTS credit points)</p>
          </div>

          <p className="text-[15px] leading-relaxed">You have submitted all necessary documents and met all stated requirements. We confirm that you are <strong>CONDITIONALLY ADMITTED</strong> to the program starting in September 2026. The University reserves the right to verify the validity of your documents; the Final Letter of Admission will be issued once your documents meet the legal requirements.</p>

          <p className="mt-4 font-bold text-[15px]">To receive the Final Letter of Admission, please transfer the following fees:</p>
          <table className="w-full text-[15px] my-3" style={{ fontFamily: 'Inter, sans-serif' }}>
            <tbody>
              <tr className="border-b border-slate-100"><td className="py-1.5">Application fee</td><td className="py-1.5 text-right font-semibold">EUR {FEES.application.toLocaleString()}</td></tr>
              <tr className="border-b border-slate-100"><td className="py-1.5">Tuition fee — first two semesters</td><td className="py-1.5 text-right font-semibold">EUR {firstTwo.toLocaleString()}</td></tr>
              <tr className="border-b border-slate-100"><td className="py-1.5">Dormitory fee — one semester</td><td className="py-1.5 text-right font-semibold">EUR {FEES.dormitorySemester.toLocaleString()}</td></tr>
              <tr><td className="py-2 font-extrabold">Altogether</td><td className="py-2 text-right font-extrabold text-primary-600">EUR {total.toLocaleString()}</td></tr>
            </tbody>
          </table>
          <p className="text-[15px] leading-relaxed">Final payment deadline: <strong>15th July 2026</strong>. A dormitory deposit of EUR {FEES.dormitoryDeposit} is payable after arrival.</p>

          <div className="mt-4 rounded-xl bg-slate-50 p-4 text-[13px] leading-relaxed" style={{ fontFamily: 'Inter, sans-serif' }}>
            <div className="font-bold text-slate-700 mb-1">Bank details</div>
            <div>Bank: {FEES.bank.name} · 1056 Budapest, Váci street 38., Hungary</div>
            <div>Account holder: Neumann János Egyetem</div>
            <div>IBAN: <span className="font-mono">{FEES.bank.iban}</span> · SWIFT: <span className="font-mono">{FEES.bank.swift}</span></div>
            <div className="text-slate-400 mt-1">In the “Information for beneficiary” field indicate your name and passport number.</div>
          </div>

          <p className="mt-5 text-[15px]">Should you have any questions, contact us at admission@nje.hu.</p>
          <p className="mt-5 text-[15px]">Yours sincerely,</p>

          {/* aláírás-blokk */}
          <div className="mt-8 flex items-end justify-between">
            <div>
              <div className="w-56 border-b border-slate-400 pb-1 mb-1 flex items-end h-12">
                <span className="text-primary-600 italic text-lg" style={{ fontFamily: 'Newsreader, serif' }}>Orsolya Krix</span>
              </div>
              <div className="text-sm font-bold text-slate-900" style={{ fontFamily: 'Inter, sans-serif' }}>Krix Orsolya</div>
              <div className="text-xs text-slate-500" style={{ fontFamily: 'Inter, sans-serif' }}>International Office · John von Neumann University</div>
            </div>
            <div className="text-right" style={{ fontFamily: 'Inter, sans-serif' }}>
              <div className="inline-flex items-center gap-1.5 text-[11px] font-bold text-slate-400 border border-dashed border-slate-300 rounded-lg px-2.5 py-1.5">
                <Icon name="PenTool" size={13} /> Flintsign digitális aláírás — később
              </div>
            </div>
          </div>
        </div>
      </div>

      <div className="screen-only">
        <StepNav onBack={back} onNext={onFinish} nextLabel="Folyamat lezárása" />
      </div>
    </div>
  );
}

Object.assign(window, { LetterStep });
