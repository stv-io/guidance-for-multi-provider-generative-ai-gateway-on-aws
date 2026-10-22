# Only lookup the Route53 zone if use_route53 is true. Behind CloudFront the record points at the
# distribution, so it goes in the public zone even when the ALB itself is internal.
data "aws_route53_zone" "this" {
  count        = var.use_route53 ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = !var.public_load_balancer && !var.use_cloudfront
}

# Only create Route53 records if use_route53 is true
resource "aws_route53_record" "alb_alias" {
  count   = var.use_route53 ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.record_name
  type    = "A"

  alias {
    # If CloudFront is enabled, point to CloudFront, otherwise point to ALB
    name                   = var.use_cloudfront ? aws_cloudfront_distribution.this[0].domain_name : aws_lb.this.dns_name
    zone_id                = var.use_cloudfront ? aws_cloudfront_distribution.this[0].hosted_zone_id : aws_lb.this.zone_id
    # Route 53 rejects target health evaluation for CloudFront alias targets
    evaluate_target_health = !var.use_cloudfront
  }

  depends_on = [aws_cloudfront_distribution.this]
}

# The distribution has IPv6 enabled; without an AAAA record IPv6 clients only get the A record
resource "aws_route53_record" "cloudfront_ipv6" {
  count   = var.use_route53 && var.use_cloudfront ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.record_name
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.this[0].domain_name
    zone_id                = aws_cloudfront_distribution.this[0].hosted_zone_id
    evaluate_target_health = false
  }
}
