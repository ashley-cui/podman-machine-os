#!/bin/bash

set -exo pipefail

source ./util.sh

echo "Preparing to build ${FULL_IMAGE_NAME}"

# Freeze on specific commit to increase stability.
# Renovate is configured to update to a new commit so do not update the format
# without updating the renovate config, see .github/renovate.json5.
gitreporef="561349037d798c14c12b77523d1320bbfb903f34"
gitrepotld="https://raw.githubusercontent.com/coreos/custom-coreos-disk-images/${gitreporef}/"
curl -LO --fail "${gitrepotld}/custom-coreos-disk-images.sh"

echo " Building image locally"

# Validate PODMAN_PR_NUM var, see the Containerfile for the pull logic.
case "${PODMAN_PR_NUM}" in
  '') echo "Will install podman from the podman-next copr, the podman version is ignored" ;;
  [0-9]*) ;;
  *) echo 'PODMAN_PR_NUM must be empty or set to a valid PR number' 1>&2; exit 1;;
esac

# koji tags prepend "f" to the release (rpm --eval)
FEDORA_VERSION="f"$(podman run --rm "$FCOS_BASE_IMAGE" rpm --eval '%{?fedora}')
export FEDORA_VERSION

# Don't fail if koji download-build can't find any rpms
set +e
if [[ ${PODMAN_PR_NUM} != "" ]]; then
    mkdir -p ./rpms
    pushd ./rpms
    for pkg in container-selinux crun;
    do
        for tag in "${FEDORA_VERSION}"-updates-candidate "${FEDORA_VERSION}"-updates-testing "${FEDORA_VERSION}"-updates-testing-pending;
        do
            koji download-build --latestfrom="$tag" -a "$(arch)" -a noarch "$pkg"
            if [[ $? -eq 1 ]]; then
                echo "Continuing..."
                continue
            fi
        done
    done
    for pkg in aardvark-dns containers-common netavark;
    do
        for tag in $(koji list-sidetags --user=packit | grep "${FEDORA_VERSION}")
        do
            koji download-build --latestfrom="$tag" -a "$(arch)" -a noarch "$pkg"
            if [[ $? -eq 1 ]]; then
                echo "Continuing..."
                continue
            fi
        done
    done
    rm -f crun-krun*.rpm crun-wasm*.rpm
    popd
fi
set -e

# See podman-rpm-info-vars.sh for all build-arg values. If PODMAN_PR_NUM is
# empty, the rpm version, release and fedora release values are of no concern
# to the build process.
podman build -t "${FULL_IMAGE_NAME_ARCH}" -f podman-image/Containerfile "${PWD}"/podman-image \
    --build-arg FCOS_BASE_IMAGE="${FCOS_BASE_IMAGE}" \
    --build-arg PODMAN_PR_NUM="${PODMAN_PR_NUM}" \
    --build-arg FEDORA_VERSION="${FEDORA_VERSION}"

echo "Saving image from image store to filesystem"

mkdir -p "$OUTDIR"
podman save --format oci-archive -o "${OUTDIR}/${DISK_IMAGE_NAME}" "${FULL_IMAGE_NAME_ARCH}"

echo "Transforming OCI image into disk image"
pushd "$OUTDIR" && sh "$SRCDIR"/custom-coreos-disk-images.sh \
  --platforms applehv,hyperv,qemu \
  --ociarchive "${PWD}/${DISK_IMAGE_NAME}" \
  --osname fedora-coreos \
  --imgref "ostree-remote-registry:fedora:$FULL_IMAGE_NAME" \
  --metal-image-size 6144 \
  --extra-kargs='ostree.prepare-root.composefs=0'


declare -A COREOS_PLATFORM_SUFFIX=(
    ['applehv']='raw'
    ['hyperv']='vhdx'
    ['qemu']='qcow2'
)

echo "Compressing disk images with zstd"
# note: we are still "in" the outdir at this point
for hypervisor in "${!COREOS_PLATFORM_SUFFIX[@]}"; do
  # Rename the file to our preferred format
  extension="${COREOS_PLATFORM_SUFFIX[$hypervisor]}"
  filename="${DISK_IMAGE_NAME}-${hypervisor}.${CPU_ARCH}.${extension}"
  newfilename="${DISK_IMAGE_NAME}.${CPU_ARCH}.${hypervisor}.${extension}"
  mv "$filename" "$newfilename"

  # Compress the file
  zstd --rm -T0 -14 "$newfilename"
done

popd
