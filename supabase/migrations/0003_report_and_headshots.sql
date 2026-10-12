-- Headshots and the editable Present report. Run once in the Supabase SQL editor.

-- Photo + roster details. espn_id drives the headshot; headshot_url is a manual override.
alter table players
  add column espn_id text,
  add column position text not null default '',
  add column jersey text not null default '',
  add column headshot_url text not null default '';

-- Report card text, curated per player. Pre-filled from meetings, then edited down.
-- report_as_of: newest meeting date pulled in. report_synced_at: when it was pulled,
-- so the app can tell when newer meeting notes exist.
alter table players
  add column report_recent text not null default '',
  add column report_upcoming text not null default '',
  add column report_as_of date,
  add column report_synced_at timestamptz,
  add column report_hidden boolean not null default false;

-- Summary as 4–5 bullets instead of a paragraph.
alter table settings
  add column summary_bullets jsonb not null default '[]'::jsonb;

-- Start the bullets from the existing summary, one per sentence.
update settings
set summary_bullets = coalesce((
  select jsonb_agg(trim(s))
  from regexp_split_to_table(summary, '(?<=[.!?])\s+') as s
  where trim(s) <> ''
), '[]'::jsonb)
where summary_bullets = '[]'::jsonb;
