# Technical Approach

## Recommended MVP Path

Start with import-first processing:

1. User exports Messages data as CSV, TXT, JSON, or PDF text from a trusted tool.
2. ThreadPilot imports the file locally.
3. A parser normalizes conversations into thread, participant, message, timestamp, and read-state-like metadata where available.
4. A classifier assigns each thread to Action Required, Opportunities, or Noise.
5. A summarizer produces a thread brief and suggested next step.

This avoids fragile private assumptions about Apple Messages internals while proving the product value.

## Advanced macOS Mode

For power users, ThreadPilot may offer direct local indexing of the macOS Messages database after explicit consent and Full Disk Access. This path needs careful review before App Store distribution.

Potential constraints:

- Apple does not provide a stable public Messages history API.
- The local Messages database schema may change across macOS versions.
- Full Disk Access is a high-trust permission.
- App Store review may scrutinize the privacy model heavily.

## Processing Pipeline

- `Ingest`: parse source data into normalized message records.
- `Threading`: group messages by conversation and participant set.
- `Feature Extraction`: detect unread count, recency, dates, questions, commitments, requests, links, money, and sender type.
- `Classification`: assign category and confidence.
- `Summarization`: create brief, important-message list, timeline, and next action.
- `Review Feedback`: capture user corrections for future tuning.

## Classification Signals

Action Required:

- Direct requests or questions.
- Deadline language.
- Unanswered latest message from another person.
- Scheduling, payment, document, health, family, or travel terms.

Opportunities:

- Invitation language.
- Referral, intro, job, sale, meeting, collaboration, or event terms.
- Positive sentiment plus a proposed next step.

Noise:

- Automated alerts.
- OTP/security codes after expiration.
- Delivery/status updates.
- Group chatter without direct mentions.
- Threads with no open question or commitment.

## Suggested Local Technologies

- SwiftUI for the app.
- SQLite for local index storage.
- NaturalLanguage framework for lightweight tagging.
- Foundation Models or another local LLM option where available.
- Optional API adapter for cloud model summarization with explicit consent.
