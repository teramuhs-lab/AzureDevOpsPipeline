-- ============================================================================
-- Migration: V001__create_users_table.sql
-- Purpose:   Create the core Users table
-- Author:    Database DevOps Pipeline
-- ============================================================================
-- MIGRATION RULES:
--   1. This file runs ONCE per environment (tracked by MigrationHistory)
--   2. NEVER modify this file after it's been deployed
--   3. To change this table, create a NEW migration (e.g., V003__alter_users.sql)
--   4. Do NOT include USE [database] — the pipeline sets the target
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Users' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.Users (
        UserId          INT IDENTITY(1,1)   NOT NULL,
        Email           NVARCHAR(255)       NOT NULL,
        FirstName       NVARCHAR(100)       NOT NULL,
        LastName        NVARCHAR(100)       NOT NULL,
        IsActive        BIT                 NOT NULL DEFAULT 1,
        CreatedDate     DATETIME2           NOT NULL DEFAULT SYSUTCDATETIME(),
        ModifiedDate    DATETIME2           NOT NULL DEFAULT SYSUTCDATETIME(),

        CONSTRAINT PK_Users PRIMARY KEY CLUSTERED (UserId),
        CONSTRAINT UQ_Users_Email UNIQUE (Email)
    );

    PRINT 'Table dbo.Users created successfully.';
END
ELSE
    PRINT 'Table dbo.Users already exists. Skipping.';
