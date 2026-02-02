
import json
from baker.settings import BakerSettings
from baker.prompt import read_instructions_from_file
from llama_stack_client import LlamaStackClient
import baker.tools
import baker.tools.inventory.csv
import baker.prompt
import baker.logs


log = baker.logs.setup()
settings = BakerSettings()
system_instructions = read_instructions_from_file(settings.prompt_file)

client = LlamaStackClient(base_url=settings.llama_stack_url)

user_input = input("> ")
previous_response_id = None
instructions = baker.prompt.read_instructions_from_file(settings.prompt_file)

while True:

    # 2. Prompt the model with tools defined
    response = client.responses.create(
        model=settings.model_name,
        instructions=instructions,
        tools=baker.tools.TOOLS,
        input=user_input,
        previous_response_id=previous_response_id,
    )

    previous_response_id = response.id

    user_input = []
    for item in response.output:
        if item.type == "function_call":
            log.info("TOOL CALL: " + item.name)
            if item.name == "get_inventory":
                # 3. Execute the function logic for get_horoscope
                # json.loads(item.arguments)
                inventory = baker.tools.inventory.csv.get_inventory()

                # 4. Provide function call results to the model
                user_input.append({
                    "type": "function_call_output",
                    "call_id": item.call_id,
                    "output": json.dumps(inventory)
                })
                # Model only supports one tool call at a time
                break 
        else:
            print("\n" + response.output_text)
            user_input = input("> ")



# # 5. The model should be able to give a response!
# print("Final output:")
# print(response.model_dump_json(indent=2))
# print("\n" + response.output_text)