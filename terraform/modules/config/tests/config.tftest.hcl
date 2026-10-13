# Offline unit tests for the configuration module.
# Run: terraform -chdir=terraform/modules/config init && terraform -chdir=terraform/modules/config test

variables {
  config_dir     = "../../../config"
  max_node_count = 4
}

run "repository_defaults_are_valid" {
  command = plan

  assert {
    condition     = length(output.subscribers.imsis) == 10
    error_message = "expected 10 IMSIs"
  }
  assert {
    condition     = output.subscribers.imsis[0] == "208930000000001" && output.subscribers.imsis[9] == "208930000000010"
    error_message = "unexpected IMSI sequence: ${jsonencode(output.subscribers.imsis)}"
  }
  assert {
    condition     = length(distinct(output.subscribers.imsis)) == 10
    error_message = "IMSIs must be unique"
  }
  assert {
    condition     = output.plmn.snssai_hex == "01010203" && output.plmn.tac_hex == "000001"
    error_message = "unexpected S-NSSAI/TAC encoding"
  }
  assert {
    condition     = output.network.per_node_pod_prefix == 25 && output.network.pod_node_capacity == 32
    error_message = "64 Pods/node must give a /25 per node and 32 nodes in a /20"
  }
  assert {
    condition     = output.network.node_capacity == 252
    error_message = "a /24 node range has 252 usable addresses"
  }
  assert {
    condition     = output.images.parts.nrf.name == "docker.io/free5gc/nrf" && startswith(output.images.parts.nrf.tag, "v4.2.2@sha256:")
    error_message = "image split is wrong: ${jsonencode(output.images.parts.nrf)}"
  }
}

run "registry_prefix_is_applied" {
  command = plan
  variables {
    image_registry = "europe-west9-docker.pkg.dev/p/dockerhub/"
  }
  assert {
    condition     = output.images.parts.busybox.name == "europe-west9-docker.pkg.dev/p/dockerhub/library/busybox"
    error_message = "registry prefix not applied: ${output.images.parts.busybox.name}"
  }
}

run "imsi_leading_zeros_are_preserved" {
  command = plan
  variables {
    subscribers_file = "tests/fixtures/subscribers-leading-zeros.yaml"
    network_file     = "../../../config/network.yaml"
  }
  # dnn in the fixture matches network.yaml ("internet").
  assert {
    condition     = jsonencode(output.subscribers.imsis) == jsonencode(["001010000000099", "001010000000100", "001010000000101"])
    error_message = "got ${jsonencode(output.subscribers.imsis)}"
  }
  assert {
    condition     = output.plmn.plmn == "00101" && output.plmn.mnc == "01"
    error_message = "PLMN leading zeros lost"
  }
}

run "three_digit_mnc_and_hex_sst" {
  command = plan
  variables {
    subscribers_file = "tests/fixtures/subscribers-3digit-mnc.yaml"
  }
  assert {
    condition     = jsonencode(output.subscribers.imsis) == jsonencode(["310410000000009", "310410000000010"])
    error_message = "got ${jsonencode(output.subscribers.imsis)}"
  }
  assert {
    condition     = output.plmn.snssai_hex == "0aabcdef"
    error_message = "SST must be hex-encoded and SD lower-cased, got ${output.plmn.snssai_hex}"
  }
}

run "rejects_msin_overflow" {
  command = plan
  variables {
    subscribers_file = "tests/fixtures/subscribers-overflow.yaml"
  }
  expect_failures = [output.plmn, output.subscribers]
}

run "rejects_imsi_not_matching_plmn" {
  command = plan
  variables {
    subscribers_file = "tests/fixtures/subscribers-plmn-mismatch.yaml"
  }
  expect_failures = [output.plmn, output.subscribers]
}

run "rejects_dnn_mismatch" {
  command = plan
  variables {
    subscribers_file = "tests/fixtures/subscribers-dnn-mismatch.yaml"
  }
  expect_failures = [output.plmn, output.subscribers]
}

run "rejects_unquoted_mnc" {
  command = plan
  variables {
    subscribers_file = "tests/fixtures/subscribers-unquoted-mnc.yaml"
  }
  expect_failures = [output.plmn, output.subscribers]
}

run "rejects_overlapping_ranges" {
  command = plan
  variables {
    network_file = "tests/fixtures/network-overlap.yaml"
  }
  expect_failures = [output.network]
}

run "rejects_ue_pool_overlapping_pods" {
  command = plan
  variables {
    network_file = "tests/fixtures/network-ue-overlaps-pods.yaml"
  }
  expect_failures = [output.network]
}

run "rejects_non_canonical_cidr" {
  command = plan
  variables {
    network_file = "tests/fixtures/network-noncanonical.yaml"
  }
  expect_failures = [output.network]
}

run "rejects_garbage_cidr" {
  command = plan
  variables {
    network_file = "tests/fixtures/network-garbage.yaml"
  }
  expect_failures = [output.network]
}

run "rejects_public_range" {
  command = plan
  variables {
    network_file = "tests/fixtures/network-public.yaml"
  }
  expect_failures = [output.network]
}

run "rejects_pod_range_too_small_for_nodes" {
  command = plan
  variables {
    network_file   = "tests/fixtures/network-small-pods.yaml"
    max_node_count = 4
  }
  expect_failures = [output.network]
}

run "rejects_tiny_service_range" {
  command = plan
  variables {
    network_file = "tests/fixtures/network-tiny-services.yaml"
  }
  expect_failures = [output.network]
}

run "rejects_overlap_with_reserved_range" {
  command = plan
  variables {
    extra_reserved_cidrs = { onprem = "10.60.128.0/17" }
  }
  expect_failures = [output.network]
}
