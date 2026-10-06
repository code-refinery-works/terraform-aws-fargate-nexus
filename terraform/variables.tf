variable "aws_region"             { default = "ap-northeast-1" }
variable "env"                    { description = "prod / stg / dev" }
variable "project"                { description = "Project identifier" }
variable "vpc_cidr"               { default = "10.0.0.0/16" }
variable "public_subnet_cidrs"    { type = list(string); default = ["10.0.0.0/24", "10.0.1.0/24"] }
variable "private_subnet_cidrs"   { type = list(string); default = ["10.0.10.0/24", "10.0.11.0/24"] }
variable "isolated_subnet_cidrs"  { type = list(string); default = ["10.0.20.0/24", "10.0.21.0/24"] }
variable "single_nat_gw"          { type = bool; default = false; description = "true=dev(cost saving), false=prod(HA)" }
variable "acm_certificate_arn"    { description = "ACM cert ARN for ALB (ap-northeast-1)" }
variable "cf_acm_certificate_arn" { description = "ACM cert ARN for CloudFront (us-east-1)" }
variable "domain_name"            { description = "FQDN e.g. api.example.com" }
variable "container_port"         { type = number; default = 8080 }
variable "task_cpu"               { default = "512" }
variable "task_memory"            { default = "1024" }
variable "desired_count"          { type = number; default = 2 }
variable "max_count"              { type = number; default = 10 }
variable "aurora_max_acu"         { type = number; default = 16 }
variable "db_name"                { default = "apidb" }