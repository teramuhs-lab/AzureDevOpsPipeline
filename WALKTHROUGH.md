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
12. [DevSecOps — Security in the Pipeline](#12-devsecops--security-in-the-pipeline)
13. [Troubleshooting — Issues We Encountered](#13-troubleshooting--issues-we-encountered)
14. [Docker — Running SQL Server Locally](#14-docker--running-sql-server-locally)
15. [Docker Management — Day-to-Day Operations](#15-docker-management--day-to-day-operations)
16. [What to Learn Next](#16-what-to-learn-next)

---

## 1. Project Structure

```
AzureDevOpsPipeline/
├── pipelines/
│   ├── azure-pipelines.yml              # Main pipeline definition (5 stages)
│   └── templates/
│       ├── variables-common.yml         # Shared variables (non-secret)
│       ├── variables-dev.yml            # Dev server/database names
│       ├── variables-test.yml           # Test server/database names
│       └── variables-prod.yml           # Prod server/database names
├── scripts/
│   ├── Validate-SqlMigrations.ps1       # Pre-deployment validation
│   ├── Scan-SqlSecurity.ps1             # DevSecOps: SQL security scanner
│   ├── Scan-SecretsLeak.ps1             # DevSecOps: Credential leak scanner
│   ├── Deploy-SqlMigrations.ps1         # Migration execution engine
│   ├── Test-Deployment.ps1              # Post-deployment health checks
│   └── Setup-DockerDb.ps1              # Docker SQL Server setup helper
├── migrations/
│   ├── V001__create_users_table.sql     # First migration
│   ├── V002__create_orders_table.sql    # Second migration
│   └── V003__add_phone_to_users.sql     # Third migration
├── docker-compose.yml                   # Local SQL Server (Docker)
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

> This section documents every step we performed to set up this project in Azure DevOps.
> Use this as a reference guide you can follow again for any future pipeline project.

---

### Step 1: Create an Azure DevOps Organization & Project

**Where:** https://dev.azure.com

1. Sign in with your Microsoft account
2. If you don't have an organization, Azure DevOps will prompt you to create one
   - Organization name becomes part of your URL: `https://dev.azure.com/YOUR_ORG`
3. Click **+ New project** (top-right)
4. Fill in the form:
   - **Project name:** `DevOps` (avoid typos — e.g., "DveOps")
   - **Description:** `SQL Server Database CI/CD Pipeline - Migration-based deployments with validation and approval gates`
   - **Visibility:** `Private` — only people you invite can access it
5. Click **Create project**

**Result:** Your project is live at `https://dev.azure.com/YOUR_ORG/DevOps`

> **DBA Parallel:** Creating a project is like creating a new database — it's the container for everything else (repos, pipelines, boards).

---

### Step 2: Initialize Git Locally and Push Code

**Where:** Your local terminal (PowerShell or zsh)

Azure DevOps provides a Git repository inside your project. You need to push your local code to it.

#### 2a. Initialize the local Git repository

```bash
cd /path/to/AzureDevOpsPipeline
git init
git branch -M main
```

- `git init` creates a `.git/` folder, turning your directory into a Git repository
- `git branch -M main` renames the default branch to `main`

#### 2b. Stage and commit all files

```bash
git add .
git commit -m "Initial CI/CD pipeline for SQL Server database migrations"
```

- `git add .` stages all files for commit (like selecting scripts to deploy)
- `git commit` saves a snapshot of your code (like creating a restore point)

#### 2c. Connect to Azure DevOps remote repository

```bash
git remote add origin https://dev.azure.com/YOUR_ORG/DevOps/_git/DevOps
```

- This tells Git where to push your code — your Azure DevOps repo

#### 2d. Authenticate with a Personal Access Token (PAT)

Git over HTTPS to Azure DevOps requires a PAT, not your password.

**To create a PAT:**
1. Go to https://dev.azure.com/YOUR_ORG
2. Click your **profile icon** (top-right corner)
3. Click **Personal access tokens**
4. Click **+ New Token**
5. Configure:
   - **Name:** `git-access`
   - **Expiration:** 90 days (you can extend later)
   - **Scopes:** Select **Code → Read & Write**
6. Click **Create**
7. **COPY THE TOKEN** — you will not be able to see it again

**Set the remote URL with your PAT embedded:**

```bash
git remote set-url origin https://YOUR_USERNAME:YOUR_PAT@dev.azure.com/YOUR_ORG/DevOps/_git/DevOps
```

> **Security note:** The PAT in the URL is stored in your local `.git/config`. This is acceptable for personal projects. For shared machines, use Git Credential Manager instead.

> **DBA Parallel:** A PAT is like a SQL Server login with specific permissions and an expiration date. It's scoped (Code Read & Write only), time-limited, and auditable — much better than using `sa` with a sticky note password.

#### 2e. Push to Azure DevOps

```bash
git push -u origin main
```

**Expected output:**
```
Enumerating objects: 19, done.
...
To https://dev.azure.com/YOUR_ORG/DevOps/_git/DevOps
 * [new branch]      main -> main
branch 'main' set up to track 'origin/main'.
```

**Verify:** Go to `https://dev.azure.com/YOUR_ORG/DevOps/_git/DevOps` — you should see all your files.

---

### Step 3: Create the Pipeline

**Where:** Azure DevOps → Pipelines

1. In your project, click **Pipelines** in the left sidebar
2. Click **New Pipeline** (or **Create Pipeline** if it's your first)
3. **Where is your code?** → Select **Azure Repos Git**
4. **Select a repository** → Select **DevOps**
5. **Configure your pipeline** → Select **Existing Azure Pipelines YAML file**
6. In the dropdown:
   - **Branch:** `main`
   - **Path:** `/pipelines/azure-pipelines.yml`
7. Click **Continue**
8. Review the YAML — this is your pipeline definition
9. Click **Save** (the dropdown arrow next to "Run") — do NOT run yet, we need to set up secrets and environments first

> **Why save and not run?** The pipeline references a Variable Group (`SQLDatabase-Secrets`) and Environments (`SQL-Dev`, `SQL-Test`, `SQL-Prod`) that don't exist yet. Running now would fail.

> **DBA Parallel:** This is like creating a SQL Agent Job and adding the steps, but not scheduling it yet because the linked servers aren't configured.

---

### Step 4: Create the Variable Group (Secrets)

**Where:** Azure DevOps → Pipelines → Library

This is where you store database passwords and connection strings securely.

1. Click **Pipelines** → **Library** in the left sidebar
2. Click **+ Variable group**
3. **Variable group name:** `SQLDatabase-Secrets`
4. Click **+ Add** to create variables:
   - **Name:** `SqlAdminPassword`
   - **Value:** your database password
   - Click the **lock icon** (🔒) to make it a secret — this encrypts it
5. Click **Save**

**After saving, set pipeline permissions:**
1. On the Variable Group page, click the **Pipeline permissions** tab
2. Click **+** and authorize your pipeline to use this group

> **What the lock icon does:**
> - Encrypts the value at rest in Azure DevOps
> - Masks it in pipeline logs (shows `***` instead of the actual value)
> - Prevents anyone from reading the value back through the UI
> - Only the pipeline can decrypt it at runtime

> **DBA Parallel:** This is the equivalent of SQL Server Credential Manager or Always Encrypted — secrets are never stored in plain text, and there's an audit trail for every access.

---

### Step 5: Create Environments with Approval Gates

**Where:** Azure DevOps → Pipelines → Environments

Environments are deployment targets that Azure DevOps tracks. They enable approval gates, deployment history, and audit trails.

#### 5a. Create the three environments

Repeat this for each environment:

1. Click **Pipelines** → **Environments** in the left sidebar
2. Click **New environment**
3. Fill in:
   - **Name:** (must match the YAML exactly)
   - **Resource:** Select **None** (we use hosted agents, not Kubernetes or VMs)
4. Click **Create**

Create all three:

| Name | Description |
|------|-------------|
| `SQL-Dev` | Development SQL Server database |
| `SQL-Test` | Test/QA SQL Server database |
| `SQL-Prod` | Production SQL Server database |

> **Why "None" for resource?** Our pipeline runs on Microsoft-hosted agents (`windows-latest`). We're not deploying to Kubernetes clusters or managing VMs — we're running PowerShell scripts that connect to SQL Server over the network. The environment here is a logical concept for tracking and approvals, not a physical target.

#### 5b. Add approval checks to SQL-Test

1. Click on **SQL-Test** to open it
2. Click the **three dots menu** (⋮) in the top-right corner
3. Select **Approvals and checks**
4. Click **Approvals** (first option)
5. **Approvers:** Add yourself (your Azure DevOps email)
6. **Instructions:** `Review Dev deployment results before promoting to Test`
7. **Advanced settings:**
   - **Minimum number of approvers:** `1`
   - **Allow requestors to approve:** `Yes` (fine for learning; set to No in real teams)
   - **Timeout:** `48 hours`
8. Click **Create**

#### 5c. Add approval checks to SQL-Prod

1. Click on **SQL-Prod** to open it
2. Same steps as above, but stricter settings:
   - **Approvers:** Add yourself (in real teams: DBA Lead + Release Manager)
   - **Instructions:** `Verify Test deployment was successful. Review migration scripts before production deployment.`
   - **Advanced settings:**
     - **Minimum number of approvers:** `1` (in real teams: `2`)
     - **Allow requestors to approve:** `Yes` (in real teams: `No`)
     - **Timeout:** `72 hours`
3. Click **Create**

#### 5d. Leave SQL-Dev with NO approvals

Dev deploys automatically on every commit — no gates needed. This gives developers fast feedback.

> **How approvals work at runtime:**
> 1. Pipeline reaches the `DeployTest` stage
> 2. Azure DevOps sees that `SQL-Test` has an approval check
> 3. Pipeline **pauses** and sends a notification (email + Azure DevOps UI)
> 4. Approver reviews the Dev deployment results
> 5. Approver clicks **Approve** or **Reject**
> 6. If approved → pipeline continues to deploy to Test
> 7. If rejected → pipeline stops, nothing deploys

> **DBA Parallel:** This is the automated Change Advisory Board (CAB). Instead of scheduling meetings, sending emails, and hoping someone remembers to sign off — the system enforces the gate. No approval = no deployment. Every approval is logged with who, when, and any comments.

---

### Step 6: Run the Pipeline (First Run)

**Where:** Azure DevOps → Pipelines

Now that everything is configured:

1. Go to **Pipelines** → click on your pipeline
2. Click **Run pipeline**
3. **Branch:** `main`
4. Click **Run**

**What to expect on the first run:**
- **Validate stage** will run and should pass (checks your SQL scripts)
- **DeployDev stage** will attempt to deploy — this will **fail** because there's no actual SQL Server connected yet, and that's OK. The goal is to see the pipeline structure work.
- If it reaches **DeployTest**, you'll get an **approval notification**

> **This is normal!** The first run proves the pipeline structure works. Connecting to actual SQL Servers is the next step.

---

### Step 7: Trigger the Pipeline Automatically (Future Commits)

Once everything is wired up, the pipeline triggers automatically when you:

1. Edit or add a file in `migrations/` or `scripts/`
2. Commit the change
3. Push to `main`

```bash
# Example: adding a new migration
git add migrations/V004__add_email_index.sql
git commit -m "Add index on Users.Email for performance"
git push
```

The pipeline will trigger within seconds. You can watch it run in **Pipelines** → click the running pipeline.

---

### Summary: What We Set Up

| Step | What We Did | Why |
|------|-------------|-----|
| 1. Create Project | `DevOps` project on Azure DevOps | Container for repos, pipelines, environments |
| 2. Push Code | `git push` local code to Azure Repos | Pipeline needs code in a remote Git repo |
| 3. Create Pipeline | Pointed pipeline at `azure-pipelines.yml` | Tells Azure DevOps what to run |
| 4. Variable Group | `SQLDatabase-Secrets` with encrypted password | Secrets must never be in code |
| 5. Environments | `SQL-Dev`, `SQL-Test`, `SQL-Prod` with approvals | Enforces promotion gates and audit trail |
| 6. First Run | Triggered the pipeline to verify structure | Proves everything is wired correctly |
| 7. Auto-Trigger | Push changes → pipeline runs automatically | The CI/CD loop is now active |

> **The big picture:** You've gone from "run scripts manually on production" to "code changes flow through an automated, validated, approved pipeline." Every deployment is tracked, every promotion requires approval, and every secret is encrypted. This is what enterprise Database DevOps looks like.

---

## 12. DevSecOps — Security in the Pipeline

### What is DevSecOps?

**DevSecOps = DevOps + Security baked into every stage**, instead of security being an afterthought at the end.

### What You Already Have (DevOps)

```
Code → Build → Test → Deploy
```

### What DevSecOps Adds

```
Code → Security Scan → Build → Security Test → Deploy → Monitor
```

| Approach | Pipeline Flow |
|----------|--------------|
| **Traditional** | Code -> Build -> Test -> Deploy -> *Security audit (weeks later)* |
| **DevOps** | Code -> Build -> Test -> Deploy *(automated, but no security checks)* |
| **DevSecOps** | Code -> **Security Scan** -> Build -> **Security Test** -> Deploy -> **Monitor** |

The key insight: **security checks run automatically on every commit**, not as an afterthought.

### Concrete Examples Using Your Pipeline

| DevOps (what you built) | DevSecOps (what you'd add) |
|---|---|
| Validate SQL syntax | Scan SQL for **SQL injection** vulnerabilities |
| Store passwords in Variable Groups | Scan repo for **leaked secrets** (e.g., Credential Scanner) |
| Deploy migrations | Check migrations against **compliance policies** (e.g., no `sa` account usage) |
| Approval gates | **Automated security gate** — block deploy if vulnerabilities found |
| Post-deployment tests | **Penetration testing** and security smoke tests |

### DBA Parallel — You Already Think This Way

You already practice security instinctively as a DBA:

| What You Do as a DBA | DevSecOps Principle | DevSecOps Equivalent |
|---------------------|--------------------|--------------------|
| Don't give everyone `sa` access | **Least privilege** | Excessive permissions scanner |
| Don't store passwords in scripts | **Secret management** | Secret leak scanner |
| Audit who runs what | **Security logging** | Pipeline audit trail |
| Review scripts before production | **Security review gate** | Automated security gate |
| Don't enable xp_cmdshell | **Attack surface reduction** | Dangerous configuration scanner |
| Use Windows Auth over SQL Auth | **Identity management** | Managed Identity (advanced topic) |

**DevSecOps just automates those instincts into the pipeline.** Instead of relying on human diligence, the system enforces security rules on every commit.

### Key DevSecOps Tools in Azure DevOps

| Tool | What It Does | DBA Parallel |
|------|-------------|-------------|
| **Microsoft Defender for DevOps** | Scans code for vulnerabilities across multiple languages | Like running a security audit tool across all your stored procedures |
| **Credential Scanner** | Catches leaked passwords in code | Like searching every script for hardcoded `sa` passwords |
| **OWASP Dependency Check** | Finds vulnerable libraries | Like checking if your SQL Server version has known CVEs |
| **SonarQube** | Code quality + security analysis | Like a comprehensive code review with security focus |
| **Azure Key Vault** | Enterprise-grade secret management | Replaces Variable Groups; this is what the "Link secrets from an Azure key vault" toggle was for in your Variable Group |

### In Your Pipeline, It Looks Like This

```
Stage 1: Validate SQL Scripts        ← you have this (DevOps)
Stage 2: Security Scan               ← DevSecOps addition
Stage 3: Deploy to DEV               ← you have this (DevOps)
Stage 4: Deploy to TEST              ← you have this (DevOps)
Stage 5: Deploy to PROD              ← you have this (DevOps)
```

### How DevSecOps Fits Into This Pipeline (Detailed)

Our pipeline now has 5 stages:

```
Stage 1: Validate SQL Scripts       (DevOps - catch syntax errors)
Stage 2: Security Scan              (DevSecOps - catch security issues)
Stage 3: Deploy to DEV              (DevOps - automated deployment)
Stage 4: Deploy to TEST             (DevOps - approval gate)
Stage 5: Deploy to PROD             (DevOps - approval gate)
```

Stage 2 is the DevSecOps addition. It runs two security scanners:

### Scanner 1: SQL Security Scan (`Scan-SqlSecurity.ps1`)

Checks SQL migration scripts for security vulnerabilities:

| Rule | What It Catches | Why It Matters |
|------|----------------|----------------|
| **SQL Injection** | Dynamic SQL with string concatenation (`EXEC('SELECT ' + @var)`) | #1 database attack vector. Use `sp_executesql` with parameters instead. |
| **Excessive Permissions** | `GRANT ALL`, adding users to `sysadmin` role | Violates principle of least privilege. Grant only what's needed. |
| **Hardcoded Credentials** | Passwords embedded in SQL scripts (`PASSWORD = 'abc123'`) | Anyone with repo access can read them. Git history preserves them forever. |
| **Dangerous Configurations** | Enabling `xp_cmdshell` or OLE Automation | These features allow OS-level command execution from SQL Server. |
| **Privilege Escalation** | `WITH EXECUTE AS` or `EXECUTE AS OWNER` | Can elevate permissions beyond what the caller should have. |
| **Security Feature Bypass** | Setting `TRUSTWORTHY ON` or `DB_CHAINING ON` | Weakens SQL Server's security isolation between databases. |

### Scanner 2: Secret Leak Scanner (`Scan-SecretsLeak.ps1`)

Searches ALL files in the repository for leaked credentials:

| Rule | Pattern Examples | Why It Matters |
|------|-----------------|----------------|
| **Connection Strings** | `Server=x;Password=abc123` | Embedded connection string = full database access for anyone |
| **Hardcoded Passwords** | `password = "mySecret"` in any file | Secrets in code are readable by everyone with repo access |
| **Azure Storage Keys** | `AccountKey=xxxxx` in config files | Storage keys grant full access to Azure storage accounts |
| **API Keys** | `api_key = "sk_live_xxxxx"` | API keys can be used to make authorized calls to external services |
| **Private Keys** | `-----BEGIN PRIVATE KEY-----` | Private keys enable impersonation and decryption |
| **AWS Access Keys** | `AKIA` followed by 16 characters | AWS access keys grant cloud resource access |

### DBA Parallels for DevSecOps

You already think this way as a DBA:

| What You Do as a DBA | DevSecOps Equivalent |
|---------------------|---------------------|
| Don't give everyone `sa` access | Excessive permissions scanner |
| Don't store passwords in scripts | Secret leak scanner |
| Audit who runs what | Pipeline audit trail |
| Review scripts before production | Automated security gate |
| Don't enable xp_cmdshell | Dangerous configuration scanner |
| Use Windows Auth over SQL Auth | Managed Identity (advanced topic) |

### Enterprise DevSecOps Tools

In production environments, these scanners would be replaced or supplemented by:

| Tool | What It Does |
|------|-------------|
| **Microsoft Defender for DevOps** | Scans code for vulnerabilities across multiple languages |
| **GitHub Advanced Security** | Secret scanning, code scanning, dependency review |
| **SonarQube** | Code quality + security analysis with detailed reporting |
| **GitLeaks / TruffleHog** | Deep Git history scanning for leaked secrets |
| **OWASP Dependency Check** | Finds known vulnerabilities in third-party libraries |
| **Azure Key Vault** | Enterprise-grade secret management (replaces Variable Groups) |

Our scripts demonstrate the **concepts** these tools implement. Understanding the patterns helps you evaluate and use enterprise tools effectively.

---

## 13. Troubleshooting — Issues We Encountered

> This section documents real issues we hit while setting up this pipeline
> and how we resolved them. These are common problems you'll encounter in
> real DevOps work.

### Issue 1: Em Dash Characters Breaking PowerShell

**Symptom:** Validate stage failed with `Unexpected token 'remove' in expression or statement`

**Cause:** Em dash characters (`--`) in PowerShell string messages. Windows PowerShell 5.1 (used by Azure DevOps hosted agents) doesn't handle Unicode em dashes in string expressions.

**Fix:** Replaced all em dash characters (`--`) with regular hyphens (`-`) in PowerShell scripts.

**Lesson:** Always test scripts on Windows PowerShell 5.1, not just PowerShell 7 (pwsh). Azure DevOps `windows-latest` agents use Windows PowerShell by default.

---

### Issue 2: Variable Group Secrets Not Available in Deployment Jobs

**Symptom:** `SQL_PASSWORD environment variable is not set` error during Deploy to DEV stage.

**Cause:** In Azure DevOps YAML pipelines, `deployment` jobs (with `strategy: runOnce: deploy:`) require the Variable Group to be referenced at **both** the stage level AND the deployment job level. Stage-level variables alone are not sufficient for secret injection into deployment jobs.

**Fix:** Added `variables: - group: 'SQLDatabase-Secrets'` at the deployment job level in addition to the stage level:

```yaml
- deployment: DeployDevDB
  environment: 'SQL-Dev'
  variables:                              # <-- Added this
    - group: 'SQLDatabase-Secrets'        # <-- And this
  strategy:
    runOnce:
      deploy:
        steps:
          - task: PowerShell@2
            env:
              SQL_PASSWORD: $(SqlAdminPassword)   # Now resolves correctly
```

**Lesson:** Secret variables from Variable Groups need explicit `env:` mapping in tasks AND the Variable Group must be accessible at the job scope. Regular (non-secret) variables work differently from secrets in deployment jobs.

---

### Issue 3: Pipeline Not Auto-Triggering on YAML Changes

**Symptom:** After pushing changes to `pipelines/azure-pipelines.yml`, no new pipeline run started.

**Cause:** The trigger path filter only includes `migrations/*` and `scripts/*`. Changes to `pipelines/*` are intentionally excluded.

```yaml
trigger:
  paths:
    include:
      - migrations/*    # SQL migration files
      - scripts/*       # Deployment scripts
      # pipelines/* is NOT included -- by design
```

**Fix:** Run the pipeline manually from Azure DevOps UI when pipeline YAML changes.

**Why this is correct:** You don't want the pipeline deploying to databases just because someone edited a YAML comment. Only SQL migration or script changes should trigger deployments. Pipeline structure changes are tested via manual runs.

---

### Issue 4: First Run Permission Prompts

**Symptom:** Pipeline paused with "Permission needed" at multiple stages on the first run.

**Cause:** Azure DevOps requires explicit authorization for pipelines to access:
- Variable Groups (secrets)
- Environments (deployment targets)

**Fix:** Click "Permit" when prompted. This is a one-time authorization per resource.

**Why this exists:** It's a security feature. A new pipeline shouldn't automatically have access to production secrets or deployment environments. An administrator must explicitly grant access. This is the same principle as `GRANT EXECUTE ON procedure TO login` in SQL Server.

---

## 14. Docker — Running SQL Server Locally

> Docker lets you run SQL Server in seconds without installing it on your machine.
> This section teaches Docker fundamentals using DBA parallels so you can understand
> containers the same way you understand SQL Server instances.

### What is Docker?

Docker is a tool that runs applications in **containers** — isolated environments that include everything the application needs. Think of it as a lightweight virtual machine that starts in seconds instead of minutes.

**The key insight for DBAs:** Instead of spending an hour installing SQL Server, configuring TCP/IP, setting up authentication, and creating a database, you run ONE command and get a fully configured SQL Server instance in under 30 seconds.

### Docker Concepts — DBA Dictionary

| Docker Concept | DBA Parallel | What It Actually Is |
|---------------|-------------|-------------------|
| **Image** | SQL Server ISO/installer | A read-only template. `mcr.microsoft.com/mssql/server:2022-latest` is the SQL Server 2022 image. |
| **Container** | A running SQL Server instance | A live, running copy created from an image. You can have multiple containers from the same image (like multiple SQL instances). |
| **Volume** | Default data directory (`D:\SQLData`) | Persistent storage. Without it, your databases disappear when the container stops. With it, data survives restarts. |
| **Port mapping** | TCP Port in SQL Server Config Manager | Maps a port on your Mac (1433) to the container's port (1433). This is how you connect from outside the container. |
| **docker compose** | A scripted SQL Server installer | A YAML file that defines your entire environment. Run `docker compose up` and everything starts. Like a scripted unattended install. |
| **Dockerfile** | Custom install script | Instructions to build a custom image (e.g., SQL Server + your schema pre-loaded). We don't need one here because the official image works out of the box. |
| **Registry** | Microsoft Download Center | Where images are stored. `mcr.microsoft.com` is Microsoft's registry. `docker pull` downloads from it. |

### How Docker Works — Step by Step

```
1. You run: docker compose up -d

2. Docker checks: "Do I have the SQL Server image?"
   - NO  → Downloads it from Microsoft's registry (first time only, ~700MB)
   - YES → Uses the cached image

3. Docker creates a container from the image
   (Like installing SQL Server from the ISO)

4. Docker starts the container
   (Like starting the SQL Server Windows service)

5. SQL Server initializes inside the container
   (Creates system databases, starts listening on port 1433)

6. You connect with Azure Data Studio or SSMS
   (Server: localhost,1433 — exactly like connecting to a local instance)
```

### The docker-compose.yml File — Explained

Our `docker-compose.yml` is the "scripted installer" for your local SQL Server. Here's what each section does:

```yaml
services:
  sql-server:                                    # Service name (like an instance name)
    image: mcr.microsoft.com/mssql/server:2022-latest  # Which SQL Server to install
    container_name: sql-dev-local                # Name for this container

    environment:                                 # Setup wizard answers
      ACCEPT_EULA: "Y"                          # Accept license (required)
      MSSQL_SA_PASSWORD: "DevOps#Pass123"       # sa password
      MSSQL_PID: "Developer"                    # Edition: Developer (free, all features)

    ports:
      - "1433:1433"                             # Map Mac port 1433 -> container port 1433

    volumes:
      - sqlserver-data:/var/opt/mssql           # Persist data files

    deploy:
      resources:
        limits:
          memory: 2G                            # Like max server memory in sp_configure
```

**Why `docker-compose.yml` instead of a raw `docker run` command?**
Same reason you write SQL scripts instead of clicking in SSMS — it's repeatable, version-controlled, and self-documenting. Anyone on your team runs `docker compose up` and gets the exact same setup.

### Essential Docker Commands — DBA Cheat Sheet

| Command | DBA Equivalent | What It Does |
|---------|---------------|-------------|
| `docker compose up -d` | `net start MSSQLSERVER` | Start SQL Server (create container if needed) |
| `docker compose down` | `net stop MSSQLSERVER` | Stop SQL Server (container removed, data preserved) |
| `docker compose down -v` | Uninstall SQL Server + delete all databases | Stop and DELETE all data. **Destructive!** |
| `docker compose ps` | `Get-Service MSSQLSERVER` | Check if SQL Server is running |
| `docker compose logs -f sql-server` | SQL Server Error Log | Watch real-time logs (Ctrl+C to stop) |
| `docker exec -it sql-dev-local bash` | RDP into the server | Open a shell inside the container |
| `docker compose restart` | Restart SQL Server service | Restart the container |
| `docker images` | "What installers do I have?" | List downloaded images |
| `docker ps -a` | "What instances exist?" | List all containers (running or stopped) |

### Quick Start — Get SQL Server Running

**Step 1: Start SQL Server**
```bash
cd AzureDevOpsPipeline
docker compose up -d
```

First run downloads the image (~700MB). Subsequent starts take 2-3 seconds.

**Step 2: Wait for SQL Server to be ready (15-30 seconds)**
```bash
docker compose logs -f sql-server
```
Look for: `SQL Server is now ready for client connections`
Press Ctrl+C to stop watching logs.

**Step 3: Run the setup script (creates DevOpsDemo database)**
```bash
pwsh scripts/Setup-DockerDb.ps1
```
Or create the database manually:
```bash
docker exec sql-dev-local /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "DevOps#Pass123" -No \
  -Q "CREATE DATABASE DevOpsDemo"
```

**Step 4: Connect with Azure Data Studio**
- Server: `localhost,1433`
- Authentication: SQL Login
- User: `sa`
- Password: `DevOps#Pass123`

**Step 5: Run your migration scripts**
```bash
pwsh scripts/Deploy-SqlMigrations.ps1 \
  -ServerInstance "localhost" \
  -DatabaseName "DevOpsDemo" \
  -MigrationsPath "./migrations" \
  -Environment "Dev"
```

### Containers vs Virtual Machines

You were considering VMware Fusion. Here's why Docker is often better for development:

| Feature | Docker Container | Virtual Machine (VMware Fusion) |
|---------|-----------------|-------------------------------|
| **Startup time** | 2-3 seconds | 1-2 minutes |
| **Disk usage** | ~700MB (shared image) | 20-60GB per VM |
| **RAM usage** | 2GB (configurable) | 4-8GB minimum |
| **Setup time** | One command | Download ISO, install OS, install SQL Server |
| **Reproducibility** | `docker compose up` | Manual or scripted install |
| **Sharing** | Share `docker-compose.yml` (1KB) | Share entire VM image (20GB+) |
| **Multiple instances** | Easy — change port number | Heavy — each needs full OS |
| **OS** | Linux (SQL Server runs on Linux too) | Full Windows |

**When to use a VM instead:**
- You need Windows-specific features (SSIS, SSRS, SQL Agent with Windows auth)
- You're learning Windows Server administration
- You need Active Directory integration

**When Docker is better:**
- Local development database
- Testing your CI/CD pipeline
- Running multiple SQL Server versions side by side
- Quick disposable environments

### Docker Architecture — How It Fits Together

```
Your Mac (Host Machine)
├── Docker Desktop (the Docker engine)
│   └── Container: sql-dev-local
│       ├── SQL Server 2022 (Linux)
│       ├── Port 1433 (mapped to Mac's port 1433)
│       └── /var/opt/mssql (data files)
│           └── Mounted to volume "sqlserver-data" on your Mac's disk
│
├── Azure Data Studio / SSMS
│   └── Connects to localhost,1433 → reaches the container
│
└── Your Pipeline Scripts
    └── Deploy-SqlMigrations.ps1 -ServerInstance "localhost"
        └── Connects to localhost,1433 → reaches the container
```

### What Happens to Your Data?

| Action | Your Databases | Your Data |
|--------|---------------|-----------|
| `docker compose stop` | Preserved | Safe |
| `docker compose down` | Preserved (in volume) | Safe |
| `docker compose down -v` | **DELETED** | **GONE** |
| Docker Desktop restart | Preserved | Safe |
| Mac restart | Preserved | Safe |
| `docker compose up` after `down` | Restored from volume | Safe |

The `-v` flag means "delete volumes." This is the ONLY command that destroys your data. Think of it as `DROP DATABASE` — it's permanent.

### Multiple SQL Server Versions

Need to test against SQL Server 2019 AND 2022? Docker makes this trivial:

```yaml
# In docker-compose.yml, add a second service:
services:
  sql-2022:
    image: mcr.microsoft.com/mssql/server:2022-latest
    ports:
      - "1433:1433"        # Connect via localhost,1433
    # ... (same config as above)

  sql-2019:
    image: mcr.microsoft.com/mssql/server:2019-latest
    ports:
      - "1434:1433"        # Connect via localhost,1434
    # ... (same config, different port)
```

Now you have two SQL Server instances running simultaneously on different ports. Try doing that with traditional installs — you'd need named instances, different service accounts, and manual configuration. Docker does it with a port number change.

### Troubleshooting Docker

**Container won't start — port already in use:**
```bash
# Check what's using port 1433
lsof -i :1433
# Change the port in docker-compose.yml: "1434:1433"
```

**SQL Server won't accept connections:**
```bash
# Check container status
docker compose ps
# Check logs for errors
docker compose logs sql-server
# Common issue: password doesn't meet complexity requirements
```

**Container keeps restarting:**
```bash
# Check logs for the error
docker compose logs --tail 50 sql-server
# Usually: weak password or insufficient memory
```

**"Cannot connect to localhost,1433":**
```bash
# Verify container is running
docker compose ps
# Verify port mapping
docker port sql-dev-local
# Wait — SQL Server needs 15-30 seconds to initialize
```

---

## 15. Docker Management — Day-to-Day Operations

> Now that you have Docker running, this section teaches you how to manage it.
> Think of this as the "SQL Server Administration" guide, but for Docker.

### The Docker Lifecycle — How Containers Live and Die

```
Image (blueprint)
  │
  ├─ docker compose up ──→ Container CREATED ──→ Container RUNNING
  │                                                    │
  │                              docker compose stop ──┤
  │                                                    │
  │                              Container STOPPED ◄───┘
  │                                  │
  │         docker compose start ────┤
  │                                  │
  │         docker compose down ─────┤──→ Container REMOVED
  │                                        (volume data kept)
  │
  │         docker compose down -v ──────→ Container REMOVED
  │                                        + Volume DELETED
  │                                        (ALL DATA GONE)
  │
  └─ docker rmi ──→ Image DELETED (need to re-download)
```

**DBA Parallel:**
| Docker Lifecycle | SQL Server Equivalent |
|-----------------|----------------------|
| Image downloaded | SQL Server installer downloaded |
| Container created | SQL Server installed |
| Container running | SQL Server service started |
| Container stopped | SQL Server service stopped |
| Container removed | SQL Server uninstalled (but data files remain) |
| Volume deleted | Data files (.mdf/.ldf) deleted |
| Image deleted | Installer deleted |

---

### Container Management

#### Viewing containers

```bash
# Show running containers (like Get-Service | Where Status -eq Running)
docker ps

# Show ALL containers, including stopped ones
docker ps -a

# Show containers with custom format (cleaner output)
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Show only your SQL Server container
docker compose ps
```

**Reading the output:**
```
NAMES           STATUS                  PORTS
sql-dev-local   Up 2 hours (healthy)    0.0.0.0:1434->1433/tcp
```
- `STATUS`: "Up" = running, "Exited" = stopped, "(healthy)" = healthcheck passing
- `PORTS`: `0.0.0.0:1434->1433` means Mac port 1434 routes to container port 1433

#### Starting and stopping

```bash
# Start your SQL Server (defined in docker-compose.yml)
docker compose up -d

# Stop without removing (data preserved, fast restart)
docker compose stop

# Start again after stop (faster than 'up' - container already exists)
docker compose start

# Stop AND remove container (data preserved in volume)
docker compose down

# Restart (stop + start)
docker compose restart
```

**DBA Parallel:**
```
docker compose up -d    = net start MSSQLSERVER
docker compose stop     = net stop MSSQLSERVER
docker compose start    = net start MSSQLSERVER (after stop)
docker compose restart  = Restart-Service MSSQLSERVER
docker compose down     = Stop service + uninstall (but keep databases)
```

#### Executing commands inside a container

```bash
# Open an interactive bash shell inside the container
# (like RDP-ing into a server and opening cmd)
docker exec -it sql-dev-local bash

# Run a single command without entering the shell
docker exec sql-dev-local ls /var/opt/mssql/data

# Check SQL Server process inside container
docker exec sql-dev-local ps aux | grep sqlservr
```

**The `-it` flags explained:**
- `-i` = interactive (keep stdin open — so you can type)
- `-t` = allocate a terminal (so you get a proper prompt)
- Together: you get a live shell session inside the container

---

### Image Management

Images are the "installers" — read-only templates that containers are created from.

```bash
# List all downloaded images (like "what installers do I have?")
docker images

# See how much space images use
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

# Pull/update an image without starting a container
docker pull mcr.microsoft.com/azure-sql-edge:latest

# Remove an image you no longer need
docker rmi mcr.microsoft.com/azure-sql-edge:latest

# Remove all unused images (saves disk space)
docker image prune
```

**Understanding image tags:**
```
mcr.microsoft.com/azure-sql-edge:latest
│                  │                │
│                  │                └── Tag (version) — "latest" = newest
│                  └── Image name
└── Registry (Microsoft Container Registry)
```

Common SQL Server image tags:
| Image | Tag | What It Is |
|-------|-----|-----------|
| `mssql/server` | `2022-latest` | SQL Server 2022 (x86 only) |
| `mssql/server` | `2019-latest` | SQL Server 2019 (x86 only) |
| `azure-sql-edge` | `latest` | Azure SQL Edge (ARM + x86) |

---

### Volume Management

Volumes are where your database files live. This is the most important section for a DBA — volumes are your data.

```bash
# List all volumes (like viewing all data directories)
docker volume ls

# Inspect a volume (see where it's stored on your Mac's disk)
docker volume inspect azuredevopspipeline_sqlserver-data

# See volume disk usage
docker system df -v | head -20

# Remove a specific volume (DESTRUCTIVE - deletes all database files!)
docker volume rm azuredevopspipeline_sqlserver-data

# Remove all unused volumes (CAREFUL - only removes volumes not attached to containers)
docker volume prune
```

**Where do volumes actually live on your Mac?**
Docker Desktop stores volumes inside its own VM. You can inspect the path:
```bash
docker volume inspect azuredevopspipeline_sqlserver-data --format '{{.Mountpoint}}'
# Output: /var/lib/docker/volumes/azuredevopspipeline_sqlserver-data/_data
```

This path is inside Docker's VM, not directly on your Mac filesystem. Docker Desktop manages it automatically.

**DBA Parallel:**
| Volume Operation | SQL Server Equivalent |
|-----------------|----------------------|
| `docker volume ls` | Check default data directories |
| `docker volume inspect` | View file path properties of a database |
| `docker volume rm` | Delete .mdf/.ldf files permanently |
| `docker volume prune` | Clean up orphaned data files |

---

### Logs and Monitoring

#### Viewing logs

```bash
# Stream logs in real-time (like watching SQL Server Error Log)
# Press Ctrl+C to stop
docker compose logs -f sql-server

# Show last 50 lines
docker compose logs --tail 50 sql-server

# Show logs with timestamps
docker compose logs -t sql-server

# Show logs since a specific time
docker compose logs --since 1h sql-server
```

**DBA Parallel:** `docker compose logs` = opening SQL Server Error Log in SSMS or running `xp_readerrorlog`

#### Resource monitoring

```bash
# Live resource usage (like Task Manager / Performance Monitor)
# Shows CPU %, Memory usage, Network I/O, Disk I/O
# Press Ctrl+C to stop
docker stats

# One-time snapshot (no live updates)
docker stats --no-stream

# Show only your SQL container
docker stats sql-dev-local --no-stream
```

**Reading the output:**
```
NAME            CPU %    MEM USAGE / LIMIT     MEM %    NET I/O          BLOCK I/O
sql-dev-local   0.50%    412MiB / 2GiB         20.12%   1.2kB / 0B       45MB / 12MB
```
- `MEM USAGE / LIMIT`: 412MB used out of 2GB limit (set in docker-compose.yml)
- `CPU %`: Current CPU usage
- `NET I/O`: Network traffic in/out
- `BLOCK I/O`: Disk reads/writes

**DBA Parallel:**
```
docker stats  =  sp_who2 + sys.dm_os_performance_counters + Task Manager
```

#### Healthcheck status

```bash
# Check container health status
docker inspect sql-dev-local --format '{{.State.Health.Status}}'

# See healthcheck history (last few checks)
docker inspect sql-dev-local --format '{{json .State.Health}}' | python3 -m json.tool
```

Health statuses:
- `healthy` — healthcheck is passing (SQL Server is accepting connections)
- `unhealthy` — healthcheck is failing (SQL Server may be down)
- `starting` — container just started, still initializing

---

### Network Management

Docker creates networks to let containers talk to each other.

```bash
# List Docker networks
docker network ls

# Inspect a network (see which containers are connected)
docker network inspect azuredevopspipeline_default

# See your container's IP address inside Docker
docker inspect sql-dev-local --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

**When do you need networks?**
For a single SQL Server container, you don't need to manage networks — Docker handles it. Networks become important when you have **multiple containers that need to talk to each other** (e.g., a web app container connecting to a SQL container).

**DBA Parallel:** Docker networks = SQL Server network configuration (TCP/IP, Named Pipes). The port mapping (`1434:1433`) is your "connection point" from outside Docker.

---

### Cleanup and Maintenance

Docker can accumulate unused images, stopped containers, and orphaned volumes over time.

```bash
# See total Docker disk usage (start here)
docker system df

# Output example:
# TYPE          TOTAL   ACTIVE  SIZE      RECLAIMABLE
# Images        5       2       3.2GB     1.8GB (56%)
# Containers    3       1       62B       0B
# Volumes       2       1       245MB     120MB (49%)
```

#### Safe cleanup commands (won't delete running containers or used volumes)

```bash
# Remove stopped containers, unused networks, dangling images
docker system prune

# Same as above + unused images (not just dangling)
docker system prune -a

# Remove only unused volumes (CAREFUL with this one)
docker volume prune

# Remove only unused images
docker image prune -a
```

**What "dangling" means:**
- A dangling image has no tag and no container using it
- Usually leftover from image updates (old versions replaced by new pulls)
- Safe to remove

**DBA Parallel:**
```
docker system prune   = Cleanup old backups, delete orphaned files
docker volume prune   = Drop databases that no one is using anymore
docker image prune    = Delete old SQL Server installers
```

#### Scheduled cleanup tip

Add to your routine (e.g., monthly):
```bash
# See what's using space
docker system df

# Clean up safely
docker system prune -a

# Verify
docker system df
```

---

### Docker Compose Advanced Operations

#### Rebuilding after changes

```bash
# If you change docker-compose.yml:
docker compose down && docker compose up -d

# Force recreate containers (even if config hasn't changed)
docker compose up -d --force-recreate

# Pull latest image version and restart
docker compose pull && docker compose up -d
```

#### Viewing configuration

```bash
# Validate and view the final docker-compose.yml (after variable substitution)
docker compose config

# See which services are defined
docker compose config --services
```

#### Scaling (running multiple instances)

```bash
# This doesn't apply to our setup (we have fixed container names)
# but in general, you can scale services:
# docker compose up -d --scale web=3
# This creates 3 instances of the "web" service
```

---

### Quick Reference Card

```
┌─────────────────────────────────────────────────────────┐
│              DOCKER MANAGEMENT CHEAT SHEET              │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  DAILY OPERATIONS                                       │
│  docker compose up -d        Start SQL Server           │
│  docker compose stop         Stop SQL Server            │
│  docker compose start        Resume SQL Server          │
│  docker compose ps           Check status               │
│  docker compose logs -f      Watch error logs           │
│                                                         │
│  INSPECTION                                             │
│  docker ps                   List running containers    │
│  docker stats                Live resource monitor      │
│  docker exec -it [name] bash Shell into container       │
│  docker inspect [name]       Full container details     │
│                                                         │
│  IMAGES                                                 │
│  docker images               List downloaded images     │
│  docker pull [image]         Download/update image      │
│  docker rmi [image]          Delete an image            │
│                                                         │
│  VOLUMES (YOUR DATA)                                    │
│  docker volume ls            List all volumes           │
│  docker volume inspect [v]   Volume details             │
│  docker volume rm [v]        DELETE volume (DANGER!)    │
│                                                         │
│  CLEANUP                                                │
│  docker system df            Check disk usage           │
│  docker system prune         Clean unused resources     │
│  docker system prune -a      Aggressive cleanup         │
│                                                         │
│  NUCLEAR OPTIONS (CAUTION!)                             │
│  docker compose down -v      Stop + delete ALL data     │
│  docker volume prune         Delete unused volumes      │
│  docker system prune -a      Delete everything unused   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## 16. What to Learn Next

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
│   ├── azure-pipelines.yml           ← Main pipeline (5 stages, including DevSecOps)
│   └── templates/
│       ├── variables-common.yml      ← Shared config (non-secret)
│       ├── variables-dev.yml         ← Dev server/DB names
│       ├── variables-test.yml        ← Test server/DB names
│       └── variables-prod.yml        ← Prod server/DB names
├── scripts/
│   ├── Validate-SqlMigrations.ps1    ← Pre-deployment checks
│   ├── Scan-SqlSecurity.ps1          ← DevSecOps: SQL security scanner
│   ├── Scan-SecretsLeak.ps1          ← DevSecOps: Credential leak scanner
│   ├── Deploy-SqlMigrations.ps1      ← Migration execution engine
│   ├── Test-Deployment.ps1           ← Post-deployment health checks
│   └── Setup-DockerDb.ps1           ← Docker SQL Server setup helper
├── migrations/
│   ├── V001__create_users_table.sql
│   ├── V002__create_orders_table.sql
│   └── V003__add_phone_to_users.sql
├── docker-compose.yml                ← Local SQL Server (Docker)
└── WALKTHROUGH.md                    ← Full educational guide
```

### Key Concepts Covered (with DBA parallels)

| Concept | Where to Look | DBA Parallel |
|---------|--------------|--------------|
| **Pipeline structure** | `azure-pipelines.yml` | SQL Agent Job with 5 step groups |
| **Triggers** | Lines 24-30 of the pipeline | DDL trigger on `migrations/*` path |
| **Stages/Jobs/Tasks** | Each `stage:` block | Job steps organized by environment |
| **Environment promotion** | `dependsOn:` between stages | Manual script promotion, now automated |
| **Secure variables** | Variable Groups + `env: SQL_PASSWORD` | SQL Server Credential Manager |
| **Approval gates** | `environment: 'SQL-Prod'` | Change Advisory Board, enforced by system |
| **DevSecOps scanning** | `Scan-SqlSecurity.ps1`, `Scan-SecretsLeak.ps1` | Security audit before deployment |
| **Deployment validation** | `Test-Deployment.ps1` | Automated DBCC CHECKDB + smoke tests |
| **Migration tracking** | `MigrationHistory` table in deploy script | Deployment audit log |

### The Pipeline Flow

```
Commit → Validate → Security Scan → Deploy DEV → Test DEV → Approve → Deploy TEST → Approve → Deploy PROD
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
   │  SECURITY    │  DevSecOps: SQL injection, secrets,
   │    SCAN      │  permissions, dangerous configs
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
