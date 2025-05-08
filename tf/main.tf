// TERRAFORM VERSION AND PROVIDER REQUIREMENTS
terraform {
  required_version = ">= 0.14.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.51.1"
    }
  }
}

// PROVIDERS
provider "openstack" {
  cloud = "openstack_kvm"
}

provider "openstack" {
  alias = "swift"
  cloud = "openstack_chi"
}

// VARIABLES
variable "suffix" {
  description = "Suffix to differentiate resources"
  type        = string
  nullable    = false
}

variable "key" {
  description = "Name of the SSH key pair registered in Chameleon"
  type        = string
  default     = "id_rsa_chameleon"
}

// DATA SOURCES
data "openstack_networking_network_v2" "sharednet3" {
  name = "sharednet3"
}

data "openstack_networking_secgroup_v2" "allow_ssh" {
  name = "allow-ssh"
}

data "openstack_networking_secgroup_v2" "allow_8000" {
  name = "allow-8000"
}

data "openstack_networking_secgroup_v2" "allow_9000" {
  name = "allow-9000"
}

data "openstack_networking_secgroup_v2" "allow_9001" {
  name = "allow-9001"
}

// NETWORKING PORT
resource "openstack_networking_port_v2" "main-vm-port-${var.suffix}" {
  name       = "main-vm-port-${var.suffix}"
  network_id = data.openstack_networking_network_v2.sharednet3.id
  security_group_ids = [
    data.openstack_networking_secgroup_v2.allow_ssh.id,
    data.openstack_networking_secgroup_v2.allow_8000.id,
    data.openstack_networking_secgroup_v2.allow_9000.id,
    data.openstack_networking_secgroup_v2.allow_9001.id,
  ]
}

// COMPUTE INSTANCE
resource "openstack_compute_instance_v2" "main-vm-${var.suffix}" {
  name        = "main-vm-${var.suffix}"
  image_name  = "CC-Ubuntu24.04"
  flavor_name = "m1.medium"
  key_pair    = var.key

  network {
    port = openstack_networking_port_v2["main-vm-port-${var.suffix}"].id
  }

  user_data = <<-EOF
    #! /bin/bash
    sudo echo "127.0.1.1 main-vm-${var.suffix}" >> /etc/hosts
    su cc -c /usr/local/bin/cc-load-public-keys
  EOF
}

// FLOATING IP - FIRST TIME ONLY
resource "openstack_networking_floatingip_v2" "main-vm-floating-ip-${var.suffix}" {
  pool        = "public"
  description = "Floating IP for main-vm-${var.suffix}"
  port_id     = openstack_networking_port_v2["main-vm-port-${var.suffix}"].id
}

// OBJECT STORAGE (EXISTING CONTAINER CREATED BY FRIEND)
data "openstack_objectstorage_container_v1" "objectstore-shared-container" {
  provider = openstack.swift
  name     = "object-persist-project19"
}

// BLOCK STORAGE VOLUME
resource "openstack_blockstorage_volume_v3" "blockstorage-volume-${var.suffix}" {
  name              = "blockstorage-volume-${var.suffix}"
  size              = 20
  availability_zone = "KVM@TACC"
}

// VOLUME ATTACH TO VM
resource "openstack_compute_volume_attach_v2" "blockstorage-volume-attach-${var.suffix}" {
  instance_id = openstack_compute_instance_v2["main-vm-${var.suffix}"].id
  volume_id   = openstack_blockstorage_volume_v3["blockstorage-volume-${var.suffix}"].id
}

// OUTPUTS
output "vm_name" {
  value       = openstack_compute_instance_v2["main-vm-${var.suffix}"].name
  description = "Name of the deployed VM"
}

output "network_port_name" {
  value       = openstack_networking_port_v2["main-vm-port-${var.suffix}"].name
  description = "Name of the VM's network port"
}

output "floating_ip_address" {
  value       = openstack_networking_floatingip_v2["main-vm-floating-ip-${var.suffix}"].address
  description = "Public IP to reach the VM"
}

output "ssh_command" {
  value       = "ssh cc@${openstack_networking_floatingip_v2["main-vm-floating-ip-${var.suffix}"].address}"
  description = "SSH command to connect to the VM"
}

output "object_storage_container_name" {
  value       = data.openstack_objectstorage_container_v1.objectstore-shared-container.name
  description = "Referenced Swift container shared by teammate"
}

output "block_volume_name" {
  value       = openstack_blockstorage_volume_v3["blockstorage-volume-${var.suffix}"].name
  description = "Name of the persistent block volume"
}

// REUSE EXISTING FLOATING IP - OPTIONAL BLOCK
# Uncomment below if you want to re-use a reserved floating IP after first apply

# variable "floating_ip_address" {
#   description = "Existing floating IP to use"
#   default     = "129.114.27.242"  // Replace with your reserved IP
# }

# data "openstack_networking_floatingip_v2" "existing_ip" {
#   address = var.floating_ip_address
# }

# resource "openstack_networking_floatingip_associate_v2" "main-vm-fip-association" {
#   floating_ip = data.openstack_networking_floatingip_v2.existing_ip.address
#   port_id     = openstack_networking_port_v2["main-vm-port-${var.suffix}"].id
# }

# output "floating_ip_address" {
#   value       = data.openstack_networking_floatingip_v2.existing_ip.address
#   description = "Reused IP to reach the VM"
# }

# output "ssh_command" {
#   value       = "ssh cc@${data.openstack_networking_floatingip_v2.existing_ip.address}"
#   description = "SSH command for reused IP"
# }
