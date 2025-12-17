#!/bin/bash
set -e -o pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
# Source configuration
if [ -f "config.env" ]; then
    source config.env
else
    echo "Error: config.env not found."
    exit 1
fi

# Defaults
POD_CIDR="${POD_CIDR:-10.200.0.0/16}"
KUBERNETES_FULL_VERSION="${KUBERNETES_FULL_VERSION:-v1.29.0}"
CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-v0.15.0}"
CILIUM_VERSION="${CILIUM_VERSION:-1.14.5}"

echo "--- Initializing Kubernetes Control Plane ---"

# Get the internal IP of the node
INTERNAL_IP=$(hostname -I | awk '{print $1}')
echo "Internal IP: $INTERNAL_IP"

# Initialize Kubeadm
# We specify the apiserver-advertise-address to ensure it binds to the internal IP
sudo kubeadm init \
  --pod-network-cidr=$POD_CIDR \
  --apiserver-advertise-address=$INTERNAL_IP \
  --kubernetes-version=$KUBERNETES_FULL_VERSION
echo "[SUCCESS] Kubeadm initialized."

echo "--- Configuring Kubectl for Root ---"
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
echo "[SUCCESS] Kubectl configured."

echo "--- Installing Cilium CLI ---"
CILIUM_CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CILIUM_CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CILIUM_CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CILIUM_CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CILIUM_CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CILIUM_CLI_ARCH}.tar.gz{,.sha256sum}
echo "[SUCCESS] Cilium CLI installed."

echo "--- Installing Cilium CNI ---"
cilium install --version $CILIUM_VERSION
echo "[SUCCESS] Cilium CNI installed."

echo "--- Waiting for Cilium to be ready ---"
cilium status --wait
echo "[SUCCESS] Cilium is ready."

echo "--- Cluster Initialized ---"
echo "To join worker nodes, run the following command on them:"
kubeadm token create --print-join-command
