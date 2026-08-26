def register():
    from vllm import ModelRegistry
    if "CustomQwen3ForCausalLM" not in ModelRegistry.get_supported_archs():
        ModelRegistry.register_model(
            "CustomQwen3ForCausalLM",
            "vllm.model_executor.models.qwen3:Qwen3ForCausalLM",
        )