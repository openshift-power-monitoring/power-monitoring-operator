#!/usr/bin/env bash

# copyright 2024.
#
# licensed under the apache license, version 2.0 (the "license");
# you may not use this file except in compliance with the license.
# you may obtain a copy of the license at
#
#     http://www.apache.org/licenses/license-2.0
#
# unless required by applicable law or agreed to in writing, software
# distributed under the license is distributed on an "as is" basis,
# without warranties or conditions of any kind, either express or implied.
# see the license for the specific language governing permissions and
# limitations under the license.
#

set -eu -o pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
declare -r PROJECT_ROOT

declare -r POWERMON_BUNDLE="power-monitoring-operator-bundle-container"
declare -r TMP_DIR="$PROJECT_ROOT/tmp"
declare -r BIN_DIR="$TMP_DIR/bin"
declare -r OCP_VERSION=${OCP_VERSION:-'v4.13'}

declare INDEX_IMG=""

source "$PROJECT_ROOT/hack/utils.bash"

ensure_all_tools() {
	header "Ensuring all tools are installed"
	"$PROJECT_ROOT/hack/tools.sh" all
}

validate_podman() {
	header "Validating podman"

	command -v podman >/dev/null 2>&1 || {
		fail "No podman found"
		info "Please install podman or make sure its running"
		return 1
	}
}

get_index_image() {
	header "Fetch index image"
	local url="https://datagrepper.engineering.redhat.com/raw?topic=/topic/VirtualTopic.eng.ci.redhat-container-image.index.built&delta=824000&contains=$POWERMON_BUNDLE"
	local ret=0

	INDEX_IMG=$(curl -s "$url" |
		jq --arg requested_ocp_version "$OCP_VERSION" -r \
			'.raw_messages[] |
      select(.msg.index.ocp_version == $requested_ocp_version) |
        .msg.index.index_image' |
		head -n 1 | awk -F':' '{print "brew.registry.redhat.io/rh-osbs/iib:"$2}')

	[[ -n $INDEX_IMG && $INDEX_IMG != "null" ]] || {
		ret=1
		err "No matching index image found. Please check if provided OCP version is available or connected to VPN!"
		return $ret
	}
	ok "Using index image: $INDEX_IMG"
	return $ret

}

add_brew_registry() {
	header "Getting credentials for brew registry"
	local url="https://employee-token-manager.registry.redhat.com/v1/tokens"
	local ret=0

	! token=$(curl --negotiate -u : $url -s) || [[ -z $token ]] || [[ $token == "null" ]] && {
		ret=1
		err "Could not get token. Please use the following command to create a token and retry the script. Make sure to be connected on VPN:
curl --negotiate -u : -X POST -H 'Content-Type: application/json' --data '{\"description\":\"for testing cpaas built powermon images on openshift cluster\"}' $url -s"
		return $ret
	}

	ok "Found token..."

	username=$(echo "$token" | jq 'last' | jq -r '.credentials.username')
	password=$(echo "$token" | jq 'last' | jq -r '.credentials.password')

	info "Getting auth from cluster"
	run oc get secret/pull-secret -n openshift-config -o json |
		jq -r '.data.".dockerconfigjson"' | base64 -d >"$TMP_DIR/authfile"

	info "Logging to brew registry"
	run podman login --authfile "$TMP_DIR/authfile" --username "$username" --password "$password" brew.registry.redhat.io || {
		ret=1
		fail "Logging to brew registry failed"
		return $ret
	}

	info "Set auth to cluster"
	run oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="$TMP_DIR/authfile"

	return $ret
}

create_icsp() {
	header "Creating ImageContentSourcePolicy to mirror images.."
	run oc apply -f - <<EOF
  apiVersion: operator.openshift.io/v1alpha1
  kind: ImageContentSourcePolicy
  metadata:
    name: brew-registry
  spec:
    repositoryDigestMirrors:
    - mirrors:
      - brew.registry.redhat.io
      source: registry.redhat.io
    - mirrors:
      - brew.registry.redhat.io
      source: registry.stage.redhat.io
    - mirrors:
      - brew.registry.redhat.io
      source: registry-proxy.engineering.redhat.com
EOF
}

add_catalog_source() {
	header "Adding CatalogSource for power monitoring with index Image..."
	run oc apply -f - <<EOF
  apiVersion: operators.coreos.com/v1alpha1
  kind: CatalogSource
  metadata:
    name: powermon-operator-catalog
    namespace: openshift-marketplace
  spec:
    sourceType: grpc
    image: $INDEX_IMG
    displayName: Openshift Power Monitoring
    publisher: Power Mon RC Images
EOF
}

main() {
	export PATH="$BIN_DIR:$PATH"
	ensure_all_tools

	validate_podman || {
		line 60 heavy
		fail "Fix issues reported above and rerun the script"
		return 1
	}

	export OCP_VERSION
	get_index_image || {
		line 60 heavy
		die "Fail to get index image"
	}
	add_brew_registry || {
		line 60 heavy
		die "Fail to add brew registry"
	}
	create_icsp
	add_catalog_source

	header "All Done"
}

main "$@"
