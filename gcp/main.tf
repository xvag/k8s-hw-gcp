
###
### Create VPC, Subnet, Firewall Rules and Public-IP
###

resource "google_compute_address" "k8s-ip" {
  name   = "k8s-ip"
  region = var.vpc.controller.region
}

resource "google_compute_network" "controller-vpc" {
  name = "controller-vpc"
  auto_create_subnetworks = "false"
}

resource "google_compute_subnetwork" "controller-subnet" {
  name          = "controller-subnet"
  region        = var.vpc.controller.region
  ip_cidr_range = var.vpc.controller.subnet
  network       = google_compute_network.controller-vpc.id
}

resource "google_compute_network" "worker-vpc" {
  name = "worker-vpc"
  auto_create_subnetworks = "false"
}

resource "google_compute_subnetwork" "worker-subnet" {
  name          = "worker-subnet"
  region        = var.vpc.worker.region
  ip_cidr_range = var.vpc.worker.subnet
  network       = google_compute_network.worker-vpc.id
}

resource "google_compute_network" "nagios-vpc" {
  name = "nagios-vpc"
  auto_create_subnetworks = "false"
}

resource "google_compute_subnetwork" "nagios-subnet" {
  name          = "nagios-subnet"
  region        = var.vpc.nagios.region
  ip_cidr_range = var.vpc.nagios.subnet
  network       = google_compute_network.nagios-vpc.id
}

resource "google_compute_firewall" "nagios-fw" {
  name     = "nagios-fw"
  network  = "nagios-vpc"
  allow {
    protocol = "tcp"
    ports    = var.vpc.nagios.fw
  }
  allow {
    protocol = "icmp"
  }
  source_ranges = ["0.0.0.0/0"]
  depends_on = [
    google_compute_subnetwork.nagios-subnet
  ]
}

resource "google_compute_firewall" "controller-fw-in" {
  name     = "controller-fw-in"
  network  = "controller-vpc"
  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
  source_ranges = ["${var.vpc.controller.subnet}","${var.vpc.worker.subnet}","${var.pod-cidr-range}"]
  depends_on = [
    google_compute_subnetwork.controller-subnet
  ]
}

resource "google_compute_firewall" "worker-fw-in" {
  name     = "worker-fw-in"
  network  = "worker-vpc"
  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
  source_ranges = ["${var.vpc.controller.subnet}","${var.vpc.worker.subnet}","${var.pod-cidr-range}"]
  depends_on = [
    google_compute_subnetwork.worker-subnet
  ]
}

resource "google_compute_firewall" "controller-fw-ex" {
  name     = "controller-fw-ex"
  network  = "controller-vpc"
  allow {
    protocol = "tcp"
    ports    = var.vpc.controller.fw
  }
  allow {
    protocol = "icmp"
  }
  source_ranges = ["0.0.0.0/0"]
  depends_on = [
    google_compute_subnetwork.controller-subnet
  ]
}

resource "google_compute_firewall" "worker-fw-ex" {
  name     = "worker-fw-ex"
  network  = "worker-vpc"
  allow {
    protocol = "tcp"
    ports    = var.vpc.worker.fw
  }
  allow {
    protocol = "icmp"
  }
  source_ranges = ["0.0.0.0/0"]
  depends_on = [
    google_compute_subnetwork.worker-subnet
  ]
}

resource "google_compute_firewall" "k8s-fw-allow-health-check" {
  name    = "k8s-fw-allow-health-check"
  network = "controller-vpc"
  allow {
    protocol = "tcp"
  }
  source_ranges  = ["209.85.152.0/22", "209.85.204.0/22", "35.191.0.0/16"]
  depends_on = [
    google_compute_subnetwork.controller-subnet
  ]
}

###
### Create the VPC peerings
###

resource "google_compute_network_peering" "controller-worker" {
  name         = "controller-worker"
  network      = google_compute_network.controller-vpc.self_link
  peer_network = google_compute_network.worker-vpc.self_link
}

resource "google_compute_network_peering" "worker-controller" {
  name         = "worker-controller"
  network      = google_compute_network.worker-vpc.self_link
  peer_network = google_compute_network.controller-vpc.self_link
}

###
### Create Forwarding from Public-IP, Controllers' Health-Check and Cluster's pods Routing
###

resource "google_compute_http_health_check" "k8s-health-check" {
  name         = "k8s-health-check"
  host         = "kubernetes.default.svc.cluster.local"
  request_path = "/healthz"
}

resource "google_compute_target_pool" "k8s-target-pool" {
  name      = "k8s-target-pool"
  instances = var.target-pool
  region    = var.vpc.controller.region
  health_checks = [
    google_compute_http_health_check.k8s-health-check.name,
  ]
}

resource "google_compute_forwarding_rule" "k8s-forwarding-rule" {
  name       = "k8s-forwarding-rule"
  ip_address = google_compute_address.k8s-ip.address
  port_range = "6443-6443"
  region     = var.vpc.controller.region
  target     = google_compute_target_pool.k8s-target-pool.id
  depends_on = [
    google_compute_address.k8s-ip,
    google_compute_target_pool.k8s-target-pool
  ]
}

resource "google_compute_route" "k8s-pods-route" {
  count       = var.vpc.worker.no

  name        = "k8s-route-pods-worker-${count.index}"
  dest_range  = var.pod-cidr[count.index]
  network     = "worker-vpc"
  next_hop_ip = var.vpc.worker.ip[count.index]
  depends_on = [
    google_compute_subnetwork.worker-subnet,
    google_compute_network_peering.controller-worker,
    google_compute_network_peering.worker-controller
  ]
}

###
### Create the VMs
###

resource "google_compute_instance" "controller" {
  count = var.vpc.controller.no

  name                      = "${var.vpc.controller.name}-${count.index}"
  machine_type              = var.vpc.controller.machine
  zone                      = var.vpc.controller.zone
  allow_stopping_for_update = true
  can_ip_forward            = true
  tags                      = ["k8s", "controller"]
  boot_disk {
    initialize_params {
      image = var.vpc.controller.image
      size  = var.vpc.controller.size
    }
  }
  network_interface {
    subnetwork = google_compute_subnetwork.controller-subnet.self_link
    network_ip = var.vpc.controller.ip[count.index]
    access_config {
    }
  }
  service_account {
    scopes = ["compute-rw","storage-ro","service-management","service-control","logging-write","monitoring"]
  }
  metadata = {
    ssh-keys = "${var.ssh_user}:${var.ssh_key}"
  }
  depends_on = [
    google_compute_subnetwork.controller-subnet
  ]
}

resource "google_compute_instance" "worker" {
  count = var.vpc.worker.no

  name                      = "${var.vpc.worker.name}-${count.index}"
  machine_type              = var.vpc.worker.machine
  zone                      = var.vpc.worker.zone
  allow_stopping_for_update = true
  can_ip_forward            = true
  tags                      = ["k8s", "worker"]
  boot_disk {
    initialize_params {
      image = var.vpc.worker.image
      size  = var.vpc.worker.size
    }
  }
  network_interface {
    subnetwork = google_compute_subnetwork.worker-subnet.self_link
    network_ip = var.vpc.worker.ip[count.index]
    access_config {
    }
  }
  service_account{
    scopes = ["compute-rw","storage-ro","service-management","service-control","logging-write","monitoring"]
  }
  metadata = {
    ssh-keys = "${var.ssh_user}:${var.ssh_key}"
    pod-cidr = var.pod-cidr[count.index]
  }
  depends_on = [
    google_compute_subnetwork.worker-subnet
  ]
}

resource "google_compute_instance" "nagios" {
  count = var.vpc.nagios.no

  name                      = "${var.vpc.nagios.name}-${count.index}"
  machine_type              = var.vpc.nagios.machine
  zone                      = var.vpc.nagios.zone
  allow_stopping_for_update = true
  can_ip_forward            = true
  tags                      = ["nagios"]
  boot_disk {
    initialize_params {
      image = var.vpc.nagios.image
      size  = var.vpc.nagios.size
    }
  }
  network_interface {
    subnetwork = google_compute_subnetwork.nagios-subnet.self_link
    network_ip = var.vpc.nagios.ip[count.index]
    access_config {
    }
  }
  service_account{
    scopes = ["compute-rw","storage-ro","service-management","service-control","logging-write","monitoring"]
  }
  metadata = {
    ssh-keys = "${var.ssh_user}:${var.ssh_key}"
  }
  depends_on = [
    google_compute_subnetwork.nagios-subnet
  ]
}
