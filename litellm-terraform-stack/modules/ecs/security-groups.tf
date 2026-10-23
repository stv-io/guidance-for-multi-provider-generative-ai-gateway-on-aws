###############################################################################
# (7) Security Groups & Ingress for Redis and RDS
###############################################################################

# CloudFront security is implemented using origin custom headers instead of IP ranges
# This avoids hitting AWS security group rule limits (60 rules per security group)
# CloudFront has hundreds of IP ranges globally, which would exceed the limit
# Security group for ECS Service tasks
resource "aws_security_group" "ecs_service_sg" {
  name        = "${var.name}-service-sg"
  description = "Security group for ECS Fargate service"
  vpc_id      = var.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"  # "-1" represents all protocols
    cidr_blocks      = ["0.0.0.0/0"]
    description      = "Allow all outbound traffic by default"
  }
}

resource "aws_security_group_rule" "alb_ingress_4000" {
  type                     = "ingress"
  from_port                = 4000
  to_port                  = 4000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_service_sg.id
  source_security_group_id = aws_security_group.alb_sg.id
  description              = "Allow Load Balancer to ECS"
}

resource "aws_security_group_rule" "alb_ingress_3000" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_service_sg.id
  source_security_group_id = aws_security_group.alb_sg.id
  description              = "Allow Load Balancer to ECS"
}


# Allow ECS tasks to connect to Redis
resource "aws_security_group_rule" "redis_ingress" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = var.redis_security_group_id
  source_security_group_id = aws_security_group.ecs_service_sg.id
  description              = "Allow ECS tasks to connect to Redis"
}

# Allow ECS tasks to connect to RDS
resource "aws_security_group_rule" "db_ingress" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = var.db_security_group_id
  source_security_group_id = aws_security_group.ecs_service_sg.id
  description              = "Allow ECS tasks to connect to RDS"
}

data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb_sg" {
  name        = "${var.name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = var.vpc_id

  # Public load balancer: Allow HTTPS traffic with WAF protection
  # Security is provided by:
  # 1. When CloudFront is enabled: Custom origin header authentication via ALB listener rules
  # 2. When CloudFront is disabled: WAF rules on the ALB
  # 3. When private: Only accessible from private subnets
  dynamic "ingress" {
    for_each = local.use_vpc_origin ? [] : [443, 80]
    content {
      description = ingress.value == 443 ? "HTTPS traffic" : "HTTP traffic for CloudFront origin (custom header authentication)"
      protocol    = "tcp"
      from_port   = ingress.value
      to_port     = ingress.value
      cidr_blocks = var.public_load_balancer ? ["0.0.0.0/0"] : var.private_subnets_cidr_blocks
    }
  }

  # VPC origin: only CloudFront origin-facing addresses. One 80-443 rule because the managed
  # prefix list counts as ~55 entries against the 60-rule security group quota.
  dynamic "ingress" {
    for_each = local.use_vpc_origin ? [1] : []
    content {
      description     = "CloudFront VPC origin (HTTP 80 / HTTPS 443)"
      protocol        = "tcp"
      from_port       = 80
      to_port         = 443
      prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id]
    }
  }

  tags = {
    Name = "${var.name}-alb-sg"
    SecurityModel = local.use_vpc_origin ? "CloudFront-VPC-Origin" : var.use_cloudfront ? "CloudFront-Protected" : (var.public_load_balancer ? "Public-WAF-Protected" : "Private-VPC-Only")
  }

  # Allow all outbound
  egress {
    description = "Allow all outbound"
    protocol    = -1
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
