

import json
import os
import logging
from typing import Any, Dict, List, Optional
from dotenv import load_dotenv
from llama_stack_client import LlamaStackClient

load_dotenv()
model = os.getenv("INFERENCE_MODEL", "ollama/llama3.2:3b")
LOG = logging.getLogger("thought")
LOG.setLevel(logging.DEBUG)
client = LlamaStackClient(base_url="https://lsd-llama-milvus-inline-service-llama-stack-tests.apps.ocp.hkk6t.sandbox5156.opentlc.com/v1")
conversation_log = []
previous_response_id = None


def think(query: Optional[str]):
    global conversation_log
    global previous_response_id

    if query is not None:
        conversation_log.append({"role": "user", "content": query})

    response = client.responses.create(
        model=model,
        instructions="You are a helpful hospitality expert that can use tools to answer questions about the hotels in our hotel group.",
        input=conversation_log,
        tools=[{
            "type": "function",
            "name": "get_hotel_ratings",
            "description": "List hotels by rating in descending order. This function returns an ordered dictionary of hotel names mapped to the stars of the hotel (from 1 to 5).",
            "parameters": {
                "type": "object",
                "properties": {},
            }
        }],
        previous_response_id=previous_response_id
    )
    previous_response_id = response.id
    conversation_log += response.output

    LOG.debug(f"Context: {conversation_log}")

    assistant_answer = ""

    # find tool calls in the response output
    tool_calls = []
    for item in response.output:
        LOG.debug(f"Item type: {item.type}")

        if item.type == "function_call":
            name = item.name
            args = json.loads(item.arguments)
            tool_calls.append({
                "name": name,
                "call_id": item.call_id,
                "arguments": args
            })
            continue
        elif item.type == "message":
            # Some function calls incorrectly come typed as messages
            maybe_function_call = _try_parse_function_call_as_text(item)
            if _is_function_call(maybe_function_call):
                LOG.debug(f"Found function call incorrectly typed as message: {maybe_function_call}")
                tool_calls.append(maybe_function_call)

            else:
                assistant_answer = " ".join([piece.text.strip() for piece in item.content if piece.type == "output_text"])

    LOG.debug(f"Decided to use tools: {tool_calls}")

    return assistant_answer, tool_calls

def _is_function_call(function_call: dict) -> bool:
    return "name" in function_call and "arguments" in function_call


def _try_parse_function_call_as_text(item) -> dict:
    try:
        function_call = json.loads(item.content[0].text)
    except (json.JSONDecodeError, IndexError):
        function_call = [{}]

    return { **function_call[0], "call_id": "msg_0724254c-38d0-42fe-88fb-425711053385" }