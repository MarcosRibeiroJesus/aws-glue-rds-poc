variable "aws_region" {
  description = "AWS region to deploy the PoC resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for all resources created by this PoC"
  type        = string
  default     = "glue-rds-poc"
}

variable "db_name" {
  description = "Initial PostgreSQL database name"
  type        = string
  default     = "pocdb"
}

variable "db_username" {
  description = "Master username for the RDS PostgreSQL instance"
  type        = string
  default     = "postgres_admin"
}

variable "db_password" {
  description = "Master password for the RDS PostgreSQL instance (if empty, a random password is generated)"
  type        = string
  default     = "123456"
  sensitive   = true
}

variable "force_workflow_trigger_token" {
  description = "Optional token (e.g. git commit SHA) to re-upload the Glue script and fire the EventBridge -> Glue Workflow trigger on every deployment"
  type        = string
  default     = "initial"
}
