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
  inference_provider=$2
  safety_model=$3

  if [ "$inference_provider" == "together" ]; then
    model="together/meta-llama/Llama-4-Scout-17B-16E-Instruct"
  elif [ "$inference_provider" == "fireworks" ]; then
    model="fireworks/accounts/fireworks/models/llama4-scout-instruct-basic"
  else
    # not supported
    echo "Inference provider $inference_provider not supported"
    exit 1
  fi

  SAFETY_MODEL=$safety_model \
  LLAMA_STACK_TEST_INTERVAL_SECONDS=3 \
  pytest -s -v llama-stack/tests/integration/ \
    --stack-config $stack_config \
    -k "not(supervised_fine_tune or builtin_tool_code or safety_with_image or code_interpreter_for or rag_and_code or truncation or register_and_unregister or register_and_iterrows)" \
    --text-model $model \
    --vision-model $model \
    --safety-shield $safety_model \
    --embedding-model all-MiniLM-L6-v2
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
  docker run -d --name ollama -p 11434:11434 docker.io/leseb/ollama-with-models
  # TODO: rebuild an ollama image with llama-guard3:1b
  echo "Verifying Ollama status..."
  timeout 30 bash -c 'while ! curl -s -L http://127.0.0.1:11434; do sleep 1 && echo "."; done'
  docker exec ollama ollama pull llama-guard3:1b
}
