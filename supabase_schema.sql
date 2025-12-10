-- Create the locations table
create table if not exists public.locations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users not null,
  name text not null,
  lat double precision not null,
  lng double precision not null,
  fingerprint text not null,
  created_at timestamp with time zone default now()
);

-- Enable Row Level Security (RLS)
alter table public.locations enable row level security;

-- Create policies

-- Policy: Users can see their own locations
create policy "Users can select their own locations"
on public.locations for select
using (auth.uid() = user_id);

-- Policy: Users can insert their own locations
create policy "Users can insert their own locations"
on public.locations for insert
with check (auth.uid() = user_id);

-- Policy: Users can update their own locations
create policy "Users can update their own locations"
on public.locations for update
using (auth.uid() = user_id);

-- Policy: Users can delete their own locations
create policy "Users can delete their own locations"
on public.locations for delete
using (auth.uid() = user_id);

-- Optional index for faster lookups
create index if not exists locations_user_id_idx on public.locations (user_id);
create index if not exists locations_fingerprint_idx on public.locations (fingerprint);
