#!/usr/bin/env bash

set -e

# TODO: assert required tools (oc, yq, curl, git, kubectl, kubectl-package)

function log() {
	echo "[bundle] ${1}"
}

_BUNDLE_REGISTRY=ghcr.io/jbpratt/managed-openshift/release-bundle

OPERATOR=$1
COMMIT=$2
TEMPLATE=https://raw.githubusercontent.com/openshift/${OPERATOR}/${COMMIT}/hack/olm-registry/olm-artifacts-template.yaml

# TODO: values should come from operator build pipeline
REGISTRY_IMG=quay.io/app-sre/${OPERATOR}-registry
IMAGE_TAG=staging-latest
IMAGE_DIGEST=$(skopeo inspect --format '{{.Digest}}' docker://"${REGISTRY_IMG}":"${IMAGE_TAG}" | tr -d "\r")
CHANNEL=${IMAGE_TAG%%-*}

_OUTDIR=resources/${OPERATOR}
rm -rf "${_OUTDIR}" && mkdir -p "${_OUTDIR}"

log "Downloading template..."
_RAW_TEMPLATE=$(curl -sL "${TEMPLATE}" | sed 's/apiVersion: v1/apiVersion: template.openshift.io\/v1/')

log "Process template with parameters..."
_PROCESSED_TEMPLATE=$(oc process \
	--local \
	--output=yaml \
	--ignore-unknown-parameters \
	--filename \
	"${TEMPLATE}" \
	REGISTRY_IMG="${REGISTRY_IMG}" \
	CHANNEL="${CHANNEL}" \
	IMAGE_TAG="${IMAGE_TAG}" \
	IMAGE_DIGEST="${IMAGE_DIGEST}" <<<"${_RAW_TEMPLATE}")

log "Appending 'package-operator.run/phase' to every object and writing to ${_OUTDIR} ..."
yq "
    .items[0].spec.resources[] |
    select(.kind!=\"Namespace\") |
    .metadata.annotations += {\"package-operator.run/phase\":\"${OPERATOR}\"} |
    split_doc" <<<"${_PROCESSED_TEMPLATE}" >"${_OUTDIR}"/resources.yaml
yq "
    .items[0].spec.resources[] |
    select(.kind==\"Namespace\") |
    .metadata.annotations += {\"package-operator.run/phase\": \"namespaces\"}" <<<"${_PROCESSED_TEMPLATE}" >"${_OUTDIR}"/namespace.yaml

# add new operator phase if it doesn't exist
if ! grep -q "${OPERATOR}" resources/manifest.yaml; then
	yq -i ".spec.phases += {\"name\": \"${OPERATOR}\"}" resources/manifest.yaml
fi

git add "${_OUTDIR}" resources/manifest.yaml

if git diff --quiet --exit-code --cached; then
	log "No changes" && exit 1
fi

log "Committing changes..."
git commit --quiet --message "${OPERATOR}: ${COMMIT:1:7}"
# git push

_BRANCH=$(git rev-parse --abbrev-ref HEAD)
_COMMIT=$(git rev-parse --short HEAD)
_BUILD_NUMBER=$(git rev-list --count HEAD)
_TAG=${_BUNDLE_REGISTRY}:${_BRANCH/#release-/}-${_BUILD_NUMBER}-${_COMMIT}

log "Building and pushing package ${_TAG} ..."
kubectl package build --push --tag "${_TAG}" ./resources

cat <<EOF
apiVersion: package-operator.run/v1alpha1
kind: ClusterPackage
metadata:
  name: managed-openshift-release-bundle
spec:
  image: ${_TAG}
EOF
