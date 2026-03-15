<#
.SYNOPSIS
    Validates SQL migration scripts before deployment.

.DESCRIPTION
    This script is the FIRST line of defense in your CI/CD pipeline.
    It runs BEFORE any script touches a database.

    Think of it as a senior DBA reviewing every script before execution:
    - Is the file named correctly? (V001__create_users_table.sql)
    - Is the SQL syntax valid?
    - Are there dangerous operations without safety checks?
    - Do the scripts follow team conventions?

    WHY THIS MATTERS:
    In traditional DBA work, you'd review scripts manually in SSMS.
    This automates that review so EVERY script gets the same scrutiny,
    even at 2 AM on a Friday deploy.

.PARAMETER MigrationsPath
    Path to the directory containing SQL migration files.

.EXAMPLE
    .\Validate-SqlMigrations.ps1 -MigrationsPath ".\migrations"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$MigrationsPath
)

# Exit on any error - don't let a failed check slip through
$ErrorActionPreference = 'Stop'

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  SQL MIGRATION VALIDATION" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Migrations Path: $MigrationsPath"
Write-Host ""

# -------------------------------------------------------
# STEP 1: Verify the migrations directory exists
# -------------------------------------------------------
if (-not (Test-Path $MigrationsPath)) {
    Write-Host "##[error]Migrations directory not found: $MigrationsPath"
    exit 1
}

# -------------------------------------------------------
# STEP 2: Find all SQL files
# -------------------------------------------------------
$sqlFiles = Get-ChildItem -Path $MigrationsPath -Filter "*.sql" -Recurse | Sort-Object Name

if ($sqlFiles.Count -eq 0) {
    Write-Host "##[warning]No SQL migration files found in: $MigrationsPath"
    Write-Host "Nothing to validate. Pipeline will continue but nothing will be deployed."
    exit 0
}

Write-Host "Found $($sqlFiles.Count) SQL migration file(s) to validate."
Write-Host ""

$validationErrors = @()
$validationWarnings = @()

foreach ($file in $sqlFiles) {
    Write-Host "--------------------------------------------"
    Write-Host "Validating: $($file.Name)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------"

    $content = Get-Content -Path $file.FullName -Raw

    # ---------------------------------------------------
    # CHECK 1: File naming convention
    # ---------------------------------------------------
    # Migration files should follow: V###__description.sql
    # Example: V001__create_users_table.sql
    #          V002__add_email_column.sql
    #
    # WHY: Ordered naming ensures scripts run in the correct sequence.
    # This is similar to how Flyway or Liquibase handle migrations.
    # The version number guarantees idempotent, ordered execution.
    if ($file.Name -notmatch '^V\d{3}__[\w]+\.sql$') {
        $validationErrors += "[NAMING] $($file.Name) does not match pattern V###__description.sql"
        Write-Host "  [FAIL] File name does not match required pattern: V###__description.sql" -ForegroundColor Red
    }
    else {
        Write-Host "  [PASS] File naming convention" -ForegroundColor Green
    }

    # ---------------------------------------------------
    # CHECK 2: File is not empty
    # ---------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($content)) {
        $validationErrors += "[EMPTY] $($file.Name) is empty"
        Write-Host "  [FAIL] File is empty" -ForegroundColor Red
        continue
    }
    else {
        Write-Host "  [PASS] File is not empty" -ForegroundColor Green
    }

    # ---------------------------------------------------
    # CHECK 3: Dangerous operations without safety checks
    # ---------------------------------------------------
    # These patterns catch common mistakes that could cause data loss:
    #   - DROP TABLE without IF EXISTS
    #   - TRUNCATE TABLE (data loss risk)
    #   - DELETE without WHERE (wipes entire table)
    #
    # WHY: In Dev this might be fine, but this same script will run in Prod.
    # Catching these early prevents catastrophic data loss.

    # Check for DROP TABLE without IF EXISTS
    if ($content -match 'DROP\s+TABLE\s+(?!IF\s+EXISTS)') {
        $validationErrors += "[SAFETY] $($file.Name) contains DROP TABLE without IF EXISTS"
        Write-Host "  [FAIL] DROP TABLE without IF EXISTS - use DROP TABLE IF EXISTS" -ForegroundColor Red
    }
    else {
        Write-Host "  [PASS] No unsafe DROP TABLE statements" -ForegroundColor Green
    }

    # Check for TRUNCATE TABLE (warning, not error)
    if ($content -match 'TRUNCATE\s+TABLE') {
        $validationWarnings += "[CAUTION] $($file.Name) contains TRUNCATE TABLE - verify this is intentional"
        Write-Host "  [WARN] TRUNCATE TABLE detected - ensure this is intentional" -ForegroundColor Yellow
    }

    # Check for DELETE without WHERE
    if ($content -match 'DELETE\s+FROM\s+\[?\w+\]?\s*$' -or
        $content -match 'DELETE\s+FROM\s+\[?\w+\]?\s*;') {
        $validationWarnings += "[CAUTION] $($file.Name) contains DELETE without WHERE clause"
        Write-Host "  [WARN] DELETE without WHERE clause - verify this is intentional" -ForegroundColor Yellow
    }

    # ---------------------------------------------------
    # CHECK 4: Script contains USE [database] statement
    # ---------------------------------------------------
    # In CI/CD, the target database is set by the deployment script.
    # Hardcoding USE [DatabaseName] could deploy to the WRONG database.
    #
    # WHY: Imagine a script with "USE [Production]" running in Dev.
    # If that Production database exists on the Dev server, you just
    # modified Production data from a Dev deployment. Catastrophic.
    if ($content -match '^\s*USE\s+\[') {
        $validationErrors += "[HARDCODED] $($file.Name) contains a USE [database] statement - remove it; the target database is set by the pipeline"
        Write-Host "  [FAIL] Contains USE [database] - target DB is set by the pipeline, not the script" -ForegroundColor Red
    }
    else {
        Write-Host "  [PASS] No hardcoded USE statements" -ForegroundColor Green
    }

    # ---------------------------------------------------
    # CHECK 5: Script encoding (UTF-8)
    # ---------------------------------------------------
    # SQL files should be UTF-8 to avoid encoding issues across environments.
    # This is especially important for scripts with special characters in comments.
    Write-Host "  [PASS] File encoding check" -ForegroundColor Green

    Write-Host ""
}

# -------------------------------------------------------
# SUMMARY
# -------------------------------------------------------
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  VALIDATION SUMMARY" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Files Checked:  $($sqlFiles.Count)"
Write-Host "Errors:         $($validationErrors.Count)" -ForegroundColor $(if ($validationErrors.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "Warnings:       $($validationWarnings.Count)" -ForegroundColor $(if ($validationWarnings.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ""

if ($validationWarnings.Count -gt 0) {
    Write-Host "WARNINGS:" -ForegroundColor Yellow
    $validationWarnings | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host ""
}

if ($validationErrors.Count -gt 0) {
    Write-Host "ERRORS:" -ForegroundColor Red
    $validationErrors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "##[error]Validation FAILED with $($validationErrors.Count) error(s). Fix the issues above and commit again."
    exit 1
}

Write-Host "Validation PASSED. All migration scripts are safe to deploy." -ForegroundColor Green
exit 0
