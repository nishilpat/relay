import jsforce from 'jsforce';

// Cached connection — re-authenticated automatically on session expiry.
let activeConnection = null;

function isSalesforceConfigured() {
  return !!(
    process.env.SALESFORCE_USERNAME &&
    process.env.SALESFORCE_PASSWORD &&
    process.env.SALESFORCE_SECURITY_TOKEN
  );
}

async function getAuthenticatedConnection() {
  if (activeConnection) return activeConnection;

  const conn = new jsforce.Connection({
    loginUrl: process.env.SALESFORCE_LOGIN_URL || 'https://login.salesforce.com',
  });

  // jsforce SOAP login: password must have the security token appended directly.
  await conn.login(
    process.env.SALESFORCE_USERNAME,
    process.env.SALESFORCE_PASSWORD + process.env.SALESFORCE_SECURITY_TOKEN
  );

  console.log(`[Salesforce] Authenticated as ${process.env.SF_USERNAME}`);
  activeConnection = conn;
  return conn;
}

async function getConnectionWithAutoReconnect() {
  try {
    return await getAuthenticatedConnection();
  } catch (error) {
    // Session may have expired — clear cached connection and retry once.
    if (error.errorCode === 'INVALID_SESSION_ID' || error.name === 'INVALID_SESSION_ID') {
      console.log('[Salesforce] Session expired — re-authenticating…');
      activeConnection = null;
      return await getAuthenticatedConnection();
    }
    throw error;
  }
}

// Attempt to find an existing Salesforce Account by company name so the Task
// can be linked to it. Returns the Account Id or null if not found.
async function findAccountIdByCompanyName(conn, companyName) {
  try {
    const result = await conn.query(
      `SELECT Id FROM Account WHERE Name = '${companyName.replace(/'/g, "\\'")}' LIMIT 1`
    );
    return result.records.length > 0 ? result.records[0].Id : null;
  } catch {
    return null;
  }
}

// Maps Relay urgency strings to Salesforce Task priority values.
function mapUrgencyToSalesforcePriority(urgency) {
  const lower = urgency.toLowerCase();
  if (lower.includes('blocking')) return 'High';
  if (lower === 'high') return 'High';
  if (lower === 'medium') return 'Normal';
  return 'Low';
}

// Returns today + 3 days as a Salesforce date string (YYYY-MM-DD).
function defaultActivityDate() {
  const date = new Date();
  date.setDate(date.getDate() + 3);
  return date.toISOString().split('T')[0];
}

// Creates a Salesforce Task from a Relay customer intake + Claude analysis.
// Links the Task to an existing Account if one is found by company name.
export async function createSalesforceTaskFromIntake(intakeRecord, analysisOutputs) {
  if (!isSalesforceConfigured()) return { skipped: true, reason: 'Salesforce not configured' };

  const conn = await getConnectionWithAutoReconnect();

  const accountId = await findAccountIdByCompanyName(conn, intakeRecord.company);

  const taskFields = {
    Subject: `Relay: ${intakeRecord.company} — ${analysisOutputs.classification.category}`,
    Description: analysisOutputs.salesforceNote,
    Status: 'Not Started',
    Priority: mapUrgencyToSalesforcePriority(analysisOutputs.classification.urgency),
    ActivityDate: defaultActivityDate(),
    // Link to Account if found; otherwise the Task is unlinked (AE can assign manually).
    ...(accountId ? { WhatId: accountId } : {}),
  };

  const result = await conn.sobject('Task').create(taskFields);

  if (!result.success) {
    throw new Error(`Salesforce Task creation failed: ${JSON.stringify(result.errors)}`);
  }

  console.log(`[Salesforce] Task created: ${result.id}${accountId ? ` (linked to Account ${accountId})` : ' (unlinked)'}`);
  return { success: true, taskId: result.id, linkedAccountId: accountId };
}

// Creates a Salesforce Task from AE post-call notes analysis.
export async function createSalesforceTaskFromNotes(notesData, analysisOutputs) {
  if (!isSalesforceConfigured()) return { skipped: true, reason: 'Salesforce not configured' };

  const conn = await getConnectionWithAutoReconnect();

  const companyName = notesData.company || 'Unknown';
  const accountId = await findAccountIdByCompanyName(conn, companyName);

  const taskFields = {
    Subject: `Relay post-call: ${companyName} — ${notesData.dealStage || 'No stage'}`,
    Description: analysisOutputs.salesforceNote,
    Status: 'Not Started',
    Priority: mapUrgencyToSalesforcePriority(analysisOutputs.classification.urgency),
    ActivityDate: defaultActivityDate(),
    ...(accountId ? { WhatId: accountId } : {}),
  };

  const result = await conn.sobject('Task').create(taskFields);

  if (!result.success) {
    throw new Error(`Salesforce Task creation failed: ${JSON.stringify(result.errors)}`);
  }

  console.log(`[Salesforce] Task created: ${result.id}${accountId ? ` (linked to Account ${accountId})` : ' (unlinked)'}`);
  return { success: true, taskId: result.id, linkedAccountId: accountId };
}

// Verifies the Salesforce connection — used by the /api/salesforce-test route.
export async function testSalesforceConnection() {
  if (!isSalesforceConfigured()) {
    return { configured: false, reason: 'SALESFORCE_USERNAME, SALESFORCE_PASSWORD, or SALESFORCE_SECURITY_TOKEN not set in .env' };
  }

  const conn = await getConnectionWithAutoReconnect();
  const identity = await conn.identity();
  return {
    configured: true,
    connected: true,
    username: identity.username,
    displayName: identity.display_name,
    orgId: identity.organization_id,
  };
}
