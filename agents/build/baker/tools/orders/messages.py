import logging
from datetime import datetime, timedelta

log = logging.getLogger(__name__)


_CONVERSATIONS = [
    {
        "customer": "Alex Johnson",
        "conversation": [
            {
                "role": "customer",
                "content": "Hi! Can I get a small birthday cake for Saturday? Something chocolate, maybe 6-8 servings.",
                "timestamp": datetime.now() - timedelta(hours=22),
            },
            {
                "role": "baker",
                "content": "Sure! We can do chocolate. Saturday pickup—morning or afternoon? And any allergies or dietary needs?",
                "timestamp": datetime.now() - timedelta(hours=21, minutes=50),
            },
            {
                "role": "customer",
                "content": "Afternoon would be great. No allergies, just need it by 3pm for the party.",
                "timestamp": datetime.now() - timedelta(hours=21, minutes=15),
            },
        ],
    },
    {
        "customer": "Sam Smith",
        "conversation": [
            {
                "role": "customer",
                "content": "Do you have anything vegan? Looking for a couple of pastries or a small cake for tomorrow.",
                "timestamp": datetime.now() - timedelta(hours=18),
            },
        ],
    },
    {
        "customer": "Jordan Lee",
        "conversation": [
            {
                "role": "customer",
                "content": "Are the cinnamon rolls available today? And do you do gluten free at all?",
                "timestamp": datetime.now() - timedelta(hours=12),
            },
            {
                "role": "baker",
                "content": "Cinnamon rolls are on today's menu. We don't do gluten-free cinnamon rolls, but we have GF options for other items—want me to list what's available?",
                "timestamp": datetime.now() - timedelta(hours=11, minutes=45),
            },
            {
                "role": "customer",
                "content": "That's ok, I'll take 4 cinnamon rolls then. Pickup around 9am?",
                "timestamp": datetime.now() - timedelta(hours=11, minutes=20),
            },
        ],
    },
    {
        "customer": "Morgan Taylor",
        "conversation": [
            {
                "role": "customer",
                "content": "We need 3 dozen assorted muffins for a team meeting tomorrow 10am. Can you do that?",
                "timestamp": datetime.now() - timedelta(hours=8),
            },
        ],
    },
]


def get_customer_orders():
    """
    Get all customer orders.
    Orders are stored as conversations between the customer and the bakery.
    Mock data for demo; replace with real chat/API integration.
    """
    return _CONVERSATIONS


def get_customer_orders_formatted():
    """
    Get all customer orders formatted for JSON serialization.
    """
    return [
        {
            "customer": customer["customer"],
            "conversation": [
                {
                    "role": entry["role"],
                    "content": entry["content"],
                    "timestamp": entry["timestamp"].isoformat(),
                }
                for entry in customer["conversation"]
            ],
        }
        for customer in _CONVERSATIONS
    ]


def send_customer_message(customer: str, message: str):
    """
    Send a message to a specific customer.
    """
    log.info(f"Sending message to {customer}")
    for conversation in _CONVERSATIONS:
        if conversation["customer"] == customer:
            conversation["conversation"].append(
                {
                    "role": "baker",
                    "content": message,
                    "timestamp": datetime.now(),
                }
            )
            return {"status": "sent", "customer": customer}

    log.error(f"Customer {customer} not found")
    return {
        "status": "error",
        "customer": customer,
        "error": f"Customer {customer} not found",
    }
