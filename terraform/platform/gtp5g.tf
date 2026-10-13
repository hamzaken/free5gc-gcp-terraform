# gtp5g node preparation on the dedicated UPF node pool.
#
# A privileged INIT container builds gtp5g for the node's exact kernel and
# loads it; the long-running container is unprivileged and only reports
# readiness while the expected module version is present. Every new or
# rebooted UPF node gets the module automatically (DaemonSet semantics).
#
# The UPF Pod has its own gate (wait-gtp5g init container, patch 0004), so a
# UPF is never started on a node without a compatible module.

locals {
  gtp5g_namespace = kubernetes_namespace_v1.this["gtp5g"].metadata[0].name
  gtp5g           = module.render.gtp5g
}

resource "kubernetes_config_map_v1" "gtp5g_scripts" {
  metadata {
    name      = "gtp5g-loader"
    namespace = local.gtp5g_namespace
  }
  data = {
    "build-and-load.sh" = file("${path.root}/../../kubernetes/gtp5g/build-and-load.sh")
  }
}

resource "kubernetes_service_account_v1" "gtp5g" {
  metadata {
    name      = "gtp5g-loader"
    namespace = local.gtp5g_namespace
  }
  automount_service_account_token = false
}

resource "kubernetes_daemon_set_v1" "gtp5g" {
  metadata {
    name      = "gtp5g-loader"
    namespace = local.gtp5g_namespace
    labels    = { "app.kubernetes.io/name" = "gtp5g-loader" }
  }

  spec {
    selector {
      match_labels = { "app.kubernetes.io/name" = "gtp5g-loader" }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "1"
      }
    }

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "gtp5g-loader" }
        annotations = {
          # Re-run the loader when the script or pinned version changes.
          "free5gc.io/script-sha256" = sha256(kubernetes_config_map_v1.gtp5g_scripts.data["build-and-load.sh"])
          "free5gc.io/gtp5g-version" = local.gtp5g.version
        }
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.gtp5g.metadata[0].name
        automount_service_account_token = false
        node_selector                   = local.upf_node_selector
        # No system-*-critical priority class: GKE restricts those to
        # kube-system with a ResourceQuota, so Pods would never be created.

        toleration {
          key      = "free5gc.io/upf"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        init_container {
          name    = "build-and-load"
          image   = local.image_refs.ubuntu
          command = ["/bin/bash", "/scripts/build-and-load.sh"]

          env {
            name  = "GTP5G_VERSION"
            value = local.gtp5g.version
          }
          env {
            name  = "GTP5G_URL"
            value = local.gtp5g.source_url
          }
          env {
            name  = "GTP5G_SHA256"
            value = local.gtp5g.source_sha256
          }
          env {
            name  = "HOST_ROOT"
            value = "/host"
          }

          # Loading a kernel module requires CAP_SYS_MODULE in the initial
          # user namespace; "privileged" is the supported way to get it on GKE.
          security_context {
            privileged = true
          }

          resources {
            requests = { cpu = "250m", memory = "256Mi" }
            limits   = { memory = "1Gi" }
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }
          volume_mount {
            name       = "host-modules"
            mount_path = "/host/lib/modules"
            read_only  = true
          }
          volume_mount {
            name       = "host-os-release"
            mount_path = "/host/etc/os-release"
            read_only  = true
          }
        }

        container {
          name    = "ready"
          image   = local.image_refs.busybox
          command = ["/bin/sh", "-c", "trap 'exit 0' TERM; while true; do sleep 3600 & wait $!; done"]

          readiness_probe {
            exec {
              command = ["/bin/sh", "-c", "test \"$(cat /sys/module/gtp5g/version)\" = \"${local.gtp5g.version}\""]
            }
            period_seconds = 30
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 65534
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "5m", memory = "8Mi" }
            limits   = { memory = "32Mi" }
          }
        }

        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map_v1.gtp5g_scripts.metadata[0].name
            default_mode = "0555"
          }
        }
        volume {
          name = "host-modules"
          host_path {
            path = "/lib/modules"
            type = "Directory"
          }
        }
        volume {
          name = "host-os-release"
          host_path {
            # /etc/os-release is a relative symlink on Ubuntu; mount its target.
            path = "/usr/lib/os-release"
            type = "File"
          }
        }
      }
    }
  }

  # Readiness of the DaemonSet is checked by scripts/verify.sh; Terraform does
  # not block here so that a gtp5g failure is reported with full logs.
  wait_for_rollout = false
}
