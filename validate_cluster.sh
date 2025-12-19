#!/bin/bash
set -e -o pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
# Source configuration
if [[ -f "config.env" ]]; then
    source config.env
else
    echo "Error: config.env not found."
    exit 1
fi

CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-k8s-control-plane}"
ZONE="${ZONE:-us-central1-a}"

echo "============================================================"
echo "Validating Kubernetes Cluster"
echo "Control Plane: ${CONTROL_PLANE_NAME} | Zone: ${ZONE}"
echo "============================================================"

# Helper function to run command on Control Plane
function run_on_cp() {
    gcloud compute ssh "${CONTROL_PLANE_NAME}" --project "${PROJECT_ID}" --zone "${ZONE}" --command "$1"
}

echo "--- 1. Checking Node Status ---"
run_on_cp "kubectl get nodes -o wide"
echo ""

echo "--- 2. Checking System Pods ---"
run_on_cp "kubectl get pods -n kube-system -o wide"
echo ""

echo "--- 3. Checking Cilium Status ---"
run_on_cp "cilium status"
echo ""

echo "--- 4. Connectivity Test ---"
echo "Deploying Nginx..."
run_on_cp "kubectl create deployment nginx-test --image=nginx --replicas=4 || true"
run_on_cp "kubectl expose deployment nginx-test --port=80 --target-port=80 || true"

echo "Waiting for pods to be ready..."
run_on_cp "kubectl wait --for=condition=ready pod -l app=nginx-test --timeout=60s"

echo "Testing internal connectivity (Pod to Service)..."
# Get ClusterIP of the service
SVC_IP=$(run_on_cp "kubectl get svc nginx-test -o jsonpath='{.spec.clusterIP}'")
echo "Service IP: ${SVC_IP}"

# Run a curl from within one of the pods
POD_NAME=$(run_on_cp "kubectl get pods -l app=nginx-test -o jsonpath='{.items[0].metadata.name}'")
echo "Testing curl from pod ${POD_NAME}..."
run_on_cp "kubectl exec ${POD_NAME} -- curl -s -m 5 ${SVC_IP}" && echo "Connectivity Successful!" || echo "Connectivity Failed!"

echo "--- Cleanup ---"
run_on_cp "kubectl delete deployment nginx-test"
run_on_cp "kubectl delete svc nginx-test"

echo "============================================================"
echo "Validation Complete"
echo "============================================================"
