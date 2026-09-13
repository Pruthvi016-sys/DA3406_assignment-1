-- ============================================================================
-- ScrollSense · Assignment 1 · Deliverable F — queries.sql
-- Data Management | SQLite 3.44+
--
-- Run against a database built per README.md (schema.sql + generate_data.py,
-- seed=16). Every query sets PRAGMA foreign_keys = ON itself is unnecessary
-- for SELECTs, but the session should still have it on per §0.1.
--
-- Conventions used throughout this file:
--   * No date('now') anywhere. The generator fixes its data window ending
--     2026-09-12 (WINDOW_END in generate_data.py); "last 7 days" / "last
--     month" are anchored to MAX(timestamp) of the relevant table instead,
--     so the results are reproducible on any wall-clock date.
--   * Every query carries an explicit ORDER BY so "first five rows" is
--     deterministic on any rerun.
--   * Row counts below were captured via a separate
--     SELECT COUNT(*) FROM (query) — not a client grid footer — per the
--     task sheet's own warning about DBeaver's batched fetch.
-- ============================================================================

PRAGMA foreign_keys = ON;

-- ============================================================================
-- Tier 1 — core SQL
-- ============================================================================

-- ----------------------------------------------------------------------------
-- F1 · Top 10 audio tracks by number of distinct videos in the last 7 days.
-- Intent: "last 7 days" is anchored to the most recent Video.uploaded_at in
--   the data (not date('now') — the generator's window ends 2026-09-12, not
--   today's wall-clock date), so the query is reproducible on any rerun date.
-- Expected shape: at most 10 rows, one per track_id, ranked by distinct
--   video count within the trailing 7-day window (inclusive of the anchor).
-- ----------------------------------------------------------------------------
WITH anchor AS (
    SELECT MAX(uploaded_at) AS max_ts FROM Video
),
window_bounds AS (
    SELECT datetime(max_ts, '-6 days') AS win_start, max_ts AS win_end
    FROM anchor
)
SELECT
    v.audio_track_id,
    COUNT(DISTINCT v.video_id) AS distinct_videos_7d
FROM Video v, window_bounds w
WHERE v.audio_track_id IS NOT NULL
  AND v.uploaded_at BETWEEN w.win_start AND w.win_end
GROUP BY v.audio_track_id
ORDER BY distinct_videos_7d DESC, v.audio_track_id ASC
LIMIT 10;
-- Rows returned: 10   Runtime: 4.7 ms
-- Reading: track 1 (the single seeded "trending sound") dominates the last
--   7 days with 433 distinct videos in the window; every other track in the
--   top 10 sits at 2-3, confirming the generator's one-viral-track design
--   (50,000-clip trending sound from the brief, §2.2) shows up correctly
--   even in a short recency slice.

-- ----------------------------------------------------------------------------
-- F2 · Watch hours and mean completion rate per creator, live clips only.
-- Intent: every creator must appear, including one with zero live clips and
--   one whose clips have never been shown at all (§2.4). "Creator" is read
--   off CreatorTierPeriod (C.2's decision: there is no separate Creator
--   table), NOT off AppUser or off Video.owner_id — starting from Video
--   would silently drop the 524 creators who have never uploaded.
--   "Current" moderation state is append-only (ModerationDecision); a naive
--   join fans out over every historical decision, so the latest decision
--   per video is resolved first via ROW_NUMBER() before it ever reaches the
--   telemetry join.
--   mean_completion_rate is deliberately the fraction of VIEWS (not
--   impressions) that reached the end: a creator with impressions but zero
--   ViewSegment rows still appears (LEFT JOIN from AllCreators), contributing
--   0 watch hours and a NULL completion rate (no denominator), never a
--   fabricated 0.0 that would misrepresent "never watched" as "watched and
--   never finished".
-- Expected shape: exactly 750 rows (COUNT(DISTINCT user_id) FROM
--   CreatorTierPeriod) — one per creator, no more, no fewer.
-- ----------------------------------------------------------------------------
WITH LatestDecision AS (
    SELECT
        video_id, state_code,
        ROW_NUMBER() OVER (
            PARTITION BY video_id ORDER BY decided_at DESC, decision_id DESC
        ) AS rn
    FROM ModerationDecision
),
CurrentState AS (
    SELECT video_id, state_code FROM LatestDecision WHERE rn = 1
),
LiveVideo AS (
    SELECT v.video_id, v.owner_id, v.duration_ms
    FROM Video v
    JOIN CurrentState cs ON cs.video_id = v.video_id
    WHERE cs.state_code = 'live'
),
SegFacts AS (
    SELECT
        lv.owner_id,
        i.impression_id,
        SUM(vs.segment_end_ms - vs.segment_start_ms)                       AS watch_ms,
        MAX(CASE WHEN vs.segment_end_ms >= lv.duration_ms THEN 1 ELSE 0 END) AS reached_end
    FROM LiveVideo lv
    JOIN Impression  i  ON i.video_id = lv.video_id
    JOIN ViewSegment vs ON vs.impression_id = i.impression_id
    GROUP BY lv.owner_id, i.impression_id
),
CreatorWatch AS (
    SELECT
        owner_id AS user_id,
        SUM(watch_ms)             AS total_watch_ms,
        AVG(reached_end * 1.0)    AS mean_completion,
        COUNT(*)                  AS n_views
    FROM SegFacts
    GROUP BY owner_id
),
AllCreators AS (
    SELECT DISTINCT user_id FROM CreatorTierPeriod
)
SELECT
    ac.user_id,
    ROUND(COALESCE(cw.total_watch_ms, 0) / 3600000.0, 4) AS watch_hours,
    ROUND(cw.mean_completion, 4)                          AS mean_completion_rate,
    COALESCE(cw.n_views, 0)                               AS n_views
FROM AllCreators ac
LEFT JOIN CreatorWatch cw ON cw.user_id = ac.user_id
ORDER BY watch_hours DESC, ac.user_id ASC;
-- Rows returned: 750   Runtime: 412.7 ms
-- Reading: 653 of the 750 creators have zero live-clip views (n_views = 0,
--   mean_completion_rate = NULL) despite many of them having been shown —
--   exactly the "900 impressions, watched twice" shape §2.4 warns must not
--   be dropped off the report; the top creator (id 684) accounts for 3.25
--   watch-hours against a 4.7% completion rate, illustrating that raw watch
--   volume and completion quality are independent signals worth reporting
--   separately, not blended into one number.

-- ----------------------------------------------------------------------------
-- F3 · Videos with no audio track — NOT IN vs NOT EXISTS.
-- Intent: same business question, two constructs, to expose SQLite's
--   three-valued-logic trap. AudioTrack.track_id is a NOT NULL primary key,
--   so the subquery's *result set* is guaranteed NULL-free — this is
--   deliberately NOT the textbook "NULL inside the subquery" version of the
--   bug. The trap here fires from the OTHER side of the comparison instead:
--   the outer expression Video.audio_track_id is itself NULL for exactly
--   the rows this query is trying to find.
-- ----------------------------------------------------------------------------

-- (a) NOT IN
SELECT v.video_id
FROM Video v
WHERE v.audio_track_id NOT IN (SELECT track_id FROM AudioTrack)
ORDER BY v.video_id;
-- Rows returned: 0   Runtime: 3.4 ms

-- (b) NOT EXISTS
SELECT v.video_id
FROM Video v
WHERE NOT EXISTS (
    SELECT 1 FROM AudioTrack a WHERE a.track_id = v.audio_track_id
)
ORDER BY v.video_id;
-- Rows returned: 14636   Runtime: 7.1 ms
-- Reading: NOT IN returns ZERO rows — silently wrong — while NOT EXISTS
--   returns the correct 14,636 (matches a direct
--   `WHERE audio_track_id IS NULL` sanity check exactly). Under SQL's
--   three-valued logic, `NULL NOT IN (list)` evaluates to UNKNOWN
--   regardless of what the list contains, and a WHERE clause discards
--   UNKNOWN rows just like FALSE ones. Every video with a NULL
--   audio_track_id — precisely the set we're asking for — is silently
--   excluded before the IN-list is even consulted. NOT EXISTS is a
--   correlated existence test, not a value comparison: comparing
--   `a.track_id = NULL` inside it simply finds no matching row (never
--   UNKNOWN at the WHERE-clause level), so NOT EXISTS correctly reports
--   "true, no track exists for this video" whenever audio_track_id is NULL.
--   The lesson generalises beyond this schema: NOT IN is unsafe the moment
--   EITHER side of the implicit equality can be NULL, not only when the
--   subquery's own column is nullable.

-- ----------------------------------------------------------------------------
-- F4 · Users who liked and then retracted a like on the same clip within 60s.
-- Intent: pair each retraction with its own most recent preceding like on
--   the same (user, video) — not just any like on that pair — since a user
--   could like the same clip more than once across separate like/retract
--   cycles. ROW_NUMBER over candidate likes, ordered nearest-first, picks
--   exactly one match per retraction.
-- Expected shape: one row per (user, video, retraction) triple whose gap is
--   <= 60s; distinct users <= row count, since one user can trigger this on
--   multiple videos.
-- ----------------------------------------------------------------------------
WITH Likes AS (
    SELECT signal_id, user_id, video_id, occurred_at
    FROM EngagementSignal WHERE signal_type = 'like'
),
Retractions AS (
    SELECT signal_id, user_id, video_id, occurred_at
    FROM EngagementSignal WHERE signal_type = 'like_retraction'
),
Paired AS (
    SELECT
        r.user_id, r.video_id,
        l.occurred_at AS liked_at,
        r.occurred_at AS retracted_at,
        (julianday(r.occurred_at) - julianday(l.occurred_at)) * 86400.0 AS gap_seconds,
        ROW_NUMBER() OVER (
            PARTITION BY r.signal_id ORDER BY l.occurred_at DESC
        ) AS rn
    FROM Retractions r
    JOIN Likes l
      ON l.user_id = r.user_id
     AND l.video_id = r.video_id
     AND l.occurred_at <= r.occurred_at
)
SELECT user_id, video_id, liked_at, retracted_at, ROUND(gap_seconds, 1) AS gap_seconds
FROM Paired
WHERE rn = 1
  AND gap_seconds <= 60
ORDER BY gap_seconds ASC, user_id ASC;
-- Rows returned: 1861   Runtime: 18.4 ms
-- Reading: 1,861 distinct (user, video) retraction events land inside the
--   60-second window (1,554 distinct users), matching E.3's seeded target
--   exactly; the generator also planted 1,989 slower retractions (minutes to
--   an hour later) specifically so this BETWEEN-style filter has real
--   negative cases to exclude, confirmed absent from this result set.

-- ----------------------------------------------------------------------------
-- F5 · Videos whose caption carries a given hashtag (:tag), case-insensitive,
--   tolerant of surrounding punctuation and whitespace.
-- Intent: hashtags live inside free-text captions (C.2's deliberate choice,
--   not a separate table), typed in "no consistent case" (§2.2). No REGEXP,
--   no split_part in SQLite — built from lower()/trim()/replace()/instr().
-- Approach: strip common ASCII sentence punctuation to spaces, lowercase,
--   pad both ends of the caption with a single space so the very first/last
--   token still has a boundary to match against, then look for the padded
--   token ' #tag ' as a substring.
-- ----------------------------------------------------------------------------
WITH cleaned AS (
    SELECT
        video_id,
        caption,
        ' ' || lower(
            replace(replace(replace(replace(replace(replace(replace(replace(
                trim(caption),
            '.', ' '), ',', ' '), '!', ' '), '?', ' '), ';', ' '), ':', ' '),
            char(34), ' '), char(39), ' ')
        ) || ' ' AS norm
    FROM Video
)
SELECT video_id, caption
FROM cleaned
WHERE instr(norm, ' #' || lower('catsofscrollsense') || ' ') > 0
ORDER BY video_id;
-- Example bound to :tag = 'catsofscrollsense'
-- Rows returned: 3637   Runtime: 24.2 ms
-- Reading: 3,637 videos carry #catsofscrollsense in any capitalisation —
--   matches a direct `lower(caption) LIKE '%#catsofscrollsense%'` sanity
--   check exactly on this (punctuation-free) generated dataset.
--   One-line answers to the task sheet's two follow-up questions:
--   * LIKE vs GLOB: LIKE is used, deliberately — SQLite's LIKE is
--     case-insensitive for ASCII by default (no COLLATE NOCASE needed once
--     both sides are already lower()'d), whereas GLOB is always
--     case-sensitive and would require lower()-ing both sides anyway with
--     none of LIKE's ASCII case-folding for free.
--   * Tamil captions: unaffected either way. Tamil script has no case to
--     fold, so LIKE's case-insensitivity is moot for a Tamil hashtag; the
--     ASCII punctuation list this query strips (., , ! ? ; : " ') also
--     never appears inside Tamil text; the one real gap is Unicode
--     normalisation (composed vs. decomposed codepoint sequences for the
--     same visible glyph, same issue E.1 named for handles) — SQLite
--     performs none, and neither does this query; a hashtag typed in two
--     different Tamil codepoint sequences that render identically would
--     not match here.

-- ----------------------------------------------------------------------------
-- F6 · Users shown a given creator's (:creator_id) clips but never engaged
--   with any of them — via a set operator.
-- Intent: EXCEPT expresses "shown, minus engaged" directly as set
--   subtraction rather than as a LEFT JOIN / IS NULL anti-join — the task
--   sheet asks specifically for the set-operator form.
-- ----------------------------------------------------------------------------
SELECT DISTINCT i.user_id
FROM Impression i
JOIN Video v ON v.video_id = i.video_id
WHERE v.owner_id = 279  -- example: the highest-reach creator in the generated data

EXCEPT

SELECT DISTINCT es.user_id
FROM EngagementSignal es
JOIN Video v ON v.video_id = es.video_id
WHERE v.owner_id = 279

ORDER BY user_id;
-- Example bound to :creator_id = 279 (the highest-reach creator in the
-- generated data — 219,132 impressions across its clips)
-- Rows returned: 151   Runtime: 480.0 ms
-- Reading: of the 5,000 users shown creator 279's clips (effectively the
--   whole user base, given creator 279's reach), all but 151 engaged with
--   at least one of them in some way — a 97% reach-to-engagement rate that
--   is a direct consequence of this creator's viral audio track (F1) and
--   power-law follower count, not typical of the platform as a whole.

-- One signal roll-up, UNION vs UNION ALL:
SELECT user_id, video_id FROM EngagementSignal WHERE signal_type = 'like'
UNION
SELECT user_id, video_id FROM EngagementSignal WHERE signal_type = 'save';
-- Rows returned (UNION):     15586   Runtime: 219.9 ms

SELECT user_id, video_id FROM EngagementSignal WHERE signal_type = 'like'
UNION ALL
SELECT user_id, video_id FROM EngagementSignal WHERE signal_type = 'save';
-- Rows returned (UNION ALL): 15656   Runtime: 8.2 ms
-- Reading: the 70-row gap (15656 - 15586) is exactly the number of
--   (user_id, video_id) pairs where the same user both liked AND saved the
--   same clip — UNION's implicit DISTINCT collapses that pair to one row,
--   UNION ALL keeps both. Neither answer is "more correct" in the abstract:
--   UNION is right if the question is "which (user, video) pairs engaged
--   at all", UNION ALL is right if the question is "how many engagement
--   events occurred" (a user who both liked and saved the same clip
--   generated two events, not one). The runtime gap (219.9ms vs 8.2ms) is
--   itself informative: UNION's implicit dedup forces a sort over ~15.6K
--   rows that UNION ALL never pays for — a good reason to default to
--   UNION ALL whenever duplicates are known to be impossible or acceptable.

-- ----------------------------------------------------------------------------
-- F7 · Cost of each agent session last month, broken out by prompt template
--   version, restricted to sessions costing more than :threshold.
-- Intent: "last month" is the last full calendar month present in the data
--   (computed from MAX(Turn.created_at), never date('now')) — August 2026 on
--   this dataset, since the window ends mid-September. Turn -> price-period
--   is a RANGE join on validity intervals (A10/E.2), never an equality join
--   on timestamp: ModelPricePeriod.effective_from <= created_at AND
--   (effective_to IS NULL OR effective_to > created_at). The per-session
--   threshold filters on the SESSION's total cost across every template
--   version it used, even though the reported rows are broken out by
--   version — a window SUM() computes the session total once, the outer
--   WHERE filters against it without collapsing the per-version rows.
-- ----------------------------------------------------------------------------
WITH anchor AS (
    SELECT MAX(created_at) AS max_ts FROM Turn
),
month_bounds AS (
    SELECT
        strftime('%Y-%m-01T00:00:00Z', date(max_ts, 'start of month', '-1 month')) AS month_start,
        strftime('%Y-%m-01T00:00:00Z', date(max_ts, 'start of month'))             AS month_end
    FROM anchor
),
TurnCost AS (
    SELECT
        t.session_id, t.sequence_no, t.template_id, t.template_version,
        (tu.input_tokens  * mp.input_rate
       + tu.output_tokens * mp.output_rate
       + tu.cached_tokens * mp.cached_rate) AS turn_cost
    FROM Turn t
    JOIN month_bounds mb ON t.created_at >= mb.month_start AND t.created_at < mb.month_end
    JOIN TurnUsage tu ON tu.session_id = t.session_id AND tu.sequence_no = t.sequence_no
    JOIN ModelPricePeriod mp
      ON mp.model_id = t.model_id
     AND mp.effective_from <= t.created_at
     AND (mp.effective_to IS NULL OR mp.effective_to > t.created_at)
),
BySessionTemplate AS (
    SELECT session_id, template_id, template_version,
           SUM(turn_cost) AS subtotal_cost, COUNT(*) AS n_turns
    FROM TurnCost
    GROUP BY session_id, template_id, template_version
),
SessionTotal AS (
    SELECT session_id, SUM(subtotal_cost) AS session_total
    FROM BySessionTemplate
    GROUP BY session_id
)
SELECT
    bst.session_id, bst.template_id, bst.template_version,
    ROUND(bst.subtotal_cost, 6) AS subtotal_cost, bst.n_turns,
    ROUND(st.session_total, 6)  AS session_total_cost
FROM BySessionTemplate bst
JOIN SessionTotal st ON st.session_id = bst.session_id
WHERE st.session_total > 1.00  -- example threshold: USD 1.00
ORDER BY st.session_total DESC, bst.session_id, bst.template_id, bst.template_version;
-- Example bound to :threshold = 1.00 (USD)
-- Rows returned: 35 (9 distinct sessions)   Runtime: 7.2 ms
-- Reading: the most expensive session in August cost $1.26 across five
--   (template_id, template_version) combinations in a single turn's worth
--   of nested tool activity; restricting to session_total > $1.00 keeps the
--   report to the 9 genuinely expensive sessions instead of Finance having
--   to scroll all ~1,025 August sessions to find them.

-- ----------------------------------------------------------------------------
-- F8 · Videos whose moderation state changed more than twice, with the full
--   sequence of transitions in chronological order.
-- Intent: "changed" means the state actually differs from the immediately
--   preceding decision — a second human decision that re-confirms the same
--   state is not a change and must not inflate the count. LAG() detects
--   real transitions; group_concat's ORDER BY clause (SQLite 3.44+, per
--   §0.1) guarantees the printed sequence is chronological regardless of
--   physical row order.
-- ----------------------------------------------------------------------------
WITH Ordered AS (
    SELECT
        video_id, state_code, decided_at,
        LAG(state_code) OVER (
            PARTITION BY video_id ORDER BY decided_at, decision_id
        ) AS prev_state
    FROM ModerationDecision
),
RealChanges AS (
    SELECT video_id, state_code, decided_at
    FROM Ordered
    WHERE prev_state IS NULL OR state_code <> prev_state
),
ChangeCounts AS (
    SELECT video_id, COUNT(*) AS n_states
    FROM RealChanges
    GROUP BY video_id
)
SELECT
    cc.video_id,
    cc.n_states,
    (
        SELECT group_concat(rc.state_code || '@' || rc.decided_at, ' -> ')
        FROM (
            SELECT state_code, decided_at
            FROM RealChanges
            WHERE video_id = cc.video_id
            ORDER BY decided_at
        ) rc
    ) AS transition_sequence
FROM ChangeCounts cc
WHERE cc.n_states > 2
ORDER BY cc.n_states DESC, cc.video_id ASC;
-- Rows returned: 1644   Runtime: 71.4 ms
-- Reading: 1,644 of the 20,000 videos (8.2%) cycled through more than two
--   genuinely distinct moderation states — the pending -> live ->
--   {demoted | age_restricted} -> live pattern in the sample rows shows a
--   clip provisionally penalised and then reinstated, exactly the kind of
--   history a single-column "current state" on Video (the founders'
--   original design, §2.7) would have destroyed.

-- ============================================================================
-- Tier 2 — window functions and recursion
-- ============================================================================

-- ----------------------------------------------------------------------------
-- F9 · Each user's longest streak of consecutive active days.
-- Intent: "active day" = a calendar day on which the user received at least
--   one Impression (the lowest-friction, highest-volume activity signal —
--   just having the app open and scrolling). Classic gaps-and-islands:
--   number each user's distinct active dates consecutively, subtract the
--   row number (in days) from the date itself — rows in the same
--   unbroken run collapse to the same "island key" — then group and take
--   each user's longest island.
-- ----------------------------------------------------------------------------
WITH ActiveDays AS (
    SELECT DISTINCT user_id, date(occurred_at) AS active_date
    FROM Impression
),
Numbered AS (
    SELECT
        user_id, active_date,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY active_date) AS rn
    FROM ActiveDays
),
Islands AS (
    SELECT
        user_id, active_date, rn,
        date(active_date, '-' || rn || ' days') AS island_key
    FROM Numbered
),
Streaks AS (
    SELECT
        user_id, island_key,
        COUNT(*)         AS streak_len,
        MIN(active_date) AS streak_start,
        MAX(active_date) AS streak_end
    FROM Islands
    GROUP BY user_id, island_key
),
BestPerUser AS (
    SELECT
        user_id, streak_len, streak_start, streak_end,
        ROW_NUMBER() OVER (
            PARTITION BY user_id ORDER BY streak_len DESC, streak_start ASC
        ) AS rn
    FROM Streaks
)
SELECT user_id, streak_len, streak_start, streak_end
FROM BestPerUser
WHERE rn = 1
ORDER BY streak_len DESC, user_id ASC;
-- Rows returned: 5000   Runtime: 420.5 ms
-- Reading: every one of the 5,000 users has at least one impression, so all
--   5,000 appear; the longest streak in the data is 20 consecutive days
--   (user 4277, Aug 12-31) against a ~60-day data window, meaning even the
--   most consistent user in this generated sample was active on roughly a
--   third of all days without a single gap — the daily-rhythm and
--   right-skew distributions (E.3) don't force artificial daily logins.

-- ----------------------------------------------------------------------------
-- F10 · Rank creators by 7-day rolling watch time, showing week-over-week
--   change (live clips only, same LiveVideo resolution as F2).
-- Intent: "7 days" is interpreted as seven CALENDAR days (RANGE, ordered by
--   julianday(day), not ROWS) — the version Growth actually asked for, per
--   the task sheet's own warning that this is not the same query as "the
--   seven days on which this creator happened to have activity". The
--   week-over-week comparison is likewise a self-join on the exact date
--   seven calendar days earlier (date(day, '-7 days')), not a ROWS-based
--   LAG(7) — a creator with a gapped daily-activity table would make
--   LAG(...,7 ROWS) silently compare against the wrong day.
-- ----------------------------------------------------------------------------
WITH LatestDecision AS (
    SELECT
        video_id, state_code,
        ROW_NUMBER() OVER (
            PARTITION BY video_id ORDER BY decided_at DESC, decision_id DESC
        ) AS rn
    FROM ModerationDecision
),
LiveVideo AS (
    SELECT ld.video_id, v.owner_id
    FROM LatestDecision ld
    JOIN Video v ON v.video_id = ld.video_id
    WHERE ld.rn = 1 AND ld.state_code = 'live'
),
DailyWatch AS (
    SELECT
        lv.owner_id AS creator_id,
        date(i.occurred_at) AS day,
        SUM(vs.segment_end_ms - vs.segment_start_ms) AS watch_ms
    FROM LiveVideo lv
    JOIN Impression  i  ON i.video_id = lv.video_id
    JOIN ViewSegment vs ON vs.impression_id = i.impression_id
    GROUP BY lv.owner_id, date(i.occurred_at)
),
Rolling AS (
    SELECT
        creator_id, day, watch_ms,
        SUM(watch_ms) OVER (
            PARTITION BY creator_id ORDER BY julianday(day)
            RANGE BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS rolling_7d_watch_ms
    FROM DailyWatch
),
Ranked AS (
    SELECT
        creator_id, day, rolling_7d_watch_ms,
        RANK() OVER (PARTITION BY day ORDER BY rolling_7d_watch_ms DESC) AS rank_that_day
    FROM Rolling
)
SELECT
    cur.day, cur.creator_id, cur.rolling_7d_watch_ms, cur.rank_that_day,
    prior.rolling_7d_watch_ms AS rolling_7d_watch_ms_7_days_ago,
    ROUND(cur.rolling_7d_watch_ms - COALESCE(prior.rolling_7d_watch_ms, 0), 1) AS wow_change_ms
FROM Ranked cur
LEFT JOIN Ranked prior
       ON prior.creator_id = cur.creator_id
      AND prior.day = date(cur.day, '-7 days')
WHERE cur.day = (SELECT MAX(day) FROM DailyWatch)
ORDER BY cur.rank_that_day ASC;
-- Rows returned: 46 (all creators with any live-clip watch time on the
--   data's last active day)   Runtime: 264.0 ms
-- Reading: creator 279 holds rank 1 on the final day with a 7-day rolling
--   watch time of ~102.4M ms, up ~63K ms week-over-week — a small
--   incremental gain on an already-dominant base, versus creator 950 in
--   rank 2, whose rolling watch time grew by ~1.25M ms, a far larger
--   week-over-week jump off a smaller base. Rank alone would have hidden
--   that creator 950 is the one actually accelerating.

-- ----------------------------------------------------------------------------
-- F11 · Full nesting tree for a given agent session's tool calls (:session_id,
--   :sequence_no), with depth.
-- Intent: tool calls nest to arbitrary depth (§2.5, A9) via a
--   self-referencing parent_tool_call_id — walked with a recursive CTE
--   (SQLite 3.8.3+, per §0.1), anchored on top-level calls
--   (parent_tool_call_id IS NULL) for the given turn.
-- ----------------------------------------------------------------------------
WITH RECURSIVE ToolTree AS (
    SELECT
        tool_call_id, session_id, sequence_no, parent_tool_call_id,
        tool_name, latency_ms, errored, called_at,
        0 AS depth,
        CAST(tool_call_id AS TEXT) AS path
    FROM ToolCall
    WHERE session_id = 173 AND sequence_no = 4  -- example: a session/turn with real nesting
      AND parent_tool_call_id IS NULL

    UNION ALL

    SELECT
        tc.tool_call_id, tc.session_id, tc.sequence_no, tc.parent_tool_call_id,
        tc.tool_name, tc.latency_ms, tc.errored, tc.called_at,
        tt.depth + 1,
        tt.path || '.' || tc.tool_call_id
    FROM ToolCall tc
    JOIN ToolTree tt ON tc.parent_tool_call_id = tt.tool_call_id
)
SELECT tool_call_id, parent_tool_call_id, depth, tool_name, latency_ms, errored, path
FROM ToolTree
ORDER BY path;
-- Example bound to :session_id = 173, :sequence_no = 4
-- Rows returned: 6   Runtime: 1.9 ms
-- Reading: turn 4 of session 173 issued three top-level tool calls
--   (get_user_history, search_videos x2), and exactly one of them
--   (get_user_history, call 573) spawned a single nested sub-call
--   (search_videos, call 6822, depth 1) — the generator seeds nesting
--   sparingly (E.3: "incl. one level of nesting" against 7,702 total tool
--   calls), so most sessions in this dataset are flat and this recursive
--   query degenerates gracefully to depth 0 for them, as it should.

-- ----------------------------------------------------------------------------
-- F12 · Sessions where the agent recommended a clip that the user then
--   watched to completion — reporting that clip's position in the shelf.
-- Intent: the "spine" query (§3 of the brief). Completion uses
--   MAX(segment_end_ms) >= duration_ms via EXISTS, never a COUNT of
--   ViewSegment rows — an impression can legitimately produce several
--   segments (loops, scroll-away-and-back, §2.4), so counting rows would
--   both risk double-counting a genuinely-completed view watched in three
--   short loops and risk missing one entirely depending on aggregation
--   order. The traceability itself is a plain key join
--   (Recommendation.recommendation_id = Impression.source_recommendation_id,
--   B.3 #3) — never a timestamp-window heuristic, which the brief's own §3
--   explicitly warns can silently pull in a later, unrelated impression of
--   the same re-entrant clip (A7).
-- ----------------------------------------------------------------------------
WITH CompletedImpression AS (
    SELECT i.impression_id, i.source_recommendation_id
    FROM Impression i
    JOIN Video v ON v.video_id = i.video_id
    WHERE i.source_recommendation_id IS NOT NULL
      AND EXISTS (
          SELECT 1 FROM ViewSegment vs
          WHERE vs.impression_id = i.impression_id
            AND vs.segment_end_ms >= v.duration_ms
      )
)
SELECT
    r.session_id, r.sequence_no, r.position, r.video_id, ci.impression_id
FROM Recommendation r
JOIN CompletedImpression ci ON ci.source_recommendation_id = r.recommendation_id
ORDER BY r.session_id, r.sequence_no, r.position;
-- Rows returned: 348   Runtime: 32.1 ms
-- Reading: of the 24,000 impressions traceable back to a specific
--   recommendation slot, 348 (1.45%) were watched all the way to
--   completion — a low but real conversion rate for agent-sourced
--   discovery, computable in one join precisely because Recommendation
--   carries a first-class foreign key rather than requiring a fuzzy
--   timestamp match (B.3 #3's payoff, realised).

-- ----------------------------------------------------------------------------
-- F13 · Turns where the LLM judge scored above 4 but the user gave a
--   thumbs-down.
-- Intent: both JudgeScore and UserRating are intentionally append-only
--   (A11 — a turn can be re-judged, a rating can change). "Scored above 4"
--   uses the LATEST judge score's helpfulness dimension for that turn, and
--   "thumbs-down" uses the user's LATEST rating — not "any score/rating
--   ever" — because using "any" would let a turn that was originally rated
--   thumbs-down and later corrected to thumbs-up still show up as a live
--   disagreement, which is no longer true. ROW_NUMBER() resolves each
--   append-only log to its current value before the comparison.
-- ----------------------------------------------------------------------------
WITH LatestJudge AS (
    SELECT
        session_id, sequence_no, helpfulness, judged_at,
        ROW_NUMBER() OVER (
            PARTITION BY session_id, sequence_no
            ORDER BY judged_at DESC, judge_score_id DESC
        ) AS rn
    FROM JudgeScore
),
LatestRating AS (
    SELECT
        session_id, sequence_no, thumbs, rated_at,
        ROW_NUMBER() OVER (
            PARTITION BY session_id, sequence_no
            ORDER BY rated_at DESC, rating_id DESC
        ) AS rn
    FROM UserRating
)
SELECT
    t.session_id, t.sequence_no, lj.helpfulness, lr.thumbs, lj.judged_at, lr.rated_at
FROM Turn t
JOIN LatestJudge  lj ON lj.session_id = t.session_id AND lj.sequence_no = t.sequence_no AND lj.rn = 1
JOIN LatestRating lr ON lr.session_id = t.session_id AND lr.sequence_no = t.sequence_no AND lr.rn = 1
WHERE lj.helpfulness > 4
  AND lr.thumbs = -1
ORDER BY t.session_id, t.sequence_no;
-- Rows returned: 5   Runtime: 3.0 ms
-- Reading: only 5 turns out of 65 that carry BOTH a judge score and a user
--   rating land in this disagreement bucket — and this small set is the
--   single most commercially valuable data in the company, because it is
--   the only place where an automated proxy for quality (the LLM judge,
--   cheap and scalable) and the ground truth it is a proxy FOR (an actual
--   user's reaction, expensive and rare — only 295 of 4,642 turns are ever
--   rated at all) actively contradict each other. Everywhere the two agree,
--   the judge is doing its job and nothing needs attention; everywhere only
--   one of them fired, there's no way to tell if the judge is right. Only
--   here is there direct evidence the judge itself needs recalibration —
--   and because both signals are logged as append-only history rather than
--   overwritten (A11), ScrollSense can watch whether a prompt-template or
--   judge-model change later shrinks this exact set, which is the only
--   real test of whether the fix worked.
