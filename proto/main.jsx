/* ============================================================
   Felvételi prototípus · FŐ ALKALMAZÁS
   Lépés-állapotgép + localStorage perzisztencia
   ============================================================ */
const { useState: useStateM, useEffect: useEffectM } = React;
const LS_KEY = 'nje_felveteli_proto_v1';

const STEPS = [
  { id: 'register', label: 'Regisztráció', hint: 'Fiók létrehozása', Comp: window.RegisterStep },
  { id: 'programs', label: 'Szakválasztás', hint: 'Egy vagy több szak', Comp: window.ProgramsStep },
  { id: 'documents', label: 'Dokumentumok', hint: 'Feltöltés + AI', Comp: window.DocumentsStep },
  { id: 'check', label: 'Ellenőrzés', hint: 'Check + csalásszűrés', Comp: window.CheckStep },
  { id: 'math', label: 'Matek teszt', hint: 'Szintfelmérő', Comp: window.MathStep },
  { id: 'interview', label: 'Interjú', hint: 'Teams foglalás', Comp: window.InterviewStep },
  { id: 'letter', label: 'Felvételi levél', hint: 'Conditional letter', Comp: window.LetterStep },
];

function load() { try { return JSON.parse(localStorage.getItem(LS_KEY)) || {}; } catch (e) { return {}; } }

function App() {
  const saved = load();
  const [step, setStep] = useStateM(saved.step || 0);
  const [maxReached, setMaxReached] = useStateM(saved.maxReached || 0);
  const [data, setData] = useStateM(saved.data || {});
  const [done, setDone] = useStateM(saved.done || false);

  useEffectM(() => {
    // a matek-kérdések függvényeket tartalmaznak → nem szerializálhatók; kihagyjuk a mentésből
    const safeData = { ...data };
    if (safeData.math) safeData.math = { ...safeData.math, questions: undefined };
    try { localStorage.setItem(LS_KEY, JSON.stringify({ step, maxReached, data: safeData, done })); } catch (e) {}
  }, [step, maxReached, data, done]);

  const set = (patch) => setData((d) => ({ ...d, ...patch }));
  const goto = (i) => { setStep(i); window.scrollTo({ top: 0 }); };
  const next = () => { const n = Math.min(step + 1, STEPS.length - 1); setMaxReached((m) => Math.max(m, n)); goto(n); };
  const back = () => goto(Math.max(step - 1, 0));
  const reset = () => { setStep(0); setMaxReached(0); setData({}); setDone(false); window.scrollTo({ top: 0 }); };

  const Cur = STEPS[step].Comp;
  const Icon = window.Icon;

  if (done) {
    return (
      <div className="min-h-screen flex items-center justify-center p-6">
        <div className="bg-white border border-slate-200 rounded-3xl shadow-xl max-w-lg w-full p-10 text-center">
          <div className="w-16 h-16 rounded-2xl bg-emerald-50 text-emerald-600 flex items-center justify-center mx-auto mb-5"><Icon name="CheckCheck" size={32} /></div>
          <h2 className="text-2xl font-extrabold text-slate-900">Jelentkezés lezárva</h2>
          <p className="text-slate-500 mt-2">A feltételes felvételi levelet kiállítottuk és iktattuk. A jelentkező megkapta e-mailben, az interjú a Teams-ben létrejött.</p>
          <div className="mt-4 inline-flex"><window.Badge tone="primary" icon="Hash">{(data.letter || {}).fileNumber || '—'}</window.Badge></div>
          <div className="mt-7"><window.Button variant="dark" icon="RotateCcw" onClick={reset}>Új jelentkezés indítása</window.Button></div>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex">
      {/* oldalsáv */}
      <aside className="screen-only w-72 flex-none bg-slate-100 border-r border-slate-200 p-5 hidden lg:flex flex-col">
        <div className="flex items-center gap-2.5 mb-7 px-2">
          <img src="nje-logo.svg" alt="" style={{ height: 32 }} onError={(e) => { e.target.style.display = 'none'; }} />
          <div>
            <div className="font-extrabold text-slate-900 leading-tight text-sm">UniPortal · Felvételi</div>
            <div className="text-[11px] text-slate-400">Neumann János Egyetem</div>
          </div>
        </div>
        <window.StepRail steps={STEPS} current={step} maxReached={maxReached} onJump={goto} />
        <div className="mt-auto pt-5">
          <button onClick={reset} className="text-xs text-slate-400 hover:text-slate-600 flex items-center gap-1.5 px-2">
            <Icon name="RotateCcw" size={13} /> Folyamat újraindítása
          </button>
        </div>
      </aside>

      {/* tartalom */}
      <main className="flex-1 min-w-0">
        {/* mobil lépésjelző */}
        <div className="screen-only lg:hidden sticky top-0 z-10 bg-white/90 backdrop-blur border-b border-slate-200 px-5 py-3 flex items-center justify-between">
          <span className="font-bold text-slate-900 text-sm">{step + 1}. {STEPS[step].label}</span>
          <span className="text-xs text-slate-400">{step + 1} / {STEPS.length}</span>
        </div>
        <div className="max-w-5xl mx-auto px-5 sm:px-8 py-8 sm:py-10">
          <Cur data={data} set={set} next={next} back={back} onFinish={() => { setDone(true); window.scrollTo({ top: 0 }); }} />
        </div>
      </main>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
