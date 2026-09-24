-- The Mine — schema. Run once in the Supabase SQL editor.
-- Contains no player data and no working join code: this repo is public.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- members (app users)

-- Staff who can sign in. Rows can exist before the person signs up, so
-- historical notes have an author to point at; signing up "claims" the row.
create table members (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  user_id uuid unique references auth.users(id) on delete set null,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

-- Join code. No policies, so only security-definer functions can read it.
-- Seeded with a random value; set the real one from the app or the private seed.
create table app_secrets (
  id int primary key default 1 check (id = 1),
  join_code text not null
);
insert into app_secrets (join_code) values (encode(gen_random_bytes(12), 'hex'));

create or replace function me() returns uuid
language sql stable security definer set search_path = public as $$
  select id from members where user_id = auth.uid()
$$;

create or replace function is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where user_id = auth.uid())
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from members where user_id = auth.uid()), false)
$$;

-- ---------------------------------------------------------------- program data

create table settings (
  id int primary key default 1 check (id = 1),
  season text not null default '2026',
  maintainers text not null default '',
  summary text not null default '',
  quote text not null default '',
  quote_attrib text not null default '',
  -- days between conversations, per readiness tier
  cadence jsonb not null default '{"Contributing Now":28,"Trending Up":21,"Foundation Build":14,"Carryover":21}',
  updated_at timestamptz not null default now()
);
insert into settings (id) values (1);

create table staff (
  id uuid primary key default gen_random_uuid(),
  role text not null default '',
  name text not null,
  responsibility text not null default '',
  sort int not null default 0
);

create table players (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,  -- p01… from the HTML tracker
  name text not null,
  player_group text not null default 'Rookie' check (player_group in ('Rookie', 'Carryover')),
  tier text not null default 'Contributing Now'
    check (tier in ('Contributing Now', 'Trending Up', 'Foundation Build', 'Carryover')),
  status text not null default 'Active' check (status in ('Active', 'Injured', 'IR', 'Practice Squad')),
  focus text not null default '',
  notes text not null default '',
  talking_points text not null default '',  -- prep for the next meeting
  owner text not null default '',
  sort int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table meetings (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  meeting_date date not null,
  meeting_time time,
  meeting_type text not null default '1-on-1',
  status text not null default 'Completed' check (status in ('Completed', 'Planned')),
  attendees text not null default '',
  created_by uuid references members(id) on delete set null default me(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on meetings (player_id, meeting_date desc);

-- Each attendee writes their own notes on a meeting. One row per author, so
-- two people never overwrite each other. author_id null = pre-app program notes.
create table meeting_notes (
  id uuid primary key default gen_random_uuid(),
  meeting_id uuid not null references meetings(id) on delete cascade,
  author_id uuid references members(id) on delete set null,
  goal text not null default '',
  discussed text not null default '',
  next_steps text not null default '',
  next_owner text not null default '',
  next_due date,
  next_done boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (meeting_id, author_id)
);
create index on meeting_notes (meeting_id);

create table goals (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  title text not null,
  category text not null default 'Body'
    check (category in ('Body', 'Mind', 'Football IQ', 'Technique', 'Special Teams', 'Life')),
  target text not null default '',
  status text not null default 'Not started'
    check (status in ('Not started', 'In progress', 'On track', 'At risk', 'Achieved')),
  progress text not null default '',
  updated_at timestamptz not null default now()
);
create index on goals (player_id);

create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger touch before update on settings      for each row execute function touch_updated_at();
create trigger touch before update on players       for each row execute function touch_updated_at();
create trigger touch before update on meetings      for each row execute function touch_updated_at();
create trigger touch before update on meeting_notes for each row execute function touch_updated_at();
create trigger touch before update on goals         for each row execute function touch_updated_at();

-- ---------------------------------------------------------------- joining

create or replace function check_join_code(p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if not exists (select 1 from app_secrets where lower(join_code) = lower(trim(p_code))) then
    raise exception 'That join code is not right';
  end if;
  if exists (select 1 from members where user_id = auth.uid()) then
    raise exception 'This account is already on the team';
  end if;
end $$;

-- Staff still waiting to be claimed (names only), for the join screen.
create or replace function unclaimed_members() returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select id, name from members where user_id is null and auth.uid() is not null order by name
$$;

create or replace function claim_member(p_member uuid, p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform check_join_code(p_code);
  update members set user_id = auth.uid() where id = p_member and user_id is null;
  if not found then raise exception 'That name is already claimed'; end if;
end $$;

create or replace function join_as_new_member(p_name text, p_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  perform check_join_code(p_code);
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter your name'; end if;
  insert into members (name, user_id) values (trim(p_name), auth.uid()) returning id into new_id;
  return new_id;
end $$;

create or replace function get_join_code() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return (select join_code from app_secrets where id = 1);
end $$;

create or replace function set_join_code(p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if length(trim(p_code)) < 6 then raise exception 'Use at least 6 characters'; end if;
  update app_secrets set join_code = trim(p_code) where id = 1;
end $$;

-- Log a meeting and the caller's notes in one transaction.
create or replace function log_meeting(
  p_player uuid, p_date date, p_time time, p_type text, p_status text, p_attendees text,
  p_goal text, p_discussed text, p_next_steps text, p_next_owner text, p_next_due date,
  p_next_done boolean, p_clear_talking_points boolean
) returns uuid
language plpgsql security definer set search_path = public as $$
declare mid uuid;
begin
  if not is_member() then raise exception 'Members only'; end if;
  insert into meetings (player_id, meeting_date, meeting_time, meeting_type, status, attendees, created_by)
  values (p_player, p_date, p_time, coalesce(p_type, '1-on-1'), coalesce(p_status, 'Completed'),
          coalesce(p_attendees, ''), me())
  returning id into mid;
  insert into meeting_notes (meeting_id, author_id, goal, discussed, next_steps, next_owner, next_due, next_done)
  values (mid, me(), coalesce(p_goal, ''), coalesce(p_discussed, ''), coalesce(p_next_steps, ''),
          coalesce(p_next_owner, ''), p_next_due, coalesce(p_next_done, false));
  if p_clear_talking_points then
    update players set talking_points = '' where id = p_player;
  end if;
  return mid;
end $$;

-- Functions are executable by PUBLIC by default; limit these to signed-in users.
revoke execute on function get_join_code(), set_join_code(text), claim_member(uuid, text),
  join_as_new_member(text, text), unclaimed_members(), check_join_code(text),
  log_meeting(uuid, date, time, text, text, text, text, text, text, text, date, boolean, boolean)
  from public, anon;
grant execute on function get_join_code(), set_join_code(text), claim_member(uuid, text),
  join_as_new_member(text, text), unclaimed_members(),
  log_meeting(uuid, date, time, text, text, text, text, text, text, text, date, boolean, boolean)
  to authenticated;

-- ---------------------------------------------------------------- table grants
-- Explicit rather than relying on project defaults. Signed-out visitors get nothing.

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke all on all tables in schema public from anon;

-- ---------------------------------------------------------------- row level security
-- Everything is members-only. Signed-in accounts without a claimed member row see nothing.

alter table members       enable row level security;
alter table app_secrets   enable row level security;
alter table settings      enable row level security;
alter table staff         enable row level security;
alter table players       enable row level security;
alter table meetings      enable row level security;
alter table meeting_notes enable row level security;
alter table goals         enable row level security;

create policy "members read"    on members for select to authenticated using (is_member());
create policy "admins manage"   on members for update to authenticated using (is_admin()) with check (is_admin());
create policy "admins remove"   on members for delete to authenticated using (is_admin());

create policy "members read"    on settings for select to authenticated using (is_member());
create policy "members edit"    on settings for update to authenticated using (is_member()) with check (is_member());

create policy "members all"     on staff    for all to authenticated using (is_member()) with check (is_member());
create policy "members all"     on goals    for all to authenticated using (is_member()) with check (is_member());
create policy "members all"     on meetings for all to authenticated using (is_member()) with check (is_member());

create policy "members read"    on players for select to authenticated using (is_member());
create policy "members add"     on players for insert to authenticated with check (is_member());
create policy "members edit"    on players for update to authenticated using (is_member()) with check (is_member());
create policy "admins remove"   on players for delete to authenticated using (is_admin());

-- Notes: anyone on the team reads them; you write your own. Pre-app program
-- notes (no author) are editable by any member; admins can edit anything.
create policy "members read"    on meeting_notes for select to authenticated using (is_member());
create policy "write own"       on meeting_notes for insert to authenticated
  with check (is_member() and author_id = me());
create policy "edit own"        on meeting_notes for update to authenticated
  using (is_member() and (author_id = me() or author_id is null or is_admin()))
  with check (is_member() and (author_id = me() or author_id is null or is_admin()));
create policy "delete own"      on meeting_notes for delete to authenticated
  using (is_member() and (author_id = me() or author_id is null or is_admin()));

-- ---------------------------------------------------------------- realtime
-- Every open tab (Present included) updates as soon as someone saves.

alter publication supabase_realtime add table members, settings, staff, players, meetings, meeting_notes, goals;
