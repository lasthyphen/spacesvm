#!/usr/bin/env bash
set -e

# e.g.,
# ./scripts/run.sh 1.7.13
#
# run without e2e tests
# ./scripts/run.sh 1.7.13
#
# to run E2E tests (terminates cluster afterwards)
# E2E=true ./scripts/run.sh 1.7.13
if ! [[ "$0" =~ scripts/run.sh ]]; then
  echo "must be run from repository root"
  exit 255
fi

SPACESVM_PATH=$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  cd .. && pwd
)
source "$SPACESVM_PATH"/scripts/constants.sh

VERSION=$1
if [[ -z "${VERSION}" ]]; then
  echo "Missing version argument!"
  echo "Usage: ${0} [VERSION]" >> /dev/stderr
  exit 255
fi

MODE=${MODE:-run}
E2E=${E2E:-false}
if [[ ${E2E} == true ]]; then
  MODE="test"
fi

DIJETS_LOG_LEVEL=${DIJETS_LOG_LEVEL:-INFO}

echo "Running with:"
echo VERSION: ${VERSION}
echo MODE: ${MODE}

############################
# download dijetsnode
# https://github.com/lasthyphen/dijetsnode/releases
GOARCH=$(go env GOARCH)
GOOS=$(go env GOOS)
DOWNLOAD_URL=https://github.com/lasthyphen/dijetsnode/releases/download/v${VERSION}/dijetsnode-linux-${GOARCH}-v${VERSION}.tar.gz
DOWNLOAD_PATH=/tmp/dijetsnode.tar.gz
if [[ ${GOOS} == "darwin" ]]; then
  DOWNLOAD_URL=https://github.com/lasthyphen/dijetsnode/releases/download/v${VERSION}/dijetsnode-macos-v${VERSION}.zip
  DOWNLOAD_PATH=/tmp/dijetsnode.zip
fi

rm -rf /tmp/dijetsnode-v${VERSION}
rm -rf /tmp/dijetsnode-build
rm -f ${DOWNLOAD_PATH}

echo "downloading dijetsnode ${VERSION} at ${DOWNLOAD_URL}"
curl -L ${DOWNLOAD_URL} -o ${DOWNLOAD_PATH}

echo "extracting downloaded dijetsnode"
if [[ ${GOOS} == "linux" ]]; then
  tar xzvf ${DOWNLOAD_PATH} -C /tmp
elif [[ ${GOOS} == "darwin" ]]; then
  unzip ${DOWNLOAD_PATH} -d /tmp/dijetsnode-build
  mv /tmp/dijetsnode-build/build /tmp/dijetsnode-v${VERSION}
fi
find /tmp/dijetsnode-v${VERSION}

DIJETSNODE_PATH=/tmp/dijetsnode-v${VERSION}/dijetsnode
DIJETSNODE_PLUGIN_DIR=/tmp/dijetsnode-v${VERSION}/plugins

############################

############################
echo "building spacesvm"
go build \
-o /tmp/dijetsnode-v${VERSION}/plugins/sqja3uK17MJxfC7AN8nGadBw9JK5BcrsNwNynsqP5Gih8M5Bm \
./cmd/spacesvm
find /tmp/dijetsnode-v${VERSION}

echo "building spaces-cli"
go build -v -o /tmp/spaces-cli ./cmd/spaces-cli
############################

############################
echo "creating allocations file"
cat <<EOF > /tmp/allocations.json
[
  {"address":"0xF9370fa73846393798C2d23aa2a4aBA7489d9810", "balance":10000000},
  {"address":"0x8Db3219F3f59b504BCF132EfB4B87Bf08c771d83", "balance":10000000},
  {"address":"0x162a5fadfdd769f9a665701348FbeEd12A4FFce7", "balance":10000000},
  {"address":"0x69fd199Aca8250d520F825d22F4ad9db4A58E9D9", "balance":10000000},
  {"address":"0x454474642C32b19E370d9A55c20431d85833cDD6", "balance":10000000},
  {"address":"0xeB4Fc761FAb7501abe8cD04b2d831a45E8913DdF", "balance":10000000},
  {"address":"0xD23cbfA7eA985213aD81223309f588A7E66A246A", "balance":10000000}
]
EOF

echo "creating VM genesis file"
rm -f /tmp/spacesvm.genesis
/tmp/spaces-cli genesis 1 /tmp/allocations.json \
--genesis-file /tmp/spacesvm.genesis
############################

############################
echo "building e2e.test"
# to install the ginkgo binary (required for test build and run)
go install -v github.com/onsi/ginkgo/v2/ginkgo@v2.1.4
ACK_GINKGO_RC=true ginkgo build ./tests/e2e
./tests/e2e/e2e.test --help

#################################
# download dijets-network-runner
# https://github.com/lasthyphen/dijets-network-runner
# TODO: use "go install -v github.com/ava-labs/dijets-network-runner/cmd/dijets-network-runner@v${NETWORK_RUNNER_VERSION}"
NETWORK_RUNNER_VERSION=1.3.6
DOWNLOAD_PATH=/tmp/dijets-network-runner.tar.gz
DOWNLOAD_URL=https://github.com/lasthyphen/dijets-network-runner/releases/download/v${NETWORK_RUNNER_VERSION}/dijets-network-runner_${NETWORK_RUNNER_VERSION}_linux_amd64.tar.gz
if [[ ${GOOS} == "darwin" ]]; then
  DOWNLOAD_URL=https://github.com/lasthyphen/dijets-network-runner/releases/download/v${NETWORK_RUNNER_VERSION}/dijets-network-runner_${NETWORK_RUNNER_VERSION}_darwin_amd64.tar.gz
fi

rm -f ${DOWNLOAD_PATH}
rm -f /tmp/dijets-network-runner

echo "downloading dijets-network-runner ${NETWORK_RUNNER_VERSION} at ${DOWNLOAD_URL}"
curl -L ${DOWNLOAD_URL} -o ${DOWNLOAD_PATH}

echo "extracting downloaded dijets-network-runner"
tar xzvf ${DOWNLOAD_PATH} -C /tmp
/tmp/dijets-network-runner -h

############################
# run "dijets-network-runner" server
echo "launch dijets-network-runner in the background"
/tmp/dijets-network-runner \
server \
--log-level debug \
--port=":32342" \
--disable-grpc-gateway &
PID=${!}

############################
# By default, it runs all e2e test cases!
# Use "--ginkgo.skip" to skip tests.
# Use "--ginkgo.focus" to select tests.
echo "running e2e tests"
./tests/e2e/e2e.test \
--ginkgo.v \
--network-runner-log-level debug \
--network-runner-grpc-endpoint="0.0.0.0:32342" \
--dijetsnode-path=${DIJETSNODE_PATH} \
--dijetsnode-plugin-dir=${DIJETSNODE_PLUGIN_DIR} \
--vm-genesis-path=/tmp/spacesvm.genesis \
--output-path=/tmp/dijetsnode-v${VERSION}/output.yaml \
--mode=${MODE}

############################
# e.g., print out MetaMask endpoints
if [[ -f "/tmp/dijetsnode-v${VERSION}/output.yaml" ]]; then
  echo "cluster is ready!"
  cat /tmp/dijetsnode-v${VERSION}/output.yaml
else
  echo "cluster is not ready in time... terminating ${PID}"
  kill ${PID}
  exit 255
fi

############################
if [[ ${MODE} == "test" ]]; then
  # "e2e.test" already terminates the cluster for "test" mode
  # just in case tests are aborted, manually terminate them again
  echo "network-runner RPC server was running on PID ${PID} as test mode; terminating the process..."
  pkill -P ${PID} || true
  kill -2 ${PID}
  pkill -9 -f sqja3uK17MJxfC7AN8nGadBw9JK5BcrsNwNynsqP5Gih8M5Bm || true # in case pkill didn't work
else
  echo "network-runner RPC server is running on PID ${PID}..."
  echo ""
  echo "use the following command to terminate:"
  echo ""
  echo "pkill -P ${PID} && kill -2 ${PID} && pkill -9 -f sqja3uK17MJxfC7AN8nGadBw9JK5BcrsNwNynsqP5Gih8M5Bm"
  echo ""
fi
