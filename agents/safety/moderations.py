import logging
logging.basicConfig(level=logging.WARNING)

from llama_stack_client import LlamaStackClient
from baker.settings import BakerSettings
from rich import print
from rich.markdown import Markdown


if __name__ == "__main__":

    settings = BakerSettings()
    client = LlamaStackClient(base_url=settings.llama_stack_url)

    shield_id = "hapmod"

    client.shields.delete(identifier=shield_id)
    client.shields.register(
        shield_id=shield_id,
        provider_id="trustyai_fms",
        provider_shield_id=shield_id,
        params={
            "type": "content",
            "confidence_threshold": 0.1,
            "message_types": ["user"],
            "detectors": {
                "hap": {
                    "detector_params": {
                        "custom_criteria": "The user is alergic to peanuts and eggs. No messages suggesting products with peanuts or eggs."
                    }
                }
            }
        }
    )


    moderation = client.moderations.create(
        input="You are awful",
        model="hapmod"
    )
    print(moderation)