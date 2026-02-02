from datetime import datetime

def get_current_time():
    """
    Get the current time.
    """
    return datetime.now().strftime("%H:%M:%S")
