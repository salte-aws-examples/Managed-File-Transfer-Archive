variable "archive_bucket_name" {
  description = "Name of the archive S3 bucket to be provisioned"
  type        = string
}

variable "lambda_execution_role_name" {
  description = "Name of the IAM execution role for the archive Lambda"
  type        = string
}

variable "lambda_function_name" {
  description = "Name of the archive Lambda function"
  type        = string
}

variable "lambda_log_group_name" {
  description = "Name of the CloudWatch log group for the archive Lambda"
  type        = string
}

variable "primary_bucket_name" {
  description = "Name of the primary MFT Transfer Family S3 bucket — source of S3 events"
  type        = string
}

variable "primary_kms_key_alias" {
  description = "KMS key alias used for the primary MFT bucket — used for both Lambda decrypt and archive bucket encryption. e.g. alias/mft-default"
  type        = string
}

variable "security_group_ids" {
  description = "Security group IDs for Lambda VPC config — shared MFT workload security group"
  type        = list(string)
}

variable "subnet_ids" {
  description = "Private subnet IDs for Lambda VPC config"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID for Lambda network placement"
  type        = string
}
