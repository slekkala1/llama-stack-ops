#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-}
LLAMA_STACK_ONLY=${LLAMA_STACK_ONLY:-false}
DISTRO=starter

# Set fake tokens for fork testing when real ones are not available
NPM_TOKEN=${NPM_TOKEN:-"fake-npm-token"}
TOGETHER_API_KEY=${TOGETHER_API_KEY:-"fake-together-api-key"}
FIREWORKS_API_KEY=${FIREWORKS_API_KEY:-"fake-fireworks-api-key"}
TAVILY_SEARCH_API_KEY=${TAVILY_SEARCH_API_KEY:-"fake-tavily-search-api-key"}

source $(dirname $0)/../common.sh

set -euo pipefail
set -x

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

  # Repos to process
  REPOS=(stack-client-python stack-client-typescript stack)

  if is_truthy "$LLAMA_STACK_ONLY"; then
    REPOS=(stack)
  fi

  setup_environment

  # First build packages
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

  # Publish packages once build and test pass
  for repo in "${REPOS[@]}"; do
    echo "Publishing $repo..."
    cd llama-$repo
    # publish_packages $repo
    cd ..
  done


  echo "Nightly test, build and publish completed successfully!"
}

# Execute main
main "$@"
