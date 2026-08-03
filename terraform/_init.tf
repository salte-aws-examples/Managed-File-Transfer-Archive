terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
  
  # Uncomment when ready for remote state. Configure in .tfwconfig.yml
  # backend "s3" {
  #   # Backend configuration provided via:
  #   # - terraflow CLI flags
  #   # - environment variables (TERRAFLOW_*)
  #   # - .tfwconfig.yml
  #   # Do not hardcode values here
  # }
}

provider "aws" {
  # Region automatically read from AWS_REGION environment variable
}

