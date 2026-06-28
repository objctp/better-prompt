import { appendFileSync, mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { AuditEntry, PipelineState } from "./types";

export function writeAudit(auditPath: string, entry: AuditEntry): void {
  mkdirSync(dirname(auditPath), { recursive: true });
  appendFileSync(auditPath, `${JSON.stringify(entry)}\n`);
}

export function writeState(statePath: string, state: PipelineState): void {
  mkdirSync(dirname(statePath), { recursive: true });
  writeFileSync(statePath, `${JSON.stringify(state)}\n`);
}

export function clearState(statePath: string): void {
  try {
    unlinkSync(statePath);
  } catch {
    // best effort
  }
}
