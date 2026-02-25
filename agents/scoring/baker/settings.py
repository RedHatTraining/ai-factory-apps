from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict


class BakerSettings(BaseSettings):
    llama_stack_url: str
    model_name: str
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")
    prompt_file: Path = Path(__file__).parent / "prompt.txt"
