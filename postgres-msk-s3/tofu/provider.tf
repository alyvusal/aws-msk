terraform {
  required_version = "~> 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    null = {
      source  = "opentofu/null"
      version = "3.2.4"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
