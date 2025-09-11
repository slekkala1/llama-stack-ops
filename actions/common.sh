github_org() {
  repo=$1
  if [ "$repo" == "stack" ]; then
    echo "meta-llama"
  else
    echo "llamastack"
  fi
}

run_integration_tests() {
  stack_config=$1

  echo "Running integration tests (text)"
  bash llama-stack/scripts/integration-tests.sh \
    --stack-config $stack_config \
    --inference-mode replay \
    --suite base

  echo "Running integration tests (vision)"
  bash llama-stack/scripts/integration-tests.sh \
    --stack-config $stack_config \
    --inference-mode replay \
    --suite vision
}

install_dependencies() {
  uv pip install pytest pytest-asyncio
}

is_truthy() {
  case "$1" in
  true | 1) return 0 ;;
  false | 0) return 1 ;;
  *) return 1 ;;
  esac
}


test_library_client() {
  local distro=${1:-$DISTRO}
  local llama_stack_only=${2:-$LLAMA_STACK_ONLY}

  echo "Building distribution"

  if is_truthy "$llama_stack_only"; then
    llama stack build --distro $distro --image-type venv
  else
    llama stack build --distro $distro --image-type venv
  fi

  echo "Running integration tests before uploading"
  run_integration_tests $distro
}

test_docker() {
  local distro=${1:-$DISTRO}
  local llama_stack_only=${2:-$LLAMA_STACK_ONLY}
  local together_api_key=${3:-$TOGETHER_API_KEY}
  local fireworks_api_key=${4:-$FIREWORKS_API_KEY}
  local tavily_search_api_key=${5:-$TAVILY_SEARCH_API_KEY}

  echo "Testing docker"

  if is_truthy "$llama_stack_only"; then
    USE_COPY_NOT_MOUNT=true LLAMA_STACK_DIR=llama-stack \
      llama stack build --distro $distro --image-type container
  else
    USE_COPY_NOT_MOUNT=true LLAMA_STACK_DIR=llama-stack \
      LLAMA_STACK_CLIENT_DIR=llama-stack-client-python \
      llama stack build --distro $distro --image-type container
  fi

  docker images

  # run the container in the background
  export LLAMA_STACK_PORT=8321

  docker run -d --network host --name llama-stack-$distro -p $LLAMA_STACK_PORT:$LLAMA_STACK_PORT \
    -e OLLAMA_URL=http://localhost:11434 \
    -e SAFETY_MODEL=ollama/llama-guard3:1b \
    -e LLAMA_STACK_TEST_INFERENCE_MODE=replay \
    -e LLAMA_STACK_TEST_RECORDING_DIR=/app/llama-stack-source/tests/integration/recordings \
    -e TOGETHER_API_KEY=$together_api_key \
    -e FIREWORKS_API_KEY=$fireworks_api_key \
    -e TAVILY_SEARCH_API_KEY=$tavily_search_api_key \
    -v $(pwd)/llama-stack:/app/llama-stack-source \
    distribution-$distro:dev \
    --port $LLAMA_STACK_PORT

  # check localhost:$LLAMA_STACK_PORT/health repeatedly until it returns 200
  iterations=0
  max_iterations=20
  while [ $(curl -s -o /dev/null -w "%{http_code}" localhost:$LLAMA_STACK_PORT/v1/health) -ne 200 ]; do
    sleep 2
    iterations=$((iterations + 1))
    if [ $iterations -gt $max_iterations ]; then
      echo "Failed to start the container"
      docker logs llama-stack-$distro
      exit 1
    fi
  done

  run_integration_tests http://localhost:$LLAMA_STACK_PORT

  # stop the container
  docker stop llama-stack-$distro
}

test_llama_cli() {
  uv pip list | grep llama
  llama model prompt-format -m Llama3.2-90B-Vision-Instruct > /dev/null
  llama model list > /dev/null
  llama stack list-apis > /dev/null
}
