output "instance_name" {
  value = google_sql_database_instance.primary.name
}

output "instance_connection_name" {
  value = google_sql_database_instance.primary.connection_name
}

output "private_ip_address" {
  value = google_sql_database_instance.primary.private_ip_address
}

output "database_name" {
  value = google_sql_database.app.name
}

output "db_user" {
  value = google_sql_user.app.name
}
