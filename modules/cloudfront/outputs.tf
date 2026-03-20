output "cloudfront_domain" {
  value = aws_cloudfront_distribution.main.domain_name
}

output "s3_bucket" {
  value = data.aws_s3_bucket.frontend.bucket
}
