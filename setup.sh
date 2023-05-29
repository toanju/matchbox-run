#!/bin/bash

set -euo pipefail

MATCHBOX_IMAGE="quay.io/poseidon/matchbox:v0.10.0"
CERTS_DIR="certs"

UEFI_FW_DIR=lib/assets/uefi
UEFI_FW_VERSIONFILE=latest-version
UEFI_FW_VERSION=$(curl --silent "https://api.github.com/repos/pftf/RPi4/releases/latest" | jq -r .tag_name)

function download_uefi_firmware() {
  pushd ${UEFI_FW_DIR} || exit 1
  curl -sLO "https://github.com/pftf/RPi4/releases/download/${UEFI_FW_VERSION}/RPi4_UEFI_Firmware_${UEFI_FW_VERSION}.zip"
  popd || exit 2
}

function write_firmware_versionfile() {
  pushd $UEFI_FW_DIR || exit 1
    echo "$UEFI_FW_VERSION" > $UEFI_FW_VERSIONFILE
  popd || exit 2
}

function create_tls_certs() {
  pushd ${CERTS_DIR} || exit 1
    curl -sOL https://raw.githubusercontent.com/poseidon/matchbox/main/scripts/tls/cert-gen
    curl -sOL https://raw.githubusercontent.com/poseidon/matchbox/main/scripts/tls/openssl.conf
    chmod 755 cert-gen

    export SAN=DNS.1:matchbox.lan,IP.1:10.10.10.1
    ./cert-gen

  popd || exit 2
}

mkdir -p ${UEFI_FW_DIR} ${CERTS_DIR}
download_uefi_firmware
write_firmware_versionfile
create_tls_certs

./get-flatcar beta current ./lib/assets arm64

eval "$(grep FLATCAR_VERSION= lib/assets/flatcar/current/version.txt)"
rsync -av ./lib/assets/flatcar/current/* "./lib/assets/flatcar/$FLATCAR_VERSION/"

podman run --net=host --rm -v ./lib:/var/lib/matchbox:Z -v ./$CERTS_DIR:/etc/matchbox:Z,ro "$MATCHBOX_IMAGE" -address=0.0.0.0:8080 -rpc-address=0.0.0.0:8081 -log-level=debug
