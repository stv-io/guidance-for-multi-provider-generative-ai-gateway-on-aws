###############################################################################
# (10) WAF
###############################################################################
# Behind CloudFront the web ACL sits at the edge (CLOUDFRONT scope, us-east-1), so bad requests
# are dropped before they reach the VPC. The regional ACL on the ALB (modules/base/waf.tf) is
# only created when the edge ACL does not already cover all traffic.
resource "aws_wafv2_web_acl_association" "litellm_waf" {
  count        = var.regional_waf ? 1 : 0
  resource_arn = aws_lb.this.arn
  web_acl_arn  = var.wafv2_acl_arn
}

resource "aws_wafv2_web_acl" "cloudfront" {
  provider    = aws.us_east_1
  count       = var.cloudfront_waf ? 1 : 0
  name        = "${var.name}-cloudfront"
  description = "Edge WAF for the LiteLLM gateway"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-cloudfront"
    sampled_requests_enabled   = true
  }

  # Same exclusions as the regional ACL: API clients often send no User-Agent, and prompts are
  # routinely larger than the rule set's 8 KB body limit
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        rule_action_override {
          name = "NoUserAgent_HEADER"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # Per-IP request rate over 5 minutes. Per-key limits are LiteLLM's job (rpm/tpm on the key);
  # this only stops a single address from flooding the gateway.
  rule {
    name     = "RateLimitPerIP"
    priority = 4

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.cloudfront_waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }
}

moved {
  from = aws_wafv2_web_acl_association.litellm_waf
  to   = aws_wafv2_web_acl_association.litellm_waf[0]
}
