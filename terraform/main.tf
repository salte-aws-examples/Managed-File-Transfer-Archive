# Lambda function
resource "aws_lambda_function" "main" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${local.project_name}-${terraform.workspace}-lambda"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime         = "nodejs20.x"

  tags = local.common_tags
}

# IAM execution role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${local.project_name}-${terraform.workspace}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# IAM policy for CloudWatch Logs
resource "aws_iam_role_policy" "lambda_logs" {
  name = "${local.project_name}-${terraform.workspace}-lambda-logs"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.project_name}-${terraform.workspace}-lambda"
  retention_in_days  = 7

  tags = local.common_tags
}

# Archive Lambda function code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../src/main"
  output_path = "${path.module}/lambda_function.zip"
  excludes    = ["node_modules", ".git"]
}

