variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "frontend_image" {
  type = string
}

variable "backend_image" {
  type = string
}

variable "grafana_image" {
  type = string
}

variable "prometheus_image" {
  type = string
}

variable "configs_bucket" {
  type = string
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}

variable "db_endpoint" {
  type      = string
  sensitive = true
}

variable "db_host" {
  type      = string
  sensitive = true
}

variable "db_name" {
  type = string
}

variable "db_pass" {
  type      = string
  sensitive = true
}

variable "certificate_arn" {
  type = string
}

variable "subdomain" {
  type    = string
  default = "mpdesafio4.ezopscloud.co"
}
