# Managed-File-Transfer-Archive

## Overview

Terraform/Terraflow add-on to the primary MFT platform. It provisions an **archive S3 bucket** and a **VPC-attached Lambda** that mirrors objects arriving in the primary AWS Transfer Family bucket.

On each `s3:ObjectCreated:*` event the Lambda:

1. Parses the source key
2. Repositions the frequency segment so static lifecycle prefixes work
3. Appends a UTC datetime stamp to the filename
4. Copies the object into the archive bucket with KMS encryption

Detailed requirements live in [`SPECIFICATION.md`](./SPECIFICATION.md).

## Architecture

```
                         ┌─────────────────────────────────────┐
                         │     Existing MFT Platform (ext.)    │
                         │  Transfer Family / partners / apps  │
                         └──────────────────┬──────────────────┘
                                            │ PutObject
                                            ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  Primary MFT S3 Bucket  (data source — not managed here)                  │
│  Key: <env>/<carrier>/<partner>/<transferType>/<frequency>/<filename>     │
└─────────────────────────────────┬─────────────────────────────────────────┘
                                  │ s3:ObjectCreated:*
                                  ▼
                    ┌─────────────────────────────┐
                    │  Lambda Permission          │
                    │  (s3.amazonaws.com invoke)  │
                    └──────────────┬──────────────┘
                                   ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  VPC (private subnets + shared MFT security group)                        │
│                                                                           │
│   ┌──────────────────────────────┐     ┌──────────────────────────────┐ │
│   │  Archive Lambda              │     │  CloudWatch Log Group        │ │
│   │  runtime: nodejs20.x         │────▶│  retention: 90 days          │ │
│   │  handler: index.handler      │     └──────────────────────────────┘ │
│   │  env: ARCHIVE_BUCKET         │                                      │
│   └──────────────┬───────────────┘                                      │
│                  │ CopyObject (aws:kms)                                   │
└──────────────────┼──────────────────────────────────────────────────────┘
                   │
                   ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  Archive S3 Bucket  (provisioned by this project)                         │
│  Key: <env>/<frequency>/<carrier>/<partner>/<transferType>/               │
│       <basename>_<yyyyMMdd-HHmmss><ext>                                   │
│                                                                           │
│  • Public access blocked                                                  │
│  • Default encryption: aws:kms (shared MFT CMK) + bucket key              │
│  • Lifecycle rules by prefix (STANDARD_IA → DEEP_ARCHIVE → expire)        │
└───────────────────────────────────────────────────────────────────────────┘
                   ▲
                   │ encrypt / decrypt
                   │
         ┌─────────┴─────────┐
         │  Existing KMS Key │
         │  (alias lookup)   │
         └───────────────────┘
```

### Major resources

| Resource | Purpose |
|---|---|
| `aws_s3_bucket.archive` | Archive destination with KMS encryption and lifecycle rules |
| `aws_lambda_function.archive` | Copies/rekeys objects on primary-bucket create events |
| `aws_iam_role.lambda_exec` | Least-privilege execution role (logs, ENI, S3, KMS) |
| `aws_cloudwatch_log_group.archive_lambda` | Lambda logs (90-day retention) |
| `aws_s3_bucket_notification.primary` | Wires primary bucket `ObjectCreated` → Lambda |

All taggable resources (`aws_s3_bucket`, `aws_lambda_function`, `aws_iam_role`, `aws_cloudwatch_log_group`) receive `merge(var.tags, { Name = <resource name> })`, so a `Name` tag is always set from the resource’s configured name and combined with any tags passed in via `TAGS`.

### Data sources (existing platform)

| Data source | Purpose |
|---|---|
| `aws_s3_bucket.primary` | Primary Transfer Family bucket (events + `s3:GetObject`) |
| `aws_kms_key.mft` | Shared MFT CMK for decrypt/encrypt |
| `archive_file.lambda` | Zips `.build/lambda/archive` for Lambda deploy |

### Key rewrite

| | Path |
|---|---|
| **Primary** | `<env>/<carrier>/<partner>/<transferType>/<frequency>/<filename>` |
| **Archive** | `<env>/<frequency>/<carrier>/<partner>/<transferType>/<basename>_<datetime><ext>` |

Valid frequencies: `daily`, `weekly`, `monthly`, `quarterly`, `semi-annual`, `annual`.

Invalid keys or frequencies are logged and skipped; per-record errors do not fail the invocation (avoids S3 retry storms).

### Lifecycle summary

| Prefix | IA | Deep Archive | Expire |
|---|---|---|---|
| `production/daily` | 7d | — | 60d |
| `production/weekly` | 7d | — | 84d |
| `production/monthly` | 7d | 37d | 396d |
| `production/quarterly` | 7d | 90d | 1095d |
| `production/semi-annual` | 7d | 180d | 2555d |
| `production/annual` | 7d | 365d | 2555d |
| `test/*` (all frequencies) | — | — | 7d |

## Project structure

```
.tfwconfig.yml              # Terraflow config (variables interpolated from .env)
.env.example                # Credential / env template
.env                        # Local secrets (gitignored)
SPECIFICATION.md            # Authoritative project spec
terraform/
├── _init.tf                # Providers / backend scaffold
├── inputs.tf               # Input variables
├── locals.tf               # Lambda sizing + lifecycle map
├── main.tf                 # Resources and data sources
└── outputs.tf              # Bucket / Lambda outputs
src/
├── main/index.ts           # Archive Lambda handler
└── test/index.spec.ts      # Jest unit tests (mocked AWS SDK)
```

## Local development

### Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.0
- [Node.js](https://nodejs.org/) >= 18.x (Lambda runtime is **nodejs20.x**)
- [Terraflow](https://www.npmjs.com/package/terraflow): `npm install -g terraflow`
- AWS credentials (`~/.aws` or env vars)

### Setup

```bash
cp .env.example .env
# Add project variables (see Configuration below)

npm install
```

### Test / lint / build

```bash
npm test                 # Jest unit tests
npm run test:coverage
npm run lint
npm run build:lambda:archive   # esbuild → .build/lambda/archive/index.js
```

### Plan / apply

Prefer the npm wrappers so the Lambda artifact is built first:

```bash
npm run tf:plan          # build:lambda:archive && tf plan
npm run tf:apply         # build:lambda:archive && tf apply
```

Or use Terraflow directly (build the Lambda first):

```bash
npm run build:lambda:archive
terraflow plan
terraflow apply
```

## Configuration

Terraform inputs are declared in `terraform/inputs.tf` and supplied via `.tfwconfig.yml` using `${VAR}` interpolation from `.env`:

| Env var | Terraform variable |
|---|---|
| `ARCHIVE_BUCKET_NAME` | `archive_bucket_name` |
| `PRIMARY_BUCKET_NAME` | `primary_bucket_name` |
| `PRIMARY_KMS_KEY_ALIAS` | `primary_kms_key_alias` (code prefixes `alias/`) |
| `LAMBDA_FUNCTION_NAME` | `lambda_function_name` |
| `LAMBDA_EXECUTION_ROLE_NAME` | `lambda_execution_role_name` |
| `LAMBDA_LOG_GROUP_NAME` | `lambda_log_group_name` |
| `VPC_ID` | `vpc_id` |
| `SUBNET_IDS` | `subnet_ids` (JSON array string) |
| `SECURITY_GROUP_IDS` | `security_group_ids` (JSON array string) |
| `TAGS` | `tags` (JSON object string) |

Example `.env` entries:

```bash
ARCHIVE_BUCKET_NAME='my-archive-bucket'
PRIMARY_BUCKET_NAME='my-primary-bucket'
PRIMARY_KMS_KEY_ALIAS='mft-default'
SUBNET_IDS='["subnet-aaa","subnet-bbb"]'
SECURITY_GROUP_IDS='["sg-ccc"]'
TAGS='{"Project":"Managed-File-Transfer-Archive","ManagedBy":"terraform"}'
```

See [Terraflow configuration docs](https://github.com/salte-common/terraflow/blob/main/docs/configuration.md) for backends, workspaces, and template variables (`AWS_REGION`, `AWS_ACCOUNT_ID`, etc.).

### Outputs

| Output | Description |
|---|---|
| `archive_bucket_name` / `archive_bucket_arn` | Provisioned archive bucket |
| `lambda_function_name` / `lambda_function_arn` | Archive Lambda |

## Development workflow

1. Create a feature branch
2. Update code / Terraform as needed
3. Run `npm test` and `npm run lint`
4. `npm run tf:plan` against a non-prod workspace
5. Open a pull request

Workspace selection follows Terraflow defaults (CLI → `TERRAFLOW_WORKSPACE` → git tag → branch → hostname).

## Assumptions

- Primary MFT bucket, KMS key, VPC, subnets, security group, and S3 VPC endpoints already exist
- Archive bucket is single-region (no CRR)
- Resource names are supplied explicitly (no derived naming prefix)

## License

MIT
