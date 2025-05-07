// TERRAFORM VERSION AND PROVIDER REQUIREMENTS
// We define Terraform's provider settings to ensure compatibility with ChameleonCloud's OpenStack environment.
terraform {
  required_version = ">= 0.14.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.51.1"
    }
  }
}

// PROVIDER CONFIGURATION
// This tells Terraform to use OpenStack and look for auth details in clouds.yaml file.
provider "openstack" {
  cloud = "openstack"
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
// Fetch the public shared network and security groups pre-configured in Chameleon.
data "openstack_networking_network_v2" "sharednet3" {
  name = "sharednet3"
}

data "openstack_networking_secgroup_v2" "allow_ssh" {
  name = "allow-ssh"
}

// ADDITIONAL SECURITY GROUPS
// These are required to expose services like MLFlow (port 8000) and MinIO (ports 9000, 9001)
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
// This is the network interface for VM. We attach only the necessary security groups.
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
// We spin up one CPU VM (no GPU needed for inference) on sharednet3, accessible via floating IP.
resource "openstack_compute_instance_v2" "main-vm-${var.suffix}" {
  name        = "main-vm-${var.suffix}"
  image_name  = "CC-Ubuntu24.04"
  flavor_name = "m1.medium" // Suitable for CPU-based inference
  key_pair    = var.key

  network {
    port = openstack_networking_port_v2["main-vm-port-${var.suffix}"].id
  }

  // User data for first-boot initialization (load SSH keys, register hostname)
  user_data = <<-EOF
    #! /bin/bash
    sudo echo "127.0.1.1 main-vm-${var.suffix}" >> /etc/hosts
    su cc -c /usr/local/bin/cc-load-public-keys
  EOF
}

// FLOATING IP - FIRST TIME ONLY
// This block creates a public IP and assigns it to VM so we can SSH or access APIs.
resource "openstack_networking_floatingip_v2" "main-vm-floating-ip-${var.suffix}" {
  pool        = "public"
  description = "Floating IP for main-vm-${var.suffix}"
  port_id     = openstack_networking_port_v2["main-vm-port-${var.suffix}"].id
}

// OBJECT STORAGE CONTAINER (Swift)
// This creates a Swift container for storing datasets or model artifacts.
resource "openstack_objectstorage_container_v1" "objectstore-container-${var.suffix}" {
  name = "objectstore-container-${var.suffix}"
}

// BLOCK STORAGE VOLUME (Cinder)
// This defines a 20GB persistent volume in the KVM@TACC zone.
resource "openstack_blockstorage_volume_v3" "blockstorage-volume-${var.suffix}" {
  name              = "blockstorage-volume-${var.suffix}"
  size              = 20
  availability_zone = "KVM@TACC"
}

// ATTACH VOLUME TO VM
// This attaches the block volume to the instance so it can be mounted in the OS.
resource "openstack_compute_volume_attach_v2" "blockstorage-volume-attach-${var.suffix}" {
  instance_id = openstack_compute_instance_v2["main-vm-${var.suffix}"].id
  volume_id   = openstack_blockstorage_volume_v3["blockstorage-volume-${var.suffix}"].id
}

// OUTPUTS FOR FIRST-TIME RUN
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

output "object_storage_container" {
  value       = openstack_objectstorage_container_v1["objectstore-container-${var.suffix}"].name
  description = "Name of the created Swift object storage container"
}

output "block_volume_name" {
  value       = openstack_blockstorage_volume_v3["blockstorage-volume-${var.suffix}"].name
  description = "Name of the persistent block volume"
}
