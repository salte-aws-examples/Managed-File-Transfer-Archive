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
