#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi

if [ -z "$NPM_TOKEN" ]; then
  echo "You must set the NPM_TOKEN environment variable" >&2
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-}
LLAMA_STACK_ONLY=${LLAMA_STACK_ONLY:-false}

source $(dirname $0)/../common.sh

set -euo pipefail
set -x

is_truthy() {
  case "$1" in
  true | 1) return 0 ;;
  false | 0) return 1 ;;
  *) return 1 ;;
  esac
}

setup_environment() {
  echo "Setting up build environment..."

  npm config set '//registry.npmjs.org/:_authToken' "$NPM_TOKEN"

  npm install -g yarn

  TMPDIR=$(mktemp -d)
  cd $TMPDIR

  uv venv -p python3.12
  source .venv/bin/activate
  uv pip install twine

  install_dependencies  # Installs test dependencies
}

clone_and_prepare_repo() {
  local repo=$1
  local org=$(github_org $repo)

  echo "Cloning and preparing $repo..."
  git clone --depth 10 "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git"
  cd llama-$repo

  echo "Checking out main branch for nightly build"
  git checkout main

  update_version_numbers $repo
}

update_version_numbers() {
  local repo=$1

  echo "Updating version numbers for $repo..."
  if [ "$repo" == "stack-client-typescript" ]; then
    echo "Updating TypeScript package version to $VERSION"
    perl -pi -e "s/\"version\": \".*\"/\"version\": \"$VERSION\"/" package.json
  else
    echo "Updating Python package version to $VERSION"
    perl -pi -e "s/^version = .*$/version = \"$VERSION\"/" pyproject.toml
  fi
}

build_packages() {
  local repo=$1

  echo "Building packages for $repo..."

  if [ "$repo" == "stack-client-typescript" ]; then
    local VERSION_INFO=$(cat package.json | jq -r '.version')
    echo "Building TypeScript package version: $VERSION_INFO"
    npx yarn install
    npx yarn build
  else
    local VERSION_INFO=$(cat pyproject.toml | grep version)
    echo "Building Python package version: $VERSION_INFO"
    uv build -q
    uv pip install dist/*.whl
  fi
}

test_packages() {
  local repo=$1

  # Basic CLI testing and Run integration tests for main stack package
  # TODO: Add docker tests also
  if [ "$repo" == "stack" ]; then
    echo "Testing packages for $repo..."
    test_llama_cli

    echo "Running integration tests for main stack..."
    llama stack build --distro starter --image-type venv
    cd ..
    run_integration_tests starter
    cd llama-stack
  fi
}

publish_packages() {
  local repo=$1

  echo "Publishing packages for $repo..."

  if [ "$repo" == "stack-client-typescript" ]; then
    echo "Publishing TypeScript package to npm"
    cd dist
    if [ "$NPM_TOKEN" = "fake-npm-token" ]; then
      echo "Skipping npm publish (using fake token for testing)"
      echo "Would publish with tag: nightly"
    else
      npx yarn publish --access public --tag nightly --registry https://registry.npmjs.org/
    fi
    cd ..
  else
    echo "Publishing Python package to TestPyPI"
    if [ "$NPM_TOKEN" = "fake-npm-token" ]; then
      echo "Skipping TestPyPI upload (fork testing mode)"
      echo "Would upload: dist/*.whl dist/*.tar.gz"
      ls -la dist/
    else
      python -m twine upload \
        --repository-url https://test.pypi.org/legacy/ \
        --skip-existing \
        dist/*.whl dist/*.tar.gz
    fi
  fi
}

main() {
  echo "Starting combined test, build and publish for nightly packages..."

  # Repos to process
  REPOS=(stack-client-python stack-client-typescript stack)

  if is_truthy "$LLAMA_STACK_ONLY"; then
    REPOS=(stack)
  fi

  setup_environment

  for repo in "${REPOS[@]}"; do
    echo "Processing $repo..."

    clone_and_prepare_repo $repo
    build_packages $repo
    test_packages $repo
    publish_packages $repo

    echo "Completed processing $repo"
    cd ..
  done

  echo "Nightly test, build and publish completed successfully!"
}

# Execute main
main "$@"
