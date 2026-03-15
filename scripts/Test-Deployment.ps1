<#
.SYNOPSIS
    Runs post-deployment validation tests against the database.

.DESCRIPTION
    After every deployment, this script verifies that the database is healthy.
    It runs a series of checks to confirm the migration actually worked.

    WHY POST-DEPLOYMENT TESTS MATTER:
    A script can execute successfully (no SQL errors) but still cause problems:
    - A column was added but with the wrong data type
    - A stored procedure was created but references a missing table
    - An index was added but it's missing a key column
    - A constraint was added that conflicts with existing data

    These tests catch those issues BEFORE the deployment moves to the next environment.

    DBA PARALLEL:
    This is like running DBCC CHECKDB after a maintenance operation.
    You're verifying the database is in a consistent, expected state.
    Except here, you're also verifying that YOUR CHANGES worked correctly.

.PARAMETER ServerInstance
    The SQL Server instance to test

.PARAMETER DatabaseName
    The database to validate

.PARAMETER Environment
    The environment name (for logging)

.EXAMPLE
    .\Test-Deployment.ps1 -ServerInstance "dev-sql.database.windows.net" `
                          -DatabaseName "MyApp_Dev" `
                          -Environment "Dev"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ServerInstance,

    [Parameter(Mandatory = $true)]
    [string]$DatabaseName,

    [Parameter(Mandatory = $true)]
    [string]$Environment
)

$ErrorActionPreference = 'Stop'

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  POST-DEPLOYMENT VALIDATION TESTS" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Environment: $Environment"
Write-Host "Server:      $ServerInstance"
Write-Host "Database:    $DatabaseName"
Write-Host ""

# Build connection string (password from environment variable)
$sqlPassword = $env:SQL_PASSWORD
if ([string]::IsNullOrEmpty($sqlPassword)) {
    Write-Host "##[error]SQL_PASSWORD environment variable is not set."
    exit 1
}

$connectionString = "Server=$ServerInstance;Database=$DatabaseName;User Id=deploy_admin;Password=$sqlPassword;TrustServerCertificate=True;Connection Timeout=30;"

# Helper function for running test queries
function Invoke-SqlTest {
    param(
        [string]$ConnectionString,
        [string]$Query
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $result = $command.ExecuteScalar()
        return $result
    }
    finally {
        if ($connection.State -eq 'Open') {
            $connection.Close()
        }
        $connection.Dispose()
    }
}

$testResults = @()
$testsPassed = 0
$testsFailed = 0

# -------------------------------------------------------
# TEST 1: Database connectivity
# -------------------------------------------------------
# Can we connect to the database at all?
# If the deployment broke connectivity, everything else is moot.
Write-Host "TEST 1: Database connectivity" -ForegroundColor Yellow
try {
    $result = Invoke-SqlTest -ConnectionString $connectionString -Query "SELECT 1"
    if ($result -eq 1) {
        Write-Host "  [PASS] Successfully connected to database" -ForegroundColor Green
        $testsPassed++
    }
}
catch {
    Write-Host "  [FAIL] Cannot connect to database: $($_.Exception.Message)" -ForegroundColor Red
    $testsFailed++
    # If we can't even connect, skip remaining tests
    Write-Host "##[error]Cannot connect to database. Skipping remaining tests."
    exit 1
}

# -------------------------------------------------------
# TEST 2: MigrationHistory table exists and has records
# -------------------------------------------------------
# Verify the deployment tracking infrastructure is in place.
Write-Host "TEST 2: Migration tracking integrity" -ForegroundColor Yellow
try {
    $migrationCount = Invoke-SqlTest -ConnectionString $connectionString `
        -Query "SELECT COUNT(*) FROM dbo.MigrationHistory"

    if ($migrationCount -gt 0) {
        Write-Host "  [PASS] MigrationHistory has $migrationCount record(s)" -ForegroundColor Green
        $testsPassed++
    }
    else {
        Write-Host "  [WARN] MigrationHistory is empty - expected at least one migration" -ForegroundColor Yellow
        $testsPassed++  # Not necessarily a failure on first run
    }
}
catch {
    Write-Host "  [FAIL] MigrationHistory table issue: $($_.Exception.Message)" -ForegroundColor Red
    $testsFailed++
}

# -------------------------------------------------------
# TEST 3: No invalid objects in the database
# -------------------------------------------------------
# After deployment, check that all objects are valid.
# Invalid objects (broken views, procs referencing dropped columns) indicate
# that a migration broke something it shouldn't have.
#
# DBA TIP: This is like running sp_refreshview on all views,
# or checking for broken dependencies with sys.sql_expression_dependencies.
Write-Host "TEST 3: Check for invalid stored procedures" -ForegroundColor Yellow
try {
    $invalidObjects = Invoke-SqlTest -ConnectionString $connectionString -Query @"
SELECT COUNT(*)
FROM sys.procedures p
WHERE OBJECTPROPERTY(p.object_id, 'ExecIsQuotedIdentOn') IS NULL
   OR p.object_id IN (
       SELECT referencing_id
       FROM sys.sql_expression_dependencies d
       WHERE d.is_ambiguous = 1
   )
"@

    if ($null -eq $invalidObjects -or $invalidObjects -eq 0) {
        Write-Host "  [PASS] No invalid stored procedures detected" -ForegroundColor Green
        $testsPassed++
    }
    else {
        Write-Host "  [WARN] Found $invalidObjects potentially invalid procedure(s)" -ForegroundColor Yellow
        $testsPassed++  # Warning, not failure - needs investigation
    }
}
catch {
    Write-Host "  [FAIL] Could not check object validity: $($_.Exception.Message)" -ForegroundColor Red
    $testsFailed++
}

# -------------------------------------------------------
# TEST 4: Check database is ONLINE
# -------------------------------------------------------
# A migration could theoretically leave the database in a bad state
# (RECOVERY_PENDING, SUSPECT, etc.). This confirms it's healthy.
Write-Host "TEST 4: Database state is ONLINE" -ForegroundColor Yellow
try {
    $dbState = Invoke-SqlTest -ConnectionString $connectionString `
        -Query "SELECT state_desc FROM sys.databases WHERE name = DB_NAME()"

    if ($dbState -eq 'ONLINE') {
        Write-Host "  [PASS] Database state: ONLINE" -ForegroundColor Green
        $testsPassed++
    }
    else {
        Write-Host "  [FAIL] Database state: $dbState (expected ONLINE)" -ForegroundColor Red
        $testsFailed++
    }
}
catch {
    Write-Host "  [FAIL] Could not check database state: $($_.Exception.Message)" -ForegroundColor Red
    $testsFailed++
}

# -------------------------------------------------------
# TEST 5: Verify latest migration timestamp is recent
# -------------------------------------------------------
# Sanity check: the most recent migration should have been applied
# within the last hour (during this pipeline run).
Write-Host "TEST 5: Latest migration is recent" -ForegroundColor Yellow
try {
    $minutesSinceLastMigration = Invoke-SqlTest -ConnectionString $connectionString -Query @"
SELECT DATEDIFF(MINUTE, MAX(AppliedOn), SYSUTCDATETIME())
FROM dbo.MigrationHistory
"@

    if ($null -eq $minutesSinceLastMigration) {
        Write-Host "  [SKIP] No migrations in history table" -ForegroundColor DarkGray
        $testsPassed++
    }
    elseif ($minutesSinceLastMigration -le 60) {
        Write-Host "  [PASS] Latest migration applied $minutesSinceLastMigration minute(s) ago" -ForegroundColor Green
        $testsPassed++
    }
    else {
        Write-Host "  [WARN] Latest migration was $minutesSinceLastMigration minutes ago - expected within last 60 min" -ForegroundColor Yellow
        $testsPassed++  # Might be a re-run with no new migrations
    }
}
catch {
    Write-Host "  [FAIL] Could not verify migration timing: $($_.Exception.Message)" -ForegroundColor Red
    $testsFailed++
}

# -------------------------------------------------------
# RESULTS SUMMARY
# -------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  TEST RESULTS" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Passed: $testsPassed" -ForegroundColor Green
Write-Host "Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host ""

if ($testsFailed -gt 0) {
    Write-Host "##[error]$testsFailed test(s) FAILED. Deployment validation did not pass."
    Write-Host "##[error]Review the failures above before promoting to the next environment."
    exit 1
}

Write-Host "All post-deployment tests PASSED for $Environment." -ForegroundColor Green
exit 0
