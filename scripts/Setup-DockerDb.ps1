<#
.SYNOPSIS
    Sets up the local Docker SQL Server and creates the DevOpsDemo database.

.DESCRIPTION
    This script automates what you'd normally do manually after installing SQL Server:
    1. Starts SQL Server in Docker (docker compose up)
    2. Waits for SQL Server to be ready (like waiting for the service to start)
    3. Creates the DevOpsDemo database
    4. Verifies the connection works

    DBA PARALLEL:
    This is the scripted equivalent of:
    1. Starting SQL Server service in services.msc
    2. Opening SSMS and connecting
    3. Running CREATE DATABASE
    4. Running a quick SELECT to verify

    DOCKER CONCEPTS FOR DBAs:
    - Container = a running instance of SQL Server (like a SQL Server service)
    - Image = the SQL Server installer package (like the .iso file)
    - Volume = where .mdf/.ldf files are stored (like default data directory)
    - docker compose up = Start SQL Server (like net start MSSQLSERVER)
    - docker compose down = Stop SQL Server (like net stop MSSQLSERVER)

.EXAMPLE
    .\Setup-DockerDb.ps1
#>

$ErrorActionPreference = 'Stop'

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  DOCKER SQL SERVER SETUP" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------------
# STEP 1: Check Docker is running
# -------------------------------------------------------
Write-Host "Step 1: Checking Docker..." -ForegroundColor Yellow
try {
    $dockerVersion = docker --version 2>&1
    Write-Host "  Docker found: $dockerVersion" -ForegroundColor Green
}
catch {
    Write-Host "  [FAIL] Docker is not installed or not running." -ForegroundColor Red
    Write-Host "  Install Docker Desktop from https://www.docker.com/products/docker-desktop/" -ForegroundColor Red
    exit 1
}

# Check Docker daemon is running
try {
    docker info 2>&1 | Out-Null
    Write-Host "  Docker daemon is running." -ForegroundColor Green
}
catch {
    Write-Host "  [FAIL] Docker daemon is not running. Start Docker Desktop." -ForegroundColor Red
    exit 1
}

Write-Host ""

# -------------------------------------------------------
# STEP 2: Start SQL Server container
# -------------------------------------------------------
# "docker compose up -d" does several things:
#   1. Downloads the SQL Server image (first time only - like downloading the installer)
#   2. Creates a container from that image (like installing SQL Server)
#   3. Starts the container (like starting the SQL Server service)
#   -d means "detached" - runs in the background (like a Windows service)
Write-Host "Step 2: Starting SQL Server container..." -ForegroundColor Yellow

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (Test-Path "$projectRoot/docker-compose.yml") {
    $composeDir = $projectRoot
} elseif (Test-Path "$PSScriptRoot/../docker-compose.yml") {
    $composeDir = (Resolve-Path "$PSScriptRoot/..").Path
} else {
    $composeDir = Get-Location
}

Push-Location $composeDir
try {
    docker compose up -d 2>&1
    Write-Host "  Container started." -ForegroundColor Green
}
catch {
    Write-Host "  [FAIL] Could not start container: $_" -ForegroundColor Red
    Pop-Location
    exit 1
}
Pop-Location

Write-Host ""

# -------------------------------------------------------
# STEP 3: Wait for SQL Server to be ready
# -------------------------------------------------------
# SQL Server takes 15-30 seconds to initialize inside the container.
# This is like waiting for the SQL Server service status to show "Running."
# We poll with a simple SELECT 1 query until it responds.
Write-Host "Step 3: Waiting for SQL Server to be ready..." -ForegroundColor Yellow

$maxAttempts = 30
$attempt = 0
$ready = $false

while ($attempt -lt $maxAttempts -and -not $ready) {
    $attempt++
    try {
        # Test TCP connectivity to port 1434
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("localhost", 1434)
        $tcp.Close()

        # Try a SQL connection via Python (works on Mac without sqlcmd)
        $pyResult = python3 -c "
import pymssql
try:
    conn = pymssql.connect(server='localhost', port=1434, user='sa', password='DevOps#Pass123', login_timeout=3)
    conn.close()
    print('OK')
except:
    print('FAIL')
" 2>&1

        if ($pyResult -eq 'OK') {
            $ready = $true
            Write-Host "  SQL Server is ready! (attempt $attempt)" -ForegroundColor Green
        }
    }
    catch {
        # Not ready yet
    }

    if (-not $ready) {
        Write-Host "  Waiting... (attempt $attempt/$maxAttempts)" -ForegroundColor Gray
        Start-Sleep -Seconds 2
    }
}

if (-not $ready) {
    Write-Host "  [FAIL] SQL Server did not start within 60 seconds." -ForegroundColor Red
    Write-Host "  Check logs: docker compose logs sql-server" -ForegroundColor Red
    exit 1
}

Write-Host ""

# -------------------------------------------------------
# STEP 4: Create DevOpsDemo database
# -------------------------------------------------------
# This is your development database - the same one your pipeline deploys to.
# The migration scripts (V001, V002, etc.) will run against this database.
Write-Host "Step 4: Creating DevOpsDemo database..." -ForegroundColor Yellow

$pyResult = python3 -c "
import pymssql
conn = pymssql.connect(server='localhost', port=1434, user='sa', password='DevOps#Pass123', autocommit=True)
cursor = conn.cursor()
cursor.execute(""IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'DevOpsDemo') CREATE DATABASE DevOpsDemo"")
print('OK')
conn.close()
" 2>&1

if ($pyResult -eq 'OK') {
    Write-Host "  Database ready." -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Could not create database: $pyResult" -ForegroundColor Red
    exit 1
}

Write-Host ""

# -------------------------------------------------------
# STEP 5: Verify connection
# -------------------------------------------------------
Write-Host "Step 5: Verifying setup..." -ForegroundColor Yellow

python3 -c "
import pymssql
conn = pymssql.connect(server='localhost', port=1434, user='sa', password='DevOps#Pass123', database='DevOpsDemo')
cursor = conn.cursor()
cursor.execute('SELECT @@SERVERNAME, @@VERSION')
row = cursor.fetchone()
print(f'  Server:   {row[0]}')
print(f'  Version:  {row[1][:70]}')
cursor.execute('SELECT name FROM sys.databases ORDER BY name')
print('  Databases:')
for row in cursor:
    print(f'    - {row[0]}')
conn.close()
"

Write-Host ""

# -------------------------------------------------------
# SUMMARY
# -------------------------------------------------------
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  SETUP COMPLETE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "SQL Server is running in Docker." -ForegroundColor Green
Write-Host ""
Write-Host "Connection Details:" -ForegroundColor Yellow
Write-Host "  Server:    localhost,1434"
Write-Host "  Database:  DevOpsDemo"
Write-Host "  Login:     sa"
Write-Host "  Password:  DevOps#Pass123"
Write-Host ""
Write-Host "Useful Commands:" -ForegroundColor Yellow
Write-Host "  Stop:      docker compose down"
Write-Host "  Start:     docker compose up -d"
Write-Host "  Destroy:   docker compose down -v  (deletes all data)"
Write-Host "  Logs:      docker compose logs -f sql-server"
Write-Host "  SQL Shell: docker exec -it sql-dev-local /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'DevOps#Pass123' -No"
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Connect with Azure Data Studio: localhost,1434"
Write-Host "  2. Run your migration scripts against DevOpsDemo"
Write-Host "  3. Test your pipeline deployment locally"
Write-Host ""
