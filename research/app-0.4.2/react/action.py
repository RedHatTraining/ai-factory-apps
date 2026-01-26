import logging
from typing import Any, Dict, List, OrderedDict

from react.thought import conversation_log

LOG = logging.getLogger("action")

def run(actions: List[Dict[str, Any]]):
    for action in actions:
        name = action["name"]
        args = action["arguments"]
        call_id = action["call_id"]
        result = _call_function(name, args)
        LOG.debug(f"Action: {action} result: {result}")
        conversation_log.append({
            "type": "function_call_output",
            "call_id": call_id,
            "output": str(result)
        })


def _call_function(name: str, args: Dict[str, Any]) -> Any:
    if name == "get_hotel_ratings":
        return get_hotel_ratings(**args)
    else:
        raise ValueError(f"Unknown function: {name}")


def get_hotel_ratings() -> OrderedDict[str, int]:
    """
    List hotels by rating in descending order.
    This function returns an ordered dictionary of hotel names mapped
    to the stars of the hotel (from 1 to 5).
    """
    return OrderedDict[str, int]({
        "Cala B Hotel & Spa": 5,
        "Santa Lucia": 4,
        "Bella Vista": 3,
        "La Roca": 2,
        "Palm Beach": 2
    })