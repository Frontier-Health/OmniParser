#!/usr/bin/env bash
#
# Manage an OmniParser GPU EC2 instance (g4dn.xlarge).
#
# Usage:
#   ./ec2_manage.sh create   - launch a new instance
#   ./ec2_manage.sh start    - start a stopped instance
#   ./ec2_manage.sh stop     - stop the instance (keeps EBS, no compute cost)
#   ./ec2_manage.sh terminate- terminate and delete the instance
#   ./ec2_manage.sh status   - show instance state and IP
#   ./ec2_manage.sh ssh      - SSH into the instance
#   ./ec2_manage.sh deploy   - deploy/update OmniParser on the instance
#
# Prerequisites:
#   - AWS CLI v2 configured with credentials (aws configure)
#   - An existing EC2 key pair (set OMNI_KEY_NAME)
#   - OMNI_SUBNET_ID set to a subnet you can reach (e.g. via VPN)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.ec2_instance"

# ---------------------------------------------------------------------------
# Configuration -- override via environment variables
# ---------------------------------------------------------------------------
INSTANCE_TYPE="${OMNI_INSTANCE_TYPE:-g4dn.xlarge}"
KEY_NAME="${OMNI_KEY_NAME:-}"
REGION="${AWS_DEFAULT_REGION:-eu-west-2}"
VOLUME_SIZE="${OMNI_VOLUME_SIZE:-150}"
SUBNET_ID="${OMNI_SUBNET_ID:-}"
SECURITY_GROUP_NAME="omniparser-sg"
REPO_URL="${OMNI_REPO_URL:-https://github.com/Frontier-Health/OmniParser.git}"
GH_TOKEN="${OMNI_GH_TOKEN:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_require_aws_cli() {
    if ! command -v aws &>/dev/null; then
        echo "ERROR: AWS CLI not found. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
        exit 1
    fi
}

_require_key_name() {
    if [ -z "$KEY_NAME" ]; then
        echo "ERROR: Set OMNI_KEY_NAME to your EC2 key pair name." >&2
        exit 1
    fi
}

_require_subnet() {
    if [ -z "$SUBNET_ID" ]; then
        echo "ERROR: Set OMNI_SUBNET_ID to the subnet to launch into." >&2
        exit 1
    fi
}

_save_instance_id() {
    echo "$1" > "$STATE_FILE"
    echo "Instance ID saved to $STATE_FILE"
}

_load_instance_id() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "ERROR: No instance tracked. Run '$0 create' first." >&2
        exit 1
    fi
    cat "$STATE_FILE"
}

_get_instance_ip() {
    local instance_id="$1"
    local public_ip private_ip
    read -r public_ip private_ip < <(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' \
        --output text)
    if [ -n "$public_ip" ] && [ "$public_ip" != "None" ]; then
        echo "$public_ip"
    else
        echo "$private_ip"
    fi
}

_get_instance_info() {
    local instance_id="$1"
    aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].{State:State.Name,PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress,Type:InstanceType}' \
        --output table 2>/dev/null
}

_wait_for_state() {
    local instance_id="$1"
    local target="$2"
    echo "Waiting for instance to reach '$target'..."
    aws ec2 wait "instance-${target}" \
        --instance-ids "$instance_id" \
        --region "$REGION"
    echo "Instance is now $target."
}

_vpc_id_from_subnet() {
    aws ec2 describe-subnets \
        --subnet-ids "$SUBNET_ID" \
        --region "$REGION" \
        --query 'Subnets[0].VpcId' \
        --output text
}

_ensure_security_group() {
    local vpc_id
    vpc_id=$(_vpc_id_from_subnet)

    local sg_id
    sg_id=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" "Name=vpc-id,Values=${vpc_id}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null)

    if [ "$sg_id" = "None" ] || [ -z "$sg_id" ]; then
        echo "Creating security group '${SECURITY_GROUP_NAME}' in VPC ${vpc_id}..."
        sg_id=$(aws ec2 create-security-group \
            --group-name "$SECURITY_GROUP_NAME" \
            --description "OmniParser inference server" \
            --vpc-id "$vpc_id" \
            --region "$REGION" \
            --query 'GroupId' \
            --output text)

        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --region "$REGION" \
            --protocol tcp --port 22 --cidr 0.0.0.0/0

        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --region "$REGION" \
            --protocol tcp --port 8000 --cidr 0.0.0.0/0

        echo "Security group created: $sg_id (SSH + port 8000 open)"
    else
        echo "Using existing security group: $sg_id"
    fi
    echo "$sg_id"
}

_resolve_ami() {
    echo "Finding latest Deep Learning GPU AMI..." >&2
    local ami_id
    ami_id=$(aws ec2 describe-images \
        --region "$REGION" \
        --owners amazon \
        --filters \
            "Name=name,Values=Deep Learning OSS Nvidia Driver AMI GPU PyTorch * (Amazon Linux 2023)*" \
            "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)
    if [ "$ami_id" = "None" ] || [ -z "$ami_id" ]; then
        echo "ERROR: Could not find Deep Learning GPU AMI in $REGION." >&2
        exit 1
    fi
    echo "$ami_id"
}

# ---------------------------------------------------------------------------
# User-data script that runs on first boot to set up the instance
# ---------------------------------------------------------------------------
_user_data() {
    cat <<'USERDATA'
#!/bin/bash
set -ex

# Install Docker (official repo for latest buildx support)
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker && systemctl start docker
usermod -aG docker ec2-user

# Install NVIDIA Container Toolkit
dnf config-manager --add-repo https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
dnf install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

echo "=== OmniParser instance setup complete ==="
USERDATA
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_create() {
    _require_aws_cli
    _require_key_name
    _require_subnet

    if [ -f "$STATE_FILE" ]; then
        echo "WARNING: Instance already tracked ($(cat "$STATE_FILE")). Use 'status' or 'terminate' first." >&2
        exit 1
    fi

    AMI_ID=$(_resolve_ami)
    echo "AMI: $AMI_ID"

    SG_ID=$(_ensure_security_group | tail -1)

    echo "Launching ${INSTANCE_TYPE} in subnet ${SUBNET_ID}..."
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SG_ID" \
        --subnet-id "$SUBNET_ID" \
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${VOLUME_SIZE},VolumeType=gp3}" \
        --user-data "$(_user_data)" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=omniparser-server}]" \
        --region "$REGION" \
        --query 'Instances[0].InstanceId' \
        --output text)

    _save_instance_id "$INSTANCE_ID"
    echo "Instance launched: $INSTANCE_ID"

    _wait_for_state "$INSTANCE_ID" "running"

    IP=$(_get_instance_ip "$INSTANCE_ID")
    echo ""
    echo "========================================"
    echo " Instance is running!"
    echo " IP: $IP"
    echo " SSH: ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${IP}"
    echo ""
    echo " Wait ~3-5 min for user-data setup to finish, then run:"
    echo "   $0 deploy"
    echo "========================================"
}

cmd_start() {
    _require_aws_cli
    local instance_id
    instance_id=$(_load_instance_id)
    echo "Starting instance $instance_id..."
    aws ec2 start-instances --instance-ids "$instance_id" --region "$REGION" > /dev/null
    _wait_for_state "$instance_id" "running"
    IP=$(_get_instance_ip "$instance_id")
    echo "Instance running at $IP"
    echo "API will be available at http://${IP}:8000/probe/"
}

cmd_stop() {
    _require_aws_cli
    local instance_id
    instance_id=$(_load_instance_id)
    echo "Stopping instance $instance_id..."
    aws ec2 stop-instances --instance-ids "$instance_id" --region "$REGION" > /dev/null
    _wait_for_state "$instance_id" "stopped"
    echo "Instance stopped. EBS volume preserved. No compute charges."
}

cmd_terminate() {
    _require_aws_cli
    local instance_id
    instance_id=$(_load_instance_id)
    echo "This will permanently delete instance $instance_id and its EBS volume."
    read -r -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        aws ec2 terminate-instances --instance-ids "$instance_id" --region "$REGION" > /dev/null
        rm -f "$STATE_FILE"
        echo "Instance terminated."
    else
        echo "Cancelled."
    fi
}

cmd_status() {
    _require_aws_cli
    local instance_id
    instance_id=$(_load_instance_id)
    echo "Instance: $instance_id"
    _get_instance_info "$instance_id"
}

cmd_ssh() {
    _require_aws_cli
    _require_key_name
    local instance_id
    instance_id=$(_load_instance_id)
    IP=$(_get_instance_ip "$instance_id")
    if [ "$IP" = "None" ] || [ -z "$IP" ]; then
        echo "ERROR: Instance has no IP. Is it running?" >&2
        exit 1
    fi
    echo "Connecting to ec2-user@${IP}..."
    ssh -o StrictHostKeyChecking=no -i "${HOME}/.ssh/${KEY_NAME}.pem" "ec2-user@${IP}" "${@:1}"
}

cmd_deploy() {
    _require_aws_cli
    _require_key_name
    local instance_id
    instance_id=$(_load_instance_id)
    IP=$(_get_instance_ip "$instance_id")
    if [ "$IP" = "None" ] || [ -z "$IP" ]; then
        echo "ERROR: Instance has no IP. Is it running?" >&2
        exit 1
    fi

    if [ -z "$GH_TOKEN" ]; then
        echo "ERROR: Set OMNI_GH_TOKEN to a GitHub personal access token with repo scope" >&2
        echo "       (required to clone the private repo)." >&2
        exit 1
    fi

    local auth_repo_url
    auth_repo_url=$(echo "$REPO_URL" | sed "s|https://|https://${GH_TOKEN}@|")

    SSH_CMD="ssh -o StrictHostKeyChecking=no -i ${HOME}/.ssh/${KEY_NAME}.pem ec2-user@${IP}"

    echo "Deploying OmniParser to ${IP}..."

    $SSH_CMD bash -s <<REMOTE
set -ex

# Clone or update the repo
if [ ! -d ~/OmniParser ]; then
    git clone ${auth_repo_url} ~/OmniParser
else
    cd ~/OmniParser
    git remote set-url origin ${auth_repo_url}
    git pull
fi

cd ~/OmniParser

# Download model weights if not present
export PATH="\$HOME/.local/bin:\$PATH"
if [ ! -f weights/icon_detect/model.pt ]; then
    echo "Installing HuggingFace CLI..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    curl -LsSf https://hf.co/cli/install.sh | bash
    export PATH="\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH"

    echo "Downloading model weights..."
    for f in \
        icon_detect/train_args.yaml \
        icon_detect/model.pt \
        icon_detect/model.yaml \
        icon_caption/config.json \
        icon_caption/generation_config.json \
        icon_caption/model.safetensors; do
        hf download microsoft/OmniParser-v2.0 "\$f" --local-dir weights
    done
    mv weights/icon_caption weights/icon_caption_florence
fi

# Install Docker CE with buildx + compose from official repo
if ! docker buildx version 2>&1 | grep -qE 'v0\.(1[7-9]|[2-9][0-9])'; then
    echo "Installing Docker CE..."
    sudo dnf install -y dnf-plugins-core
    sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo sed -i 's/\$releasever/9/g' /etc/yum.repos.d/docker-ce.repo
    sudo dnf install -y --allowerasing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable docker && sudo systemctl start docker
    sudo usermod -aG docker ec2-user
fi

# Build and start with Docker Compose
docker compose -f docker-compose.gpu.yml up --build -d

echo "Waiting for server to be ready..."
for i in \$(seq 1 30); do
    if curl -sf http://localhost:8000/probe/ > /dev/null 2>&1; then
        echo "OmniParser server is ready!"
        exit 0
    fi
    sleep 5
done
echo "WARNING: Server did not become ready within 150s. Check logs with: docker compose -f docker-compose.gpu.yml logs"
REMOTE

    echo ""
    echo "========================================"
    echo " Deploy complete!"
    echo " API endpoint: http://${IP}:8000"
    echo " Health check: curl http://${IP}:8000/probe/"
    echo " Parse:        curl -X POST http://${IP}:8000/parse/ -H 'Content-Type: application/json' -d '{\"base64_image\": \"...\"}'"
    echo "========================================"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-help}" in
    create)    cmd_create ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    terminate) cmd_terminate ;;
    status)    cmd_status ;;
    ssh)       shift; cmd_ssh "$@" ;;
    deploy)    cmd_deploy ;;
    *)
        echo "Usage: $0 {create|start|stop|terminate|status|ssh|deploy}"
        echo ""
        echo "Commands:"
        echo "  create     Launch a new g4dn.xlarge GPU instance"
        echo "  start      Start a stopped instance"
        echo "  stop       Stop the instance (no compute cost, EBS preserved)"
        echo "  terminate  Permanently delete the instance"
        echo "  status     Show instance state and IP"
        echo "  ssh        SSH into the instance (extra args passed to ssh)"
        echo "  deploy     Clone/update repo, download weights, build & start server"
        echo ""
        echo "Environment variables:"
        echo "  OMNI_KEY_NAME        EC2 key pair name (required)"
        echo "  OMNI_SUBNET_ID       Subnet to launch into (required)"
        echo "  OMNI_GH_TOKEN        GitHub PAT with repo scope (required for deploy)"
        echo "  OMNI_INSTANCE_TYPE   Instance type (default: g4dn.xlarge)"
        echo "  OMNI_VOLUME_SIZE     EBS volume size in GB (default: 150)"
        echo "  OMNI_REPO_URL        Git repo URL (default: Frontier-Health/OmniParser)"
        echo "  AWS_DEFAULT_REGION   AWS region (default: eu-west-2)"
        exit 1
        ;;
esac
