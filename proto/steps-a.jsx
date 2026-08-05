/* ============================================================
   Felvételi prototípus · LÉPÉSEK 1–3
   Regisztráció · Szakválasztás · Dokumentum-feltöltés
   ============================================================ */

/* ---------- 1. REGISZTRÁCIÓ ---------- */
function RegisterStep({ data, set, next }) {
  const a = data.account || {};
  const upd = (k, v) => set({ account: { ...a, [k]: v } });
  const valid = a.fullName && a.email && a.email.includes('@') && (a.password || '').length >= 4;
  return (
    <div>
      <StepHeader eyebrow="1. lépés" title="Fiók létrehozása"
        desc="Hozza létre jelentkezői fiókját. A megadott adatokat később az útlevél-ellenőrzés is felülírhatja." />
      <Card className="p-7 max-w-2xl">
        <div className="grid sm:grid-cols-2 gap-5">
          <div className="sm:col-span-2"><Field label="Teljes név" value={a.fullName} onChange={(v) => upd('fullName', v)} placeholder="Pl. Adaeze Okonkwo" required /></div>
          <Field label="E-mail" type="email" value={a.email} onChange={(v) => upd('email', v)} placeholder="nev@email.com" required />
          <Field label="Jelszó" type="password" value={a.password} onChange={(v) => upd('password', v)} placeholder="••••••" hint="Min. 4 karakter (demo)" required />
          <Combobox label="Állampolgárság" value={a.country} onChange={(v) => upd('country', v)} options={COUNTRIES} placeholder="Kezdjen el gépelni…" />
          <Field label="Születési dátum" type="date" value={a.birthDate} onChange={(v) => upd('birthDate', v)} />
        </div>
        <div className="flex items-center gap-2 mt-6 text-xs text-slate-400">
          <Icon name="ShieldCheck" size={14} /> A személyes adatokat a GDPR szerint kezeljük (prototípus).
        </div>
      </Card>
      <StepNav hideBack onNext={next} nextDisabled={!valid} nextLabel="Fiók létrehozása" />
    </div>
  );
}

/* ---------- 2. SZAKVÁLASZTÁS ---------- */
function ProgramsStep({ data, set, next, back }) {
  const selected = data.programs || [];
  const toggle = (id) => set({ programs: selected.includes(id) ? selected.filter((x) => x !== id) : [...selected, id] });
  const groups = [
    { key: 'undergraduate', label: 'Alapképzés (BSc)' },
    { key: 'graduate', label: 'Mesterképzés / Doktori (MA · MBA · PhD)' },
    { key: 'preparatory', label: 'Előkészítő kurzus' },
  ];
  return (
    <div>
      <StepHeader eyebrow="2. lépés" title="Szakválasztás"
        desc="Válassza ki a szakokat — egyszerre több szakra is jelentkezhet. A felvételi bírálat szakonként történik." />
      <div className="space-y-7">
        {groups.map((g) => (
          <div key={g.key}>
            <div className="text-xs font-bold uppercase tracking-wide text-slate-400 mb-3">{g.label}</div>
            <div className="grid sm:grid-cols-2 gap-3">
              {PROGRAMS.filter((p) => p.level === g.key).map((p) => {
                const on = selected.includes(p.id);
                return (
                  <Card key={p.id} hover active={on} onClick={() => toggle(p.id)} className="p-4 flex items-start gap-3">
                    <span className={`flex-none mt-0.5 w-5 h-5 rounded-md border-2 flex items-center justify-center ${on ? 'bg-primary-500 border-primary-500' : 'border-slate-300'}`}>
                      {on && <Icon name="Check" size={13} className="text-white" />}
                    </span>
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <span className="text-[10px] font-extrabold px-1.5 py-0.5 rounded bg-slate-100 text-slate-600">{p.code}</span>
                        <span className="font-bold text-slate-900 text-sm leading-tight">{p.name}</span>
                      </div>
                      <div className="text-xs text-slate-400 mt-1">{p.faculty}</div>
                      <div className="text-xs text-slate-500 mt-1.5 flex gap-3">
                        <span>{p.tuition.toLocaleString()} EUR / szemeszter</span>
                        <span>· {p.semesters} szemeszter · {p.ects} ECTS</span>
                      </div>
                    </div>
                  </Card>
                );
              })}
            </div>
          </div>
        ))}
      </div>
      <StepNav onBack={back} onNext={next} nextDisabled={selected.length === 0}
        note={selected.length ? `${selected.length} szak kiválasztva` : 'Válasszon legalább egy szakot'} />
    </div>
  );
}

/* ---------- 3. DOKUMENTUM-FELTÖLTÉS ---------- */
function FileRow({ doc, entry, onUpload }) {
  const ref = useRef(null);
  const uploaded = entry && entry.fileName;
  return (
    <Card className="p-4">
      <div className="flex items-center gap-4">
        <span className={`flex-none w-11 h-11 rounded-xl flex items-center justify-center ${uploaded ? 'bg-emerald-50 text-emerald-600' : 'bg-slate-100 text-slate-400'}`}>
          <Icon name={uploaded ? 'CheckCircle2' : doc.icon} size={22} />
        </span>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="font-bold text-slate-900 text-sm">{doc.label}</span>
            {doc.optional && <Badge tone="slate">opcionális</Badge>}
            {doc.ocr && <Badge tone="primary" icon="Sparkles">AI kinyerés</Badge>}
          </div>
          <div className="text-xs text-slate-400 mt-0.5 truncate">{uploaded ? entry.fileName : doc.hint}</div>
        </div>
        <input ref={ref} type="file" accept={doc.accept} className="hidden"
          onChange={(e) => { const f = e.target.files[0]; if (f) onUpload(doc, f.name); }} />
        {uploaded
          ? <Button variant="ghost" size="sm" icon="RefreshCw" onClick={() => ref.current.click()}>Csere</Button>
          : <Button variant="soft" size="sm" icon="Upload" onClick={() => ref.current.click()}>Feltöltés</Button>}
      </div>
    </Card>
  );
}

function DocumentsStep({ data, set, next, back }) {
  const docs = data.docs || {};
  const ex = data.extracted;
  const onUpload = (doc, fileName) => {
    const nextDocs = { ...docs, [doc.id]: { fileName, status: 'uploaded' } };
    const patch = { docs: nextDocs };
    if (doc.ocr) patch.extracted = mockPassportOCR(data.account || {});
    set(patch);
  };
  const setExtracted = (k, v) => set({ extracted: { ...ex, [k]: v } });
  const required = DOC_TYPES.filter((d) => !d.optional);
  const allReq = required.every((d) => docs[d.id] && docs[d.id].fileName);

  return (
    <div>
      <StepHeader eyebrow="3. lépés" title="Dokumentumok feltöltése"
        desc="Töltse fel a szükséges dokumentumokat PDF vagy kép formátumban. Az útlevélből az adatokat automatikusan kinyerjük." />
      <div className="grid lg:grid-cols-2 gap-6">
        <div className="space-y-3">
          {DOC_TYPES.map((d) => <FileRow key={d.id} doc={d} entry={docs[d.id]} onUpload={onUpload} />)}
        </div>
        <div>
          {ex ? (
            <Card className="p-5 sticky top-4">
              <div className="flex items-center justify-between mb-4">
                <div className="flex items-center gap-2 font-bold text-slate-900"><Icon name="Sparkles" size={18} className="text-primary-500" /> Kinyert adatok</div>
                <Badge tone="green" icon="CircleCheck">{ex.confidence}% biztos</Badge>
              </div>
              <p className="text-xs text-slate-400 mb-4">Az útlevélből automatikusan kinyert mezők. Kézzel ellenőrizhető és javítható.</p>
              <div className="space-y-3">
                <Field label="Név (útlevél szerint)" value={ex.name} onChange={(v) => setExtracted('name', v)} />
                <Field label="Útlevélszám" value={ex.passportNumber} onChange={(v) => setExtracted('passportNumber', v)} />
                <div className="grid grid-cols-2 gap-3">
                  <Field label="Ország" value={ex.country} onChange={(v) => setExtracted('country', v)} />
                  <Field label="Szül. dátum" type="date" value={ex.birthDate} onChange={(v) => setExtracted('birthDate', v)} />
                </div>
              </div>
            </Card>
          ) : (
            <Card className="p-8 border-dashed flex flex-col items-center justify-center text-center h-full min-h-[220px]">
              <Icon name="ScanLine" size={32} className="text-slate-300 mb-3" />
              <div className="font-semibold text-slate-500">AI adatkinyerés</div>
              <p className="text-xs text-slate-400 mt-1 max-w-xs">Töltse fel az útlevelet — a rendszer automatikusan kiolvassa a nevet, útlevélszámot és az állampolgárságot.</p>
            </Card>
          )}
        </div>
      </div>
      <StepNav onBack={back} onNext={next} nextDisabled={!allReq}
        note={allReq ? 'Minden kötelező dokumentum feltöltve' : 'Töltse fel a kötelező dokumentumokat'} />
    </div>
  );
}

Object.assign(window, { RegisterStep, ProgramsStep, DocumentsStep });
