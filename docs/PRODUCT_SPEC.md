# ThreadPilot Product Spec

## Problem

Important messages get buried in long or noisy threads. Users need a fast way to find unread conversations that require action, contain opportunities, or can safely be ignored.

## Target User

Busy professionals, founders, caregivers, operators, and anyone whose personal Messages app doubles as a task inbox.

## Core Jobs

- Show unread or recently active threads ranked by importance.
- Categorize threads into Action Required, Opportunities, and Noise.
- Summarize long threads without losing the reason they matter.
- Extract follow-up actions, dates, commitments, money mentions, links, addresses, and open questions.
- Let users mark the categorization as correct or incorrect to improve future triage.

## Acceptance Criteria

- The app can ingest sample message-thread data from a local fixture.
- The app shows categorized thread groups.
- Each thread displays unread count, summary, suggested action, and confidence.
- The app design does not imply automatic iPhone Messages access.
- Any direct macOS Messages access is presented as an advanced, permissioned mode.
- Cloud AI processing is opt-in and clearly labeled.

## Non-Goals

- Sending messages on the user's behalf.
- Secretly reading Messages without permission.
- iOS automatic full-history scanning.
- Replacing Apple Messages as the primary messaging client.

## Privacy Requirements

- Default to local processing or local import.
- Make Full Disk Access optional and explain why it is needed.
- Never upload message content without explicit user approval.
- Provide a delete-all-local-data control.
- Show when summaries were generated and by which processing mode.

## Open Questions

- Should the first MVP rely only on user-imported exports?
- Is direct macOS `chat.db` access acceptable for the intended distribution path?
- Which local model stack should be used for summaries and classification?
- Should the app support legal/archive exports, or stay focused on daily triage?
