-- Function to allow users to delete their own account
-- This is called from the app and uses the authenticated user's JWT
CREATE OR REPLACE FUNCTION delete_user_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_user_id uuid;
BEGIN
  -- Get the current authenticated user ID
  current_user_id := auth.uid();

  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Delete the user from auth.users
  -- This will CASCADE delete to user_subscriptions and trip_collaborators
  -- The app already deleted locations, trips, and user_profiles manually
  DELETE FROM auth.users WHERE id = current_user_id;

  -- Log the deletion
  RAISE NOTICE 'User account % deleted successfully', current_user_id;
END;
$$;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION delete_user_account() TO authenticated;

-- Add comment
COMMENT ON FUNCTION delete_user_account() IS 'Allows authenticated users to delete their own account. Should only be called after app has cleaned up user data.';
