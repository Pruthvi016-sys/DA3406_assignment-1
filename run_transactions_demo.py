#!/usr/bin/env python3
"""
ScrollSense · Assignment 1 · Deliverable G.3 — run_transactions_demo.py

Executes T1, T2 and T3 from transactions.sql for real against a live
scrollsense.db and prints the actual proof output — this is not a mock
transcript, it is the console output this script produced on this exact
database (used verbatim in the written report).

T2 and T3 need two/three independent SQLite connections open at once (to
demonstrate WAL-mode reader isolation and single-writer SQLITE_BUSY), which
is why this is a standalone script rather than a single `.sql` file: no
`.sql` script runner can hold two connections open simultaneously.

Usage:
    python3 run_transactions_demo.py scrollsense.db
"""

import sqlite3
import sys

DB_PATH = sys.argv[1] if len(sys.argv) > 1 else "scrollsense.db"


def line(msg=""):
    print(msg)


def hr(title):
    print()
    print("=" * 78)
    print(title)
    print("=" * 78)


def connect():
    # isolation_level=None => autocommit mode; we issue BEGIN/COMMIT/ROLLBACK
    # ourselves so the transaction boundaries in the transcript are explicit,
    # matching transactions.sql exactly rather than python's implicit ones.
    conn = sqlite3.connect(DB_PATH, isolation_level=None, timeout=5.0)
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


# ============================================================================
# T1 — Block breaks Follow (two-statement operation), rolled back by a real
# constraint violation (SQLite's `1/0` is NULL, not an error, so a UNIQUE
# violation is used instead — a duplicate Block insert).
# ============================================================================

def demo_t1():
    hr("T1 — Block breaks Follow, atomically (real constraint failure mid-transaction)")

    conn = connect()
    BLOCKER, BLOCKED = 684, 4627

    before_block = conn.execute(
        "SELECT COUNT(*) FROM Block WHERE blocker_id=? AND blocked_id=?", (BLOCKER, BLOCKED)
    ).fetchone()[0]
    before_follow = conn.execute(
        "SELECT follower_id, followee_id, ended_at FROM Follow "
        "WHERE (follower_id=? AND followee_id=?) OR (follower_id=? AND followee_id=?)",
        (BLOCKED, BLOCKER, BLOCKER, BLOCKED),
    ).fetchall()
    line(f"Before: Block rows for ({BLOCKER}->{BLOCKED}) = {before_block}")
    line(f"Before: Follow rows between them            = {before_follow}")

    line("\nBEGIN;")
    conn.execute("BEGIN")
    conn.execute(
        "INSERT INTO Block(blocker_id, blocked_id, blocked_at) VALUES (?,?,?)",
        (BLOCKER, BLOCKED, "2026-09-13T10:00:00Z"),
    )
    line(f"  INSERT INTO Block ...  -- ({BLOCKER} blocks {BLOCKED})  [ok]")

    conn.execute(
        "UPDATE Follow SET ended_at = ? "
        "WHERE ((follower_id=? AND followee_id=?) OR (follower_id=? AND followee_id=?)) "
        "  AND ended_at IS NULL",
        ("2026-09-13T10:00:00Z", BLOCKED, BLOCKER, BLOCKER, BLOCKED),
    )
    line("  UPDATE Follow SET ended_at = ...  -- breaks any existing follow, both directions  [ok]")

    line("  -- deliberate failure: duplicate Block insert -> UNIQUE/PK violation")
    try:
        conn.execute(
            "INSERT INTO Block(blocker_id, blocked_id, blocked_at) VALUES (?,?,?)",
            (BLOCKER, BLOCKED, "2026-09-13T10:00:05Z"),
        )
        line("  INSERT INTO Block ... (duplicate)  [UNEXPECTED: did not fail]")
    except sqlite3.IntegrityError as e:
        line(f"  INSERT INTO Block ... (duplicate)  -> IntegrityError: {e}")
        conn.execute("ROLLBACK")
        line("ROLLBACK;  -- issued by the driver on catching the error")

    after_block = conn.execute(
        "SELECT COUNT(*) FROM Block WHERE blocker_id=? AND blocked_id=?", (BLOCKER, BLOCKED)
    ).fetchone()[0]
    after_follow = conn.execute(
        "SELECT follower_id, followee_id, ended_at FROM Follow "
        "WHERE (follower_id=? AND followee_id=?) OR (follower_id=? AND followee_id=?)",
        (BLOCKED, BLOCKER, BLOCKER, BLOCKED),
    ).fetchall()
    line(f"\nAfter:  Block rows for ({BLOCKER}->{BLOCKED}) = {after_block}   (expect 0 -- rolled back)")
    line(f"After:  Follow rows between them            = {after_follow}   (expect ended_at IS NULL -- unaffected)")
    conn.close()


# ============================================================================
# T2 — Moderation decision: a decision INSERT (which itself fires the
# audit-log AFTER trigger already in schema.sql) held open on one connection
# is invisible to a second connection until COMMIT — demonstrated under
# WAL, per §0.1's own reason for requiring that pragma.
# ============================================================================

def demo_t2():
    hr("T2 — Moderation decision: half-applied write is invisible to a second connection (WAL)")

    VIDEO_ID = 1
    connA = connect()  # the writer
    connB = connect()  # the reader

    row = connB.execute(
        "SELECT current_state FROM v_video_current_state WHERE video_id=?", (VIDEO_ID,)
    ).fetchone()
    line(f"Conn B, before: v_video_current_state(video_id={VIDEO_ID}) = {row[0]}")

    line("\nConn A: BEGIN;")
    connA.execute("BEGIN")
    connA.execute(
        "INSERT INTO ModerationDecision(video_id, state_code, decided_at, decider_type, decider_id) "
        "VALUES (?, 'age_restricted', '2026-09-13T10:05:00Z', 'human', 42)",
        (VIDEO_ID,),
    )
    line("Conn A:   INSERT INTO ModerationDecision ... (video 1 -> age_restricted, decider 42)")
    line("Conn A:   -- fires trg_moderation_audit_ins automatically (same transaction)")
    line("Conn A:   -- left OPEN, not yet committed")

    # Conn B starts a fresh read transaction to get a consistent WAL snapshot
    connB.execute("BEGIN")
    row_mid = connB.execute(
        "SELECT current_state FROM v_video_current_state WHERE video_id=?", (VIDEO_ID,)
    ).fetchone()
    audit_mid = connB.execute(
        "SELECT COUNT(*) FROM ModerationDecisionAudit WHERE video_id=? AND state_code='age_restricted'",
        (VIDEO_ID,),
    ).fetchone()[0]
    line(f"\nConn B, while A's transaction is open (new read txn):")
    line(f"  v_video_current_state(video_id={VIDEO_ID}) = {row_mid[0]}   (expect: still the OLD state)")
    line(f"  ModerationDecisionAudit rows for 'age_restricted' on this video = {audit_mid}   (expect 0)")
    connB.execute("COMMIT")  # close B's read txn, no writes

    line("\nConn A: COMMIT;")
    connA.execute("COMMIT")

    connB.execute("BEGIN")
    row_after = connB.execute(
        "SELECT current_state FROM v_video_current_state WHERE video_id=?", (VIDEO_ID,)
    ).fetchone()
    audit_after = connB.execute(
        "SELECT COUNT(*) FROM ModerationDecisionAudit WHERE video_id=? AND state_code='age_restricted'",
        (VIDEO_ID,),
    ).fetchone()[0]
    line(f"\nConn B, after A commits (new read txn):")
    line(f"  v_video_current_state(video_id={VIDEO_ID}) = {row_after[0]}   (expect: NEW state)")
    line(f"  ModerationDecisionAudit rows for 'age_restricted' on this video = {audit_after}   (expect 1)")
    connB.execute("COMMIT")

    connA.close()
    connB.close()


# ============================================================================
# T3 — Handle change, twice-a-year rule (fires on the 3rd attempt), plus a
# SQLITE_BUSY demo: attempt a write from a third connection while a writer
# transaction is held open elsewhere.
# ============================================================================

def demo_t3():
    hr("T3 — Handle change: twice-a-year cap, and SQLITE_BUSY under a concurrent writer")

    USER_ID = 4627

    # ---- Part (a): SQLITE_BUSY, while another writer transaction is open ----
    connWriter = connect()
    connWriter.execute("BEGIN IMMEDIATE")  # acquire the write lock now
    connWriter.execute(
        "UPDATE AppUser SET display_name = display_name WHERE user_id = ?", (USER_ID,)
    )
    line("Conn Writer: BEGIN IMMEDIATE; UPDATE AppUser ...  -- write lock held, left open")

    connOther = sqlite3.connect(DB_PATH, isolation_level=None, timeout=0)  # fail immediately, no wait
    connOther.execute("PRAGMA foreign_keys = ON")
    try:
        connOther.execute("BEGIN IMMEDIATE")
        connOther.execute(
            "UPDATE AppUser SET display_name = display_name WHERE user_id = ?", (USER_ID + 1,)
        )
        line("Conn Other:  UPDATE AppUser ... (different row!)  [UNEXPECTED: did not fail]")
        connOther.execute("ROLLBACK")
    except sqlite3.OperationalError as e:
        line(f"Conn Other:  BEGIN IMMEDIATE; UPDATE AppUser ...  -> OperationalError: {e}")
    connOther.close()

    connWriter.execute("COMMIT")
    connWriter.close()
    line("Conn Writer: COMMIT;  -- lock released")

    # ---- Part (b): the twice-a-year cap itself, three attempts ----
    conn = connect()
    original = conn.execute("SELECT handle FROM AppUser WHERE user_id=?", (USER_ID,)).fetchone()[0]
    line(f"\nUser {USER_ID} starting handle: {original!r}")

    handles = [original + "_v1", original + "_v2", original + "_v3"]
    for i, new_handle in enumerate(handles, start=1):
        cur = conn.execute("SELECT handle FROM AppUser WHERE user_id=?", (USER_ID,)).fetchone()[0]
        try:
            conn.execute("BEGIN")
            conn.execute("UPDATE AppUser SET handle=? WHERE user_id=?", (new_handle, USER_ID))
            conn.execute("COMMIT")
            n_log = conn.execute(
                "SELECT COUNT(*) FROM HandleChangeLog WHERE user_id=?", (USER_ID,)
            ).fetchone()[0]
            line(f"Attempt {i}: {cur!r} -> {new_handle!r}   [ok]   (HandleChangeLog rows so far: {n_log})")
        except sqlite3.IntegrityError as e:
            conn.execute("ROLLBACK")
            line(f"Attempt {i}: {cur!r} -> {new_handle!r}   -> IntegrityError: {e}")

    final = conn.execute("SELECT handle FROM AppUser WHERE user_id=?", (USER_ID,)).fetchone()[0]
    log_rows = conn.execute(
        "SELECT log_id, old_handle, new_handle FROM HandleChangeLog WHERE user_id=? ORDER BY log_id",
        (USER_ID,),
    ).fetchall()
    line(f"\nFinal handle on AppUser: {final!r}   (expect: {handles[1]!r} -- the 3rd attempt never applied)")
    line(f"HandleChangeLog rows:    {log_rows}   (expect exactly 2 rows -- the 3rd was rejected before logging)")
    conn.close()


if __name__ == "__main__":
    demo_t1()
    demo_t2()
    demo_t3()
