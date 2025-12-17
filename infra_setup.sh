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

# Defaults if not set in config.env
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
NETWORK_NAME="${NETWORK_NAME:-k8s-vpc}"
SUBNET_NAME="${SUBNET_NAME:-k8s-subnet}"
SUBNET_RANGE="${SUBNET_RANGE:-10.240.0.0/24}"
POD_CIDR="${POD_CIDR:-10.200.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.32.0.0/24}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"

# Construct Image Name
if [ -n "$CUSTOM_IMAGE_NAME" ]; then
    IMAGE_NAME="projects/$PROJECT_ID/global/images/$CUSTOM_IMAGE_NAME"
else
    IMAGE_NAME=""
fi

CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-k8s-control-plane}"
WORKER_NAME_PREFIX="${WORKER_NAME_PREFIX:-k8s-worker}"
WORKER_COUNT="${WORKER_COUNT:-2}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
BOOT_DISK_SIZE="${BOOT_DISK_SIZE:-50GB}"

echo "Using Project: $PROJECT_ID"
echo "Region: $REGION | Zone: $ZONE"

# ==============================================================================
# NETWORK SETUP
# ==============================================================================
echo "--- Creating VPC Network ---"
if ! gcloud compute networks describe $NETWORK_NAME &>/dev/null; then
    gcloud compute networks create $NETWORK_NAME --subnet-mode custom
else
    echo "Network $NETWORK_NAME already exists."
fi

echo "--- Creating Subnet ---"
if ! gcloud compute networks subnets describe $SUBNET_NAME --region $REGION &>/dev/null; then
    gcloud compute networks subnets create $SUBNET_NAME \
        --network $NETWORK_NAME \
        --region $REGION \
        --range $SUBNET_RANGE
else
    echo "Subnet $SUBNET_NAME already exists."
fi

echo "--- Creating Firewall Rules ---"
# Allow internal communication
if ! gcloud compute firewall-rules describe ${NETWORK_NAME}-allow-internal &>/dev/null; then
    gcloud compute firewall-rules create ${NETWORK_NAME}-allow-internal \
        --network $NETWORK_NAME \
        --allow tcp,udp,icmp \
        --source-ranges $SUBNET_RANGE,$POD_CIDR
fi

# Allow SSH
if ! gcloud compute firewall-rules describe ${NETWORK_NAME}-allow-ssh &>/dev/null; then
    gcloud compute firewall-rules create ${NETWORK_NAME}-allow-ssh \
        --network $NETWORK_NAME \
        --allow tcp:22 \
        --source-ranges 0.0.0.0/0
fi

# Allow K8s API (6443)
if ! gcloud compute firewall-rules describe ${NETWORK_NAME}-allow-k8s-api &>/dev/null; then
    gcloud compute firewall-rules create ${NETWORK_NAME}-allow-k8s-api \
        --network $NETWORK_NAME \
        --allow tcp:6443 \
        --source-ranges 0.0.0.0/0
fi

# ==============================================================================
# COMPUTE INSTANCES
# ==============================================================================

# Check if custom image is provided, else warn
if [ -z "$IMAGE_NAME" ]; then
    echo "WARNING: CUSTOM_IMAGE_NAME is not set in config.env. Using default Ubuntu image."
    IMAGE_ARGS="--image-family=$IMAGE_FAMILY --image-project=$IMAGE_PROJECT"
else
    # Verify image exists
    if ! gcloud compute images describe $CUSTOM_IMAGE_NAME --project $PROJECT_ID &>/dev/null; then
         echo "WARNING: Custom image $CUSTOM_IMAGE_NAME not found in project $PROJECT_ID. Falling back to default Ubuntu."
         IMAGE_ARGS="--image-family=$IMAGE_FAMILY --image-project=$IMAGE_PROJECT"
    else
         IMAGE_ARGS="--image=$IMAGE_NAME"
    fi
fi

echo "--- Creating Control Plane Instance ---"
if ! gcloud compute instances describe $CONTROL_PLANE_NAME --zone $ZONE &>/dev/null; then
    gcloud compute instances create $CONTROL_PLANE_NAME \
        --zone $ZONE \
        --machine-type $MACHINE_TYPE \
        --network $NETWORK_NAME \
        --subnet $SUBNET_NAME \
        --tags k8s-control-plane \
        --scopes cloud-platform \
        $IMAGE_ARGS \
        --boot-disk-size $BOOT_DISK_SIZE
else
    echo "Control Plane $CONTROL_PLANE_NAME already exists."
fi

echo "--- Creating Worker Instances ---"
for (( i=0; i<$WORKER_COUNT; i++ )); do
    NAME="${WORKER_NAME_PREFIX}-${i}"
    if ! gcloud compute instances describe $NAME --zone $ZONE &>/dev/null; then
        gcloud compute instances create $NAME \
            --zone $ZONE \
            --machine-type $MACHINE_TYPE \
            --network $NETWORK_NAME \
            --subnet $SUBNET_NAME \
            --tags k8s-worker \
            --scopes cloud-platform \
            $IMAGE_ARGS \
            --boot-disk-size $BOOT_DISK_SIZE
    else
        echo "Worker $NAME already exists."
    fi
done

echo "Infrastructure setup complete."
