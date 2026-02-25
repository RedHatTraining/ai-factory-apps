"""
MOCK: This is a mock implementation of the inventory tool.
Read a mock inventory from a CSV file.
"""

import csv
from pathlib import Path


def get_inventory():
    """
    Read the inventory from a CSV file and return a dictionary.
    """
    file_path = Path(__file__).parent / "inventory.csv"

    with open(file_path, "r") as file:
        reader = csv.DictReader(file)
        return {
            row["product"]: {
                "name": row["product"].replace("_", " ").title(),
                "quantity": row["quantity"],
                "unit": row["unit"],
                "received_date": row["received_date"],
                "expiry_date": row["expiry_date"],
                "notes": row["notes"],
            }
            for row in reader
        }


def search_inventory(query: str):
    """
    Search the inventory for a specific product.
    Case-insensitive, order-independent token matching (all tokens must be present).
    """
    tokens = query.lower().split()

    results = []

    if not tokens:
        return results

    for key, product in get_inventory().items():
        query_tokens_in_product_key = [t in key.lower() for t in tokens]

        if all(query_tokens_in_product_key):
            results.append(product)

    return results
