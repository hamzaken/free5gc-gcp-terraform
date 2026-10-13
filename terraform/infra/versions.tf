terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7.0"
    }
  }

  # State: local by default (git-ignored). For anything shared, copy
  # backend.tf.example to backend.tf and use a private, versioned GCS bucket.
  # The state contains no secret values by design (docs/security.md#state),
  # but it does reveal project IDs, network layout and resource names.
}
