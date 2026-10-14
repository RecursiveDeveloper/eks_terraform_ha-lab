terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "6.69.0"
    }
  }

  backend "s3" {
    bucket         = "tf-backend-lab-s3"
    key            = "terraform.tfstate"
    region         = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}
