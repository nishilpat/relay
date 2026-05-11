/**
 * Relay Proxy Worker
 *
 * Proxies requests to Claude, ElevenLabs, AssemblyAI, and Google Sheets so
 * no API keys or credentials ever ship in the app or relay-server.
 * All secrets are stored as Cloudflare Worker secrets.
 *
 * Routes:
 *   POST /chat              → Anthropic Messages API (streaming or non-streaming)
 *   POST /tts               → ElevenLabs TTS API
 *   POST /transcribe-token  → AssemblyAI temp token
 *   POST /sheets-append     → Google Sheets API — append one row
 *   GET  /sheets-test       → Google Sheets API — verify credentials + sheet access
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  GOOGLE_CLIENT_EMAIL: string;
  GOOGLE_PRIVATE_KEY: string;  // service account private key (PEM format, newlines as \n)
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    try {
      // Google Sheets test uses GET; everything else uses POST.
      if (request.method === "GET" && url.pathname === "/sheets-test") {
        return await handleSheetsTest(request, env);
      }

      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405 });
      }

      if (url.pathname === "/chat")             return await handleChat(request, env);
      if (url.pathname === "/tts")              return await handleTTS(request, env);
      if (url.pathname === "/transcribe-token") return await handleTranscribeToken(env);
      if (url.pathname === "/sheets-append")    return await handleSheetsAppend(request, env);

    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

// ── Claude ────────────────────────────────────────────────────────────────────

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

// ── AssemblyAI ────────────────────────────────────────────────────────────────

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    { method: "GET", headers: { authorization: env.ASSEMBLYAI_API_KEY } }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI error ${response.status}: ${errorBody}`);
    return new Response(errorBody, { status: response.status, headers: { "content-type": "application/json" } });
  }

  return new Response(await response.text(), { status: 200, headers: { "content-type": "application/json" } });
}

// ── ElevenLabs ────────────────────────────────────────────────────────────────

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs error ${response.status}: ${errorBody}`);
    return new Response(errorBody, { status: response.status, headers: { "content-type": "application/json" } });
  }

  return new Response(response.body, {
    status: response.status,
    headers: { "content-type": response.headers.get("content-type") || "audio/mpeg" },
  });
}

// ── Google Sheets ─────────────────────────────────────────────────────────────

// Converts a PEM private key string to a DER ArrayBuffer for Web Crypto.
// Handles both literal \n (from JSON file copy-paste) and actual newlines.
function pemToDer(pem: string): ArrayBuffer {
  // Normalise: convert literal \n escape sequences to real newlines.
  const normalised = pem.replace(/\\n/g, "\n");

  // Extract the base64 payload between any PEM header/footer using regex
  // so we're not sensitive to exact header wording or surrounding whitespace.
  const match = normalised.match(/-----BEGIN [^-]+-----\s*([\s\S]+?)\s*-----END [^-]+-----/);
  if (!match) {
    throw new Error(
      "GOOGLE_PRIVATE_KEY is not valid PEM. Re-add the Worker secret — " +
      "copy only the private_key value from the service account JSON (no surrounding quotes)."
    );
  }

  // Strip any remaining whitespace from the base64 payload.
  const base64 = match[1].replace(/\s/g, "");

  try {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  } catch {
    throw new Error(
      `GOOGLE_PRIVATE_KEY base64 is invalid (${base64.length} chars after stripping whitespace). ` +
      "The secret may have been pasted with extra characters. Delete and re-add it."
    );
  }
}

// Base64url-encodes a string or ArrayBuffer (no padding, URL-safe chars).
function base64url(input: string | ArrayBuffer): string {
  const str =
    typeof input === "string"
      ? input
      : String.fromCharCode(...new Uint8Array(input));
  return btoa(str).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

// Obtains a short-lived Google OAuth2 access token using the service account.
// Uses the Web Crypto API (RS256 JWT) — no external libraries needed.
async function getGoogleAccessToken(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);

  const claimSet = {
    iss:   env.GOOGLE_CLIENT_EMAIL,
    scope: "https://www.googleapis.com/auth/spreadsheets",
    aud:   "https://oauth2.googleapis.com/token",
    iat:   now,
    exp:   now + 3600,
  };

  const header    = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims    = base64url(JSON.stringify(claimSet));
  const signingInput = `${header}.${claims}`;

  // Import the PEM private key (stored with literal \n in the Worker secret).
  const privateKeyPem = env.GOOGLE_PRIVATE_KEY.replace(/\\n/g, "\n");
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(privateKeyPem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signingInput)
  );

  const jwt = `${signingInput}.${base64url(signature)}`;

  // Exchange the signed JWT for a Google OAuth access token.
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}`,
  });

  if (!tokenResponse.ok) {
    const err = await tokenResponse.text();
    throw new Error(`Google token error ${tokenResponse.status}: ${err}`);
  }

  const tokenData = await tokenResponse.json() as { access_token: string };
  return tokenData.access_token;
}

// POST /sheets-append
// Body: { spreadsheetId, tab, row: string[], ensureHeaders?: string[] }
// Appends one row to the sheet. If ensureHeaders is provided and row 1 is
// empty, writes the headers first.
async function handleSheetsAppend(request: Request, env: Env): Promise<Response> {
  const { spreadsheetId, tab, row, ensureHeaders } = await request.json() as {
    spreadsheetId: string;
    tab: string;
    row: string[];
    ensureHeaders?: string[];
  };

  const accessToken = await getGoogleAccessToken(env);
  const sheetsBase  = `https://sheets.googleapis.com/v4/spreadsheets/${spreadsheetId}`;
  const authHeader  = { "Authorization": `Bearer ${accessToken}`, "content-type": "application/json" };

  // Write headers to row 1 if the sheet tab is empty and headers were supplied.
  if (ensureHeaders?.length) {
    const checkResponse = await fetch(
      `${sheetsBase}/values/${encodeURIComponent(tab)}!A1:A1`,
      { headers: { "Authorization": `Bearer ${accessToken}` } }
    );
    const checkData = await checkResponse.json() as { values?: string[][] };

    if (!checkData.values?.length) {
      await fetch(
        `${sheetsBase}/values/${encodeURIComponent(tab)}!A1:${columnLetter(ensureHeaders.length)}1?valueInputOption=USER_ENTERED`,
        { method: "PUT", headers: authHeader, body: JSON.stringify({ values: [ensureHeaders] }) }
      );
    }
  }

  // Append the data row.
  const appendResponse = await fetch(
    `${sheetsBase}/values/${encodeURIComponent(tab)}!A:${columnLetter(row.length)}:append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS`,
    { method: "POST", headers: authHeader, body: JSON.stringify({ values: [row] }) }
  );

  if (!appendResponse.ok) {
    const err = await appendResponse.text();
    console.error(`[/sheets-append] Sheets API error ${appendResponse.status}: ${err}`);
    return new Response(JSON.stringify({ error: err }), {
      status: appendResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  const result = await appendResponse.json();
  return new Response(JSON.stringify({ success: true, result }), {
    headers: { "content-type": "application/json" },
  });
}

// GET /sheets-test — verifies credentials and returns the spreadsheet title.
// Requires ?sheetId=<spreadsheetId> query param.
async function handleSheetsTest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const spreadsheetId = url.searchParams.get("sheetId");

  if (!spreadsheetId) {
    return new Response(JSON.stringify({ error: "Missing ?sheetId query param" }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }

  const accessToken = await getGoogleAccessToken(env);
  const response = await fetch(
    `https://sheets.googleapis.com/v4/spreadsheets/${spreadsheetId}?fields=properties.title`,
    { headers: { "Authorization": `Bearer ${accessToken}` } }
  );

  if (!response.ok) {
    const err = await response.text();
    return new Response(JSON.stringify({ configured: true, connected: false, error: err }), {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.json() as { properties: { title: string } };
  return new Response(
    JSON.stringify({ configured: true, connected: true, sheetTitle: data.properties.title }),
    { headers: { "content-type": "application/json" } }
  );
}

// Returns the A1-notation column letter for a 1-based column index (1→A, 26→Z, 27→AA).
function columnLetter(n: number): string {
  let result = "";
  while (n > 0) {
    result = String.fromCharCode(((n - 1) % 26) + 65) + result;
    n = Math.floor((n - 1) / 26);
  }
  return result;
}
