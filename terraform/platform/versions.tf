terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3.0"
    }
  }

  # Local state by default (git-ignored); see backend.tf.example. The state
  # holds rendered Helm values and Kubernetes manifests, none of which contain
  # secret values (Secrets are referenced by name only).
}
