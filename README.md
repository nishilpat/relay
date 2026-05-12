# Relay

**Turn customer conversations into sales follow-through.**

Relay gives Account Executives a customer handoff link and a Mac command center that turn questions, call notes, and deal blockers into follow-up emails, CRM-ready internal notes, Slack updates, Google Sheets rows, and next-step tasks.

Built on top of an open-source macOS menu bar companion foundation and adapted for the Relay sales workflow.

---
## Get started with Claude Code

The best way to get this running is with Claude Code, as this repo is filled with placeholders (instead of specific keys, workspaces, sheets, etc.)

Once you get Claude running, paste this:

```text
Hi Claude.

Clone https://github.com/nishilpat/relay.git into my current directory.

Then read the README.md and CLAUDE.md. I want to get Relay running locally on my Mac and understand what's needed.

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

Claude Code helped me build Relay from the same instructions! It helped walk through the whole setup and I kept talking to it to explore features, fix bugs, and test!
---

## What Relay does

Relay has two surfaces:

**1. Customer Relay Link** (`/intake`)
A lightweight web page the AE shares with customers after a call. Customers submit questions, blockers, feature requests, or follow-ups. Claude classifies, summarizes, and generates a complete follow-through package automatically on submission. When configured, Relay also appends each intake to a shared Google Sheet automatically.

**2. AE Mac Menu App**
The macOS menu bar app shows incoming customer asks, accepts pasted post-call notes, and displays all generated outputs — email draft, CRM-ready internal note, Slack update, product request, task list — each with a copy button.
The current voice setup uses Apple Speech for transcription and ElevenLabs for spoken output.
The public repo still contains some original companion onboarding code, but the checked-in app leaves `OnboardingVideoURL` blank, so the onboarding video and its screen-pointing demo are inactive by default.

---

## Why two surfaces

Customers should NOT install the Mac app. The Mac app is for AEs only.

The Relay Link is a URL the AE can paste into any email. Customers fill it out in their browser. The Mac app polls the same backend so new submissions appear immediately.

---

## Why the Google Sheet matters

Relay does not just generate AI output cards. It also has an elegant lightweight ops layer:

- every customer intake can be appended to a shared Google Sheet automatically
- the Sheet becomes a simple running log of asks, blockers, urgency, sentiment, revenue impact, owner, and summary
- this gives the team a live spreadsheet view without needing a heavier CRM integration for the demo

The sync happens through a Cloudflare Worker that holds the Google service account credentials, so the app and backend never ship those secrets directly.

---

## How to run locally

### 1. Start the web server

```bash
cd relay-server
npm install
# Create relay-server/.env manually — there is no checked-in .env.example
# Add CLAUDE_PROXY_URL or ANTHROPIC_API_KEY
node server.js
```

The server starts at `http://localhost:3000`.

- Landing page: `http://localhost:3000/`
- Customer intake: `http://localhost:3000/intake`
- API: `http://localhost:3000/api/`

### 2. Open the Mac app

```bash
open leanring-buddy.xcodeproj
# Select leanring-buddy scheme → Cmd+R
```

The Mac app uses the `relayServerBaseURL` constant in `leanring-buddy/CompanionManager.swift`.
Set that value to `http://localhost:3000`, your ngrok URL, or your own deployed backend before running the app.

---

## Required environment variables

Create `relay-server/.env` manually:

| Variable | Required | Purpose |
|----------|----------|---------|
| `CLAUDE_PROXY_URL` | If no API key | Cloudflare Worker proxy URL for Claude |
| `ANTHROPIC_API_KEY` | If no proxy | Direct Anthropic API key |
| `PORT` | No (default: 3000) | Server port |
| `SLACK_WEBHOOK_URL` | No | If set, Slack integration becomes live |
| `GOOGLE_SHEET_ID` | No | If set, customer intakes can be appended to Google Sheets |
| `GOOGLE_SHEET_TAB` | No (default: `Relay Intakes`) | Tab name used for the synced intake log |
| `SHEETS_PROXY_URL` | No | Optional override for the Worker base URL used for Sheets routes |
| `DB_PATH` | No (default: `./relay.db`) | SQLite database path |

At least one of `CLAUDE_PROXY_URL` or `ANTHROPIC_API_KEY` must be set. For a public-safe setup, use your own Worker URL such as `https://your-worker-name.your-subdomain.workers.dev/chat`.

---

## What is functional

- ✅ Customer intake form (`/intake`) — all fields, category, urgency radio buttons
- ✅ Claude analysis on submission — classification, FAQ matching, all 7 output types
- ✅ Confirmation page with copy-button output cards (email, CRM-ready internal note, Slack, product request, tasks, JSON)
- ✅ FAQ answer shown if Claude confidence is high
- ✅ SQLite storage — intakes persist across server restarts
- ✅ `GET /api/intakes` — Mac app polls this to show recent customer asks
- ✅ `POST /api/analyze` — Mac app submits post-call notes for analysis
- ✅ Mac app panel — three tabs: Customer Asks, Post-Call Notes, Outputs
- ✅ Mac app copy buttons — copies any output to clipboard
- ✅ Intake form also available at `/relay-link`
- ✅ Apple Mail handoff via `mailto:`
- ✅ Optional Slack webhook posting when configured
- ✅ Optional Google Sheets sync when configured
- ✅ Push-to-talk voice path in the Mac app — Apple Speech transcription, Claude response, ElevenLabs spoken output, cursor overlay

---

## What is mocked / not wired

- **Slack**: Copy button always works. Live posting only happens if `SLACK_WEBHOOK_URL` is set.
- **Google Sheets**: Google Sheets sync is implemented and production-shaped, but only becomes live when the Worker and sheet env vars are configured.
- **Salesforce**: Salesforce helper code and routes exist, but the current demo does not use a live Salesforce account. The workflow uses the generated `salesforceNote` as a CRM-ready note you can copy.
- **Email sending**: The live email path is Apple Mail via `mailto:`. Gmail draft code exists, but Gmail MCP is not configured in the current setup.
- **Onboarding video / cursor demo**: The original companion foundation still contains onboarding video + demo interaction code, but the checked-in public repo leaves `OnboardingVideoURL` blank, so that path does not run in the current workflow.
- **AssemblyAI**: AssemblyAI support remains in the codebase and Worker, but the current app workflow uses Apple Speech instead.
- **File upload**: Intake form has a placeholder — file upload not implemented in MVP.

---

## How Claude is used

Claude is called for multiple flows via `relay-server/claude.js`:

### Claude tech stack at a glance

- **Backend sales workflow**: Relay server uses the Anthropic Messages API for customer intake analysis, post-call notes analysis, and AE Slack draft generation.
- **Mac app voice workflow**: The menu bar app sends screen captures plus the user's spoken transcript to Claude, so the current voice assistant path is multimodal and uses Claude vision.
- **Current model default**: The checked-in default is `claude-sonnet-4-6`.
- **Optional Gmail path**: Gmail draft creation uses Claude with `mcp_servers`, but only if Gmail MCP is configured.
- **Present in code but not part of the current workflow**: `ElementLocationDetector.swift` contains a separate Claude Computer Use helper, but it is not wired into the current live app path. The original onboarding cursor demo prompt also remains in code, but the checked-in public repo leaves `OnboardingVideoURL` blank, so that demo path is inactive by default.

**Customer intake** — classifies category, urgency, sentiment, revenue impact; matches FAQ; generates email + CRM-ready internal note + Slack + product request + tasks.

**Post-call notes** — extracts deal blockers, technical requirements, stakeholders; estimates urgency and revenue impact; generates the same 7-output package.

**AE Slack draft** — generates a short AE-style Slack message for manual review and sending.

**Optional Gmail draft creation** — Gmail MCP code exists, but it is not configured in the current demo setup.

Claude rules in every prompt: never invent facts, mark unknowns explicitly, customer-facing content must be cautious, internal updates must be operational, tasks must reference specific topics from the actual input.

---

## Why integrations are optional for MVP

The value of Relay is the AI-generated content — the email draft, the CRM note, the Slack message. AEs can copy and paste these into their existing tools even when the live integrations are not configured.

Live integrations require OAuth, token management, and per-user configuration — unnecessary for a demo. The copy button delivers the same workflow outcome without the complexity.

In the current demo setup:

- Slack can post live when `SLACK_WEBHOOK_URL` is configured
- Google Sheets can append live when the Worker and `GOOGLE_SHEET_ID` are configured
- Email opens in Apple Mail via `mailto:`
- Salesforce and Gmail draft codepaths exist, but they are not configured

---

## Google Sheets sync

Relay's Google Sheets setup is intentionally simple and useful:

- `relay-server/sheets.js` formats each intake into a single row
- the Cloudflare Worker exposes `/sheets-append` and `/sheets-test`
- the Worker signs a Google service account JWT and talks to the Sheets API
- if the target tab is empty, the Worker can write headers automatically on first append

The current row includes:

- submitted time
- customer name, company, and email
- question, blocker status, and timeline
- category and urgency
- sentiment, revenue impact, and recommended owner
- executive summary
- intake ID

This gives Relay a durable shared spreadsheet log without shipping Google credentials in the app or backend.

---

## Project structure

```
relay/
├── relay-server/          # Web server + frontend
│   ├── server.js          # Express routes
│   ├── storage.js         # SQLite layer
│   ├── claude.js          # Claude API + prompt building
│   ├── faq.json           # Local FAQ knowledge base (10 entries)
│   └── public/
│       ├── index.html     # Landing page
│       └── intake.html    # Customer intake form + results
├── leanring-buddy/        # macOS menu bar app (Swift)
│   ├── CompanionManager.swift    # State + Relay API methods
│   ├── CompanionPanelView.swift  # Relay UI panel (3 tabs)
│   └── ...                       # Voice features retained from the original companion foundation
├── worker/                # Cloudflare Worker API proxy
│   └── src/index.ts
└── AGENTS.md              # Full architecture + agent documentation
```
