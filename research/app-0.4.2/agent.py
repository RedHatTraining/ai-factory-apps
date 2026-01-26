import logging
from rich.logging import RichHandler


FORMAT = "%(message)s"
logging.basicConfig(
    level=logging.ERROR, format=FORMAT, datefmt="[%X]", handlers=[RichHandler()]
)

from react import observe, thought, action

# TODO: test safety and scoring metrics

def run_agent_loop():
    while True:
        query = observe.conversation()

        assistant_answer, tool_calls  = thought.think(query)
        print(assistant_answer)

        action.run(tool_calls)


if __name__ == "__main__":
    run_agent_loop()
