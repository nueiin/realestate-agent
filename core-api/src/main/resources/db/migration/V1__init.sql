-- ── jobs ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS jobs (
    id               UUID        PRIMARY KEY,
    question         TEXT        NOT NULL,
    status           TEXT        NOT NULL DEFAULT 'PLANNING',
    -- status: PLANNING | AWAIT_APPROVAL | RUNNING | DONE | FAILED | CANCELLED
    plan             JSONB,
    result           JSONB,
    error            TEXT,
    total_tokens     INT,
    total_cost_usd   NUMERIC(12, 6),
    steps            INT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── traces ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS traces (
    id          BIGSERIAL   PRIMARY KEY,
    job_id      UUID        NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    seq         INT         NOT NULL,
    type        TEXT        NOT NULL,
    -- type: PLAN | TOOL_CALL | TOOL_RESULT | SELF_CORRECT | FINAL
    tool_name   TEXT,
    input       JSONB,
    output      JSONB,
    duration_ms INT,
    cached      BOOL,
    tokens      INT,
    ts          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_traces_job_id ON traces(job_id);

-- ── api_cache ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS api_cache (
    lawd_cd     TEXT        NOT NULL,
    deal_ymd    TEXT        NOT NULL,  -- YYYYMM
    payload     JSONB       NOT NULL,
    fetched_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (lawd_cd, deal_ymd)
);

-- ── region_codes ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS region_codes (
    lawd_cd     TEXT PRIMARY KEY,      -- 법정동코드 앞 5자리 (시군구)
    sido        TEXT NOT NULL,
    sigungu     TEXT NOT NULL,
    full_name   TEXT NOT NULL
);

-- ── results ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS results (
    job_id      UUID PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE,
    report_md   TEXT,
    charts      JSONB
);
