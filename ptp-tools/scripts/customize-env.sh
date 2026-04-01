#!/bin/bash
IMG_PREFIX=$1
ENV_PATH=$2

# Get RELEASE_VERSION dynamically from version/version.go
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/../../version/version.go"
if [ -f "$VERSION_FILE" ]; then
  RELEASE_VERSION=$(grep 'Version = ' "$VERSION_FILE" | sed 's/.*"\(.*\)".*/\1/')
  RELEASE_VERSION="v${RELEASE_VERSION}"
else
  RELEASE_VERSION="v4.19.0"
fi

cat <<EOF > $ENV_PATH/env.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ptp-operator
  namespace: openshift-ptp
spec:
  template:
    spec:
      containers:
        - name: ptp-operator
          imagePullPolicy: Always
          env:
            - name: OPERATOR_NAME
              value: "ptp-operator"
            - name: RELEASE_VERSION
              value: "$RELEASE_VERSION"
            - name: LINUXPTP_DAEMON_IMAGE
              value: "$IMG_PREFIX:lptpd"
            - name: KUBE_RBAC_PROXY_IMAGE
              value: "$IMG_PREFIX:krp"
            - name: SIDECAR_EVENT_IMAGE
              value: "$IMG_PREFIX:cep"
            - name: IMAGE_PULL_POLICY
              value: "Always"
EOF