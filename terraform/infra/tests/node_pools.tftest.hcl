# Offline tests of the node-pool sizing rules (no credentials, no cloud calls:
# the Google providers are mocked).
# Run: terraform -chdir=terraform/infra init -backend=false && terraform -chdir=terraform/infra test

mock_provider "google" {
  override_data {
    target = module.gke.data.google_container_engine_versions.this
    values = {
      release_channel_default_version = {
        RAPID   = "1.37.0-gke.100"
        REGULAR = "1.36.4-gke.1391002"
        STABLE  = "1.35.2-gke.100"
      }
    }
  }
  override_data {
    target = module.gke.data.google_project.this
    values = {
      number = "123456789012"
    }
  }
}

mock_provider "random" {}

variables {
  project_id = "test-project-123"
}

run "default_pools_are_accepted" {
  # 1 x e2-standard-4 general + 1 x e2-standard-2 UPF. Set explicitly so a
  # local terraform.tfvars cannot change what this case tests.
  command = plan
  variables {
    general_pool = {}
    upf_pool     = {}
  }
}

run "two_e2_standard_2_general_nodes_are_accepted" {
  command = plan
  variables {
    general_pool = { machine_type = "e2-standard-2", node_count = 2 }
  }
}

run "custom_machine_type_vcpus_are_counted" {
  command = plan
  variables {
    general_pool = { machine_type = "n2-custom-4-16384", node_count = 1 }
  }
}

run "single_e2_standard_2_general_node_is_rejected" {
  # The layout that leaves Pods unschedulable (about 2 vCPU in total).
  command = plan
  variables {
    general_pool = { machine_type = "e2-standard-2", node_count = 1 }
  }
  expect_failures = [var.general_pool]
}

run "shared_core_general_nodes_are_rejected" {
  command = plan
  variables {
    general_pool = { machine_type = "e2-medium", node_count = 4 }
  }
  expect_failures = [var.general_pool]
}

run "shared_core_upf_node_is_rejected" {
  command = plan
  variables {
    upf_pool = { machine_type = "e2-medium", node_count = 1 }
  }
  expect_failures = [var.upf_pool]
}
