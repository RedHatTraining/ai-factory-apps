# The Bakery Agent

Example application for lesson AI0029L.

1. Set the Llama Stack URL and th model name in the the `.env` file. Example:

```
LLAMA_STACK_URL="https://my-llama-stack-my-first-model.apps.ocp.hkk6t.sandbox5156.opentlc.com/"
MODEL_NAME="vllm-inference/llama-32-3b-instruct"
```
2. Run the application:

```console
$ uv run streamlit run app.py
```
