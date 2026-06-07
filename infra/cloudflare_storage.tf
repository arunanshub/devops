resource "cloudflare_r2_bucket" "etcd_snapshots" {
  account_id = var.cloudflare_account_id
  name       = "arunanshu-etcd-snapshots"
}

resource "cloudflare_r2_bucket_lifecycle" "etcd_snapshots" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.etcd_snapshots.name

  rules = [
    {
      id      = "expire-etcd-snapshots-after-45-days"
      enabled = true
      conditions = {
        prefix = ""
      }
      delete_objects_transition = {
        condition = {
          type    = "Age"
          max_age = 3888000
        }
      }
      abort_multipart_uploads_transition = {
        condition = {
          type    = "Age"
          max_age = 604800
        }
      }
    }
  ]
}

resource "cloudflare_r2_bucket" "velero_backups" {
  account_id = var.cloudflare_account_id
  name       = "arunanshu-velero-backups"
}

resource "cloudflare_r2_bucket_lifecycle" "velero_backups" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.velero_backups.name

  rules = [
    {
      id      = "expire-velero-backups-after-45-days"
      enabled = true
      conditions = {
        prefix = ""
      }
      delete_objects_transition = {
        condition = {
          type    = "Age"
          max_age = 3888000
        }
      }
      abort_multipart_uploads_transition = {
        condition = {
          type    = "Age"
          max_age = 604800
        }
      }
    }
  ]
}
