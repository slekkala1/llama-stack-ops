#!/bin/bash

# Generate version if not provided
if [ -z "$VERSION" ]; then
  echo "VERSION not provided, will generate nightly version..."
else
  echo "Using provided VERSION: $VERSION"
fi

if [ -z "$NPM_TOKEN" ]; then
  echo "You must set the NPM_TOKEN environment variable" >&2
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-}
LLAMA_STACK_ONLY=${LLAMA_STACK_ONLY:-false}
DISTRO=starter

source $(dirname $0)/../common.sh

set -euo pipefail
set -x

generate_nightly_version() {
  # Only generate version if not already set
  if [ -n "$VERSION" ]; then
    echo "Using provided VERSION: $VERSION"
    return
  fi

  echo "Extracting base version from llama-stack repo..."

  # Clone llama-stack repo to extract version
  local org=$(github_org stack)
  git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-stack.git" temp-version-check
  cd temp-version-check

  # Extract version from pyproject.toml
  local base_version=$(grep '^version = ' pyproject.toml | sed 's/version = "\(.*\)"/\1/')
  cd ..
  rm -rf temp-version-check

  # Generate nightly version with date suffix
  local date=$(date +%Y%m%d)
  VERSION="${base_version}-dev.${date}"

  echo "Generated nightly version: $VERSION (base: $base_version)"
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


publish_packages() {
  local repo=$1

  echo "Publishing packages for $repo..."

  if [ "$repo" == "stack-client-typescript" ]; then
    echo "Publishing TypeScript package to npm"
    cd dist
    npx yarn publish --access public --tag nightly --registry https://registry.npmjs.org/
    cd ..
  else
    echo "Publishing Python package to TestPyPI"
    python -m twine upload \
      --repository-url https://test.pypi.org/legacy/ \
      --skip-existing \
      dist/*.whl dist/*.tar.gz
  fi
}

main() {
  echo "Starting combined test, build and publish for nightly packages..."

  # Generate version if not provided
  generate_nightly_version
  export VERSION
  echo "Using version: $VERSION"

  # Repos to process
  REPOS=(stack-client-python stack-client-typescript stack)
  if is_truthy "$LLAMA_STACK_ONLY"; then
    REPOS=(stack)
  fi

  setup_environment

  # Build packages
  for repo in "${REPOS[@]}"; do
    echo "Processing $repo..."

    clone_and_prepare_repo $repo
    build_packages $repo

    echo "Completed processing $repo"
    cd ..
  done

  # Run tests
  test_llama_cli
  test_library_client "$DISTRO" "$LLAMA_STACK_ONLY"
  test_docker "$DISTRO" "$LLAMA_STACK_ONLY" "$TOGETHER_API_KEY" "$FIREWORKS_API_KEY" "$TAVILY_SEARCH_API_KEY"

  # Publish packages after build and test pass
  for repo in "${REPOS[@]}"; do
    echo "Publishing $repo..."
    cd llama-$repo
    publish_packages $repo
    cd ..
  done


  echo "Nightly test, build and publish completed successfully!"
}

# Execute main
main "$@"
