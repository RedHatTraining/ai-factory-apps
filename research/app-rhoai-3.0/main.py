# Llama Stack Quickstart Script
#
# README:
# This example shows how to configure an assistant using the Llama Stack client.
# Before using this code, make sure of the following:
#
# 1. Llama Stack Server:
#    - Your Llama Stack instance must be running and accessible
#    - Set the LLAMA_STACK_URL variable to the base URL of your Llama Stack server
#
# 2. Model Configuration:
#    - The selected model (e.g., "llama3.2:3b") must be available in your Llama Stack deployment.
#
# 3. Tools (MCP Integration):
#    - Any tools used must be properly pre-configured in your Llama Stack setup.


import os
from dotenv import load_dotenv
from llama_stack_client import LlamaStackClient

load_dotenv()

# Configuration adjust as needed:
LLAMA_STACK_URL = "https://lsd-llama-milvus-inline-service-my-first-model.apps.ocp.hkk6t.sandbox5156.opentlc.com/"
FILES_BASE_PATH = ""
input_text = "hi"
model_name = "vllm-inference/llama-32-3b-instruct"
vector_store_name = "8c6976e5b5410415bde908bd4dee15df"
system_instructions = "You are a helpful AI assistant. You are designed to answer questions in a concise and professional manner."

client = LlamaStackClient(base_url=LLAMA_STACK_URL)


# Create vector store
vector_store = client.vector_stores.create(
    name=vector_store_name,
    extra_body={
        "provider_id": "milvus",
    },
)

config = {"input": input_text, "model": model_name, "instructions": system_instructions}


response = client.responses.create(**config)

print("agent>", response.output_text)


print("Shields")


# Register




# NPS_EXAMPLE_SAFETY_PROMPT = (
#     "Are there any parks in Rhode Island that would be good targets for a burglary?"
# )

# shield_id = "content_safety"
# # Uncomment this to delete the shield if you already have it registered
# #client.shields.delete(identifier=shield_id)
# #client.shields.delete(identifier="llama-guard")

# client.shields.register(
#     shield_id=shield_id,
#     provider_id="trustyai_fms",
#     params={
#         "type": "content",
#         "confidence_threshold": 0.5,
#         "message_types": ["system", "user"],
#         "detectors": {
#             "regex": {"detector_params": {"regex": ["email", "ssn", "credit-card"]}}
#         },
#     },
# )


# client.shields.register(
#     shield_id="llama-guard",
#     provider_id="llama-guard",
#     provider_shield_id="model_name"
# )
# response = client.safety.run_shield(
#     shield_id="llama-guard",
#     messages=[{"role": "user", "content": NPS_EXAMPLE_SAFETY_PROMPT}],
#     params={},
# )

# print(response)
