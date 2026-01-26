#!/usr/bin/env bash


uv run llama stack list-deps starter | xargs -L1 uv pip install
uv run --env-file .env llama stack run starter