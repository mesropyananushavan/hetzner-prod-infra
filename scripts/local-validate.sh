#!/usr/bin/env bash
set -euo pipefail

kubectl kustomize clusters/local >/dev/null
kubectl kustomize clusters/prod >/dev/null

echo "Rendered local and existing prod kustomizations successfully."
