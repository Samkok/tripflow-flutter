create or replace function public.get_public_user_profile(p_user_id uuid)
returns table (
  id uuid,
  user_id uuid,
  first_name text,
  last_name text,
  email text,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    up.id,
    up.user_id,
    up.first_name,
    up.last_name,
    up.email,
    up.created_at,
    up.updated_at
  from public.user_profiles up
  where up.user_id = p_user_id
  limit 1;
$$;

grant execute on function public.get_public_user_profile(uuid) to authenticated;
