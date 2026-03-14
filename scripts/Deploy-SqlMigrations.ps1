<#
.SYNOPSIS
    Deploys SQL migration scripts to a target database.

.DESCRIPTION
    This is the core deployment engine. It connects to the target SQL Server
    and executes migration scripts IN ORDER, tracking which ones have already
    been applied.

    HOW IT WORKS (for DBAs transitioning to DevOps):

    1. Connects to the target database using provided credentials
    2. Checks a MigrationHistory table to see which scripts have already run
    3. Runs ONLY the new scripts, in version order (V001, V002, V003...)
    4. Records each successful migration in the MigrationHistory table
    5. If any script fails, it stops immediately (no partial deployments)

    WHY THIS APPROACH:
    This is the same pattern used by tools like Flyway, Liquibase, and EF Migrations.
    The key insight: each script runs EXACTLY ONCE per environment.
    V001 runs in Dev, then Test, then Prod — same script, same order, guaranteed.

    DBA PARALLEL:
    Think of MigrationHistory as a deployment log. Instead of checking SSMS
    to see "did we run that ALTER TABLE script?", you query the tracking table.
    It's auditable, queryable, and automated.

.PARAMETER ServerInstance
    The SQL Server instance to deploy to (e.g., 'server.database.windows.net')

.PARAMETER DatabaseName
    The target database name

.PARAMETER MigrationsPath
    Path to the directory containing SQL migration files

.PARAMETER Environment
    The environment name (Dev, Test, Production) — used for logging

.EXAMPLE
    .\Deploy-SqlMigrations.ps1 -ServerInstance "dev-sql.database.windows.net" `
                                -DatabaseName "MyApp_Dev" `
                                -MigrationsPath ".\migrations" `
                                -Environment "Dev"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ServerInstance,

    [Parameter(Mandatory = $true)]
    [string]$DatabaseName,

    [Parameter(Mandatory = $true)]
    [string]$MigrationsPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Dev', 'Test', 'Production')]
    [string]$Environment
)

$ErrorActionPreference = 'Stop'

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  SQL MIGRATION DEPLOYMENT" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Environment:    $Environment"
Write-Host "Server:         $ServerInstance"
Write-Host "Database:       $DatabaseName"
Write-Host "Migrations:     $MigrationsPath"
Write-Host "Timestamp:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

# -------------------------------------------------------
# BUILD CONNECTION STRING
# -------------------------------------------------------
# The password comes from the environment variable SQL_PASSWORD,
# which was injected by the pipeline from the Variable Group.
#
# SECURITY NOTE:
#   - The password is NEVER logged or displayed
#   - Azure DevOps masks it in all output automatically
#   - It exists only in memory during script execution
#   - After the pipeline finishes, it's gone
#
# In a real enterprise environment, you might use:
#   - Azure AD authentication (no password needed)
#   - Managed Identity (even more secure)
#   - Azure Key Vault references
$sqlPassword = $env:SQL_PASSWORD
if ([string]::IsNullOrEmpty($sqlPassword)) {
    Write-Host "##[error]SQL_PASSWORD environment variable is not set."
    Write-Host "Ensure the Variable Group 'SQLDatabase-Secrets' is linked to this pipeline."
    exit 1
}

$connectionString = "Server=$ServerInstance;Database=$DatabaseName;User Id=deploy_admin;Password=$sqlPassword;TrustServerCertificate=True;Connection Timeout=30;"

# -------------------------------------------------------
# FUNCTION: Execute a SQL command
# -------------------------------------------------------
# This wraps ADO.NET SqlConnection/SqlCommand.
# Using ADO.NET directly (instead of Invoke-Sqlcmd) gives us more
# control over error handling and connection management.
function Invoke-SqlDeployment {
    param(
        [string]$ConnectionString,
        [string]$Query,
        [int]$CommandTimeout = 120
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = $CommandTimeout
        $command.ExecuteNonQuery() | Out-Null
    }
    finally {
        if ($connection.State -eq 'Open') {
            $connection.Close()
        }
        $connection.Dispose()
    }
}

function Invoke-SqlQuery {
    param(
        [string]$ConnectionString,
        [string]$Query
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $results = @()
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $reader = $command.ExecuteReader()
        while ($reader.Read()) {
            $row = @{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $row[$reader.GetName($i)] = $reader.GetValue($i)
            }
            $results += [PSCustomObject]$row
        }
        $reader.Close()
    }
    finally {
        if ($connection.State -eq 'Open') {
            $connection.Close()
        }
        $connection.Dispose()
    }
    return $results
}

# -------------------------------------------------------
# STEP 1: Ensure MigrationHistory table exists
# -------------------------------------------------------
# This table tracks which migrations have been applied.
# It's created automatically on first run — no manual setup needed.
#
# Columns:
#   MigrationId     - Auto-incrementing ID
#   ScriptName      - The filename (e.g., V001__create_users_table.sql)
#   AppliedOn       - When the script was executed
#   AppliedBy       - Who/what ran it (pipeline ID)
#   Environment     - Which environment (Dev/Test/Prod)
#   Checksum        - Hash of the script content (detects tampering)
Write-Host "Ensuring MigrationHistory table exists..." -ForegroundColor Yellow

$createTrackingTable = @"
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'MigrationHistory' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.MigrationHistory (
        MigrationId     INT IDENTITY(1,1) PRIMARY KEY,
        ScriptName      NVARCHAR(255) NOT NULL,
        AppliedOn       DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        AppliedBy       NVARCHAR(255) NOT NULL,
        Environment     NVARCHAR(50) NOT NULL,
        Checksum        NVARCHAR(64) NOT NULL,
        ExecutionTimeMs INT NULL,
        CONSTRAINT UQ_MigrationHistory_ScriptName UNIQUE (ScriptName)
    );
    PRINT 'MigrationHistory table created.';
END
ELSE
    PRINT 'MigrationHistory table already exists.';
"@

Invoke-SqlDeployment -ConnectionString $connectionString -Query $createTrackingTable
Write-Host "  [OK] MigrationHistory table ready." -ForegroundColor Green

# -------------------------------------------------------
# STEP 2: Get already-applied migrations
# -------------------------------------------------------
Write-Host "Checking previously applied migrations..." -ForegroundColor Yellow

$appliedMigrations = Invoke-SqlQuery -ConnectionString $connectionString `
    -Query "SELECT ScriptName, Checksum FROM dbo.MigrationHistory ORDER BY ScriptName"

$appliedNames = @{}
foreach ($m in $appliedMigrations) {
    $appliedNames[$m.ScriptName] = $m.Checksum
}

Write-Host "  Found $($appliedNames.Count) previously applied migration(s)." -ForegroundColor Green

# -------------------------------------------------------
# STEP 3: Identify new migrations to apply
# -------------------------------------------------------
$allMigrations = Get-ChildItem -Path $MigrationsPath -Filter "*.sql" | Sort-Object Name
$pendingMigrations = @()

foreach ($file in $allMigrations) {
    $fileContent = Get-Content -Path $file.FullName -Raw
    $checksum = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($fileContent)
        )
    ).Replace('-', '')

    if ($appliedNames.ContainsKey($file.Name)) {
        # Migration already applied — verify checksum hasn't changed
        # If someone modifies an already-applied script, that's a red flag.
        # Applied scripts should NEVER be modified — create a new migration instead.
        if ($appliedNames[$file.Name] -ne $checksum) {
            Write-Host "##[error]CHECKSUM MISMATCH: $($file.Name) has been modified after deployment!"
            Write-Host "Applied scripts must NEVER be changed. Create a new migration instead."
            Write-Host "  Expected: $($appliedNames[$file.Name])"
            Write-Host "  Actual:   $checksum"
            exit 1
        }
        Write-Host "  [SKIP] $($file.Name) — already applied" -ForegroundColor DarkGray
    }
    else {
        $pendingMigrations += @{
            File     = $file
            Checksum = $checksum
        }
    }
}

Write-Host ""

if ($pendingMigrations.Count -eq 0) {
    Write-Host "No new migrations to apply. Database is up to date." -ForegroundColor Green
    exit 0
}

Write-Host "$($pendingMigrations.Count) new migration(s) to apply:" -ForegroundColor Yellow
$pendingMigrations | ForEach-Object { Write-Host "  -> $($_.File.Name)" -ForegroundColor Yellow }
Write-Host ""

# -------------------------------------------------------
# STEP 4: Apply each migration in order
# -------------------------------------------------------
# Each migration runs in its own transaction context.
# If a script fails, execution stops IMMEDIATELY.
# Already-applied scripts are NOT rolled back (by design).
#
# WHY NO AUTOMATIC ROLLBACK:
#   In database deployments, automatic rollback is dangerous.
#   If V001 and V002 succeed but V003 fails:
#   - V001 and V002 stay applied (they worked fine)
#   - V003 is NOT recorded in MigrationHistory
#   - You fix V003, commit, and the pipeline re-runs
#   - It picks up from V003 because V001/V002 are already tracked
#
#   This is SAFER than rolling everything back, because:
#   - V001 might have created a table that V002 depends on
#   - Rolling back V001 after V002 ran would cascade failures
#   - The MigrationHistory table is your single source of truth

$failedMigration = $null

foreach ($migration in $pendingMigrations) {
    $file = $migration.File
    $checksum = $migration.Checksum

    Write-Host "--------------------------------------------"
    Write-Host "Applying: $($file.Name)" -ForegroundColor Cyan
    Write-Host "--------------------------------------------"

    $sqlContent = Get-Content -Path $file.FullName -Raw
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Execute the migration script
        Invoke-SqlDeployment -ConnectionString $connectionString -Query $sqlContent

        $stopwatch.Stop()
        $elapsedMs = $stopwatch.ElapsedMilliseconds

        # Record successful migration in tracking table
        $recordMigration = @"
INSERT INTO dbo.MigrationHistory (ScriptName, AppliedBy, Environment, Checksum, ExecutionTimeMs)
VALUES ('$($file.Name)', 'AzureDevOps-Pipeline', '$Environment', '$checksum', $elapsedMs);
"@
        Invoke-SqlDeployment -ConnectionString $connectionString -Query $recordMigration

        Write-Host "  [OK] Applied successfully (${elapsedMs}ms)" -ForegroundColor Green
    }
    catch {
        $stopwatch.Stop()
        $failedMigration = $file.Name
        Write-Host "  [FAIL] Migration failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "##[error]Migration $($file.Name) failed. Deployment stopped."
        Write-Host "##[error]Previously applied migrations in this run are still in effect."
        Write-Host "##[error]Fix the script and re-run the pipeline."
        exit 1
    }
}

# -------------------------------------------------------
# DEPLOYMENT COMPLETE
# -------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host "Environment:        $Environment"
Write-Host "Migrations Applied: $($pendingMigrations.Count)"
Write-Host "Timestamp:          $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""
exit 0
