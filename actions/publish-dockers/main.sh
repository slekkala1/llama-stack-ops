#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi
DISTROS=${DISTROS:-}

set -euo pipefail

release_exists() {
  local source=$1
  releases=$(curl -s https://${source}.org/pypi/llama-stack/json | jq -r '.releases | keys[]')
  for release in $releases; do
    if [ x"$release" = x"$VERSION" ]; then
      return 0
    fi
  done
  return 1
}

if release_exists "test.pypi"; then
  echo "Version $VERSION found in test.pypi"
  PYPI_SOURCE="testpypi"
elif release_exists "pypi"; then
  echo "Version $VERSION found in pypi"
  PYPI_SOURCE="pypi"
else
  echo "Version $VERSION not found in either test.pypi or pypi" >&2
  exit 1
fi

set -x
TMPDIR=$(mktemp -d)
cd $TMPDIR
uv venv -p python3.12
source .venv/bin/activate

uv pip install --index-url https://test.pypi.org/simple/ \
  --extra-index-url https://pypi.org/simple \
  --index-strategy unsafe-best-match \
  llama-stack==${VERSION}

which llama
llama stack list-apis

build_and_push_docker() {
  distro=$1

  echo "Building and pushing docker for distro $distro"
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    TEST_PYPI_VERSION=${VERSION} llama stack build --distro $distro --image-type container
  else
    PYPI_VERSION=${VERSION} llama stack build --distro $distro --image-type container
  fi
  docker images

  echo "Pushing docker image"
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    docker tag distribution-$distro:test-${VERSION} llamastack/distribution-$distro:test-${VERSION}
    docker push llamastack/distribution-$distro:test-${VERSION}
  else
    docker tag distribution-$distro:${VERSION} llamastack/distribution-$distro:${VERSION}
    docker tag distribution-$distro:${VERSION} llamastack/distribution-$distro:latest
    docker push llamastack/distribution-$distro:${VERSION}
    docker push llamastack/distribution-$distro:latest
  fi
}

if [ -z "$DISTROS" ]; then
  DISTROS=(starter meta-reference-gpu postgres-demo dell starter-gpu)
else
  DISTROS=(${DISTROS//,/ })
fi

for distro in "${DISTROS[@]}"; do
  build_and_push_docker $distro
done

echo "Done"
