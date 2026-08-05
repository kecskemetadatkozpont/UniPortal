// ============================================================
// whatsapp-send — kimenő WhatsApp üzenet a Meta Cloud API-n át
//
// Miért Edge Function: a WhatsApp access token soha nem kerülhet a
// böngészőbe. A statikus oldal ezt a függvényt hívja a bejelentkezett
// felhasználó JWT-jével; a token csak itt, szerveroldalon létezik.
//
// Ha a Meta-adatok nincsenek beállítva, a függvény SZIMULÁL: az üzenetet
// elmenti `simulated = true` jelöléssel, hibát nem dob. Így a CRM inbox már
// a Meta-fiók meglétele előtt is valódi, megosztott adatot használ, és a
// későbbi élesítés csak secretek beállítása — kódmódosítás nélkül.
//
// Deploy:  supabase functions deploy whatsapp-send
// Secretek: supabase secrets set WHATSAPP_ACCESS_TOKEN=… WHATSAPP_PHONE_NUMBER_ID=…
// ============================================================
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const WA_TOKEN = Deno.env.get('WHATSAPP_ACCESS_TOKEN') ?? '';
const WA_PHONE_ID = Deno.env.get('WHATSAPP_PHONE_NUMBER_ID') ?? '';
const WA_VERSION = Deno.env.get('WHATSAPP_API_VERSION') ?? 'v21.0';

// A Cloud API csak számjegyeket fogad (E.164, + nélkül).
const normalise = (raw: string) => String(raw ?? '').replace(/[^\d]/g, '').replace(/^0+/, '');

const newId = () => 'WA-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  // ---- 1. ki hívja? Csak bejelentkezett ügyintéző küldhet. ----
  const authHeader = req.headers.get('Authorization') ?? '';
  const caller = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });

  const { data: userData } = await caller.auth.getUser();
  const user = userData?.user;
  if (!user) return json({ error: 'unauthorised' }, 401);

  const { data: isStaff, error: staffErr } = await caller.rpc('is_staff');
  if (staffErr) return json({ error: 'staff_check_failed', detail: staffErr.message }, 500);
  if (!isStaff) return json({ error: 'forbidden', detail: 'Csak ügyintéző küldhet WhatsApp üzenetet.' }, 403);

  // ---- 2. bemenet ----
  let payload: Record<string, any>;
  try { payload = await req.json(); } catch { return json({ error: 'invalid_json' }, 400); }

  const to = normalise(payload.to);
  const text: string = (payload.text ?? '').toString().trim();
  const template: string = (payload.template ?? '').toString().trim();
  const language: string = (payload.language ?? 'hu').toString();
  const components = Array.isArray(payload.components) ? payload.components : [];

  if (!to) return json({ error: 'missing_to' }, 400);
  if (!text && !template) return json({ error: 'missing_body', detail: 'Szöveg vagy sablonnév kötelező.' }, 400);

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);

  // ---- 3. a 24 órás ablak ----
  // A Meta csak akkor engedi a szabad szöveget, ha a partner az elmúlt 24
  // órában írt. Ezt itt is ellenőrizzük, hogy ne a Graph API hibájából
  // derüljön ki — az üzenet így el sem indul, és nem kerül a naplóba sikeresként.
  if (!template) {
    const { data: open } = await admin.rpc('wa_window_open', { p_wa_id: to });
    if (open === false) {
      return json({
        error: 'window_closed',
        detail: 'A 24 órás ablak lezárult: ehhez a partnerhez csak jóváhagyott sablonnal lehet üzenetet kezdeményezni.',
      }, 409);
    }
  }

  // ---- 4. küldés (vagy szimuláció) ----
  const live = Boolean(WA_TOKEN && WA_PHONE_ID);
  let waMessageId: string | null = null;
  let status = 'sent';
  let errorText: string | null = null;

  if (live) {
    const body = template
      ? { messaging_product: 'whatsapp', to, type: 'template', template: { name: template, language: { code: language }, components } }
      : { messaging_product: 'whatsapp', recipient_type: 'individual', to, type: 'text', text: { body: text } };

    try {
      const res = await fetch(`https://graph.facebook.com/${WA_VERSION}/${WA_PHONE_ID}/messages`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${WA_TOKEN}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const data = await res.json();
      if (!res.ok) {
        status = 'failed';
        errorText = data?.error?.message ?? `HTTP ${res.status}`;
      } else {
        waMessageId = data?.messages?.[0]?.id ?? null;
      }
    } catch (e) {
      status = 'failed';
      errorText = (e as Error).message;
    }
  }

  // ---- 5. naplózás ----
  const row = {
    id: newId(),
    wa_message_id: waMessageId,
    wa_id: to,
    direction: 'out',
    msg_type: template ? 'template' : 'text',
    body: template ? (text || `[sablon: ${template}]`) : text,
    template_name: template || null,
    status,
    error: errorText,
    sent_by: user.email ?? null,
    simulated: !live,
  };
  const { error: insErr } = await admin.from('wa_messages').insert(row);
  if (insErr) return json({ error: 'db_insert_failed', detail: insErr.message }, 500);

  await admin.from('wa_contacts')
    .upsert({ wa_id: to, last_message_at: new Date().toISOString() }, { onConflict: 'wa_id' });

  return json({
    ok: status !== 'failed',
    simulated: !live,
    status,
    message_id: waMessageId,
    error: errorText,
  }, status === 'failed' ? 502 : 200);
});
