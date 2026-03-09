variable "project_name" {
  type = string
}

variable "environment" {
  type        = string
  description = "O ambiente que será usado"
  default     = "dev"
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "db_pass" {
  type      = string
  sensitive = true
}
