###############################################################################
# Cloud SQL — PostgreSQL 15 primary, private IP only
###############################################################################

resource "random_id" "db_suffix" {
  byte_length = 4
}

resource "google_sql_database_instance" "primary" {
  name             = "${var.instance_name}-${random_id.db_suffix.hex}"
  database_version = var.db_version
  region           = var.region

  depends_on = [var.private_services_connection]

  settings {
    tier              = var.tier
    availability_type = var.high_availability ? "REGIONAL" : "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = var.disk_size_gb
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled                                  = false   # no public IP
      private_network                               = var.network_id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
      backup_retention_settings {
        retained_backups = 7
      }
    }

    maintenance_window {
      day          = 7  # Sunday
      hour         = 4
      update_track = "stable"
    }

    database_flags {
      name  = "log_connections"
      value = "on"
    }

    database_flags {
      name  = "log_disconnections"
      value = "on"
    }

    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }

    user_labels = var.labels
  }

  deletion_protection = false  # set true when going production
}

resource "google_sql_database" "app" {
  name     = var.db_name
  instance = google_sql_database_instance.primary.name
}

resource "google_sql_user" "app" {
  name     = "drapp"
  instance = google_sql_database_instance.primary.name
  password = var.db_password
}
