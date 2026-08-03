variable "git_repository" {
  description = "Git repository name (e.g., org/repo)"
  type        = string
}

variable "git_commit_sha" {
  description = "Git commit SHA that deployed this infrastructure"
  type        = string
}

