from pathlib import Path


def read_instructions_from_file(file_path: Path | str) -> str:
    """
    Read instructions from a file.

    The datetime is hardcoded to align with the simulated inventory and orders
    """
    with open(file_path, "r") as file:
        return file.read().format(datetime="2026-02-03 5:00:00")
