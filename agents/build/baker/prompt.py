from datetime import datetime
from pathlib import Path


def read_instructions_from_file(file_path: Path | str) -> str:
    """
    Read instructions from a file.
    """
    with open(file_path, "r") as file:
        return file.read().format(datetime=datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
