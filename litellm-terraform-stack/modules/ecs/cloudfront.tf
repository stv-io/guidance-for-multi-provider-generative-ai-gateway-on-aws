# Generate a random secret for CloudFront-to-ALB authentication
# This secret is used for secure origin authentication between CloudFront and ALB
resource "random_password" "cloudfront_secret" {
  count   = var.use_cloudfront ? 1 : 0
  length  = 32
  special = false

  # Add keepers to prevent regeneration unless explicitly changed
  keepers = {
    name = var.name  # Only regenerate if the name changes
  }

  # Prevent updates to the secret's properties during regular deployments
  lifecycle {
    ignore_changes = [length, special, min_lower, min_upper, min_numeric]
  }
}

# VPC origin: CloudFront reaches the internal ALB through ENIs in the private subnets, so the
# CloudFront -> ALB hop stays on the AWS network instead of crossing the internet. With a custom
# domain the hop is also TLS (local.origin_https).
# CloudFront refuses to update a VPC origin that a distribution uses (CannotUpdateEntityWhileInUse),
# so the origin is keyed by its protocol: switching protocol creates the new origin, moves the
# distribution to it, and only then deletes the old one.
locals {
  vpc_origin_protocol = local.origin_https ? "https-only" : "http-only"
}

resource "aws_cloudfront_vpc_origin" "alb" {
  for_each = local.use_vpc_origin ? toset([local.vpc_origin_protocol]) : toset([])

  vpc_origin_endpoint_config {
    name                   = each.key == "http-only" ? "${var.name}-alb" : "${var.name}-alb-${each.key}"
    arn                    = aws_lb.this.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = each.key

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

moved {
  from = aws_cloudfront_vpc_origin.alb[0]
  to   = aws_cloudfront_vpc_origin.alb["http-only"]
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "this" {
  count               = var.use_cloudfront ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name}-distribution"
  default_root_object = ""
  price_class         = var.cloudfront_price_class
  web_acl_id          = var.cloudfront_waf ? aws_wafv2_web_acl.cloudfront[0].arn : null

  origin {
    # A VPC origin is addressed by its ARN; the domain name only sets the TLS server name, so with
    # an HTTPS origin it is the custom domain the ALB certificate covers
    domain_name = local.origin_https ? local.fqdn : aws_lb.this.dns_name
    origin_id   = "ALB"

    # Second layer behind the VPC origin and the ALB security group: the ALB only forwards
    # requests that carry this header
    custom_header {
      name  = "X-CloudFront-Secret"
      value = local.cloudfront_secret
    }

    # cloudfront_vpc_origin = false (upstream design): the ALB is public and the CloudFront -> ALB
    # hop is plain HTTP over the internet, guarded only by the secret header.
    dynamic "custom_origin_config" {
      for_each = local.use_vpc_origin ? [] : [1]
      content {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = ["TLSv1.2"]
        origin_read_timeout    = 60
      }
    }

    dynamic "vpc_origin_config" {
      for_each = local.use_vpc_origin ? [1] : []
      content {
        vpc_origin_id       = aws_cloudfront_vpc_origin.alb[local.vpc_origin_protocol].id
        origin_read_timeout = 60
      }
    }
  }

  # Default cache behavior for API requests
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "ALB"

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Host", "Origin"]

      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
    compress               = true
  }

  # Custom domain certificate (us-east-1), or the default *.cloudfront.net one
  dynamic "viewer_certificate" {
    for_each = local.custom_domain && local.cloudfront_certificate_arn != "" ? [1] : []
    content {
      acm_certificate_arn      = local.cloudfront_certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }

  dynamic "viewer_certificate" {
    for_each = local.custom_domain && local.cloudfront_certificate_arn != "" ? [] : [1]
    content {
      cloudfront_default_certificate = true
    }
  }

  aliases = local.custom_domain ? [local.fqdn] : []

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Enable logging to the ALB access logs bucket - commented out to avoid S3 ACL issues
  # logging_config {
  #   include_cookies = false
  #   bucket          = aws_s3_bucket.access_log_bucket.bucket_domain_name
  #   prefix          = "cloudfront-logs/"
  # }

  tags = {
    Name = "${var.name}-cloudfront-distribution"
  }

  depends_on = [aws_lb.this]
}
