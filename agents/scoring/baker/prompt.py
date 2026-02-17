from datetime import datetime
from pathlib import Path


def read_instructions_from_file(file_path: Path | str) -> str:
    """
    Read instructions from a file.
    """
    with open(file_path, "r") as file:
        return file.read().format(datetime="2026-02-17 12:00:00")
