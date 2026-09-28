create table if not exists public.lng_entries (
  id text primary key,
  s text not null default 'user',
  t text not null,
  k jsonb not null default '[]'::jsonb,
  p text,
  d text,
  time text,
  note text,
  links jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.lng_entries enable row level security;
create policy "public can read LNG entries" on public.lng_entries for select using (true);
create policy "public can submit LNG entries" on public.lng_entries for insert with check (true);