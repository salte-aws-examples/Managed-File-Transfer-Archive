# Managed-File-Transfer-Archive

Infrastructure as Code project managed with [Terraflow](https://github.com/salte-common/terraflow).

**Cursor-ready:** This project is scaffolded for [Cursor](https://cursor.com/) with rules for Terraflow, development standards, and AI code tracking. Open in Cursor to get up and running quickly with AI-assisted development.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.0
- [Node.js](https://nodejs.org/) >= 18.x
- [Terraflow](https://www.npmjs.com/package/terraflow): `npm install -g terraflow`
- Cloud provider credentials (aws)

## Getting Started

1. **Credentials** (optional if using standard locations):
   - **AWS:** `~/.aws/credentials` and `~/.aws/config` — no `.env` needed
   - **Azure:** `az login` — no `.env` needed
   - **GCP:** `gcloud auth application-default login` — no `.env` needed
   
   Otherwise, copy `.env.example` to `.env` and configure your credentials:
   ```bash
   cp .env.example .env
   # Edit .env with your credentials
   ```

2. Review and update `.tfwconfig.yml` with your backend configuration

3. **Initialize Terraform** (optional — runs automatically before plan/apply):
   ```bash
   terraflow init
   ```
   You can skip this step; Terraflow runs init automatically when needed.

4. Plan your infrastructure:
   ```bash
   terraflow plan
   ```

5. Apply your infrastructure:
   ```bash
   terraflow apply
   ```

## Project Structure

- `src/` - Application source code
  - `main/` - Main application code
  - `test/` - Test files
- `terraform/` - Infrastructure as Code
  - `modules/` - Reusable Terraform modules
  - `_init.tf` - Provider and backend configuration
  - `*.tf` - Main terraform configuration
- `.tfwconfig.yml` - Terraflow configuration
- `.env` - Local environment variables (not committed)

## Terraflow Commands

```bash
# Initialize terraform and workspace
terraflow init

# Plan changes
terraflow plan

# Apply changes
terraflow apply

# Destroy infrastructure
terraflow destroy

# Show current configuration
terraflow config show
```

## Workspace Management

Terraflow derives workspace names in this order (first match wins):

1. **CLI override** — `--workspace` or `-w`
2. **Environment variable** — `TERRAFLOW_WORKSPACE`
3. **Git tag** — if checked out on a tag (e.g. `v1.0.0` → `v1-0-0`)
4. **Git branch** — if non-ephemeral (e.g. `main`, `my-preview-branch`). Ephemeral branches (`feature/foo`, `fix/bar`) fall through to hostname.
5. **Hostname** — when none of the above apply (no git repo, no tag, or ephemeral branch)

Examples:
- `main` → `main` workspace
- `my-preview-branch` → `my-preview-branch` workspace
- `feature/new-api` → hostname
- No git repo → hostname

## Configuration

See `.tfwconfig.yml` for all available options and the [documentation](https://github.com/salte-common/terraflow/blob/main/docs/configuration.md) for detailed configuration reference.

## Project Specification

You can create a `SPECIFICATION.md` file in the project root to define project-specific requirements, architecture, and conventions. Cursor and other AI tools will read this file to inform code suggestions and maintain consistency with your specification.

## License

MIT

