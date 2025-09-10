#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi
if [ -z "${COMMIT_ID+x}" ]; then
  echo "You must set the COMMIT_ID environment variable" >&2
  exit 1
fi

if [ -z "${CLIENT_PYTHON_COMMIT_ID+x}" ]; then
  echo "You must set the CLIENT_PYTHON_COMMIT_ID environment variable" >&2
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-}
CUT_MODE=${CUT_MODE:-test-and-cut}
LLAMA_STACK_ONLY=${LLAMA_STACK_ONLY:-false}

source $(dirname $0)/../common.sh

set -euo pipefail
set -x

if [ "$CUT_MODE" != "test-and-cut" ] && [ "$CUT_MODE" != "test-only" ] && [ "$CUT_MODE" != "cut-only" ]; then
  echo "Invalid mode: $CUT_MODE" >&2
  exit 1
fi


DISTRO=starter

TMPDIR=$(mktemp -d)
cd $TMPDIR

uv venv --python 3.12
source .venv/bin/activate

build_packages() {
  npm install -g yarn

  REPOS=(stack-client-python stack-client-typescript stack)
  if is_truthy "$LLAMA_STACK_ONLY"; then
    REPOS=(stack)
  fi

  for repo in "${REPOS[@]}"; do
    org=$(github_org $repo)
    git clone --depth 10 "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git"
    cd llama-$repo

    if [ "$repo" == "stack" ] && [ -n "$COMMIT_ID" ]; then
      REF="${COMMIT_ID#origin/}"
      git fetch origin "$REF"

      # Use FETCH_HEAD which is where the fetched commit is stored
      git checkout -b "rc-$VERSION" FETCH_HEAD
    elif [ "$repo" == "stack-client-python" ] && [ -n "$CLIENT_PYTHON_COMMIT_ID" ]; then
      REF="${CLIENT_PYTHON_COMMIT_ID#origin/}"
      git fetch origin "$REF"
      git checkout -b "rc-$VERSION" FETCH_HEAD
    else
      git checkout -b "rc-$VERSION"
    fi

    # TODO: this is dangerous use uvx toml-cli toml set project.version $VERSION instead of this
    perl -pi -e "s/^version = .*$/version = \"$VERSION\"/" pyproject.toml

    if ! is_truthy "$LLAMA_STACK_ONLY"; then
      # this one is only applicable for llama-stack-client-python
      if [ -f "src/llama_stack_client/_version.py" ]; then
        perl -pi -e "s/__version__ = .*$/__version__ = \"$VERSION\"/" src/llama_stack_client/_version.py
      fi
      if [ -f "package.json" ]; then
        perl -pi -e "s/\"version\": \".*\"/\"version\": \"$VERSION\"/" package.json
      fi

      # this is applicable for llama-stack repo but we should not do it when
      # LLAMA_STACK_ONLY is true
      perl -pi -e "s/llama-stack-client>=.*/llama-stack-client>=$VERSION\",/" pyproject.toml
    fi

    if [ "$repo" == "stack-client-typescript" ]; then
      npx yarn install
      npx yarn build
    else
      uv build -q
      uv pip install dist/*.whl
    fi

    git commit -am "Release candidate $VERSION"
    cd ..
  done
}


build_packages

install_dependencies

if [ "$CUT_MODE" != "cut-only" ]; then
  test_llama_cli
  test_library_client "$DISTRO" "$LLAMA_STACK_ONLY"
  test_docker "$DISTRO" "$LLAMA_STACK_ONLY" "$TOGETHER_API_KEY" "$FIREWORKS_API_KEY" "$TAVILY_SEARCH_API_KEY"
fi

# if MODE is test-only, don't cut the branch
if [ "$CUT_MODE" == "test-only" ]; then
  echo "Not cutting (i.e., pushing the branch) because MODE is test-only"
  exit 0
fi

for repo in "${REPOS[@]}"; do
  echo "Pushing branch rc-$VERSION for llama-$repo"
  cd llama-$repo
  org=$(github_org $repo)
  git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "rc-$VERSION"
  cd ..

done

echo "Successfully cut a release candidate branch $VERSION"
