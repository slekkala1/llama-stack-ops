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

  export LLAMA_STACK_TEST_INFERENCE_MODE=replay
  export LLAMA_STACK_TEST_RECORDING_DIR=llama-stack/tests/integration/recordings
  export SAFETY_MODEL="ollama/llama-guard3:1b"
  export OLLAMA_URL=http://localhost:11434

  set +x
  TEST_TYPES=$(for dir in llama-stack/tests/integration/*/; do
    [ -d "$dir" ] && basename "$dir"
  done | grep -Ev '^(__pycache__|fixtures|test_cases|recordings|post_training)$' | sort)
  TEST_FILES=""
  for test_type in $TEST_TYPES; do
    test_files=$(find llama-stack/tests/integration/$test_type -name "test_*.py" -o -name "*_test.py")
    if [ -n "$test_files" ]; then
      TEST_FILES="$TEST_FILES $test_files"
      echo "Added test files from $test_type: $(echo $test_files | wc -w) files"
    fi
  done

  set -x
  uv run pytest -s -v $TEST_FILES \
      --stack-config $stack_config \
      -k "not(builtin_tool or safety_with_image or code_interpreter or test_rag)" \
      --text-model ollama/llama3.2:3b-instruct-fp16 \
      --safety-shield llama-guard \
      --embedding-model sentence-transformers/all-MiniLM-L6-v2

  # run vision tests only for library client meaning stack-config should not have localhost in it
  # this is because otherwise we need to run docker again with the LLAMA_STACK_TEST_RECORDING_DIR set to the vision directory
  # set to a different directory. this is annoying.
  if [[ $stack_config != *"localhost"* ]]; then
    export LLAMA_STACK_TEST_RECORDING_DIR=llama-stack/tests/integration/recordings/vision
    uv run pytest -s -v llama-stack/tests/integration/inference/test_vision_inference.py \
      --stack-config $stack_config \
        --vision-model=ollama/llama3.2-vision:11b \
        --embedding-model=sentence-transformers/all-MiniLM-L6-v2
  fi
}

install_dependencies() {
  uv pip install pytest nbval pytest-asyncio reportlab pypdf mcp pyarrow>=21.0.0
}

test_llama_cli() {
  uv pip list | grep llama
  llama model prompt-format -m Llama3.2-90B-Vision-Instruct
  llama model list
  llama stack list-apis
  llama stack list-providers inference
  llama stack list-providers telemetry
}

setup_ollama() {
  echo "WARNING: We should really not be needing to run Ollama!!"

  docker run -d --name ollama -p 11434:11434 docker.io/leseb/ollama-with-models
  # TODO: rebuild an ollama image with llama-guard3:1b
  echo "Verifying Ollama status..."
  timeout 30 bash -c 'while ! curl -s -L http://127.0.0.1:11434; do sleep 1 && echo "."; done'
  docker exec ollama ollama pull llama-guard3:1b
}
