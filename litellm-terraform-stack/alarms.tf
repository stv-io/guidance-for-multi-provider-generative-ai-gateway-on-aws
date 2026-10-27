###############################################################################
# Spend alarms (created when alarm_email is set)
###############################################################################
# Two signals, because they fail differently:
#   - an AWS Budgets budget on Bedrock cost: in dollars, but Cost Explorer data lags by hours
#   - a CloudWatch alarm on Bedrock tokens per hour: near real time, catches a runaway client
#     or loop within the hour, but counts tokens, not dollars
# Both are account- and region-wide: they include Bedrock use that does not go through the gateway.
locals {
  spend_alarms = var.alarm_email != ""
}

# Anthropic models on Bedrock bill as their own Marketplace service ("Claude ... (Amazon Bedrock
# Edition)"), not as "Amazon Bedrock", so the filter lists them. Smoke test X1 fails when Cost
# Explorer shows a Bedrock-billed service that is missing here.
resource "aws_budgets_budget" "bedrock" {
  count        = local.spend_alarms ? 1 : 0
  name         = "${var.name}-bedrock-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.bedrock_monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = var.bedrock_budget_services
  }

  # Credits would hide the spend: on a credit-funded account the net cost stays at zero
  cost_types {
    include_credit = false
    include_refund = false
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = "ACTUAL"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = [var.alarm_email]
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "FORECASTED"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.alarm_email]
  }
}

resource "aws_sns_topic" "alarms" {
  count = local.spend_alarms ? 1 : 0
  name  = "${var.name}-alarms"
}

# SNS sends a confirmation email first; alarms are only delivered after the link in it is clicked
resource "aws_sns_topic_subscription" "alarm_email" {
  count     = local.spend_alarms ? 1 : 0
  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "bedrock_tokens" {
  count               = local.spend_alarms ? 1 : 0
  alarm_name          = "${var.name}-bedrock-tokens-per-hour"
  alarm_description   = "Bedrock input + output tokens in ${data.aws_region.current.region} over ${var.bedrock_tokens_per_hour_alarm} in one hour (all callers, not only the gateway)"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.bedrock_tokens_per_hour_alarm
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms[0].arn]
  ok_actions          = [aws_sns_topic.alarms[0].arn]

  metric_query {
    id          = "tokens"
    expression  = "input + output"
    label       = "Bedrock tokens per hour"
    return_data = true
  }

  # Without a ModelId dimension these are the totals across all models
  metric_query {
    id = "input"
    metric {
      namespace   = "AWS/Bedrock"
      metric_name = "InputTokenCount"
      period      = 3600
      stat        = "Sum"
    }
  }

  metric_query {
    id = "output"
    metric {
      namespace   = "AWS/Bedrock"
      metric_name = "OutputTokenCount"
      period      = 3600
      stat        = "Sum"
    }
  }
}

###############################################################################
# Health alarms (created when health_alarms is true)
###############################################################################
# They notify only when health_alarm_notifications is true and alarm_email is set (same SNS topic
# as the token alarm, also on return to OK). Otherwise they only change state in the CloudWatch
# console, and test X3 checks them there.
# Container Insights is off (cost), so "no task serving" is detected at the ALB: a target group
# with no healthy target means every task is down or failing its health check.
locals {
  health_alarms = var.health_alarms
  health_actions = local.spend_alarms && var.health_alarm_notifications ? [aws_sns_topic.alarms[0].arn] : []

  target_groups = module.ecs_cluster.target_group_arn_suffixes

  # Node IDs follow the replication group ID: <id>-001, <id>-002, ...
  redis_nodes = [
    for i in range(1, var.redis_num_cache_clusters + 1) :
    format("%s-%03d", module.base.redis_replication_group_id, i)
  ]
}

# Errors the ALB itself returns (no healthy target, timeouts) and errors the tasks return
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  for_each            = local.health_alarms ? { elb = "HTTPCode_ELB_5XX_Count", target = "HTTPCode_Target_5XX_Count" } : {}
  alarm_name          = "${var.name}-alb-${each.key}-5xx"
  alarm_description   = "${each.value} above ${var.alb_5xx_alarm_count} in 5 minutes, twice in a row"
  namespace           = "AWS/ApplicationELB"
  metric_name         = each.value
  dimensions          = { LoadBalancer = module.ecs_cluster.alb_arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alb_5xx_alarm_count
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.health_actions
  ok_actions          = local.health_actions
}

resource "aws_cloudwatch_metric_alarm" "no_healthy_targets" {
  for_each            = local.health_alarms ? local.target_groups : {}
  alarm_name          = "${var.name}-${each.key}-no-healthy-targets"
  alarm_description   = "No healthy ${each.key} target behind the ALB for 3 minutes: the gateway is down"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = module.ecs_cluster.alb_arn_suffix, TargetGroup = each.value }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  # No data points means no target reported at all
  treat_missing_data = "breaching"
  alarm_actions      = local.health_actions
  ok_actions         = local.health_actions
}

# A task that keeps failing its health check while another one still serves
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each            = local.health_alarms ? local.target_groups : {}
  alarm_name          = "${var.name}-${each.key}-unhealthy-targets"
  alarm_description   = "At least one unhealthy ${each.key} target for 10 minutes (longer than a deployment or the 300 s grace period)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = module.ecs_cluster.alb_arn_suffix, TargetGroup = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 10
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.health_actions
  ok_actions          = local.health_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count               = local.health_alarms ? 1 : 0
  alarm_name          = "${var.name}-rds-cpu"
  alarm_description   = "RDS CPU above 80% for 15 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = module.base.rds_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.health_actions
  ok_actions          = local.health_actions
}

# LiteLLM writes a spend log row per request, so storage only grows
resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  count               = local.health_alarms ? 1 : 0
  alarm_name          = "${var.name}-rds-free-storage"
  alarm_description   = "RDS free storage below 10% of the ${var.rds_allocated_storage} GiB allocated"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = module.base.rds_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.rds_allocated_storage * 1073741824 * 0.1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.health_actions
  ok_actions          = local.health_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  count               = local.health_alarms ? 1 : 0
  alarm_name          = "${var.name}-rds-connections"
  alarm_description   = "RDS connections above ${var.rds_connections_alarm} for 10 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = module.base.rds_identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.rds_connections_alarm
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.health_actions
  ok_actions          = local.health_actions
}

# Valkey holds the rate-limit counters and the response cache; when it is full, volatile-lru
# evicts cached responses first, so high memory is a warning, not an outage
resource "aws_cloudwatch_metric_alarm" "valkey_memory" {
  for_each            = local.health_alarms ? toset(local.redis_nodes) : toset([])
  alarm_name          = "${each.key}-memory"
  alarm_description   = "Valkey node ${each.key} memory above 80% for 15 minutes"
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  dimensions          = { CacheClusterId = each.key }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.health_actions
  ok_actions          = local.health_actions
}
