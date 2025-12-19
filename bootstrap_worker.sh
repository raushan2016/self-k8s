#!/bin/bash
set -e -o pipefail

if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 '<kubeadm join command>'"
    echo "Example: $0 'kubeadm join 10.128.0.2:6443 --token ... --discovery-token-ca-cert-hash ...'"
    exit 1
fi

read -ra JOIN_COMMAND_PARTS <<< "$1"

echo "--- Joining Kubernetes Cluster ---"
echo "Executing: sudo ${JOIN_COMMAND_PARTS[*]}"

# Execute the join command
sudo "${JOIN_COMMAND_PARTS[@]}"

echo "--- Node Joined ---"
