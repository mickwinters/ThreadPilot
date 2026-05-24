# ThreadPilot

ThreadPilot is a macOS app concept for organizing unread Apple Messages threads into practical triage lanes:

- **Action Required**: threads that need a reply, decision, payment, scheduling, or follow-up.
- **Opportunities**: invitations, referrals, warm leads, reconnect moments, and time-sensitive possibilities.
- **Noise**: low-value chatter, confirmations, automated messages, and threads that can wait.

The app is designed around a privacy-first Mac workflow. Apple does not provide a public iOS API for scanning message history, so ThreadPilot targets macOS where users can explicitly grant access or import exported message data.

## Project Goals

- Identify unread or recently active threads that matter.
- Summarize long conversations into short, useful briefings.
- Detect likely tasks, commitments, deadlines, dates, money mentions, links, addresses, and open questions.
- Keep processing local by default where possible.
- Make any cloud AI processing explicit, optional, and auditable.

## Early App Shape

- SwiftUI macOS app shell.
- Local-first categorization pipeline.
- Thread list grouped by triage category.
- Per-thread summary, important messages, suggested next action, and confidence score.
- Import mode for CSV/TXT exports from tools like iMazing, Decipher TextMessage, or MessageHarvest.
- Optional advanced mode for direct macOS Messages database access with clear user consent.

## Development

This scaffold uses Swift Package Manager for a lightweight prototype.

```bash
cd ThreadPilot
swift build
swift run ThreadPilot
```

For a production app, migrate this prototype into an Xcode macOS app target with entitlements, onboarding, permissions UX, and notarization/App Store review preparation.
