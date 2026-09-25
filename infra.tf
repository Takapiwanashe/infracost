# Sandbox PoC: member-account install only.
# Expect Infracost UI "permission checks" for CE/BCM/org to FAIL here — that is normal.
# What you CAN validate in sandbox:
#   1) Role + trust policy create successfully
#   2) Infracost can sts:AssumeRole with the External ID
#   3) ViewOnlyAccess / member read APIs work in THIS account
# After that, repeat with is_management_account = true on the payer account.
module "integration" {
  source  = "infracost/integration/aws"
  version = "0.4.0"
  providers = {
    aws = aws.restack-sandbox
  }

  infracost_external_id = var.infracost_external_id
  is_management_account = false
}

output "sandbox_role_arn" {
  description = "Paste into Infracost only to test AssumeRole from sandbox. Not a full management integration."
  value       = module.integration.role_arn
}

output "sandbox_account_id" {
  value = module.integration.account_id
}

variable "infracost_external_id" {
  description = "Infracost external ID"
  type        = string
  
}