terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.61"
    }
  }

  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    state {
      method = method.aes_gcm.main
    }

    plan {
      method = method.aes_gcm.main
    }

  }
}

provider "hcloud" {
  token = var.hcloud_token
}

# Reference your existing SSH key by its fingerprint or name
resource "hcloud_ssh_key" "mine" {
  name       = "my-key"
  public_key = file("~/.ssh/id_ed25519.pub")
}

resource "hcloud_server" "k3s" {
  name        = "k3s-node-1"
  image       = "ubuntu-24.04"
  server_type = "cx23" # 2 vCPU, 4 GB RAM, ~€4.5/mo
  location    = "hel1" # Helsinki, Finland
  ssh_keys    = [hcloud_ssh_key.mine.id]

  user_data = <<-EOF
    #!/bin/bash
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init" sh -
  EOF
}
