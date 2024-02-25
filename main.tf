locals {
  project_name     = coalesce(try(var.context["project"]["name"], null), "default")
  project_id       = coalesce(try(var.context["project"]["id"], null), "default_id")
  environment_name = coalesce(try(var.context["environment"]["name"], null), "test")
  environment_id   = coalesce(try(var.context["environment"]["id"], null), "test_id")
  resource_name    = coalesce(try(var.context["resource"]["name"], null), "example")
  resource_id      = coalesce(try(var.context["resource"]["id"], null), "example_id")

  namespace = join("-", [local.project_name, local.environment_name])

  tags = {
    "Name" = join("-", [local.namespace, local.resource_name])

    "walrus.seal.io-catalog-name"     = "terraform-azure-mysql"
    "walrus.seal.io-project-id"       = local.project_id
    "walrus.seal.io-environment-id"   = local.environment_id
    "walrus.seal.io-resource-id"      = local.resource_id
    "walrus.seal.io-project-name"     = local.project_name
    "walrus.seal.io-environment-name" = local.environment_name
    "walrus.seal.io-resource-name"    = local.resource_name
  }

  architecture = coalesce(var.architecture, "standalone")
}

#
# Ensure
#
data "azurerm_resource_group" "selected" {
  name = var.infrastructure.resource_group

  lifecycle {
    postcondition {
      condition     = self.id != null
      error_message = "Resource group is not avaiable"
    }
  }
}

data "azurerm_virtual_network" "selected" {
  name                = var.infrastructure.virtual_network
  resource_group_name = data.azurerm_resource_group.selected.name

  lifecycle {
    postcondition {
      condition     = self.id != null
      error_message = "Virtual network is not avaiable"
    }
  }
}

data "azurerm_subnet" "selected" {
  name = var.infrastructure.subnet

  virtual_network_name = data.azurerm_virtual_network.selected.name
  resource_group_name  = data.azurerm_resource_group.selected.name

  lifecycle {
    postcondition {
      condition     = self.id != null
      error_message = "Subnet is not avaiable"
    }
  }
}

data "azurerm_private_dns_zone" "selected" {
  count = var.infrastructure.domain_suffix == null ? 0 : 1

  name                = var.infrastructure.domain_suffix
  resource_group_name = data.azurerm_resource_group.selected.name

  lifecycle {
    postcondition {
      condition     = self.id != null
      error_message = "Failed to get available private dns zone"
    }
  }
}

#
# Random
#

# create a random password for blank password input.

resource "random_password" "password" {
  length      = 16
  special     = false
  lower       = true
  min_lower   = 3
  min_upper   = 3
  min_numeric = 3
}

# create the name with a random suffix.

resource "random_string" "name_suffix" {
  length  = 10
  special = false
  upper   = false
}

#
# Deployment
#

# create server.

locals {
  name     = join("-", [local.resource_name, random_string.name_suffix.result])
  fullname = join("-", [local.namespace, local.name])
  version  = coalesce(var.engine_version, "8.0.21")
  database = coalesce(var.database, "mydb")
  username = coalesce(var.username, "rdsuser")
  password = coalesce(var.password, random_password.password.result)

  replication_readonly_replicas = var.replication_readonly_replicas == 0 ? 1 : var.replication_readonly_replicas
}

resource "azurerm_mysql_flexible_server" "primary" {
  name = local.fullname
  tags = local.tags

  resource_group_name = data.azurerm_resource_group.selected.name
  location            = data.azurerm_resource_group.selected.location

  administrator_login    = local.username
  administrator_password = local.password

  backup_retention_days = 7

  delegated_subnet_id = data.azurerm_subnet.selected.id
  private_dns_zone_id = var.infrastructure.domain_suffix == null ? null : element(data.azurerm_private_dns_zone.selected, 0).id
  sku_name            = var.resources.class

  version = local.version

  storage {
    size_gb = try(var.storage.size / 1024, 20)
  }

  lifecycle {
    ignore_changes = [
      administrator_login,
      administrator_password,
    ]
  }
}

resource "azurerm_mysql_flexible_server" "secondary" {
  count = local.architecture == "replication" ? local.replication_readonly_replicas : 0

  name = join("-", [local.fullname, "secondary", tostring(count.index)])
  tags = local.tags

  resource_group_name = data.azurerm_resource_group.selected.name
  location            = data.azurerm_resource_group.selected.location

  administrator_login    = local.username
  administrator_password = local.password

  backup_retention_days = 7

  delegated_subnet_id = data.azurerm_subnet.selected.id
  private_dns_zone_id = var.infrastructure.domain_suffix == null ? null : element(data.azurerm_private_dns_zone.selected, 0).id
  sku_name            = var.resources.class

  version = local.version

  source_server_id = azurerm_mysql_flexible_server.primary.id
  create_mode      = "Replica"

  storage {
    size_gb = try(var.storage.size / 1024, 20)
  }

  lifecycle {
    ignore_changes = [
      administrator_login,
      administrator_password,
    ]
  }

}

# create database.

resource "azurerm_mysql_flexible_database" "database" {
  name                = local.database
  resource_group_name = data.azurerm_resource_group.selected.name
  server_name         = azurerm_mysql_flexible_server.primary.name
  charset             = "utf8"
  collation           = "utf8_unicode_ci"

  lifecycle {
    ignore_changes = [
      name,
      charset,
      collation
    ]
  }
}
