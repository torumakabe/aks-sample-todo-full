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
    ip_addresses = var.service_switch == "blue" ? [var.service_ip_blue] : [var.service_ip_green]
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
