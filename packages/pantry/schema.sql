PRAGMA encoding = "UTF-8";
PRAGMA integrity_check;

CREATE TABLE IF NOT EXISTS kinds (
  name TEXT PRIMARY KEY UNIQUE,
  tag INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS bl_values (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL REFERENCES kinds(name),
  marked INTEGER DEFAULT 0 CHECK (marked IN (0,1))
);

CREATE TABLE IF NOT EXISTS atoms (
  value_id INTEGER PRIMARY KEY REFERENCES bl_values(id),
  payload_id INTEGER NOT NULL REFERENCES atom_payloads(id)
);

CREATE TABLE IF NOT EXISTS atom_payloads (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  content BLOB UNIQUE
);

CREATE TABLE IF NOT EXISTS edges (
  parent INTEGER NOT NULL REFERENCES bl_values(id),
  pos INTEGER NOT NULL,
  child INTEGER NOT NULL REFERENCES bl_values(id),
  PRIMARY KEY (parent, pos),
  CHECK (parent > child)
) without ROWID;
