#!/bin/bash
#
# Deploy OpenStack Helm in a target VM or local environment.

set -ex

if [[ $UID != 0 ]]; then
  echo Script must be run as root, exiting.
  exit 1
fi

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
BASEDIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
cd "${BASEDIR}"

# Update apt cache if needed
if [ ! -f /var/lib/apt/periodic/update-success-stamp ] || \
     sudo find /var/lib/apt/periodic/update-success-stamp -mtime +1 | grep update-success-stamp; then
     sudo -E apt -y update
fi

# OpenStack release
: ${VM_NAME:=victoria}
# Target VM ubuntu version
: ${VM_UBUNTU_VERSION:=bionic}


# set memory for host VM
: ${RAM:=32000}
# Set vCPU for host VM
: ${vCPU:=$(nproc)}
# Set disk size
: ${disk_size:=128G}

# check if vm meets the minimum host requirements
# The ouput disk_size is defined in GB
disk_size=$(echo $(df -H / | grep /dev |awk '{print $2}'))
disk_size=$(echo $(echo $disk_size | tr -d 'G'))
vCPU=$(echo $(nproc))
RAM=$(echo $( free | grep Mem | awk '{print $2}'))
if [[ $disk_size -lt 128 && $vCPU -lt 8 && $RAM -lt 32882868 ]]; then
  echo "Minimum requirements not satisfied"
  exit 1
else
  echo "Proceeding with installation"
fi

# enable ipv4 forwarding
sysctl net.ipv4.ip_forward=1

cat <<'END' > ./tgthost_script.sh

#!/bin/bash

set -ex

STARTTIME=`date +%H:%M`
echo $STARTTIME

# Install az cli
if command -v az; then
  echo az cli already installed;
else
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
fi


# Set hostname and FQDN
hostname gatestack
echo 'gatestack' >  /etc/hostname
if ! grep gatestack /etc/hosts; then
  echo '127.0.1.1 gatestack' >> /etc/hosts
fi

# Update apt cache if needed
if [ ! -f /var/lib/apt/periodic/update-success-stamp ] || \
     sudo find /var/lib/apt/periodic/update-success-stamp -mtime +1 | grep update-success-stamp; then
     sudo -E apt -y update
fi

apt -y install git curl make wget

if [[ ! -d openstack-helm-infra ]]; then
  while ! git clone "https://review.opendev.org/openstack/openstack-helm-infra"; do
    echo openstack-helm-infra clone attempt failed, retrying...
    sleep 10
  done
fi
if [[ ! -d openstack-helm ]]; then
  while ! git clone "https://review.opendev.org/openstack/openstack-helm"; do
    echo openstack-helm clone attempt failed, retrying...
    sleep 10
  done
  export PS_NUMBER="36"
  git fetch https://review.opendev.org/openstack/openstack-helm refs/changes/32/837132/$PS_NUMBER && git checkout FETCH_HEAD
fi

# Set release / distro info
export OPENSTACK_RELEASE=victoria
export CONTAINER_DISTRO_VERSION=focal
export OSH_TEST_TIMEOUT=1200
export OS_CLOUD=openstack_helm
if ! grep "export OS_CLOUD=openstack_helm" ~/.bashrc; then
 echo "export OS_CLOUD=openstack_helm" >> ~/.bashrc
fi

# Replacement for openstack-helm-infra/playbooks/osh-infra-gate-runner.yaml, since it has Zuul-exclusive roles.
apt -y install --no-install-recommends \
  python3-pip \
  libssl-dev \
  python3-dev \
  build-essential \
  jq \
  curl

pip3 install --upgrade pip
pip3 install --upgrade setuptools
pip3 install --upgrade cmd2
pip3 install --upgrade pyopenssl
pip3 install --upgrade "ansible==2.9"
pip3 install --upgrade ara==0.16.5

# Missing package install needed for 170-setup-gateway.sh
apt -y install net-tools

echo ================RESOLV_CONF_CONTENTS===============
cat /etc/resolv.conf

# Start scripts from "openstack-helm-compute-kit" job in openstack-helm repo
cd openstack-helm
./tools/deployment/common/install-packages.sh

# Create Cluster & deploy k8s
function install_docker() {
  sudo apt-get update
  sudo apt-get install ca-certificates apt-transport-https curl gnupg lsb-release -y
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg --yes
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt-get update
  sudo apt-get install docker-ce docker-ce-cli containerd.io -y
}

function install_kind() {
  sudo curl -Lo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.11.1/kind-linux-amd64
  sudo chmod +x /usr/local/bin/kind
}

function install_kubectl() {
  sudo curl -Lo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo chmod +x /usr/local/bin/kubectl
}

function install_jq() {
  sudo curl -Lo /usr/local/bin/jq "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"
  sudo chmod +x /usr/local/bin/jq
}

function install_yq() {
  sudo curl -Lo /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v4.13.0/yq_linux_amd64"
  sudo chmod +x /usr/local/bin/yq
}

function install_helm() {
  curl https://baltocdn.com/helm/signing.asc | sudo apt-key add -
  echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
  sudo apt-get update
  sudo apt-get install helm -y
}

function install() {
  if ! command -v docker >/dev/null; then
    install_docker
  fi

  if ! command -v kind >/dev/null; then
    install_kind
  fi

  if ! command -v kubectl >/dev/null; then
    install_kubectl
  fi

  if ! command -v jq >/dev/null; then
    install_jq
  fi

  if ! command -v yq >/dev/null; then
    install_yq
  fi

  if ! command -v helm >/dev/null; then
    install_helm
  fi
}

install

# Seed cluster-config file
mkdir $HOME/.kube
touch $HOME/.kube/config.yaml

cat <<EOF > $HOME/.kube/config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  ipFamily: ipv4
nodes:
- role: control-plane
EOF

# Set recommended host configuration per https://docs.openstack.org/openstack-helm/latest/install/developer/requirements-and-host-config.html#host-configuration
sed -i "s/^hosts:.*/hosts:          files dns/" ./nsswitch.conf

kind create cluster \
  --config=$HOME/.kube/config.yaml \
  --name gatestack

kubectl get pod -A
kubectl -n kube-system get pod -l k8s-app=kube-dns

# NOTE: Wait for dns to be running.
END=$(($(date +%s) + 240))
until kubectl --namespace=kube-system \
        get pods -l k8s-app=kube-dns --no-headers -o name | grep -q "^pod/coredns"; do
  NOW=$(date +%s)
  [ "${NOW}" -gt "${END}" ] && exit 1
  echo "still waiting for dns"
  sleep 10
done
kubectl -n kube-system wait --timeout=240s --for=condition=Ready pods -l k8s-app=kube-dns

# Remove stable repo, if present, to improve build time
helm repo remove stable || true

# Add labels to the core namespaces & nodes
kubectl label --overwrite namespace default name=default
kubectl label --overwrite namespace kube-system name=kube-system
kubectl label --overwrite namespace kube-public name=kube-public
kubectl label nodes --all openstack-control-plane=enabled
kubectl label nodes --all openstack-compute-node=enabled
kubectl label nodes --all openvswitch=enabled
kubectl label nodes --all linuxbridge=enabled
kubectl label nodes --all ceph-mon=enabled
kubectl label nodes --all ceph-osd=enabled
kubectl label nodes --all ceph-mds=enabled
kubectl label nodes --all ceph-rgw=enabled
kubectl label nodes --all ceph-mgr=enabled

for NAMESPACE in ceph openstack osh-infra; do
tee /tmp/${NAMESPACE}-ns.yaml << EOF
apiVersion: v1
kind: Namespace
metadata:
  labels:
    kubernetes.io/metadata.name: ${NAMESPACE}
    name: ${NAMESPACE}
  name: ${NAMESPACE}
EOF

kubectl create -f /tmp/${NAMESPACE}-ns.yaml
done

make all

# Continue Setup
./tools/deployment/common/setup-client.sh
if ! type kubectl >& /dev/null; then
  echo 'kubectl not installed, exiting!'
  exit 1
fi
#check for openstack command
if command -v openstack; then
  echo openstack installed
else
  echo openstack not installed
  exit 1
fi

./tools/deployment/component/common/ingress.sh
# Umbrella chart patchset selected by PS_NUMBER in gerrit checkout above
./tools/deployment/component/common/openstack.sh



# Mark Time-to-usability
ENDTIME=`date +%H:%M`
echo "Started:  $STARTTIME"
echo "Ended:    $ENDTIME"

# Test creation of heat stacks
./tools/deployment/developer/common/900-use-it.sh
./tools/deployment/common/force-cronjob-run.sh
END
chmod 755 tgthost_script.sh

# Run target script locally
nohup ./tgthost_script.sh >& ./logfile &
