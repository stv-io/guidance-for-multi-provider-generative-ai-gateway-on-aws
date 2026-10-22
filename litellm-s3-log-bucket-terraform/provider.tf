provider "aws" {
  default_tags {
    tags = {
      "stack-id" = var.name
      "project"  = "llmgateway"
    }
  }
}

terraform {
  required_version = ">= 1.6"
  backend "s3" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
