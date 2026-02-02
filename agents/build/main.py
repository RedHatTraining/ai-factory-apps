from baker.agent import BakerAgent
import baker.logs
import baker.tools
from baker.settings import BakerSettings
from llama_stack_client import LlamaStackClient
from baker.prompt import read_instructions_from_file
import baker.tools.inventory.csv
import json



log = baker.logs.setup()


def main():
    # Configuration adjust as needed:
    settings = BakerSettings()
    system_instructions = read_instructions_from_file(settings.prompt_file)

    client = LlamaStackClient(base_url=settings.llama_stack_url)

    # Create vector store
    # vector_store = client.vector_stores.create(
    #     name=vector_store_name,
    #     extra_body={
    #         "provider_id": "milvus",
    #     },
    # )

    user_input = input("> ")

    agent = BakerAgent(
        model=settings.model_name,
        instructions=system_instructions,
        client=client,
        tools=baker.tools.TOOLS,
    )

    agent_response, function_calls = agent.create_turn(user_input, stream=False)

    while True:
        # Ask the user for approval of the tool calls
        executed_calls = []
        for call in function_calls:
            #approved = get_approval_from_user(approval_request)
            # if approved:

            fn_name = call[0]
            call_id = str(call[2])

            if fn_name == "get_inventory":
                user_input = ""
                executed_calls.append({
                    "type": "function_call_output",
                    "call_id": call_id,
                    "output": json.dumps(baker.tools.inventory.csv.get_inventory())
                })

        if not executed_calls:
            user_input = input("> ")

        agent_response, function_calls = agent.create_turn(
            user_input, executed_calls, stream=False
        )


def get_approval_from_user(approval_request):
    """
    This is a placeholder for the actual logic to get approval from the user.
    It prints the approval request so you can see the information that would be
    available to the user.  In a real application, you would replace this with
    the actual logic to show this to the user in a reasonable way and then ask
    for a yes/no decision on whether to approve the tool call.
    """
    response = input(f"{approval_request[0]} (yes/no) > ")
    return response.lower() in ["y", "yes", "1"]


if __name__ == "__main__":
    main()
