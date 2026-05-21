# Nisbah Learning — System Design Document

## 1. Overview

Nisbah Learning is a **web-only** two-sided marketplace connecting students with Islamic teachers for paid one-on-one lessons (Quran, Hadith, Arabic, Fiqh, Usul, Aqidah). Students discover teachers, negotiate a contract, pay on a recurring monthly schedule, attend live video sessions, review AI-generated session transcripts, and read uploaded materials. Teachers list themselves, run sessions, and receive biweekly payouts net of platform commission. Admins resolve vetting edge cases, flagged messages, and disputes.

The system is deliberately sized for **product validation**, not scale: 300 MAU, ~100 video-hours/month. The architecture is a **modular monolith** (Node.js + TypeScript) on a **single VM behind Nginx**, leaning on managed services (Supabase, Stripe, Daily.co for video, AWS S3 + CloudFront) so the team writes business logic, not infrastructure.

**Out of scope:** native mobile apps; the automated vetting *algorithm* (the pipeline boundary and status machine are designed, the scoring logic is TBD); group/multi-party classes; in-house video infrastructure; cloud recording of sessions (replaced by free AI transcripts, see [Section 2.1](#21-functional-requirements)). Pricing — **25 % commission at launch, dropping to 15 % once a teacher has accumulated 500 delivered hours; no platform subscription fee; no cap on concurrent contracts per student** — is now fixed ([Section 2.1](#21-functional-requirements)).

## 2. Requirements

### 2.1 Functional Requirements

- **Auth & roles.** Email+password and Google OAuth, identical flow for both roles; role (`student` | `teacher`) chosen at signup. Admin is an internal role.
- **Teacher profile (public to signed-in users).** Photo (≤5 MB, optional), name + verified tick, hourly rate, subjects, certifications (required), ijaza (required), experience (optional), 1–2 min intro video, languages, preferred session length (≤2 h), availability (own timezone, displayed converted), ratings/reviews, expected reply time, completion badges.
- **Student profile (private).** Photo, name, prior studies — visible only to a teacher in an active contract with that student.
- **Verification.** Every teacher is vetted at signup → `verified` (composite ≥0.85, no anomalies), `listed` unverified (0.55–0.85), or `rejected` (<0.55 or anomalies); ambiguous/anomalous cases go to an admin queue. Process completes ≤24 h. Unverified teachers are fully bookable; the tick is a trust signal, not a gate. Admin can promote/revoke verification.
- **Search & filters.** Subject, price band, rating floor, language, timezone (UTC−11..+13), availability day or Open Availability, gender.
- **Contract negotiation.** Student requests a teacher → teacher proposes a plan (subject, total duration, sessions/week, session length, total price) → student approves or requests changes (loop) → on approval **and** first-charge clearing, the contract is `active`. Terms: ≥1 month, ≥4 sessions.
- **Recurring payments.** All charges are in **USD** (business is registered in Canada; USD is the marketplace standard). Per active contract, monthly charge = `total_price ÷ length_months` on the contract anniversary. **There is no platform subscription fee** — revenue comes entirely from commission on teacher payouts. First charge (first month's slice) is taken at approval; contract activates only when it clears. **Anniversary day clamps to the last available day of a shorter month** (e.g. start Jan 29 → next charge Feb 28; start Mar 31 → next charge Apr 30; the original day resumes the next month it exists). **No cap on the number of concurrent active contracts a student may hold.**
- **Failed charges.** Retry timing is delegated to **Stripe Billing Smart Retries** (Stripe's ML-tuned retry schedule, configured in the Stripe dashboard) — we do not hand-code a fixed ladder. When Stripe emits the final-failure webhook the contract moves to `paused` (chat, video, transcripts, materials locked); 14 days paused → auto-cancel. Cross-border USD declines (foreign-issuer cards that block USD charges) follow the same path, with a clear student-facing message asking them to enable international charges and trigger a manual retry.
- **Refunds.** Mid-contract student cancel: current-month contract slice refunded, future months never billed. Cancel ≥24 h before contract start: full refund.
- **Teacher payouts.** Biweekly, for sessions actually delivered, minus commission. **Commission is 25 % at launch; the platform tracks each teacher's cumulative delivered hours, and the first payout after that count crosses 500 — and every payout after — is computed at 15 %.** If a slice is refunded mid-contract, the teacher is still paid for delivered sessions; the platform absorbs the gap.
- **In-app messaging.** All student↔teacher conversation is in-app; **every message is screened for contact-info / PII by an in-process regex/heuristic filter before delivery, strictly and uniformly — regardless of contract state**; flagged messages are held for admin and **persisted as a labelled corpus** for a future classifier. There is no relaxed mode; off-platform contact stays disallowed for the lifetime of the relationship.
- **Materials.** Teachers upload books/PDFs; students read in-app while the contract is active.
- **Sessions, timezones, rescheduling.** Times stored in UTC, displayed in viewer-local time with the teacher's original local time in brackets (`Mon 3:00 PM EST (originally 8:00 PM PKT)`). Students may request out-of-availability times; teacher accepts or counters. Cancel/reschedule requires ≥24 h notice; rescheduled into the same or following week.
- **Transcripts.** Every live session is transcribed by **Daily.co's built-in AI transcription** (Deepgram-backed) — no video recording. Speaker-labelled, timestamped transcripts are available to the student and teacher **for the lifetime of the contract** as a free feature (cost is absorbed into the platform commission, not billed separately). Transcripts are stored as text in Postgres and purged when the contract reaches a terminal state (`completed` or `cancelled`); while a contract is `paused`, transcripts are locked (not deleted) and become available again on resume.
- **Transactional email.** All platform email — auth (verification, password reset, magic link), contract lifecycle (proposal, approval, paused, cancelled, completed), billing (charge succeeded/failed, refund, card expiring), payouts (sent, KYC action required), sessions (booking confirmed, 24 h / 1 h reminders, transcript ready), and moderation/admin (PII flag escalation, dispute filed) — is sent through **Resend** as the single provider. Supabase Auth is configured to deliver its auth emails via Resend SMTP rather than its built-in mailer, so every outbound email shares one domain, one set of DKIM/SPF/DMARC records, and one set of delivery logs.

### 2.2 Non-Functional Requirements

- **Scale.** ~300 MAU; ~100 concurrent-equivalent video-hours/month. Single VM is sufficient; no horizontal scaling required.
- **Durability & consistency.** Contracts and payments require full **ACID** — handled via Postgres transactions and Stripe as the system of record for money; payment state changes are idempotent against Stripe webhook IDs.
- **Transcripts retention.** Transcript text retained in Postgres for the contract lifetime; deleted when the contract reaches `completed` or `cancelled`. No S3 involvement (transcripts are kilobytes of text, not media).
- **Availability.** Best-effort single-VM (~99% — SPOF accepted at this stage). RTO of minutes-to-hours via daily VM image rebuild; **RPO for business data is effectively zero** because all durable state lives in Supabase / S3 / Stripe, not on the VM.
- **Security.** TLS at Nginx; private media (contract PDFs, student photos) served only via short-lived **CloudFront signed URLs** minted after an authz check, buckets locked down with Origin Access Control; transcript and student-profile access enforced by Supabase Row-Level Security; secrets in environment, not image.
- **Observability.** Structured app logs, Stripe webhook audit trail, and scheduler job logs (billing runs, retries, payout batches, transcript purges, delivered-hours counter updates).

## 3. Architecture

```mermaid
graph TD
    Browser[React SPA]

    subgraph VM["Single VM (Docker Compose)"]
        Nginx[Nginx · TLS + static + proxy]
        subgraph App["Node.js modular monolith"]
            Auth[Auth]
            Profiles[Profiles / Search]
            Contracts[Contracts]
            Payments[Payments]
            Messaging[Messaging]
            Media[Materials / Sessions]
            Notifications[Notifications]
            Vetting[Vetting · TBD]
        end
        Worker[In-process Scheduler/Worker]
    end

    subgraph Ext["Managed / third-party services"]
        Supabase[(Supabase<br/>Postgres + Auth)]
        ObjStore[(AWS S3 + CloudFront)]
        Stripe[Stripe<br/>Billing + Connect]
        Video[Daily.co<br/>video · screen share · AI transcripts]
        Email[Resend<br/>transactional email]
    end

    Browser -->|HTTPS| Nginx
    Nginx -->|/api| Auth & Profiles & Contracts & Payments & Messaging & Media
    Stripe -->|webhooks| Nginx
    Video -->|transcript-ready webhook| Nginx

    Auth -->|verify JWT / OAuth| Supabase
    Profiles -->|SQL| Supabase
    Contracts -->|SQL txns| Supabase
    Payments -->|SQL txns| Supabase
    Payments -->|charges / refunds| Stripe
    Messaging -->|SQL · messages + flagged corpus| Supabase
    Media -->|signed URLs| ObjStore
    Media -->|rooms · transcripts| Video
    Media -->|transcript text| Supabase
    Vetting -->|status writes| Supabase

    Worker -->|recurring billing · payouts| Stripe
    Worker -->|state transitions · transcript purge · delivered-hours counter| Supabase
    Notifications -->|send| Email
    Supabase -->|auth emails via SMTP| Email
```

**Components.**

- **React SPA → Nginx → Node monolith.** Nginx terminates TLS, serves the built SPA's static assets, and reverse-proxies `/api` to the Node process. Both run as containers via a single Docker Compose file on one VM.
- **Auth module.** Delegates identity to **Supabase Auth** (email/password + Google OAuth); the app verifies Supabase-issued JWTs and maps them to a `users` row and role.
- **Profiles + Search.** Reads/writes profile data in Postgres; filtered search is a parameterized SQL query (300 users — no search engine needed). Computes timezone-converted availability for display.
- **Contracts.** Owns the request → propose → revise → approve state machine. Approval and first-charge clearing are committed together so a contract is never `active` without cleared payment.
- **Payments.** Wraps **Stripe Billing** (recurring contract slices + retry schedule) and **Stripe Connect** (biweekly teacher payouts with tiered commission split — 25% or 15% per teacher, selected at payout-batch open time from `delivered_hours_total`). Stripe is the source of truth for money; webhooks (received through Nginx) drive local payment state idempotently.
- **Messaging.** Persists messages in Postgres; every message passes through an **in-process regex/heuristic PII filter** (emails, phone numbers incl. spelled-out, URLs, social/IM handles, common app names) before delivery — no external service, no per-message cost, message content never leaves the VM (consistent with RLS + disabled Daily chat). Filtering is **strict and uniform on every message regardless of contract state** — there is no relaxed/post-contract mode. Flagged items are routed to the admin queue **and stored with their match metadata as a training corpus** (see [Section 8](#8-future-considerations) — a traditional classifier later, not an LLM). This is the *only* text channel — Daily's native in-call chat is switched off so no student↔teacher text can route around the filter. *Intentional MVP trade-off: regex accepts lower recall now in exchange for zero cost/latency/dependency; policy + account penalties are the backstop for what it misses.*
- **Materials & Sessions.** Binary files (photos, intro videos, PDFs) live in **AWS S3**; Postgres holds only the object key — never the bytes (see Storage below and the Trade-offs note on Postgres BLOBs). All media is fronted by **CloudFront**: public assets (profile photo, intro video) via a plain public distribution; private assets (contract PDFs, student photos) via short-lived **CloudFront signed URLs** the API mints *after* checking contract/role authorization. Live sessions use **Daily.co** (standard package: video/audio + screen sharing). **Daily's built-in in-call text chat is disabled** (`enable_chat: false`) and **video recording is disabled** (`enable_recording: false`) on every room. Instead, **Daily's AI transcription is enabled on every session** (Deepgram-backed): on session end Daily fires a transcript-ready webhook that the Sessions module persists as text in a `session_transcripts` row keyed by the session id (retained for the contract lifetime, purged on contract `completed`/`cancelled`). Transcripts are RLS-gated to the contract participants — no S3 or signed-URL flow required.
- **Notifications.** Centralizes all outbound transactional email through **Resend** (REST API from the Node app for app-triggered email; Resend SMTP wired into Supabase Auth so verification/reset/magic-link mails ship from the same domain and logs). Triggers span auth, contract lifecycle, billing, payouts, sessions (incl. 24 h / 1 h reminders fired by the worker), transcript-ready, and moderation/admin notices. Resend handles domain auth (SPF/DKIM/DMARC), bounce/complaint webhooks, and the suppression list; templates are colocated with the module (React Email).
- **Scheduler / Worker.** An in-process scheduler (single VM, single instance — no distributed locking needed) runs: triggering due Stripe invoices on contract anniversaries (Stripe Billing's Smart Retries handle decline retry timing — we don't), reacting to Stripe's final-failure webhook by moving the contract to `paused`, auto-cancelling after 14 days paused, the **biweekly payout batch** (which reads each teacher's `delivered_hours_total` at batch open time and applies 15% commission if ≥500 else 25%), incrementing `delivered_hours_total` whenever a session transitions to `delivered`, and the transcript purge (Postgres DELETE) when a contract reaches `completed`/`cancelled`.

**Infrastructure justification.** No message queue or cache: at 300 MAU the load fits one VM with direct Postgres access; introducing Kafka/Redis would be unjustified operational weight for product validation. Supabase removes auth + DB ops. Stripe removes PCI scope and billing-engine complexity. S3 + CloudFront decouples large media from the disposable VM and keeps image/video bytes off the Postgres connection pool.

**Storage.** Bytes in S3, only the key in Postgres. Class is chosen per access pattern; CloudFront fronts everything (cache + lower latency for a timezone-spread user base):

| Asset | S3 class | CloudFront | Access |
|---|---|---|---|
| Profile photo | Standard | Public dist. | Any signed-in user |
| Intro video (1–2 min) | Standard-IA | Public dist. | Public on profile |
| Books / PDFs | Standard | Signed URLs | Private; contract-gated |

Profile photos sit on **Standard**, not Infrequent Access: they render on every search card and profile view, and IA's per-GB *retrieval* fee penalizes exactly that hot pattern (IA also has 128 KB-billable and 30-day minimums). The intro video is on **Standard-IA** — watched rarely, and CloudFront absorbs the occasional cache-miss retrieval. Private buckets are reachable only through CloudFront via **Origin Access Control**; the API mints a short-lived **CloudFront signed URL** after the authz check (no public object URLs ever leave the server). Transcripts are not in S3 — they live in Postgres as text and are protected by RLS on the `session_transcripts` table.

**Critical flow — contract approval, first charge, activation:**

```mermaid
sequenceDiagram
    participant S as Student (SPA)
    participant App as Node app (Contracts/Payments)
    participant DB as Supabase Postgres
    participant Stripe as Stripe

    S->>App: POST /contracts/{id}/approve
    App->>DB: txn — status = pending_payment, payment(pending)
    App->>Stripe: charge (first slice)
    Stripe-->>App: PaymentIntent processing
    App-->>S: 202 Accepted — awaiting payment

    Stripe-->>App: webhook payment_intent.succeeded
    App->>DB: txn — payment cleared, status = active, set anniversaries
    App-->>S: contract active

    Note over App,Stripe: payment_intent.payment_failed → stays inactive, re-prompt student
```

A **Deployment & Recovery** note: the app is shipped as a Docker Compose stack (Nginx + Node) on a single VM; the VM **provider is left open** (Hetzner/DigitalOcean/Vultr vs AWS/GCP). The VM is **stateless** — all durable state is in Supabase, S3, and Stripe. A provider-scheduled **daily image snapshot** is taken; on VM failure a new VM is created from the latest image and DNS is repointed (minutes-to-hours RTO). No warm standby — unjustified cost at this scale.

## 4. API Design

REST over HTTPS, JSON, Supabase JWT in `Authorization`. Core, non-obvious endpoints:

| Method & Path | Request (key fields) | Response (key fields) | Status |
|---|---|---|---|
| `POST /auth/signup` | `email`, `password` \| OAuth token, `role` | `user_id`, `role` | 201 / 409 |
| `POST /teachers/applications` | `certifications[]`, `ijaza[]`, `experience[]?`, `intro_video` (object keys) | `application_id`, `status=processing` | 202 |
| `GET /teachers` | filters: `subject`, `price_band`, `rating_min`, `language`, `tz`, `day`\|`open`, `gender` | `teachers[]` (profile + `verified`, availability in viewer tz w/ original) | 200 |
| `POST /contracts` | `teacher_id` | `contract_id`, `status=requested` | 201 |
| `POST /contracts/{id}/plan` | `subject`, `total_months`, `sessions_per_week`, `session_length`, `total_price` | `revision_id`, `status=proposed` | 201 |
| `POST /contracts/{id}/approve` | — | `status=pending_payment`, `payment_intent` | 202 / 402 |
| `POST /contracts/{id}/cancel` | — | `refund` (current-month slice refunded if mid-month; full refund if ≥24 h pre-start) | 200 |
| `POST /contracts/{id}/messages` | `body` | `message_id`, `status=delivered`\|`flagged` | 201 |
| `GET /media/{object_key}/url` | — (authz: active contract / role) | `signed_url`, `expires_in` | 200 / 403 |
| `POST /webhooks/stripe` | Stripe event (signed) | `received` | 200 |

Non-obvious contracts: `approve` returns `202` — activation is asynchronous, confirmed by the Stripe webhook, not synchronously. `GET /media/.../url` never returns the object directly; it returns a short-lived signed URL only after an authorization check. `messages` may return `status=flagged` (held for admin) rather than an error.

## 5. Data Model

Postgres (Supabase). Money stored in **integer minor units** (cents); all timestamps **UTC `timestamptz`**; teacher availability also stores the teacher's IANA timezone for the "(originally …)" display. Student-profile rows protected by **RLS**: readable only by the owner and by a teacher joined through an `active` contract.

```mermaid
erDiagram
    USERS ||--o| TEACHER_PROFILES : has
    USERS ||--o| STUDENT_PROFILES : has
    TEACHER_PROFILES ||--o{ AVAILABILITY : sets
    TEACHER_PROFILES ||--o{ MATERIALS : uploads
    USERS ||--o{ CONTRACTS : "student in"
    TEACHER_PROFILES ||--o{ CONTRACTS : "teacher in"
    CONTRACTS ||--o{ CONTRACT_PLAN_REVISIONS : negotiates
    CONTRACTS ||--o{ SESSIONS : schedules
    SESSIONS ||--o| SESSION_TRANSCRIPTS : produces
    CONTRACTS ||--o{ PAYMENTS : bills
    CONTRACTS ||--o{ MESSAGES : contains
    PAYOUT_BATCHES ||--o{ SESSIONS : pays
    USERS ||--o{ VETTING_APPLICATIONS : submits
```

Key tables (selected columns):

- **`users`** — `id`, `email`, `role` (`student|teacher|admin`), `auth_provider`, `created_at`.
- **`teacher_profiles`** — `user_id`, `photo_key?`, `hourly_rate_cents`, `subjects[]`, `certifications[]`, `ijaza[]`, `experience[]?`, `intro_video_key`, `languages[]`, `pref_session_minutes` (≤120), `verification_status` (`verified|listed|rejected`), `delivered_hours_total` (int, default 0 — incremented when a session transitions to `delivered`; read at payout-batch open time to pick 25%/15% commission), `expected_reply_minutes`. Index: `(verification_status)`, GIN on `subjects`, `languages`.
- **`student_profiles`** — `user_id`, `photo_key?`, `name`, `prior_studies`. RLS-restricted.
- **`availability`** — `teacher_id`, `weekday`, `start_utc`, `end_utc`, `teacher_tz` (IANA), `open_availability` (bool).
- **`contracts`** — `id`, `student_id`, `teacher_id`, `subject`, `total_months`, `sessions_per_week`, `session_minutes`, `total_price_cents`, `status` (`requested|proposed|pending_payment|active|paused|cancelled|completed`), `start_at`, `contract_anniversary_dom`, `paused_at?`. Index: `(status)`, `(teacher_id)`, `(student_id)`.
- **`contract_plan_revisions`** — `contract_id`, `proposed_by`, terms snapshot, `created_at` (negotiation history).
- **`payments`** — `id`, `contract_id`, `student_id`, `kind` (`first_charge|slice`), `amount_cents` (**USD**), `currency` (`'USD'`, single value at MVP), `status` (`pending|cleared|failed|refunded`), `stripe_payment_intent_id` (unique — webhook idempotency), `stripe_invoice_id?`. *(No `retry_count` / `next_retry_at` — retry scheduling is owned by Stripe Smart Retries; we only record the terminal outcomes Stripe webhooks deliver.)*
- **`payout_batches`** — `id`, `teacher_id`, `period_start`, `period_end`, `gross_cents`, `commission_bps` (2500 or 1500 — the rate picked at batch open by reading `teacher_profiles.delivered_hours_total`), `commission_cents`, `net_cents`, `stripe_transfer_id`, `status`.
- **`sessions`** — `id`, `contract_id`, `scheduled_start_utc`, `scheduled_end_utc`, `status` (`scheduled|delivered|cancelled|rescheduled`), `delivered_at?`, `payout_batch_id?`.
- **`session_transcripts`** — `session_id` (PK, FK → sessions), `transcript` (jsonb — Deepgram payload with speaker turns + timestamps), `created_at`. Lifetime bound to the parent contract; when the contract becomes `completed`/`cancelled` the worker deletes the rows. RLS-gated to the contract participants.
- **`messages`** — `id`, `contract_id`, `sender_id`, `body`, `status` (`delivered|flagged`), `matched_rules[]?` (which regex patterns fired), `admin_label?` (`pii|clean|null` — set when an admin reviews a flag), `created_at`. The last two columns are the seed of the future-classifier training set ([Section 8](#8-future-considerations)).
- **`vetting_applications`** — `user_id`, `document_keys[]`, `composite_score?`, `status` (`processing|auto_verified|auto_listed|admin_queue|rejected`), `decided_at`. *(Scoring algorithm TBD.)*

No sharding/partitioning — single small Postgres instance is far within capacity at this scale.

## 6. Trade-offs & Alternatives

- **Modular monolith on one VM → vs microservices.** *Why:* 300 MAU and a small team; one deployable maximizes iteration speed and minimizes ops. *Gave up:* independent scaling and fault isolation per module, and the single VM is a SPOF — accepted because all durable state is external and recovery is a daily-image rebuild.
- **Postgres (Supabase-managed) → vs a NoSQL store or self-hosted Postgres.** *Why:* contracts and payments demand **ACID** — a half-charged contract or a lost payment row is unacceptable; relational transactions + constraints give that directly. Supabase additionally removes auth/OAuth/DB ops and RLS cleanly enforces student-profile privacy. *Gave up:* some control and a vendor dependency; mitigated since the data is standard, portable Postgres.
- **Media bytes in S3, key in Postgres → vs storing photos as Postgres BLOBs.** *Why:* even at ≤5 MB/photo, BLOBs bloat every backup and daily snapshot, tie up a scarce single-instance connection for the whole transfer (competing with contract/payment queries), and can't sit behind a CDN. Keys-in-DB keeps the same code path as PDFs. *Gave up:* a second system (S3) in the data path — acceptable, it's already required for PDFs and intro videos.
- **S3 Standard for hot media, Standard-IA only for the intro video → vs IA everywhere to cut storage cost.** *Why:* IA's per-GB retrieval fee makes frequently-viewed objects (profile photos) *more* expensive, not less. Class is matched to the actual access pattern. *Gave up:* marginally higher per-GB storage on Standard — negligible at this volume.
- **Stripe Billing + Connect → vs a custom billing/payout engine.** *Why:* per-contract recurring anniversaries, retry ladder, refunds, and marketplace split payouts (with a per-teacher rate that flips 25% → 15% at the 500-hour milestone) are exactly Stripe's domain; keeps PCI scope out. *Gave up:* fee per transaction and Stripe-shaped data modeling; acceptable versus building a correct money system from scratch.
- **Daily.co (video + AI transcription, no recording) → vs self-hosted SFU (or Agora).** *Why:* 1:1 video + screen share + built-in Deepgram-backed transcription with a transcript-ready webhook is commodity; self-hosting WebRTC and a transcription pipeline is disproportionate at ~100 h/mo, and Daily's room flags let us cleanly disable both native chat *and* video recording to keep moderation guarantees and avoid storing minors' video. *Gave up:* per-minute cost on video + transcription, and a soft provider lock-in — bounded because the only artifact we keep is the transcript text, stored in our own Postgres.
- **Regex/heuristic PII filter now → vs a managed moderation API (Hive) or self-hosted ML (Presidio / OSS NER).** *Why:* at validation scale the goal is enough friction that going off-platform costs more than staying on it, not a perfect PII firewall — regex delivers that at zero cost/latency and keeps message content on the VM (a paid API would also be a recurring per-message cost and would send every message to a third party, against the privacy posture). The regex flags double as a free labelled corpus. *Gave up:* recall on obfuscated/novel attempts — accepted, with policy + account penalties as the backstop and a documented upgrade path ([Section 8](#8-future-considerations)) to a traditional classifier (Hive/Presidio remain fallbacks if accuracy proves insufficient). *Explicitly not an LLM/SLM:* short-text contact-info detection is textbook linear/NER classification; an LLM is unjustified cost and latency here.
- **No queue/cache → vs Redis + a job queue.** *Why:* request volume and the scheduler's daily/biweekly cadence fit a single in-process scheduler against Postgres; one instance means no distributed-lock complexity. *Gave up:* horizontal worker scaling and sub-second fan-out — neither is needed yet; revisit if MAU grows an order of magnitude.

**Cost:** see **[Section 7](#7-pricing) Pricing** for the itemized monthly run-rate (~\$152/month at this scale, excluding Stripe pass-through).

## 7. Pricing

Itemized monthly cost at the stated validation scale. **Assumptions:** 100 video-hours/month = **6,000 session-minutes**; 1:1 sessions → 2 participants → **12,000 user-minutes**; every session is transcribed → **6,000 audio-minutes** sent through Daily's transcription.

| Component | Unit price | Monthly basis | Monthly cost |
|---|---|---|---|
| Daily.co — video | \$0.004 / user-min | 12,000 user-min | **\$48.00** |
| Daily.co — AI transcription | ~\$0.004 / audio-min | 6,000 audio-min | **~\$24.00** |
| Supabase — database | \$25 + \$10 compute | flat | **\$35.00** |
| AWS CloudFront | ~\$0.085 / GB egress + request fees (pay-as-you-go, no flat fee) | ~30 GB/mo³ | **~\$3.00** |
| AWS S3 (Standard) | \$0.023 / GB-mo | ~30 GB resident¹ | **~\$1.00** |
| Single VM | ~\$10–40 | flat (provider TBD) | **~\$20.00** |
| Resend — transactional email | \$20 / mo (paid plan, 50k emails) | flat | **\$20.00** |
| **Platform run-rate** | | | **≈ \$152 / month** |
| PII filtering | in-process regex | — | **\$0** |
| Stripe | 3.7% + \$0.30 / charge | per transaction | *pass-through²* |

¹ With video recording removed, S3 storage falls back to a rounding error: only profile photos, intro videos (1–2 min each), and uploaded PDFs are retained — ~30 GB total at this scale.

² Stripe fees are a variable pass-through on student charges, not a platform run cost — excluded from the run-rate total. PII filtering adds \$0 (in-process regex; no third-party provider).

³ CloudFront is **pay-as-you-go** (per-GB egress + per-10k requests, no fixed/committed fee); ~30 GB/mo covers profile-photo views, intro-video previews on the discovery page, and PDF reads. No recording-playback egress.

**Shape of the bill:** the two Daily.co lines (video \$48 + transcription ~\$24 = **~\$72**, ~47% of the total) are the only usage-variable cost; everything else is fixed (Supabase + VM + Resend = **\$75**) or rounding-error (S3 + CloudFront ≈ \$4). Cost scales almost entirely with delivered video minutes — if usage doubles, the Daily lines roughly double, the fixed tier holds, and S3/CloudFront stay negligible. No more "biggest cost lever" — removing recording already pulled the largest variable line out.

## 8. Future Considerations

Deliberately **not built now** — recorded here so the current design stays minimal but the path is known:

- **Traditional ML PII classifier (regex → learned model).** The regex filter runs in production as a weak-supervision *labelling function*: every decision is logged so a small classifier (logistic regression / linear SVM / small NER on char+word n-grams — **not** an LLM/SLM) can later be trained to beat regex on obfuscated/novel attempts. **Data to collect now so the dataset exists when it's needed:** (1) every flagged message with `matched_rules[]`; (2) `admin_label` whenever an admin reviews a flag (true/false-positive ground truth); (3) a **small random sample of *un*flagged delivered messages** for periodic human spot-labelling — without this the model only relearns the regex and can never measure or close false-negatives; (4) post-hoc signals already available — messages shortly followed by an off-platform-contact report or contract dispute — as additional positives. Train only once volume justifies it; deploy the model as a same-VM CPU sidecar (no GPU/hosted inference at this scale). Hive / self-hosted Presidio remain documented fallbacks if regex accuracy proves insufficient before then.
- **Local payment methods.** USD-only card billing will see a steady tail of cross-border declines (foreign-issuer banks blocking USD). Once decline-rate data justifies the integration cost, add region-appropriate local methods (e.g. bKash / JazzCash / UPI / SEPA) — much higher acceptance and lower fees in those corridors, at the cost of additional provider integrations and settlement complexity.
- **Scale-out triggers.** If MAU grows ~10×, revisit: a managed VM with autoscaling or container platform, a Redis-backed job queue for the scheduler, and read replicas — none justified at 300 MAU.

## 9. Pre-Implementation Checklist

A surface-area inventory used as a checkpoint before implementation begins. Each item is marked **✅ ready** (the design above is sufficient to start), **🟡 needs clarity** (open questions remaining within this design's scope), or **⏸ deferred** (intentionally out of scope per [Section 1](#1-overview) / [Section 8](#8-future-considerations)). This list is the working catalogue — update as items resolve.

### 9.1 User-facing features

| # | Feature | Status | Open questions / notes |
|---|---|---|---|
| 1 | Auth & accounts (student / teacher / admin roles) | ✅ ready | Supabase Auth + Google OAuth; role chosen at signup; admin internal. |
| 2 | Teacher discovery & search (browse, filter, profile view) | ✅ ready | Parameterized SQL; filter set fixed in [Section 2.1](#21-functional-requirements). |
| 3 | Teacher onboarding & vetting (application, admin review) | ⏸ deferred | Scoring **algorithm** TBD ([Section 1](#1-overview)); pipeline boundary + status machine designed. |
| 4 | Contract lifecycle (proposal → approval → active → paused/completed/cancelled) | 🟡 needs clarity | State machine designed; **teacher-initiated cancellation** path is a gap. |
| 5 | Scheduling & calendar (session slots, reminders) | ✅ ready | UTC + viewer-local display; 24 h reschedule rule; reminder cadence in [Section 2.1](#21-functional-requirements) / Notifications. |
| 6 | Video conferencing (Daily.co) | ✅ ready | Standard package; native chat disabled. |
| 7 | Session transcripts (Daily AI transcription) | ✅ ready | Free for all users; contract-lifetime retention; stored as text in Postgres; purge on terminal state. |
| 8 | In-platform messaging (with PII moderation) | ✅ ready | Strict regex on every message; flagged corpus stored for [Section 8](#8-future-considerations) ML. |
| 9 | Materials sharing (photos/PDFs in S3) | ✅ ready | Contract-gated signed URLs. |
| 10 | Reviews / ratings (post-contract) | 🟡 needs clarity | Referenced on profiles ([Section 2.1](#21-functional-requirements)) but **submission flow, schema, moderation, and edit/delete policy are not yet designed.** |
| 11 | Payments — student-side (contract slice billing) | 🟡 needs clarity | Slice billing locked (no sub fee); **upfront-vs-slices contract payment option still under discussion** (mandatory upfront for <1-month contracts, optional for longer). |
| 12 | Payouts — teacher-side (Stripe Connect, biweekly, tiered commission) | 🟡 needs clarity | Tiered commission (25% / 15% at 500 delivered hours) added; `delivered_hours_total` counter + rate selection at batch open are wireable. Edge cases unresolved: KYC gate before first payout, first-payout timing, negative-balance cycles (refunds > earnings), dispute holdback, tax-form scope, payout-currency/FX. |
| 13 | Refunds & disputes | 🟡 needs clarity | Mid-month student cancel covered ([Section 2.1](#21-functional-requirements)); **mid-month cancel with delivered-sessions accounting, Stripe chargebacks, teacher-initiated cancellation refund rules** still open. |
| 14 | Notifications (email/in-app) | ✅ ready | Resend for email ([Section 2.1](#21-functional-requirements), [Section 3](#3-architecture)); in-app notification surface (toast/inbox) not separately designed but low-risk. |
| 15 | Admin console (vetting, dispute review, PII flag review) | 🟡 needs clarity | Queues referenced throughout, but the **admin UI surface, permissions, and audit-log expectations are not designed.** |

### 9.2 Internal services / modules (modular monolith)

| # | Module | Status | Open questions / notes |
|---|---|---|---|
| 1 | Identity / Auth (Supabase) | ✅ ready | JWT verify → `users` row + role; RLS for student profiles. |
| 2 | Profiles & Discovery | ✅ ready | SQL + GIN indexes on `subjects`, `languages`. |
| 3 | Contracts | 🟡 needs clarity | State machine clear; **teacher-initiated cancellation transitions** missing. |
| 4 | Scheduling | ✅ ready | UTC storage + viewer-local display; reschedule rules in [Section 2.1](#21-functional-requirements). |
| 5 | Messaging (incl. regex PII filter) | ✅ ready | Filter rules + flagged corpus schema set; classifier deferred to [Section 8](#8-future-considerations). |
| 6 | Media (S3 + CloudFront, signed URLs) | ✅ ready | OAC + signed URLs; per-asset class chosen. |
| 7 | Video integration (Daily.co webhooks) | ✅ ready | Room flags (`enable_chat: false`, `enable_recording: false`, transcription on) + transcript-ready webhook handler. |
| 8 | Billing (Stripe Billing — per-contract Subscriptions, webhooks) | 🟡 needs clarity | Per-contract Subscription mapping clear (no platform sub fee); **upfront-pay-in-full Stripe primitive choice (Invoice vs PaymentIntent vs Subscription cancel-and-prorate) pending** alongside feature decision in row 11 above. |
| 9 | Payouts (Stripe Connect — Transfers, KYC, tiered commission) | 🟡 needs clarity | `delivered_hours_total` counter on `teacher_profiles` + rate selection (25% / 15%) at batch open are wireable. Same edge cases as user-facing row 12. |
| 10 | Notifications | ✅ ready | Resend API + Supabase Auth via Resend SMTP; React Email templates colocated with module. |
| 11 | Scheduler / Worker (cron: anniversaries, pauses, transcript purges, payouts, delivered-hours counter) | ✅ ready | In-process; jobs enumerated in [Section 3](#3-architecture). |
| 12 | Admin module | 🟡 needs clarity | Backend endpoints implied but **API surface + UI not specified** (see row 15 above). |

**Summary of what still needs design work before implementation can finish:** reviews/ratings (10), the upfront-vs-slices contract payment option (11 & 8), payout edge cases (12 & 9), refund/cancellation edge cases incl. teacher-initiated cancel (13, plus the contract row 4), and the admin console surface (15 & 12). Everything else is implementation-ready.

---

*Open items deferred by design: automated vetting scoring algorithm and VM provider. Now decided in this design: PII moderation (regex-first, ML-later — [Section 3](#3-architecture) / [Section 6](#6-trade-offs--alternatives) / [Section 8](#8-future-considerations)), no platform subscription fee — revenue is commission-only ([Section 2.1](#21-functional-requirements)), billing currency (USD — [Section 2.1](#21-functional-requirements)), **tiered commission (25 % at launch, 15 % after a teacher reaches 500 delivered hours — applied at the next payout)** ([Section 2.1](#21-functional-requirements)), **no cap on concurrent active contracts per student** ([Section 2.1](#21-functional-requirements)), session transcripts free for all users via Daily AI transcription — no cloud recording ([Section 2.1](#21-functional-requirements)).*
