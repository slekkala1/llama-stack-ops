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

  pytest -s -v llama-stack/tests/integration/ \
      --stack-config $stack_config \
      -k "not(supervised_fine_tune or builtin_tool_code or safety_with_image or code_interpreter_for or rag_and_code or truncation or register_and_unregister or register_and_iterrows)" \
      --text-model ollama/llama3.2:3b-instruct-fp16 \
      --safety-shield llama-guard \
      --embedding-model sentence-transformers/all-MiniLM-L6-v2

  # run vision tests only for library client meaning stack-config should not have localhost in it
  # this is because otherwise we need to run docker again with the LLAMA_STACK_TEST_RECORDING_DIR set to the vision directory
  # set to a different directory. this is annoying.
  if [[ $stack_config != *"localhost"* ]]; then
    export LLAMA_STACK_TEST_RECORDING_DIR=llama-stack/tests/integration/recordings/vision
    pytest -s -v tests/integration/inference/test_vision_inference.py \
      --stack-config $stack_config \
        --vision-model=ollama/llama3.2-vision:11b \
        --embedding-model=sentence-transformers/all-MiniLM-L6-v2
  fi
}

install_dependencies() {
  uv pip install pytest nbval pytest-asyncio reportlab pypdf mcp
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
