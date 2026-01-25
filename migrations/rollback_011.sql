-- Rollback migration 011: Remove delete_user_account function
DROP FUNCTION IF EXISTS delete_user_account();
