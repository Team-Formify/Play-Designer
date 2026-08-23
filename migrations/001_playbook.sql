-- Play Designer — live playbook storage
--
-- Paste this into Supabase → SQL Editor → New query → Run.
-- Safe to run twice; every statement is guarded.
--
-- The playbook is one document, not a relational model. Eleven players and
-- their routes only ever make sense as a whole play, and the app already reads
-- and writes it as a single JSON file, so it is stored as one jsonb row.
-- Shredding it into players/routes/plays tables would buy nothing and cost a
-- join on every read.

create table if not exists public.playbook (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null references auth.users(id) on delete cascade,
  data        jsonb not null,
  device      text,                                   -- which device wrote it last
  updated_at  timestamptz not null default now(),
  created_at  timestamptz not null default now(),

  -- One playbook per person. Makes the app's upsert trivial and makes it
  -- impossible to end up with two rows quietly diverging.
  constraint playbook_one_per_owner unique (owner),

  -- Never let an empty or malformed document overwrite a good one.
  constraint playbook_has_plays check (jsonb_array_length(data->'plays') > 0)
);

comment on table  public.playbook is 'One row per coach. data is the whole special-teams-plays.json.';
comment on column public.playbook.device is 'Free text, e.g. "iPhone" — so a conflict can say which device wrote last.';

-- updated_at has to be trustworthy: the app compares it to decide whether this
-- device is behind the server, so the client must not be able to fake it.
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  new.owner = coalesce(new.owner, auth.uid());
  return new;
end $$;

drop trigger if exists playbook_touch on public.playbook;
create trigger playbook_touch
  before insert or update on public.playbook
  for each row execute function public.touch_updated_at();

-- Row level security.
--
-- The anon key is public — it ships inside the page source, so anyone who views
-- source has it. RLS is therefore the only thing standing between your playbook
-- and the internet. With these policies, holding the anon key gets you nothing
-- without being signed in as you.
--
-- (TeamFormify's notes flag permissive USING (true) policies as an open gap.
--  Not repeating that here.)

alter table public.playbook enable row level security;

drop policy if exists playbook_select_own on public.playbook;
create policy playbook_select_own on public.playbook
  for select using (auth.uid() = owner);

drop policy if exists playbook_insert_own on public.playbook;
create policy playbook_insert_own on public.playbook
  for insert with check (auth.uid() = owner);

drop policy if exists playbook_update_own on public.playbook;
create policy playbook_update_own on public.playbook
  for update using (auth.uid() = owner) with check (auth.uid() = owner);

-- Deliberately no delete policy. Nothing in the app deletes a playbook, and
-- rule 1 of the project brief is that plays do not disappear on their own.

create index if not exists playbook_owner_idx on public.playbook (owner);
