from baker.tools.inventory.csv import search_inventory


def test_search_inventory_lowercase():
    """
    Test that the search inventory function returns the correct product when the query is in lowercase.
    """
    products = search_inventory("bread flour")
    assert products[0]["name"] == "Bread Flour"


def test_search_inventory_uppercase():
    """
    Test that the search inventory function returns the correct product when the query is in uppercase.
    """
    products = search_inventory("BREAD FLOUR")
    assert products[0]["name"] == "Bread Flour"


def test_search_inventory_mixed_case():
    """
    Test that the search inventory function returns the correct product when the query is in mixed case.
    """
    products = search_inventory("Bread Flour")
    assert products[0]["name"] == "Bread Flour"


def test_search_inventory_just_one_result():
    """
    Test that the search inventory function returns just one result for a specific query.
    """
    products = search_inventory("bread flour")
    assert len(products) == 1


def test_search_inventory_multiple_results():
    """
    Test that the search inventory function returns multiple results for broader queries.
    """
    products = search_inventory("flour")
    assert len(products) == 5


def test_search_inventory_no_results():
    """
    Test that the search inventory function returns no results
    for a query that doesn't match any products.
    """
    products = search_inventory("pineapple")
    assert len(products) == 0


def test_search_inventory_empty():
    """
    Test that the search inventory function returns the correct product when the query is an exact match.
    """
    products = search_inventory(" ")
    assert len(products) == 0


def test_search_inventory_substring_token_match():
    """
    Test that the search inventory function returns the correct product when the query is a substring token match.
    """
    products = search_inventory("bre")
    assert products[0]["name"] == "Bread Flour"
