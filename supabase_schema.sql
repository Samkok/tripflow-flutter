-- Create the locations table
create table if not exists public.locations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users not null,
  trip_id uuid references public.trips(id) on delete set null,
  name text not null,
  lat double precision not null,
  lng double precision not null,
  fingerprint text not null,
  scheduled_date timestamp with time zone,
  is_skipped boolean default false,
  stay_duration integer default 0,
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
create index if not exists locations_trip_id_idx on public.locations (trip_id);
create index if not exists locations_fingerprint_idx on public.locations (fingerprint);

-- Create the trips table
create table if not exists public.trips (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null,
  name text not null,
  description text,
  status text default 'planning', -- 'planning', 'active', 'completed', 'archived'
  is_active boolean default false,
  start_date timestamp with time zone,
  end_date timestamp with time zone,
  total_distance double precision default 0,
  total_duration_minutes integer default 0,
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now()
);

-- Enable Row Level Security (RLS)
alter table public.trips enable row level security;

-- Create policies for trips
create policy "Users can select their own trips"
on public.trips for select
using (auth.uid() = user_id);

create policy "Users can insert their own trips"
on public.trips for insert
with check (true);

create policy "Users can update their own trips"
on public.trips for update
using (auth.uid() = user_id);

create policy "Users can delete their own trips"
on public.trips for delete
using (auth.uid() = user_id);

-- Create indexes for faster lookups
create index if not exists trips_user_id_idx on public.trips (user_id);
create index if not exists trips_status_idx on public.trips (status);
create index if not exists trips_is_active_idx on public.trips (is_active);
create index if not exists trips_created_at_idx on public.trips (created_at);

-- Policy: Users can delete their own locations
create policy "Users can delete their own locations"
on public.locations for delete
using (auth.uid() = user_id);

-- Optional index for faster lookups
create index if not exists locations_user_id_idx on public.locations (user_id);
create index if not exists locations_fingerprint_idx on public.locations (fingerprint);

-- Create the user_profiles table
create table if not exists public.user_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null unique,
  first_name text,
  last_name text,
  email text not null,
  phone_number text,
  profile_picture_url text,
  bio text,
  date_of_birth date,
  gender text,
  address text,
  city text,
  country text,
  preferences jsonb default '{}'::jsonb,
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now()
);

-- Enable Row Level Security (RLS)
alter table public.user_profiles enable row level security;

-- Create policies for user_profiles

-- Policy: Users can view their own profile
create policy "Users can select their own profile"
on public.user_profiles for select
using (auth.uid() = user_id);

-- Policy: Users can insert their own profile (allow service role bypass)
create policy "Users can insert their own profile"
on public.user_profiles for insert
with check (true);

-- Policy: Users can update their own profile
create policy "Users can update their own profile"
on public.user_profiles for update
using (auth.uid() = user_id);

-- Policy: Users can delete their own profile
create policy "Users can delete their own profile"
on public.user_profiles for delete
using (auth.uid() = user_id);

-- Create indexes for faster lookups
create index if not exists user_profiles_user_id_idx on public.user_profiles (user_id);
create index if not exists user_profiles_email_idx on public.user_profiles (email);
create index if not exists user_profiles_created_at_idx on public.user_profiles (created_at);

-- Create a function to insert user profile (bypasses RLS when called from auth trigger)
create or replace function public.create_user_profile(
  p_user_id uuid,
  p_email text,
  p_first_name text default null,
  p_last_name text default null,
  p_phone_number text default null,
  p_profile_picture_url text default null,
  p_bio text default null,
  p_date_of_birth date default null,
  p_gender text default null,
  p_address text default null,
  p_city text default null,
  p_country text default null,
  p_preferences jsonb default '{}'::jsonb
)
returns public.user_profiles as $$
declare
  v_profile public.user_profiles;
begin
  insert into public.user_profiles (
    user_id,
    email,
    first_name,
    last_name,
    phone_number,
    profile_picture_url,
    bio,
    date_of_birth,
    gender,
    address,
    city,
    country,
    preferences
  ) values (
    p_user_id,
    p_email,
    p_first_name,
    p_last_name,
    p_phone_number,
    p_profile_picture_url,
    p_bio,
    p_date_of_birth,
    p_gender,
    p_address,
    p_city,
    p_country,
    p_preferences
  ) returning * into v_profile;
  
  return v_profile;
end;
$$ language plpgsql security definer;
