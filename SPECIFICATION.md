# MFT Archive — Project Specification

## Overview

A Terraform/Terraflow add-on project to the primary MFT platform. Provisions an S3 archive bucket that mirrors files arriving in the primary AWS Transfer Family S3 bucket, with datetime-stamped filenames and frequency-based path restructuring to enable static lifecycle policies.

---

## Repository Structure

After scaffolding and Cursor modifications the repository should look like this:

```
.tfwconfig.yml              # Terraflow config — do not modify
.env.example                # Environment variable template — do not modify
terraform/
├── _init.tf                # Keep as scaffolded — do not modify
├── inputs.tf               # Overwrite — variables defined in this spec
├── locals.tf               # Overwrite — locals defined in this spec
├── main.tf                 # Overwrite — all resources and data sources
└── outputs.tf              # Overwrite — outputs defined in this spec
src/
├── main/
│   └── index.ts            # Overwrite — archive Lambda handler
└── test/
    └── index.spec.ts       # Overwrite — unit tests
```

**Delete entirely:**
- `terraform/modules/` — not used in this project

---

## Input Variables (`terraform/inputs.tf`)

```hcl
variable "vpc_id" {
  description = "VPC ID for Lambda network placement"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for Lambda VPC config"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for Lambda VPC config — shared MFT workload security group"
  type        = list(string)
}

variable "primary_bucket_name" {
  description = "Name of the primary MFT Transfer Family S3 bucket — source of S3 events"
  type        = string
}

variable "archive_bucket_name" {
  description = "Name of the archive S3 bucket to be provisioned"
  type        = string
}

variable "primary_kms_key_alias" {
  description = "KMS key alias used for the primary MFT bucket — used for both Lambda decrypt and archive bucket encryption. e.g. alias/mft-default"
  type        = string
}

variable "lambda_function_name" {
  description = "Name of the archive Lambda function"
  type        = string
}

variable "lambda_execution_role_name" {
  description = "Name of the IAM execution role for the archive Lambda"
  type        = string
}

variable "lambda_log_group_name" {
  description = "Name of the CloudWatch log group for the archive Lambda"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all taggable resources (merged with a Name tag derived from each resource name)"
  type        = map(string)
  default     = {}
}
```

---

## Locals (`terraform/locals.tf`)

```hcl
locals {
  lambda_memory_size = 256
  lambda_timeout     = 60

  lifecycle_policies = {
    "production/daily" = {
      ia_transition_days = 7
      expiration_days    = 60
    }
    "production/weekly" = {
      ia_transition_days = 7
      expiration_days    = 84
    }
    "production/monthly" = {
      ia_transition_days      = 7
      glacier_transition_days = 37
      expiration_days         = 396
    }
    "production/quarterly" = {
      ia_transition_days      = 7
      glacier_transition_days = 90
      expiration_days         = 1095
    }
    "production/semi-annual" = {
      ia_transition_days      = 7
      glacier_transition_days = 180
      expiration_days         = 2555
    }
    "production/annual" = {
      ia_transition_days      = 7
      glacier_transition_days = 365
      expiration_days         = 2555
    }
    "test/daily"       = { expiration_days = 7 }
    "test/weekly"      = { expiration_days = 7 }
    "test/monthly"     = { expiration_days = 7 }
    "test/quarterly"   = { expiration_days = 7 }
    "test/semi-annual" = { expiration_days = 7 }
    "test/annual"      = { expiration_days = 7 }
  }
}
```

---

## Resources and Data Sources (`terraform/main.tf`)

### Data Sources

```hcl
# Primary MFT bucket — referenced for event notification and IAM
data "aws_s3_bucket" "primary" {
  bucket = var.primary_bucket_name
}

# KMS key — single key used for both primary bucket decryption and archive bucket encryption
data "aws_kms_key" "mft" {
  key_id = var.primary_kms_key_alias
}

# Lambda archive zip
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../.build/lambda/archive"
  output_path = "${path.module}/../.build/lambda/archive.zip"
}
```

### Archive S3 Bucket

```hcl
resource "aws_s3_bucket" "archive" {
  bucket = var.archive_bucket_name
  tags   = merge(var.tags, { Name = var.archive_bucket_name })
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = data.aws_kms_key.mft.arn
    }
    bucket_key_enabled = true
  }
}
```

### Lifecycle Policy

Use a `dynamic` block iterating over `local.lifecycle_policies`. Each map key is the prefix (e.g. `production/daily`). Generate one rule per entry:

- `id` = key with `/` replaced by `-` (e.g. `production-daily`)
- `prefix` = key + `/` (e.g. `production/daily/`)
- `status` = `Enabled`
- If `ia_transition_days` is set → add transition to `STANDARD_IA`
- If `glacier_transition_days` is set → add transition to `DEEP_ARCHIVE`
- Always add expiration with `expiration_days`

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  dynamic "rule" {
    for_each = local.lifecycle_policies
    content {
      id     = replace(rule.key, "/", "-")
      status = "Enabled"

      filter {
        prefix = "${rule.key}/"
      }

      dynamic "transition" {
        for_each = lookup(rule.value, "ia_transition_days", null) != null ? [rule.value.ia_transition_days] : []
        content {
          days          = transition.value
          storage_class = "STANDARD_IA"
        }
      }

      dynamic "transition" {
        for_each = lookup(rule.value, "glacier_transition_days", null) != null ? [rule.value.glacier_transition_days] : []
        content {
          days          = transition.value
          storage_class = "DEEP_ARCHIVE"
        }
      }

      expiration {
        days = rule.value.expiration_days
      }
    }
  }
}
```

### S3 Event Notification

```hcl
resource "aws_s3_bucket_notification" "primary" {
  bucket = data.aws_s3_bucket.primary.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.archive.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.s3_invoke]
}
```

### Lambda Permission

```hcl
resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invocation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.archive.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = data.aws_s3_bucket.primary.arn
}
```

### CloudWatch Log Group

```hcl
resource "aws_cloudwatch_log_group" "archive_lambda" {
  name              = var.lambda_log_group_name
  retention_in_days = 90
  tags              = merge(var.tags, { Name = var.lambda_log_group_name })
}
```

### Lambda Function

```hcl
resource "aws_lambda_function" "archive" {
  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  memory_size      = local.lambda_memory_size
  timeout          = local.lambda_timeout

  environment {
    variables = {
      ARCHIVE_BUCKET = var.archive_bucket_name
    }
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  tags = merge(var.tags, { Name = var.lambda_function_name })

  depends_on = [aws_cloudwatch_log_group.archive_lambda]
}
```

### IAM Role

```hcl
resource "aws_iam_role" "lambda_exec" {
  name = var.lambda_execution_role_name
  tags = merge(var.tags, { Name = var.lambda_execution_role_name })

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_exec" {
  name = var.lambda_execution_role_name
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${data.aws_s3_bucket.primary.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.archive.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = data.aws_kms_key.mft.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = data.aws_dynamodb_table.users.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}
```

---

## Outputs (`terraform/outputs.tf`)

```hcl
output "archive_bucket_name" {
  description = "Name of the provisioned archive S3 bucket"
  value       = aws_s3_bucket.archive.id
}

output "archive_bucket_arn" {
  description = "ARN of the provisioned archive S3 bucket"
  value       = aws_s3_bucket.archive.arn
}

output "lambda_function_name" {
  description = "Name of the archive Lambda function"
  value       = aws_lambda_function.archive.function_name
}

output "lambda_function_arn" {
  description = "ARN of the archive Lambda function"
  value       = aws_lambda_function.archive.arn
}
```

---

## Lambda Source (`src/main/index.ts`)

### Behavior

Triggered by S3 `ObjectCreated` events on the primary MFT bucket. For each event record:

1. Parse the S3 key to extract path components
2. Construct the archive key with frequency repositioned and datetime appended
3. Copy the object to the archive bucket

### S3 Key Structure

**Primary bucket key:**
```
<envPath>/<carrierId>/<partnerId>/<transferTypeId>/<frequency>/<filename>
```

Where `<envPath>` is `test` or `production`.

**Archive bucket key:**
```
<envPath>/<frequency>/<carrierId>/<partnerId>/<transferTypeId>/<basename>_<datetime>.<ext>
```

### Key Parsing

```
parts[0] = envPath        (test | production)
parts[1] = carrierId
parts[2] = partnerId
parts[3] = transferTypeId
parts[4] = frequency      (daily | weekly | monthly | quarterly | semi-annual | annual)
parts[5] = filename
```

Minimum 6 parts required — log error and skip if fewer parts found.

### Datetime Format

Append to base filename (before extension): `_YYYYMMDD-HHmmss` using UTC time at moment of Lambda invocation.

Example: `general-ledger.txt` → `general-ledger_20260115-143022.txt`

For files with no extension: `general-ledger` → `general-ledger_20260115-143022`

### Archive Key Construction

```typescript
const archiveKey = `${envPath}/${frequency}/${carrierId}/${partnerId}/${transferTypeId}/${basename}_${datetime}${ext}`;
```

### Valid Frequency Values

```typescript
const VALID_FREQUENCIES = ["daily", "weekly", "monthly", "quarterly", "semi-annual", "annual"];
```

Log error and skip if frequency parsed from key is not in this list.

### Source Code

```typescript
import { S3Client, GetObjectCommand, CopyObjectCommand } from "@aws-sdk/client-s3";
import { S3Event } from "aws-lambda";
import { format } from "date-fns";

const s3 = new S3Client({});

const VALID_FREQUENCIES = ["daily", "weekly", "monthly", "quarterly", "semi-annual", "annual"];
const ARCHIVE_BUCKET = process.env.ARCHIVE_BUCKET!;

export const handler = async (event: S3Event): Promise<void> => {
  for (const record of event.Records) {
    const sourceBucket = record.s3.bucket.name;
    const sourceKey    = decodeURIComponent(record.s3.object.key.replace(/\+/g, " "));

    try {
      const parts = sourceKey.split("/");

      if (parts.length < 6) {
        console.error(`Unexpected key structure — skipping: ${sourceKey}`);
        continue;
      }

      const [envPath, carrierId, partnerId, transferTypeId, frequency, filename] = parts;

      if (!VALID_FREQUENCIES.includes(frequency)) {
        console.error(`Invalid frequency '${frequency}' in key — skipping: ${sourceKey}`);
        continue;
      }

      // Split filename into basename and extension
      const lastDot  = filename.lastIndexOf(".");
      const basename = lastDot > -1 ? filename.slice(0, lastDot) : filename;
      const ext      = lastDot > -1 ? filename.slice(lastDot) : "";

      // Datetime suffix — UTC
      const datetime = format(new Date(), "yyyyMMdd-HHmmss");

      // Construct archive key — frequency moved to second level
      const archiveKey = `${envPath}/${frequency}/${carrierId}/${partnerId}/${transferTypeId}/${basename}_${datetime}${ext}`;

      await s3.send(new CopyObjectCommand({
        CopySource:        `${sourceBucket}/${sourceKey}`,
        Bucket:            ARCHIVE_BUCKET,
        Key:               archiveKey,
        ServerSideEncryption: "aws:kms",
      }));

      console.log(`Archived: ${sourceKey} → ${archiveKey}`);
    } catch (err) {
      console.error(`Failed to archive ${sourceKey}:`, err);
    }
  }
};
```

---

## Unit Tests (`src/test/index.spec.ts`)

Cover the following cases:

- Valid key with extension — correct archive key constructed, correct datetime suffix
- Valid key without extension — correct archive key constructed
- Key with fewer than 6 parts — error logged, S3 copy not called
- Invalid frequency value — error logged, S3 copy not called
- Each valid frequency value — routes to correct archive prefix
- S3 copy failure — error logged, processing continues for remaining records
- Multiple records in single event — each processed independently

Mock `@aws-sdk/client-s3` — do not make real AWS calls in unit tests.

---

## Build Script (`package.json`)

Add the following scripts alongside existing ones:

```json
"build:lambda:archive": "node -e \"require('fs').mkdirSync('.build/lambda/archive',{recursive:true})\" && esbuild src/main/index.ts --bundle --platform=node --target=node20 --format=cjs --outfile=.build/lambda/archive/index.js",
"tf:plan": "npm run build:lambda:archive && tf plan",
"tf:apply": "npm run build:lambda:archive && tf apply"
```

---

## `.tfwconfig.yml` Variables

The following environment variables are expected in `.env` and referenced in `.tfwconfig.yml`:

```
AWS_REGION
AWS_ACCOUNT_ID
GITHUB_REPOSITORY
GIT_COMMIT_SHA
PRIMARY_BUCKET_NAME
ARCHIVE_BUCKET_NAME
PRIMARY_KMS_KEY_ALIAS
LAMBDA_FUNCTION_NAME
LAMBDA_EXECUTION_ROLE_NAME
LAMBDA_LOG_GROUP_NAME
VPC_ID
SUBNET_IDS           # JSON array string, e.g. ["subnet-aaa","subnet-bbb"]
SECURITY_GROUP_IDS   # JSON array string, e.g. ["sg-ccc"]
TAGS                 # JSON object string, e.g. {"Project":"mft-archive","ManagedBy":"terraform"}
```

---

## Assumptions and Constraints

1. The primary MFT bucket already exists — this project references it via data source, does not manage it
2. The DynamoDB users table already exists — referenced via data source, not managed here
3. The KMS key already exists — referenced via alias data source, not managed here
4. The archive bucket is single-region — no CRR required
5. The shared MFT security group is provisioned externally — passed as input
6. S3 Gateway endpoints for S3 and DynamoDB already exist in the VPC — no new endpoints needed
7. `date-fns` is the datetime library — add to `package.json` dependencies
8. Lambda runtime is `nodejs20.x`
9. All resource names are provided explicitly — no derived naming, no prefix variable
10. The `terraform/modules/` directory generated by Terraflow scaffolding should be deleted
