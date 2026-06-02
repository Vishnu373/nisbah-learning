import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

import { Client } from 'pg';

const MIGRATIONS_DIR = join(__dirname, 'migrations');

// Applies any *.sql files in ./migrations not yet recorded in schema_migrations,
// in filename order, each in its own transaction. Returns the versions applied.
export const runMigrations = async (connectionString: string): Promise<string[]> => {
  const client = new Client({ connectionString });
  await client.connect();
  const applied: string[] = [];

  try {
    await client.query(
      `create table if not exists schema_migrations (
        version text primary key,
        applied_at timestamptz not null default now()
      )`,
    );

    const files = readdirSync(MIGRATIONS_DIR)
      .filter((f) => f.endsWith('.sql'))
      .sort();

    for (const file of files) {
      const { rows } = await client.query('select 1 from schema_migrations where version = $1', [
        file,
      ]);
      if (rows.length > 0) continue;

      const sql = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
      await client.query('begin');
      try {
        await client.query(sql);
        await client.query('insert into schema_migrations (version) values ($1)', [file]);
        await client.query('commit');
        applied.push(file);
      } catch (err) {
        await client.query('rollback');
        throw err;
      }
    }
  } finally {
    await client.end();
  }

  return applied;
};

if (require.main === module) {
  const connectionString = process.env['DATABASE_URL'];
  if (!connectionString) {
    console.error('DATABASE_URL is not set');
    process.exit(1);
  }

  runMigrations(connectionString)
    .then((applied) => {
      console.log(
        applied.length ? `Applied migrations: ${applied.join(', ')}` : 'No pending migrations',
      );
    })
    .catch((err) => {
      console.error(err);
      process.exit(1);
    });
}
