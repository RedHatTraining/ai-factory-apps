TOOLS = [
    {
        "type": "function",
        "name": "get_current_time",
        "description": "Get the current time.",
        "parameters": {"type": "object", "properties": {}},
    },
    {
        "type": "function",
        "name": "get_inventory",
        "description": "Get the current inventory of the bakery.",
        "parameters": {"type": "object", "properties": {}},
    },
    {
        "type": "function",
        "name": "get_inventory_by_product",
        "description": "Get the inventory of a specific product.",
        "parameters": {
            "type": "object",
            "properties": {
                "product": {
                    "type": "string",
                    "description": "The product to get the inventory of.",
                },
            },
            "required": ["product"],
        },
    },
    {
        "type": "function",
        "name": "search_inventory",
        "description": "Search the inventory for a specific product.",
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
        "name": "get_all_customer_messages",
        "description": "Get all customer messages/orders since the given time.",
        "parameters": {
            "type": "object",
            "properties": {
                "since": {
                    "type": "string",
                    "description": "The time since which to get the customer messages.",
                },
            },
            "required": ["since"],
        },
    },
    {
        "type": "function",
        "name": "get_customer_messages",
        "description": "Get the customer messages/orders for a specific customer.",
        "parameters": {
            "type": "object",
            "properties": {
                "customer": {
                    "type": "string",
                    "description": "The customer to get the messages for.",
                },
            },
            "required": ["customer"],
        },
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
        "name": "publish_menu",
        "description": "Publish a menu to the bakery's website and social media.",
        "parameters": {
            "type": "object",
            "properties": {
                "menu": {
                    "type": "string",
                    "description": "The menu to publish.",
                },
            },
            "required": ["menu"],
        },
    },
]