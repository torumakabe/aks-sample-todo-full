resource "azurerm_kubernetes_cluster" "green" {
  depends_on         = [azurerm_subnet_route_table_association.green]
  name               = "${var.aks_cluster_name}-green"
  kubernetes_version = data.azurerm_kubernetes_service_versions.current.latest_version
  //kubernetes_version  = "1.18.10"
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
