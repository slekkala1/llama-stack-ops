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

is_truthy() {
  case "$1" in
  true | 1) return 0 ;;
  false | 0) return 1 ;;
  *) return 1 ;;
  esac
}

DISTRO=starter

# Determine branch name and build type based on environment
if [ "$NIGHTLY_BUILD" = "true" ]; then
  BRANCH_NAME="nightly-$(date +%Y%m%d)"
  BUILD_TYPE="nightly build"
else
  BRANCH_NAME="rc-$VERSION"
  BUILD_TYPE="release candidate"
fi

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
      git checkout -b "$BRANCH_NAME" FETCH_HEAD
    elif [ "$repo" == "stack-client-python" ] && [ -n "$CLIENT_PYTHON_COMMIT_ID" ]; then
      REF="${CLIENT_PYTHON_COMMIT_ID#origin/}"
      git fetch origin "$REF"
      git checkout -b "$BRANCH_NAME" FETCH_HEAD
    else
      git checkout -b "$BRANCH_NAME"
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

test_library_client() {
  echo "Building distribution"

  if is_truthy "$LLAMA_STACK_ONLY"; then
    llama stack build --distro $DISTRO --image-type venv
  else
    llama stack build --distro $DISTRO --image-type venv
  fi

  echo "Running integration tests before uploading"
  run_integration_tests $DISTRO
}

test_docker() {
  echo "Testing docker"

  if is_truthy "$LLAMA_STACK_ONLY"; then
    USE_COPY_NOT_MOUNT=true LLAMA_STACK_DIR=llama-stack \
      llama stack build --distro $DISTRO --image-type container
  else
    USE_COPY_NOT_MOUNT=true LLAMA_STACK_DIR=llama-stack \
      LLAMA_STACK_CLIENT_DIR=llama-stack-client-python \
      llama stack build --distro $DISTRO --image-type container
  fi

  docker images

  # run the container in the background
  export LLAMA_STACK_PORT=8321

  docker run -d --network host --name llama-stack-$DISTRO -p $LLAMA_STACK_PORT:$LLAMA_STACK_PORT \
    -e OLLAMA_URL=http://localhost:11434 \
    -e SAFETY_MODEL=ollama/llama-guard3:1b \
    -e LLAMA_STACK_TEST_INFERENCE_MODE=replay \
    -e LLAMA_STACK_TEST_RECORDING_DIR=/app/llama-stack-source/tests/integration/recordings \
    -e TOGETHER_API_KEY=$TOGETHER_API_KEY \
    -e FIREWORKS_API_KEY=$FIREWORKS_API_KEY \
    -e TAVILY_SEARCH_API_KEY=$TAVILY_SEARCH_API_KEY \
    -v $(pwd)/llama-stack:/app/llama-stack-source \
    distribution-$DISTRO:dev \
    --port $LLAMA_STACK_PORT

  # check localhost:$LLAMA_STACK_PORT/health repeatedly until it returns 200
  iterations=0
  max_iterations=20
  while [ $(curl -s -o /dev/null -w "%{http_code}" localhost:$LLAMA_STACK_PORT/v1/health) -ne 200 ]; do
    sleep 2
    iterations=$((iterations + 1))
    if [ $iterations -gt $max_iterations ]; then
      echo "Failed to start the container"
      docker logs llama-stack-$DISTRO
      exit 1
    fi
  done

  run_integration_tests http://localhost:$LLAMA_STACK_PORT

  # stop the container
  docker stop llama-stack-$DISTRO
}

build_packages

install_dependencies

if [ "$CUT_MODE" != "cut-only" ]; then
  test_llama_cli
  test_library_client
  test_docker
fi

# if MODE is test-only, don't cut the branch
if [ "$CUT_MODE" == "test-only" ]; then
  echo "Not cutting (i.e., pushing the branch) because MODE is test-only"
  exit 0
fi

for repo in "${REPOS[@]}"; do
  echo "Pushing $BUILD_TYPE branch $BRANCH_NAME for llama-$repo"
  cd llama-$repo
  org=$(github_org $repo)
  git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/$org/llama-$repo.git" "$BRANCH_NAME"
  cd ..

done

echo "Successfully cut a $BUILD_TYPE branch $BRANCH_NAME for $VERSION"
