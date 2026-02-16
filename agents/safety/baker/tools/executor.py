"""
Tool executor for the Baker agent.
Dispatches tool calls to their implementations.
"""

import json
import logging

import baker.tools.inventory.csv as inventory_csv
import baker.tools.orders.messages as orders_messages
import baker.tools.menu.renderer as menu_renderer


log = logging.getLogger(__name__)


def execute_tool(tool_name: str, arguments: dict) -> str:
    """Execute a tool by name and return the result as JSON string."""

    log.debug(f"Executing tool: {tool_name} with arguments: {arguments}")

    if tool_name == "get_inventory":
        return json.dumps(inventory_csv.get_inventory())

    elif tool_name == "search_inventory":
        return json.dumps(inventory_csv.search_inventory(arguments["query"]))

    elif tool_name == "get_customer_orders":
        return json.dumps(orders_messages.get_customer_orders_formatted())

    elif tool_name == "send_customer_message":
        return json.dumps(
            orders_messages.send_customer_message(
                arguments["customer"], arguments["message"]
            )
        )

    elif tool_name == "render_menu":
        return json.dumps(menu_renderer.render_menu(arguments["markdown_content"]))

    else:
        log.error(f"Unknown tool: {tool_name}")
        return json.dumps({"error": f"Unknown tool: {tool_name}"})
