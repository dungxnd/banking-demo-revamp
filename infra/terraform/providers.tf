provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "banking-demo"
      ManagedBy = "Terraform"
    }
  }
}
