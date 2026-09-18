-- agent-monitor: Supabase / Postgres schema
--
-- Run this once in your Supabase project: SQL Editor -> New query -> paste -> Run.
-- Then copy your project URL and anon key into .env.

create table if not exists public.agent_tasks (
    id            text primary key,
    agent_id      text        not null,
    agent_label   text,
    agent_kind    text,
    host          text,
    task          text        not null,
    status        text        not null default 'working'
                  check (status in ('working', 'waiting', 'done', 'failed')),
    detail        text,
    question      text,
    step          integer,
    total         integer,
    repo          text,
    cwd           text,
    started_at    timestamptz,
    updated_at    timestamptz not null default now(),
    ended_at      timestamptz,
    waiting_since timestamptz,
    -- Agents sweep expired rows opportunistically on write, so the table stays
    -- small without a scheduled job.
    expires_at    timestamptz
);

-- The menu bar app only ever asks "what changed since X".
create index if not exists agent_tasks_updated_at_idx on public.agent_tasks (updated_at desc);
create index if not exists agent_tasks_expires_at_idx on public.agent_tasks (expires_at);

alter table public.agent_tasks enable row level security;

-- SECURITY NOTE
-- This policy lets anyone holding the project's anon key read and write this
-- table. That is the trade for a zero-friction setup: the anon key ships to
-- every agent host, including remote ones.
--
-- What that means in practice: anyone with your project URL and anon key can
-- read your task titles and questions. Keep secrets out of task text.
--
-- To lock it down, drop this policy and use Supabase Auth (or a per-agent JWT)
-- so each agent authenticates as itself.
drop policy if exists agent_tasks_anon_all on public.agent_tasks;
create policy agent_tasks_anon_all
    on public.agent_tasks
    for all
    to anon, authenticated
    using (true)
    with check (true);

-- Optional: enables Supabase Realtime on this table, so a future version of the
-- app can hold a websocket instead of polling. Harmless if unused.
-- The publication is owned by supabase_admin, so this can fail on permissions
-- depending on which role runs the script. Realtime is optional, so swallow any
-- failure rather than aborting the whole migration.
do $$
begin
    alter publication supabase_realtime add table public.agent_tasks;
exception
    when others then
        raise notice 'Realtime not enabled for agent_tasks (%). This is safe to ignore.', sqlerrm;
end $$;
