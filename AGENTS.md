# Relay - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

Relay is a sales workflow agent for Account Executives. It has two surfaces:

1. **Customer Relay Link** — a lightweight web intake page the AE shares with customers after a call. Customers submit questions, blockers, feature requests, and follow-ups. Claude classifies, summarizes, and generates follow-through outputs automatically. In the current setup, Slack and Google Sheets can be notified automatically on submission when configured. Salesforce code exists in the repo but is not part of the current demo setup.

2. **AE Mac Menu App** — the Relay menu bar app serves as the AE's command center. Shows incoming customer asks (auto-refreshed every 30s), accepts post-call notes, and displays all Claude-generated outputs — each with a Copy button. Email card is editable before opening in Mail; Gmail draft saving exists as an optional codepath but is not configured in the current demo. Slack card has a Claude-drafted message the AE can edit before sending.

The core pitch: **"Relay turns customer conversations into sales follow-through."**

All API keys live on a Cloudflare Worker proxy or server-side `.env` — nothing sensitive ships in the Mac app binary.

---

## Architecture

### Two Surfaces

- **Web server** (`relay-server/`) — Node.js/Express server that serves the landing page and intake form, receives customer submissions, calls Claude for analysis, stores intakes in SQLite, auto-fires Slack and Google Sheets when configured, and still contains dormant Salesforce routes/helpers. Also serves as the API backend for the Mac app.
- **Mac menu bar app** (`leanring-buddy/`) — SwiftUI macOS app (menu bar only, no dock icon). Panel shows Relay UI: recent customer asks, post-call notes form, and generated outputs. The original companion voice pipeline (push-to-talk, transcription, TTS, overlay) is fully retained.

### Mac App Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel
- **Pattern**: MVVM with `@ObservedObject` / `@Published` state management
- **Relay API**: Mac app calls the Relay server via `CompanionManager.relayServerBaseURL`. In this public-safe repo the checked-in default is a placeholder URL, and requests include the `ngrok-skip-browser-warning` header so you can point it at localhost, ngrok, or your own deployed backend.
- **Voice pipeline**: Retained from the original companion app — push-to-talk (`Ctrl+Option`), Apple Speech transcription by default, Claude streaming response, ElevenLabs for spoken output/TTS, cursor overlay. AssemblyAI support still exists in the repo and Worker, but the current app config uses Apple Speech (`VoiceTranscriptionProvider = apple`). `companionManager.start()` initializes the full pipeline on app launch.
- **Onboarding demo path**: The original companion onboarding video + screen-pointing demo code is still present, but the checked-in public repo leaves `OnboardingVideoURL` blank in `Info.plist`, so that onboarding demo path is inactive by default unless a video URL is configured locally.
- **Voice state indicator**: Panel header shows Relay logo (three circles) which dims during active voice use; header text swaps to "Listening…" / "Processing…" / "Responding…"
- **Logo**: `RelayLogoView` SwiftUI Canvas component renders the three-circle Relay logo (orange/blue/green) from a 24×24 SVG viewBox. Used in the menu bar icon, panel header, and cursor overlay.
- **Panel**: Resizable — default 560pt wide, min 420pt, max 1000pt. Dimensions preserved between open/close cycles. `hasPanelBeenShownBefore` tracks first vs subsequent shows.
- **Auto-refresh**: Panel polls `GET /api/intakes` every 30 seconds via a `while !Task.isCancelled` loop in `.task {}`. Manual refresh button turns blue while loading.
- **Dismiss intakes**: `dismissRelayIntake(withID:)` removes a card from the in-app list (data remains in SQLite and Google Sheets on the backend).
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: Disabled in this public-cleanup repo. `RelayAnalytics.swift` is a no-op compatibility shim so the app keeps compiling without PostHog.

### Web Server Architecture

- **Runtime**: Node.js 22.5+ (uses native `fetch`, `crypto.randomUUID`, and built-in `node:sqlite`)
- **Framework**: Express.js
- **Storage**: SQLite via built-in `node:sqlite` (synchronous, no native compilation)
- **Claude**: Called via Cloudflare Worker proxy (default) or directly if `ANTHROPIC_API_KEY` is set. Gmail MCP calls always go direct to Anthropic.
- **Serves**: Landing page (`/`), intake form (`/intake`, `/relay-link`), and REST API (`/api/*`)

### API Proxy (Cloudflare Worker)

The Mac app voice features and parts of the web server route external API calls through a Cloudflare Worker that holds secrets. The Worker actively handles Claude, ElevenLabs, and Google Sheets. It also still includes an AssemblyAI token route for the dormant transcription path.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude chat (streaming or non-streaming) |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS (voice features) |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | AssemblyAI temp token for the legacy/dormant transcription path |
| `POST /sheets-append` | `sheets.googleapis.com/v4/spreadsheets/…` | Append one row to Google Sheet |
| `GET /sheets-test` | `sheets.googleapis.com/v4/spreadsheets/…` | Verify service account + sheet access |

**Worker secrets**: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`, `GOOGLE_CLIENT_EMAIL`, `GOOGLE_PRIVATE_KEY`

**Google Sheets JWT auth in the Worker**: The Worker signs a Google service account JWT using the Web Crypto API (RS256 / RSASSA-PKCS1-v1_5), exchanges it for an OAuth access token, then calls the Sheets REST API. No `googleapis` npm package — pure Web Crypto + fetch. `GOOGLE_PRIVATE_KEY` must be the PEM value with literal `\n` sequences (the Worker normalises them).

### Web Server API Routes

| Method | Route | Purpose |
|--------|-------|---------|
| `POST` | `/api/intake` | Receive customer intake, run Claude analysis, save to SQLite, auto-fire Slack + Google Sheets when configured, and still attempt Salesforce sync if Salesforce env vars are set |
| `GET` | `/api/intakes` | Return recent customer intakes for the Mac app (polled every 30s) |
| `POST` | `/api/analyze` | Analyze post-call notes or customer intake on demand |
| `POST` | `/api/save` | Save generated outputs |
| `POST` | `/api/slack` | Send Slack webhook (only if `SLACK_WEBHOOK_URL` is configured) |
| `POST` | `/api/slack-draft` | Generate a concise AE-voice Slack message via Claude from analysis outputs |
| `POST` | `/api/salesforce` | Create Salesforce Task from post-call notes. Backend route exists, but it is not currently surfaced by the Mac app UI |
| `GET` | `/api/salesforce-test` | Verify Salesforce credentials and return org identity |
| `GET` | `/api/config` | Return `{ gmailEnabled, slackEnabled, salesforceEnabled }` — Mac app reads this to show/hide buttons |
| `POST` | `/api/gmail-draft` | Create a Gmail draft via Claude + Gmail MCP. Returns `{ success, draftId }` or 503 if unconfigured |
| `GET` | `/api/sheets-test` | Verify Google Sheets Worker connection |

### Claude Usage (relay-server)

Claude is used for four purposes in `claude.js`. All prompts instruct Claude to be concise — no filler, no padding:

- **Customer intake** (`analyzeCustomerIntake`): Classifies category/urgency/sentiment, matches FAQ, generates concise customer email (3-4 sentences) + CRM-ready internal note (`salesforceNote` field) + Slack update + product request + next-step tasks.
- **Post-call notes** (`analyzePostCallNotes`): Extracts deal blockers, stakeholders, revenue impact, generates same output set.
- **AE Slack draft** (`generateAESlackDraft`): Generates a 1-2 sentence personal Slack message in the AE's voice — not the structured auto-notification. AE edits it in the Mac app before sending.
- **Gmail draft** (`createGmailDraft`): Calls Anthropic directly with `mcp_servers` and `anthropic-beta: mcp-client-2025-04-04`. Claude uses the Gmail MCP tool to create a draft (never sends).

Analysis functions use `extractJSONFromClaudeResponse`. Gmail uses `extractFinalTextFromResponse` to find the last text block after MCP tool use.

### Integration Degradation Pattern

All integrations degrade gracefully. The Mac app fetches `GET /api/config` at every panel refresh (every 30s) to know which buttons to show.

| Integration | Trigger | Configured | Unconfigured |
|-------------|---------|-----------|-------------|
| **Slack (auto)** | Auto on `POST /api/intake` | Posts structured `slackUpdate` to webhook | Skipped silently |
| **Slack (AE draft)** | Manual — AE clicks "Draft AE message" | Claude drafts → AE edits → sends | Button always visible; server returns error if webhook not set |
| **Salesforce** | Backend code path only | Creates Task via jsforce SOAP if env vars are configured | Not part of the current demo flow. The Mac app currently shows the generated `salesforceNote` as copyable text only |
| **Gmail Drafts** | Optional manual button in Mac app | Creates draft via Claude + MCP if `GMAIL_MCP_URL` is configured | Hidden; AE uses "Open in Mail" (`mailto:`) in the current demo setup |
| **Google Sheets** | Auto on `POST /api/intake` | Appends row via Cloudflare Worker | Skipped silently |

### Salesforce Integration (`salesforce.js`)

Uses `jsforce` for SOAP login — no Connected App or OAuth required.

- Authenticates via `conn.login(username, password + securityToken)` — connection cached, re-authenticated on `INVALID_SESSION_ID`
- On intake: SOQL lookup for Account by company name; links Task via `WhatId` if found, unlinked otherwise
- Task fields: Subject, Description (`salesforceNote` from Claude), Status, Priority (mapped from urgency), ActivityDate (today + 3 days)

### Google Sheets Integration (`sheets.js`)

- Server calls `POST /sheets-append` on the Cloudflare Worker (not googleapis directly — credentials live as Worker secrets)
- Worker signs a service account JWT (RS256 via Web Crypto), gets an OAuth token, appends a row to the sheet
- If the tab is empty, headers are written automatically on first append
- 14 columns: Submitted At, Name, Company, Email, Question, Is Blocking, Timeline, Category, Urgency, Sentiment, Revenue Impact, Recommended Owner, Executive Summary, Intake ID
- Server only needs `GOOGLE_SHEET_ID` in `.env` — credentials never leave the Worker

### Gmail MCP Integration

- Requires `ANTHROPIC_API_KEY`, `GMAIL_MCP_URL`, and optionally `GMAIL_MCP_AUTH_TOKEN`
- Server calls Anthropic directly with `mcp_servers: [{ type: "url", url, name: "gmail", authorization_token }]`
- Claude creates a draft (never sends); returns `{"success": true, "draftId": "..."}`
- Mac app email card: "Open in Mail" is always visible and is the active demo path; "Save to Gmail Drafts" is shown only when `gmailIntegrationEnabled`

### Slack Draft Flow (Mac App)

The `RelaySlackOutputCard` has a draft → edit → send state machine:
1. **idle** — "Draft AE message for Slack" button (sparkles icon)
2. **generatingDraft** — calls `POST /api/slack-draft`; Claude writes a 1-2 sentence personal message
3. **editingDraft** — editable `TextEditor` shown; AE can rewrite; "Send to #relay-signals" button
4. **sendingDraft** — POSTs to `POST /api/slack` via `sendSlackUpdate()`
5. **sent** — green confirmation; "Send another" link to reset
6. **failed** — amber error with Retry link

The structured auto-notification (`slackUpdate`) is always shown above the draft section for reference.

### Editable Email Card

`RelayEmailOutputCard` pre-fills `@State private var editableSubject` and `@State private var editableEmailBody` from the Claude-generated content on `.onAppear`. The AE can edit both before clicking "Open in Mail" or "Save to Gmail Drafts". Copy and both send buttons always use the current editable values.

### Key Architecture Decisions

**Two surfaces, one backend**: Both web intake and Mac app call the same `relay-server` API.

**`/api/config` for feature flags**: Mac app never checks env vars. Fetched at every 30-second refresh cycle. In the current app, Slack and Gmail flags drive UI behavior; `salesforceEnabled` is present in the response model but not currently used by the UI.

**Google Sheets via Worker proxy**: Credentials (`GOOGLE_CLIENT_EMAIL`, `GOOGLE_PRIVATE_KEY`) are Cloudflare Worker secrets. The server only knows the sheet ID. No `googleapis` npm package on the server.

**SQLite via `node:sqlite`**: Synchronous, zero-dependency. Intakes persist locally even if Sheet/Slack/Salesforce hooks fail.

**Voice pipeline preserved**: `companionManager.start()` must never be skipped — it initialises push-to-talk shortcut, audio engine, and accessibility checks alongside the Relay UI.

**Inactive onboarding demo by default**: The checked-in public repo keeps the onboarding video + `onboardingDemoSystemPrompt` code for compatibility, but that path currently no-ops unless `OnboardingVideoURL` is set.

**`relayCurrentCustomerEmail`**: Set to `intake.email` when generating from an intake, `nil` for post-call notes. Pre-fills the Gmail/Mail To field.

---

## Key Files

### Web Server (`relay-server/`)

| File | Lines | Purpose |
|------|-------|---------|
| `server.js` | ~283 | Express server — all API routes, auto-fires Slack + Sheets on intake, and still contains Salesforce routes/hooks |
| `storage.js` | ~93 | SQLite storage — `initStorage`, `saveCustomerIntake`, `getRecentCustomerIntakes`, `saveGeneratedOutputs` |
| `claude.js` | ~330 | Claude integration — `analyzeCustomerIntake`, `analyzePostCallNotes`, `generateAESlackDraft`, `createGmailDraft`. Main backend analysis defaults to `claude-sonnet-4-6`. |
| `salesforce.js` | ~147 | Salesforce via `jsforce` — `createSalesforceTaskFromIntake`, `createSalesforceTaskFromNotes`, `testSalesforceConnection` |
| `sheets.js` | ~90 | Google Sheets via Cloudflare Worker proxy — `appendIntakeToSheet`, `testSheetsConnection`. No `googleapis` package. |
| `faq.json` | — | Local FAQ knowledge base — 10 entries |
| `.env` | — | Environment variables (gitignored — never commit) |
| `public/index.html` | — | Landing page |
| `public/intake.html` | — | Customer intake form with Claude analysis and copy-button output cards |

### Mac App (`leanring-buddy/`)

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~88 | App entry point. Calls `companionManager.start()`, shows panel on launch. |
| `CompanionManager.swift` | ~1407 | Central state. Relay models, @Published state, Relay API methods, and the retained voice pipeline. Checked-in `workerBaseURL` and `relayServerBaseURL` use placeholder values that should be replaced with your own Worker and backend URLs. Apple Speech is the default transcription provider and ElevenLabs handles spoken output. |
| `CompanionPanelView.swift` | ~1353 | Relay AE Command Center panel. Three tabs. `RelayEmailOutputCard` (editable subject + body). `RelaySlackOutputCard` (draft→edit→send). `RelayLogoView`. Auto-poll via `.task {}` loop. |
| `MenuBarPanelManager.swift` | ~302 | NSStatusItem + NSPanel lifecycle. Resizable panel: default 560pt, min 420pt, max 1000pt. `hasPanelBeenShownBefore` preserves user-resized dimensions. |
| `OverlayWindow.swift` | ~882 | Full-screen cursor overlay. Uses `RelayLogoView` instead of the original `Triangle` shape. |
| `ClaudeAPI.swift` | ~291 | Claude streaming API — voice features only. |
| `DesignSystem.swift` | ~880 | Design tokens. Key: `DS.Colors.background`, `surface1/2/3/4`, `accent` (#2563eb), `textPrimary/Secondary/Tertiary`, `borderSubtle`. Never hardcode hex in SwiftUI. |
| `worker/src/index.ts` | ~326 | Cloudflare Worker — Claude, ElevenLabs, Google Sheets, and dormant AssemblyAI token route. JWT signing via Web Crypto for Google OAuth. |

### Key Types in `CompanionManager.swift`

| Type | Kind | Purpose |
|------|------|---------|
| `RelayActiveTab` | enum | `.customerAsks` / `.postCallNotes` / `.outputs` |
| `RelayCustomerIntake` | struct (Codable) | Customer intake record including optional `analysis` |
| `RelayAnalysisOutputs` | struct (Codable) | All Claude-generated outputs + nested `RelayClassification`, `RelayFAQMatch`, `RelayCustomerEmail` |
| `RelayServerConfig` | struct (Decodable) | Response from `GET /api/config` |
| `RelayGmailDraftResult` | struct (Decodable) | Response from `POST /api/gmail-draft` |
| `RelayGmailError` | enum (LocalizedError) | Gmail error cases |
| `RelaySlackSendResult` | struct (Decodable) | Response from `POST /api/slack` |
| `RelaySlackError` | enum (LocalizedError) | Slack error cases |

### Key Types in `CompanionPanelView.swift`

| Type | Kind | Purpose |
|------|------|---------|
| `RelayLogoView` | SwiftUI View | Three-circle Relay logo rendered via Canvas from 24×24 SVG viewBox. Used in header, menu bar icon, cursor overlay. |
| `RelayEmailOutputCard` | SwiftUI View | Email card with editable `TextField` (subject) and `TextEditor` (body), plus Open in Mail and optional Gmail buttons |
| `RelaySlackOutputCard` | SwiftUI View | Slack card with draft→edit→send state machine (`RelaySlackCardState`) |

---

## Build & Run

### Web Server

```bash
cd relay-server
npm install          # express, cors, dotenv, jsforce
npm start            # node --experimental-sqlite server.js
npm run dev          # same with --watch for auto-restart
```

### Mac App

```bash
open leanring-buddy.xcodeproj
# Cmd+R — relay-server must be reachable at whatever URL `relayServerBaseURL` is set to.
# The checked-in default is a placeholder. Update it to localhost, ngrok, or your deployed backend.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC permissions.

### Cloudflare Worker

```bash
cd worker
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put GOOGLE_CLIENT_EMAIL   # service account email
npx wrangler secret put GOOGLE_PRIVATE_KEY    # PEM private key with \n sequences
npx wrangler deploy
```

Verify Google Sheets connection:
```bash
curl "https://your-worker-name.your-subdomain.workers.dev/sheets-test?sheetId=YOUR_SHEET_ID"
```

---

## Environment Variables (relay-server)

| Variable | Default | Required for | Purpose |
|----------|---------|-------------|---------|
| `PORT` | `3000` | — | Server port |
| `CLAUDE_PROXY_URL` | `https://your-worker-name.your-subdomain.workers.dev/chat` | Claude analysis | Cloudflare Worker proxy URL |
| `CLAUDE_MODEL` | `claude-sonnet-4-6` | Claude analysis | Model ID for intake + notes analysis |
| `ANTHROPIC_API_KEY` | (unset) | Gmail MCP (required); Claude analysis (optional) | Direct Anthropic access. Required for Gmail MCP. |
| `SLACK_WEBHOOK_URL` | (unset) | Slack integration | Auto-posts on every intake if set |
| `SALESFORCE_USERNAME` | (unset) | Salesforce | Service account email |
| `SALESFORCE_PASSWORD` | (unset) | Salesforce | Login password (never share) |
| `SALESFORCE_SECURITY_TOKEN` | (unset) | Salesforce | Appended to password for SOAP auth |
| `SALESFORCE_LOGIN_URL` | `https://login.salesforce.com` | Salesforce | Use `https://test.salesforce.com` for sandboxes |
| `GMAIL_MCP_URL` | (unset) | Gmail | Gmail MCP server URL |
| `GMAIL_MCP_AUTH_TOKEN` | (unset) | Gmail | OAuth token for Gmail MCP |
| `GOOGLE_SHEET_ID` | (unset) | Google Sheets | Spreadsheet ID from sheet URL. Credentials live in Worker secrets. |
| `GOOGLE_SHEET_TAB` | `Relay Intakes` | Google Sheets | Tab name within the spreadsheet |
| `SHEETS_PROXY_URL` | (derived from `CLAUDE_PROXY_URL`) | Google Sheets | Worker base URL for Sheets routes |
| `DB_PATH` | `./relay.db` | — | SQLite file path |

**Cloudflare Worker secrets** (set via `wrangler secret put`):

| Secret | Purpose |
|--------|---------|
| `ANTHROPIC_API_KEY` | Claude API |
| `ASSEMBLYAI_API_KEY` | Legacy/dormant voice transcription path |
| `ELEVENLABS_API_KEY` | Text-to-speech |
| `GOOGLE_CLIENT_EMAIL` | Google service account email |
| `GOOGLE_PRIVATE_KEY` | Google service account private key (PEM with `\n`) |

---

## Code Style & Conventions

### Variable and Method Naming

- Be as clear and specific as possible — a developer with zero context should understand a name immediately
- Optimize for clarity over concision. No single-character variables.
- Keep argument names matching their source variable names

### Code Clarity

- Clear is better than clever. No functionality in fewer lines if it hurts readability.
- Add a comment when the name alone can't explain the why.

### Swift/SwiftUI Conventions

- SwiftUI for all UI unless AppKit-only
- All UI state updates on `@MainActor`
- All async operations use `async/await`
- All buttons: `.onHover { NSCursor.pointingHand.push() / NSCursor.pop() }`
- DS color tokens only — never hardcode hex in SwiftUI
- `@Published` and stored properties in `CompanionManager` class body, not extensions
- Never name a stored property `body` in a SwiftUI View — conflicts with `var body: some View`

### JavaScript Conventions

- ES modules (`type: "module"`)
- `node:sqlite` is synchronous — no `await` on DB calls
- Claude prompts emphasize concise, low-filler output. The intake and notes analysis prompts explicitly enforce strict JSON output and no invented facts.
- Analysis responses are JSON — use `extractJSONFromClaudeResponse`
- Gmail/MCP responses use `extractFinalTextFromResponse`

### Integration Pattern

New integrations follow the established degradation pattern:
1. Check env var server-side — skip silently or return 503 if not set
2. Expose boolean flag in `GET /api/config`
3. Mac app reads config at refresh; shows/hides button accordingly
4. Always keep a Copy fallback — never remove it when adding a send button

### Do NOT

- Do not add features, refactor, or improve beyond what was asked
- Do not add comments or annotations to code you didn't change
- Do not fix known non-blocking warnings (Swift 6 concurrency, deprecated `onChange`)
- Do not rename the project directory or scheme (`leanring` typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions
- Do not claim integrations are live unless the relevant env var/secret is configured
- Do not comment out or remove `companionManager.start()` — it initialises push-to-talk
- Do not use `better-sqlite3` — use `node:sqlite` (built-in, works on Node 23+)
- Do not create a nested `.git` inside `relay-server/` — it breaks outer repo tracking
- Do not put `GOOGLE_CLIENT_EMAIL` or `GOOGLE_PRIVATE_KEY` in `.env` — they are Worker secrets only

---

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, explain the why
- Do not force-push to main
- Never commit `.env` — gitignored, contains real credentials
- `relay-server/node_modules/`, `relay-server/relay.db`, `relay-server/.env` are all gitignored

---

## Self-Update Instructions

Update this file when changes affect architecture, integrations, API routes, env vars, key files, or conventions. Specifically:

1. **New files** — add to Key Files with purpose and line count
2. **Deleted files** — remove their entries
3. **Architecture changes** — update relevant section
4. **New env vars** — add to the env vars table with `Required for` filled in
5. **New Worker secrets** — add to the Worker secrets table
6. **New API routes** — add to the routes table
7. **New integrations** — add to Integration Degradation Pattern table
8. **Line count drift** — update if a file changes by more than 50 lines
9. **New shared types** — add to Key Types tables

Do NOT update for minor edits, bug fixes, or changes that don't affect documented architecture or conventions.
