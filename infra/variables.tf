variable "hcloud_token" {
  type        = string
  description = "Hetzner Cloud API token (read+write). Injected via sops exec-env at runtime."
  sensitive   = true
}

variable "state_passphrase" {
  type        = string
  description = "Passphrase for OpenTofu state encryption (pbkdf2 + aes_gcm)."
  sensitive   = true
}

variable "home_ip" {
  type        = string
  description = "Your home public IP in CIDR notation (e.g. 2001:db8::1/128). Restricts Talos API (50000) and kube-API (6443) ingress."

  validation {
    condition     = can(cidrhost(var.home_ip, 0))
    error_message = "home_ip must be a valid CIDR (e.g. 1.2.3.4/32 or 2001:db8::1/128)."
  }
}

variable "nodes" {
  type = map(object({
    server_type = string
    location    = string
    private_ip  = string
  }))
  description = "Declarative cluster topology. All nodes are Talos control-plane+worker. Each key becomes the node name suffix (e.g. 'cp-1')."

  validation {
    condition = (
      length(values(var.nodes)) == length(toset([for v in var.nodes : v.private_ip]))
    )
    error_message = "All node private_ip values must be unique."
  }
}

variable "cloudflare_api_token" {
  type        = string
  description = "Cloudflare API token. Needs: Tunnel:Edit, Access:Edit, DNS:Edit. Injected via sops exec-env."
  sensitive   = true
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID (visible in the Cloudflare dashboard URL)."
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone ID for arunanshu.dev."
}

variable "owner_email" {
  type        = string
  description = "Email address allowed through Cloudflare Access for all protected applications."
}

check "private_ips_are_in_subnet" {
  assert {
    condition = alltrue([
      for k, v in var.nodes :
      cidrcontains(local.subnet_cidr, v.private_ip)
      && v.private_ip != cidrhost(local.subnet_cidr, 0)
      && v.private_ip != cidrhost(local.subnet_cidr, -1)
    ])
    error_message = "Every node private_ip must be a usable host address within subnet ${local.subnet_cidr}."
  }

  assert {
    condition = (
      cidrcontains(local.subnet_cidr, local.lb_private_ip)
      && local.lb_private_ip != cidrhost(local.subnet_cidr, 0)
      && local.lb_private_ip != cidrhost(local.subnet_cidr, -1)
      && !contains([for v in var.nodes : v.private_ip], local.lb_private_ip)
    )
    error_message = "local.lb_private_ip must be a usable, node-unique host address within subnet ${local.subnet_cidr}."
  }
}
