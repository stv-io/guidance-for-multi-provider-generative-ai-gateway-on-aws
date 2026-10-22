variable "name" {
  description = "Standard name to be used as prefix on all resources."
  type        = string
  default     = "genai-gateway"
}

variable "vpc_id" {
  type      = string
  default   = ""
  description = "If set, use this VPC instead of creating a new one. Leave empty to create a new VPC."
}

variable "log_bucket_arn" {
  description = "ARN of the log bucket"
  type        = string
}

variable "litellm_version" {
  description = "Version tag for LiteLLM image"
  type        = string
}

variable "openai_api_key" {
  description = "OpenAI API key"
  type        = string
  sensitive   = true
}

variable "azure_openai_api_key" {
  description = "Azure OpenAI API key"
  type        = string
  sensitive   = true
}

variable "azure_api_key" {
  description = "Azure API key"
  type        = string
  sensitive   = true
}

variable "anthropic_api_key" {
  description = "Anthropic API key"
  type        = string
  sensitive   = true
}

variable "groq_api_key" {
  description = "Groq API key"
  type        = string
  sensitive   = true
}

variable "cohere_api_key" {
  description = "Cohere API key"
  type        = string
  sensitive   = true
}

variable "co_api_key" {
  description = "Co API key"
  type        = string
  sensitive   = true
}

variable "hf_token" {
  description = "HuggingFace token"
  type        = string
  sensitive   = true
}

variable "huggingface_api_key" {
  description = "HuggingFace API key"
  type        = string
  sensitive   = true
}

variable "databricks_api_key" {
  description = "Databricks API key"
  type        = string
  sensitive   = true
}

variable "gemini_api_key" {
  description = "Gemini API key"
  type        = string
  sensitive   = true
}

variable "codestral_api_key" {
  description = "Codestral API key"
  type        = string
  sensitive   = true
}

variable "mistral_api_key" {
  description = "Mistral API key"
  type        = string
  sensitive   = true
}

variable "azure_ai_api_key" {
  description = "Azure AI API key"
  type        = string
  sensitive   = true
}

variable "nvidia_nim_api_key" {
  description = "NVIDIA NIM API key"
  type        = string
  sensitive   = true
}

variable "xai_api_key" {
  description = "XAI API key"
  type        = string
  sensitive   = true
}

variable "perplexityai_api_key" {
  description = "PerplexityAI API key"
  type        = string
  sensitive   = true
}

variable "github_api_key" {
  description = "GitHub API key"
  type        = string
  sensitive   = true
}

variable "deepseek_api_key" {
  description = "Deepseek API key"
  type        = string
  sensitive   = true
}

variable "ai21_api_key" {
  description = "AI21 API key"
  type        = string
  sensitive   = true
}

variable "langsmith_api_key" {
  description = "Langsmith API key"
  type        = string
  sensitive   = true
}

variable "langsmith_project" {
  description = "Langsmith project"
  type        = string
}

variable "langsmith_default_run_name" {
  description = "langsmith default run name"
  type        = string
}

variable "okta_audience" {
  description = "Okta audience"
  type        = string
}

variable "okta_issuer" {
  description = "Okta issuer"
  type        = string
}

variable "use_route53" {
  description = "Whether to use Route53 for DNS management. If false, no Route53 resources will be created."
  type        = bool
  default     = false
}

variable "use_cloudfront" {
  description = "Whether to use CloudFront for content distribution. If false, only ALB will be used."
  type        = bool
  default     = true
}

variable "cloudfront_price_class" {
  description = "The price class for CloudFront distribution"
  type        = string
  default     = "PriceClass_100"
  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "Price class must be one of PriceClass_100, PriceClass_200, or PriceClass_All."
  }
}

variable "certificate_arn" {
  description = "ARN of the ACM certificate. Required if use_route53 is true."
  type        = string
  default     = ""
}

variable "record_name" {
  description = "Record name for the ingress. Required if use_route53 is true."
  type        = string
  default     = ""
}

variable "hosted_zone_name" {
  description = "Hosted zone name for the ingress. Required if use_route53 is true."
  type        = string
  default     = ""
}

variable "create_private_hosted_zone_in_existing_vpc" {
  description = "In the case public_load_balancer=false (meaning we need a private hosted zone), and an vpc_id is provided, decides whether we create a private hosted zone, or assume one already exists and import it"
  type        = bool
}

variable "architecture" {
  description = "The architecture for the node group instances (x86 or arm64)"
  type        = string
  default     = "x86"
  validation {
    condition     = contains(["x86", "arm"], var.architecture)
    error_message = "Architecture must be either 'x86' or 'arm64'."
  }
}

variable "disable_outbound_network_access" {
    description = "Whether to disable outbound network access from the VPC"
    type = bool
}

variable "desired_capacity" {
  description = "Desired number of ECS tasks"
  type = number
}

variable "min_capacity" {
  description = "Minimum number of ECS tasks (autoscaling)"
  type = number
}

variable "max_capacity" {
  description = "Maximum number of ECS tasks (autoscaling)"
  type = number
}

variable "public_load_balancer" {
  description = "whether the load balancer is public"
  type = bool
}

variable "cpu_target_utilization_percent" {
  description = "CPU target utilization percent for autoscale"
  type = number
}

variable "memory_target_utilization_percent" {
  description = "Memory target utilization percent for autoscale"
  type = number
}

variable "vcpus" {
  description = "Number of ECS vcpus"
  type = number
}

variable "create_vpc_endpoints_in_existing_vpc" {
  type    = bool
  description = "If using an existing VPC, set this to true to also create interface/gateway endpoints within it."
}

variable "ecrLitellmRepository" {
  type        = string
  description = "Name of the LiteLLM ECR repository"
}

variable "ecrMiddlewareRepository" {
  type        = string
  description = "Name of the Middleware ECR repository"
}

variable "rds_instance_class" {
  type        = string
  description = "The instance class for the RDS database"
}

variable "rds_multi_az" {
  type        = bool
  default     = true
  description = "Whether the RDS database is deployed Multi-AZ"
}

variable "rds_allocated_storage" {
  type        = number
  description = "The allocated storage in GB for the RDS database"
}

variable "redis_node_type" {
  type        = string
  description = "The node type for Redis clusters"
}

variable "redis_num_cache_clusters" {
  type        = number
  description = "The number of cache clusters for Redis"
}

variable "disable_swagger_page" {
  type    = bool
  description = "Whether to disable the swagger page or not"
}

variable "disable_admin_ui" {
  type    = bool
  description = "Whether to disable the admin UI or not"
}

variable "langfuse_public_key" {
  type    = string
  description = "the public key of your langfuse deployment"
}

variable "langfuse_secret_key" {
  type    = string
  description = "the secret key of your langfuse deployment"
}

variable "langfuse_host" {
  type    = string
  description = "the hostname of your langfuse deployment. Optional, defaults to https://cloud.langfuse.com"
  default = "https://cloud.langfuse.com"
}

variable "cloudfront_vpc_origin" {
  description = "Reach the ALB through a CloudFront VPC origin: the ALB becomes internal (private subnets) and only CloudFront can reach it, over the AWS network"
  type        = bool
  default     = true
}

variable "cloudfront_certificate_arn" {
  description = "ACM certificate in us-east-1 for the CloudFront custom domain. When empty: created by the stack if certificate_arn is also empty, otherwise falls back to certificate_arn (only valid if the stack is in us-east-1)"
  type        = string
  default     = ""
}

variable "cloudfront_waf" {
  description = "Attach a CLOUDFRONT-scope web ACL to the distribution. Behind a VPC origin it replaces the regional ACL on the ALB"
  type        = bool
  default     = true
}

variable "cloudfront_waf_rate_limit" {
  description = "Requests per 5 minutes from one IP before the edge WAF blocks it"
  type        = number
  default     = 2000
}

variable "alarm_email" {
  description = "Recipient of the Bedrock budget and token alarms. Empty = no alarms"
  type        = string
  default     = ""
}

variable "bedrock_monthly_budget_usd" {
  description = "Monthly Bedrock budget in USD (notifications at 50/80/100% actual and 100% forecast)"
  type        = number
  default     = 100
}

variable "bedrock_tokens_per_hour_alarm" {
  description = "Bedrock input + output tokens in one hour that raise the near-real-time alarm"
  type        = number
  default     = 2000000
}

variable "bedrock_budget_services" {
  description = "Cost Explorer service names that make up Bedrock spend. Anthropic models bill as their own '... (Amazon Bedrock Edition)' service; smoke test X1 flags any that are missing"
  type        = list(string)
  default = [
    "Amazon Bedrock",
    "Claude Haiku 4.5 (Amazon Bedrock Edition)",
    "Claude Haiku 5.5 (Amazon Bedrock Edition)",
    "Claude Sonnet 4.5 (Amazon Bedrock Edition)",
    "Claude Sonnet 4.6 (Amazon Bedrock Edition)",
    "Claude Sonnet 5 (Amazon Bedrock Edition)",
    "Claude Sonnet 5.5 (Amazon Bedrock Edition)",
    "Claude Opus 4.5 (Amazon Bedrock Edition)",
    "Claude Opus 4.6 (Amazon Bedrock Edition)",
    "Claude Opus 5 (Amazon Bedrock Edition)",
    "Claude Opus 5.5 (Amazon Bedrock Edition)",
    "Claude 3.5 Haiku (Amazon Bedrock Edition)",
    "Claude 3 Haiku (Amazon Bedrock Edition)",
  ]
}

variable "nat_gateway_per_az" {
  description = "One NAT gateway per AZ (each private subnet egresses through its own AZ) instead of a single shared one"
  type        = bool
  default     = false
}

variable "create_appregistry_application" {
  description = "Create a Service Catalog AppRegistry application for the solution (only for accounts that already use AppRegistry; it is closed to new customers)"
  type        = bool
  default     = false
}
