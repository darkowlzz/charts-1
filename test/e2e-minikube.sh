#!/usr/bin/env bash

set -Eeuxo pipefail

readonly REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"

enable_lio() {
    echo "Enable LIO"
    sudo apt -y update
    sudo apt -y install linux-image-extra-$(uname -r)
    sudo mount --make-rshared /sys
    docker run --name enable_lio --privileged --rm --cap-add=SYS_ADMIN -v /lib/modules:/lib/modules -v /sys:/sys:rshared storageos/init:0.1
    echo
}

run_minikube() {
    echo "Install socat and util-linux"
    sudo apt-get install -y socat util-linux
    echo

    echo "Copy nsenter tool for Ubuntu 14.04 (current travisCI build VM version)"
    # shellcheck disable=SC2046
    sudo docker run --rm -v $(pwd):/target jpetazzo/nsenter
    sudo mv -fv nsenter /usr/local/bin/
    echo

    echo "Run minikube"
    # Download kubectl, which is a requirement for using minikube.
    curl -Lo kubectl https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubectl && chmod +x kubectl && sudo mv kubectl /usr/local/bin/
    # Download minikube.
    curl -Lo minikube https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}/minikube-linux-amd64 && chmod +x minikube && sudo mv minikube /usr/local/bin/
    # TODO: remove the --bootstrapper flag once this issue is solved: https://github.com/kubernetes/minikube/issues/2704
    sudo minikube config set WantReportErrorPrompt false
    sudo -E minikube start --vm-driver=none --cpus 2 --memory 2048 --bootstrapper=localkube --kubernetes-version=${K8S_VERSION} --extra-config=apiserver.Authorization.Mode=RBAC
    # Fix the kubectl context, as it's often stale.
    # - minikube update-context
    # Wait for Kubernetes to be up and ready.
    JSONPATH='{range .items[*]}{@.metadata.name}:{range @.status.conditions[*]}{@.type}={@.status};{end}{end}'; until kubectl get nodes -o jsonpath="$JSONPATH" 2>&1 | grep -q "Ready=True"; do sleep 1; done
    echo
}

run_tillerless() {
     # -- Work around for Tillerless Helm, till Helm v3 gets released -- #
     echo "Install Tillerless Helm plugin..."
     # shellcheck disable=SC2154
     docker exec "$config_container_id" helm init --client-only
     # shellcheck disable=SC2154
     docker exec "$config_container_id" helm plugin install https://github.com/rimusz/helm-tiller
     # shellcheck disable=SC2154
     docker exec "$config_container_id" bash -c 'echo "Starting Tiller..."; helm tiller start-ci >/dev/null 2>&1 &'
     # shellcheck disable=SC2154
     docker exec "$config_container_id" bash -c 'echo "Waiting Tiller to launch on 44134..."; while ! nc -z localhost 44134; do sleep 1; done; echo "Tiller launched..."'
     echo
}

main() {
    enable_lio
    run_minikube

    echo "Ready for testing"

    echo "Add git remote k8s ${CHARTS_REPO}"
    git remote add storageos "${CHARTS_REPO}" &> /dev/null || true
    git fetch storageos master
    echo

    local config_container_id
    config_container_id=$(docker run -it -d -v "/home:/home" -v "$REPO_ROOT:/workdir" \
        --workdir /workdir "$CHART_TESTING_IMAGE:$CHART_TESTING_TAG" cat)

    # copy kubeconfig file
    docker cp /home/travis/.kube "$config_container_id:/root/.kube"

    # --- Work around for Tillerless Helm, till Helm v3 gets released --- #
    run_tillerless
    # shellcheck disable=SC2086
    docker exec -e HELM_HOST=localhost:44134 "$config_container_id" chart_test.sh --no-lint --config /workdir/test/.testenv_minikube
    # ------------------------------------------------------------------- #

    ##### docker exec -e KUBECONFIG="/home/travis/.kube/config" "$config_container_id" chart_test.sh --no-lint --config /workdir/test/.testenv ${CHART_TESTING_ARGS}

    echo "Done Testing!"
}

main
