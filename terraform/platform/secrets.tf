# Secret delivery: Google Secret Manager -> GKE Secret Manager sync ->
# Kubernetes Secrets, authenticated with Workload Identity Federation for GKE.
#
# Terraform only declares WHICH secret goes WHERE. The values never pass
# through Terraform (no data source reads them), so they are absent from plan
# output and state.

locals {
  secret_version = { for k, v in var.secret_resource_names : k => "${v}/versions/latest" }

  # namespace => files to fetch and Kubernetes Secrets to produce.
  secret_sync = {
    free5gc = {
      namespace = var.free5gc_namespace
      files = {
        "mongodb-root-password" = local.secret_version.mongodb_root_password
        "mongodb-app-password"  = local.secret_version.mongodb_app_password
        "subscribers.txt"       = local.secret_version.subscriber_credentials
      }
      secrets = {
        # Keys expected by the Bitnami MongoDB chart (auth.existingSecret)
        # and by patch 0003 (passwordKey: mongodb-passwords).
        # Maps file names to Secret KEY NAMES (no values); the inline allow
        # silences gitleaks' hashicorp-tf-password heuristic for that reason.
        "mongodb-credentials" = {
          "mongodb-root-password" = "mongodb-root-password"
          "mongodb-app-password"  = "mongodb-passwords" # gitleaks:allow
        }
        "subscriber-credentials" = {
          "subscribers.txt" = "subscribers.txt"
        }
      }
    }
    ueransim = {
      namespace = var.ueransim_namespace
      files = {
        "subscribers.txt" = local.secret_version.subscriber_credentials
      }
      secrets = {
        "ue-credentials" = {
          "subscribers.txt" = "subscribers.txt"
        }
      }
    }
  }

  secret_sync_objects = merge([
    for scope, cfg in local.secret_sync : {
      for name, mapping in cfg.secrets : "${scope}/${name}" => {
        scope     = scope
        namespace = cfg.namespace
        name      = name
        mapping   = mapping
      }
    }
  ]...)
}

# ServiceAccount whose Workload Identity principal is granted
# roles/secretmanager.secretAccessor on specific secrets (infra/modules/secrets).
resource "kubernetes_service_account_v1" "secret_sync" {
  for_each = local.secret_sync

  metadata {
    name      = var.secret_sync_ksa
    namespace = each.value.namespace
  }
  automount_service_account_token = false

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_manifest" "secret_provider_class" {
  for_each = local.secret_sync

  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "secret-manager"
      namespace = each.value.namespace
    }
    spec = {
      provider = "gke"
      parameters = {
        secrets = yamlencode([
          for path, version in each.value.files : {
            resourceName = version
            path         = path
          }
        ])
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_manifest" "secret_sync" {
  for_each = local.secret_sync_objects

  manifest = {
    apiVersion = "secret-sync.gke.io/v1"
    kind       = "SecretSync"
    metadata = {
      name      = each.value.name
      namespace = each.value.namespace
    }
    spec = {
      serviceAccountName      = var.secret_sync_ksa
      secretProviderClassName = kubernetes_manifest.secret_provider_class[each.value.scope].manifest.metadata.name
      secretObject = {
        type = "Opaque"
        data = [
          for source, target in each.value.mapping : {
            sourcePath = source
            targetKey  = target
          }
        ]
      }
    }
  }

  depends_on = [kubernetes_service_account_v1.secret_sync]
}
