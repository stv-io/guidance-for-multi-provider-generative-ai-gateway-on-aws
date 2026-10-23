###############################################################################
# (8) Application Load Balancer, Listener, Target Groups
###############################################################################
locals {
  # With a CloudFront VPC origin the ALB is internal and only CloudFront can reach it
  use_vpc_origin = var.use_cloudfront && var.cloudfront_vpc_origin
  alb_internal   = local.use_vpc_origin || !var.public_load_balancer

  # CloudFront -> ALB is HTTPS when the ALB holds a certificate for the custom domain. CloudFront
  # forwards the Host header, so TLS is negotiated for that name and needs no DNS record for the ALB.
  origin_https = local.use_vpc_origin && local.custom_domain

  # The listener requests arrive on: CloudFront's origin protocol, or HTTPS for direct clients
  entry_listener_arn = var.use_cloudfront && !local.origin_https ? aws_lb_listener.http.arn : aws_lb_listener.https.arn

  cloudfront_secret = var.use_cloudfront ? "litellm-cf-${random_password.cloudfront_secret[0].result}" : ""

  # Paths served by the middleware (:3000). Everything else, including the Bedrock pass-through
  # under /bedrock/model/*, goes to LiteLLM (:4000).
  middleware_routes = {
    chat_history         = { priority = 20, path = "/chat-history" }
    bedrock_chat_history = { priority = 21, path = "/bedrock/chat-history" }
    bedrock_liveliness   = { priority = 22, path = "/bedrock/health/liveliness" }
    session_ids          = { priority = 23, path = "/session-ids" }
    key_generate         = { priority = 24, path = "/key/generate" }
    user_new             = { priority = 25, path = "/user/new" }
    chat_completions     = { priority = 26, path = "/chat/completions" }
    openai_completions   = { priority = 27, path = "/v1/chat/completions" }
  }
}

# ALB
resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  subnets            = local.alb_internal ? var.private_subnets : var.public_subnets
  # You need to supply a security group for the ALB itself:
  security_groups    = [aws_security_group.alb_sg.id]
  internal           = local.alb_internal
  # Long non-streaming completions can exceed 60 s between bytes
  idle_timeout       = 120
  drop_invalid_header_fields = true
  access_logs {
    bucket  = aws_s3_bucket.access_log_bucket.bucket
    prefix  = "alb-access-logs-"
    enabled = true
   }
}

# HTTP listener: CloudFront's origin listener while the hop is HTTP. With an HTTPS origin it only
# answers 403; without CloudFront it redirects clients to HTTPS.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = var.use_cloudfront ? [1] : []
    content {
      type = "fixed-response"
      fixed_response {
        content_type = "application/json"
        message_body = "{\"error\": \"Access denied. Direct access to this endpoint is not allowed.\"}"
        status_code  = "403"
      }
    }
  }

  dynamic "default_action" {
    for_each = var.use_cloudfront ? [] : [1]
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

# HTTPS listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
  certificate_arn   = local.alb_certificate_arn

  # Behind CloudFront only requests carrying the secret header are forwarded (rules below)
  dynamic "default_action" {
    for_each = var.use_cloudfront ? [1] : []
    content {
      type = "fixed-response"
      fixed_response {
        content_type = "application/json"
        message_body = "{\"error\": \"Access denied. Direct access to this endpoint is not allowed.\"}"
        status_code  = "403"
      }
    }
  }

  dynamic "default_action" {
    for_each = var.use_cloudfront ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.tg_4000.arn
    }
  }
}

# Self-signed certificate for the HTTPS listener when there is neither a certificate_arn nor a
# custom domain to request one for
resource "tls_private_key" "self_signed" {
  count     = var.certificate_arn == "" && !local.create_certificates ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self_signed" {
  count           = var.certificate_arn == "" && !local.create_certificates ? 1 : 0
  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    common_name  = "litellm-gateway.local"
    organization = "LiteLLM Gateway"
  }

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "self_signed" {
  count            = var.certificate_arn == "" && !local.create_certificates ? 1 : 0
  private_key      = tls_private_key.self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed[0].cert_pem

  lifecycle {
    create_before_destroy = true
  }
}

# Target Group for port 4000 (LiteLLMContainer)
resource "aws_lb_target_group" "tg_4000" {
  name        = "${var.name}-4000"
  port        = 4000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health/liveliness"
    port                = "4000"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
  }
}

# Target Group for port 3000 (MiddlewareContainer)
resource "aws_lb_target_group" "tg_3000" {
  name        = "${var.name}-3000"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/bedrock/health/liveliness"
    port                = "3000"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
  }
}

###############################################################################
# (9) Listener rules
###############################################################################
# Middleware paths. Behind CloudFront they also require the secret header; the VPC origin and the
# ALB security group already keep everyone but CloudFront out, so the header is a second layer.
resource "aws_lb_listener_rule" "middleware" {
  for_each     = local.middleware_routes
  listener_arn = local.entry_listener_arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_3000.arn
  }

  condition {
    path_pattern {
      values = [each.value.path]
    }
  }

  dynamic "condition" {
    for_each = var.use_cloudfront ? [1] : []
    content {
      http_header {
        http_header_name = "X-CloudFront-Secret"
        values           = [local.cloudfront_secret]
      }
    }
  }
}

# Behind CloudFront: everything else carrying the secret header goes to LiteLLM; the listener's
# default action rejects the rest. Without CloudFront the HTTPS default action forwards to LiteLLM.
resource "aws_lb_listener_rule" "cloudfront_to_litellm" {
  count        = var.use_cloudfront ? 1 : 0
  listener_arn = local.entry_listener_arn
  priority     = 90

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_4000.arn
  }

  condition {
    http_header {
      http_header_name = "X-CloudFront-Secret"
      values           = [local.cloudfront_secret]
    }
  }
}

###############################################################################
# (11) Application Auto Scaling (CPU & Memory)
###############################################################################
resource "aws_appautoscaling_target" "ecs_service_target" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.litellm_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu_policy" {
  name               = "${var.name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service_target.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_utilization_percent
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }
}

# Memory hardly follows load (LiteLLM idles at ~45% of a 2 GB task), and target
# tracking assumes it does: at 2 tasks × 45% it computes that 1 task would sit at
# ~90% and never scales in. 0 disables the policy so CPU alone drives scaling.
resource "aws_appautoscaling_policy" "memory_policy" {
  count              = var.memory_target_utilization_percent > 0 ? 1 : 0
  name               = "${var.name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service_target.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.memory_target_utilization_percent
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }
}

moved {
  from = aws_appautoscaling_policy.memory_policy
  to   = aws_appautoscaling_policy.memory_policy[0]
}
