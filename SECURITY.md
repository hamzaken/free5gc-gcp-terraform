# Security policy

This is a lab template for an open-source 5G core. Its design, residual risks
and accepted limitations are documented in [docs/security.md](docs/security.md).

## Reporting a vulnerability

Please **do not open a public issue** for security problems in this
repository (for example a way secrets could leak into Git, Terraform state,
logs or manifests, or an unintended network exposure).

Use GitHub's private reporting instead: **Security → Report a vulnerability**
on this repository. You should receive an answer within a reasonable time;
this is a personal project maintained on a best-effort basis.

Vulnerabilities in upstream software (free5GC, UERANSIM, gtp5g, MongoDB,
GKE) should be reported to those projects directly.
