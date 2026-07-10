PRAGMA encoding = "UTF-8";

PRAGMA integrity_check;

CREATE TABLE
  IF NOT EXISTS all_values (
    id BLOB PRIMARY KEY,
    kind TEXT NOT NULL,
    marked INTEGER DEFAULT 0 CHECK (marked IN (0, 1)),
    payload_id BLOB REFERENCES payloads (id),
    CHECK (
      (
        kind IN ('nil', 'list', 'record', 'set', 'dict')
        AND payload_id is NULL
      )
      OR (
        kind IN ('int', 'string', 'symbol', 'bytes')
        AND payload_id is NOT NULL
      )
    )
  );

CREATE TABLE
  IF NOT EXISTS payloads (id BLOB PRIMARY KEY, content BLOB UNIQUE);

CREATE TABLE
  IF NOT EXISTS list_edges (
    parent_id BLOB NOT NULL REFERENCES all_values (id),
    value_id BLOB NOT NULL REFERENCES all_values (id),
    pos INTEGER NOT NULL,
    PRIMARY KEY (parent_id, pos, value_id)
  );

CREATE TABLE
  IF NOT EXISTS record_edges (
    parent_id BLOB NOT NULL REFERENCES all_values (id),
    value_id BLOB NOT NULL REFERENCES all_values (id),
    pos INTEGER NOT NULL,
    PRIMARY KEY (parent_id, pos, value_id)
  );

CREATE TABLE
  IF NOT EXISTS dict_edges (
    parent_id BLOB NOT NULL REFERENCES all_values (id),
    key_id BLOB NOT NULL REFERENCES all_values (id),
    value_id BLOB NOT NULL REFERENCES all_values (id),
    PRIMARY KEY (parent_id, key_id, value_id)
  );

CREATE TABLE
  IF NOT EXISTS set_edges (
    parent_id BLOB NOT NULL REFERENCES all_values (id),
    value_id BLOB NOT NULL REFERENCES all_values (id),
    PRIMARY KEY (parent_id, value_id)
  );

CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_atoms on all_values (kind, marked, payload_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_shared_payloads on all_values (payload_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_list_inclusion on list_edges (parent_id, value_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_record_inclusion on record_edges (parent_id, value_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_dict_key_inclusion on dict_edges (parent_id, key_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_dict_value_inclusion on dict_edges (parent_id, value_id);