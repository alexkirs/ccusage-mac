-- npx wrangler d1 execute ccusage --remote --file=schema.sql
CREATE TABLE IF NOT EXISTS state (k TEXT PRIMARY KEY, body TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS hist (t INTEGER PRIMARY KEY, v TEXT NOT NULL);
