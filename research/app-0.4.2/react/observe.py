import logging
from typing import Optional
from react.thought import conversation_log


LOG = logging.getLogger("observe")

def conversation() -> Optional[str]:
    """
    Get user input from the console.
    """
    LOG.debug(f"Observing: Conversation log: {conversation_log}")

    # if the last message in the context is a function call, no need to ask the user
    last_item = conversation_log[-1] if len(conversation_log) > 0 else {}
    if "type" in last_item and last_item["type"] == "function_call_output":
        return None

    return input("> ")

