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
# CloudFront -> ALB hop stays on the AWS network instead of crossing the internet.
resource "aws_cloudfront_vpc_origin" "alb" {
  count = local.use_vpc_origin ? 1 : 0

  vpc_origin_endpoint_config {
    name                   = "${var.name}-alb"
    arn                    = aws_lb.this.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

locals {
  # CloudFront only accepts us-east-1 certificates; certificate_arn is the regional ALB certificate
  cloudfront_certificate_arn = var.cloudfront_certificate_arn != "" ? var.cloudfront_certificate_arn : var.certificate_arn
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "this" {
  count               = var.use_cloudfront ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name}-distribution"
  default_root_object = ""
  price_class         = var.cloudfront_price_class
  
  origin {
    domain_name = aws_lb.this.dns_name
    origin_id   = "ALB"
    
    # Add a custom origin header for security
    # This replaces the IP-based security group approach
    # ALB should be configured to only accept requests with this header
    custom_header {
      name  = "X-CloudFront-Secret"
      value = "litellm-cf-${random_password.cloudfront_secret[0].result}"
    }
    
    # Security note on CloudFront-ALB communication:
    #
    # Default (cloudfront_vpc_origin = true): the ALB is internal and CloudFront reaches it through a
    # VPC origin, so the HTTP hop never leaves the AWS network and the ALB has no public address.
    # The secret header below is kept as a second layer.
    #
    # cloudfront_vpc_origin = false: the ALB is public and the CloudFront -> ALB hop is plain HTTP
    # over the internet. Security then rests on:
    #
    # 1. Custom header authentication (X-CloudFront-Secret) that prevents direct access to the ALB
    # 2. Communication between end users and CloudFront remains encrypted with HTTPS
    # 3. The ALB is configured to reject requests without the secret header
    #
    # This approach eliminates certificate validation issues while maintaining a strong security posture.
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
        vpc_origin_id       = aws_cloudfront_vpc_origin.alb[0].id
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
  
  # Use the provided certificate if Route53 is enabled with a custom domain
  dynamic "viewer_certificate" {
    for_each = var.use_route53 && local.cloudfront_certificate_arn != "" ? [1] : []
    content {
      acm_certificate_arn = local.cloudfront_certificate_arn
      ssl_support_method  = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }
  
  # Use CloudFront default certificate if no Route53 or certificate is provided
  dynamic "viewer_certificate" {
    for_each = !var.use_route53 || local.cloudfront_certificate_arn == "" ? [1] : []
    content {
      cloudfront_default_certificate = true
    }
  }
  
  # Add aliases only if Route53 is used
  aliases = var.use_route53 ? [format("%s.%s", var.record_name, var.hosted_zone_name)] : []
  
  # Associate WAF Web ACL if provided - commented out due to regional WAF scope issue
  # CloudFront requires global WAF WebACLs, but the current WAF is regional
  # web_acl_id = var.wafv2_acl_arn
  
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
