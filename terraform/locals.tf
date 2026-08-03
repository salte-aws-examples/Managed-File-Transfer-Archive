locals {
  # Project name for resource naming
  project_name = "Managed-File-Transfer-Archive"
  
  # Sanitized names for GCP resources (lowercase, hyphens replaced with dashes)
  # GCP requires lowercase alphanumeric with dashes for many resource names
  sanitized_project_name = lower(replace("Managed-File-Transfer-Archive", "_", "-"))
  sanitized_workspace    = lower(replace(terraform.workspace, "_", "-"))
  
  # Common tags/labels for all resources
  common_tags = {
    Workspace   = terraform.workspace
    ManagedBy   = "terraform"
    Repository  = var.git_repository
    CommitHash  = var.git_commit_sha
  }
}

