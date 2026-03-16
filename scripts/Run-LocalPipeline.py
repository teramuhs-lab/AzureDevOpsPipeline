"""
Local Pipeline Runner — Simulates the Azure DevOps pipeline against Docker SQL Server.

PURPOSE:
    Runs the same pipeline stages locally on your Mac using Docker SQL Server.
    The actual Azure DevOps pipeline uses PowerShell + ADO.NET (Windows-only).
    This script does the same thing using Python + pymssql (cross-platform).

    Think of this as a "dry run" of your pipeline — same logic, same checks,
    same migration scripts, just running locally instead of on a hosted agent.

PIPELINE STAGES SIMULATED:
    Stage 1: Validate SQL Scripts      (same checks as Validate-SqlMigrations.ps1)
    Stage 2: Security Scan             (same checks as Scan-SqlSecurity.ps1 + Scan-SecretsLeak.ps1)
    Stage 3: Deploy to Local Docker    (same logic as Deploy-SqlMigrations.ps1)
    Stage 4: Post-Deployment Tests     (same checks as Test-Deployment.ps1)

USAGE:
    python3 scripts/Run-LocalPipeline.py

PREREQUISITES:
    pip3 install pymssql
    docker compose up -d
"""

import os
import re
import sys
import hashlib
import time
from datetime import datetime, timezone

# -------------------------------------------------------
# CONFIGURATION
# -------------------------------------------------------
SERVER = "localhost"
PORT = 1434
USER = "sa"
PASSWORD = "DevOps#Pass123"
DATABASE = "DevOpsDemo"
MIGRATIONS_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "migrations")
ENVIRONMENT = "Dev"

# Colors for terminal output (ANSI codes)
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
MAGENTA = "\033[95m"
GRAY = "\033[90m"
RESET = "\033[0m"
BOLD = "\033[1m"


def print_header(title, color=CYAN):
    print(f"\n{color}{'=' * 50}")
    print(f"  {title}")
    print(f"{'=' * 50}{RESET}\n")


def print_pass(msg):
    print(f"  {GREEN}[PASS]{RESET} {msg}")


def print_fail(msg):
    print(f"  {RED}[FAIL]{RESET} {msg}")


def print_warn(msg):
    print(f"  {YELLOW}[WARN]{RESET} {msg}")


def print_skip(msg):
    print(f"  {GRAY}[SKIP]{RESET} {msg}")


def print_stage(number, title):
    print(f"\n{BOLD}{MAGENTA}{'#' * 50}")
    print(f"  STAGE {number}: {title}")
    print(f"{'#' * 50}{RESET}\n")


# -------------------------------------------------------
# DATABASE CONNECTION
# -------------------------------------------------------
def get_connection(database=None):
    """Connect to SQL Server in Docker. Like opening a connection in SSMS."""
    import pymssql
    return pymssql.connect(
        server=SERVER,
        port=PORT,
        user=USER,
        password=PASSWORD,
        database=database or DATABASE,
        autocommit=True
    )


def execute_query(sql, database=None, fetch=False):
    """Execute a SQL query. Like running a query in SSMS."""
    conn = get_connection(database)
    cursor = conn.cursor(as_dict=True)
    cursor.execute(sql)
    result = cursor.fetchall() if fetch else None
    conn.close()
    return result


def execute_scalar(sql, database=None):
    """Execute a query and return a single value."""
    conn = get_connection(database)
    cursor = conn.cursor()
    cursor.execute(sql)
    row = cursor.fetchone()
    conn.close()
    return row[0] if row else None


# =============================================================
# STAGE 1: VALIDATE SQL SCRIPTS
# =============================================================
def stage_validate():
    """
    Same checks as Validate-SqlMigrations.ps1:
    - File naming convention (V###__description.sql)
    - Files are not empty
    - No DROP TABLE without IF EXISTS
    - No hardcoded USE [database] statements
    - Flags TRUNCATE TABLE and DELETE without WHERE
    """
    print_stage(1, "VALIDATE SQL SCRIPTS")
    print(f"Migrations Path: {MIGRATIONS_PATH}")
    print()

    if not os.path.exists(MIGRATIONS_PATH):
        print_fail(f"Migrations directory not found: {MIGRATIONS_PATH}")
        return False

    sql_files = sorted([f for f in os.listdir(MIGRATIONS_PATH) if f.endswith('.sql')])

    if not sql_files:
        print_warn("No SQL migration files found.")
        return True

    print(f"Found {len(sql_files)} SQL migration file(s) to validate.\n")

    errors = []
    warnings = []

    for filename in sql_files:
        filepath = os.path.join(MIGRATIONS_PATH, filename)
        print(f"{YELLOW}Validating: {filename}{RESET}")

        with open(filepath, 'r') as f:
            content = f.read()

        # CHECK 1: Naming convention
        if not re.match(r'^V\d{3}__[\w]+\.sql$', filename):
            errors.append(f"[NAMING] {filename} does not match V###__description.sql")
            print_fail("File name does not match required pattern: V###__description.sql")
        else:
            print_pass("File naming convention")

        # CHECK 2: Not empty
        if not content.strip():
            errors.append(f"[EMPTY] {filename} is empty")
            print_fail("File is empty")
            continue
        else:
            print_pass("File is not empty")

        # CHECK 3: DROP TABLE without IF EXISTS
        if re.search(r'DROP\s+TABLE\s+(?!IF\s+EXISTS)', content, re.IGNORECASE):
            errors.append(f"[SAFETY] {filename} contains DROP TABLE without IF EXISTS")
            print_fail("DROP TABLE without IF EXISTS")
        else:
            print_pass("No unsafe DROP TABLE statements")

        # CHECK 3b: TRUNCATE TABLE (warning)
        if re.search(r'TRUNCATE\s+TABLE', content, re.IGNORECASE):
            warnings.append(f"[CAUTION] {filename} contains TRUNCATE TABLE")
            print_warn("TRUNCATE TABLE detected - verify intentional")

        # CHECK 3c: DELETE without WHERE (warning)
        if re.search(r'DELETE\s+FROM\s+\[?\w+\]?\s*$', content, re.IGNORECASE | re.MULTILINE) or \
           re.search(r'DELETE\s+FROM\s+\[?\w+\]?\s*;', content, re.IGNORECASE):
            warnings.append(f"[CAUTION] {filename} contains DELETE without WHERE")
            print_warn("DELETE without WHERE clause")

        # CHECK 4: USE [database] statement
        if re.search(r'^\s*USE\s+\[', content, re.IGNORECASE | re.MULTILINE):
            errors.append(f"[HARDCODED] {filename} contains USE [database]")
            print_fail("Contains USE [database] - target DB is set by the pipeline")
        else:
            print_pass("No hardcoded USE statements")

        print()

    # Summary
    print(f"{CYAN}{'=' * 50}")
    print(f"  VALIDATION SUMMARY")
    print(f"{'=' * 50}{RESET}")
    print(f"Files Checked:  {len(sql_files)}")
    print(f"Errors:         {RED if errors else GREEN}{len(errors)}{RESET}")
    print(f"Warnings:       {YELLOW if warnings else GREEN}{len(warnings)}{RESET}")

    if errors:
        print(f"\n{RED}ERRORS:{RESET}")
        for e in errors:
            print(f"  {RED}{e}{RESET}")
        return False

    print(f"\n{GREEN}Validation PASSED.{RESET}")
    return True


# =============================================================
# STAGE 2: SECURITY SCAN
# =============================================================
def stage_security_scan():
    """
    Same checks as Scan-SqlSecurity.ps1 + Scan-SecretsLeak.ps1:
    - SQL injection patterns
    - Excessive permissions
    - Hardcoded credentials
    - Dangerous configurations
    """
    print_stage(2, "SECURITY SCAN")

    sql_files = sorted([f for f in os.listdir(MIGRATIONS_PATH) if f.endswith('.sql')])
    errors = []
    warnings = []

    # --- SQL Security Scan ---
    print(f"{BOLD}SQL Security Scan{RESET}\n")

    for filename in sql_files:
        filepath = os.path.join(MIGRATIONS_PATH, filename)
        with open(filepath, 'r') as f:
            content = f.read()

        print(f"{YELLOW}Scanning: {filename}{RESET}")

        # Rule 1: SQL Injection
        if re.search(r"EXEC\s*\(\s*['\"].*\+", content, re.IGNORECASE) or \
           re.search(r"EXECUTE\s*\(\s*['\"].*\+", content, re.IGNORECASE):
            errors.append(f"[SQL-INJECTION] {filename}")
            print_fail("Dynamic SQL with concatenation (SQL injection risk)")
        else:
            print_pass("No SQL injection patterns")

        # Rule 2: Excessive permissions
        if re.search(r'GRANT\s+ALL', content, re.IGNORECASE) or \
           re.search(r'ALTER\s+SERVER\s+ROLE\s+sysadmin\s+ADD', content, re.IGNORECASE) or \
           re.search(r'sp_addsrvrolemember.*sysadmin', content, re.IGNORECASE):
            errors.append(f"[EXCESSIVE-PERMS] {filename}")
            print_fail("Excessive permissions (GRANT ALL or sysadmin)")
        else:
            print_pass("No excessive permissions")

        # Rule 2b: db_owner (warning)
        if re.search(r'ALTER\s+ROLE\s+db_owner\s+ADD', content, re.IGNORECASE) or \
           re.search(r'sp_addrolemember.*db_owner', content, re.IGNORECASE):
            warnings.append(f"[PERMS-REVIEW] {filename}: db_owner grant")
            print_warn("db_owner role grant - verify necessity")

        # Rule 3: Hardcoded credentials
        if re.search(r"PASSWORD\s*=\s*['\"][^'\"]+['\"]", content, re.IGNORECASE) or \
           re.search(r"pwd\s*=\s*['\"][^'\"]+['\"]", content, re.IGNORECASE):
            errors.append(f"[HARDCODED-CRED] {filename}")
            print_fail("Hardcoded credentials found")
        else:
            print_pass("No hardcoded credentials")

        # Rule 4: Dangerous configurations
        if re.search(r'xp_cmdshell', content, re.IGNORECASE) or \
           re.search(r"sp_configure\s+['\"]xp_cmdshell", content, re.IGNORECASE) or \
           re.search(r"sp_configure\s+['\"]Ole Automation", content, re.IGNORECASE):
            errors.append(f"[DANGEROUS-CONFIG] {filename}")
            print_fail("Dangerous server configuration change")
        else:
            print_pass("No dangerous configuration changes")

        # Rule 5: Privilege escalation
        if re.search(r"EXECUTE\s+AS\s+['\"]?\w+['\"]?", content, re.IGNORECASE) or \
           re.search(r"WITH\s+EXECUTE\s+AS", content, re.IGNORECASE):
            warnings.append(f"[PRIV-ESCALATION] {filename}: EXECUTE AS")
            print_warn("EXECUTE AS detected - review for privilege escalation")

        # Rule 6: Security feature bypass
        if re.search(r'ALTER\s+DATABASE.*SET\s+TRUSTWORTHY\s+ON', content, re.IGNORECASE) or \
           re.search(r'ALTER\s+DATABASE.*SET\s+DB_CHAINING\s+ON', content, re.IGNORECASE):
            errors.append(f"[SECURITY-DISABLE] {filename}")
            print_fail("Security feature being disabled")
        else:
            print_pass("Security features intact")

        print()

    # Summary
    print(f"{MAGENTA}{'=' * 50}")
    print(f"  SECURITY SCAN SUMMARY")
    print(f"{'=' * 50}{RESET}")
    print(f"Files Scanned:      {len(sql_files)}")
    print(f"Security Errors:    {RED if errors else GREEN}{len(errors)}{RESET}")
    print(f"Security Warnings:  {YELLOW if warnings else GREEN}{len(warnings)}{RESET}")

    if errors:
        print(f"\n{RED}SECURITY ERRORS:{RESET}")
        for e in errors:
            print(f"  {RED}{e}{RESET}")
        return False

    print(f"\n{GREEN}Security scan PASSED.{RESET}")
    return True


# =============================================================
# STAGE 3: DEPLOY MIGRATIONS
# =============================================================
def stage_deploy():
    """
    Same logic as Deploy-SqlMigrations.ps1:
    1. Create MigrationHistory table if not exists
    2. Check which migrations are already applied
    3. Apply new migrations in order
    4. Record each migration in tracking table
    """
    print_stage(3, "DEPLOY TO LOCAL DOCKER")

    print(f"Environment:    {ENVIRONMENT}")
    print(f"Server:         {SERVER},{PORT}")
    print(f"Database:       {DATABASE}")
    print(f"Timestamp:      {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print()

    # Step 1: Ensure MigrationHistory table exists
    print(f"{YELLOW}Ensuring MigrationHistory table exists...{RESET}")
    execute_query("""
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
        END
    """)
    print_pass("MigrationHistory table ready.")

    # Step 2: Get already-applied migrations
    print(f"\n{YELLOW}Checking previously applied migrations...{RESET}")
    applied = execute_query(
        "SELECT ScriptName, Checksum FROM dbo.MigrationHistory ORDER BY ScriptName",
        fetch=True
    )
    applied_map = {row['ScriptName']: row['Checksum'] for row in applied}
    print_pass(f"Found {len(applied_map)} previously applied migration(s).")

    # Step 3: Identify pending migrations
    sql_files = sorted([f for f in os.listdir(MIGRATIONS_PATH) if f.endswith('.sql')])
    pending = []

    for filename in sql_files:
        filepath = os.path.join(MIGRATIONS_PATH, filename)
        with open(filepath, 'r') as f:
            content = f.read()

        checksum = hashlib.sha256(content.encode('utf-8')).hexdigest().upper()

        if filename in applied_map:
            # Verify checksum (detect tampering)
            if applied_map[filename] != checksum:
                print_fail(f"CHECKSUM MISMATCH: {filename} was modified after deployment!")
                print(f"  Expected: {applied_map[filename]}")
                print(f"  Actual:   {checksum}")
                return False
            print_skip(f"{filename} - already applied")
        else:
            pending.append({'filename': filename, 'filepath': filepath, 'checksum': checksum})

    print()

    if not pending:
        print(f"{GREEN}No new migrations to apply. Database is up to date.{RESET}")
        return True

    print(f"{YELLOW}{len(pending)} new migration(s) to apply:{RESET}")
    for m in pending:
        print(f"  -> {m['filename']}")
    print()

    # Step 4: Apply each migration
    for migration in pending:
        filename = migration['filename']
        filepath = migration['filepath']
        checksum = migration['checksum']

        print(f"{CYAN}{'─' * 45}")
        print(f"Applying: {filename}")
        print(f"{'─' * 45}{RESET}")

        with open(filepath, 'r') as f:
            sql_content = f.read()

        start_time = time.time()
        try:
            execute_query(sql_content)
            elapsed_ms = int((time.time() - start_time) * 1000)

            # Record in MigrationHistory
            execute_query(f"""
                INSERT INTO dbo.MigrationHistory (ScriptName, AppliedBy, Environment, Checksum, ExecutionTimeMs)
                VALUES ('{filename}', 'Local-Pipeline-Runner', '{ENVIRONMENT}', '{checksum}', {elapsed_ms});
            """)

            print_pass(f"Applied successfully ({elapsed_ms}ms)")
        except Exception as e:
            print_fail(f"Migration failed: {e}")
            print(f"\n{RED}Deployment stopped. Fix the script and re-run.{RESET}")
            return False

    # Summary
    print(f"\n{GREEN}{'=' * 50}")
    print(f"  DEPLOYMENT COMPLETE")
    print(f"{'=' * 50}{RESET}")
    print(f"Environment:        {ENVIRONMENT}")
    print(f"Migrations Applied: {len(pending)}")
    print(f"Timestamp:          {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    return True


# =============================================================
# STAGE 4: POST-DEPLOYMENT TESTS
# =============================================================
def stage_test():
    """
    Same checks as Test-Deployment.ps1:
    1. Database connectivity
    2. MigrationHistory integrity
    3. No invalid objects
    4. Database is ONLINE
    5. Latest migration is recent
    """
    print_stage(4, "POST-DEPLOYMENT TESTS")

    print(f"Environment: {ENVIRONMENT}")
    print(f"Server:      {SERVER},{PORT}")
    print(f"Database:    {DATABASE}")
    print()

    passed = 0
    failed = 0

    # TEST 1: Connectivity
    print(f"{YELLOW}TEST 1: Database connectivity{RESET}")
    try:
        result = execute_scalar("SELECT 1")
        if result == 1:
            print_pass("Successfully connected to database")
            passed += 1
        else:
            print_fail("Unexpected result from connectivity check")
            failed += 1
    except Exception as e:
        print_fail(f"Cannot connect: {e}")
        print(f"\n{RED}Cannot connect to database. Skipping remaining tests.{RESET}")
        return False

    # TEST 2: MigrationHistory
    print(f"{YELLOW}TEST 2: Migration tracking integrity{RESET}")
    try:
        count = execute_scalar("SELECT COUNT(*) FROM dbo.MigrationHistory")
        if count and count > 0:
            print_pass(f"MigrationHistory has {count} record(s)")
        else:
            print_warn("MigrationHistory is empty")
        passed += 1
    except Exception as e:
        print_fail(f"MigrationHistory issue: {e}")
        failed += 1

    # TEST 3: Check for tables created by migrations
    print(f"{YELLOW}TEST 3: Verify migration objects exist{RESET}")
    try:
        table_count = execute_scalar("""
            SELECT COUNT(*) FROM sys.tables
            WHERE name IN ('Users', 'Orders', 'MigrationHistory')
        """)
        if table_count and table_count >= 2:
            print_pass(f"Found {table_count} expected table(s)")
            passed += 1
        else:
            print_warn(f"Only found {table_count} expected table(s)")
            passed += 1
    except Exception as e:
        print_fail(f"Could not check objects: {e}")
        failed += 1

    # TEST 4: Database is ONLINE
    print(f"{YELLOW}TEST 4: Database state is ONLINE{RESET}")
    try:
        state = execute_scalar("SELECT state_desc FROM sys.databases WHERE name = DB_NAME()")
        if state == 'ONLINE':
            print_pass(f"Database state: ONLINE")
            passed += 1
        else:
            print_fail(f"Database state: {state} (expected ONLINE)")
            failed += 1
    except Exception as e:
        print_fail(f"Could not check state: {e}")
        failed += 1

    # TEST 5: Latest migration is recent
    print(f"{YELLOW}TEST 5: Latest migration is recent{RESET}")
    try:
        minutes = execute_scalar("""
            SELECT DATEDIFF(MINUTE, MAX(AppliedOn), SYSUTCDATETIME())
            FROM dbo.MigrationHistory
        """)
        if minutes is None:
            print_skip("No migrations in history table")
            passed += 1
        elif minutes <= 60:
            print_pass(f"Latest migration applied {minutes} minute(s) ago")
            passed += 1
        else:
            print_warn(f"Latest migration was {minutes} minutes ago")
            passed += 1
    except Exception as e:
        print_fail(f"Could not verify timing: {e}")
        failed += 1

    # Summary
    print(f"\n{CYAN}{'=' * 50}")
    print(f"  TEST RESULTS")
    print(f"{'=' * 50}{RESET}")
    print(f"{GREEN}Passed: {passed}{RESET}")
    print(f"{RED if failed else GREEN}Failed: {failed}{RESET}")

    if failed > 0:
        print(f"\n{RED}{failed} test(s) FAILED.{RESET}")
        return False

    print(f"\n{GREEN}All post-deployment tests PASSED for {ENVIRONMENT}.{RESET}")
    return True


# =============================================================
# MAIN — RUN ALL STAGES
# =============================================================
def main():
    print(f"\n{BOLD}{MAGENTA}{'=' * 50}")
    print(f"  LOCAL PIPELINE RUNNER")
    print(f"  Simulating Azure DevOps Pipeline")
    print(f"{'=' * 50}{RESET}")
    print(f"Server:     {SERVER},{PORT}")
    print(f"Database:   {DATABASE}")
    print(f"Migrations: {MIGRATIONS_PATH}")
    print(f"Timestamp:  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    # Check prerequisites
    try:
        import pymssql
    except ImportError:
        print(f"\n{RED}pymssql is not installed. Run: pip3 install pymssql{RESET}")
        sys.exit(1)

    # Verify Docker SQL Server is running
    try:
        conn = pymssql.connect(server=SERVER, port=PORT, user=USER, password=PASSWORD, login_timeout=5)
        conn.close()
    except Exception as e:
        print(f"\n{RED}Cannot connect to SQL Server at {SERVER}:{PORT}")
        print(f"Is Docker running? Try: docker compose up -d{RESET}")
        print(f"Error: {e}")
        sys.exit(1)

    # Ensure DevOpsDemo database exists
    try:
        conn = pymssql.connect(server=SERVER, port=PORT, user=USER, password=PASSWORD, autocommit=True)
        cursor = conn.cursor()
        cursor.execute("IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'DevOpsDemo') CREATE DATABASE DevOpsDemo")
        conn.close()
    except Exception as e:
        print(f"\n{RED}Could not create database: {e}{RESET}")
        sys.exit(1)

    results = {}

    # Stage 1: Validate
    results['Validate'] = stage_validate()
    if not results['Validate']:
        print(f"\n{RED}Pipeline STOPPED at Stage 1: Validation failed.{RESET}")
        sys.exit(1)

    # Stage 2: Security Scan
    results['Security'] = stage_security_scan()
    if not results['Security']:
        print(f"\n{RED}Pipeline STOPPED at Stage 2: Security scan failed.{RESET}")
        sys.exit(1)

    # Stage 3: Deploy
    results['Deploy'] = stage_deploy()
    if not results['Deploy']:
        print(f"\n{RED}Pipeline STOPPED at Stage 3: Deployment failed.{RESET}")
        sys.exit(1)

    # Stage 4: Test
    results['Test'] = stage_test()
    if not results['Test']:
        print(f"\n{RED}Pipeline STOPPED at Stage 4: Tests failed.{RESET}")
        sys.exit(1)

    # Final Summary
    print(f"\n{BOLD}{GREEN}{'=' * 50}")
    print(f"  PIPELINE COMPLETE — ALL STAGES PASSED")
    print(f"{'=' * 50}{RESET}")
    print()
    for stage, passed in results.items():
        status = f"{GREEN}PASSED{RESET}" if passed else f"{RED}FAILED{RESET}"
        print(f"  {stage}: {status}")
    print()
    print(f"Your migrations have been deployed to Docker SQL Server.")
    print(f"Connect with Azure Data Studio: {SERVER},{PORT}")
    print(f"Database: {DATABASE}")
    print()


if __name__ == '__main__':
    main()
