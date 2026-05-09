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

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the SSH public key to upload to Hetzner and inject into nodes."
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to the SSH private key used for provisioning and kubeconfig retrieval."
  default     = "~/.ssh/id_ed25519"
}

variable "home_ip" {
  type        = string
  description = "Your home public IP in CIDR notation (e.g. 2001:db8::1/128). Restricts SSH ingress. Store in secrets.yaml."

  validation {
    condition     = can(cidrhost(var.home_ip, 0))
    error_message = "home_ip must be a valid CIDR (e.g. 1.2.3.4/32 or 2001:db8::1/128)."
  }
}

variable "k3s_token" {
  type        = string
  description = "Static k3s cluster join token shared by all nodes. Generate: openssl rand -hex 32. Store in secrets.yaml."
  sensitive   = true
}

variable "nodes" {
  type = map(object({
    server_type = string
    role        = string # cp_only | cp_worker | worker
    location    = string
    private_ip  = string
  }))
  description = "Declarative cluster topology. Each key becomes the node name suffix (e.g. 'cp-1')."

  validation {
    condition = alltrue([
      for k, v in var.nodes : contains(["cp_only", "cp_worker", "worker"], v.role)
    ])
    error_message = "Each node role must be one of: cp_only, cp_worker, worker."
  }

  validation {
    condition = (
      length([for k, v in var.nodes : k if contains(["cp_only", "cp_worker"], v.role)]) % 2 == 1
    )
    error_message = "Control plane node count (cp_only + cp_worker) must be odd (1, 3, 5...)."
  }

  validation {
    condition = (
      length(values(var.nodes)) == length(toset([for v in var.nodes : v.private_ip]))
    )
    error_message = "All node private_ip values must be unique."
  }
}

variable "bootstrap_node" {
  type        = string
  description = "Key from var.nodes that bootstraps the cluster with --cluster-init. Must have a CP role."

  validation {
    condition     = contains(keys(var.nodes), var.bootstrap_node)
    error_message = "bootstrap_node must be a key in var.nodes."
  }
}

# Cross-variable assertion: bootstrap node must have a CP role.
# Cannot be expressed inside a variable{} validation block because HCL
# does not allow referencing a second variable from within validation{}.
check "bootstrap_node_has_cp_role" {
  assert {
    condition     = contains(["cp_only", "cp_worker"], var.nodes[var.bootstrap_node].role)
    error_message = "bootstrap_node '${var.bootstrap_node}' must have role cp_only or cp_worker."
  }
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
