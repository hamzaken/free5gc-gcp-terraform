# Ingress NetworkPolicies, enforced natively by GKE Dataplane V2.
#
#   free5gc ns   NF <-> NF (SBI over HTTP, N4/PFCP SMF->UPF): allowed between
#                Pods carrying the chart's "nf" label
#                MongoDB 27017/TCP: only NRF, UDR, PCF, CHF and the provisioner
#                AMF 38412/SCTP (N2): only from the gNB
#                UPF 2152/UDP (N3): only from the gNB
#   ueransim ns  gNB 4997/UDP (radio link simulation): only from UEs
#                gNB 2152/UDP (N3 downlink): only from the UPF
#   all three    everything else denied by default
#
# Egress is not restricted: NFs need DNS and the UPF forwards UE traffic to
# the internet (N6). See docs/security.md for the residual risk.

locals {
  policy_namespaces = {
    free5gc  = var.free5gc_namespace
    ueransim = var.ueransim_namespace
    gtp5g    = "gtp5g-system"
  }
  ns_label = "kubernetes.io/metadata.name"
}

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  for_each = local.policy_namespaces

  metadata {
    name      = "default-deny-ingress"
    namespace = each.value
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_network_policy_v1" "nf_mesh" {
  metadata {
    name      = "allow-nf-to-nf"
    namespace = var.free5gc_namespace
  }
  spec {
    pod_selector {
      match_expressions {
        key      = "nf"
        operator = "Exists"
      }
    }
    ingress {
      from {
        pod_selector {
          match_expressions {
            key      = "nf"
            operator = "Exists"
          }
        }
      }
    }
    policy_types = ["Ingress"]
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_network_policy_v1" "mongodb" {
  metadata {
    name      = "allow-mongodb-clients"
    namespace = var.free5gc_namespace
  }
  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "mongodb" }
    }
    ingress {
      from {
        pod_selector {
          match_expressions {
            key      = "nf"
            operator = "In"
            values   = ["nrf", "udr", "pcf", "chf"]
          }
        }
      }
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "subscriber-provisioner" }
        }
      }
      ports {
        port     = "27017"
        protocol = "TCP"
      }
    }
    policy_types = ["Ingress"]
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_network_policy_v1" "amf_n2" {
  metadata {
    name      = "allow-n2-from-gnb"
    namespace = var.free5gc_namespace
  }
  spec {
    pod_selector {
      match_labels = { nf = "amf" }
    }
    ingress {
      from {
        namespace_selector {
          match_labels = { (local.ns_label) = var.ueransim_namespace }
        }
        pod_selector {
          match_labels = { component = "gnb" }
        }
      }
      ports {
        port     = "38412"
        protocol = "SCTP"
      }
    }
    policy_types = ["Ingress"]
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_network_policy_v1" "upf_n3" {
  metadata {
    name      = "allow-n3-from-gnb"
    namespace = var.free5gc_namespace
  }
  spec {
    pod_selector {
      match_labels = { nf = "upf" }
    }
    ingress {
      from {
        namespace_selector {
          match_labels = { (local.ns_label) = var.ueransim_namespace }
        }
        pod_selector {
          match_labels = { component = "gnb" }
        }
      }
      ports {
        port     = "2152"
        protocol = "UDP"
      }
    }
    policy_types = ["Ingress"]
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_network_policy_v1" "ueransim_gnb" {
  metadata {
    name      = "allow-gnb-ingress"
    namespace = var.ueransim_namespace
  }
  spec {
    pod_selector {
      match_labels = { component = "gnb" }
    }
    # Radio link simulation from the UEs.
    ingress {
      from {
        pod_selector {
          match_labels = { component = "ue" }
        }
      }
      ports {
        port     = "4997"
        protocol = "UDP"
      }
    }
    # GTP-U downlink from the UPF.
    ingress {
      from {
        namespace_selector {
          match_labels = { (local.ns_label) = var.free5gc_namespace }
        }
        pod_selector {
          match_labels = { nf = "upf" }
        }
      }
      ports {
        port     = "2152"
        protocol = "UDP"
      }
    }
    policy_types = ["Ingress"]
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_network_policy_v1" "ueransim_ue" {
  metadata {
    name      = "allow-ue-from-gnb"
    namespace = var.ueransim_namespace
  }
  spec {
    pod_selector {
      match_labels = { component = "ue" }
    }
    # RLS replies from the gNB to the UE's ephemeral UDP port.
    ingress {
      from {
        pod_selector {
          match_labels = { component = "gnb" }
        }
      }
      ports {
        protocol = "UDP"
      }
    }
    policy_types = ["Ingress"]
  }

  depends_on = [kubernetes_namespace_v1.this]
}
