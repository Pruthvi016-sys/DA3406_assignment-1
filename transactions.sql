-- ============================================================================
-- ScrollSense · Assignment 1 · Deliverable G.3 — transactions.sql
-- Data Management | SQLite 3.44+
--
-- Three failure-mode demonstrations from Brief §2.7. Each block below is
-- the exact SQL each connection issues. T1 is a single connection and can
-- be pasted into one `sqlite3`/DBeaver session directly. T2 and T3 each
-- need TWO (T3: three) simultaneous connections to the SAME scrollsense.db
-- file to demonstrate cross-connection isolation and locking, which no
-- single `.sql` script runner can hold open at once -- run those two via
-- `python3 run_transactions_demo.py scrollsense.db` instead, which opens
-- the connections explicitly and issues exactly the statements shown below
-- in the order shown, printing real proof output (captured verbatim in the
-- written report, G.3).
--
-- Why T1 is Block/Follow, not the like-retraction the task sheet's own
-- template names: B.2/B.3 #1 deliberately modelled a retraction as ONE
-- EngagementSignal row (signal_type='like_retraction'), specifically to
-- eliminate the founders' two-write hazard for that case (a retraction was
-- never "end the like row AND write a negative-signal row" in this design
-- -- it never touches the original like row at all). There is no real
-- dual-write left there to demonstrate failing. A.4 (blocking must break
-- any existing follow, in both directions) is a genuine two-statement
-- operation across two tables (Block, Follow) with no shared design fix,
-- so it is used here instead.
-- ============================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;   -- confirm WAL is active (set once, at schema.sql time)

-- ----------------------------------------------------------------------------
-- T1 — Block breaks Follow, atomically.
--
-- A block (A4) must (a) record the block and (b) end any existing follow
-- between the two users, in both directions. Demonstrated on a real pair
-- already present in the seed-16 data: user 4627 follows user 684, with no
-- existing Block row between them.
--
-- SELECT 1/0 is deliberately NOT used as the injected failure: SQLite's
-- integer division returns NULL for x/0, not an error, so `SELECT 1/0;`
-- inside a transaction simply produces a NULL row and COMMIT proceeds
-- normally -- it does not demonstrate anything. The injected failure below
-- is a real UNIQUE/PRIMARY KEY constraint violation instead (re-inserting
-- the same Block row a second time, simulating a duplicate block request
-- racing into the same transaction).
-- ----------------------------------------------------------------------------

BEGIN;

INSERT INTO Block(blocker_id, blocked_id, blocked_at)
VALUES (684, 4627, '2026-09-13T10:00:00Z');

UPDATE Follow
SET ended_at = '2026-09-13T10:00:00Z'
WHERE ((follower_id = 684 AND followee_id = 4627)
    OR (follower_id = 4627 AND followee_id = 684))
  AND ended_at IS NULL;

-- deliberate failure: duplicate Block insert -> real UNIQUE/PK violation
INSERT INTO Block(blocker_id, blocked_id, blocked_at)
VALUES (684, 4627, '2026-09-13T10:00:05Z');

COMMIT;  -- never reached; the duplicate insert above aborts the statement,
         -- and the driver issues ROLLBACK on catching it (see below)
ROLLBACK;

-- Proof of consistency: expect Block to have NO row for this pair, and the
-- Follow row to be untouched (ended_at still NULL) -- neither write landed.
SELECT COUNT(*) AS block_rows
FROM Block WHERE blocker_id = 684 AND blocked_id = 4627;

SELECT follower_id, followee_id, ended_at
FROM Follow
WHERE (follower_id = 4627 AND followee_id = 684)
   OR (follower_id = 684 AND followee_id = 4627);


-- ----------------------------------------------------------------------------
-- T2 — Moderation decision: a half-applied write must be invisible.
--
-- A moderation decision is one INSERT into ModerationDecision (B.2/B.3 #2:
-- "current" state is derived from history via v_video_current_state, never
-- written a second time -- this is the direct fix for §2.7's named bug).
-- That single INSERT still fires the AFTER INSERT audit trigger already in
-- schema.sql (trg_moderation_audit_ins), so it genuinely writes to TWO
-- tables (ModerationDecision + ModerationDecisionAudit) inside one
-- transaction -- the two-statement operation this demo needs, produced
-- automatically rather than written by hand.
--
-- Run via run_transactions_demo.py, which opens Connection A (writer) and
-- Connection B (reader) against the same file and issues exactly this:
-- ----------------------------------------------------------------------------

-- Connection B, before:
SELECT current_state FROM v_video_current_state WHERE video_id = 1;

-- Connection A:
BEGIN;
INSERT INTO ModerationDecision(video_id, state_code, decided_at, decider_type, decider_id)
VALUES (1, 'age_restricted', '2026-09-13T10:05:00Z', 'human', 42);
-- (trg_moderation_audit_ins fires here automatically, same transaction)
-- -- left OPEN, not committed yet --

-- Connection B, while A's transaction is still open (its own fresh read txn):
BEGIN;
SELECT current_state FROM v_video_current_state WHERE video_id = 1;   -- expect: unchanged
SELECT COUNT(*) FROM ModerationDecisionAudit
WHERE video_id = 1 AND state_code = 'age_restricted';                 -- expect: 0
COMMIT;

-- Connection A:
COMMIT;

-- Connection B, after A commits (a new read txn):
BEGIN;
SELECT current_state FROM v_video_current_state WHERE video_id = 1;   -- expect: 'age_restricted'
SELECT COUNT(*) FROM ModerationDecisionAudit
WHERE video_id = 1 AND state_code = 'age_restricted';                 -- expect: 1
COMMIT;

-- Note (§0.1's own reason for requiring journal_mode=WAL): under the
-- DEFAULT rollback-journal mode, Connection B's read above would instead
-- BLOCK until Connection A releases its lock (or hit SQLITE_BUSY under a
-- short timeout) rather than transparently seeing the pre-transaction
-- value -- a different, less interesting thing to demonstrate. WAL is what
-- lets a reader see a consistent snapshot *concurrently* with an open writer.


-- ----------------------------------------------------------------------------
-- T3 — Handle change: the twice-a-year rule, and SQLITE_BUSY under a
-- concurrent writer.
--
-- Part (a): while one connection holds an open write transaction, a SECOND
-- connection's attempted write on a *different, unrelated* row still fails
-- immediately with SQLITE_BUSY -- SQLite locks the whole database file for
-- writes, not row-by-row, so it never needs to resolve which of two
-- concurrent writers "wins" on overlapping data. The anomaly this
-- sidesteps is the classic multi-writer LOST UPDATE: two transactions each
-- read-modify-write the same row concurrently and one silently clobbers
-- the other's change with no error at all. A single-writer engine can
-- never produce that outcome, because there is structurally never a
-- second writer to race against; a multi-writer engine (Postgres included)
-- has to prevent it deliberately, with row/predicate locking or
-- serializable snapshot isolation.
--
-- Part (b): the rolling-365-day cap on handle changes (A1), enforced by
-- trg_appuser_handle_change_cap (schema.sql), fires on the third distinct
-- handle write within the window.
--
-- Run via run_transactions_demo.py. Statements issued:
-- ----------------------------------------------------------------------------

-- Connection "Writer": acquire the write lock and hold it open.
BEGIN IMMEDIATE;
UPDATE AppUser SET display_name = display_name WHERE user_id = 4627;
-- -- left OPEN --

-- Connection "Other" (opened with a zero busy-timeout, so SQLite fails
-- immediately instead of waiting): attempts an unrelated write.
BEGIN IMMEDIATE;
UPDATE AppUser SET display_name = display_name WHERE user_id = 4628;
-- expect: SQLITE_BUSY ("database is locked") -- raised before any row is touched

-- Connection "Writer":
COMMIT;   -- releases the lock

-- Connection (single, sequential): three handle changes for the same user.
UPDATE AppUser SET handle = handle || '_v1' WHERE user_id = 4627;  -- 1st change this window -> ok
UPDATE AppUser SET handle = handle || '_v2' WHERE user_id = 4627;  -- 2nd change this window -> ok
UPDATE AppUser SET handle = handle || '_v3' WHERE user_id = 4627;  -- 3rd change this window -> rejected

-- Proof of consistency: expect exactly 2 HandleChangeLog rows for this
-- user (the trigger rejects the write BEFORE it happens, so the 3rd
-- attempt is never logged), and AppUser.handle still holding the *_v2*
-- value, never *_v3*.
SELECT COUNT(*) FROM HandleChangeLog WHERE user_id = 4627;
SELECT handle FROM AppUser WHERE user_id = 4627;
