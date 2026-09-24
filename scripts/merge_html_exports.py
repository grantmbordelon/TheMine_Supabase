#!/usr/bin/env python3
"""Merge copies of the single-file HTML tracker into one seed for Supabase.

    python3 scripts/merge_html_exports.py BASE.html JOSH.html AUSTIN.html

BASE is the copy both people started from. Writes private/0002_seed_merged.sql
and private/merge-report.md (private/ is gitignored because this repo is public).

Merge rules
- Players and goals: three-way merge per field against BASE. A field changed in
  only one copy takes that copy's value; changed identically in both is fine;
  changed differently in both is a conflict (Austin's value wins, reported).
  Deleted in one copy and untouched in the other = deleted.
- Meetings: both people sat in the same 1-on-1s and each logged their own notes.
  New meetings for the same player within a day of each other are treated as one
  meeting carrying two sets of notes, one per author.
- Meetings already in BASE become "program notes" with no author.
"""
import json
import re
import secrets
import sys
import uuid
from pathlib import Path

NS = uuid.UUID("6d1f2b1e-49e7-4c0a-9a1f-000000002026")
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "private"

MEMBERS = [  # (key, name, is_admin)
    ("josh", "Josh Williams", True),
    ("austin", "Austin Moss", True),
    ("grant", "Grant Bordelon", True),
]
OWNER_ALIASES = {
    "austin": "Austin Moss",
    "josh": "Josh Williams",
    "josh & austin": "Josh Williams, Austin Moss",
    "josh and austin": "Josh Williams, Austin Moss",
}


def uid(*parts):
    return str(uuid.uuid5(NS, "/".join(parts)))


def load(path):
    html = Path(path).read_text()
    m = re.search(r'<script id="mine-data" type="application/json">(.*?)</script>', html, re.S)
    if not m:
        sys.exit(f"No embedded data in {path}")
    return json.loads(m.group(1))


def q(v):
    """SQL literal."""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (dict, list)):
        return q(json.dumps(v)) + "::jsonb"
    return "'" + str(v).replace("'", "''") + "'"


def norm_time(t):
    """'8:00AM', '10:30am', '11', '9:30 AM' -> 'HH:MM' (24h) or None."""
    t = (t or "").strip().lower().replace(" ", "")
    if not t:
        return None
    m = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?(am|pm)?", t)
    if not m:
        return None
    h, mi, ap = int(m.group(1)), int(m.group(2) or 0), m.group(3)
    if ap == "pm" and h < 12:
        h += 12
    if ap == "am" and h == 12:
        h = 0
    if not ap and 1 <= h <= 6:  # bare "3" during the work day means 3 PM
        h += 12
    return f"{h:02d}:{mi:02d}" if h < 24 and mi < 60 else None


def norm_owner(o):
    o = (o or "").strip()
    if norm_time(o):  # a time typed into the owner box
        return ""
    return OWNER_ALIASES.get(o.lower(), o)


def three_way(base, a, b, label, report):
    """Merge dicts keyed by id. a = Josh, b = Austin."""
    B, A, U = ({x["id"]: x for x in d} for d in (base, a, b))
    out = []
    for k in list(B) + [k for k in list(A) + list(U) if k not in B]:
        o, j, u = B.get(k), A.get(k), U.get(k)
        if o is None:  # new in one or both
            out.append(u or j)
            continue
        if j is None or u is None:
            other = u if j is None else j
            who = "Josh" if j is None else "Austin"
            if other == o:
                report.append(f"- {label} `{k}` ({o.get('title') or o.get('name')}): deleted by {who}.")
                continue
            report.append(f"- {label} `{k}`: deleted by {who} but edited by the other; kept the edit.")
            out.append(other)
            continue
        merged = {}
        for f in set(o) | set(j) | set(u):
            ov, jv, uv = o.get(f), j.get(f), u.get(f)
            if jv == uv:
                merged[f] = jv
            elif jv == ov:
                merged[f] = uv
            elif uv == ov:
                merged[f] = jv
            else:
                merged[f] = uv
                report.append(f"- CONFLICT {label} `{k}`.{f}: Josh={jv!r} Austin={uv!r}; used Austin's.")
        out.append(merged)
    return out


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    base, josh, austin = (load(p) for p in sys.argv[1:])
    report = ["# Merge report", ""]
    mid = {k: uid("member", k) for k, _, _ in MEMBERS}

    players = three_way(base["players"], josh["players"], austin["players"], "player", report)
    goals = three_way(base["goals"], josh["goals"], austin["goals"], "goal", report)
    pid = {p["id"]: uid("player", p["id"]) for p in players}
    pname = {p["id"]: p["name"] for p in players}

    # ---- meetings
    base_ids = {m["id"] for m in base["meetings"]}
    # BASE meetings, with any edits (three-way) — author-less program notes.
    shared = three_way(
        base["meetings"],
        [m for m in josh["meetings"] if m["id"] in base_ids],
        [m for m in austin["meetings"] if m["id"] in base_ids],
        "meeting", report,
    )
    new_j = [m for m in josh["meetings"] if m["id"] not in base_ids]
    new_a = [m for m in austin["meetings"] if m["id"] not in base_ids]

    def day(s):
        y, mo, d = map(int, s.split("-"))
        return y * 372 + mo * 31 + d

    meetings = []  # (meeting_row, [(author_key|None, note)])
    for m in shared:
        meetings.append((m, [(None, m)]))
    used_a = set()
    for j in new_j:
        match = next((a for a in new_a if a["id"] not in used_a and a["playerId"] == j["playerId"]
                      and abs(day(a["date"]) - day(j["date"])) <= 1), None)
        if match:
            used_a.add(match["id"])
            row = dict(match)  # Austin's header fields are the more complete ones
            row["time"] = match["time"] or j["time"]
            if match["date"] != j["date"]:
                report.append(f"- DATE MISMATCH {pname[j['playerId']]}: Josh logged {j['date']}, "
                              f"Austin logged {match['date']}. Merged into one meeting dated {match['date']}.")
            meetings.append((row, [("josh", j), ("austin", match)]))
        else:
            meetings.append((j, [("josh", j)]))
    for a in new_a:
        if a["id"] not in used_a:
            meetings.append((a, [("austin", a)]))

    paired = sum(1 for _, n in meetings if len(n) == 2)
    report.insert(2, f"{len(players)} players · {len(meetings)} meetings ({paired} with notes from both Josh and "
                     f"Austin) · {sum(len(n) for _, n in meetings)} notes · {len(goals)} goals")
    report.insert(3, "")

    # ---- SQL
    join_code = "mine-" + secrets.token_hex(3)
    L = [
        "-- The Mine — merged seed from the Josh + Austin HTML trackers.",
        "-- PRIVATE: contains player notes. Do not commit. Run once, after 0001_init.sql.",
        "begin;",
        "do $$ begin if exists (select 1 from players) then",
        "  raise exception 'Already seeded — players table is not empty'; end if; end $$;",
        "",
        f"update app_secrets set join_code = {q(join_code)} where id = 1;",
        "",
        "insert into members (id, name, is_admin) values",
        ",\n".join(f"  ({q(mid[k])}, {q(n)}, {q(adm)})" for k, n, adm in MEMBERS) + ";",
        "",
    ]
    meta = austin["meta"]
    L += [
        "update settings set",
        f"  season = {q(meta['season'])}, maintainers = {q(meta['maintainers'])},",
        f"  summary = {q(meta['summary'])},",
        f"  quote = {q(meta['quote'])}, quote_attrib = {q(meta['quoteAttrib'])},",
        f"  cadence = {q(meta['cadence'])}",
        "where id = 1;",
        "",
        "insert into staff (role, name, responsibility, sort) values",
        ",\n".join(f"  ({q(s['role'])}, {q(s['name'])}, {q(s['responsibility'])}, {i})"
                   for i, s in enumerate(austin["staff"])) + ";",
        "",
        "insert into players (id, legacy_id, name, player_group, tier, status, focus, notes, talking_points, owner, sort) values",
        ",\n".join(
            f"  ({q(pid[p['id']])}, {q(p['id'])}, {q(p['name'])}, {q(p['group'])}, {q(p['tier'])}, {q(p['status'])}, "
            f"{q(p['focus'])}, {q(p['notes'])}, {q(p['talkingPoints'])}, {q(p['owner'])}, {i})"
            for i, p in enumerate(players)) + ";",
        "",
        "insert into goals (player_id, title, category, target, status, progress, updated_at) values",
        ",\n".join(
            f"  ({q(pid[g['playerId']])}, {q(g['title'])}, {q(g['category'])}, {q(g['target'])}, "
            f"{q(g['status'])}, {q(g['progress'])}, {q(g['updated'] + 'T12:00:00Z')})"
            for g in goals) + ";",
        "",
    ]
    mrows, nrows = [], []
    for i, (m, notes) in enumerate(sorted(meetings, key=lambda x: (x[0]["date"], x[0]["playerId"]))):
        meeting_id = uid("meeting", m["id"])
        creator = next((mid[a] for a, _ in notes if a), None)
        mrows.append(
            f"  ({q(meeting_id)}, {q(pid[m['playerId']])}, {q(m['date'])}, {q(norm_time(m['time']))}, "
            f"{q(m['type'])}, {q(m['status'])}, {q(m['attendees'])}, {q(creator)})")
        for author, n in notes:
            steps = (n["nextSteps"] or "").strip()
            nrows.append(
                f"  ({q(meeting_id)}, {q(mid[author] if author else None)}, {q(n['goal'].strip())}, "
                f"{q(n['discussed'].strip())}, {q(steps)}, {q(norm_owner(n['nextOwner']) if steps else '')}, "
                f"{q((n['nextDue'] or None) if steps else None)}, {q(bool(n['nextDone']))})")
    L += [
        "insert into meetings (id, player_id, meeting_date, meeting_time, meeting_type, status, attendees, created_by) values",
        ",\n".join(mrows) + ";",
        "",
        "insert into meeting_notes (meeting_id, author_id, goal, discussed, next_steps, next_owner, next_due, next_done) values",
        ",\n".join(nrows) + ";",
        "",
        "commit;",
        "",
        "-- Sanity check: expect "
        f"{len(players)} players, {len(meetings)} meetings, {len(nrows)} notes, {len(goals)} goals.",
        "select (select count(*) from players) players, (select count(*) from meetings) meetings,",
        "       (select count(*) from meeting_notes) notes, (select count(*) from goals) goals;",
        "",
    ]
    OUT.mkdir(exist_ok=True)
    (OUT / "0002_seed_merged.sql").write_text("\n".join(L))
    report += ["", f"Join code: `{join_code}` (change it any time on the Program Team tab)."]
    (OUT / "merge-report.md").write_text("\n".join(report) + "\n")
    print("\n".join(report))
    print(f"\nWrote {OUT / '0002_seed_merged.sql'}")


if __name__ == "__main__":
    main()
