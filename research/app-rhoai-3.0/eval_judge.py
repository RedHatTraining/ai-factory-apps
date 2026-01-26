
import os
from dotenv import load_dotenv
from llama_stack_client import LlamaStackClient

load_dotenv()

LLAMA_STACK_URL = "https://lsd-llama-milvus-inline-service-my-first-model.apps.ocp.hkk6t.sandbox5156.opentlc.com/"
model_name = "vllm-inference/llama-32-3b-instruct"


client = LlamaStackClient(base_url=LLAMA_STACK_URL)


def eval_judge(input_text):
    config = {"input": input_text, "model": model_name, "instructions": system_instructions}
    response = client.responses.create(**config)
    return response.output_text

client.scoring.score(
    input="Hello, how are you?",
    output="I'm doing great, thank you!",
    model="vllm-inference/llama-32-3b-instruct",
    instructions="You are a helpful AI assistant. You are designed to answer questions in a concise and professional manner."
)