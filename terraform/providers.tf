provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.cluster_name
      ManagedBy = "terraform"
    }
  }
}
