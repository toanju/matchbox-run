#!/bin/bash

set -Eeuo pipefail

# setup error trap
trap 'echo "An error occurred in line ${LINENO}. Exiting..."; exit 1' ERR

MATCHBOX_IMAGE="quay.io/poseidon/matchbox:v0.11.0"
MATCHBOX_IP="10.10.10.1"
MATCHBOX_DOMAIN="matchbox.lan"

CERTS_DIR="certs"

FLATCAR_CHANNEL=beta

UEFI_FW_REPO="toanju/RPi4"
UEFI_FW_DIR=lib/assets/uefi
UEFI_FW_VERSIONFILE=latest-version

ARCH=arm64

CONTAINER_RUNTIME="$(command -v podman || command -v ctr || command -v docker)"
if [[ -z "${CONTAINER_RUNTIME}" ]]; then
  echo "No container runtime found. Please install Podman containerd or Docker."
  exit 1
fi

if [[ "$CONTAINER_RUNTIME" == *ctr ]]
then
  CONTAINER_RUNTIME_ARGS=" --net-host "
  ID="matchbox"
else
  CONTAINER_RUNTIME_ARGS=" --net=host "
  ID=""
fi

function download_uefi_firmware() {
  UEFI_FW_VERSION=$(curl --silent "https://api.github.com/repos/${UEFI_FW_REPO}/releases/latest" | jq -r .tag_name)
  # check if FW version file exists and matches the latest version
  if [[ -f ${UEFI_FW_DIR}/${UEFI_FW_VERSIONFILE} ]]; then
    CURRENT_VERSION=$(cat ${UEFI_FW_DIR}/${UEFI_FW_VERSIONFILE})
    if [[ "${CURRENT_VERSION}" == "${UEFI_FW_VERSION}" ]]; then
      echo "UEFI firmware is already up to date: ${CURRENT_VERSION}"
      return
    else
      echo "Updating UEFI firmware from ${CURRENT_VERSION} to ${UEFI_FW_VERSION}"
    fi
  fi
  mkdir -p ${UEFI_FW_DIR}
  pushd ${UEFI_FW_DIR} || exit 1
    curl -sLO "https://github.com/${UEFI_FW_REPO}/releases/download/${UEFI_FW_VERSION}/RPi4_UEFI_Firmware_${UEFI_FW_VERSION}.zip"
    echo "$UEFI_FW_VERSION" > $UEFI_FW_VERSIONFILE
  popd || exit 2
}

function create_tls_certs() {
  if [[ -d ${CERTS_DIR} ]]; then
    echo "Directory ${CERTS_DIR} already exists, skipping TLS cert generation."
    return
  fi
  mkdir -p ${CERTS_DIR}
  pushd ${CERTS_DIR} || exit 1
    curl -sOL https://raw.githubusercontent.com/poseidon/matchbox/main/scripts/tls/cert-gen
    curl -sOL https://raw.githubusercontent.com/poseidon/matchbox/main/scripts/tls/openssl.conf
    chmod 755 cert-gen

    export SAN=DNS.1:${MATCHBOX_DOMAIN},IP.1:${MATCHBOX_IP}
    ./cert-gen
  popd || exit 2
}

function download_flatcar() {
  # check current release version
  eval "$(curl -s "https://${FLATCAR_CHANNEL}.release.flatcar-linux.net/${ARCH}-usr/current/version.txt" | grep FLATCAR_VERSION=)"
  if [[ -z "${FLATCAR_VERSION}" ]]; then
    echo "Failed to determine Flatcar version from version.txt."
    exit 1
  fi
  if [[ -d "./lib/assets/flatcar/${FLATCAR_VERSION}" ]]; then
    echo "Flatcar version ${FLATCAR_VERSION} already exists, skipping download."
    return
  fi
 
  ./get-flatcar "${FLATCAR_CHANNEL}" "$FLATCAR_VERSION" ./lib/assets "$ARCH"
}

# start here
create_tls_certs
download_uefi_firmware
download_flatcar

sudo $CONTAINER_RUNTIME image pull "$MATCHBOX_IMAGE"
if [[ "$CONTAINER_RUNTIME" == *ctr ]]
then
  sudo $CONTAINER_RUNTIME run $CONTAINER_RUNTIME_ARGS --rm -t --mount type=bind,src="$PWD"/lib,dst=/var/lib/matchbox,options=rbind:rw --mount type=bind,src="$PWD/$CERTS_DIR",dst=/etc/matchbox,options=rbind:ro "$MATCHBOX_IMAGE" matchbox /matchbox -address=0.0.0.0:8080 -rpc-address=0.0.0.0:8081 -log-level=debug
else
  sudo $CONTAINER_RUNTIME run $CONTAINER_RUNTIME_ARGS --rm -ti -v ./lib:/var/lib/matchbox:Z -v ./$CERTS_DIR:/etc/matchbox:Z,ro "$MATCHBOX_IMAGE" -address=0.0.0.0:8080 -rpc-address=0.0.0.0:8081 -log-level=debug
fi
