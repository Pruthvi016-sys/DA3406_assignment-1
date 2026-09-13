# DA3406_assignment-1

## ScrollSense — Assignment 1

## Deliverable E — Physical Implementation

### Prerequisites

- Python 3.9+ (ships with `sqlite3` module — no separate install needed)
- SQLite 3.44+ (check with `python -c "import sqlite3; print(sqlite3.sqlite_version)"`)
- `schema.sql` and `generate_data.py` in the same working directory

### How to run, from an empty database

**1. Create a fresh, empty database file**

```bash
python -c "import sqlite3; sqlite3.connect('scrollsense.db').close()"
```

**2. Apply the schema**

```bash
python -c "import sqlite3; conn = sqlite3.connect('scrollsense.db'); conn.executescript(open('schema.sql').read()); conn.commit(); conn.close(); print('schema applied')"
```

This creates all tables (plus SQLite's internal `sqlite_sequence` bookkeeping table), the lookup tables' seed rows, and all triggers — including the G.3 support objects (`HandleChangeLog` and its two triggers) and the bonus moderation audit log, both of which now ship as part of this same `schema.sql`.

> **Note on tooling:** `schema.sql` was verified to run cleanly via Python's `sqlite3.executescript()` and the official `sqlite3` CLI. **DBeaver's "Execute SQL Script" feature is not used for this step** — DBeaver's script runner splits statements naively on every semicolon, which breaks the `CREATE TRIGGER ... BEGIN ... END;` blocks in this schema (the trigger bodies contain their own internal semicolons before the closing `END;`). This is a limitation of DBeaver's client-side SQL parser, not an error in `schema.sql`. DBeaver is used only afterward, to browse tables and run single-statement queries.

**3. Generate the data**

```bash
python generate_data.py scrollsense.db
```

Seeded with `SEED = 16` (roll number) at the top of `generate_data.py`, so re-running produces identical data. Default volumes: 5,000 users, 20,000 videos, 300,000 impressions, 2,000 agent sessions (`SCALE = 1`). Takes roughly 2 minutes on a typical machine.

Expected console output:

```
users=5000 videos=20000 audio_tracks=670 impressions=300000 view_segments=136752
signals=26948 comments=5342 sessions=2000 turns=4642 tool_calls=7702 recommendations=11707
Loaded scrollsense.db successfully (seed=16, scale=1).
```

**4. Verify the load**

Row counts per table should exactly match the summary line above, e.g.:

```sql
SELECT 'AppUser', COUNT(*) FROM AppUser
UNION ALL SELECT 'Video', COUNT(*) FROM Video
UNION ALL SELECT 'Impression', COUNT(*) FROM Impression
UNION ALL SELECT 'ViewSegment', COUNT(*) FROM ViewSegment
UNION ALL SELECT 'EngagementSignal', COUNT(*) FROM EngagementSignal
UNION ALL SELECT 'AgentSession', COUNT(*) FROM AgentSession
UNION ALL SELECT 'Turn', COUNT(*) FROM Turn;
```

Sanity checks confirming distributions match the brief's requirements:

```sql
-- Duration bound (brief: 20–90 second clips)
SELECT MIN(duration_ms), MAX(duration_ms) FROM Video;
-- Expect: 20000, 90000

-- Signal mix (brief: retraction is a real negative signal, not an absence)
SELECT signal_type, COUNT(*) FROM EngagementSignal GROUP BY signal_type ORDER BY 2 DESC;

-- Funnel leak (brief 2.4: most impressions never become views, most views produce no signal)
SELECT
  (SELECT COUNT(*) FROM Impression)       AS impressions,
  (SELECT COUNT(*) FROM ViewSegment)      AS view_segments,
  (SELECT COUNT(*) FROM EngagementSignal) AS signals;
-- Expect impressions >> view_segments >> signals
```

**5. Constraint enforcement check**

To confirm CHECK/UNIQUE constraints are actually enforced (not just declared):

```sql
PRAGMA foreign_keys = ON;
INSERT INTO Video (owner_id, duration_ms, uploaded_at)
VALUES (1, 5000, '2026-01-01T00:00:00Z');
-- Expect: CHECK constraint failure (duration_ms below 20000 floor)
```

**6. Resetting**

To start over from a clean state, delete `scrollsense.db` and repeat from Step 1.

---

## Deliverable F — Queries

### Prerequisites

- A loaded `scrollsense.db`, built exactly as in Deliverable E above (Steps 1–4). All 13 queries assume the seed-16, scale-1 dataset; row counts quoted in the written report and in `queries.sql`'s inline comments will not match a differently-seeded or differently-scaled database, though the queries themselves are correct against any load.
- `queries.sql` in the same working directory.

### How to run

`queries.sql` contains multi-line prose comments ("Reading: ...", explanatory paragraphs) where only the first line of each paragraph is prefixed with `--`. Because SQL comments only extend to the end of the line they start on, a naive semicolon-splitting parser can misinterpret the un-prefixed continuation lines of these comments as SQL text once a statement boundary falls in the middle of one, producing spurious syntax errors on queries that are otherwise correct. DBeaver's `Ctrl+Enter` (Execute SQL Statement) finds true statement boundaries and does not suffer from this issue, so it is the only method used to run `queries.sql`.

#### DBeaver

1. Connect DBeaver to the **same** `scrollsense.db` file built in Deliverable E (not a new file DBeaver creates itself).
2. Confirm the driver's SQLite engine version before trusting any result — open a SQL Editor on this connection and run:
   ```sql
   SELECT sqlite_version();
   ```
   Expect `3.44.0` or higher (needed for F8's `group_concat(... ORDER BY ...)`).
3. Set foreign keys on for the session (this is per-connection, not saved from the terminal build):
   ```sql
   PRAGMA foreign_keys = ON;
   ```
4. Open `queries.sql` in a SQL Editor tab (`File → Open File`, or paste its contents in).
5. Run **one query at a time**: click anywhere inside a single query block, then press **`Ctrl+Enter`** (Execute SQL Statement) — **not** `Alt+X` / "Execute SQL Script". `Alt+X` naively splits on every semicolon and will not report each query's own runtime separately.
6. After each run, read the wall-clock time off the **Statistics** tab next to the results grid — this is the runtime to record, not a stopwatch guess.
7. For row counts, do **not** trust the grid's "N rows fetched" footer once a result is large — DBeaver fetches in batches of 200, so that label is the batch size, not the true total. Instead, run the same query wrapped as its own statement:
   ```sql
   SELECT COUNT(*) FROM (
       <paste the query here, without its trailing semicolon>
   );
   ```
   and read that single number back.

### A note on reproducibility

No query in `queries.sql` calls `date('now')`. The generator fixes its data window at `WINDOW_END = 2026-09-12` (`generate_data.py`, line ~48) regardless of the wall-clock date the script is actually run on. Any query needing "last 7 days" (F1) or "last month" (F7) anchors instead to `MAX(timestamp)` of the relevant table — `MAX(Video.uploaded_at)` for F1, `MAX(Turn.created_at)` for F7 — so the results below are exactly reproducible on any future rerun of this exact seed, on any date. Every query also carries an explicit `ORDER BY`, so "first five rows" is deterministic rather than depending on SQLite's unspecified default row order.

### Queries F1–F13 — quick index

| # | Query | Key technique |
|---|---|---|
| F1 | Top 10 audio tracks by distinct videos, last 7 days | window anchored to `MAX(uploaded_at)`, not `date('now')` |
| F2 | Watch hours + mean completion per creator, live clips only, every creator appears | latest-moderation-decision resolution, `LEFT JOIN` from `CreatorTierPeriod` |
| F3 | Videos with no audio track — `NOT IN` vs `NOT EXISTS` | three-valued-logic trap (0 rows vs 14,636) |
| F4 | Like → retraction within 60s | `ROW_NUMBER()` pairing nearest preceding like |
| F5 | Caption hashtag search, case/punctuation tolerant | `lower()`/`replace()`/`instr()`, no `REGEXP` |
| F6 | Shown-but-never-engaged, via `EXCEPT`; `UNION` vs `UNION ALL` roll-up | set operators |
| F7 | Session cost last month by template version, thresholded | range join on `ModelPricePeriod` validity intervals |
| F8 | Videos with >2 real moderation transitions | `LAG()` de-duplication + `group_concat(... ORDER BY ...)` |
| F9 | Longest streak of consecutive active days per user | gaps-and-islands |
| F10 | 7-day rolling watch time per creator, ranked, week-over-week | `RANGE` frame on `julianday()`, exact-date self-join |
| F11 | Full tool-call nesting tree with depth | `WITH RECURSIVE` |
| F12 | Recommended clip watched to completion, with shelf position | `EXISTS` + `MAX(segment_end_ms)`, never `COUNT` |
| F13 | Judge score >4 but thumbs-down | latest-row resolution on two append-only logs |

---

## Deliverable G — Views and Transactions

### Prerequisites

- A loaded `scrollsense.db`, built exactly as in Deliverable E above.
- `views.sql` and `transactions.sql` in the same working directory.
- For the T2 and T3 concurrency demonstrations only: `run_transactions_demo.py` in the same working directory (Python's `sqlite3` module, stdlib only — no extra install).

### G.1 — Loading the views

```bash
python -c "
import sqlite3
conn = sqlite3.connect('scrollsense.db')
conn.execute('PRAGMA foreign_keys = ON')
conn.executescript(open('views.sql').read())
conn.commit()
print('views applied')
"
```

Sanity check — every view should return a nonzero row count, and the counts below are exactly reproducible against the seed-16 build:

```sql
SELECT 'v_public_profile', COUNT(*) FROM v_public_profile
UNION ALL SELECT 'v_video_current_state', COUNT(*) FROM v_video_current_state
UNION ALL SELECT 'v_creator_tier_current', COUNT(*) FROM v_creator_tier_current
UNION ALL SELECT 'v_video_daily_engagement', COUNT(*) FROM v_video_daily_engagement
UNION ALL SELECT 'v_turn_cost', COUNT(*) FROM v_turn_cost;
-- Expect: 4515, 20000, 750, 222393, 4642
```

`v_public_profile` returns 4,515 of the 5,000 `AppUser` rows — the other 485 are deactivated or inside their 30-day deletion window, and the view is filtering them out exactly as G.1 requires (verify with `SELECT COUNT(*) FROM AccountStatusPeriod WHERE valid_to IS NULL AND status <> 'active'` — matches 485).

DBeaver can browse and query all five views normally once loaded — no `Alt+X` caveat applies here since `views.sql` is `CREATE VIEW` statements only, none of which contain internal semicolons the way the trigger bodies in `schema.sql` do.

### G.2 — Written answers (updatability, the as-of problem)

No commands to run — G.2(a)'s exact SQLite error text and G.2(b)'s reasoning are both in the written report. The error in G.2(a) can be reproduced directly:

**On Windows PowerShell**, `\"`-escaped double quotes inside a `python -c "..."` block are parsed differently than in bash and will fail with a `Missing argument in parameter list` error. Use single quotes around the Python block instead, with doubled single-quotes (`''`) for the literal string values inside the SQL:

```powershell
python -c "
import sqlite3
conn = sqlite3.connect('scrollsense.db')
try:
    conn.execute('INSERT INTO v_public_profile (user_id, handle, display_name, follower_count) VALUES (99999, ''x'', ''X'', 0)')
except sqlite3.OperationalError as e:
    print('OperationalError:', e)
"
```

**On bash/macOS/Linux**, the original form works as-is:

```bash
python -c "
import sqlite3
conn = sqlite3.connect('scrollsense.db')
try:
    conn.execute(\"INSERT INTO v_public_profile (user_id, handle, display_name, follower_count) VALUES (99999, 'x', 'X', 0)\")
except sqlite3.OperationalError as e:
    print('OperationalError:', e)
"
```

Expected output (either shell): `OperationalError: cannot modify v_public_profile because it is a view`.

### G.3 — Running the transaction demonstrations

**T1** (single connection — `Block` breaks `Follow`, rolled back by a real constraint violation) is run in DBeaver: paste the T1 section of `transactions.sql` (from `BEGIN;` down through the final `SELECT follower_id, followee_id, ended_at FROM Follow ...` proof query) into a SQL Editor tab, and execute it **statement-by-statement with `Ctrl+Enter`** — **not** `Alt+X`.

`transactions.sql`, like `queries.sql`, contains multi-line prose comments where only the first line of each paragraph is prefixed with `--`. A naive semicolon-splitting parser (e.g. a `for stmt in open(...).read().split(';')` loop) can misinterpret the un-prefixed continuation lines as SQL text once a statement boundary falls in the middle of one, producing a spurious `unrecognized token` or syntax error rather than executing T1's actual statements. DBeaver's `Ctrl+Enter` finds true statement boundaries and does not suffer from this issue, so it is the method used for T1.

**T2** and **T3** need two and three simultaneous connections respectively, to demonstrate: (a) WAL-mode reader isolation — a second connection cannot see a first connection's uncommitted write — and (b) `SQLITE_BUSY` when a second writer attempts to write while a first writer's transaction is still open. Run:

```bash
python run_transactions_demo.py scrollsense.db
```

This executes exactly the statements documented in `transactions.sql`'s T2 and T3 sections, opening the connections explicitly, and prints the real proof output for both — reproduced verbatim in the written report. Because T2 and T3 make committed writes (a moderation decision on video 1, a handle change on user 4627), running this script advances `scrollsense.db`'s state; re-running it a second time against the same file will not reproduce identical `HandleChangeLog` counts (the cap will already have been reached from the previous run) — reset to a fresh load (Deliverable E, Step 6) first if you need a clean re-run.

DBeaver was not used for T2/T3: DBeaver's SQL Editor holds one connection per tab, but demonstrating cross-connection isolation needs two tabs **explicitly bound to two independent `Connection` objects** (not two editors sharing one connection, which DBeaver defaults to) with manual transaction control (`Auto-commit` toggled off) on each — achievable, but far more fragile to describe reproducibly in a README than two `sqlite3.connect()` calls in one script, so the script is the documented path here.
