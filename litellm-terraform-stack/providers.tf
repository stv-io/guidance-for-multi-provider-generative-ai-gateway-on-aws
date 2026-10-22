terraform {
  required_version = ">= 1.6"
  backend "s3" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  SolutionNameKeySatisfyingRestrictions = "Guidance-for-Running-Generative-AI-Gateway-Proxy-on-AWS"
  common_labels = {
    project     = "llmgateway"
    AWSSolution = "ToDo"
    GithubRepo  = "https://github.com/aws-solutions-library-samples/"
    SolutionID  = "SO9022"
    SolutionNameKey = "Guidance for Running Generative AI Gateway Proxy on AWS"
    SolutionVersionKey = "1.0.0"
  }
}


provider "aws" {
  default_tags {
    tags = local.common_labels
  }
}

# CloudFront only accepts certificates and web ACLs from us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = local.common_labels
  }
}

# AppRegistry closed to new customers on 2026-07-30 (CreateApplication returns AccessDenied),
# so it is opt-in for accounts that already use it.
resource "aws_servicecatalogappregistry_application" "solution_application" {
  count       = var.create_appregistry_application ? 1 : 0
  name        = "${local.SolutionNameKeySatisfyingRestrictions}-${data.aws_region.current.region}-${data.aws_caller_identity.current.account_id}"
  description = "Service Catalog application to track and manage all your resources for the solution ${local.common_labels.SolutionNameKey}"

  tags = {
    "Solutions:SolutionID"      = local.common_labels.SolutionID
    "Solutions:SolutionName"    = local.common_labels.SolutionNameKey
    "Solutions:SolutionVersion" = local.common_labels.SolutionVersionKey
    "Solutions:ApplicationType" = "AWS-Solutions"
  }
}
