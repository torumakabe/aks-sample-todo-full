variable "resource_group_name" {
  type    = string
  default = "your-resource-group-name"
}

variable "aks_cluster_name" {
  type    = string
  default = "your-aks-cluster-name"
}

variable "sql_server_name" {
  type    = string
  default = "your-sqldb-server-name"
}

variable "sql_database_name" {
  type    = string
  default = "your-sqldb-db-name"
}

variable "location" {
  type    = string
  default = "your-primary-region"
}

variable "sql_admin_username" {
  type    = string
  default = "your-sqldb-admin-name"
}

variable "sql_admin_password" {
  type    = string
  default = "your-sqldb-admin-password"
}

variable "enable_migration" {
  type    = bool
  default = false
}

// your public IP address $(curl http://ifconfig.io)
variable "tf_client_ip" {
  type    = string
  default = "0.0.0.0"
}

variable "service_principal_client_id" {
  type = string
}

variable "service_principal_client_secret" {
  type = string
}

variable "service_principal_object_id" {
  type = string
}

variable "la_workspace_name" {
  type = string
}

variable "la_workspace_rg_name" {
  type = string
}

variable "service_ip_blue" {
  type    = string
  default = "192.168.1.100"
}

variable "service_ip_green" {
  type    = string
  default = "192.168.2.100"
}

variable "ai_key" {
  type    = string
  default = "your-application-insights-instrumentation-key"
}
