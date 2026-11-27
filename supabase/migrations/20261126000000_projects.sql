-- Cueframe: cloud backup of editor projects (in progress and finished).
-- One row per project. `data` is the full edit as the app saves it (EditProject JSON).
-- Video files stay on the phone; only paths to them are stored here.

create table public.projects (
  id               uuid primary key,
  user_id          uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name             text not null,
  status           text not null default 'in_progress' check (status in ('in_progress', 'finished')),
  canvas           text not null,
  quality          text not null,
  duration_seconds double precision not null default 0,
  clip_count       integer not null default 0,
  data             jsonb,
  created_at       timestamptz not null default now(),
  modified_at      timestamptz not null default now(),
  finished_at      timestamptz,
  deleted_at       timestamptz,   -- tombstone so other devices learn about deletes
  updated_at       timestamptz not null default now()  -- set by the server; the app pulls by it
);

comment on table public.projects is 'Cueframe editor projects, one per edit. Phone is the source of truth; this is the backup.';

create index projects_user_updated_idx on public.projects (user_id, updated_at);
create index projects_user_status_idx on public.projects (user_id, status) where deleted_at is null;

-- Server clock decides updated_at, and a row can never move to another user.
create function public.projects_before_write() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id;
  end if;
  return new;
end;
$$;

create trigger projects_before_write
before insert or update on public.projects
for each row execute function public.projects_before_write();

alter table public.projects enable row level security;

create policy "Users read their own projects" on public.projects
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users add their own projects" on public.projects
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users change their own projects" on public.projects
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Users delete their own projects" on public.projects
  for delete to authenticated using ((select auth.uid()) = user_id);

revoke all on public.projects from anon;
grant select, insert, update, delete on public.projects to authenticated;
