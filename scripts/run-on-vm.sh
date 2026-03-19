#!/bin/bash
set -x
set -euo pipefail

VM_IP=$1

# Navigate to the directory where this script is located
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "Now in: $(pwd)"

# Ensure Go modules mode is always used
export GO111MODULE=on
export GOMAXPROCS=$(nproc)

source ./install-tools.sh

# refresh bashrc
export BASHRCSOURCED=1
source ~/.bashrc

# cleaning go deps
go mod tidy
go mod vendor

# Clean containers
kind delete cluster --name kind-netdevsim || true
podman rm -f switch1 || true

# Build images
cd ../ptp-tools
# configure images for local registry
export IMG_PREFIX="$VM_IP/test"

# Clean all images and manifests
make -j 5 podman-cleanall

# Build images
make -j 5 podman-buildall
cd -

# build kustomize
cd ..
make kustomize
cd -
./create-local-registry.sh "$VM_IP"

# push images
cd ../ptp-tools
make -j 5 podman-pushall
cd -

# deploy kind cluster
./k8s-start.sh "$VM_IP"

# deploy ptp-operator
cd ../ptp-tools
# Start deployment, it will fail because it is missing certs
make deploy-all || true
sleep 5
cd -

# Build certificates
kubectl apply -f certs.yaml

# Fix certificates
./retry.sh 60 5 ./fix-certs.sh
sleep 5

# delete ptp-operator pod
kubectl delete pods -l name=ptp-operator -n openshift-ptp

# wait for operator to come up
kubectl rollout status deployment ptp-operator -n openshift-ptp

# Patch ptpoperatorconfig - use emptyDir for storage (local-path PVCs can't be shared across DaemonSet nodes)
if ! kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"ptpEventConfig": {"enableEventPublisher": true, "transportHost": "http://ptp-event-publisher-service-NODE_NAME.openshift-ptp.svc.cluster.local:9043", "storageType": "emptyDir"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}' 2>/dev/null; then
    echo "Events config failed (may not be supported in this release), trying basic config..."
    if ! kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"ptpEventConfig": {"enableEventPublisher": true, "transportHost": "http://ptp-event-publisher-service-NODE_NAME.openshift-ptp.svc.cluster.local:9043"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}' 2>/dev/null; then
        echo "Events config not supported, using basic daemonNodeSelector only..."
        kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}'
    fi
fi

./retry.sh 30 3 kubectl rollout status ds linuxptp-daemon -n openshift-ptp

# Fix prometheus monitoring
./fix-ptp-prometheus-monitoring.sh

kubectl get pods -n openshift-ptp -o wide

# run tests
./run-tests.sh --kind serial --mode oc,bc,dualnicbc,dualnicbcha,dualfollower --linuxptp-daemon-image "$VM_IP/test:lptpd"
