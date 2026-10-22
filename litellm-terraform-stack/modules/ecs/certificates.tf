###############################################################################
# ACM certificates for the custom domain
###############################################################################
# With use_route53 and a record/zone name, but no certificate_arn, the stack requests its own
# DNS-validated certificates for RECORD_NAME.HOSTED_ZONE_NAME:
#   - one in the stack region, for the ALB (also used on the CloudFront -> ALB hop)
#   - one in us-east-1, for CloudFront
# ACM gives the same validation CNAME for the same name in every region of an account, so one set
# of records validates both.
locals {
  custom_domain       = var.use_route53 && var.record_name != "" && var.hosted_zone_name != ""
  fqdn                = local.custom_domain ? "${var.record_name}.${var.hosted_zone_name}" : ""
  create_certificates = local.custom_domain && var.certificate_arn == ""

  alb_certificate_arn = (
    var.certificate_arn != "" ? var.certificate_arn :
    local.create_certificates ? aws_acm_certificate_validation.alb[0].certificate_arn :
    aws_acm_certificate.self_signed[0].arn
  )
  # CloudFront only accepts us-east-1 certificates; certificate_arn is the regional ALB certificate,
  # so falling back to it only works for a stack in us-east-1
  cloudfront_certificate_arn = (
    var.cloudfront_certificate_arn != "" ? var.cloudfront_certificate_arn :
    local.create_certificates && var.use_cloudfront ? aws_acm_certificate_validation.cloudfront[0].certificate_arn :
    var.certificate_arn
  )
}

resource "aws_acm_certificate" "alb" {
  count             = local.create_certificates ? 1 : 0
  domain_name       = local.fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "cloudfront" {
  provider          = aws.us_east_1
  count             = local.create_certificates && var.use_cloudfront ? 1 : 0
  domain_name       = local.fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = local.create_certificates ? {
    for o in aws_acm_certificate.alb[0].domain_validation_options : o.domain_name => o
  } : {}

  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "alb" {
  count                   = local.create_certificates ? 1 : 0
  certificate_arn         = aws_acm_certificate.alb[0].arn
  validation_record_fqdns = [for r in aws_route53_record.certificate_validation : r.fqdn]
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider                = aws.us_east_1
  count                   = local.create_certificates && var.use_cloudfront ? 1 : 0
  certificate_arn         = aws_acm_certificate.cloudfront[0].arn
  validation_record_fqdns = [for r in aws_route53_record.certificate_validation : r.fqdn]
}
