CREATE TABLE IF NOT EXISTS feedback (
    submission_id TEXT PRIMARY KEY,
    received_at TEXT NOT NULL,
    feedback_type TEXT NOT NULL,
    message TEXT NOT NULL,
    app_short_version TEXT NOT NULL,
    build_version TEXT NOT NULL,
    macos_version TEXT,
    architecture TEXT,
    screen_id TEXT NOT NULL,
    region_json TEXT NOT NULL,
    anonymous_install_id_hash TEXT NOT NULL,
    contact TEXT,
    diagnostics_included INTEGER NOT NULL DEFAULT 0,
    screenshot_key TEXT,
    screenshot_content_type TEXT,
    payload_json TEXT NOT NULL,
    feishu_record_id TEXT,
    delivered_at TEXT
);

CREATE INDEX IF NOT EXISTS feedback_received_at_idx ON feedback(received_at DESC);
CREATE INDEX IF NOT EXISTS feedback_build_version_idx ON feedback(build_version, received_at DESC);

CREATE TABLE IF NOT EXISTS feedback_outbox (
    submission_id TEXT PRIMARY KEY REFERENCES feedback(submission_id) ON DELETE CASCADE,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TEXT NOT NULL,
    last_error TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS feedback_outbox_due_idx ON feedback_outbox(next_attempt_at);

CREATE TABLE IF NOT EXISTS rate_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rate_key TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS rate_events_lookup_idx ON rate_events(rate_key, created_at);
