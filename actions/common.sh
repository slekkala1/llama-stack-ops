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
  sh llama-stack/scripts/integration-tests.sh \
    --stack-config $stack_config \
    --provider ollama \
    --inference-mode replay

  # run vision tests only for library client meaning stack-config should not have localhost in it
  if [[ $stack_config != *"localhost"* ]]; then
    echo "Running integration tests (vision)"
    sh llama-stack/scripts/integration-tests.sh \
      --stack-config $stack_config \
      --provider ollama \
      --inference-mode replay \
      --run-vision-tests
  fi
}

install_dependencies() {
  uv pip install pytest pytest-asyncio
}

test_llama_cli() {
  uv pip list | grep llama
  llama model prompt-format -m Llama3.2-90B-Vision-Instruct > /dev/null
  llama model list > /dev/null
  llama stack list-apis > /dev/null
}
