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
  description = "Path to the SSH private key used by null_resource local-exec to retrieve kubeconfig."
  default     = "~/.ssh/id_ed25519"
}

variable "home_ip" {
  type        = string
  description = "Your home public IP (IPv6 or IPv4). Used to restrict firewall ingress for SSH and k3s API. Do not hardcode — put in secrets.yaml."
}

variable "location" {
  type        = string
  description = "Hetzner datacenter location (e.g. hel1, nbg1, fsn1)."
  default     = "hel1"
}

variable "control_plane_server_type" {
  type        = string
  description = "Hetzner server type for the control plane node."
  default     = "cx33"
}
