terraform {
  required_version = "~> 0.13.5"
}


provider "azurerm" {
  version = "~>2.33"
  features {}
}

provider "null" {
  version = "~> 3"
}

data "azurerm_log_analytics_workspace" "demo" {
  name                = var.la_workspace_name
  resource_group_name = var.la_workspace_rg_name
}

resource "azurerm_resource_group" "demo" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_virtual_network" "demo" {
  name                = "vnet-demo"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  address_space       = ["192.168.0.0/16"]
}

resource "azurerm_subnet" "agw" {
  name                 = "subnet-agw"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = ["192.168.0.0/24"]
}

resource "azurerm_subnet" "blue" {
  name                 = "subnet-blue"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = ["192.168.1.0/24"]
}

resource "azurerm_route_table" "blue" {
  name                = "route-blue"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
}

resource "azurerm_subnet_route_table_association" "blue" {
  subnet_id      = azurerm_subnet.blue.id
  route_table_id = azurerm_route_table.blue.id
}

resource "azurerm_subnet" "green" {
  name                 = "subnet-green"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = ["192.168.2.0/24"]
}

resource "azurerm_route_table" "green" {
  name                = "route-green"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
}

resource "azurerm_subnet_route_table_association" "green" {
  subnet_id      = azurerm_subnet.green.id
  route_table_id = azurerm_route_table.green.id
}

resource "azurerm_subnet" "private_endpoint" {
  name                                           = "subnet-private-endpoint"
  resource_group_name                            = azurerm_resource_group.demo.name
  virtual_network_name                           = azurerm_virtual_network.demo.name
  address_prefixes                               = ["192.168.3.0/24"]
  enforce_private_link_endpoint_network_policies = true
}

resource "azurerm_public_ip" "demo" {
  name                = "pip-demo"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_application_gateway" "demo" {
  name                = "agw-demo"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "agw-demo-gw-ip"
    subnet_id = azurerm_subnet.agw.id
  }

  frontend_port {
    name = "agw-demo-feport"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "agw-demo-feip"
    public_ip_address_id = azurerm_public_ip.demo.id
  }

  backend_address_pool {
    name         = "agw-demo-beap"
    ip_addresses = [var.service_ip_green]
  }

  backend_http_settings {
    name                  = "agw-demo-be-htst"
    cookie_based_affinity = "Disabled"
    path                  = "/"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
  }

  http_listener {
    name                           = "agw-demo-httplstn"
    frontend_ip_configuration_name = "agw-demo-feip"
    frontend_port_name             = "agw-demo-feport"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "agw-demo-rqrt"
    rule_type                  = "Basic"
    http_listener_name         = "agw-demo-httplstn"
    backend_address_pool_name  = "agw-demo-beap"
    backend_http_settings_name = "agw-demo-be-htst"
  }
}

resource "azurerm_sql_server" "demo" {
  name                         = var.sql_server_name
  resource_group_name          = azurerm_resource_group.demo.name
  location                     = azurerm_resource_group.demo.location
  version                      = "12.0"
  administrator_login          = var.sql_admin_username
  administrator_login_password = var.sql_admin_password
}

resource "azurerm_sql_database" "demo" {
  name                             = var.sql_database_name
  resource_group_name              = azurerm_resource_group.demo.name
  location                         = azurerm_resource_group.demo.location
  server_name                      = azurerm_sql_server.demo.name
  requested_service_objective_name = "GP_Gen5_2"
}

resource "azurerm_sql_firewall_rule" "Allow_client_pri_tf_client" {
  count               = var.enable_migration ? 1 : 0
  name                = "Allow_tf_client"
  resource_group_name = azurerm_resource_group.demo.name
  server_name         = azurerm_sql_server.demo.name
  start_ip_address    = var.tf_client_ip
  end_ip_address      = var.tf_client_ip

  // Waiting for firewall setting
  provisioner "local-exec" {
    command = "sleep 30"
  }
}

resource "null_resource" "migrater" {
  count      = var.enable_migration ? 1 : 0
  depends_on = [azurerm_sql_database.demo, azurerm_sql_firewall_rule.Allow_client_pri_tf_client]
  provisioner "local-exec" {
    command = <<EOT
      rm ../app/dotnetcore-sqldb-tutorial/Migrations/ -r
      dotnet ef migrations add InitialCreate --project ../app/dotnetcore-sqldb-tutorial
      export ConnectionStrings__MyDbConnection="Server=tcp:${azurerm_sql_server.demo.fully_qualified_domain_name},1433;Initial Catalog=${var.sql_database_name};Persist Security Info=False;User ID=${var.sql_admin_username};Password=${var.sql_admin_password};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
      dotnet ef database update --project ../app/dotnetcore-sqldb-tutorial
    EOT
  }
}

resource "azurerm_private_dns_zone" "demo" {
  name                = "privatelink.database.windows.net"
  resource_group_name = azurerm_resource_group.demo.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "demo" {
  name                  = "dnszonelink-demo"
  resource_group_name   = azurerm_resource_group.demo.name
  private_dns_zone_name = azurerm_private_dns_zone.demo.name
  virtual_network_id    = azurerm_virtual_network.demo.id
}

resource "azurerm_private_endpoint" "sql" {
  name                = "private-endpoint-sql"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  subnet_id           = azurerm_subnet.private_endpoint.id

  private_dns_zone_group {
    name                 = "private-dnszone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.demo.id]
  }

  private_service_connection {
    name                           = "private-endpoint-connection-sql"
    private_connection_resource_id = azurerm_sql_server.demo.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }
}

resource "azurerm_kubernetes_cluster" "blue" {
  depends_on          = [azurerm_subnet_route_table_association.blue]
  name                = "${var.aks_cluster_name}-blue"
  kubernetes_version  = "1.18.8"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  dns_prefix          = var.aks_cluster_name
  network_profile {
    network_plugin     = "kubenet"
    network_policy     = "calico"
    service_cidr       = "10.0.0.0/16"
    dns_service_ip     = "10.0.0.10"
    docker_bridge_cidr = "172.17.0.1/16"
  }

  default_node_pool {
    name               = "default"
    type               = "VirtualMachineScaleSets"
    availability_zones = [1, 2, 3]
    node_count         = 3
    vm_size            = "Standard_F2s_v2"
    vnet_subnet_id     = azurerm_subnet.blue.id
  }

  service_principal {
    client_id     = var.service_principal_client_id
    client_secret = var.service_principal_client_secret
  }

  addon_profile {
    kube_dashboard {
      enabled = false
    }
    oms_agent {
      enabled                    = true
      log_analytics_workspace_id = data.azurerm_log_analytics_workspace.demo.id
    }
  }

}

resource "azurerm_role_assignment" "aks_metrics_blue" {
  scope                = azurerm_kubernetes_cluster.blue.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = var.service_principal_object_id
}

resource "azurerm_kubernetes_cluster" "green" {
  depends_on          = [azurerm_subnet_route_table_association.green]
  name                = "${var.aks_cluster_name}-green"
  kubernetes_version  = "1.18.8"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  dns_prefix          = var.aks_cluster_name
  network_profile {
    network_plugin     = "kubenet"
    network_policy     = "calico"
    service_cidr       = "10.1.0.0/16"
    dns_service_ip     = "10.1.0.10"
    docker_bridge_cidr = "172.18.0.1/16"
  }

  default_node_pool {
    name               = "default"
    type               = "VirtualMachineScaleSets"
    availability_zones = [1, 2, 3]
    node_count         = 3
    vm_size            = "Standard_F2s_v2"
    vnet_subnet_id     = azurerm_subnet.green.id
  }

  service_principal {
    client_id     = var.service_principal_client_id
    client_secret = var.service_principal_client_secret
  }

  addon_profile {
    kube_dashboard {
      enabled = false
    }
    oms_agent {
      enabled                    = true
      log_analytics_workspace_id = data.azurerm_log_analytics_workspace.demo.id
    }
  }

}

resource "azurerm_role_assignment" "aks_metrics_green" {
  scope                = azurerm_kubernetes_cluster.green.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = var.service_principal_object_id
}

provider "kubernetes" {
  version = "~>1.13"
  alias   = "blue"

  load_config_file       = false
  host                   = azurerm_kubernetes_cluster.blue.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.blue.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.blue.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.blue.kube_config.0.cluster_ca_certificate)
}

resource "kubernetes_cluster_role" "log_reader_blue" {
  provider = kubernetes.blue

  metadata {
    name = "containerhealth-log-reader"
  }

  rule {
    api_groups = ["", "metrics.k8s.io", "extensions", "apps"]
    resources  = ["pods/log", "events", "nodes", "pods", "deployments", "replicasets"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "log_reader_blue" {
  provider = kubernetes.blue

  metadata {
    name = "containerhealth-read-logs-global"
  }

  role_ref {
    kind      = "ClusterRole"
    name      = "containerhealth-log-reader"
    api_group = "rbac.authorization.k8s.io"
  }

  subject {
    kind      = "User"
    name      = "clusterUser"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_service" "todoapp_blue" {
  provider = kubernetes.blue

  metadata {
    name = "todoapp"
    annotations = {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
    }
  }

  spec {
    selector = {
      app = "todoapp"
    }

    session_affinity = "ClientIP"

    port {
      port        = 80
      target_port = 5000
    }

    type             = "LoadBalancer"
    load_balancer_ip = var.service_ip_blue
  }
}

resource "kubernetes_deployment" "todoapp_blue" {
  provider = kubernetes.blue

  metadata {
    name = "todoapp"
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "todoapp"
      }
    }

    template {
      metadata {
        labels = {
          app = "todoapp"
        }
      }

      spec {
        container {
          image = "torumakabe/demo-ts-app-sql:1.0.0"
          name  = "todoapp"

          port {
            container_port = 5000
          }

          env {
            name  = "ConnectionStrings__MyDbConnection"
            value = "Server=tcp:${azurerm_sql_server.demo.fully_qualified_domain_name},1433;Initial Catalog=${var.sql_database_name};Persist Security Info=False;User ID=${var.sql_admin_username};Password=${var.sql_admin_password};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
          }

          env {
            name  = "APPINSIGHTS_INSTRUMENTATIONKEY"
            value = var.ai_key
          }

        }
      }
    }
  }
}

provider "kubernetes" {
  version = "~>1.13"
  alias   = "green"

  load_config_file       = false
  host                   = azurerm_kubernetes_cluster.green.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.green.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.green.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.green.kube_config.0.cluster_ca_certificate)
}

resource "kubernetes_cluster_role" "log_reader_green" {
  provider = kubernetes.green

  metadata {
    name = "containerhealth-log-reader"
  }

  rule {
    api_groups = ["", "metrics.k8s.io", "extensions", "apps"]
    resources  = ["pods/log", "events", "nodes", "pods", "deployments", "replicasets"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "log_reader_green" {
  provider = kubernetes.green

  metadata {
    name = "containerhealth-read-logs-global"
  }

  role_ref {
    kind      = "ClusterRole"
    name      = "containerhealth-log-reader"
    api_group = "rbac.authorization.k8s.io"
  }

  subject {
    kind      = "User"
    name      = "clusterUser"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_service" "todoapp_green" {
  provider = kubernetes.green

  metadata {
    name = "todoapp"
    annotations = {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
    }
  }

  spec {
    selector = {
      app = "todoapp"
    }

    session_affinity = "ClientIP"

    port {
      port        = 80
      target_port = 5000
    }

    type             = "LoadBalancer"
    load_balancer_ip = var.service_ip_green
  }
}

resource "kubernetes_deployment" "todoapp_green" {
  provider = kubernetes.green

  metadata {
    name = "todoapp"
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "todoapp"
      }
    }

    template {
      metadata {
        labels = {
          app = "todoapp"
        }
      }

      spec {
        container {
          image = "torumakabe/demo-ts-app-sql:1.0.0"
          name  = "todoapp"

          port {
            container_port = 5000
          }

          env {
            name  = "ConnectionStrings__MyDbConnection"
            value = "Server=tcp:${azurerm_sql_server.demo.fully_qualified_domain_name},1433;Initial Catalog=${var.sql_database_name};Persist Security Info=False;User ID=${var.sql_admin_username};Password=${var.sql_admin_password};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
          }

          env {
            name  = "APPINSIGHTS_INSTRUMENTATIONKEY"
            value = var.ai_key
          }

        }
      }
    }
  }
}

