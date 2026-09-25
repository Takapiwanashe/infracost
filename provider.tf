provider "aws" {
  alias   = "restack-sandbox"
  region  = "af-south-1"
  profile = "restack-sandbox" # AWS CLI/SSO profile name (separate from Terraform alias above)
  default_tags {
    tags = {
      Environment = "poc"
      Owner       = "CloudOps"
      CostCenter  = "ManagedServices"
      Createdby   = "gladman"
      Schedule    = "stop-at-5-sa"
    }
  }
}
