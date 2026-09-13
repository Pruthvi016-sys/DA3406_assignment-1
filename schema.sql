-- ============================================================================
-- ScrollSense · Assignment 1 · Deliverable E.1 — schema.sql
-- Data Management | SQLite 3.44+
--
-- Timestamp convention (E.1): every temporal column is ISO-8601 UTC text,
--   'YYYY-MM-DDTHH:MM:SSZ', sorted correctly by plain TEXT comparison and
--   convertible with strftime()/julianday() for F3 (streaks), F9 (rolling
--   window), F10 (nesting depth timing). Never mixed with epoch integers.
--
-- Enum strategy (E.1): a closed set gets a CHECK(col IN (...)) when the
--   set is small and effectively frozen by the brief; it gets a lookup
--   table + FK when a named stakeholder is expected to extend it. Two
--   sets fall in the second bucket here: moderation state (Trust & Safety
--   will add states such as 'shadow_banned' or 'under_appeal' without a
--   schema migration) and monetisation tier (Finance/Growth add tiers as
--   the creator program evolves). Every other closed set (account status,
--   identity type, decider type, signal type, share destination, audio
--   source type) is small, brief-fixed, and unlikely to grow — CHECK(IN).
-- ============================================================================

PRAGMA foreign_keys = ON;   -- SQLite ignores every declared FK without this
PRAGMA journal_mode = WAL;  -- needed for G.3's concurrency demonstration

-- ----------------------------------------------------------------------------
-- Lookup tables (extensible enums)
-- ----------------------------------------------------------------------------

CREATE TABLE ModerationState (
    state_code   TEXT PRIMARY KEY,      -- 'pending' | 'live' | 'age_restricted' | 'demoted' | 'taken_down' (seed rows below; Trust & Safety may INSERT more)
    description  TEXT NOT NULL
);

CREATE TABLE Tier (
    tier_code    TEXT PRIMARY KEY,      -- e.g. 'none','bronze','silver','gold','partner' (Finance may INSERT more)
    description  TEXT NOT NULL
);

-- ----------------------------------------------------------------------------
-- Diagram 1 — Users & Social Graph
-- ----------------------------------------------------------------------------

CREATE TABLE AppUser (
    user_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    handle        VARCHAR(30) NOT NULL,
    display_name  VARCHAR(60) NOT NULL,
    created_at    TEXT NOT NULL,

    -- A7/A8 in E.2: "unique, case-insensitively, among active accounts" is
    -- two separate rules. COLLATE NOCASE gives us the first half
    -- declaratively. The second half (scoped to active accounts) cannot be
    -- expressed here at all: "active" is not a column on AppUser, it is a
    -- fact derived from the *current* row of AccountStatusPeriod (B.2's
    -- validity-interval design), and SQLite has no equivalent of a
    -- deferred cross-table CHECK or a materialised computed column to
    -- reference here. That half of the rule is enforced in application
    -- code / a BEFORE INSERT trigger that queries AccountStatusPeriod
    -- (see E.2 row A7b). NOCASE also only folds ASCII case — Tamil script
    -- has no case distinction at all, so case-folding is moot for a Tamil
    -- handle; the real risk for non-Latin scripts is Unicode
    -- *normalisation* (two different codepoint sequences rendering
    -- identically), which SQLite does not perform and which NOCASE does
    -- not touch either way.
    CHECK (handle = trim(handle) AND length(handle) > 0),
    UNIQUE (handle COLLATE NOCASE)
);

CREATE TABLE UserIdentity (
    user_id        INTEGER NOT NULL,
    identity_type  TEXT    NOT NULL CHECK (identity_type IN ('phone','google')),
    credential     VARCHAR(120) NOT NULL,
    linked_at      TEXT NOT NULL,
    PRIMARY KEY (user_id, identity_type),
    FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
    -- D.1 Relation 4 schema note: {credential} is a candidate key in its own
    -- right (a phone/Google account authenticates at most one ScrollSense
    -- account) but was missing from C.1 — added here as the D.1 payoff.
    UNIQUE (credential)
);

CREATE TABLE DeclaredInterest (
    user_id      INTEGER NOT NULL,
    category     VARCHAR(40) NOT NULL,
    declared_at  TEXT NOT NULL,
    PRIMARY KEY (user_id, category),
    FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE
);

CREATE TABLE InferredInterest (
    user_id       INTEGER NOT NULL,
    category      VARCHAR(40) NOT NULL,
    confidence    REAL NOT NULL CHECK (typeof(confidence) IN ('integer','real') AND confidence BETWEEN 0.0 AND 1.0),
    refreshed_at  TEXT NOT NULL,
    suppressed    INTEGER NOT NULL DEFAULT 0 CHECK (suppressed IN (0,1)),
    PRIMARY KEY (user_id, category),
    FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE
);

CREATE TABLE AccountStatusPeriod (
    user_id     INTEGER NOT NULL,
    valid_from  TEXT NOT NULL,
    status      TEXT NOT NULL CHECK (status IN ('active','deactivated','pending_deletion')),
    valid_to    TEXT,                       -- NULL = currently in force
    PRIMARY KEY (user_id, valid_from),
    FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE CreatorTierPeriod (
    user_id     INTEGER NOT NULL,
    valid_from  TEXT NOT NULL,
    tier_code   TEXT NOT NULL,
    valid_to    TEXT,                       -- NULL = currently in force
    PRIMARY KEY (user_id, valid_from),
    FOREIGN KEY (user_id)   REFERENCES AppUser(user_id) ON DELETE CASCADE,
    FOREIGN KEY (tier_code) REFERENCES Tier(tier_code)  ON DELETE RESTRICT,
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE Follow (
    follower_id  INTEGER NOT NULL,
    followee_id  INTEGER NOT NULL,
    started_at   TEXT NOT NULL,
    ended_at     TEXT,                      -- NULL = still following; non-NULL = ended (unfollow OR block, per A4)
    PRIMARY KEY (follower_id, followee_id, started_at),
    FOREIGN KEY (follower_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
    FOREIGN KEY (followee_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
    CHECK (follower_id <> followee_id),
    CHECK (ended_at IS NULL OR ended_at > started_at)
);

CREATE TABLE Block (
    blocker_id  INTEGER NOT NULL,
    blocked_id  INTEGER NOT NULL,
    blocked_at  TEXT NOT NULL,
    PRIMARY KEY (blocker_id, blocked_id),
    FOREIGN KEY (blocker_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
    FOREIGN KEY (blocked_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
    CHECK (blocker_id <> blocked_id)
);

CREATE TABLE Mute (
    muter_id  INTEGER NOT NULL,
    muted_id  INTEGER NOT NULL,
    muted_at  TEXT NOT NULL,
    PRIMARY KEY (muter_id, muted_id),
    FOREIGN KEY (muter_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
    FOREIGN KEY (muted_id) REFERENCES AppUser(user_id) ON DELETE CASCADE,
    CHECK (muter_id <> muted_id)
);

-- ----------------------------------------------------------------------------
-- Diagram 2 — Content & Watch Telemetry
-- ----------------------------------------------------------------------------

-- C.2's mutual-FK pair: Video.audio_track_id and AudioTrack.original_video_id
-- reference each other. SQLite accepts a forward FK reference at CREATE TABLE
-- time (the referenced table need not exist yet), so ordinary creation order
-- (Video, then AudioTrack) works — but a single INSERT transaction that
-- populates one video and one track that reference *each other* still needs
-- both FKs DEFERRABLE INITIALLY DEFERRED, since neither row can satisfy its
-- FK until the other exists. Declared on both sides per C.2.

CREATE TABLE Video (
    video_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_id        INTEGER NOT NULL,
    duration_ms     INTEGER NOT NULL CHECK (typeof(duration_ms)='integer' AND duration_ms BETWEEN 20000 AND 90000),
    caption         VARCHAR(2200) NOT NULL DEFAULT '',
    audio_track_id  INTEGER,                -- NULL = no audio track attached
    uploaded_at     TEXT NOT NULL,
    FOREIGN KEY (owner_id) REFERENCES AppUser(user_id)
        ON DELETE RESTRICT,                 -- content ownership must be reassigned/anonymised explicitly, never silently cascaded away
    FOREIGN KEY (audio_track_id) REFERENCES AudioTrack(track_id)
        ON DELETE SET NULL                  -- track removed -> video just loses its audio ref, clip itself survives
        DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE AudioTrack (
    track_id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source_type        TEXT NOT NULL CHECK (source_type IN ('original','licensed')),
    original_video_id  INTEGER UNIQUE,      -- NULL = licensed catalogue track, not original to any ScrollSense upload
    added_at           TEXT NOT NULL,
    FOREIGN KEY (original_video_id) REFERENCES Video(video_id)
        ON DELETE SET NULL                  -- source video removed -> track keeps circulating for the 50,000 other clips using it, just loses its "original of" link
        DEFERRABLE INITIALLY DEFERRED,
    CHECK ((source_type = 'original' AND original_video_id IS NOT NULL)
        OR (source_type = 'licensed' AND original_video_id IS NULL))
);

CREATE TABLE ModerationDecision (
    decision_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    video_id     INTEGER NOT NULL,
    state_code   TEXT NOT NULL,
    decided_at   TEXT NOT NULL,
    decider_type TEXT NOT NULL CHECK (decider_type IN ('classifier','human')),
    decider_id   INTEGER,                   -- NULL when decider_type='classifier' (no human reviewer to name); NOT NULL when 'human'
    FOREIGN KEY (video_id)    REFERENCES Video(video_id)             ON DELETE CASCADE,
    FOREIGN KEY (state_code)  REFERENCES ModerationState(state_code) ON DELETE RESTRICT,
    CHECK ((decider_type = 'human'      AND decider_id IS NOT NULL)
        OR (decider_type = 'classifier' AND decider_id IS NULL))
);

CREATE TABLE Impression (
    impression_id             INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id                   INTEGER NOT NULL,
    video_id                  INTEGER NOT NULL,
    occurred_at               TEXT NOT NULL,
    feed_position             INTEGER NOT NULL CHECK (typeof(feed_position)='integer' AND feed_position >= 0),
    model_version             VARCHAR(40) NOT NULL,
    source_recommendation_id  INTEGER,      -- NULL = organic/algorithmic feed entry, not sourced from an agent shelf (B.3 #3)
    FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE RESTRICT,   -- telemetry is a historical fact of record; user deletion is handled by anonymisation, never by silently deleting analytics rows
    FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE RESTRICT,  -- same reasoning: content removal must not corrupt the funnel's denominator
    FOREIGN KEY (source_recommendation_id) REFERENCES Recommendation(recommendation_id) ON DELETE SET NULL
);

CREATE TABLE ViewSegment (
    impression_id      INTEGER NOT NULL,
    segment_id         INTEGER NOT NULL,
    segment_start_ms   INTEGER NOT NULL CHECK (typeof(segment_start_ms)='integer' AND segment_start_ms >= 0),
    segment_end_ms     INTEGER NOT NULL,
    PRIMARY KEY (impression_id, segment_id),
    FOREIGN KEY (impression_id) REFERENCES Impression(impression_id) ON DELETE CASCADE,
    CHECK (typeof(segment_end_ms)='integer' AND segment_end_ms > segment_start_ms)
);

CREATE TABLE EngagementSignal (
    signal_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id       INTEGER NOT NULL,
    video_id      INTEGER NOT NULL,
    signal_type   TEXT NOT NULL CHECK (signal_type IN
                      ('like','save','share','follow_from_feed','not_interested','report','like_retraction')),
    occurred_at   TEXT NOT NULL,
    destination   TEXT CHECK (destination IS NULL OR destination IN ('whatsapp','instagram','copied_link')),
    FOREIGN KEY (user_id)  REFERENCES AppUser(user_id) ON DELETE RESTRICT,
    FOREIGN KEY (video_id) REFERENCES Video(video_id)  ON DELETE RESTRICT,
    -- B.3 #1's named cost, made honest and enforced: destination is NULL
    -- for every signal_type except 'share', and mandatory for 'share'.
    CHECK ((signal_type = 'share' AND destination IS NOT NULL)
        OR (signal_type <> 'share' AND destination IS NULL))
);

CREATE TABLE Comment (
    comment_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id        INTEGER,                 -- NULL = the posting account no longer exists (see FK below); never NULL at insert time
    video_id       INTEGER NOT NULL,
    body           VARCHAR(500) NOT NULL,
    commented_at   TEXT NOT NULL,
    FOREIGN KEY (user_id)  REFERENCES AppUser(user_id) ON DELETE SET NULL,  -- one of the brief's own named gaps ("what happens to their comments on other people's videos?"): the comment survives as an orphaned record, matching how most social platforms show "deleted user" rather than erasing the thread
    FOREIGN KEY (video_id) REFERENCES Video(video_id)  ON DELETE CASCADE    -- a comment cannot outlive the video it is attached to
);

-- ----------------------------------------------------------------------------
-- Diagram 3 — The Agent Layer
-- ----------------------------------------------------------------------------

CREATE TABLE Model (
    model_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    model_name  VARCHAR(60) NOT NULL UNIQUE
);

CREATE TABLE ModelPricePeriod (
    model_id        INTEGER NOT NULL,
    effective_from  TEXT NOT NULL,
    input_rate      REAL NOT NULL CHECK (typeof(input_rate) IN ('integer','real') AND input_rate >= 0),
    output_rate     REAL NOT NULL CHECK (typeof(output_rate) IN ('integer','real') AND output_rate >= 0),
    cached_rate     REAL NOT NULL CHECK (typeof(cached_rate) IN ('integer','real') AND cached_rate >= 0),
    effective_to    TEXT,                    -- NULL = currently in force
    PRIMARY KEY (model_id, effective_from),
    FOREIGN KEY (model_id) REFERENCES Model(model_id) ON DELETE CASCADE,
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);

CREATE TABLE PromptTemplate (
    template_id    INTEGER NOT NULL,
    version        INTEGER NOT NULL,
    template_text  TEXT NOT NULL,
    created_at     TEXT NOT NULL,
    PRIMARY KEY (template_id, version)
    -- No UPDATE path is ever exercised on this table (B.2): a template edit
    -- is a new (template_id, version+1) row, never a mutation of an
    -- existing one, which is what lets Turn's FK below stay pinned to the
    -- exact text used at the time.
);

CREATE TABLE AgentSession (
    session_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL,
    started_at  TEXT NOT NULL,
    ended_at    TEXT,                        -- NULL = session still open
    FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE RESTRICT   -- agent history feeds Finance's cost reporting; must survive independently of account lifecycle
);

CREATE TABLE Turn (
    session_id         INTEGER NOT NULL,
    sequence_no        INTEGER NOT NULL,
    user_message       TEXT NOT NULL,
    assistant_message  TEXT NOT NULL,
    template_id        INTEGER NOT NULL,
    template_version   INTEGER NOT NULL,
    model_id           INTEGER NOT NULL,
    temperature        REAL NOT NULL CHECK (typeof(temperature) IN ('integer','real') AND temperature >= 0),
    created_at         TEXT NOT NULL,
    PRIMARY KEY (session_id, sequence_no),
    FOREIGN KEY (session_id) REFERENCES AgentSession(session_id) ON DELETE CASCADE,
    FOREIGN KEY (template_id, template_version) REFERENCES PromptTemplate(template_id, version)
        ON DELETE RESTRICT,                  -- brief, verbatim: a historical response must never lose its link to the exact template text used
    FOREIGN KEY (model_id) REFERENCES Model(model_id) ON DELETE RESTRICT,
    CHECK (sequence_no >= 1)
);

-- D.1's payoff table: the BCNF split of the naive TurnUsage design.
-- Token counts live here, at Turn's own grain; price resolution against
-- ModelPricePeriod happens at query time in v_turn_cost (G.1), never
-- duplicated onto this row.
CREATE TABLE TurnUsage (
    session_id      INTEGER NOT NULL,
    sequence_no     INTEGER NOT NULL,
    input_tokens    INTEGER NOT NULL CHECK (typeof(input_tokens)='integer' AND input_tokens >= 0),
    output_tokens   INTEGER NOT NULL CHECK (typeof(output_tokens)='integer' AND output_tokens >= 0),
    cached_tokens   INTEGER NOT NULL DEFAULT 0 CHECK (typeof(cached_tokens)='integer' AND cached_tokens >= 0),
    PRIMARY KEY (session_id, sequence_no),
    FOREIGN KEY (session_id, sequence_no) REFERENCES Turn(session_id, sequence_no) ON DELETE CASCADE
);

CREATE TABLE ToolCall (
    tool_call_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id            INTEGER NOT NULL,
    sequence_no           INTEGER NOT NULL,
    parent_tool_call_id   INTEGER,           -- NULL = top-level call, not nested inside another (A9)
    tool_name             VARCHAR(60) NOT NULL,
    arguments_json        TEXT NOT NULL,
    result                TEXT,              -- NULL = call errored, no result was produced
    latency_ms            INTEGER NOT NULL CHECK (typeof(latency_ms)='integer' AND latency_ms >= 0),
    errored               INTEGER NOT NULL CHECK (errored IN (0,1)),
    called_at             TEXT NOT NULL,
    FOREIGN KEY (session_id, sequence_no) REFERENCES Turn(session_id, sequence_no) ON DELETE CASCADE,
    FOREIGN KEY (parent_tool_call_id) REFERENCES ToolCall(tool_call_id) ON DELETE CASCADE,
    CHECK (json_valid(arguments_json)),                 -- E.4: the one deliberate JSON column
    CHECK (NOT (errored = 1 AND result IS NOT NULL))    -- an errored call has no successful result
);

CREATE TABLE JudgeScore (
    judge_score_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id            INTEGER NOT NULL,
    sequence_no           INTEGER NOT NULL,
    judge_model_version   VARCHAR(40) NOT NULL,
    helpfulness           REAL NOT NULL CHECK (typeof(helpfulness) IN ('integer','real') AND helpfulness BETWEEN 0 AND 5),
    groundedness          REAL NOT NULL CHECK (typeof(groundedness) IN ('integer','real') AND groundedness BETWEEN 0 AND 5),
    safety                REAL NOT NULL CHECK (typeof(safety) IN ('integer','real') AND safety BETWEEN 0 AND 5),
    judged_at             TEXT NOT NULL,
    FOREIGN KEY (session_id, sequence_no) REFERENCES Turn(session_id, sequence_no) ON DELETE CASCADE
);

CREATE TABLE UserRating (
    rating_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id    INTEGER NOT NULL,
    sequence_no   INTEGER NOT NULL,
    thumbs        INTEGER NOT NULL CHECK (thumbs IN (-1, 1)),
    rated_at      TEXT NOT NULL,
    FOREIGN KEY (session_id, sequence_no) REFERENCES Turn(session_id, sequence_no) ON DELETE CASCADE
    -- A11: a rating can change after the fact; the *change* is kept (a new
    -- row), never overwritten, so "current" rating = latest row by rated_at.
);

CREATE TABLE Recommendation (
    recommendation_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id                INTEGER NOT NULL,
    sequence_no               INTEGER NOT NULL,
    position                  INTEGER NOT NULL CHECK (typeof(position)='integer' AND position >= 1),
    video_id                  INTEGER NOT NULL,
    FOREIGN KEY (session_id, sequence_no) REFERENCES Turn(session_id, sequence_no) ON DELETE CASCADE,
    FOREIGN KEY (video_id) REFERENCES Video(video_id) ON DELETE RESTRICT,
    UNIQUE (session_id, sequence_no, position)   -- the agent cannot show two different clips at the same shelf slot
);

-- ============================================================================
-- Indexes supporting the query workload in Deliverable F (not FKs, not PKs —
-- added for the high-fan-out lookups the funnel and cost reports depend on).
-- ============================================================================

CREATE INDEX ix_impression_video_time  ON Impression(video_id, occurred_at);
CREATE INDEX ix_impression_user_time   ON Impression(user_id, occurred_at);
CREATE INDEX ix_moderation_video_time  ON ModerationDecision(video_id, decided_at);
CREATE INDEX ix_engagement_video_type  ON EngagementSignal(video_id, signal_type, occurred_at);
CREATE INDEX ix_turn_created           ON Turn(created_at);
CREATE INDEX ix_toolcall_parent        ON ToolCall(parent_tool_call_id);

-- ============================================================================
-- Seed rows for the two extensible lookup tables.
-- ============================================================================

INSERT INTO ModerationState (state_code, description) VALUES
    ('pending',        'Awaiting a classifier or human decision'),
    ('live',           'Visible in the feed at normal rank'),
    ('age_restricted', 'Visible only to accounts confirmed 18+'),
    ('demoted',        'Surfaced less often, not removed'),
    ('taken_down',     'Removed from the feed entirely');

INSERT INTO Tier (tier_code, description) VALUES
    ('none',    'Not currently monetising'),
    ('bronze',  'Entry monetisation tier'),
    ('silver',  'Mid monetisation tier'),
    ('gold',    'Top monetisation tier'),
    ('partner', 'Invite-only partner program');

-- ============================================================================
-- Bonus B.2 — trigger preventing overlapping validity intervals.
--
-- The problem this closes: CreatorTierPeriod.valid_to is NULL for whichever
-- interval is currently open (D.1 / E.2 note), so a plain UNIQUE constraint
-- cannot enforce "at most one open interval per creator" — SQL treats every
-- NULL as distinct from every other NULL, so UNIQUE(user_id, valid_to) would
-- happily accept a second open row for the same user. SQLite also has no
-- declarative EXCLUDE constraint (PostgreSQL's answer to this exact
-- problem), so the check is hand-written as a pair of triggers.
--
-- What this version cannot guarantee that PostgreSQL's EXCLUDE can: this is
-- two separate statements (BEFORE INSERT, BEFORE UPDATE), not one constraint
-- evaluated atomically inside the storage engine, so a sufficiently unusual
-- write pattern (e.g. two overlapping intervals both inserted by a
-- multi-row statement in the same transaction before either trigger has
-- seen the other) is not caught the way a true range-exclusion index would
-- catch it. It is a per-row check, not a per-statement one.
-- ============================================================================

CREATE TRIGGER trg_creatortier_no_overlap_ins
BEFORE INSERT ON CreatorTierPeriod
FOR EACH ROW
WHEN EXISTS (
    SELECT 1 FROM CreatorTierPeriod
    WHERE user_id = NEW.user_id
      AND valid_from < COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z')
      AND COALESCE(valid_to, '9999-12-31T23:59:59Z') > NEW.valid_from
)
BEGIN
    SELECT RAISE(ABORT, 'CreatorTierPeriod: overlapping validity interval for this user_id');
END;

CREATE TRIGGER trg_creatortier_no_overlap_upd
BEFORE UPDATE ON CreatorTierPeriod
FOR EACH ROW
WHEN EXISTS (
    SELECT 1 FROM CreatorTierPeriod
    WHERE user_id = NEW.user_id
      AND rowid <> OLD.rowid
      AND valid_from < COALESCE(NEW.valid_to, '9999-12-31T23:59:59Z')
      AND COALESCE(valid_to, '9999-12-31T23:59:59Z') > NEW.valid_from
)
BEGIN
    SELECT RAISE(ABORT, 'CreatorTierPeriod: overlapping validity interval for this user_id');
END;

-- ============================================================================
-- Bonus B.1 — trigger-based audit log for moderation decisions.
-- Every INSERT into ModerationDecision is itself the audit event (B.2: the
-- table is already an append-only log), so the "audit log" this bonus asks
-- for is a second, independent trail proving no row was ever altered after
-- the fact — a classic tamper-evidence log, separate from the business data.
-- ============================================================================

CREATE TABLE ModerationDecisionAudit (
    audit_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    decision_id  INTEGER NOT NULL,
    video_id     INTEGER NOT NULL,
    state_code   TEXT NOT NULL,
    logged_at    TEXT NOT NULL,
    logged_event TEXT NOT NULL CHECK (logged_event IN ('INSERT','UPDATE','DELETE'))
);

CREATE TRIGGER trg_moderation_audit_ins
AFTER INSERT ON ModerationDecision
FOR EACH ROW
BEGIN
    INSERT INTO ModerationDecisionAudit (decision_id, video_id, state_code, logged_at, logged_event)
    VALUES (NEW.decision_id, NEW.video_id, NEW.state_code, strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'INSERT');
END;

-- ModerationDecision rows are never UPDATEd or DELETEd by the application
-- (B.2's whole point), but the audit trail should still notice if one ever
-- is — that is precisely the anomaly it exists to catch.
CREATE TRIGGER trg_moderation_audit_upd
AFTER UPDATE ON ModerationDecision
FOR EACH ROW
BEGIN
    INSERT INTO ModerationDecisionAudit (decision_id, video_id, state_code, logged_at, logged_event)
    VALUES (NEW.decision_id, NEW.video_id, NEW.state_code, strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'UPDATE');
END;

CREATE TRIGGER trg_moderation_audit_del
AFTER DELETE ON ModerationDecision
FOR EACH ROW
BEGIN
    INSERT INTO ModerationDecisionAudit (decision_id, video_id, state_code, logged_at, logged_event)
    VALUES (OLD.decision_id, OLD.video_id, OLD.state_code, strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'DELETE');
END;

-- ============================================================================
-- E.1 — STRICT-table demonstration (illustrative only; not used by the rest
-- of this schema, which stays non-STRICT so VARCHAR(n) can keep documenting
-- intended lengths — see the written report for the full argument).
--
-- A STRICT table accepts only INT, INTEGER, REAL, TEXT, BLOB, ANY as column
-- types. Two things break immediately when UserRating is rewritten STRICT:
--   1. Every VARCHAR(n)/NVARCHAR(n) declaration elsewhere in this schema
--      would be rejected outright — STRICT matches type names against an
--      exact short list, not by substring, so the max-length documentation
--      VARCHAR(n) gives a reader is lost; the workaround is TEXT plus an
--      explicit CHECK(length(col) <= n), which is more verbose for every
--      one of the ~15 VARCHAR columns in this schema.
--   2. STRICT still will NOT stop 'hello world' from being accepted into
--      an INTEGER column via a value that merely *looks* numeric-adjacent
--      in a CHECK's eyes (see the affinity_demo2 CHECK(n>0) finding above)
--      unless the CHECK itself also pins typeof() — STRICT fixes the
--      column's storage class, it does not retroactively fix a
--      loosely-written CHECK.
-- ============================================================================

CREATE TABLE UserRatingStrictDemo (
    rating_id     INTEGER PRIMARY KEY,
    session_id    INTEGER NOT NULL,
    sequence_no   INTEGER NOT NULL,
    thumbs        INTEGER NOT NULL,
    rated_at      TEXT NOT NULL
) STRICT;

-- ============================================================================
-- G.3 support — handle-change history and the twice-a-year cap (A1).
--
-- E.2 originally logged A1 ("a handle change consumes a slot on any write,
-- even a cosmetic one") as "not declarative — the twice-a-year cap needs a
-- rolling count over AppUser write history, which no single-row CHECK can
-- see". That is still true of a bare CHECK, but it understates what SQLite
-- *can* do with a small supporting table plus a trigger: HandleChangeLog
-- gives the rolling count somewhere to live, and a BEFORE UPDATE trigger can
-- then query it the same way a CHECK queries a single row. This does not
-- contradict E.2 — it upgrades A1 from "not declarative" to "declarative,
-- given one extra table", which is exactly the kind of thing E.2's own hint
-- ("go back and sharpen it") was pointing at. G.3 / T3 demonstrates it firing
-- on a third handle change within a rolling 365-day window.
-- ============================================================================

CREATE TABLE HandleChangeLog (
    log_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL,
    old_handle  VARCHAR(30) NOT NULL,
    new_handle  VARCHAR(30) NOT NULL,
    changed_at  TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES AppUser(user_id) ON DELETE CASCADE
);

-- Fires first (declared first; SQLite runs same-event triggers in creation
-- order) and rejects the write before it happens, so a rejected 3rd change
-- never reaches the AFTER trigger below and is never logged.
-- Uses the wall clock ('now'), deliberately, unlike Deliverable F's queries:
-- F's "no date('now')" rule is about analytic *reproducibility* of a report
-- run against a fixed dataset on an arbitrary future date. This trigger is
-- an *operational* rule enforced at write time against whenever the write
-- actually happens — the two are different problems, and G.3's demo issues
-- its three UPDATEs seconds apart, so all of them necessarily fall inside
-- the same rolling 365-day window regardless of which real date it is run on.
CREATE TRIGGER trg_appuser_handle_change_cap
BEFORE UPDATE OF handle ON AppUser
FOR EACH ROW
WHEN OLD.handle <> NEW.handle
 AND (
    SELECT COUNT(*) FROM HandleChangeLog
    WHERE user_id = OLD.user_id
      AND changed_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-365 days')
 ) >= 2
BEGIN
    SELECT RAISE(ABORT, 'AppUser: handle may change at most twice within any rolling 365-day window');
END;

CREATE TRIGGER trg_appuser_handle_change_log
AFTER UPDATE OF handle ON AppUser
FOR EACH ROW
WHEN OLD.handle <> NEW.handle
BEGIN
    INSERT INTO HandleChangeLog (user_id, old_handle, new_handle, changed_at)
    VALUES (NEW.user_id, OLD.handle, NEW.handle, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
