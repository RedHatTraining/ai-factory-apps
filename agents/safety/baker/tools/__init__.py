TOOLS = [
    {
        "type": "function",
        "name": "get_inventory",
        "description": "Get the current inventory of the bakery, including the quantity of each product, the expiry date, and the received date.",
        "parameters": {"type": "object", "properties": {}},
    },
    {
        "type": "function",
        "name": "search_inventory",
        "description": "Search the inventory for a specific product. Returns an empty list if no products are found.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The query to search the inventory for.",
                },
            },
            "required": ["query"],
        },
    },
    {
        "type": "function",
        "name": "get_customer_orders",
        "description": "Get all customer pick-up orders.",
        "parameters": {"type": "object", "properties": {}},
    },
    {
        "type": "function",
        "name": "send_customer_message",
        "description": "Send a message to a specific customer.",
        "parameters": {
            "type": "object",
            "properties": {
                "customer": {
                    "type": "string",
                    "description": "The customer to send the message to.",
                },
                "message": {
                    "type": "string",
                    "description": "The message to send.",
                },
            },
            "required": ["customer", "message"],
        },
    },
    {
        "type": "function",
        "name": "render_menu",
        "description": "Generates a menu from the given Markdown content and saves the PDF ready to be printed.",
        "parameters": {
            "type": "object",
            "properties": {
                "markdown_content": {
                    "type": "string",
                    "description": "The menu content in simple Markdown format. The markdown should be a list of items formatted as follows: ## Item 1\nA description of the item.\n\tPrice: $3.99\n\n##Item 2...",
                },
            },
            "required": ["markdown_content"],
        },
    },
]
