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
