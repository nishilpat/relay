import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import path from 'path';
import { fileURLToPath } from 'url';
import {
  initStorage,
  saveCustomerIntake,
  getRecentCustomerIntakes,
  saveGeneratedOutputs,
} from './storage.js';
import { analyzeCustomerIntake, analyzePostCallNotes, createGmailDraft, generateAESlackDraft } from './claude.js';
import {
  createSalesforceTaskFromIntake,
  createSalesforceTaskFromNotes,
  testSalesforceConnection,
} from './salesforce.js';
import { appendIntakeToSheet, testSheetsConnection } from './sheets.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json({ limit: '10mb' }));
app.use(express.static(path.join(__dirname, 'public')));

initStorage();

// POST /api/intake — Receive a customer intake, run Claude analysis, save to DB.
app.post('/api/intake', async (req, res) => {
  try {
    const { name, company, email, question, isBlocking, timeline, category, urgency } = req.body;

    if (!name || !company || !email || !question) {
      return res.status(400).json({ error: 'Required fields: name, company, email, question' });
    }

    const intakeRecord = {
      id: crypto.randomUUID(),
      name: name.trim(),
      company: company.trim(),
      email: email.trim(),
      question: question.trim(),
      isBlocking: isBlocking?.trim() || null,
      timeline: timeline?.trim() || null,
      category: category || 'General question',
      urgency: urgency || 'Medium',
      createdAt: new Date().toISOString(),
    };

    console.log(`[POST /api/intake] Processing intake from ${intakeRecord.name} at ${intakeRecord.company}`);

    const analysisOutputs = await analyzeCustomerIntake(intakeRecord);
    intakeRecord.summary = analysisOutputs.executiveSummary;
    intakeRecord.analysis = analysisOutputs;

    saveCustomerIntake(intakeRecord);

    console.log(`[POST /api/intake] Saved intake ${intakeRecord.id}`);

    // Fire Slack + Salesforce in parallel — both are non-blocking (fire-and-forget).
    if (process.env.SLACK_WEBHOOK_URL && analysisOutputs.slackUpdate) {
      fetch(process.env.SLACK_WEBHOOK_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: analysisOutputs.slackUpdate }),
      }).catch(err => console.error('[Slack] Failed to send:', err));
    }

    createSalesforceTaskFromIntake(intakeRecord, analysisOutputs)
      .catch(err => console.error('[Salesforce] Task creation failed:', err));

    appendIntakeToSheet(intakeRecord, analysisOutputs)
      .catch(err => console.error('[Sheets] Append failed:', err));

    res.json({ success: true, intakeId: intakeRecord.id, outputs: analysisOutputs });
  } catch (error) {
    console.error('[POST /api/intake] Error:', error);
    res.status(500).json({ error: 'Failed to process intake. Please try again.' });
  }
});

// GET /api/intakes — Return recent customer intakes for the Mac app.
app.get('/api/intakes', (req, res) => {
  try {
    const limit = Math.min(parseInt(req.query.limit) || 20, 100);
    const intakes = getRecentCustomerIntakes(limit);
    res.json({ intakes });
  } catch (error) {
    console.error('[GET /api/intakes] Error:', error);
    res.status(500).json({ error: 'Failed to fetch intakes' });
  }
});

// POST /api/analyze — Analyze post-call notes or re-analyze a customer intake on demand.
app.post('/api/analyze', async (req, res) => {
  try {
    const { type, data } = req.body;

    if (!type || !data) {
      return res.status(400).json({ error: 'Required fields: type ("intake" | "notes"), data' });
    }

    console.log(`[POST /api/analyze] Analyzing type="${type}"`);

    let outputs;
    if (type === 'intake') {
      outputs = await analyzeCustomerIntake(data);
    } else if (type === 'notes') {
      outputs = await analyzePostCallNotes(data);
    } else {
      return res.status(400).json({ error: 'type must be "intake" or "notes"' });
    }

    res.json({ outputs });
  } catch (error) {
    console.error('[POST /api/analyze] Error:', error);
    res.status(500).json({ error: 'Analysis failed. Please try again.' });
  }
});

// POST /api/save — Persist generated outputs for a record.
app.post('/api/save', (req, res) => {
  try {
    const { sourceType, intakeId, outputs } = req.body;

    if (!sourceType || !outputs) {
      return res.status(400).json({ error: 'Required fields: sourceType, outputs' });
    }

    const savedId = saveGeneratedOutputs(sourceType, intakeId || null, outputs);
    res.json({ success: true, id: savedId });
  } catch (error) {
    console.error('[POST /api/save] Error:', error);
    res.status(500).json({ error: 'Failed to save outputs' });
  }
});

// POST /api/slack — Send a Slack webhook message (only if SLACK_WEBHOOK_URL is configured).
app.post('/api/slack', async (req, res) => {
  const slackWebhookURL = process.env.SLACK_WEBHOOK_URL;

  if (!slackWebhookURL) {
    return res.json({ sent: false, reason: 'SLACK_WEBHOOK_URL not configured — use "Copy" to send manually.' });
  }

  try {
    const { text } = req.body;
    const slackResponse = await fetch(slackWebhookURL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text }),
    });

    const slackBody = await slackResponse.text();

    if (!slackResponse.ok || slackBody !== 'ok') {
      console.error(`[Slack] Webhook rejected — HTTP ${slackResponse.status}: ${slackBody}`);
      return res.status(502).json({
        sent: false,
        error: `Slack returned ${slackResponse.status}: ${slackBody}`,
      });
    }

    console.log('[Slack] Message posted successfully');
    res.json({ sent: true });
  } catch (error) {
    console.error('[POST /api/slack] Error:', error);
    res.status(500).json({ error: 'Failed to send Slack message' });
  }
});

// POST /api/salesforce — Create a Salesforce Task from post-call notes analysis.
// Customer intakes are synced automatically on submission; this route handles
// the Mac app's post-call notes flow where the AE triggers sync manually.
app.post('/api/salesforce', async (req, res) => {
  try {
    const { notesData, outputs } = req.body;

    if (!outputs) {
      return res.status(400).json({ error: 'Required field: outputs' });
    }

    const result = await createSalesforceTaskFromNotes(notesData || {}, outputs);
    res.json(result);
  } catch (error) {
    console.error('[POST /api/salesforce] Error:', error);
    res.status(500).json({ error: error.message || 'Salesforce sync failed' });
  }
});

// GET /api/sheets-test — Verify Google Sheets service account credentials.
app.get('/api/sheets-test', async (req, res) => {
  try {
    const result = await testSheetsConnection();
    res.json(result);
  } catch (error) {
    console.error('[GET /api/sheets-test] Error:', error);
    res.status(500).json({ configured: true, connected: false, error: error.message });
  }
});

// GET /api/salesforce-test — Verify Salesforce credentials are working.
app.get('/api/salesforce-test', async (req, res) => {
  try {
    const result = await testSalesforceConnection();
    res.json(result);
  } catch (error) {
    console.error('[GET /api/salesforce-test] Error:', error);
    res.status(500).json({ configured: true, connected: false, error: error.message });
  }
});

// POST /api/slack-draft — Uses Claude to generate a short, conversational AE-voice
// Slack message from the analysis outputs. The AE edits it in the Mac app before sending.
// This is separate from the auto-notification that fires on intake submission.
app.post('/api/slack-draft', async (req, res) => {
  try {
    const { outputs } = req.body;
    if (!outputs) return res.status(400).json({ error: 'Required field: outputs' });

    console.log('[POST /api/slack-draft] Generating AE-voice draft');
    const draftText = await generateAESlackDraft(outputs);
    res.json({ draftText });
  } catch (error) {
    console.error('[POST /api/slack-draft] Error:', error);
    res.status(500).json({ error: error.message });
  }
});

// GET /api/config — Returns which integrations are enabled so the Mac app
// knows which buttons to show without hardcoding env var checks in Swift.
app.get('/api/config', (req, res) => {
  res.json({
    gmailEnabled: !!process.env.GMAIL_MCP_URL,
    slackEnabled: !!process.env.SLACK_WEBHOOK_URL,
    salesforceEnabled: !!(
      process.env.SALESFORCE_USERNAME &&
      process.env.SALESFORCE_PASSWORD &&
      process.env.SALESFORCE_SECURITY_TOKEN
    ),
  });
});

// POST /api/gmail-draft — Creates a Gmail draft via Claude + Gmail MCP.
// Returns 503 if GMAIL_MCP_URL is not configured (graceful degradation).
// The AE reviews and sends the draft manually — Relay never sends email automatically.
app.post('/api/gmail-draft', async (req, res) => {
  if (!process.env.GMAIL_MCP_URL) {
    return res.status(503).json({
      success: false,
      error: 'Gmail integration not configured — set GMAIL_MCP_URL in .env',
    });
  }

  try {
    const { to, subject, body: emailBody, intakeId } = req.body;

    if (!subject || !emailBody) {
      return res.status(400).json({ success: false, error: 'Required fields: subject, body' });
    }

    console.log(`[POST /api/gmail-draft] Creating draft for "${subject}"${intakeId ? ` (intake ${intakeId})` : ''}`);

    const result = await createGmailDraft(to || '', subject, emailBody);
    res.json(result);
  } catch (error) {
    console.error('[POST /api/gmail-draft] Error:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Serve intake page at both /intake and /relay-link.
app.get('/intake', (req, res) => res.sendFile(path.join(__dirname, 'public', 'intake.html')));
app.get('/relay-link', (req, res) => res.sendFile(path.join(__dirname, 'public', 'intake.html')));

app.listen(PORT, () => {
  console.log(`\nRelay server running at http://localhost:${PORT}`);
  console.log(`  Landing page : http://localhost:${PORT}/`);
  console.log(`  Intake form  : http://localhost:${PORT}/intake`);
  console.log(`  API          : http://localhost:${PORT}/api/\n`);
});
