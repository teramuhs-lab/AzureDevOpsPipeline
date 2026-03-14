# SQL Server Database CI/CD Pipeline — Complete Walkthrough

> **Audience:** SQL Server DBAs transitioning into Database DevOps.
> Every concept is explained with DBA parallels so you can map new ideas to what you already know.

---

## Table of Contents

1. [Project Structure](#1-project-structure)
2. [Core Concepts — DBA to DevOps Dictionary](#2-core-concepts--dba-to-devops-dictionary)
3. [Pipeline Structure Deep Dive](#3-pipeline-structure-deep-dive)
4. [Triggers — When the Pipeline Runs](#4-triggers--when-the-pipeline-runs)
5. [Stages, Jobs, and Tasks](#5-stages-jobs-and-tasks)
6. [Environment Promotion: Dev → Test → Prod](#6-environment-promotion-dev--test--prod)
7. [Secure Variables — Handling Secrets](#7-secure-variables--handling-secrets)
8. [Approval Gates — Manual Checkpoints](#8-approval-gates--manual-checkpoints)
9. [Deployment Validation — Post-Deployment Tests](#9-deployment-validation--post-deployment-tests)
10. [The Migration Pattern — Why It Works](#10-the-migration-pattern--why-it-works)
11. [Setting This Up in Azure DevOps](#11-setting-this-up-in-azure-devops)
12. [What to Learn Next](#12-what-to-learn-next)

---

## 1. Project Structure

```
AzureDevOpsPipeline/
├── pipelines/
│   ├── azure-pipelines.yml              # Main pipeline definition
│   └── templates/
│       ├── variables-common.yml         # Shared variables (non-secret)
│       ├── variables-dev.yml            # Dev server/database names
│       ├── variables-test.yml           # Test server/database names
│       └── variables-prod.yml           # Prod server/database names
├── scripts/
│   ├── Validate-SqlMigrations.ps1       # Pre-deployment validation
│   ├── Deploy-SqlMigrations.ps1         # Migration execution engine
│   └── Test-Deployment.ps1              # Post-deployment health checks
├── migrations/
│   ├── V001__create_users_table.sql     # First migration
│   ├── V002__create_orders_table.sql    # Second migration
│   └── V003__add_phone_to_users.sql     # Third migration
└── WALKTHROUGH.md                       # This file
```

### Why this structure?

| Directory | Purpose | DBA Parallel |
|-----------|---------|--------------|
| `pipelines/` | Defines WHAT runs and WHEN | Like a SQL Agent Job definition |
| `scripts/` | PowerShell that does the work | Like your deployment scripts folder |
| `migrations/` | Versioned SQL changes | Like numbered change scripts |
| `templates/` | Environment-specific config | Like linked server aliases per environment |

---

## 2. Core Concepts — DBA to DevOps Dictionary

| DevOps Term | DBA Equivalent | What It Actually Is |
|-------------|---------------|---------------------|
| **Pipeline** | SQL Agent Job | An automated sequence of steps |
| **Stage** | Job Step Group | A major phase (Validate, Deploy Dev, Deploy Prod) |
| **Job** | Individual Job Step | A unit of work within a stage |
| **Task** | A command within a step | A single action (run PowerShell, copy files) |
| **Trigger** | DDL/DML Trigger | What causes the pipeline to start |
| **Agent/Pool** | Server that runs the job | The machine executing your scripts |
| **Artifact** | Output file | Files produced by one stage for use by another |
| **Variable Group** | SQL Server Credential | Encrypted, centrally managed secrets |
| **Environment** | Registered Server in CMS | A tracked deployment target with protections |
| **Approval Gate** | Change Advisory Board | Required human sign-off before proceeding |
| **Commit** | Saving a script to a shared drive | Saving code to version control (Git) |

---

## 3. Pipeline Structure Deep Dive

A YAML pipeline has a hierarchy:

```
Pipeline (azure-pipelines.yml)
  └── Stage 1: Validate
  │     └── Job: ValidateSQL
  │           └── Task: checkout code
  │           └── Task: run validate.ps1
  │           └── Task: publish artifacts
  └── Stage 2: Deploy Dev
  │     └── Job: DeployDevDB
  │           └── Task: download artifacts
  │           └── Task: run deploy.ps1
  │           └── Task: run test.ps1
  └── Stage 3: Deploy Test (with approval)
  └── Stage 4: Deploy Prod (with approval)
```

### Stages
The highest level of organization. Each stage represents a major checkpoint. Stages run **sequentially** by default (controlled by `dependsOn`).

**Why separate stages?** If validation fails, you don't want deployment to run. If Dev deployment fails, you don't want Test deployment to run. Stages create hard boundaries.

### Jobs
Within a stage, jobs define WHAT runs. A job runs on a single agent (machine). Multiple jobs within a stage can run **in parallel**.

For database deployments, we use **deployment jobs** (note the `deployment:` keyword instead of `job:`). Deployment jobs connect to Azure DevOps Environments, which enables:
- Approval gates
- Deployment history tracking
- Rollback capabilities

### Tasks
The smallest unit of work. Each task does ONE thing:
- `checkout: self` — downloads your code
- `PowerShell@2` — runs a PowerShell script
- `PublishPipelineArtifact@1` — saves files for later stages
- `DownloadPipelineArtifact@2` — retrieves files from earlier stages

---

## 4. Triggers — When the Pipeline Runs

```yaml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - migrations/*
      - scripts/*
```

This means: **Run the pipeline when someone pushes code to the `main` branch, BUT only if files in `migrations/` or `scripts/` changed.**

### Why path filters?
Without path filters, updating a README would trigger a database deployment. Path filters ensure the pipeline only runs when relevant files change.

### DBA Parallel
Think of this as a DDL trigger that only fires for specific objects. Instead of `FOR ALTER_TABLE, CREATE_TABLE`, you have `paths: include: migrations/*`.

### Other trigger types you'll encounter:
- **Pull Request triggers** — run validation when someone creates a PR (catch errors before merge)
- **Scheduled triggers** — run at specific times (like a SQL Agent schedule)
- **Manual triggers** — someone clicks "Run" in Azure DevOps

---

## 5. Stages, Jobs, and Tasks

### Stage: Validate

```yaml
- stage: Validate
  displayName: '1 - Validate SQL Scripts'
  jobs:
    - job: ValidateSQL
      steps:
        - checkout: self
        - task: PowerShell@2
          inputs:
            filePath: 'scripts/Validate-SqlMigrations.ps1'
```

**Purpose:** Catch errors before they reach any database.

**What it checks:**
- File naming convention (V001__description.sql)
- No hardcoded `USE [database]` statements
- No `DROP TABLE` without `IF EXISTS`
- Flags `TRUNCATE TABLE` and `DELETE` without `WHERE`

**DBA Parallel:** This is like having a senior DBA review every script, but automated and consistent. Every script gets the same scrutiny, 24/7.

### Stage: Deploy (Dev/Test/Prod)

```yaml
- stage: DeployDev
  dependsOn: Validate
  jobs:
    - deployment: DeployDevDB
      environment: 'SQL-Dev'
      strategy:
        runOnce:
          deploy:
            steps:
              - task: PowerShell@2
                inputs:
                  filePath: 'scripts/Deploy-SqlMigrations.ps1'
```

**Key elements:**
- `dependsOn: Validate` — won't run unless validation passed
- `environment: 'SQL-Dev'` — links to Azure DevOps Environment (enables approvals)
- `strategy: runOnce` — deploy exactly once (not rolling, not canary)

---

## 6. Environment Promotion: Dev → Test → Prod

```
Dev (automatic) → Test (approval required) → Prod (approval required)
```

### How it flows:

1. **Developer commits** a new migration script to `main`
2. **Pipeline triggers** automatically
3. **Validate stage** checks all scripts — if any fail, pipeline stops
4. **Dev deployment** runs automatically — this is the sandbox
5. **Post-deployment tests** verify Dev is healthy
6. **Pipeline pauses** — waits for approval to deploy to Test
7. **Approver reviews** and clicks Approve in Azure DevOps
8. **Test deployment** runs — QA can now validate
9. **Pipeline pauses again** — waits for Prod approval
10. **Multiple approvers** sign off (DBA Lead + Release Manager)
11. **Prod deployment** runs with full audit logging

### Why this pattern?
- **Same script** flows through every environment — no "works on my machine"
- **Automatic gates** prevent premature promotion
- **Audit trail** shows who approved what and when
- **Rollback is clear** — you know exactly what ran where

### DBA Parallel
Instead of:
> "Hey, can you run this script on Test? I already ran it on Dev and it worked."

You get:
> The pipeline ran the exact same script, validated it first, and recorded who approved the promotion.

---

## 7. Secure Variables — Handling Secrets

### The Problem
Database deployments need credentials. You CANNOT:
- Hardcode passwords in scripts (anyone with repo access can see them)
- Put connection strings in YAML files (they're checked into Git)
- Share passwords over email or chat (insecure, no audit trail)

### The Solution: Variable Groups

**Variable Groups** are created in Azure DevOps (Pipelines > Library > Variable Groups).

```yaml
variables:
  - group: 'SQLDatabase-Secrets'    # Contains encrypted secrets
```

When the pipeline runs, it pulls the values from the Variable Group and injects them as environment variables:

```yaml
env:
  SQL_PASSWORD: $(SqlAdminPassword)   # Injected, masked in logs
```

### What makes this secure?

| Feature | What it does |
|---------|-------------|
| **Encryption at rest** | Secrets are encrypted in Azure DevOps storage |
| **Masked in logs** | If a script prints the password, Azure DevOps replaces it with `***` |
| **Access control** | Only authorized pipelines/users can read the values |
| **No Git exposure** | Secrets never appear in your repository |
| **Audit trail** | Every access is logged |

### DBA Parallel
This is the CI/CD equivalent of:
- Using Windows Authentication instead of `sa` with a sticky note password
- Storing credentials in SQL Server Credential Manager
- Using Always Encrypted for sensitive data

### How to set up a Variable Group:

1. Go to Azure DevOps → Pipelines → Library
2. Click "+ Variable group"
3. Name it `SQLDatabase-Secrets`
4. Add variables:
   - `SqlAdminPassword` → (your password) → click the lock icon to encrypt
5. Under "Pipeline permissions", authorize your pipeline

---

## 8. Approval Gates — Manual Checkpoints

### How approvals work

Approvals are configured on **Environments**, not in the YAML file.

When the pipeline reaches a stage with `environment: 'SQL-Test'`, Azure DevOps checks if that environment has approval rules. If it does, the pipeline **pauses** and notifies the approvers.

### Setting up approvals:

1. Go to Azure DevOps → Pipelines → Environments
2. Click on the environment (e.g., `SQL-Test`)
3. Click the three dots → "Approvals and checks"
4. Add "Approvals"
5. Select the approvers (individuals or groups)
6. Configure:
   - **Minimum approvers**: 1 for Test, 2 for Prod
   - **Allow self-approval**: No (for Prod)
   - **Timeout**: 72 hours (pipeline cancels if not approved)

### Recommended approval structure:

| Environment | Approvers | Self-Approval | Timeout |
|-------------|-----------|---------------|---------|
| SQL-Dev | None (automatic) | N/A | N/A |
| SQL-Test | Team Lead | Yes | 48 hours |
| SQL-Prod | DBA Lead + Release Manager | No | 72 hours |

### Why approval gates matter

Without gates:
> Developer commits a broken migration → automatically deploys to Prod → data loss

With gates:
> Developer commits → validated → deployed to Dev → tested → approved by lead → deployed to Test → QA verified → approved by DBA + RM → deployed to Prod

### DBA Parallel
This replaces:
- CAB (Change Advisory Board) meetings
- Email approval chains
- Manual change request tickets

The difference: it's **enforced by the system**, not by process compliance. You literally cannot deploy to Prod without approval.

---

## 9. Deployment Validation — Post-Deployment Tests

After every deployment, `Test-Deployment.ps1` runs five checks:

| Test | What It Checks | Why It Matters |
|------|---------------|----------------|
| **Connectivity** | Can we connect to the DB? | Migration might have broken access |
| **Migration tracking** | MigrationHistory has records | Confirms the tracking system works |
| **Object validity** | No broken procedures/views | Migration might have broken dependencies |
| **Database state** | Database is ONLINE | Migration might have left DB in bad state |
| **Recent migration** | Latest migration is fresh | Confirms the deployment actually ran |

### Why post-deployment tests?

A script can **succeed** (no SQL errors) but still **cause problems**:
- Column added with wrong data type
- Procedure created that references a missing table
- Index added with wrong columns
- Constraint conflicts with existing data

These tests catch issues **before** the deployment promotes to the next environment.

### DBA Parallel
This is your automated `DBCC CHECKDB` + sanity check + smoke test, all in one. Instead of manually querying the database after a deployment, the pipeline does it for you.

---

## 10. The Migration Pattern — Why It Works

### The key principle: Each script runs EXACTLY ONCE per environment

```
V001__create_users_table.sql     → runs in Dev, then Test, then Prod
V002__create_orders_table.sql    → runs in Dev, then Test, then Prod
V003__add_phone_to_users.sql     → runs in Dev, then Test, then Prod
```

### How the tracking works:

1. Pipeline reads `MigrationHistory` table in the target database
2. Compares it against the files in the `migrations/` folder
3. Runs ONLY the scripts that haven't been applied yet
4. Records each applied script with a checksum

### The golden rules:

1. **NEVER modify an applied migration.** The checksum check will catch it and fail the deployment.
2. **Always create NEW migrations** for changes. Want to add a column? Don't edit V001 — create V004.
3. **Migrations must be idempotent.** Use `IF NOT EXISTS` checks so re-running is safe.
4. **Number migrations sequentially.** V001, V002, V003... Order matters.

### What happens if a migration fails?

```
V001 ✅ Applied (recorded in MigrationHistory)
V002 ✅ Applied (recorded in MigrationHistory)
V003 ❌ Failed (NOT recorded — will retry on next run)
```

You fix V003, commit, and push. The pipeline re-runs:
- V001: already in MigrationHistory → skip
- V002: already in MigrationHistory → skip
- V003: not in MigrationHistory → run (the fixed version)

---

## 11. Setting This Up in Azure DevOps

### Step-by-step setup:

#### 1. Create an Azure DevOps Project
- Go to dev.azure.com → Create new project
- Name: `DatabaseDeployments`

#### 2. Push this code to the repository
```bash
git init
git add .
git commit -m "Initial CI/CD pipeline for SQL Server migrations"
git remote add origin https://dev.azure.com/YOUR_ORG/DatabaseDeployments/_git/DatabaseDeployments
git push -u origin main
```

#### 3. Create the Pipeline
- Go to Pipelines → New Pipeline
- Select your repository
- Choose "Existing Azure Pipelines YAML file"
- Path: `/pipelines/azure-pipelines.yml`
- Save (don't run yet)

#### 4. Create the Variable Group
- Go to Pipelines → Library → Variable Groups
- Create `SQLDatabase-Secrets`
- Add `SqlAdminPassword` (lock it as secret)
- Authorize the pipeline to use it

#### 5. Create Environments
- Go to Pipelines → Environments
- Create three: `SQL-Dev`, `SQL-Test`, `SQL-Prod`
- Add approvals to `SQL-Test` and `SQL-Prod`

#### 6. Update server names
- Edit the variable template files with your actual server names
- Commit and push — the pipeline will trigger automatically

---

## 12. What to Learn Next

Now that you understand the fundamentals, here's your learning path:

### Immediate next steps:
1. **Git basics** — branching, merging, pull requests (this is where your scripts live now)
2. **Azure DevOps Environments** — deeper dive into checks, gates, and deployment history
3. **YAML syntax** — get comfortable reading and writing pipeline definitions

### Intermediate:
4. **Branch policies** — require PR reviews before merging to main
5. **Multi-stage templates** — reusable pipeline components (DRY principle)
6. **Azure Key Vault integration** — enterprise-grade secret management
7. **Database project (DACPAC)** — alternative to migration scripts using SSDT

### Advanced:
8. **Infrastructure as Code** — provision the SQL Servers themselves via pipeline
9. **Monitoring integration** — connect pipeline to alerting (PagerDuty, Teams)
10. **Blue/Green deployments** — zero-downtime database deployments
11. **Database branching** — isolated database copies for feature branches

---

## Quick Reference: Project Structure

```
AzureDevOpsPipeline/
├── pipelines/
│   ├── azure-pipelines.yml           ← Main pipeline (4 stages)
│   └── templates/
│       ├── variables-common.yml      ← Shared config (non-secret)
│       ├── variables-dev.yml         ← Dev server/DB names
│       ├── variables-test.yml        ← Test server/DB names
│       └── variables-prod.yml        ← Prod server/DB names
├── scripts/
│   ├── Validate-SqlMigrations.ps1    ← Pre-deployment checks
│   ├── Deploy-SqlMigrations.ps1      ← Migration execution engine
│   └── Test-Deployment.ps1           ← Post-deployment health checks
├── migrations/
│   ├── V001__create_users_table.sql
│   ├── V002__create_orders_table.sql
│   └── V003__add_phone_to_users.sql
└── WALKTHROUGH.md                    ← Full educational guide
```

### Key Concepts Covered (with DBA parallels)

| Concept | Where to Look | DBA Parallel |
|---------|--------------|--------------|
| **Pipeline structure** | `azure-pipelines.yml` | SQL Agent Job with 4 step groups |
| **Triggers** | Lines 24-30 of the pipeline | DDL trigger on `migrations/*` path |
| **Stages/Jobs/Tasks** | Each `stage:` block | Job steps organized by environment |
| **Environment promotion** | `dependsOn:` between stages | Manual script promotion, now automated |
| **Secure variables** | Variable Groups + `env: SQL_PASSWORD` | SQL Server Credential Manager |
| **Approval gates** | `environment: 'SQL-Prod'` | Change Advisory Board, enforced by system |
| **Deployment validation** | `Test-Deployment.ps1` | Automated DBCC CHECKDB + smoke tests |
| **Migration tracking** | `MigrationHistory` table in deploy script | Deployment audit log |

### The Pipeline Flow

```
Commit → Validate → Deploy DEV → Test DEV → Approve → Deploy TEST → Approve → Deploy PROD
```

---

## Quick Reference: Pipeline Flow Diagram

```
Developer commits SQL migration to main branch
         │
         ▼
   ┌─────────────┐
   │   TRIGGER    │  Pipeline starts automatically
   └──────┬──────┘
         │
         ▼
   ┌─────────────┐
   │  VALIDATE    │  Check syntax, naming, safety
   └──────┬──────┘
         │ (pass)
         ▼
   ┌─────────────┐
   │  DEPLOY DEV  │  Run migrations against Dev DB
   └──────┬──────┘
         │
         ▼
   ┌─────────────┐
   │  TEST DEV    │  Verify deployment health
   └──────┬──────┘
         │ (pass)
         ▼
   ┌─────────────┐
   │  APPROVAL    │  Team Lead approves
   └──────┬──────┘
         │
         ▼
   ┌─────────────┐
   │ DEPLOY TEST  │  Run migrations against Test DB
   └──────┬──────┘
         │
         ▼
   ┌─────────────┐
   │  TEST TEST   │  Verify deployment health
   └──────┬──────┘
         │ (pass)
         ▼
   ┌─────────────┐
   │  APPROVAL    │  DBA Lead + Release Manager approve
   └──────┬──────┘
         │
         ▼
   ┌─────────────┐
   │ DEPLOY PROD  │  Run migrations against Prod DB
   └──────┬──────┘
         │
         ▼
   ┌─────────────┐
   │  TEST PROD   │  Final health verification
   └──────┬──────┘
         │
         ▼
      ✅ DONE
```
