# The Kubernetes and Helm providers talk to the GKE control plane through its
# DNS-based endpoint. Access is authorised by IAM with a short-lived OAuth
# token from Application Default Credentials; the endpoint serves a publicly
# trusted certificate, so no cluster CA or kubeconfig file is needed.

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_client_config" "this" {}

provider "kubernetes" {
  host  = "https://${var.cluster_dns_endpoint}"
  token = data.google_client_config.this.access_token
}

provider "helm" {
  kubernetes = {
    host  = "https://${var.cluster_dns_endpoint}"
    token = data.google_client_config.this.access_token
  }
}
