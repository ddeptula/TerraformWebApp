terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
    }
  }
}

provider "azurerm" {
  features {

  }
  subscription_id = "7fdf605c-e6b5-4f51-b9c0-27d0799ce221"
}