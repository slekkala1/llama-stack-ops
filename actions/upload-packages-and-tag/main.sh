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

npm config set '//registry.npmjs.org/:_authToken' "$NPM_TOKEN"

is_truthy() {
  case "$1" in
    true|1) return 0 ;;
    false|0) return 1 ;;
    *) return 1 ;;
  esac
}

TMPDIR=$(mktemp -d)
cd $TMPDIR

uv venv -p python3.12
source .venv/bin/activate

uv pip install twine

npm install -g yarn

REPOS=(stack-client-python stack-client-typescript stack)
if is_truthy "$LLAMA_STACK_ONLY"; then
  REPOS=(stack)
fi

for repo in "${REPOS[@]}"; do
  org=$(github_org $repo)
  git clone --depth 10 "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git"
  cd llama-$repo

  echo "Building package..."
  if [ "$NIGHTLY_BUILD" = "true" ]; then
    echo "Building nightly from main branch"
    git checkout main
    
    # Update version numbers for nightly build
    if [ "$repo" == "stack-client-typescript" ]; then
      echo "Updating TypeScript package version to $VERSION"
      perl -pi -e "s/\"version\": \".*\"/\"version\": \"$VERSION\"/" package.json
    else
      echo "Updating Python package version to $VERSION"  
      perl -pi -e "s/^version = .*$/version = \"$VERSION\"/" pyproject.toml
    fi
  else
    # Original release logic - fetch and checkout RC branch
    git fetch origin "rc-$VERSION":"rc-$VERSION"
    git checkout "rc-$VERSION"
  fi

  if [ "$repo" == "stack-client-typescript" ]; then
    NPM_VERSION=$(cat package.json | jq -r '.version')
    echo "version to build: $NPM_VERSION"

    npx yarn install
    npx yarn build
  else
    PYPROJECT_VERSION=$(cat pyproject.toml | grep version)
    echo "version to build: $PYPROJECT_VERSION"

    uv build -q
    uv pip install dist/*.whl
  fi

  # tag the commit on the branch because merging it back to main could move things
  # beyond the cut-point (main could have been updated since the cut)
  if [ "$NIGHTLY_BUILD" != "true" ]; then
    echo "Tagging llama-$repo at version $VERSION (not pushing yet)"
    git tag -a "v$VERSION" -m "Release version $VERSION"
  else
    echo "Skipping git tag creation for nightly build"
  fi

  if [ "$repo" == "stack-client-typescript" ]; then
    echo "Uploading llama-$repo to npm"
    cd dist
    # Use nightly tag for nightly builds, otherwise use version-specific tag
    if [ "$NIGHTLY_BUILD" = "true" ]; then
      NPM_PUBLISH_TAG="nightly"
    else
      NPM_PUBLISH_TAG="rc-$VERSION"
    fi
    
    # Skip actual upload for testing with fake tokens
    if [ "$NPM_TOKEN" = "fake-npm-token" ]; then
      echo "Skipping npm publish (using fake token for testing)"
      echo "Would publish with tag: $NPM_PUBLISH_TAG"
    else
      npx yarn publish --access public --tag $NPM_PUBLISH_TAG --registry https://registry.npmjs.org/
    fi
    cd ..
  else
    echo "Uploading llama-$repo to testpypi"
    
    # Skip actual upload for fork testing
    if [ "$NPM_TOKEN" = "fake-npm-token" ]; then
      echo "Skipping TestPyPI upload (fork testing mode)"
      echo "Would upload: dist/*.whl dist/*.tar.gz"
    else
      python -m twine upload \
        --repository-url https://test.pypi.org/legacy/ \
        --skip-existing \
        dist/*.whl dist/*.tar.gz
    fi
  fi

  # Only push git tags for non-nightly builds
  if [ "$NIGHTLY_BUILD" != "true" ]; then
    echo "Pushing tag for llama-$repo"
    git push "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "v$VERSION"
  else
    echo "Skipping git tag push for nightly build"
  fi

  cd ..
done
