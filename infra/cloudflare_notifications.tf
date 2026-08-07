resource "cloudflare_notification_policy" "http_ddos" {
  account_id  = var.cloudflare_account_id
  name        = "HTTP DDoS attacks"
  description = "Notify the owner when Cloudflare detects and mitigates an HTTP DDoS attack."
  alert_type  = "dos_attack_l7"
  enabled     = true

  mechanisms = {
    email = [{
      id = var.owner_email
    }]
  }
}

resource "cloudflare_notification_policy" "universal_ssl" {
  account_id  = var.cloudflare_account_id
  name        = "Universal SSL lifecycle"
  description = "Notify the owner about Universal SSL validation, issuance, renewal, and expiration events."
  alert_type  = "universal_ssl_event_type"
  enabled     = true

  mechanisms = {
    email = [{
      id = var.owner_email
    }]
  }
}

resource "cloudflare_notification_policy" "tunnel_health" {
  account_id  = var.cloudflare_account_id
  name        = "k3s tunnel health"
  description = "Notify the owner when the managed Cloudflare Tunnel connection status changes."
  alert_type  = "tunnel_health_event"
  enabled     = true

  mechanisms = {
    email = [{
      id = var.owner_email
    }]
  }

  filters = {
    tunnel_id = [cloudflare_zero_trust_tunnel_cloudflared.main.id]
  }
}
