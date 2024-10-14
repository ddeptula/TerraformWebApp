
# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "ddeptula-webapp"
  location = "East US"
}

# VNets/Networking

resource "azurerm_virtual_network" "vnet" {
  name                = "webapp-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "web" {
  name                 = "web-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
  service_endpoints = ["Microsoft.Sql"] 
}


# Load Balancer

resource "azurerm_public_ip" "pip" {
  name                = "webapp-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "loadbalancer" {
  name                = "webapp-lb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "PublicIPAddress"
    public_ip_address_id = azurerm_public_ip.pip.id
  }
}

resource "azurerm_lb_backend_address_pool" "backendpool" {
  loadbalancer_id     = azurerm_lb.loadbalancer.id
  name                = "BackendPool"
}

resource "azurerm_lb_probe" "loadbalancer_probe" {
  loadbalancer_id     = azurerm_lb.loadbalancer.id
  name                = "http-probe"
  protocol            = "Http"
  port                = 80
  request_path        = "/"
}

resource "azurerm_lb_rule" "loadbalancer_rule" {
  loadbalancer_id                = azurerm_lb.loadbalancer.id
  name                           = "http-rule"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "PublicIPAddress"
  backend_address_pool_ids = [azurerm_lb_backend_address_pool.backendpool.id]
  probe_id                       = azurerm_lb_probe.loadbalancer_probe.id
}

resource "azurerm_lb_rule" "loadbalancer_rule_https" {
  loadbalancer_id                = azurerm_lb.loadbalancer.id
  name                           = "https-rule"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "PublicIPAddress"
  backend_address_pool_ids = [azurerm_lb_backend_address_pool.backendpool.id]
  probe_id                       = azurerm_lb_probe.loadbalancer_probe.id
}


# Web NSG

resource "azurerm_network_security_group" "webappnsg" {
  name                = "webapp-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-http"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}


resource "azurerm_network_security_rule" "webapp_nsg_https_rule" {
  name                        = "allow-https"
  network_security_group_name = azurerm_network_security_group.webappnsg.name
  resource_group_name         = azurerm_resource_group.rg.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}


# Virtual Machine Scale Set

resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                            = "webapp-vmss"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  sku                             = "Standard_D2s_v3"
  instances                       = 3
  admin_username                  = "adminuser"
  admin_password                  = "P@ssw0rd1234!"
  disable_password_authentication = false
  user_data = filebase64("cloud-init.txt")
  
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  network_interface {
    name    = "webapp-nic"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.web.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.backendpool.id]
    }

    network_security_group_id = azurerm_network_security_group.webappnsg.id
    
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  # Since these can change via auto-scaling outside of Terraform,
  # we'll ignore any changes to the number of instances
  lifecycle {
    ignore_changes = [instances]
  }

}

resource "azurerm_monitor_autoscale_setting" "vmss_autoscale" {
  name                = "autoscale-config"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.vmss.id

  profile {
    name = "AutoScale"

    capacity {
      default = 2
      minimum = 2
      maximum = 3
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 75
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT1M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 25
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT1M"
      }
    }
  }
}

# SQL Database

resource "azurerm_mssql_server" "sqlsvr" {
  name                         = "webapp-sqlsvr"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version = "12.0"
  administrator_login          = "4dm1n157r470r"
  administrator_login_password = "4-v3ry-53cr37-p455w0rd"
}

resource "azurerm_mssql_database" "sqldb" {
  name                             = "webapp-db"
  server_id = azurerm_mssql_server.sqlsvr.id
  collation                        = "SQL_Latin1_General_CP1_CI_AS"
  create_mode                      = "Default"
}

# Enables the "Allow Access to Azure services" box as described in the API docs
# https://docs.microsoft.com/en-us/rest/api/sql/firewallrules/createorupdate
resource "azurerm_mssql_firewall_rule" "sql_firewall_rule" {
  name                = "allow-azure-services"
  server_id = azurerm_mssql_server.sqlsvr.id
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

resource "azurerm_mssql_virtual_network_rule" "sql_vnet_rule" {
  name                 = "allow-vnet-rule"
  server_id = azurerm_mssql_server.sqlsvr.id
  subnet_id            = azurerm_subnet.web.id
}

# Storage Account

resource "azurerm_storage_account" "webapp" {
  name                     = "ddeptulawebappstorage"
  resource_group_name       = azurerm_resource_group.rg.name
  location                  = azurerm_resource_group.rg.location
  account_tier              = "Standard"
  account_replication_type  = "LRS"               # Local Redundant Storage
}

# Monitor/Alerting

resource "azurerm_monitor_metric_alert" "cpu_alert" {
  name                = "vmss-cpu-alert"
  resource_group_name = azurerm_resource_group.rg.name
  description         = "Alert when CPU usage exceeds 80%"
  severity            = 3
  frequency           = "PT1M" # Check every minute
  window_size         = "PT5M" # Data window of 5 minutes
  scopes              = [azurerm_linux_virtual_machine_scale_set.vmss.id]

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachineScaleSets"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 1
  }
}