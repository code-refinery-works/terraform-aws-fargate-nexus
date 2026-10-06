terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
  backend "s3" {
    bucket         = "tfstate-ecs-fargate-api"
    key            = "app/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "tfstate-lock"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = { Environment = var.env, Project = var.project, ManagedBy = "Terraform" } }
}

# ── VPC ──────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_internet_gateway" "main" { vpc_id = aws_vpc.main.id }

locals {
  azs             = ["ap-northeast-1a", "ap-northeast-1c"]
  public_cidrs    = var.public_subnet_cidrs
  private_cidrs   = var.private_subnet_cidrs
  isolated_cidrs  = var.isolated_subnet_cidrs
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]
}

resource "aws_subnet" "isolated" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.isolated_cidrs[count.index]
  availability_zone = local.azs[count.index]
}

resource "aws_eip" "nat" { count = var.single_nat_gw ? 1 : 2; domain = "vpc" }

resource "aws_nat_gateway" "main" {
  count         = var.single_nat_gw ? 1 : 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; gateway_id = aws_internet_gateway.main.id }
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = var.single_nat_gw ? 1 : 2
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; nat_gateway_id = aws_nat_gateway.main[var.single_nat_gw ? 0 : count.index].id }
}
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.single_nat_gw ? 0 : count.index].id
}

# ── Security Groups ──────────────────────────────────
resource "aws_security_group" "alb" {
  name   = "${var.project}-${var.env}-alb"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 80;  to_port = 80;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0;   to_port = 0;   protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "ecs" {
  name   = "${var.project}-${var.env}-ecs"
  vpc_id = aws_vpc.main.id
  ingress { from_port = var.container_port; to_port = var.container_port; protocol = "tcp"; security_groups = [aws_security_group.alb.id] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "db" {
  name   = "${var.project}-${var.env}-db"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 5432; to_port = 5432; protocol = "tcp"; security_groups = [aws_security_group.ecs.id] }
}

# ── ECR ──────────────────────────────────────────────
resource "aws_ecr_repository" "api" {
  name                 = "${var.project}-${var.env}-api"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy = jsonencode({ rules = [{ rulePriority = 1; description = "Keep last 30 images"; selection = { tagStatus = "any"; countType = "imageCountMoreThan"; countNumber = 30 }; action = { type = "expire" } }] })
}

# ── Secrets Manager ───────────────────────────────────
resource "random_password" "db" { length = 32; special = false }
resource "random_password" "cf_secret" { length = 32; special = false }

resource "aws_secretsmanager_secret" "db" { name = "/${var.project}/${var.env}/db/password"; recovery_window_in_days = 7 }
resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({ username = "apiuser"; password = random_password.db.result })
}

# ── Aurora Serverless v2 ──────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-${var.env}"
  subnet_ids = aws_subnet.isolated[*].id
}

resource "aws_rds_cluster" "main" {
  cluster_identifier      = "${var.project}-${var.env}"
  engine                  = "aurora-postgresql"
  engine_mode             = "provisioned"
  engine_version          = "15.4"
  database_name           = var.db_name
  master_username         = "apiuser"
  master_password         = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  storage_encrypted       = true
  skip_final_snapshot     = var.env != "prod"
  deletion_protection     = var.env == "prod"
  serverlessv2_scaling_configuration { min_capacity = 0.5; max_capacity = var.aurora_max_acu }
  lifecycle { prevent_destroy = false }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.project}-${var.env}-writer"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version
}

resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.project}-${var.env}-reader"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version
}

# ── IAM ──────────────────────────────────────────────
data "aws_iam_policy_document" "ecs_assume" {
  statement { actions = ["sts:AssumeRole"]; principals { type = "Service"; identifiers = ["ecs-tasks.amazonaws.com"] } }
}

resource "aws_iam_role" "exec" {
  name               = "${var.project}-${var.env}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role_policy" "exec_secrets" {
  role   = aws_iam_role.exec.id
  policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Effect = "Allow"; Action = ["secretsmanager:GetSecretValue"]; Resource = [aws_secretsmanager_secret.db.arn] }] })
}

resource "aws_iam_role" "task" {
  name               = "${var.project}-${var.env}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# ── ECS ──────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project}-${var.env}"
  retention_in_days = 30
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-${var.env}"
  setting { name = "containerInsights"; value = "enabled" }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project}-${var.env}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name  = "api"
    image = "${aws_ecr_repository.api.repository_url}:latest"
    portMappings = [{ containerPort = var.container_port; protocol = "tcp" }]
    secrets = [{ name = "DB_SECRET"; valueFrom = aws_secretsmanager_secret.db.arn }]
    logConfiguration = { logDriver = "awslogs"; options = { "awslogs-group" = aws_cloudwatch_log_group.ecs.name; "awslogs-region" = var.aws_region; "awslogs-stream-prefix" = "api" } }
  }])
}

resource "aws_lb" "main" {
  name               = "${var.project}-${var.env}"
  internal           = false
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "api" {
  name        = "${var.project}-${var.env}-api"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check { path = "/health"; healthy_threshold = 2; unhealthy_threshold = 3 }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn
  default_action { type = "forward"; target_group_arn = aws_lb_target_group.api.arn }
}
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action { type = "redirect"; redirect { port = "443"; protocol = "HTTPS"; status_code = "HTTP_301" } }
}

resource "aws_lb_listener_rule" "cf_header" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 1
  action { type = "forward"; target_group_arn = aws_lb_target_group.api.arn }
  condition { http_header { http_header_name = "X-Origin-Verify"; values = [random_password.cf_secret.result] } }
}

resource "aws_ecs_service" "api" {
  name                               = "${var.project}-${var.env}-api"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }
  load_balancer { target_group_arn = aws_lb_target_group.api.arn; container_name = "api"; container_port = var.container_port }
}

# ── Auto Scaling ──────────────────────────────────────
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_count
  min_capacity       = var.desired_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.project}-${var.env}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
    target_value = 70.0
  }
}

# ── WAF + CloudFront ──────────────────────────────────
resource "aws_wafv2_web_acl" "cf" {
  provider    = aws.us_east_1
  name        = "${var.project}-${var.env}-cf"
  scope       = "CLOUDFRONT"
  default_action { allow {} }
  visibility_config { cloudwatch_metrics_enabled = true; metric_name = "${var.project}-${var.env}"; sampled_requests_enabled = true }
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action { none {} }
    statement { managed_rule_group_statement { name = "AWSManagedRulesCommonRuleSet"; vendor_name = "AWS" } }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "CommonRuleSet"; sampled_requests_enabled = true }
  }
  rule {
    name     = "RateLimit"
    priority = 2
    action { block {} }
    statement { rate_based_statement { limit = 2000; aggregate_key_type = "IP" } }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "RateLimit"; sampled_requests_enabled = true }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags { tags = { Environment = var.env, Project = var.project, ManagedBy = "Terraform" } }
}

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  web_acl_id      = aws_wafv2_web_acl.cf.arn
  aliases         = [var.domain_name]
  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "alb"
    custom_origin_config { http_port = 80; https_port = 443; origin_protocol_policy = "https-only"; origin_ssl_protocols = ["TLSv1.2"] }
    custom_header { name = "X-Origin-Verify"; value = random_password.cf_secret.result }
  }
  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values { query_string = true; headers = ["Authorization", "Host"]; cookies { forward = "none" } }
    min_ttl = 0; default_ttl = 0; max_ttl = 0
  }
  restrictions { geo_restriction { restriction_type = "none" } }
  viewer_certificate { acm_certificate_arn = var.cf_acm_certificate_arn; ssl_support_method = "sni-only"; minimum_protocol_version = "TLSv1.2_2021" }
}