#!/usr/bin/env -S uv run --script
#
# /// script
# requires-python = ">=3.12"
# dependencies = ["httpx"]
# ///

import json
import os
import sys
import httpx

NIM_URL = os.environ["NIM_URL"]
MODEL = os.environ["NIM_MODEL"]

prompt = " ".join(sys.argv[1:])
if not prompt:
    print("Usage: ask.py <prompt>")
    sys.exit(1)

with httpx.stream("POST", f"{NIM_URL}/v1/chat/completions", json={
    "model": MODEL,
    "messages": [{"role": "user", "content": prompt}],
    "stream": True,
}, timeout=60) as r:
    for line in r.iter_lines():
        if line.startswith("data: ") and line != "data: [DONE]":
            chunk = json.loads(line[6:])
            if text := chunk["choices"][0]["delta"].get("content"):
                print(text, end="", flush=True)
    print()
