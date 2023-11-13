#!/usr/bin/env bash

# Copyright 2023 tsuru authors. All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.
set -eu -o pipefail

[[ -n ${DEBUG:-} ]] && set -x

readonly DOCKER=${DOCKER:-docker}
readonly HELM=${HELM:-helm}
readonly KIND=${KIND:-kind}
readonly KUBECTL=${KUBECTL:-kubectl}
readonly TSURU=${TSURU:-./bin/tsuru}
readonly MINIKUBE=${MINIKUBE:-minikube}

readonly CLUSTER_PROVIDER=${CLUSTER_PROVIDER:-kind}
readonly NAMESPACE=${NAMESPACE:-tsuru-system}

readonly CHART_VERSION_TSURU_STACK=${CHART_VERSION_TSURU_STACK:-0.5.3}

function onerror() {
  echo "TSURU API LOGS:"
  ${KUBECTL} logs -n ${NAMESPACE} deploy/tsuru-api|| true
  echo

  [[ -n ${kubectl_port_forward_pid} ]] && kill ${kubectl_port_forward_pid}
}

install_tsuru_stack() {
  ${HELM} repo add --force-update tsuru https://tsuru.github.io/charts

  ${HELM} install --create-namespace \
    --namespace ${NAMESPACE} --version ${CHART_VERSION_TSURU_STACK} \
    --set tsuru-api.image.repository=localhost/tsuru/tsuru-api \
    --set tsuru-api.image.tag=integration \
    --set tsuru-api.image.pullPolicy=Never \
    tsuru tsuru/tsuru-stack
}

build_tsuru_api_container_image() {
  ${DOCKER} build -t localhost/tsuru/tsuru-api:integration -f Dockerfile .

  case ${CLUSTER_PROVIDER} in
    minikube)
      ${DOCKER} save localhost/tsuru/tsuru-api:integration | ${MINIKUBE} image load -
      ;;

    kind)
      ${DOCKER} save "localhost/tsuru/tsuru-api:integration" -o "tsuru-api.tar"
      ${KIND} load image-archive "tsuru-api.tar"
      rm "tsuru-api.tar"
      ;;
    *)
      print "Invalid local cluster provider (got ${CLUSTER_PROVIDER}, supported: kind, minikube)" >&2
      exit 1;;
  esac
}

set_initial_admin_password() {
  ${KUBECTL} exec -it -n ${NAMESPACE} deploy/tsuru-api -- \
    "echo $'123456\n123456' | tsurud root user create admin@admin.com"
}

main() {
  ${KUBECTL} cluster-info
  ${KUBECTL} get all

  ${KUBECTL} get namespace ${NAMESPACE} >/dev/null 2>&1 || \
    ${KUBECTL} create namespace ${NAMESPACE}

  build_tsuru_api_container_image

  install_tsuru_stack

  sleep 5

  trap onerror ERR

  local_tsuru_api_port=8080
  ${KUBECTL} -n ${NAMESPACE} port-forward svc/tsuru-api ${local_tsuru_api_port}:80 --address=127.0.0.1 &
  kubectl_port_forward_pid=${!}

  sleep 5

  curl -fsSL "https://tsuru.io/get" | bash
  set_initial_admin_password 

  TSURU_TARGET="http://127.0.0.1:${local_tsuru_api_port}" 
  echo "123456" | ${TSURU} login admin@admin.com

  kill ${kubectl_port_forward_pid}
}

main $@
