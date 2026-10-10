#!/usr/bin/env bash
# Delete the local kind cluster (all scan history in RustFS / Dependency-Track is lost).
set -euo pipefail
read -r -p "Delete kind cluster 'security-pipeline'? [y/N] " a
[ "${a:-n}" = y ] || exit 0
kind delete cluster --name security-pipeline
