import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import path from 'path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const faqKnowledgeBase = JSON.parse(readFileSync(path.join(__dirname, 'faq.json'), 'utf-8'));

const CLAUDE_PROXY_URL = process.env.CLAUDE_PROXY_URL || 'https://your-worker-name.your-subdomain.workers.dev/chat';
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const CLAUDE_MODEL = process.env.CLAUDE_MODEL || 'claude-sonnet-4-6';

async function callClaude(prompt) {
  const requestBody = {
    model: CLAUDE_MODEL,
    max_tokens: 2500,
    messages: [{ role: 'user', content: prompt }],
  };

  let response;

  if (ANTHROPIC_API_KEY) {
    response = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify(requestBody),
    });
  } else {
    response = await fetch(CLAUDE_PROXY_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(requestBody),
    });
  }

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Claude API error ${response.status}: ${errorText}`);
  }

  const result = await response.json();
  return result.content[0].text;
}

// Calls the Anthropic API directly with mcp_servers included so Claude can
// use the Gmail MCP tool. Always calls Anthropic directly (not via proxy)
// because mcp_servers requires the beta header and direct key access.
async function callClaudeWithMCPServers(prompt, mcpServers) {
  if (!ANTHROPIC_API_KEY) {
    throw new Error('ANTHROPIC_API_KEY is required for Gmail MCP integration. Set it in .env.');
  }

  const requestBody = {
    model: CLAUDE_MODEL,
    max_tokens: 1024,
    mcp_servers: mcpServers,
    messages: [{ role: 'user', content: prompt }],
  };

  const response = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
      'anthropic-beta': 'mcp-client-2025-04-04',
    },
    body: JSON.stringify(requestBody),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Claude MCP API error ${response.status}: ${errorText}`);
  }

  return await response.json();
}

// Extracts the final text block from a Claude response that may contain
// multiple content blocks (text, tool_use, tool_result from MCP calls).
function extractFinalTextFromResponse(claudeResponse) {
  const textBlocks = (claudeResponse.content || [])
    .filter(block => block.type === 'text')
    .map(block => block.text);

  if (textBlocks.length === 0) {
    throw new Error('No text content in Claude response');
  }
  // The last text block is Claude's final summary after MCP tool use.
  return textBlocks[textBlocks.length - 1];
}

// Generates a short, conversational Slack message in the AE's voice — not the
// structured auto-notification, but what the AE would actually type to their team.
// Returns plain text (no JSON), ready to paste or edit in the Mac app.
export async function generateAESlackDraft(analysisOutputs) {
  const prompt = `You are helping an Account Executive write a brief Slack message to their internal sales team.

Context from a recent customer interaction:
- Summary: ${analysisOutputs.executiveSummary}
- Category: ${analysisOutputs.classification.category}
- Urgency: ${analysisOutputs.classification.urgency}
- Revenue impact: ${analysisOutputs.classification.revenueImpact}
- Recommended owner: ${analysisOutputs.classification.recommendedOwner}
- Key tasks: ${(analysisOutputs.nextStepTasks || []).slice(0, 3).join('; ')}

Write a SHORT Slack message — 1-2 sentences max — in the AE's own voice. Personal, direct, action-oriented. What the AE would actually type in Slack, not a report.

Good examples of the tone:
- "Just got off with Acme. Blocked on HubSpot + SSO for Q3 rollout — could be $80k. Need Sales Eng to confirm integration support ASAP."
- "New blocker from TechFlow via Relay — SSO required before they sign. Routing to Sales Eng + Security. Response needed this week."
- "Acme submitted questions through the Relay link. Integration + security review needed before they move forward. Flagging for the team."

Return ONLY the Slack message text. No JSON, no quotes, no label, no prefix.`;

  const rawText = await callClaude(prompt);
  return rawText.trim();
}

// Creates a Gmail draft via Claude + Gmail MCP. Claude uses the Gmail MCP tool
// to save the draft — the AE reviews and sends manually. Never sends automatically.
export async function createGmailDraft(toAddress, subject, emailBody) {
  const gmailMCPUrl = process.env.GMAIL_MCP_URL;
  const gmailMCPAuthToken = process.env.GMAIL_MCP_AUTH_TOKEN;

  if (!gmailMCPUrl) {
    throw new Error('GMAIL_MCP_URL not configured');
  }

  const mcpServers = [{
    type: 'url',
    url: gmailMCPUrl,
    name: 'gmail',
    ...(gmailMCPAuthToken ? { authorization_token: gmailMCPAuthToken } : {}),
  }];

  const prompt = `You are helping an Account Executive save a follow-up email as a Gmail draft.

Create a Gmail draft with EXACTLY these details. Save as draft only — do NOT send it.

To: ${toAddress || ''}
Subject: ${subject}
Body:
${emailBody}

Use the Gmail MCP tool to create this draft. After creating it successfully, respond with ONLY this JSON and nothing else:
{"success": true, "draftId": "<the actual Gmail draft ID returned by the tool>"}

If the tool call fails, respond with:
{"success": false, "error": "<reason>"}`;

  const claudeResponse = await callClaudeWithMCPServers(prompt, mcpServers);
  const finalText = extractFinalTextFromResponse(claudeResponse).trim();

  // Parse the JSON response Claude was instructed to return.
  try {
    return JSON.parse(finalText);
  } catch {
    // Fallback: try to extract draftId from the text if Claude added extra prose.
    const draftIdMatch = finalText.match(/"draftId"\s*:\s*"([^"]+)"/);
    if (draftIdMatch) {
      return { success: true, draftId: draftIdMatch[1] };
    }
    throw new Error(`Could not parse Gmail draft response: ${finalText.slice(0, 200)}`);
  }
}

function extractJSONFromClaudeResponse(rawText) {
  const jsonBlockMatch = rawText.match(/```json\n([\s\S]*?)\n```/);
  if (jsonBlockMatch) return JSON.parse(jsonBlockMatch[1]);

  const trimmed = rawText.trim();
  if (trimmed.startsWith('{')) return JSON.parse(trimmed);

  throw new Error('Could not extract JSON from Claude response');
}

function buildFAQContext() {
  return faqKnowledgeBase
    .map(entry => `Q: ${entry.question}\nA: ${entry.answer}\nRoute to: ${entry.routeTo}`)
    .join('\n\n');
}

export async function analyzeCustomerIntake(intake) {
  const prompt = `You are Relay, a sales workflow intelligence agent. A customer submitted the following through a sales handoff page.

CUSTOMER INTAKE:
- Name: ${intake.name}
- Company: ${intake.company}
- Email: ${intake.email}
- Question / Request: ${intake.question}
- Blocking anything? ${intake.isBlocking || 'Not specified'}
- Timeline: ${intake.timeline || 'Not specified'}
- Category selected: ${intake.category}
- Urgency selected: ${intake.urgency}

INTERNAL FAQ / KNOWLEDGE BASE:
${buildFAQContext()}

Analyze this customer intake and generate the full Relay sales follow-through package.

Return ONLY a valid JSON object with no additional text or markdown, using this exact structure:
{
  "executiveSummary": "2-3 sentence max: who the customer is, what they need, and the key risk or blocker. No filler.",
  "classification": {
    "category": "one of: General question | Pricing/deal question | Feature request | Bug/problem | Integration question | Security/legal/procurement | Expansion/renewal | Other",
    "urgency": "one of: Low | Medium | High | Blocking deal",
    "sentiment": "one of: Positive | Neutral | Concerned | Frustrated",
    "revenueImpact": "description of potential revenue impact, or 'unknown'",
    "recommendedOwner": "which team or person should own the response",
    "needsHumanFollowUp": true
  },
  "faqMatch": {
    "found": true,
    "confidence": "one of: Low | Medium | High",
    "answer": "brief helpful answer if found in FAQ, otherwise null"
  },
  "customerEmail": {
    "subject": "short specific subject line",
    "body": "Short email draft — 3-4 sentences max. Acknowledge their question, note what you are confirming internally, give one clear next step. No padding. Sign off as Nishil."
  },
  "salesforceNote": "Account: [name]\\nContact: [name, email]\\nSummary: [1-2 sentences]\\nKey asks:\\n- [item]\\nRisks/blockers:\\n- [item]\\nNext steps:\\n- [item]\\nFollow-up date: [estimate or TBD]\\nSuggested task: [specific action item]",
  "slackUpdate": "Customer signal: [Company] — [topic]\\nImpact: [revenue or deal impact]\\nAsk: [what is needed]\\nOwner: [recommended team]\\nDeadline: [urgency / date]",
  "productRequest": "Request type: [type]\\nDescription: [clear description]\\nCustomer evidence: [quote or paraphrase]\\nBusiness impact: [deal size, urgency, risk]\\nUrgency: [Low/Medium/High/Blocking]\\nSuggested owner: [team]",
  "nextStepTasks": [
    "Reply to ${intake.name} at ${intake.company} confirming receipt",
    "specific task 2 referencing their actual question",
    "specific task 3",
    "specific task 4",
    "specific task 5"
  ],
  "rawData": {
    "name": "${intake.name}",
    "company": "${intake.company}",
    "email": "${intake.email}",
    "category": "${intake.category}",
    "urgency": "${intake.urgency}",
    "processedAt": "${new Date().toISOString()}",
    "processedBy": "Relay v1.0"
  }
}

Rules:
1. Be concise. Every field should be as short as possible while staying accurate. No filler, no padding, no restating what is obvious.
2. Do not invent facts. Mark unknown fields as "unknown" or "not specified."
3. The customer email must be warm and cautious — never promise something you cannot confirm.
4. If the FAQ has a relevant High-confidence answer, include it in the customer email body.
5. nextStepTasks must reference the specific topics from this intake (e.g. "Confirm SSO support on enterprise plan" not just "Check integrations").
6. All \\n in string values should be literal newlines represented as \\n in the JSON.`;

  const rawResponse = await callClaude(prompt);
  return extractJSONFromClaudeResponse(rawResponse);
}

export async function analyzePostCallNotes(notesData) {
  const prompt = `You are Relay, a sales workflow intelligence agent. An Account Executive pasted the following post-call notes.

POST-CALL NOTES:
Company / Account: ${notesData.company || 'Not specified'}
Contact: ${notesData.contact || 'Not specified'}
Deal Stage: ${notesData.dealStage || 'Not specified'}
Deal Size / Revenue Impact: ${notesData.dealSize || 'Not specified'}
Next Meeting Date: ${notesData.nextMeetingDate || 'Not specified'}
Internal Teams Needed: ${notesData.internalTeams || 'Not specified'}

Notes / Transcript:
${notesData.notes}

INTERNAL FAQ / KNOWLEDGE BASE:
${buildFAQContext()}

Analyze these post-call notes and generate the full Relay sales follow-through package.

Return ONLY a valid JSON object with no additional text or markdown, using this exact structure:
{
  "executiveSummary": "2-3 sentence max: who the customer is, the deal blockers, and the immediate next step. No filler.",
  "classification": {
    "category": "Post-call debrief",
    "urgency": "one of: Low | Medium | High | Blocking deal",
    "sentiment": "one of: Positive | Neutral | Concerned | Frustrated",
    "revenueImpact": "deal size or estimated ARR impact from the notes, or 'unknown'",
    "recommendedOwner": "which team or person should own the follow-through",
    "needsHumanFollowUp": true
  },
  "faqMatch": {
    "found": false,
    "confidence": "Low",
    "answer": null
  },
  "customerEmail": {
    "subject": "Follow-up from our conversation — [main topic from notes]",
    "body": "Short email draft — 3-4 sentences max. Reference one or two specific topics from the call, confirm next steps, note what you are following up on. No padding. Sign off as Nishil."
  },
  "salesforceNote": "Account: [from notes]\\nContact: [from notes]\\nSummary: [1-2 sentences from the call]\\nKey asks:\\n- [extracted from notes]\\nRisks/blockers:\\n- [extracted from notes]\\nNext steps:\\n- [extracted from notes]\\nFollow-up date: [from notes or estimate]\\nSuggested task: [specific CRM task]",
  "slackUpdate": "Customer signal: [Company] — [main topics from notes]\\nImpact: [deal size from notes]\\nAsk: [what internal teams need to deliver]\\nOwner: [teams mentioned in notes]\\nDeadline: [timeline from notes]",
  "productRequest": "Request type: [type extracted from notes]\\nDescription: [what customer needs]\\nCustomer evidence: [direct quote or paraphrase from notes]\\nBusiness impact: [deal size, risk, urgency]\\nUrgency: [based on timeline and deal stage]\\nSuggested owner: [team]",
  "nextStepTasks": [
    "specific task extracted from notes 1",
    "specific task extracted from notes 2",
    "specific task extracted from notes 3",
    "specific task extracted from notes 4",
    "specific task extracted from notes 5"
  ],
  "rawData": {
    "company": "${notesData.company || ''}",
    "contact": "${notesData.contact || ''}",
    "dealStage": "${notesData.dealStage || ''}",
    "dealSize": "${notesData.dealSize || ''}",
    "nextMeetingDate": "${notesData.nextMeetingDate || ''}",
    "processedAt": "${new Date().toISOString()}",
    "processedBy": "Relay v1.0"
  }
}

Rules:
1. Be concise. Every field should be as short as possible while staying accurate. No filler, no padding, no restating the obvious.
2. Extract specific technical requirements (SSO, integrations, exports, etc.) and name them explicitly in all outputs.
2. Identify all deal blockers and name them explicitly in salesforceNote and slackUpdate.
3. Reference all stakeholders mentioned in the notes (CTO, VP Sales, etc.).
4. The customer email should reference specific topics from the call — it must feel like the AE wrote it right after the meeting.
5. nextStepTasks must be concrete and specific to the content of these notes. Do not use generic tasks.
6. Do not invent facts. If something is unclear, note it as needing clarification.`;

  const rawResponse = await callClaude(prompt);
  return extractJSONFromClaudeResponse(rawResponse);
}
