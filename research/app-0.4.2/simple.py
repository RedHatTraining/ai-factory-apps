# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

"""
Demo script showing RAG with both Responses API and Chat Completions API.

This example demonstrates two approaches to RAG with Llama Stack:
1. Responses API - Automatic agentic tool calling with file search
2. Chat Completions API - Manual retrieval with explicit control

Run this script after starting a Llama Stack server:
    llama stack run starter
"""

import os

from openai import OpenAI
from dotenv import load_dotenv

load_dotenv()

# Initialize OpenAI client pointing to Llama Stack server
client = OpenAI(base_url="http://localhost:8321/v1/", api_key="none")

vs = client.vector_stores.create()


query = "How are you today"
print(f"Query: {query}\n")


print("Reply via Responses API:\n")
resp = client.responses.create(
    model=os.getenv("INFERENCE_MODEL", "ollama/llama3.2:3b"),
    input=query,
    tools=[{"type": "file_search", "vector_store_ids": [vs.id]}],
    include=["file_search_call.results"],
)

print("-" * 80)
print(resp.output[-1].content[-1].text)
print("-" * 80)
