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
                "quantity": row["quantity"],
                "unit": row["unit"],
                "expiry": row["expiry"],
                "notes": row["notes"],
            }
            for row in reader
        }


def get_inventory_by_product(product: str):
    """
    Get the inventory of a specific product.
    """
    return get_inventory()[product]


def search_inventory(query: str):
    """
    Search the inventory for a specific product.
    """
    return [product for product in get_inventory().keys() if query in product]
