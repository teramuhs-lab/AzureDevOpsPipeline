-- ============================================================================
-- Migration: V003__add_phone_to_users.sql
-- Purpose:   Add PhoneNumber column to the Users table
-- ============================================================================
-- NOTE: This demonstrates how to modify an existing table.
--   Instead of editing V001, we create a NEW migration.
--   This ensures the change is tracked, audited, and applied in order.
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'PhoneNumber'
)
BEGIN
    ALTER TABLE dbo.Users
        ADD PhoneNumber NVARCHAR(20) NULL;

    PRINT 'Column PhoneNumber added to dbo.Users.';
END
ELSE
    PRINT 'Column PhoneNumber already exists on dbo.Users. Skipping.';
