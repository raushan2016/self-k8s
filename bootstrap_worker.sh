#!/bin/bash
set -e -o pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 '<kubeadm join command>'"
    echo "Example: $0 'kubeadm join 10.128.0.2:6443 --token ... --discovery-token-ca-cert-hash ...'"
    exit 1
fi

JOIN_COMMAND=$1

echo "--- Joining Kubernetes Cluster ---"
echo "Executing: sudo $JOIN_COMMAND"

# Execute the join command
sudo $JOIN_COMMAND

echo "--- Node Joined ---"
