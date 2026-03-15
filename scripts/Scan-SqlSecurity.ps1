<#
.SYNOPSIS
    Scans SQL migration scripts for security vulnerabilities.

.DESCRIPTION
    This is a DevSecOps security gate. It runs AFTER validation but BEFORE
    deployment, catching security issues that syntax validation wouldn't flag.

    WHAT IT CHECKS:
    1. SQL injection patterns (dynamic SQL without parameterization)
    2. Excessive permissions (GRANT ALL, granting sysadmin)
    3. Hardcoded credentials (passwords in scripts)
    4. Unsafe configurations (disabling security features)
    5. Privilege escalation risks (WITH EXECUTE AS)

    WHY THIS EXISTS:
    A script can be syntactically valid AND functionally correct but still
    introduce security vulnerabilities. This scanner catches those patterns
    before they reach any database.

    DBA PARALLEL:
    You already do this mentally when reviewing scripts. "Why is this granting
    sysadmin?" or "Why is xp_cmdshell being enabled?" This automates that
    security instinct so every script gets the same review.

    DEVSECOPS CONTEXT:
    In DevOps, the pipeline is: Code -> Build -> Test -> Deploy
    In DevSecOps, security is embedded: Code -> SECURITY -> Build -> SECURITY -> Deploy
    This script is the first "SECURITY" checkpoint.

.PARAMETER MigrationsPath
    Path to the directory containing SQL migration files.

.EXAMPLE
    .\Scan-SqlSecurity.ps1 -MigrationsPath ".\migrations"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$MigrationsPath
)

$ErrorActionPreference = 'Stop'

Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  SQL SECURITY SCAN (DevSecOps)" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "Scan Path: $MigrationsPath"
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

if (-not (Test-Path $MigrationsPath)) {
    Write-Host "##[error]Migrations directory not found: $MigrationsPath"
    exit 1
}

$sqlFiles = Get-ChildItem -Path $MigrationsPath -Filter "*.sql" -Recurse | Sort-Object Name

if ($sqlFiles.Count -eq 0) {
    Write-Host "No SQL files to scan."
    exit 0
}

Write-Host "Scanning $($sqlFiles.Count) SQL file(s) for security issues..."
Write-Host ""

$securityErrors = @()
$securityWarnings = @()

# -------------------------------------------------------
# SECURITY RULES
# -------------------------------------------------------
# Each rule checks for a specific security anti-pattern.
# Rules are categorized by severity:
#   - ERROR: Blocks the pipeline (must be fixed)
#   - WARNING: Flagged for review (doesn't block)

foreach ($file in $sqlFiles) {
    Write-Host "--------------------------------------------"
    Write-Host "Scanning: $($file.Name)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------"

    $content = Get-Content -Path $file.FullName -Raw

    # ---------------------------------------------------
    # RULE 1: SQL Injection - Dynamic SQL without sp_executesql
    # ---------------------------------------------------
    # EXEC('SELECT * FROM ' + @table) is vulnerable to SQL injection.
    # Use sp_executesql with parameters instead.
    #
    # DBA Parallel: You'd catch this in a code review. Dynamic SQL
    # built with string concatenation is the #1 SQL injection vector.
    if ($content -match 'EXEC\s*\(\s*[''"].*\+' -or
        $content -match 'EXECUTE\s*\(\s*[''"].*\+') {
        $securityErrors += "[SQL-INJECTION] $($file.Name): Dynamic SQL with string concatenation detected. Use sp_executesql with parameters instead."
        Write-Host "  [FAIL] Dynamic SQL with concatenation (SQL injection risk)" -ForegroundColor Red
    }
    else {
        Write-Host "  [PASS] No SQL injection patterns" -ForegroundColor Green
    }

    # ---------------------------------------------------
    # RULE 2: Excessive permissions
    # ---------------------------------------------------
    # GRANT ALL, granting sysadmin/db_owner, or creating logins
    # with excessive rights should be flagged.
    #
    # DBA Parallel: Principle of least privilege. No one should get
    # more access than they need. This is OWASP #1 for databases.
    if ($content -match 'GRANT\s+ALL' -or
        $content -match 'ALTER\s+SERVER\s+ROLE\s+sysadmin\s+ADD' -or
        $content -match 'sp_addsrvrolemember.*sysadmin') {
        $securityErrors += "[EXCESSIVE-PERMS] $($file.Name): Excessive permissions detected (GRANT ALL or sysadmin). Use specific, minimal permissions."
        Write-Host "  [FAIL] Excessive permissions (GRANT ALL or sysadmin)" -ForegroundColor Red
    }
    else {
        Write-Host "  [PASS] No excessive permissions" -ForegroundColor Green
    }

    # Check for db_owner grants (warning - sometimes legitimate)
    if ($content -match 'ALTER\s+ROLE\s+db_owner\s+ADD' -or
        $content -match 'sp_addrolemember.*db_owner') {
        $securityWarnings += "[PERMS-REVIEW] $($file.Name): db_owner role grant detected. Verify this is necessary."
        Write-Host "  [WARN] db_owner role grant - verify necessity" -ForegroundColor Yellow
    }

    # ---------------------------------------------------
    # RULE 3: Hardcoded credentials
    # ---------------------------------------------------
    # Passwords, connection strings, or API keys embedded in SQL
    # scripts are a critical security risk.
    #
    # WHY: Even if you delete the password later, Git history
    # preserves it forever. Anyone with repo access can find it.
    if ($content -match 'PASSWORD\s*=\s*[''"][^''"]+[''"]' -or
        $content -match 'pwd\s*=\s*[''"][^''"]+[''"]') {
        $securityErrors += "[HARDCODED-CRED] $($file.Name): Hardcoded password detected. Use pipeline variables or Azure Key Vault instead."
        Write-Host "  [FAIL] Hardcoded credentials found" -ForegroundColor Red
    }
    else {
        Write-Host "  [PASS] No hardcoded credentials" -ForegroundColor Green
    }

    # ---------------------------------------------------
    # RULE 4: Dangerous system configurations
    # ---------------------------------------------------
    # Enabling xp_cmdshell, OLE Automation, or disabling security
    # features should NEVER happen through migration scripts.
    #
    # DBA Parallel: These are the settings you'd flag in a security
    # audit. xp_cmdshell enables OS command execution from SQL Server.
    if ($content -match 'xp_cmdshell' -or
        $content -match 'sp_configure\s+[''"]xp_cmdshell[''"]' -or
        $content -match 'sp_configure\s+[''"]Ole Automation') {
        $securityErrors += "[DANGEROUS-CONFIG] $($file.Name): Dangerous server configuration change (xp_cmdshell or OLE Automation). These should not be in migration scripts."
        Write-Host "  [FAIL] Dangerous server configuration change" -ForegroundColor Red
    }
    else {
        Write-Host "  [PASS] No dangerous configuration changes" -ForegroundColor Green
    }

    # ---------------------------------------------------
    # RULE 5: Privilege escalation via EXECUTE AS
    # ---------------------------------------------------
    # WITH EXECUTE AS 'dbo' or EXECUTE AS OWNER can escalate
    # privileges. Flag for review.
    if ($content -match 'EXECUTE\s+AS\s+[''"]?\w+[''"]?' -or
        $content -match 'WITH\s+EXECUTE\s+AS') {
        $securityWarnings += "[PRIV-ESCALATION] $($file.Name): EXECUTE AS detected. Verify this doesn't escalate privileges unnecessarily."
        Write-Host "  [WARN] EXECUTE AS detected - review for privilege escalation" -ForegroundColor Yellow
    }

    # ---------------------------------------------------
    # RULE 6: Disabling audit or security features
    # ---------------------------------------------------
    if ($content -match 'ALTER\s+DATABASE.*SET\s+TRUSTWORTHY\s+ON' -or
        $content -match 'ALTER\s+DATABASE.*SET\s+DB_CHAINING\s+ON') {
        $securityErrors += "[SECURITY-DISABLE] $($file.Name): Security feature being disabled (TRUSTWORTHY or DB_CHAINING). This weakens database security."
        Write-Host "  [FAIL] Security feature being disabled" -ForegroundColor Red
    }
    else {
        Write-Host "  [PASS] Security features intact" -ForegroundColor Green
    }

    Write-Host ""
}

# -------------------------------------------------------
# SUMMARY
# -------------------------------------------------------
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  SECURITY SCAN SUMMARY" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "Files Scanned:      $($sqlFiles.Count)"
Write-Host "Security Errors:    $($securityErrors.Count)" -ForegroundColor $(if ($securityErrors.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "Security Warnings:  $($securityWarnings.Count)" -ForegroundColor $(if ($securityWarnings.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ""

if ($securityWarnings.Count -gt 0) {
    Write-Host "SECURITY WARNINGS (review recommended):" -ForegroundColor Yellow
    $securityWarnings | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host ""
}

if ($securityErrors.Count -gt 0) {
    Write-Host "SECURITY ERRORS (must fix before deployment):" -ForegroundColor Red
    $securityErrors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "##[error]Security scan FAILED with $($securityErrors.Count) finding(s). Fix the issues above before deploying."
    exit 1
}

Write-Host "Security scan PASSED. No security vulnerabilities detected." -ForegroundColor Green
exit 0
