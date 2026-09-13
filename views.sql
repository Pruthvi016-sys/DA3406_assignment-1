-- ============================================================================
-- ScrollSense · Assignment 1 · Deliverable G.1 — views.sql
-- Data Management | SQLite 3.44+
--
-- Five views, one per named consumer in Brief §2.6. Run after schema.sql
-- and generate_data.py have already loaded scrollsense.db.
--
-- Each view is written so its consumer never needs to know which B.2
-- temporal strategy backs the entity it reads: v_video_current_state hides
-- that moderation is an append-only log, v_creator_tier_current hides that
-- tier is a validity interval, v_turn_cost hides that pricing is resolved
-- against a historical interval rather than "the current price". Swap any
-- one of those storage strategies for another and only the view body
-- changes -- not a single query written against the view (this is tested
-- directly in the written report, per the task sheet's own hint).
-- ============================================================================

PRAGMA foreign_keys = ON;

-- ----------------------------------------------------------------------------
-- v_public_profile — mobile client
--
-- Exposes handle, display name, follower count. Must not expose phone or
-- email (both live only in UserIdentity.credential, a table this view never
-- touches -- so there is nothing to accidentally leak) and must not return
-- accounts that are deactivated or inside the deletion window.
--
-- Deliberately kept to a SINGLE table in the FROM clause (AppUser only),
-- with the account-status filter expressed as a correlated WHERE EXISTS
-- rather than a JOIN to AccountStatusPeriod, and follower_count as a
-- correlated scalar subquery rather than a JOIN + GROUP BY to Follow. This
-- is what keeps the view eligible for Postgres's "automatically updatable"
-- rule (G.2a): exactly one table in FROM, no aggregation/DISTINCT/GROUP BY/
-- window functions/set operations at the top level. A JOIN to
-- AccountStatusPeriod or Follow here would have been simpler SQL but would
-- have made the G.2(a) claim "Postgres would have allowed this one" false.
-- ----------------------------------------------------------------------------

CREATE VIEW v_public_profile AS
SELECT
    u.user_id,
    u.handle,
    u.display_name,
    (SELECT COUNT(*) FROM Follow f
       WHERE f.followee_id = u.user_id AND f.ended_at IS NULL) AS follower_count
FROM AppUser u
WHERE EXISTS (
    SELECT 1 FROM AccountStatusPeriod asp
    WHERE asp.user_id = u.user_id
      AND asp.valid_to IS NULL
      AND asp.status = 'active'
);

-- ----------------------------------------------------------------------------
-- v_video_current_state — Trust & Safety
--
-- The current moderation state of every video, in one lookup, derived from
-- the append-only ModerationDecision log (B.2/B.3 #2: current state is
-- never a second, independently-written column -- that dual write is
-- exactly the founders' §2.7 bug this design set out to kill).
--
-- Resolves "latest decision per video" with ROW_NUMBER() (same technique as
-- F2/F8/F10), then joins once to ModerationState for the human-readable
-- description. Window function + join -> not automatically updatable in
-- either engine (see G.1 table below); that trade is accepted deliberately,
-- since Trust & Safety only ever reads this view, never writes through it.
-- ----------------------------------------------------------------------------

CREATE VIEW v_video_current_state AS
WITH LatestDecision AS (
    SELECT
        video_id, state_code, decided_at, decider_type, decider_id,
        ROW_NUMBER() OVER (
            PARTITION BY video_id ORDER BY decided_at DESC, decision_id DESC
        ) AS rn
    FROM ModerationDecision
)
SELECT
    v.video_id,
    v.owner_id,
    ld.state_code                AS current_state,
    ms.description                AS current_state_description,
    ld.decided_at                 AS state_since,
    ld.decider_type,
    ld.decider_id
FROM Video v
JOIN LatestDecision ld ON ld.video_id = v.video_id AND ld.rn = 1
JOIN ModerationState ms ON ms.state_code = ld.state_code;

-- ----------------------------------------------------------------------------
-- v_creator_tier_current — Growth
--
-- Each creator's tier as of now, read off the B.2 validity-interval design
-- (CreatorTierPeriod) as the row where valid_to IS NULL -- the "currently
-- open" interval, guaranteed unique per creator by the no-overlap triggers
-- (trg_creatortier_no_overlap_ins/upd) already in schema.sql.
--
-- Kept to a single table (CreatorTierPeriod only, tier_code left as the raw
-- code rather than joined to Tier for a description) so this view, like
-- v_public_profile, stays automatically updatable in Postgres: a Growth
-- analyst tool could in principle UPDATE a creator's tier through this view
-- and have it land as an UPDATE on the one open CreatorTierPeriod row --
-- though G.3 does not exercise that path.
-- ----------------------------------------------------------------------------

CREATE VIEW v_creator_tier_current AS
SELECT
    ctp.user_id AS creator_id,
    ctp.tier_code,
    ctp.valid_from AS tier_since
FROM CreatorTierPeriod ctp
WHERE ctp.valid_to IS NULL;

-- ----------------------------------------------------------------------------
-- v_video_daily_engagement — Growth analysts
--
-- Per video per day: impressions, view-segments, watch seconds, and net
-- likes (likes minus retractions, per B.3 #1's unified EngagementSignal
-- design). Days with impressions but no engagement must appear with zeros
-- -- never be silently dropped by an inner join (the task sheet's own
-- named failure mode).
--
-- The day grid is built from Impression alone (every day that had at least
-- one impression), then LEFT JOINed to view/watch and like/retraction
-- aggregates so a day with impressions but zero views or zero signals still
-- produces a row, with COALESCE(...,0) rather than a NULL a Growth analyst
-- writing "bad SQL" (task sheet's own phrase, §2.6) might mis-sum.
-- Aggregation throughout -> not automatically updatable in either engine.
-- ----------------------------------------------------------------------------

CREATE VIEW v_video_daily_engagement AS
WITH Days AS (
    SELECT video_id, date(occurred_at) AS day, COUNT(*) AS impressions
    FROM Impression
    GROUP BY video_id, date(occurred_at)
),
Views AS (
    SELECT
        i.video_id, date(i.occurred_at) AS day,
        COUNT(DISTINCT vs.impression_id) AS view_segments,
        SUM(vs.segment_end_ms - vs.segment_start_ms) AS watch_ms
    FROM Impression i
    JOIN ViewSegment vs ON vs.impression_id = i.impression_id
    GROUP BY i.video_id, date(i.occurred_at)
),
Likes AS (
    SELECT
        video_id, date(occurred_at) AS day,
        SUM(CASE WHEN signal_type = 'like' THEN 1 ELSE 0 END)
      - SUM(CASE WHEN signal_type = 'like_retraction' THEN 1 ELSE 0 END) AS net_likes
    FROM EngagementSignal
    WHERE signal_type IN ('like', 'like_retraction')
    GROUP BY video_id, date(occurred_at)
)
SELECT
    d.video_id,
    d.day,
    d.impressions,
    COALESCE(vw.view_segments, 0) AS view_segments,
    COALESCE(vw.watch_ms, 0)      AS watch_ms,
    COALESCE(lk.net_likes, 0)     AS net_likes
FROM Days d
LEFT JOIN Views vw ON vw.video_id = d.video_id AND vw.day = d.day
LEFT JOIN Likes lk ON lk.video_id = d.video_id AND lk.day = d.day;

-- ----------------------------------------------------------------------------
-- v_turn_cost — Finance
--
-- Cost per turn, computed against the ModelPricePeriod validity interval
-- that was in force at the TURN's own created_at -- never the current
-- price (A10/E.2: "a price change must never alter last quarter's reported
-- costs"). This is a range join on an open interval, the same shape used
-- in F7, not an equality join on a timestamp.
--
-- Reads token counts from TurnUsage, the D.1 BCNF-decomposition payoff
-- table (D.1 Relation 1), rather than a wide TurnUsage-shaped column on
-- Turn itself. Join + arithmetic expression in the SELECT list -> not
-- automatically updatable in either engine.
-- ----------------------------------------------------------------------------

CREATE VIEW v_turn_cost AS
SELECT
    t.session_id,
    t.sequence_no,
    t.created_at,
    t.model_id,
    tu.input_tokens,
    tu.output_tokens,
    tu.cached_tokens,
    mp.input_rate,
    mp.output_rate,
    mp.cached_rate,
    ROUND(
        tu.input_tokens  * mp.input_rate
      + tu.output_tokens * mp.output_rate
      + tu.cached_tokens * mp.cached_rate
    , 6) AS turn_cost
FROM Turn t
JOIN TurnUsage tu
  ON tu.session_id = t.session_id AND tu.sequence_no = t.sequence_no
JOIN ModelPricePeriod mp
  ON mp.model_id = t.model_id
 AND mp.effective_from <= t.created_at
 AND (mp.effective_to IS NULL OR mp.effective_to > t.created_at);
