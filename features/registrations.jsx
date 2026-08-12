/* ============================================================
   UniPortal Pro — Regisztráció-jóváhagyás (superadmin)
   (az app.jsx moduljába fűzve — NINCS import; React, hookok,
    Lucide, sb, todayStr a scope-ban vannak)

   Minden új regisztráció `pending` státusszal jön létre
   (07_registration_approval.sql), és a superadmin dönt róla. A
   jogosultságot nem ez a felület adja: a profiles UPDATE-et RLS +
   a profiles_protect_privileges trigger engedi vagy tiltja, tehát
   más fiókból ugyanez a hívás elbukik.
   ============================================================ */

const REG_ASSIGNABLE_ROLES = ['STUDENT', 'AGENT', 'ADMISSIONS', 'FINANCE', 'ADMIN'];

const REG_ROLE_LABEL = {
  STUDENT: 'Hallgató', AGENT: 'Ügynök', ADMISSIONS: 'Felvételi',
  FINANCE: 'Pénzügy', ADMIN: 'Admin', SUPERADMIN: 'Superadmin',
};

const REG_STATUS_STYLE = {
  pending:  { label: 'Jóváhagyásra vár', cls: 'bg-amber-50 text-amber-700 border-amber-100' },
  approved: { label: 'Jóváhagyva',       cls: 'bg-emerald-50 text-emerald-700 border-emerald-100' },
  rejected: { label: 'Elutasítva',       cls: 'bg-red-50 text-red-600 border-red-100' },
};

async function REG_loadProfiles() {
  if (!window.sb) return [];
  const { data, error } = await window.sb.from('profiles').select('*').order('created_at', { ascending: false });
  if (error) throw error;
  return data || [];
}

// A superadmin döntése. `role` csak jóváhagyáskor számít.
async function REG_decide(row, status, role, reason) {
  const patch = { approval_status: status };
  if (status === 'approved' && role) patch.role = role;
  if (status === 'rejected') patch.rejected_reason = reason || null;
  const { error } = await window.sb.from('profiles').update(patch).eq('id', row.id);
  if (error) throw error;
}

// Meglévő felhasználó szerepkörének átállítása. Ugyanaz az RLS + trigger
// engedélyezi, mint a jóváhagyást: a profiles_protect_privileges csak akkor
// engedi át a `role` mezőt, ha superadmin írja.
async function REG_setRole(row, role) {
  const { error } = await window.sb.from('profiles').update({ role }).eq('id', row.id);
  if (error) throw error;
}

/* Hány regisztráció vár döntésre? A belépéskori kezdőnézethez is ezt hívjuk. */
async function REG_pendingCount() {
  if (!window.sb) return 0;
  try {
    const { count, error } = await window.sb
      .from('profiles').select('id', { count: 'exact', head: true }).eq('approval_status', 'pending');
    return error ? 0 : (count || 0);
  } catch (e) { return 0; }
}

function REG_fmtDate(v) {
  if (!v) return '—';
  try { return new Date(v).toLocaleString('hu-HU', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }); }
  catch (e) { return String(v).slice(0, 16); }
}

function RegistrationsView({ user, onCountChange }) {
  const [rows, setRows] = useState(null);
  const [err, setErr] = useState('');
  const [tab, setTab] = useState('pending');
  const [busyId, setBusyId] = useState('');
  const [roleDraft, setRoleDraft] = useState({});   // profileId -> role
  const [rejecting, setRejecting] = useState(null); // profile row
  const [reason, setReason] = useState('');
  const [q, setQ] = useState('');

  const load = async () => {
    setErr('');
    try {
      const data = await REG_loadProfiles();
      setRows(data);
      onCountChange && onCountChange(data.filter(r => r.approval_status === 'pending').length);
    } catch (e) {
      setRows([]);
      setErr(e && e.message ? e.message : 'A regisztrációk betöltése nem sikerült.');
    }
  };
  useEffect(() => { load(); }, []);

  const changeRole = async (row, role) => {
    setBusyId(row.id); setErr('');
    try { await REG_setRole(row, role); await load(); }
    catch (e) { setErr((e && e.message) || 'A szerepkör módosítása nem sikerült.'); }
    finally { setBusyId(''); }
  };

  const decide = async (row, status, role, why) => {
    setBusyId(row.id); setErr('');
    try { await REG_decide(row, status, role, why); await load(); }
    catch (e) { setErr((e && e.message) || 'A módosítás nem sikerült.'); }
    finally { setBusyId(''); setRejecting(null); setReason(''); }
  };

  if (rows === null) {
    return (
      <div className="p-8 flex items-center gap-3 text-slate-400">
        <div className="w-5 h-5 border-2 border-primary border-t-transparent rounded-full animate-spin"></div>
        Regisztrációk betöltése…
      </div>
    );
  }

  const match = (r) => {
    const needle = q.trim().toLowerCase();
    if (!needle) return true;
    return String(r.email || '').toLowerCase().includes(needle)
        || String(r.name || '').toLowerCase().includes(needle);
  };
  const pending  = rows.filter(r => r.approval_status === 'pending').filter(match);
  const active   = rows.filter(r => r.approval_status === 'approved').filter(match);
  const rejected = rows.filter(r => r.approval_status === 'rejected').filter(match);
  const list = tab === 'pending' ? pending : tab === 'users' ? active : rejected;

  return (
    <div className="p-8 max-w-6xl">
      <div className="flex items-start justify-between gap-6 flex-wrap">
        <div>
          <p className="text-[11px] font-black text-primary uppercase tracking-widest">Hozzáférés-kezelés</p>
          <h1 className="text-3xl font-black text-slate-900 tracking-tight mt-1">Regisztrációk</h1>
          <p className="text-slate-500 mt-2 max-w-2xl leading-relaxed">
            Minden új fiók jóváhagyásra vár. A jóváhagyásig a felhasználó be tud lépni,
            de egyetlen adatot sem lát — ezt az adatbázis érvényesíti, nem csak a felület.
          </p>
        </div>
        <button onClick={load} className="px-4 py-2.5 rounded-xl text-sm font-bold text-slate-600 bg-white border border-slate-200 hover:bg-slate-50 transition-colors flex items-center gap-2">
          <Lucide.RefreshCw size={15} /> Frissítés
        </button>
      </div>

      {err && (
        <div className="mt-6 text-sm font-semibold text-red-600 bg-red-50 border border-red-100 rounded-xl px-4 py-3">{err}</div>
      )}

      <div className="flex items-center gap-2 mt-7 flex-wrap">
        {[['pending', 'Jóváhagyásra vár', pending.length], ['users', 'Felhasználók', active.length], ['rejected', 'Elutasítva', rejected.length]].map(([k, label, n]) => (
          <button key={k} onClick={() => setTab(k)}
            className={'px-4 py-2 rounded-xl text-sm font-bold transition-colors ' +
              (tab === k ? 'bg-slate-900 text-white' : 'bg-white text-slate-500 border border-slate-200 hover:bg-slate-50')}>
            {label} <span className={'ml-1 ' + (tab === k ? 'text-white/60' : 'text-slate-400')}>{n}</span>
          </button>
        ))}
        <div className="relative ml-auto">
          <Lucide.Search size={15} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-300" />
          <input value={q} onChange={e => setQ(e.target.value)} placeholder="Keresés név vagy e-mail szerint…"
            className="w-64 bg-white border border-slate-200 rounded-xl pl-9 pr-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20" />
        </div>
      </div>

      {list.length === 0 ? (
        <div className="mt-6 bg-white rounded-3xl border border-slate-100 p-14 text-center">
          <div className="w-14 h-14 rounded-2xl bg-slate-50 text-slate-300 flex items-center justify-center mx-auto mb-4">
            <Lucide.UserCheck size={26} />
          </div>
          <p className="font-bold text-slate-700">
            {q.trim() ? 'Nincs találat' : tab === 'pending' ? 'Nincs függő regisztráció' : tab === 'users' ? 'Még nincs jóváhagyott felhasználó' : 'Nincs elutasított regisztráció'}
          </p>
          <p className="text-sm text-slate-400 mt-1">
            {q.trim() ? 'Próbálj más nevet vagy e-mail-címet.'
              : tab === 'pending' ? 'Az új jelentkezők és ügyintézők itt fognak megjelenni.'
              : tab === 'users' ? 'A jóváhagyott fiókok itt jelennek meg, szerepkörrel együtt.'
              : 'Az elutasított fiókok itt gyűlnek.'}
          </p>
        </div>
      ) : (
        <div className="mt-6 bg-white rounded-3xl border border-slate-100 overflow-hidden">
          <table className="w-full">
            <thead>
              <tr className="text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
                <th className="text-left px-5 py-3">Felhasználó</th>
                <th className="text-left px-5 py-3">{tab === 'users' ? 'Szerepkör' : 'Kért szerepkör'}</th>
                <th className="text-left px-5 py-3">Regisztrált</th>
                <th className="text-left px-5 py-3">Állapot</th>
                <th className="text-right px-5 py-3">Döntés</th>
              </tr>
            </thead>
            <tbody>
              {list.map(r => {
                const st = REG_STATUS_STYLE[r.approval_status] || REG_STATUS_STYLE.pending;
                const chosen = roleDraft[r.id] || r.requested_role || r.role || 'STUDENT';
                const busy = busyId === r.id;
                const isSelf = !!(user && (user.id === r.id || user.email === r.email));
                return (
                  <tr key={r.id} className="border-b border-slate-50 last:border-0">
                    <td className="px-5 py-4">
                      <div className="font-bold text-slate-800">{r.name || '—'}</div>
                      <div className="text-[13px] text-slate-400">{r.email}</div>
                    </td>
                    <td className="px-5 py-4 text-sm font-semibold text-slate-600">
                      {tab === 'users' ? (
                        isSelf ? (
                          // A saját sorát senki nem írhatja át — különben a superadmin
                          // egy félrekattintással kizárná magát a jóváhagyásból.
                          <span className="inline-flex items-center gap-1.5 text-slate-400">
                            <Lucide.Lock size={13} /> {REG_ROLE_LABEL[r.role] || r.role}
                          </span>
                        ) : r.role === 'SUPERADMIN' ? (
                          <span className="inline-flex items-center gap-1.5 text-primary font-bold">
                            <Lucide.ShieldCheck size={13} /> Superadmin
                          </span>
                        ) : (
                          <select
                            value={r.role || 'STUDENT'}
                            disabled={busy}
                            onChange={e => changeRole(r, e.target.value)}
                            className="text-[13px] font-semibold bg-slate-50 border border-slate-200 rounded-xl px-3 py-2 focus:outline-none focus:ring-2 focus:ring-primary/20 disabled:opacity-50"
                          >
                            {REG_ASSIGNABLE_ROLES.map(role => (
                              <option key={role} value={role}>{REG_ROLE_LABEL[role]}</option>
                            ))}
                          </select>
                        )
                      ) : (
                        REG_ROLE_LABEL[r.requested_role || r.role] || r.requested_role || r.role || '—'
                      )}
                    </td>
                    <td className="px-5 py-4 text-[13px] text-slate-500">{REG_fmtDate(r.created_at)}</td>
                    <td className="px-5 py-4">
                      <span className={'inline-block px-2.5 py-1 rounded-lg text-[11px] font-black border ' + st.cls}>{st.label}</span>
                      {r.approval_status === 'approved' && r.role && (
                        <div className="text-[11px] text-slate-400 mt-1">mint {REG_ROLE_LABEL[r.role] || r.role}</div>
                      )}
                      {r.approval_status === 'rejected' && r.rejected_reason && (
                        <div className="text-[11px] text-slate-400 mt-1">{r.rejected_reason}</div>
                      )}
                    </td>
                    <td className="px-5 py-4">
                      {r.approval_status === 'pending' ? (
                        <div className="flex items-center gap-2 justify-end">
                          <select
                            value={chosen}
                            onChange={e => setRoleDraft(d => ({ ...d, [r.id]: e.target.value }))}
                            className="text-[13px] font-semibold bg-slate-50 border border-slate-200 rounded-xl px-3 py-2 focus:outline-none focus:ring-2 focus:ring-primary/20"
                            title="Szerepkör a jóváhagyáskor"
                          >
                            {REG_ASSIGNABLE_ROLES.map(role => (
                              <option key={role} value={role}>{REG_ROLE_LABEL[role]}</option>
                            ))}
                          </select>
                          <button disabled={busy} onClick={() => decide(r, 'approved', chosen)}
                            className="px-3 py-2 rounded-xl text-[13px] font-bold text-white bg-emerald-600 hover:bg-emerald-700 disabled:opacity-50 transition-colors flex items-center gap-1.5">
                            <Lucide.Check size={15} /> {busy ? '…' : 'Jóváhagyás'}
                          </button>
                          <button disabled={busy} onClick={() => { setRejecting(r); setReason(''); }}
                            className="px-3 py-2 rounded-xl text-[13px] font-bold text-red-600 bg-red-50 hover:bg-red-100 disabled:opacity-50 transition-colors">
                            Elutasítás
                          </button>
                        </div>
                      ) : (
                        <div className="flex items-center gap-2 justify-end">
                          {r.approval_status === 'rejected' && (
                            <button disabled={busy} onClick={() => decide(r, 'approved', r.requested_role || r.role || 'STUDENT')}
                              className="px-3 py-2 rounded-xl text-[13px] font-bold text-emerald-700 bg-emerald-50 hover:bg-emerald-100 disabled:opacity-50 transition-colors">
                              Mégis jóváhagyom
                            </button>
                          )}
                          {r.approval_status === 'approved' && !isSelf && r.role !== 'SUPERADMIN' && (
                            <button disabled={busy} onClick={() => decide(r, 'pending')}
                              className="px-3 py-2 rounded-xl text-[13px] font-bold text-slate-500 bg-slate-50 hover:bg-slate-100 disabled:opacity-50 transition-colors">
                              Hozzáférés visszavonása
                            </button>
                          )}
                          {busy && <Lucide.Loader2 size={15} className="animate-spin text-slate-400" />}
                        </div>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {rejecting && (
        <div className="fixed inset-0 z-[80] bg-slate-900/50 backdrop-blur-sm flex items-center justify-center p-6" onClick={() => setRejecting(null)}>
          <div className="bg-white rounded-3xl shadow-2xl max-w-md w-full p-7" onClick={e => e.stopPropagation()}>
            <h3 className="text-lg font-black text-slate-900">Regisztráció elutasítása</h3>
            <p className="text-sm text-slate-500 mt-1.5">{rejecting.email}</p>
            <label className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mt-6 mb-2">Indoklás (opcionális)</label>
            <input value={reason} onChange={e => setReason(e.target.value)} autoFocus
              placeholder="pl. nem azonosítható jelentkező"
              className="w-full bg-slate-50 border border-slate-100 rounded-2xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20" />
            <div className="flex items-center gap-2 justify-end mt-6">
              <button onClick={() => setRejecting(null)} className="px-4 py-2.5 rounded-xl text-sm font-bold text-slate-500 hover:bg-slate-50 transition-colors">Mégsem</button>
              <button onClick={() => decide(rejecting, 'rejected', null, reason)}
                className="px-4 py-2.5 rounded-xl text-sm font-bold text-white bg-red-600 hover:bg-red-700 transition-colors">Elutasítás</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

/* ---------- a jóváhagyásra váró felhasználó képernyője ---------- */
function PendingApprovalScreen({ user, onLogout }) {
  // `user` here is the app-level currentUser, which normalises the profile's
  // approval_status onto `status`.
  const rejected = user.status === 'rejected';
  return (
    <div className="min-h-screen bg-slate-900 flex items-center justify-center p-6 font-sans">
      <div className="max-w-md w-full bg-white rounded-3xl shadow-2xl p-10 text-center">
        <div className={'w-16 h-16 rounded-2xl flex items-center justify-center mx-auto mb-6 ' +
          (rejected ? 'bg-red-50 text-red-500' : 'bg-amber-50 text-amber-500')}>
          {rejected ? <Lucide.UserX size={30} /> : <Lucide.Clock size={30} />}
        </div>
        <h1 className="text-2xl font-black text-slate-900 tracking-tight">
          {rejected ? 'A regisztrációt elutasítottuk' : 'Jóváhagyásra vár'}
        </h1>
        <p className="text-slate-500 text-sm mt-3 leading-relaxed">
          {rejected ? (
            <>A(z) <span className="font-bold text-slate-700">{user.email}</span> fiókhoz tartozó
            hozzáférési kérelmet a rendszergazda elutasította.
            {user.rejected_reason ? <> Indoklás: <span className="font-semibold text-slate-600">{user.rejected_reason}</span></> : null}</>
          ) : (
            <>Köszönjük a regisztrációt! A(z) <span className="font-bold text-slate-700">{user.email}</span> fiókot
            a rendszergazdának jóvá kell hagynia, mielőtt beléphetsz. Erről e-mailben nem küldünk
            értesítést — próbáld meg később újra a bejelentkezést.</>
          )}
        </p>
        <div className="mt-8 space-y-2">
          <button onClick={() => window.location.reload()}
            className="w-full py-3.5 rounded-2xl text-sm font-bold text-white bg-primary hover:bg-primary/90 transition-colors">
            Állapot frissítése
          </button>
          <button onClick={onLogout}
            className="w-full py-3.5 rounded-2xl text-sm font-bold text-slate-500 hover:bg-slate-50 transition-colors">
            Kijelentkezés
          </button>
        </div>
      </div>
    </div>
  );
}
