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
