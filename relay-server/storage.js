// Uses Node.js built-in SQLite (node:sqlite, available in Node 22.5+).
// No native compilation required.
import { DatabaseSync } from 'node:sqlite';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let db;

export function initStorage() {
  const dbPath = process.env.DB_PATH || path.join(__dirname, 'relay.db');
  db = new DatabaseSync(dbPath);

  db.exec(`
    CREATE TABLE IF NOT EXISTS intakes (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      company TEXT NOT NULL,
      email TEXT NOT NULL,
      question TEXT NOT NULL,
      is_blocking TEXT,
      timeline TEXT,
      category TEXT NOT NULL DEFAULT 'General question',
      urgency TEXT NOT NULL DEFAULT 'Medium',
      summary TEXT,
      analysis_json TEXT,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS saved_outputs (
      id TEXT PRIMARY KEY,
      intake_id TEXT,
      source_type TEXT NOT NULL,
      outputs_json TEXT NOT NULL,
      created_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_intakes_created_at ON intakes(created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_outputs_intake_id ON saved_outputs(intake_id);
  `);

  console.log(`[Storage] Initialized at ${dbPath}`);
}

export function saveCustomerIntake(intakeData) {
  db.prepare(`
    INSERT OR REPLACE INTO intakes
      (id, name, company, email, question, is_blocking, timeline, category, urgency, summary, analysis_json, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    intakeData.id,
    intakeData.name,
    intakeData.company,
    intakeData.email,
    intakeData.question,
    intakeData.isBlocking ?? null,
    intakeData.timeline ?? null,
    intakeData.category,
    intakeData.urgency,
    intakeData.summary ?? null,
    intakeData.analysis ? JSON.stringify(intakeData.analysis) : null,
    intakeData.createdAt
  );
}

export function getRecentCustomerIntakes(limit = 20) {
  return db.prepare(`
    SELECT * FROM intakes ORDER BY created_at DESC LIMIT ?
  `).all(limit).map(row => ({
    id: row.id,
    name: row.name,
    company: row.company,
    email: row.email,
    question: row.question,
    isBlocking: row.is_blocking,
    timeline: row.timeline,
    category: row.category,
    urgency: row.urgency,
    summary: row.summary,
    analysis: row.analysis_json ? JSON.parse(row.analysis_json) : null,
    createdAt: row.created_at,
  }));
}

export function saveGeneratedOutputs(sourceType, intakeId, outputsData) {
  const outputId = crypto.randomUUID();
  db.prepare(`
    INSERT INTO saved_outputs (id, intake_id, source_type, outputs_json, created_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(outputId, intakeId ?? null, sourceType, JSON.stringify(outputsData), new Date().toISOString());
  return outputId;
}
