variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "db_name" {
  type    = string
  default = "desafio4_db"
}

variable "db_user" {
  type    = string
  default = "mateus"
}

variable "db_pass" {
  type      = string
  sensitive = true
}

