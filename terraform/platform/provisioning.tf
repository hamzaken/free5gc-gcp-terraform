# Subscriber provisioning Job: runs after the free5GC release is Ready, writes
# the subscribers idempotently into MongoDB and must succeed before UERANSIM
# is deployed.
#
# The Job name embeds a hash of the profile and script, so changing
# config/subscribers.yaml (or the script) creates a new Job run. To re-run
# after rotating credentials in Secret Manager:
#   scripts/deploy.sh --reprovision

locals {
  provisioner_script  = file("${path.root}/../../provisioning/subscribers/provision.js")
  provisioner_profile = jsonencode(module.render.subscriber_profile)
  provisioner_hash    = substr(sha256("${local.provisioner_script}${local.provisioner_profile}"), 0, 10)
  free5gc_namespace   = kubernetes_namespace_v1.this["free5gc"].metadata[0].name
}

resource "kubernetes_config_map_v1" "provisioner" {
  metadata {
    name      = "subscriber-provisioner"
    namespace = local.free5gc_namespace
  }
  data = {
    "provision.js" = local.provisioner_script
    "profile.json" = local.provisioner_profile
  }
}

resource "kubernetes_job_v1" "provisioner" {
  metadata {
    name      = "subscriber-provisioner-${local.provisioner_hash}"
    namespace = local.free5gc_namespace
    labels    = { "app.kubernetes.io/name" = "subscriber-provisioner" }
  }

  spec {
    backoff_limit           = 4
    active_deadline_seconds = 1200

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "subscriber-provisioner" }
        annotations = {
          "free5gc.io/config-hash" = local.provisioner_hash
        }
      }

      spec {
        restart_policy                  = "Never"
        automount_service_account_token = false
        node_selector                   = local.general_node_selector

        security_context {
          run_as_non_root = true
          run_as_user     = 1001
          run_as_group    = 1001
          fs_group        = 1001
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "provision"
          image   = local.image_refs.mongodb
          command = ["mongosh", "--nodb", "--quiet", "--norc", "/scripts/provision.js"]

          env {
            name = "MONGODB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "mongodb-credentials"
                key  = "mongodb-passwords"
              }
            }
          }
          # Kubernetes expands $(MONGODB_PASSWORD) when starting the
          # container; the manifest and Terraform state only hold the literal.
          env {
            name  = "MONGODB_URI"
            value = "mongodb://free5gc:$(MONGODB_PASSWORD)@mongodb.${local.free5gc_namespace}.svc.cluster.local:27017/free5gc?authSource=free5gc"
          }
          env {
            name  = "HOME"
            value = "/tmp"
          }
          env {
            name  = "DO_NOT_TRACK"
            value = "1"
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { memory = "512Mi" }
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }
          volume_mount {
            name       = "profile"
            mount_path = "/config"
            read_only  = true
          }
          volume_mount {
            name       = "credentials"
            mount_path = "/credentials"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "scripts"
          config_map {
            name = kubernetes_config_map_v1.provisioner.metadata[0].name
            items {
              key  = "provision.js"
              path = "provision.js"
            }
          }
        }
        volume {
          name = "profile"
          config_map {
            name = kubernetes_config_map_v1.provisioner.metadata[0].name
            items {
              key  = "profile.json"
              path = "profile.json"
            }
          }
        }
        volume {
          name = "credentials"
          secret {
            secret_name  = "subscriber-credentials"
            default_mode = "0400"
          }
        }
        volume {
          name = "tmp"
          empty_dir {
            medium     = "Memory"
            size_limit = "16Mi"
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [helm_release.free5gc, kubernetes_network_policy_v1.mongodb]
}
