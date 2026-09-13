#!/usr/bin/env python3
"""
ScrollSense · Assignment 1 · Deliverable E.3 — generate_data.py

Populates a fresh ScrollSense SQLite database (schema.sql must already have
been applied) with synthetic-but-plausible data.

Usage:
    python3 generate_data.py [path/to/database.db]

Distributions modelled (per E.3):
  - follower counts:      power-law (Zipf-weighted preferential attachment)
  - watch time:            right-skewed (lognormal)
  - daily activity rhythm: hour-of-day weighted, peaking in the evening
  - the funnel:            most impressions -> no view; most views -> no signal

Stdlib only (random, math, datetime, sqlite3) — no third-party dependencies,
so it runs anywhere Python 3 + SQLite 3.44+ does.
"""

import random
import math
import sqlite3
import sys
import json
from datetime import datetime, timedelta

# ---- parameters (Assignment 2 will change only this block) ----
SEED = 16              # roll number
N_USERS = 5_000
N_VIDEOS = 20_000
N_IMPRESSIONS = 300_000
N_AGENT_SESSIONS = 2_000
SCALE = 1              # A2: set to 50
# -----------------------------------------------------------------

N_USERS *= SCALE
N_VIDEOS *= SCALE
N_IMPRESSIONS *= SCALE
N_AGENT_SESSIONS *= SCALE

random.seed(SEED)

DB_PATH = sys.argv[1] if len(sys.argv) > 1 else "scrollsense.db"

# Window: 60 days of history ending "now" (kept fixed so the dataset is
# reproducible across runs with the same seed, independent of wall-clock time).
WINDOW_END = datetime(2026, 9, 12, 0, 0, 0)
WINDOW_START = WINDOW_END - timedelta(days=60)
TOTAL_WINDOW_SECONDS = int((WINDOW_END - WINDOW_START).total_seconds())

# Hour-of-day activity weights: low overnight, ramps up through the day,
# peaks in the evening (19:00-23:00) — a plausible short-video usage rhythm.
HOUR_WEIGHTS = [1, 1, 1, 1, 1, 1, 2, 3, 4, 4, 4, 5,
                5, 5, 5, 5, 6, 7, 9, 10, 10, 9, 6, 3]


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def random_timestamp(start: datetime = WINDOW_START, end: datetime = WINDOW_END) -> datetime:
    """Uniform-over-days, but hour-of-day is weighted for a daily rhythm."""
    span_days = max(1, (end - start).days)
    day_offset = random.randint(0, span_days - 1)
    hour = random.choices(range(24), weights=HOUR_WEIGHTS, k=1)[0]
    minute = random.randint(0, 59)
    second = random.randint(0, 59)
    return start + timedelta(days=day_offset, hours=hour, minutes=minute, seconds=second)


def lognormal_ms(median_ms: float, sigma: float, lo: int, hi: int) -> int:
    """Right-skewed duration in ms, clamped to [lo, hi]."""
    val = random.lognormvariate(math.log(median_ms), sigma)
    return int(min(max(val, lo), hi))


def zipf_weight(rank: int, s: float = 1.3) -> float:
    return 1.0 / (rank ** s)


def main():
    con = sqlite3.connect(DB_PATH, isolation_level=None)
    con.execute("PRAGMA foreign_keys = ON;")
    con.execute("PRAGMA journal_mode = WAL;")

    # Confirm the two lookup tables were seeded by schema.sql before we start.
    n_states = con.execute("SELECT COUNT(*) FROM ModerationState").fetchone()[0]
    n_tiers = con.execute("SELECT COUNT(*) FROM Tier").fetchone()[0]
    if n_states == 0 or n_tiers == 0:
        sys.exit("schema.sql must be applied (with its seed rows) before running generate_data.py")

    con.execute("BEGIN;")
    try:
        populate(con)
        con.execute("COMMIT;")
        print(f"Loaded {DB_PATH} successfully (seed={SEED}, scale={SCALE}).")
    except Exception:
        con.execute("ROLLBACK;")
        raise
    finally:
        con.close()


def populate(con: sqlite3.Connection):
    # ---------------------------------------------------------------
    # 1. AppUser
    # ---------------------------------------------------------------
    handles = set()
    users = []  # (handle, display_name, created_at)
    while len(users) < N_USERS:
        h = f"user_{random.randint(100000,999999)}_{len(users)}"
        if h.lower() in handles:
            continue
        handles.add(h.lower())
        created = random_timestamp(WINDOW_START - timedelta(days=200), WINDOW_END)
        users.append((h, h.replace("_", " ").title(), iso(created)))

    con.executemany(
        "INSERT INTO AppUser(handle, display_name, created_at) VALUES (?,?,?)",
        users,
    )
    user_ids = [row[0] for row in con.execute("SELECT user_id FROM AppUser ORDER BY user_id")]

    # Zipf popularity weight per user, used for both follower power-law and
    # for impression targeting (popular creators get shown more).
    ranked = list(range(1, len(user_ids) + 1))
    random.shuffle(ranked)
    popularity = {uid: zipf_weight(rank) for uid, rank in zip(user_ids, ranked)}

    # ---------------------------------------------------------------
    # 2. UserIdentity
    # ---------------------------------------------------------------
    identities = []
    for uid in user_ids:
        roll = random.random()
        if roll < 0.55:
            identities.append((uid, "phone", f"+91{random.randint(6000000000,9999999999)}",
                                iso(random_timestamp())))
        elif roll < 0.9:
            identities.append((uid, "google", f"user{uid}.{random.randint(1000,9999)}@gmail.com",
                                iso(random_timestamp())))
        else:
            identities.append((uid, "phone", f"+91{random.randint(6000000000,9999999999)}",
                                iso(random_timestamp())))
            identities.append((uid, "google", f"user{uid}.{random.randint(1000,9999)}@gmail.com",
                                iso(random_timestamp())))
    con.executemany(
        "INSERT INTO UserIdentity(user_id, identity_type, credential, linked_at) VALUES (?,?,?,?)",
        identities,
    )

    # ---------------------------------------------------------------
    # 3/4. Declared + Inferred interests
    # ---------------------------------------------------------------
    categories = ["comedy", "sports", "music", "food", "gaming", "study_tips",
                  "fashion", "pets", "travel", "finance", "dance", "movies"]
    declared, inferred = [], []
    for uid in user_ids:
        for cat in random.sample(categories, k=random.randint(1, 4)):
            declared.append((uid, cat, iso(random_timestamp())))
        for cat in random.sample(categories, k=random.randint(1, 5)):
            declared_cats = {d[1] for d in declared if d[0] == uid}
            conf = round(random.betavariate(2, 3), 3)
            suppressed = 1 if random.random() < 0.08 else 0
            inferred.append((uid, cat, conf, iso(random_timestamp()), suppressed))
    con.executemany(
        "INSERT INTO DeclaredInterest(user_id, category, declared_at) VALUES (?,?,?)",
        declared,
    )
    con.executemany(
        "INSERT OR IGNORE INTO InferredInterest(user_id, category, confidence, refreshed_at, suppressed) "
        "VALUES (?,?,?,?,?)",
        inferred,
    )

    # ---------------------------------------------------------------
    # 5. AccountStatusPeriod (mostly active; a few deactivated / pending_deletion)
    # ---------------------------------------------------------------
    status_rows = []
    for uid, (h, dn, created_at) in zip(user_ids, users):
        start = created_at
        roll = random.random()
        if roll < 0.90:
            status_rows.append((uid, start, "active", None))
        elif roll < 0.96:
            change_at = iso(random_timestamp(datetime.fromisoformat(start.replace("Z", "")), WINDOW_END))
            status_rows.append((uid, start, "active", change_at))
            status_rows.append((uid, change_at, "deactivated", None))
        else:
            change_at = iso(random_timestamp(datetime.fromisoformat(start.replace("Z", "")), WINDOW_END))
            status_rows.append((uid, start, "active", change_at))
            status_rows.append((uid, change_at, "pending_deletion", None))
    con.executemany(
        "INSERT INTO AccountStatusPeriod(user_id, valid_from, status, valid_to) VALUES (?,?,?,?)",
        status_rows,
    )

    # ---------------------------------------------------------------
    # 6. Creators + CreatorTierPeriod history
    # ---------------------------------------------------------------
    creator_ids = random.sample(user_ids, k=max(1, int(0.15 * len(user_ids))))
    tier_ladder = ["none", "bronze", "silver", "gold", "partner"]
    tier_rows = []
    for uid in creator_ids:
        n_steps = random.choices([1, 2, 3], weights=[50, 35, 15])[0]
        start = random_timestamp(WINDOW_START - timedelta(days=200), WINDOW_START)
        cur = start
        for step in range(n_steps):
            tier = tier_ladder[min(step, len(tier_ladder) - 1)]
            is_last = step == n_steps - 1
            if is_last:
                tier_rows.append((uid, iso(cur), tier, None))
            else:
                nxt = cur + timedelta(days=random.randint(20, 90))
                if nxt >= WINDOW_END:
                    tier_rows.append((uid, iso(cur), tier, None))
                    break
                tier_rows.append((uid, iso(cur), tier, iso(nxt)))
                cur = nxt
    con.executemany(
        "INSERT INTO CreatorTierPeriod(user_id, valid_from, tier_code, valid_to) VALUES (?,?,?,?)",
        tier_rows,
    )
    creator_ids_set = set(creator_ids)

    # ---------------------------------------------------------------
    # 7. Follow (power-law follower counts via popularity-weighted sampling)
    # ---------------------------------------------------------------
    follow_pairs = set()
    follows = []
    weights = [popularity[uid] for uid in user_ids]
    n_follow_edges = int(len(user_ids) * 6)  # ~6 follows per user on average
    attempts = 0
    while len(follows) < n_follow_edges and attempts < n_follow_edges * 4:
        attempts += 1
        follower = random.choice(user_ids)
        followee = random.choices(user_ids, weights=weights, k=1)[0]
        if follower == followee or (follower, followee) in follow_pairs:
            continue
        follow_pairs.add((follower, followee))
        started = random_timestamp()
        ended = None
        if random.random() < 0.08:
            ended = iso(random_timestamp(started, WINDOW_END))
        follows.append((follower, followee, iso(started), ended))
    con.executemany(
        "INSERT INTO Follow(follower_id, followee_id, started_at, ended_at) VALUES (?,?,?,?)",
        follows,
    )

    # ---------------------------------------------------------------
    # 8. Block / Mute
    # ---------------------------------------------------------------
    blocks, mutes = [], []
    block_pairs, mute_pairs = set(), set()
    for _ in range(int(len(user_ids) * 0.02)):
        a, b = random.sample(user_ids, 2)
        if (a, b) not in block_pairs:
            block_pairs.add((a, b))
            blocks.append((a, b, iso(random_timestamp())))
    for _ in range(int(len(user_ids) * 0.05)):
        a, b = random.sample(user_ids, 2)
        if (a, b) not in mute_pairs:
            mute_pairs.add((a, b))
            mutes.append((a, b, iso(random_timestamp())))
    con.executemany("INSERT INTO Block(blocker_id, blocked_id, blocked_at) VALUES (?,?,?)", blocks)
    con.executemany("INSERT INTO Mute(muter_id, muted_id, muted_at) VALUES (?,?,?)", mutes)

    # ---------------------------------------------------------------
    # 9/10. Model + ModelPricePeriod (prices step up over the window,
    # so a query restricted to "last month" must resolve against the
    # period in force then, not the current one)
    # ---------------------------------------------------------------
    model_specs = [
        ("gpt-4o-mini", [(0.00015, 0.0006, 0.000075), (0.00018, 0.00065, 0.00008)]),
        ("llama-3.1-70b", [(0.0, 0.0, 0.0)]),  # self-hosted, zero marginal rate
        ("scrollsense-ft-v3", [(0.00005, 0.0002, 0.000025), (0.00006, 0.00022, 0.00003)]),
    ]
    con.executemany("INSERT INTO Model(model_name) VALUES (?)",
                     [(m[0],) for m in model_specs])
    model_ids = {row[1]: row[0] for row in
                 con.execute("SELECT model_id, model_name FROM Model")}
    price_rows = []
    for name, price_steps in model_specs:
        mid = model_ids[name]
        n = len(price_steps)
        cur = WINDOW_START - timedelta(days=90)
        for i, (ir, orr, cr) in enumerate(price_steps):
            is_last = i == n - 1
            if is_last:
                price_rows.append((mid, iso(cur), ir, orr, cr, None))
            else:
                nxt = cur + timedelta(days=random.randint(30, 60))
                price_rows.append((mid, iso(cur), ir, orr, cr, iso(nxt)))
                cur = nxt
    con.executemany(
        "INSERT INTO ModelPricePeriod(model_id, effective_from, input_rate, output_rate, cached_rate, effective_to) "
        "VALUES (?,?,?,?,?,?)",
        price_rows,
    )

    # ---------------------------------------------------------------
    # 11. Video + AudioTrack (mutual-FK pair, populated together)
    # ---------------------------------------------------------------
    videos = []  # (owner_id, duration_ms, caption, uploaded_at)
    hashtag_pool = ["#catsofscrollsense", "#study", "#fitcheck", "#travelvibes",
                     "#homecooking", "#gymtok", "#comedyskit", "#exampreptips"]
    for _ in range(N_VIDEOS):
        owner = random.choices(user_ids, weights=weights, k=1)[0]
        dur = lognormal_ms(35000, 0.35, 20000, 90000)
        n_tags = random.randint(0, 3)
        caption = " ".join(random.sample(hashtag_pool, k=n_tags)) if n_tags else "no caption today"
        # deliberately messy case, to exercise F5's case-insensitive matching
        if random.random() < 0.3:
            caption = caption.upper()
        uploaded = random_timestamp()
        videos.append((owner, dur, caption, iso(uploaded)))
    con.executemany(
        "INSERT INTO Video(owner_id, duration_ms, caption, uploaded_at) VALUES (?,?,?,?)",
        videos,
    )
    video_ids = [row[0] for row in con.execute("SELECT video_id FROM Video ORDER BY video_id")]

    # ~55% of videos have no audio track at all
    no_track_video_ids = set(random.sample(video_ids, k=int(0.55 * len(video_ids))))

    # A handful of videos become the *original* of a track; one of those
    # tracks is deliberately made "trending" and reused by many other clips.
    remaining = [v for v in video_ids if v not in no_track_video_ids]
    n_original_tracks = max(1, int(0.03 * len(remaining)))
    original_video_choices = random.sample(remaining, k=n_original_tracks)

    audio_track_rows = []
    for vid in original_video_choices:
        audio_track_rows.append(("original", vid, iso(random_timestamp())))
    n_licensed = max(1, int(0.02 * len(video_ids)))
    for _ in range(n_licensed):
        audio_track_rows.append(("licensed", None, iso(random_timestamp())))

    con.executemany(
        "INSERT INTO AudioTrack(source_type, original_video_id, added_at) VALUES (?,?,?)",
        audio_track_rows,
    )
    track_ids = [row[0] for row in con.execute("SELECT track_id FROM AudioTrack ORDER BY track_id")]
    trending_track_id = track_ids[0] if track_ids else None

    # Assign audio_track_id back onto Video: the original creator's own
    # video keeps using its own track; the trending track is borrowed by a
    # large slice of the remaining eligible videos; everyone else keeps NULL.
    updates = []
    orig_track_by_video = {}
    cur_track_idx = 0
    for vid in original_video_choices:
        orig_track_by_video[vid] = track_ids[cur_track_idx]
        cur_track_idx += 1
    for vid in original_video_choices:
        updates.append((orig_track_by_video[vid], vid))

    borrow_pool = [v for v in remaining if v not in orig_track_by_video]
    n_borrow_trending = int(0.4 * len(borrow_pool))
    for vid in random.sample(borrow_pool, k=n_borrow_trending):
        updates.append((trending_track_id, vid))
    remaining_licensed_tracks = track_ids[n_original_tracks:]
    other_borrowers = [v for v in borrow_pool if v not in set(u[1] for u in updates)]
    for vid in other_borrowers:
        if random.random() < 0.3 and remaining_licensed_tracks:
            updates.append((random.choice(remaining_licensed_tracks), vid))

    con.executemany("UPDATE Video SET audio_track_id = ? WHERE video_id = ?", updates)

    # ---------------------------------------------------------------
    # 12. ModerationDecision (append-only history per video)
    # ---------------------------------------------------------------
    decisions = []
    for vid, (owner, dur, caption, uploaded_at) in zip(video_ids, videos):
        t = datetime.fromisoformat(uploaded_at.replace("Z", ""))
        t = t + timedelta(minutes=random.randint(1, 30))
        decisions.append((vid, "pending", iso(t), "classifier", None))
        roll = random.random()
        if roll < 0.80:
            t = t + timedelta(minutes=random.randint(1, 60))
            decisions.append((vid, "live", iso(t), "classifier", None))
            if random.random() < 0.10:
                t = t + timedelta(hours=random.randint(1, 72))
                decisions.append((vid, random.choice(["demoted", "age_restricted"]),
                                   iso(t), "human", random.randint(1, 50)))
                if random.random() < 0.4:
                    t = t + timedelta(hours=random.randint(1, 48))
                    decisions.append((vid, "live", iso(t), "human", random.randint(1, 50)))
        elif roll < 0.93:
            t = t + timedelta(minutes=random.randint(1, 60))
            decisions.append((vid, "live", iso(t), "classifier", None))
        else:
            t = t + timedelta(minutes=random.randint(1, 120))
            decisions.append((vid, "taken_down", iso(t), "human", random.randint(1, 50)))
    con.executemany(
        "INSERT INTO ModerationDecision(video_id, state_code, decided_at, decider_type, decider_id) "
        "VALUES (?,?,?,?,?)",
        decisions,
    )

    # ---------------------------------------------------------------
    # 13. Agent layer: AgentSession -> Turn -> ToolCall / JudgeScore /
    #     UserRating / Recommendation / TurnUsage  (built before Impression
    #     so a fraction of impressions can be traced back to a real
    #     recommendation, per B.3 #3)
    # ---------------------------------------------------------------
    templates = []
    for tpl_id in range(1, 4):
        n_versions = random.randint(2, 5)
        for v in range(1, n_versions + 1):
            templates.append((tpl_id, v, f"[template {tpl_id} v{v} system prompt text]",
                               iso(random_timestamp(WINDOW_START - timedelta(days=120), WINDOW_END))))
    con.executemany(
        "INSERT INTO PromptTemplate(template_id, version, template_text, created_at) VALUES (?,?,?,?)",
        templates,
    )
    max_version = {}
    for tpl_id, v, _, _ in templates:
        max_version[tpl_id] = max(max_version.get(tpl_id, 0), v)
    template_ids = list(max_version.keys())

    sessions = []
    for _ in range(N_AGENT_SESSIONS):
        uid = random.choice(user_ids)
        started = random_timestamp()
        ended = started + timedelta(minutes=random.randint(1, 20))
        sessions.append((uid, iso(started), iso(ended)))
    con.executemany(
        "INSERT INTO AgentSession(user_id, started_at, ended_at) VALUES (?,?,?)",
        sessions,
    )
    session_rows = list(con.execute("SELECT session_id, user_id, started_at FROM AgentSession"))

    turns, turn_usages, tool_calls, judge_scores, user_ratings, recommendations = [], [], [], [], [], []
    model_names = list(model_ids.keys())

    for session_id, uid, started_at in session_rows:
        n_turns = random.choices([1, 2, 3, 4, 5], weights=[35, 30, 15, 12, 8])[0]
        t = datetime.fromisoformat(started_at.replace("Z", ""))
        for seq in range(1, n_turns + 1):
            t = t + timedelta(seconds=random.randint(5, 90))
            tpl_id = random.choice(template_ids)
            tpl_version = random.randint(1, max_version[tpl_id])
            model_name = random.choice(model_names)
            model_id = model_ids[model_name]
            temperature = round(random.uniform(0.0, 1.0), 2)
            turns.append((session_id, seq, "find me that clip about the cat that thinks it's a dog",
                          "Here are a few clips that might match.", tpl_id, tpl_version,
                          model_id, temperature, iso(t)))

            in_tok = random.randint(50, 800)
            out_tok = random.randint(30, 500)
            cached_tok = random.randint(0, min(in_tok, 200))
            turn_usages.append((session_id, seq, in_tok, out_tok, cached_tok))

            # 0-3 tool calls per turn, occasionally nested one level deep
            n_calls = random.choices([0, 1, 2, 3], weights=[15, 40, 30, 15])[0]
            for _ in range(n_calls):
                tool_name = random.choice(["search_videos", "get_user_history", "fetch_trending_audio"])
                args = json.dumps({"query": "cat dog", "region": "IN"}) if tool_name == "fetch_trending_audio" \
                    else json.dumps({"query": "funny cat", "filters": {"safe": True}})
                errored = 1 if random.random() < 0.03 else 0
                tool_calls.append([session_id, seq, None, tool_name, args,
                                    None if errored else json.dumps({"result_count": random.randint(0, 20)}),
                                    random.randint(20, 900), errored, iso(t)])

            if random.random() < 0.25:  # ~25% of turns get an LLM judge score
                judge_scores.append((session_id, seq, "judge-v1",
                                      round(random.uniform(0, 5), 2),
                                      round(random.uniform(0, 5), 2),
                                      round(random.uniform(0, 5), 2),
                                      iso(t + timedelta(seconds=random.randint(1, 30)))))
            if random.random() < 0.06:  # very few turns get a user rating
                user_ratings.append((session_id, seq, random.choice([-1, 1]),
                                      iso(t + timedelta(seconds=random.randint(1, 120)))))

            n_recs = random.randint(0, 5)
            shown_videos = random.sample(video_ids, k=min(n_recs, len(video_ids)))
            for pos, vid in enumerate(shown_videos, start=1):
                recommendations.append((session_id, seq, pos, vid))

    con.executemany(
        "INSERT INTO Turn(session_id, sequence_no, user_message, assistant_message, template_id, "
        "template_version, model_id, temperature, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
        turns,
    )
    con.executemany(
        "INSERT INTO TurnUsage(session_id, sequence_no, input_tokens, output_tokens, cached_tokens) "
        "VALUES (?,?,?,?,?)",
        turn_usages,
    )
    con.executemany(
        "INSERT INTO ToolCall(session_id, sequence_no, parent_tool_call_id, tool_name, arguments_json, "
        "result, latency_ms, errored, called_at) VALUES (?,?,?,?,?,?,?,?,?)",
        tool_calls,
    )
    # A light pass of nesting: give ~15% of top-level calls a synthetic child
    top_level_calls = list(con.execute(
        "SELECT tool_call_id, session_id, sequence_no, called_at FROM ToolCall"))
    nested = []
    for tool_call_id, session_id, seq, called_at in top_level_calls:
        if random.random() < 0.15:
            t = datetime.fromisoformat(called_at.replace("Z", "")) + timedelta(milliseconds=random.randint(5, 200))
            nested.append((session_id, seq, tool_call_id, "search_videos",
                            json.dumps({"query": "sub-call refine"}),
                            json.dumps({"result_count": random.randint(0, 10)}),
                            random.randint(10, 300), 0, iso(t)))
    con.executemany(
        "INSERT INTO ToolCall(session_id, sequence_no, parent_tool_call_id, tool_name, arguments_json, "
        "result, latency_ms, errored, called_at) VALUES (?,?,?,?,?,?,?,?,?)",
        nested,
    )
    con.executemany(
        "INSERT INTO JudgeScore(session_id, sequence_no, judge_model_version, helpfulness, groundedness, "
        "safety, judged_at) VALUES (?,?,?,?,?,?,?)",
        judge_scores,
    )
    con.executemany(
        "INSERT INTO UserRating(session_id, sequence_no, thumbs, rated_at) VALUES (?,?,?,?)",
        user_ratings,
    )
    con.executemany(
        "INSERT INTO Recommendation(session_id, sequence_no, position, video_id) VALUES (?,?,?,?)",
        recommendations,
    )
    recommendation_rows = list(con.execute(
        "SELECT r.recommendation_id, r.video_id, t.session_id, t.sequence_no, t.created_at, s.user_id "
        "FROM Recommendation r "
        "JOIN Turn t ON t.session_id = r.session_id AND t.sequence_no = r.sequence_no "
        "JOIN AgentSession s ON s.session_id = t.session_id"
    ))

    # ---------------------------------------------------------------
    # 14. Impression — the high-volume core. ~8% are traced back to a real
    # Recommendation (the "critical link" in the brief); the rest are
    # organic feed entries. Popular videos get shown more (weights).
    # ---------------------------------------------------------------
    impressions = []  # (user_id, video_id, occurred_at, feed_position, model_version, source_recommendation_id)
    video_weight_by_id = {}
    owner_by_video = {vid: owner for vid, (owner, *_rest) in zip(video_ids, videos)}
    for vid in video_ids:
        video_weight_by_id[vid] = popularity[owner_by_video[vid]]
    video_weights = [video_weight_by_id[v] for v in video_ids]

    n_sourced = int(0.08 * N_IMPRESSIONS)
    for _ in range(n_sourced):
        rec_id, vid, sess_id, seq, created_at, uid = random.choice(recommendation_rows)
        t = datetime.fromisoformat(created_at.replace("Z", "")) + timedelta(seconds=random.randint(1, 300))
        impressions.append((uid, vid, iso(t), random.randint(1, 10),
                             f"ranker-v{random.randint(10,16)}", rec_id))

    n_organic = N_IMPRESSIONS - n_sourced
    for _ in range(n_organic):
        uid = random.choice(user_ids)
        vid = random.choices(video_ids, weights=video_weights, k=1)[0]
        t = random_timestamp()
        impressions.append((uid, vid, iso(t), random.randint(0, 40),
                             f"ranker-v{random.randint(10,16)}", None))

    con.executemany(
        "INSERT INTO Impression(user_id, video_id, occurred_at, feed_position, model_version, "
        "source_recommendation_id) VALUES (?,?,?,?,?,?)",
        impressions,
    )
    impression_rows = list(con.execute(
        "SELECT impression_id, user_id, video_id, occurred_at FROM Impression"))

    duration_by_video = {vid: videos[i][1] for i, vid in enumerate(video_ids)}

    # ---------------------------------------------------------------
    # 15. ViewSegment — funnel stage 1: most impressions never become a view
    # ---------------------------------------------------------------
    view_segments = []
    viewed_impressions = []  # (impression_id, user_id, video_id, occurred_at)
    for impression_id, uid, vid, occurred_at in impression_rows:
        if random.random() >= 0.35:   # 65% of impressions never become a view
            continue
        viewed_impressions.append((impression_id, uid, vid, occurred_at))
        n_segments = random.choices([1, 2, 3], weights=[75, 20, 5])[0]
        dur = duration_by_video[vid]
        cursor = 0
        for seg_id in range(1, n_segments + 1):
            watch_len = lognormal_ms(min(dur, 8000), 0.7, 300, dur + int(0.4 * dur))
            start_ms = cursor
            end_ms = start_ms + watch_len
            view_segments.append((impression_id, seg_id, start_ms, end_ms))
            cursor = end_ms if random.random() < 0.3 else 0  # sometimes loops back to 0
    con.executemany(
        "INSERT INTO ViewSegment(impression_id, segment_id, segment_start_ms, segment_end_ms) VALUES (?,?,?,?)",
        view_segments,
    )

    # ---------------------------------------------------------------
    # 16. EngagementSignal — funnel stage 2: most views produce no signal.
    # A deliberate slice of like -> like_retraction pairs within 60s (F4),
    # and a deliberate slice of >60s apart, so F4's query has both to sort.
    # ---------------------------------------------------------------
    signals = []
    destinations = ["whatsapp", "instagram", "copied_link"]
    for impression_id, uid, vid, occurred_at in viewed_impressions:
        if random.random() >= 0.22:    # ~78% of views produce no explicit signal
            continue
        t0 = datetime.fromisoformat(occurred_at.replace("Z", "")) + timedelta(seconds=random.randint(1, 60))
        signal_type = random.choices(
            ["like", "save", "share", "follow_from_feed", "not_interested", "report"],
            weights=[55, 12, 10, 8, 12, 3],
        )[0]
        if signal_type == "share":
            signals.append((uid, vid, "share", iso(t0), random.choice(destinations)))
        else:
            signals.append((uid, vid, signal_type, iso(t0), None))

        if signal_type == "like" and random.random() < 0.30:
            # deliberate retraction: ~half within 60s (F4 target), half later
            if random.random() < 0.5:
                gap = timedelta(seconds=random.randint(2, 55))
            else:
                gap = timedelta(seconds=random.randint(120, 3600))
            signals.append((uid, vid, "like_retraction", iso(t0 + gap), None))

    con.executemany(
        "INSERT INTO EngagementSignal(user_id, video_id, signal_type, occurred_at, destination) "
        "VALUES (?,?,?,?,?)",
        signals,
    )

    # ---------------------------------------------------------------
    # 17. Comment — a further, smaller slice of viewed impressions
    # ---------------------------------------------------------------
    comment_bodies = ["lol this is amazing", "wait what breed is that", "sending to my group chat",
                       "underrated creator ngl", "the editing here is so clean", "need part 2 asap"]
    comments = []
    for impression_id, uid, vid, occurred_at in viewed_impressions:
        if random.random() >= 0.05:
            continue
        t0 = datetime.fromisoformat(occurred_at.replace("Z", "")) + timedelta(seconds=random.randint(2, 90))
        comments.append((uid, vid, random.choice(comment_bodies), iso(t0)))
    con.executemany(
        "INSERT INTO Comment(user_id, video_id, body, commented_at) VALUES (?,?,?,?)",
        comments,
    )

    print(f"  users={len(users)} videos={len(videos)} audio_tracks={len(audio_track_rows)} "
          f"impressions={len(impressions)} view_segments={len(view_segments)} "
          f"signals={len(signals)} comments={len(comments)} sessions={len(sessions)} "
          f"turns={len(turns)} tool_calls={len(tool_calls)+len(nested)} recommendations={len(recommendations)}")


if __name__ == "__main__":
    main()
