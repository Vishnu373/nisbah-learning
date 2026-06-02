# Nisbah Learning

Two-sided marketplace for paid 1:1 Islamic tutoring (Quran, Hadith, Arabic, Fiqh, Usul, Aqidah).

## Project structure

```
nisbah-learning/
├── backend/                        # Node.js + TypeScript modular monolith
│   ├── src/
│   │   ├── routes/                 # Express route handlers (no direct DB calls)
│   │   ├── services/               # daily.ts, s3.ts, scheduler.ts, etc.
│   │   ├── middleware/             # auth.ts — JWT verify + role check
│   │   └── db/                    # schema.sql + migrations/
│   ├── .env.example
│   └── package.json
├── frontend/                       # React 18 + TypeScript SPA (Vite)
│   ├── src/
│   │   ├── components/
│   │   │   ├── session/
│   │   │   ├── recording/
│   │   │   ├── marketplace/
│   │   │   └── shared/
│   │   ├── dashboards/
│   │   │   ├── teacher/
│   │   │   ├── student/
│   │   │   └── admin/
│   │   ├── hooks/                  # useSession, useRecording, etc.
│   │   └── utils/                  # tz.ts — timezone display
│   ├── e2e/                        # Playwright tests
│   ├── .env.example
│   └── package.json
├── design.md                       # Authoritative system design
├── implementation.md               # Phased build plan + progress log
└── CLAUDE.md                       # Project conventions
```

## Setup

### Prerequisites

- Node.js 20+
- npm 10+

**WSL / Linux / macOS**
```bash
node --version   # should be 20+
npm --version    # should be 10+
```

**Windows (PowerShell)**
```powershell
node --version
npm --version
```

---

### Backend

```bash
cd backend
cp .env.example .env   # fill in credentials before running
npm install
```

| Command | Description |
|---|---|
| `npm run dev` | Start dev server with hot reload (tsx watch) |
| `npm run build` | Production TypeScript compile |
| `npm test` | Jest unit + integration tests |
| `npm run lint` | ESLint + Prettier check |

### Frontend

```bash
cd frontend
cp .env.example .env
npm install
```

| Command | Description |
|---|---|
| `npm run dev` | Vite dev server on port 5173 |
| `npm run build` | TypeScript check + Vite production build |
| `npm test` | Vitest unit tests |
| `npm run e2e` | Playwright e2e (requires `npm run dev` running) |
| `npm run lint` | ESLint + Prettier check |

**First-time Playwright setup (WSL / Linux)**
```bash
npx playwright install --with-deps chromium
```

**Windows (PowerShell)**
```powershell
npx playwright install chromium
```

---

### Environment variables

Both packages ship an `.env.example` listing every required variable. Copy it to `.env` and fill in values before starting. Never commit `.env`.

Key variables:

| Variable | Used by |
|---|---|
| `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY` | Backend + Frontend |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` | Backend |
| `DAILY_API_KEY` | Backend |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` | Backend |
| `AWS_S3_BUCKET`, `AWS_CLOUDFRONT_DOMAIN`, `AWS_CLOUDFRONT_KEY_PAIR_ID`, `AWS_CLOUDFRONT_PRIVATE_KEY` | Backend |
| `RESEND_API_KEY` | Backend |
