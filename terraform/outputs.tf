output "vpc_id"                  { value = aws_vpc.main.id }
output "alb_dns_name"            { value = aws_lb.main.dns_name }
output "cloudfront_domain_name"  { value = aws_cloudfront_distribution.main.domain_name }
output "ecr_repository_url"      { value = aws_ecr_repository.api.repository_url }
output "ecs_cluster_name"        { value = aws_ecs_cluster.main.name }
output "aurora_cluster_endpoint" { value = aws_rds_cluster.main.endpoint }
output "aurora_reader_endpoint"  { value = aws_rds_cluster.main.reader_endpoint }
output "db_secret_arn"           { value = aws_secretsmanager_secret.db.arn; sensitive = true }
output "cloudfront_origin_secret" {
  description = "Set this value as X-Origin-Verify custom header in CloudFront"
  value       = random_password.cf_secret.result
  sensitive   = true
}