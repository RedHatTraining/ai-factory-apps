import json
import logging
from rich import print
from rich.logging import RichHandler

FORMAT = "%(message)s"
logging.basicConfig(
    level="ERROR", format=FORMAT, datefmt="[%X]", handlers=[RichHandler()]
)

from llama_stack_client import LlamaStackClient
import baker.tools
from baker.agent import BakerAgent
from baker.settings import BakerSettings
from baker.prompt import read_instructions_from_file
from baker.tools.executor import execute_tool

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

# TODO: Define the minimum accuracy threshold for the inventory accuracy metric
SUCCESS_THRESHOLD = 0.6

TEST_ROUNDS = 3

settings = BakerSettings()
client = LlamaStackClient(base_url=settings.llama_stack_url)

# --------------------------------------------------------------------------- #
# Read Test dataset
#
# The test dataset has been hardcoded to align with the inventory and orders.
# --------------------------------------------------------------------------- #

with open("scoring_dataset.json", "r") as f:
    dataset = json.load(f)

print("Test rounds: ", TEST_ROUNDS)
print("Dataset size (per round): ", len(dataset))

# Repeat the dataset for the number of test rounds
dataset = dataset * TEST_ROUNDS

print("Total test cases: ", len(dataset))


# --------------------------------------------------------------------------- #
# Scoring function configuration
# --------------------------------------------------------------------------- #

# Due to hardware constraints, use the same model for the judge as the inference model
judge_model = settings.model_name

# Read the judge prompt from the file
with open("scoring_judge_prompt.txt", "r") as f:
    prompt_template = f.read()

scoring_fn = {
    "llm-as-judge::base": {
        "aggregation_functions": ["categorical_count"],
        "judge_model": judge_model,
        "type": "llm_as_judge",
        "judge_score_regexes": ["(CORRECT|INCORRECT)"],
        "prompt_template": prompt_template,
    },
}

# --------------------------------------------------------------------------- #
# Create agent
# --------------------------------------------------------------------------- #


def get_agent():
    """Create the agent without the Streamlit layer"""
    client = LlamaStackClient(base_url=settings.llama_stack_url)
    instructions = read_instructions_from_file(settings.prompt_file)
    return BakerAgent(
        model=settings.model_name,
        instructions=instructions,
        client=client,
        tools=baker.tools.TOOLS,
        tool_executor=execute_tool,
    )


# --------------------------------------------------------------------------- #
# Run scoring
# --------------------------------------------------------------------------- #


print(f"\n[bold]═══ Inventory Accuracy ═══[/bold]")
print(f"Success threshold: {SUCCESS_THRESHOLD * 100:.0f}%\n")

# Generate answers from the agent
print("Calling the agent to generate answers...\n")
for i, row in enumerate(dataset):
    agent = get_agent()
    generated_answer, _, _ = agent.send_message(row["input_query"])
    row["generated_answer"] = generated_answer
    print(f"Generated test case {i + 1}/{len(dataset)}:")
    print(row)

# Score the generated answers
result = client.scoring.score(
    input_rows=dataset,
    scoring_functions=scoring_fn,
)
print(result)

# Summary
counts = result.results["llm-as-judge::base"].aggregated_results["categorical_count"][
    "categorical_count"
]
num_correct = counts.get("CORRECT", 0)
accuracy = num_correct / len(dataset)

print("\n[bold]Summary[/bold]")
for label in ["CORRECT", "INCORRECT"]:
    pct = counts.get(label, 0) / len(dataset) * 100
    print(f"  {label}: {pct:.0f}%")

print("\n[bold]Result[/bold]")
print(f"  Accuracy: {accuracy * 100:.0f}%")
print(f"  Threshold: {SUCCESS_THRESHOLD * 100:.0f}%")
if accuracy >= SUCCESS_THRESHOLD:
    print("  [green]PASS[/green]")
else:
    print("  [red]FAIL[/red]")
