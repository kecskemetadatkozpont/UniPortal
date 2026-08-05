// ============================================================
// whatsapp-webhook — a Meta ide küldi a beérkező üzeneteket és a
// kézbesítési státuszokat (sent / delivered / read / failed).
//
// FONTOS: ezt a függvényt JWT-ellenőrzés NÉLKÜL kell telepíteni, mert a Meta
// nem tud Supabase tokent küldeni:
//
//   supabase functions deploy whatsapp-webhook --no-verify-jwt
//
// A hitelesítést helyette két dolog adja:
//   1. GET — a Meta verifikációs kihívása a saját WHATSAPP_VERIFY_TOKEN-eddel.
//   2. POST — az X-Hub-Signature-256 fejléc HMAC-SHA256 ellenőrzése az app
//      secrettel. Enélkül bárki hamis üzeneteket írhatna az inboxba.
//
// A webhook URL, amit a Metánál be kell állítani:
//   https://<projekt-ref>.supabase.co/functions/v1/whatsapp-webhook
// ============================================================
import { createClient } from 'jsr:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const VERIFY_TOKEN = Deno.env.get('WHATSAPP_VERIFY_TOKEN') ?? '';
const APP_SECRET = Deno.env.get('WHATSAPP_APP_SECRET') ?? '';

const newId = () => 'WA-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8);

// Konstans idejű összehasonlítás — ne lehessen a választ időzítéssel kitalálni.
function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function signatureValid(raw: string, header: string | null) {
  if (!APP_SECRET) return null;              // nincs beállítva → a hívó dönt
  if (!header?.startsWith('sha256=')) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(APP_SECRET),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw));
  const hex = Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('');
  return safeEqual(hex, header.slice('sha256='.length));
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // ---------- 1. Meta verifikáció (a webhook beállításakor, egyszer) ----------
  if (req.method === 'GET') {
    const mode = url.searchParams.get('hub.mode');
    const token = url.searchParams.get('hub.verify_token');
    const challenge = url.searchParams.get('hub.challenge') ?? '';
    if (mode === 'subscribe' && VERIFY_TOKEN && token === VERIFY_TOKEN) {
      return new Response(challenge, { status: 200, headers: { 'Content-Type': 'text/plain' } });
    }
    return new Response('verification_failed', { status: 403 });
  }

  if (req.method !== 'POST') return new Response('method_not_allowed', { status: 405 });

  // ---------- 2. aláírás-ellenőrzés ----------
  const raw = await req.text();
  const valid = await signatureValid(raw, req.headers.get('x-hub-signature-256'));
  if (valid === false) return new Response('bad_signature', { status: 401 });
  // valid === null → nincs APP_SECRET beállítva. Ilyenkor átengedjük, de
  // megjelöljük, hogy az üzenet nem hitelesített forrásból jött.
  const unverified = valid === null;

  let body: any;
  try { body = JSON.parse(raw); } catch { return new Response('invalid_json', { status: 400 }); }
  if (body?.object !== 'whatsapp_business_account') return new Response('ignored', { status: 200 });

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);
  const now = new Date().toISOString();

  for (const entry of body.entry ?? []) {
    for (const change of entry.changes ?? []) {
      const value = change.value ?? {};

      // ---- beérkező üzenetek ----
      const contacts: Record<string, string> = {};
      for (const c of value.contacts ?? []) contacts[c.wa_id] = c.profile?.name ?? '';

      for (const m of value.messages ?? []) {
        const waId = m.from;
        const text =
          m.text?.body ??
          m.button?.text ??
          m.interactive?.list_reply?.title ??
          m.interactive?.button_reply?.title ??
          `[${m.type}]`;

        // A beérkezés nyitja meg a 24 órás ablakot — ezt tartjuk nyilván.
        await admin.from('wa_contacts').upsert({
          wa_id: waId,
          display_name: contacts[waId] || null,
          last_inbound_at: now,
          last_message_at: now,
        }, { onConflict: 'wa_id' });

        await admin.from('wa_messages').upsert({
          id: newId(),
          wa_message_id: m.id ?? null,
          wa_id: waId,
          direction: 'in',
          msg_type: m.type ?? 'text',
          body: text,
          status: 'received',
          error: unverified ? 'aláírás nem ellenőrizve (WHATSAPP_APP_SECRET hiányzik)' : null,
        }, { onConflict: 'wa_message_id', ignoreDuplicates: true });
      }

      // ---- kézbesítési státuszok a korábban küldött üzenetekre ----
      for (const s of value.statuses ?? []) {
        if (!s.id) continue;
        const patch: Record<string, unknown> = { status: s.status };
        if (s.errors?.length) patch.error = s.errors[0]?.title ?? s.errors[0]?.message ?? null;
        await admin.from('wa_messages').update(patch).eq('wa_message_id', s.id);
      }
    }
  }

  // A Metának mindig 200-at kell kapnia, különben újraküld és letiltja a webhookot.
  return new Response('ok', { status: 200 });
});
