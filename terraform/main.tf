# Primary MFT bucket — referenced for event notification and IAM
data "aws_s3_bucket" "primary" {
  bucket = var.primary_bucket_name
}

# KMS key — single key used for both primary bucket decryption and archive bucket encryption
data "aws_kms_key" "mft" {
  key_id = var.primary_kms_key_alias
}

# DynamoDB users table — referenced for IAM permissions
data "aws_dynamodb_table" "users" {
  name = var.users_table_name
}

# Lambda archive zip
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../.build/lambda/archive"
  output_path = "${path.module}/../.build/lambda/archive.zip"
}

resource "aws_s3_bucket" "archive" {
  bucket = var.archive_bucket_name
}

resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.archive.id
  versioning_configuration {
    status = "Enabled"
  }
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

resource "aws_s3_bucket_notification" "primary" {
  bucket = data.aws_s3_bucket.primary.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.archive.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.s3_invoke]
}

resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invocation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.archive.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = data.aws_s3_bucket.primary.arn
}

resource "aws_cloudwatch_log_group" "archive_lambda" {
  name              = var.lambda_log_group_name
  retention_in_days = 90
}

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
      USERS_TABLE    = var.users_table_name
    }
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  depends_on = [aws_cloudwatch_log_group.archive_lambda]
}

resource "aws_iam_role" "lambda_exec" {
  name = var.lambda_execution_role_name

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
