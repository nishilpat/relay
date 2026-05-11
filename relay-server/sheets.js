// Google Sheets integration via the Cloudflare Worker proxy.
// Credentials (GOOGLE_CLIENT_EMAIL, GOOGLE_PRIVATE_KEY) live as Worker secrets —
// the relay-server only needs the sheet ID and the proxy URL.

const SHEETS_PROXY_URL = process.env.SHEETS_PROXY_URL
  || process.env.CLAUDE_PROXY_URL?.replace('/chat', '')   // reuse same worker base if set
  || 'https://your-worker-name.your-subdomain.workers.dev';

const GOOGLE_SHEET_ID  = process.env.GOOGLE_SHEET_ID;
const GOOGLE_SHEET_TAB = process.env.GOOGLE_SHEET_TAB || 'Relay Intakes';

const SHEET_HEADERS = [
  'Submitted At',
  'Name',
  'Company',
  'Email',
  'Question',
  'Is Blocking',
  'Timeline',
  'Category',
  'Urgency',
  'Sentiment',
  'Revenue Impact',
  'Recommended Owner',
  'Executive Summary',
  'Intake ID',
];

export function isSheetsConfigured() {
  return !!GOOGLE_SHEET_ID;
}

// Appends one intake row to the Google Sheet via the Worker proxy.
// Called fire-and-forget from server.js — does not block the API response.
export async function appendIntakeToSheet(intakeRecord, analysisOutputs) {
  if (!isSheetsConfigured()) {
    return { skipped: true, reason: 'GOOGLE_SHEET_ID not set' };
  }

  const row = [
    new Date(intakeRecord.createdAt).toLocaleString('en-US'),
    intakeRecord.name,
    intakeRecord.company,
    intakeRecord.email,
    intakeRecord.question,
    intakeRecord.isBlocking  || '',
    intakeRecord.timeline    || '',
    intakeRecord.category,
    intakeRecord.urgency,
    analysisOutputs?.classification?.sentiment        || '',
    analysisOutputs?.classification?.revenueImpact    || '',
    analysisOutputs?.classification?.recommendedOwner || '',
    analysisOutputs?.executiveSummary                 || '',
    intakeRecord.id,
  ];

  const response = await fetch(`${SHEETS_PROXY_URL}/sheets-append`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({
      spreadsheetId: GOOGLE_SHEET_ID,
      tab:           GOOGLE_SHEET_TAB,
      row,
      ensureHeaders: SHEET_HEADERS, // Worker writes headers if the tab is empty
    }),
  });

  if (!response.ok) {
    const err = await response.text();
    throw new Error(`Sheets proxy error ${response.status}: ${err}`);
  }

  console.log(`[Sheets] Appended intake ${intakeRecord.id} — ${intakeRecord.company}`);
  return await response.json();
}

// Verifies the Worker can reach the sheet — used by GET /api/sheets-test.
export async function testSheetsConnection() {
  if (!isSheetsConfigured()) {
    return { configured: false, reason: 'GOOGLE_SHEET_ID not set in .env' };
  }

  const response = await fetch(
    `${SHEETS_PROXY_URL}/sheets-test?sheetId=${GOOGLE_SHEET_ID}`,
    { method: 'GET' }
  );

  return await response.json();
}
