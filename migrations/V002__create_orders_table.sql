-- ============================================================================
-- Migration: V002__create_orders_table.sql
-- Purpose:   Create the Orders table with FK to Users
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Orders' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.Orders (
        OrderId         INT IDENTITY(1,1)   NOT NULL,
        UserId          INT                 NOT NULL,
        OrderDate       DATETIME2           NOT NULL DEFAULT SYSUTCDATETIME(),
        TotalAmount     DECIMAL(18,2)       NOT NULL DEFAULT 0.00,
        Status          NVARCHAR(50)        NOT NULL DEFAULT 'Pending',
        CreatedDate     DATETIME2           NOT NULL DEFAULT SYSUTCDATETIME(),

        CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderId),
        CONSTRAINT FK_Orders_Users FOREIGN KEY (UserId)
            REFERENCES dbo.Users(UserId),
        CONSTRAINT CK_Orders_TotalAmount CHECK (TotalAmount >= 0)
    );

    -- Create a nonclustered index for common lookups
    CREATE NONCLUSTERED INDEX IX_Orders_UserId
        ON dbo.Orders (UserId)
        INCLUDE (OrderDate, TotalAmount, Status);

    PRINT 'Table dbo.Orders created successfully.';
END
ELSE
    PRINT 'Table dbo.Orders already exists. Skipping.';
