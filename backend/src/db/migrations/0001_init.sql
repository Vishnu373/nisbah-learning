-- init — initial schema for Nisbah Learning (design.md §5)
-- Money in integer USD cents; all timestamps UTC timestamptz.
-- RLS: ENABLE ROW LEVEL SECURITY is applied automatically by the Supabase
-- project setting ("Enable automatic RLS"); only the policies are scripted here.
-- Note: users.id references auth.users(id) so that auth.uid() in RLS policies
-- matches our users rows (Supabase-specific; required for the policies below).

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- ── Enums ────────────────────────────────────────────────────────────────────
create type role as enum ('student', 'teacher', 'admin');
create type contract_status as enum (
  'INITIATED', 'PROPOSED', 'REVISION', 'ACCEPTED', 'ACTIVE',
  'PAUSED', 'DECLINED', 'CANCELLED', 'COMPLETED'
);
create type payment_option as enum ('FULL', 'INSTALLMENTS');
create type payment_status as enum ('PENDING', 'DONE', 'FAILED', 'REFUNDED');
create type payout_status as enum ('PENDING', 'PROCESSING', 'PAID', 'FAILED');
create type payout_type as enum ('scheduled', 'instant');
create type session_status as enum ('SCHEDULED', 'DELIVERED', 'CANCELLED', 'RESCHEDULED');
create type recording_status as enum ('PROCESSING', 'READY', 'FAILED');
create type message_status as enum ('DELIVERED', 'FLAGGED');
create type filter_layer as enum ('none', 'regex', 'comprehend');
create type request_status as enum ('OPEN', 'FULFILLED', 'CANCELLED', 'EXPIRED');
create type notification_status as enum ('PENDING', 'CANCELLED');

-- ── users ──────────────────────────────────────────────────────────────────--
create table users (
  id            uuid primary key references auth.users (id) on delete cascade,
  email         text not null unique,
  role          role not null,
  auth_provider text not null check (auth_provider in ('email', 'google')),
  created_at    timestamptz not null default now()
);

-- ── teacher_profiles ─────────────────────────────────────────────────────────
create table teacher_profiles (
  user_id                uuid primary key references users (id) on delete cascade,
  photo_key              text,
  hourly_rate_cents      int not null,
  subjects               text[] not null,
  certifications         text[],
  ijaza                  text[],
  experience             text[],
  intro_video_key        text not null,
  languages              text[] not null,
  expected_reply_minutes int not null,
  delivered_hours        int not null default 0,
  education              text,
  location               text not null
);

-- ── student_profiles (RLS: owner + teacher in active contract) ───────────────
create table student_profiles (
  user_id        uuid primary key references users (id) on delete cascade,
  photo_key      text,
  name           text not null,
  prior_subjects text[],
  education      text,
  location       text not null
);

-- ── availability ─────────────────────────────────────────────────────────────
create table availability (
  teacher_id         uuid not null references users (id) on delete cascade,
  weekday            int not null check (weekday between 0 and 6),
  start_utc          time not null,
  end_utc            time not null,
  teacher_tz         text not null,
  open_availability  bool not null default false,
  primary key (teacher_id, weekday, start_utc)
);

-- ── learning_requests (referenced by contracts.broadcast_request_id) ─────────
create table learning_requests (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references users (id),
  subject    text not null,
  note       text,
  status     request_status not null default 'OPEN',
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

-- ── contracts ────────────────────────────────────────────────────────────────
-- Plan fields (total_sessions, sessions_per_week, total_amount_cents,
-- payment_options, start_at) are null at INITIATED and set at PROPOSED.
-- The 4–100 total_sessions bound is enforced at the API layer (design §5).
create table contracts (
  id                  uuid primary key default gen_random_uuid(),
  student_id          uuid not null references users (id),
  teacher_id          uuid not null references users (id),
  subject             text not null,
  total_sessions      int,
  sessions_per_week   int,
  total_amount_cents  int,
  payment_options     payment_option,
  status              contract_status not null default 'INITIATED',
  start_at            timestamptz,
  paused_at           timestamptz,
  recording_enabled   bool not null default false,
  broadcast_request_id uuid references learning_requests (id)
);

-- ── contract_plan_revisions (negotiation history) ───────────────────────────
create table contract_plan_revisions (
  id          uuid primary key default gen_random_uuid(),
  contract_id uuid not null references contracts (id) on delete cascade,
  proposed_by uuid not null references users (id),
  terms       jsonb not null,
  created_at  timestamptz not null default now()
);

-- ── payments ─────────────────────────────────────────────────────────────────
create table payments (
  id                       uuid primary key default gen_random_uuid(),
  contract_id              uuid not null references contracts (id),
  slice_amount_cents       int not null,
  payment_status           payment_status not null default 'PENDING',
  stripe_payment_intent_id text unique,
  stripe_invoice_id        text
);

-- ── payout_batches (monthly, paid on the 28th) ──────────────────────────────
-- commission_bps stored on the row (3000 at launch); never hardcoded at call-sites.
create table payout_batches (
  id                 uuid primary key default gen_random_uuid(),
  teacher_id         uuid not null references users (id),
  period_start       date not null,
  period_end         date not null,
  gross_cents        int not null default 0,
  commission_bps     int not null default 3000,
  commission_cents   int not null default 0,
  payout_type        payout_type not null default 'scheduled',
  instant_fee_cents  int not null default 0,
  net_profit_cents   int not null default 0,
  stripe_transfer_id text,
  status             payout_status not null default 'PENDING'
);

-- ── sessions ─────────────────────────────────────────────────────────────────
create table sessions (
  id                  uuid primary key default gen_random_uuid(),
  contract_id         uuid not null references contracts (id),
  teacher_id          uuid not null references users (id),
  scheduled_start_utc timestamptz not null,
  scheduled_end_utc   timestamptz not null,
  status              session_status not null default 'SCHEDULED',
  delivered_at        timestamptz,
  payout_batch_id     uuid references payout_batches (id),
  -- no two SCHEDULED sessions for the same teacher may overlap
  constraint sessions_no_overlap exclude using gist (
    teacher_id with =,
    tstzrange(scheduled_start_utc, scheduled_end_utc) with &&
  ) where (status = 'SCHEDULED')
);

-- ── session_recordings (RLS: participants; media in S3) ──────────────────────
create table session_recordings (
  session_id   uuid primary key references sessions (id) on delete cascade,
  s3_key       text not null,
  duration_sec int,
  size_bytes   bigint,
  status       recording_status not null default 'PROCESSING',
  created_at   timestamptz not null default now()
);

-- ── messages (all rows retained as ML corpus) ───────────────────────────────
create table messages (
  id                  uuid primary key default gen_random_uuid(),
  contract_id         uuid not null references contracts (id),
  sender_id           uuid not null references users (id),
  body                text not null,
  status              message_status not null default 'DELIVERED',
  matched_rules       text[],
  comprehend_entities text[],
  filter_layer        filter_layer not null default 'none',
  created_at          timestamptz not null default now()
);

-- ── teacher_reviews (public; one per completed contract) ─────────────────────
create table teacher_reviews (
  id          uuid primary key default gen_random_uuid(),
  contract_id uuid not null unique references contracts (id),
  student_id  uuid not null references users (id),
  teacher_id  uuid not null references users (id),
  rating      int not null check (rating between 1 and 5),
  body        text,
  created_at  timestamptz not null default now()
);

-- ── student_recommendations (private; one per completed contract) ────────────
create table student_recommendations (
  id          uuid primary key default gen_random_uuid(),
  contract_id uuid not null unique references contracts (id),
  teacher_id  uuid not null references users (id),
  student_id  uuid not null references users (id),
  body        text not null,
  created_at  timestamptz not null default now()
);

-- ── learning_request_notifications (fan-out per matched teacher) ─────────────
create table learning_request_notifications (
  id         uuid primary key default gen_random_uuid(),
  request_id uuid not null references learning_requests (id) on delete cascade,
  teacher_id uuid not null references users (id),
  status     notification_status not null default 'PENDING',
  created_at timestamptz not null default now()
);

-- ── Indexes ──────────────────────────────────────────────────────────────────
create index idx_teacher_profiles_subjects  on teacher_profiles using gin (subjects);
create index idx_teacher_profiles_languages on teacher_profiles using gin (languages);

create index idx_contracts_status     on contracts (status);
create index idx_contracts_teacher_id on contracts (teacher_id);
create index idx_contracts_student_id on contracts (student_id);

create index idx_contract_plan_revisions_contract_id on contract_plan_revisions (contract_id);
create index idx_payments_contract_id on payments (contract_id);
create index idx_sessions_contract_id on sessions (contract_id);
create index idx_payout_batches_teacher_id on payout_batches (teacher_id);

create index idx_teacher_reviews_teacher_id        on teacher_reviews (teacher_id);
create index idx_student_recommendations_student_id on student_recommendations (student_id);
create index idx_learning_requests_student_id      on learning_requests (student_id);
create index idx_lrn_request_id on learning_request_notifications (request_id);
create index idx_lrn_teacher_id on learning_request_notifications (teacher_id);

-- ── RLS policies ─────────────────────────────────────────────────────────────
-- All access goes through the backend (service role, bypasses RLS); the frontend
-- never queries the DB directly. RLS is defense-in-depth. Tables without a policy
-- below are intentionally backend-only (no direct client access). SELECT-only here
-- since clients never write directly. auth.uid() = users.id (see users.id FK).

-- student_profiles: readable by the owner, by a teacher in an ACTIVE contract,
-- or temporarily by a teacher with a PENDING notification for an OPEN request
-- from that student (reverts to default on terminal request state).
create policy student_profiles_select on student_profiles
  for select using (
    auth.uid() = user_id
    or exists (
      select 1 from contracts c
      where c.student_id = student_profiles.user_id
        and c.teacher_id = auth.uid()
        and c.status = 'ACTIVE'
    )
    or exists (
      select 1
      from learning_request_notifications n
      join learning_requests r on r.id = n.request_id
      where r.student_id = student_profiles.user_id
        and n.teacher_id = auth.uid()
        and n.status = 'PENDING'
        and r.status = 'OPEN'
    )
  );

-- session_recordings: readable by the contract participants (student or teacher).
create policy session_recordings_select on session_recordings
  for select using (
    exists (
      select 1
      from sessions s
      join contracts c on c.id = s.contract_id
      where s.id = session_recordings.session_id
        and (c.student_id = auth.uid() or c.teacher_id = auth.uid())
    )
  );

-- student_recommendations: readable by teachers with a contract with the student
-- in INITIATED | PROPOSED | REVISION | ACCEPTED | ACTIVE state.
create policy student_recommendations_select on student_recommendations
  for select using (
    exists (
      select 1 from contracts c
      where c.student_id = student_recommendations.student_id
        and c.teacher_id = auth.uid()
        and c.status in ('INITIATED', 'PROPOSED', 'REVISION', 'ACCEPTED', 'ACTIVE')
    )
  );

-- learning_request_notifications: teachers see only their own rows.
create policy learning_request_notifications_select on learning_request_notifications
  for select using (auth.uid() = teacher_id);
