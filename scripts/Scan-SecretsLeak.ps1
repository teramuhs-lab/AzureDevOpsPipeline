<#
.SYNOPSIS
    Scans the repository for leaked secrets and credentials.

.DESCRIPTION
    This is a DevSecOps credential scanner. It searches ALL files in the
    repository for patterns that look like passwords, API keys, connection
    strings, or tokens that should NOT be in source code.

    WHAT IT CATCHES:
    1. Connection strings with embedded passwords
    2. API keys and tokens (Azure, AWS, generic patterns)
    3. Private keys and certificates
    4. Hardcoded passwords in any file type
    5. .env files or credential files accidentally committed

    WHY THIS IS CRITICAL:
    Git remembers everything. Even if you delete a secret in a later commit,
    it's still in the Git history. Anyone who clones the repo can find it.
    The ONLY safe approach is to never commit secrets in the first place.

    This scanner is your last line of defense before code reaches the remote
    repository (when run in a PR pipeline) or before deployment (in the main
    pipeline).

    DBA PARALLEL:
    Think of this as running a security audit that checks every file for
    the equivalent of storing the 'sa' password in a stored procedure comment.
    You'd never do that manually, but automation catches what humans miss.

    DEVSECOPS CONTEXT:
    In enterprise environments, this role is filled by tools like:
    - Microsoft Credential Scanner (CredScan)
    - GitHub Secret Scanning
    - GitLeaks or TruffleHog
    This script demonstrates the concept with patterns you can customize.

.PARAMETER ScanPath
    Root directory to scan for secrets.

.EXAMPLE
    .\Scan-SecretsLeak.ps1 -ScanPath "."
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ScanPath
)

$ErrorActionPreference = 'Stop'

Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  SECRET LEAK SCANNER (DevSecOps)" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "Scan Path: $ScanPath"
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

if (-not (Test-Path $ScanPath)) {
    Write-Host "##[error]Scan directory not found: $ScanPath"
    exit 1
}

# -------------------------------------------------------
# FILE EXCLUSIONS
# -------------------------------------------------------
# Skip binary files, Git internals, and known safe files.
# The pipeline YAML files reference $(SqlAdminPassword) which
# is a variable reference, NOT an actual secret.
$excludePatterns = @(
    '*.dll', '*.exe', '*.zip', '*.gz', '*.png', '*.jpg', '*.gif',
    '*.pdf', '*.ico'
)
$excludeDirs = @('.git', 'node_modules', '.tmp', '__pycache__')

# Get all text files to scan
$filesToScan = Get-ChildItem -Path $ScanPath -Recurse -File |
    Where-Object {
        $file = $_
        $excluded = $false
        foreach ($pattern in $excludePatterns) {
            if ($file.Name -like $pattern) { $excluded = $true; break }
        }
        foreach ($dir in $excludeDirs) {
            if ($file.FullName -like "*$dir*") { $excluded = $true; break }
        }
        -not $excluded
    }

Write-Host "Scanning $($filesToScan.Count) file(s) for leaked secrets..."
Write-Host ""

$secretFindings = @()

# -------------------------------------------------------
# SECRET DETECTION RULES
# -------------------------------------------------------
# Each rule has a name, pattern, and severity.
# Patterns are regex that match common secret formats.

$rules = @(
    @{
        Name        = 'Connection String with Password'
        Pattern     = '(?i)(connection\s*string|connectionstring|sqlconnection).*password\s*=\s*[''"][^''"]{3,}[''"]'
        Severity    = 'ERROR'
        Description = 'Connection string contains an embedded password. Use Variable Groups or Azure Key Vault instead.'
    },
    @{
        Name        = 'Hardcoded Password Assignment'
        Pattern     = '(?i)(password|passwd|pwd|secret)\s*[:=]\s*[''"][^''"$\(]{4,}[''"]'
        Severity    = 'ERROR'
        Description = 'Hardcoded password detected. Secrets must come from encrypted Variable Groups, never from code.'
    },
    @{
        Name        = 'Azure Storage Key'
        Pattern     = '(?i)DefaultEndpointsProtocol=https;AccountName=.+;AccountKey=[A-Za-z0-9+/=]{40,}'
        Severity    = 'ERROR'
        Description = 'Azure Storage connection string with account key detected.'
    },
    @{
        Name        = 'Generic API Key'
        Pattern     = '(?i)(api[_-]?key|apikey)\s*[:=]\s*[''"][A-Za-z0-9]{16,}[''"]'
        Severity    = 'ERROR'
        Description = 'API key detected in source code. Use pipeline variables or Key Vault.'
    },
    @{
        Name        = 'Private Key File'
        Pattern     = '-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----'
        Severity    = 'ERROR'
        Description = 'Private key embedded in source file. Private keys must never be in source control.'
    },
    @{
        Name        = 'AWS Access Key'
        Pattern     = '(?i)AKIA[0-9A-Z]{16}'
        Severity    = 'ERROR'
        Description = 'AWS Access Key ID detected. Remove immediately and rotate the key.'
    },
    @{
        Name        = 'Generic Token Pattern'
        Pattern     = '(?i)(bearer|token|auth)\s*[:=]\s*[''"][A-Za-z0-9._\-]{20,}[''"]'
        Severity    = 'WARNING'
        Description = 'Possible authentication token detected. Verify this is not a real credential.'
    }
)

foreach ($file in $filesToScan) {
    try {
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
    }
    catch {
        continue
    }

    if ([string]::IsNullOrEmpty($content)) { continue }

    $fileHasFindings = $false

    foreach ($rule in $rules) {
        if ($content -match $rule.Pattern) {
            # Skip false positives: pipeline variable references like $(SqlAdminPassword)
            $match = [regex]::Match($content, $rule.Pattern)
            if ($match.Value -match '\$\(') { continue }

            $relativePath = $file.FullName.Replace($ScanPath, '').TrimStart('\', '/')

            if (-not $fileHasFindings) {
                Write-Host "--------------------------------------------"
                Write-Host "File: $relativePath" -ForegroundColor Yellow
                Write-Host "--------------------------------------------"
                $fileHasFindings = $true
            }

            $finding = "[$($rule.Severity)] $($rule.Name) in $relativePath"
            $secretFindings += @{
                Rule     = $rule.Name
                File     = $relativePath
                Severity = $rule.Severity
                Message  = $rule.Description
            }

            if ($rule.Severity -eq 'ERROR') {
                Write-Host "  [FAIL] $($rule.Name)" -ForegroundColor Red
                Write-Host "         $($rule.Description)" -ForegroundColor Red
            }
            else {
                Write-Host "  [WARN] $($rule.Name)" -ForegroundColor Yellow
                Write-Host "         $($rule.Description)" -ForegroundColor Yellow
            }
        }
    }
}

# -------------------------------------------------------
# SUMMARY
# -------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  SECRET SCAN SUMMARY" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "Files Scanned:  $($filesToScan.Count)"

$errorCount = ($secretFindings | Where-Object { $_.Severity -eq 'ERROR' }).Count
$warnCount = ($secretFindings | Where-Object { $_.Severity -eq 'WARNING' }).Count

Write-Host "Errors:         $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "Warnings:       $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ""

if ($errorCount -gt 0) {
    Write-Host "##[error]Secret scan FAILED. $errorCount leaked secret(s) found."
    Write-Host "##[error]Remove all secrets from source code and use Variable Groups or Azure Key Vault."
    exit 1
}

if ($warnCount -gt 0) {
    Write-Host "##[warning]$warnCount potential secret(s) flagged for review."
    Write-Host "Review the warnings above. If they are false positives, no action is needed."
}

Write-Host ""
Write-Host "Secret scan PASSED. No leaked credentials detected." -ForegroundColor Green
exit 0
