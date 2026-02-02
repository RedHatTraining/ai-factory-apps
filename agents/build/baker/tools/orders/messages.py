import logging
from datetime import datetime, timedelta

log = logging.getLogger(__name__)


def get_all_customer_messages():
    """
    Get all customer messages since the given time.
    Mock data for demo; replace with real chat/API integration.
    """
    base = datetime.now()
    return [
        {
            "customer": "Alex Johnson",
            "conversation": [
                {
                    "role": "customer",
                    "content": "Hi! Can I get a small birthday cake for Saturday? Something chocolate, maybe 6–8 servings.",
                    "timestamp": base - timedelta(hours=22),
                },
                {
                    "role": "baker",
                    "content": "Sure! We can do chocolate. Saturday pickup—morning or afternoon? And any allergies or dietary needs?",
                    "timestamp": base - timedelta(hours=21, minutes=50),
                },
                {
                    "role": "customer",
                    "content": "Afternoon would be great. No allergies, just need it by 3pm for the party.",
                    "timestamp": base - timedelta(hours=21, minutes=15),
                },
            ],
        },
        {
            "customer": "Sam Smith",
            "conversation": [
                {
                    "role": "customer",
                    "content": "Do you have anything vegan? Looking for a couple of pastries or a small cake for tomorrow.",
                    "timestamp": base - timedelta(hours=18),
                },
            ],
        },
        {
            "customer": "Jordan Lee",
            "conversation": [
                {
                    "role": "customer",
                    "content": "Are the cinnamon rolls available today? And do you do gluten free at all?",
                    "timestamp": base - timedelta(hours=12),
                },
                {
                    "role": "baker",
                    "content": "Cinnamon rolls are on today's menu. We don't do gluten-free cinnamon rolls, but we have GF options for other items—want me to list what's available?",
                    "timestamp": base - timedelta(hours=11, minutes=45),
                },
                {
                    "role": "customer",
                    "content": "That's ok, I'll take 4 cinnamon rolls then. Pickup around 9am?",
                    "timestamp": base - timedelta(hours=11, minutes=20),
                },
            ],
        },
        {
            "customer": "Morgan Taylor",
            "conversation": [
                {
                    "role": "customer",
                    "content": "We need 3 dozen assorted muffins for a team meeting Friday 10am. Can you do that?",
                    "timestamp": base - timedelta(hours=8),
                },
            ],
        },
        {
            "customer": "Riley Chen",
            "conversation": [
                {
                    "role": "customer",
                    "content": "Hi, I ordered a lemon drizzle cake for pickup yesterday—it was amazing, thank you!",
                    "timestamp": base - timedelta(hours=5),
                },
                {
                    "role": "customer",
                    "content": "Would like to order the same again for next Wednesday, slightly bigger if possible?",
                    "timestamp": base - timedelta(hours=5, minutes=2),
                },
            ],
        },
        {
            "customer": "Casey Wright",
            "conversation": [
                {
                    "role": "customer",
                    "content": "Do you have cheesecake? Looking for one whole for Saturday.",
                    "timestamp": base - timedelta(hours=2),
                },
            ],
        },
        {
            "customer": "Jamie Park",
            "conversation": [
                {
                    "role": "customer",
                    "content": "Can I get 2 croissants and a large coffee to go? Be there in 20 mins",
                    "timestamp": base - timedelta(minutes=45),
                },
            ],
        },
    ]


def get_customer_messages(customer: str):
    """
    Get the customer messages for a specific customer.
    """
    return get_all_customer_messages()[customer]


def send_customer_message(customer: str, message: str):
    """
    Send a message to a specific customer.
    """
    log.info(f"Sending message to {customer}")
    return get_all_customer_messages()[customer].append(
        {
            "role": "customer",
            "content": message,
            "timestamp": datetime.now(),
        }
    )
