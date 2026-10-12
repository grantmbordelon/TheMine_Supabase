# The Mine — Supabase

Database for The Mine, the 49ers player development tracker. Frontend lives in
[TheMine_FrontEnd](https://github.com/grantmbordelon/TheMine_FrontEnd).

> **This repo is public.** Player data and the join code never go in git.
> `private/` is gitignored — seeds, source HTML files, and merge reports live there.

## Setup

1. Supabase SQL editor → run `supabase/migrations/0001_init.sql` (schema, RLS, realtime).
2. Supabase SQL editor → run `private/0002_seed_merged.sql` (merged data + join code).
   It refuses to run twice.
3. Supabase SQL editor → run `supabase/migrations/0003_report_and_headshots.sql`, then
   `private/0004_backfill_espn.sql` (headshot ids, positions, numbers).
4. Auth → Providers → Email: "Confirm email" off.
5. Everyone signs up in the app, picks their name, and enters the join code.

## Model

| Table | What it holds |
|---|---|
| `members` | Staff who can sign in. Pre-seeded rows get "claimed" on signup so old notes keep their author. |
| `players` | Roster, readiness tier, status, focus, notes, talking points for the next meeting. |
| `meetings` | One row per conversation: player, date, time, type, who was there. |
| `meeting_notes` | **One row per author per meeting.** Josh and Austin each write their own notes, so nobody overwrites anybody. `author_id` null = notes carried over from the original tracker. |
| `goals` | Per-player goals with category, status, and progress. |
| `staff`, `settings` | Program Team directory; report summary, quote, and contact cadence per tier. |
| `app_secrets` | The join code. No RLS policies, so only the join functions can read it. |

Everything shown on a dashboard (last contact, awaiting first check-in, overdue, open next steps)
is computed in the app from these rows. Nothing summary-like is stored.

## Access rules

- Signed out: no table or function access at all.
- Signed in, not joined: sees nothing except the list of unclaimed staff names.
- Members: read everything; add and edit players, meetings, goals, and staff; write their own notes.
- Admins: also delete players, edit anyone's notes, and view or change the join code.

## Re-running the merge

The seed was built from the three copies of the old single-file HTML tracker:

```bash
python3 scripts/merge_html_exports.py private/sources/base.html private/sources/josh.html private/sources/austin.html
```

This writes `private/0002_seed_merged.sql` and `private/merge-report.md`. The rules are in the script's docstring.
