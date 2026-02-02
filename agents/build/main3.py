
import json
from baker.settings import BakerSettings
from baker.prompt import read_instructions_from_file
from llama_stack_client import LlamaStackClient
import baker.tools
import baker.tools.inventory.csv
import baker.prompt

settings = BakerSettings()
system_instructions = read_instructions_from_file(settings.prompt_file)

client = LlamaStackClient(base_url=settings.llama_stack_url)


def get_horoscope(sign):
    return f"{sign}: Next Tuesday you will befriend a baby otter."

# Create a running input list we will add to over time
input = "What is my horoscope? I am an Aquarius."

# 2. Prompt the model with tools defined
response = client.responses.create(
    model=settings.model_name,
    instructions=baker.prompt.read_instructions_from_file(settings.prompt_file),
    tools=baker.tools.TOOLS,
    input=input,
)

response_id = response.id

input_list = []
for item in response.output:
    if item.type == "function_call":
        if item.name == "get_inventory":
            # 3. Execute the function logic for get_horoscope
            # json.loads(item.arguments)
            inventory = baker.tools.inventory.csv.get_inventory()

            # 4. Provide function call results to the model
            input_list.append({
                "type": "function_call_output",
                "call_id": item.call_id,
                "output": json.dumps(inventory)
            })

print("Final input:")
print(input_list)

response = client.responses.create(
    model=settings.model_name,
    instructions=baker.prompt.read_instructions_from_file(settings.prompt_file),
    tools=baker.tools.TOOLS,
    input=input_list,
    previous_response_id=response_id,
)

# 5. The model should be able to give a response!
print("Final output:")
print(response.model_dump_json(indent=2))
print("\n" + response.output_text)