/* ============================================================
   UniPortal — Felvételi prototípus · KÖZÖS UI ELEMEK
   (Tailwind osztályok + lucide UMD ikonok)
   ============================================================ */
const { useState, useEffect, useRef } = React;

/* ---- Ikon (lucide UMD) ---- */
function Icon({ name, size = 20, strokeWidth = 2, className = '', style }) {
  const L = window.lucide || {};
  const lib = L.icons || L;
  const lc = name.charAt(0).toLowerCase() + name.slice(1);
  let data = lib[name] || lib[lc] || L[name] || L[lc];
  const blank = React.createElement('span', { className, style: { display: 'inline-block', width: size, height: size, ...style } });
  if (!data) return blank;
  // lucide UMD shape: ["svg", attrsObject, [["path",{...}], ...]] → take children at [2]
  if (Array.isArray(data) && data[0] === 'svg' && Array.isArray(data[2])) data = data[2];
  // other builds: [name, nodes] or {children}
  if (Array.isArray(data) && typeof data[0] === 'string' && Array.isArray(data[1])) data = data[1];
  if (data && !Array.isArray(data) && Array.isArray(data.children)) data = data.children;
  if (!Array.isArray(data)) return blank;
  const kids = [];
  data.forEach((node, i) => {
    if (Array.isArray(node) && typeof node[0] === 'string') kids.push(React.createElement(node[0], { key: i, ...(node[1] || {}) }));
  });
  if (!kids.length) return blank;
  return React.createElement('svg', {
    width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
    stroke: 'currentColor', strokeWidth, strokeLinecap: 'round', strokeLinejoin: 'round',
    className, style,
  }, kids);
}

/* ---- Gomb ---- */
function Button({ children, onClick, variant = 'primary', size = 'md', disabled, className = '', icon, iconRight }) {
  const base = 'inline-flex items-center justify-center gap-2 font-semibold rounded-xl transition-all disabled:opacity-40 disabled:cursor-not-allowed';
  const sizes = { sm: 'px-3 py-1.5 text-sm', md: 'px-5 py-2.5 text-sm', lg: 'px-7 py-3.5 text-base' };
  const variants = {
    primary: 'bg-primary-500 text-white hover:bg-primary-600 shadow-lg shadow-primary-500/20',
    soft: 'bg-primary-50 text-primary-700 hover:bg-primary-100',
    ghost: 'text-slate-600 hover:bg-slate-100',
    outline: 'border border-slate-300 text-slate-700 hover:bg-slate-50 bg-white',
    dark: 'bg-slate-900 text-white hover:bg-slate-800',
  };
  return (
    <button onClick={onClick} disabled={disabled} className={`${base} ${sizes[size]} ${variants[variant]} ${className}`}>
      {icon && <Icon name={icon} size={size === 'lg' ? 20 : 16} />}
      {children}
      {iconRight && <Icon name={iconRight} size={size === 'lg' ? 20 : 16} />}
    </button>
  );
}

/* ---- Badge ---- */
function Badge({ children, tone = 'slate', icon }) {
  const tones = {
    slate: 'bg-slate-100 text-slate-600',
    green: 'bg-emerald-50 text-emerald-700',
    amber: 'bg-amber-50 text-amber-700',
    red: 'bg-red-50 text-red-700',
    primary: 'bg-primary-50 text-primary-700',
    blue: 'bg-sky-50 text-sky-700',
  };
  return (
    <span className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-bold ${tones[tone]}`}>
      {icon && <Icon name={icon} size={12} />}{children}
    </span>
  );
}

/* ---- Kártya ---- */
function Card({ children, className = '', onClick, active, hover }) {
  return (
    <div onClick={onClick}
      className={`bg-white rounded-2xl border ${active ? 'border-primary-500 ring-2 ring-primary-500/20' : 'border-slate-200'} ${hover ? 'hover:border-slate-300 hover:shadow-md cursor-pointer' : ''} transition-all ${className}`}>
      {children}
    </div>
  );
}

/* ---- Beviteli mező ---- */
function Field({ label, value, onChange, type = 'text', placeholder, hint, required }) {
  return (
    <label className="block">
      <span className="block text-xs font-bold text-slate-500 uppercase tracking-wide mb-1.5">{label}{required && <span className="text-primary-500"> *</span>}</span>
      <input
        type={type} value={value || ''} placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        className="w-full px-3.5 py-2.5 rounded-xl border border-slate-300 text-sm text-slate-900 placeholder-slate-400 focus:border-primary-500 focus:ring-2 focus:ring-primary-500/20 outline-none transition-all"
      />
      {hint && <span className="block text-xs text-slate-400 mt-1">{hint}</span>}
    </label>
  );
}

/* ---- Lépés-sáv (oldalsó) ---- */
function StepRail({ steps, current, maxReached, onJump }) {
  return (
    <nav className="space-y-1">
      {steps.map((s, i) => {
        const done = i < current;
        const active = i === current;
        const reachable = i <= maxReached;
        return (
          <button key={s.id} disabled={!reachable}
            onClick={() => reachable && onJump(i)}
            className={`w-full flex items-center gap-3 px-3 py-2.5 rounded-xl text-left transition-all ${active ? 'bg-white shadow-sm' : reachable ? 'hover:bg-white/60' : 'opacity-40 cursor-not-allowed'}`}>
            <span className={`flex-none w-7 h-7 rounded-lg flex items-center justify-center text-xs font-bold ${done ? 'bg-emerald-500 text-white' : active ? 'bg-primary-500 text-white' : 'bg-slate-200 text-slate-500'}`}>
              {done ? <Icon name="Check" size={15} /> : i + 1}
            </span>
            <span className="min-w-0">
              <span className={`block text-sm font-semibold leading-tight ${active ? 'text-slate-900' : 'text-slate-600'}`}>{s.label}</span>
              <span className="block text-[11px] text-slate-400 leading-tight truncate">{s.hint}</span>
            </span>
          </button>
        );
      })}
    </nav>
  );
}

/* ---- Lépés fejléc ---- */
function StepHeader({ eyebrow, title, desc }) {
  return (
    <div className="mb-7">
      <div className="text-xs font-bold uppercase tracking-[0.14em] text-primary-600 mb-2">{eyebrow}</div>
      <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">{title}</h2>
      {desc && <p className="text-slate-500 mt-2 max-w-2xl">{desc}</p>}
    </div>
  );
}

/* ---- Lábléc navigáció ---- */
function StepNav({ onBack, onNext, nextLabel = 'Tovább', nextDisabled, backLabel = 'Vissza', hideBack, note }) {
  return (
    <div className="flex items-center justify-between mt-8 pt-6 border-t border-slate-200">
      <div>{!hideBack && <Button variant="ghost" icon="ChevronLeft" onClick={onBack}>{backLabel}</Button>}</div>
      <div className="flex items-center gap-4">
        {note && <span className="text-xs text-slate-400">{note}</span>}
        {onNext && <Button onClick={onNext} disabled={nextDisabled} iconRight="ChevronRight" size="lg">{nextLabel}</Button>}
      </div>
    </div>
  );
}

/* ---- Kereshető legördülő (combobox) ---- */
function Combobox({ label, value, onChange, options, placeholder, required, hint }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState('');
  const ref = useRef(null);
  useEffect(() => {
    const h = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', h);
    return () => document.removeEventListener('mousedown', h);
  }, []);
  const needle = (open ? q : '').toLowerCase();
  const filtered = options.filter((o) => o.toLowerCase().includes(needle)).slice(0, 80);
  return (
    <label className="block relative" ref={ref}>
      <span className="block text-xs font-bold text-slate-500 uppercase tracking-wide mb-1.5">{label}{required && <span className="text-primary-500"> *</span>}</span>
      <div className="relative">
        <input
          value={open ? q : (value || '')} placeholder={placeholder}
          onFocus={() => { setOpen(true); setQ(''); }}
          onChange={(e) => { setQ(e.target.value); setOpen(true); }}
          className="w-full px-3.5 py-2.5 pr-9 rounded-xl border border-slate-300 text-sm text-slate-900 placeholder-slate-400 focus:border-primary-500 focus:ring-2 focus:ring-primary-500/20 outline-none transition-all"
        />
        <Icon name="ChevronsUpDown" size={16} className="text-slate-400 absolute right-3 top-1/2 -translate-y-1/2 pointer-events-none" />
      </div>
      {open && (
        <div className="absolute z-30 mt-1 w-full max-h-56 overflow-auto bg-white border border-slate-200 rounded-xl shadow-xl py-1">
          {filtered.length ? filtered.map((o) => (
            <button key={o} type="button"
              onMouseDown={(e) => { e.preventDefault(); onChange(o); setOpen(false); }}
              className="w-full text-left px-3.5 py-2 text-sm hover:bg-primary-50 flex items-center justify-between">
              <span className={value === o ? 'font-semibold text-primary-700' : 'text-slate-700'}>{o}</span>
              {value === o && <Icon name="Check" size={14} className="text-primary-500" />}
            </button>
          )) : <div className="px-3.5 py-2 text-sm text-slate-400">Nincs találat</div>}
        </div>
      )}
      {hint && <span className="block text-xs text-slate-400 mt-1">{hint}</span>}
    </label>
  );
}

Object.assign(window, { Icon, Button, Badge, Card, Field, Combobox, StepRail, StepHeader, StepNav });
