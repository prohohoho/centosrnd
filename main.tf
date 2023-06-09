# get my external IP address to enter into NSG rules
data "http" "myExtIp" {
    url = "http://ident.me/"
}

#get keyvault storage
data "azurerm_key_vault" "tcakeyv" {
  name                = "tcakeyvault"
  resource_group_name = "rnd"
}

#get secret from keyvaul to be used on vm provisioning
data "azurerm_key_vault_secret" "mySecret" {
  name      = "azureuser"
  key_vault_id = data.azurerm_key_vault.tcakeyv.id
}

#set shellscript for bootstrap
data "template_file" "startupscript"{
  template = file ("script.sh")
}

#set resource group name
resource "random_pet" "rg_name" {
  prefix = var.resource_group_name_prefix
}

#create resource group for vm and related resources
resource "azurerm_resource_group" "rg" {
  location = var.resource_group_location
  name     = random_pet.rg_name.id
}

# Create virtual network
resource "azurerm_virtual_network" "tca_terraform_network" {
  name                = "tcaVnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Create subnet
resource "azurerm_subnet" "tca_terraform_subnet" {
  name                 = "tcaSubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.tca_terraform_network.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Create public IPs
resource "azurerm_public_ip" "tca_terraform_public_ip" {
  name                = "tcaPublicIP"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Dynamic"
}

# Create Network Security Group and rule
resource "azurerm_network_security_group" "tca_terraform_nsg" {
  name                = "tcaNetworkSecurityGroup"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
   
  #enable SSH for inbound access for machines with IP similar to the one that provisioned the resources
  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "${data.http.myExtIp.body}" # reference to http data source
    destination_address_prefix = "*"
  }
  #enable HTTPS for inbound access for machines with IP similar to the one that provisioned the resources
  security_rule {
    name                       = "HTTPS"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "${data.http.myExtIp.body}" # reference to http data source
    destination_address_prefix = "*"
  }
  #enable HTTP for inbound access for machines with IP similar to the one that provisioned the resources
  security_rule {
    name                       = "HTTP"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "${data.http.myExtIp.body}" # reference to http data source
    destination_address_prefix = "*"
  }
}

# Create network interface
resource "azurerm_network_interface" "tca_terraform_nic" {
  name                = "tcaNIC"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "tca_nic_configuration"
    subnet_id                     = azurerm_subnet.tca_terraform_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.tca_terraform_public_ip.id
  }
}

# Connect the security group to the network interface
resource "azurerm_network_interface_security_group_association" "example" {
  network_interface_id      = azurerm_network_interface.tca_terraform_nic.id
  network_security_group_id = azurerm_network_security_group.tca_terraform_nsg.id
}

# Generate random text for a unique storage account name
resource "random_id" "random_id" {
  keepers = {
    # Generate a new ID only when a new resource group is defined
    resource_group = azurerm_resource_group.rg.name
  }

  byte_length = 8
}

# Create storage account for boot diagnostics
resource "azurerm_storage_account" "tca_storage_account" {
  name                     = "diag${random_id.random_id.hex}"
  location                 = azurerm_resource_group.rg.location
  resource_group_name      = azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Create (and display) an SSH key
resource "tls_private_key" "example_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create virtual machine
resource "azurerm_linux_virtual_machine" "tca_vm" {
  name                  = "tcaVM"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.tca_terraform_nic.id]
  size                  = "Standard_DS1_v2"

  #specify specs for the vm disc
  os_disk {
    name                 = "tcaOsDisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  
  #specify specs for the vm image
  source_image_reference {
    publisher = var.linux_vm_image_publisher
    offer     = var.linux_vm_image_offer
    sku       = var.centos_7_gen2_sku
    version   = "latest"
  }
  #specify authentication details for the vm
  computer_name                   = "tcaVM"
  admin_username                  = "azureuser"
  admin_password                  ="${data.azurerm_key_vault_secret.mySecret.value}"
  disable_password_authentication = false
  
  #specify specs for the vm ssh key
  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.example_ssh.public_key_openssh
  }
  
  #specify specs for the vm diagnostics
  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.tca_storage_account.primary_blob_endpoint
  }

  #call the script for bootstrap
  custom_data    = base64encode(data.template_file.startupscript.rendered)

}