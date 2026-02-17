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


settings = BakerSettings()
client = LlamaStackClient(base_url=settings.llama_stack_url)

# --------------------------------------------------------------------------- #
# Read Test dataset to score two metrics: inventory accuracy and order feasibility
#
# The test dataset has been hardcoded to align with the inventory and orders.
# --------------------------------------------------------------------------- #

with open("scoring_dataset.json", "r") as f:
    dataset = json.load(f)

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
        "judge_score_regexes": ["(CORRECT|INCORRECT|IRRELEVANT)"],
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
print("Does the agent correctly report stock levels and assess whether orders can be fulfilled?\n")

# Generate answers from the agent
print("Calling the agent to generate answers to be tested...\n")
for i, test in enumerate(dataset):
    agent = get_agent()
    generated_answer, _, _ = agent.send_message(test["input_query"])
    test["generated_answer"] = generated_answer
    print(f"Generated {i+1}/{len(dataset)}:")
    print(test)

# Score the generated answers
result = client.scoring.score(
    input_rows=dataset,
    scoring_functions=scoring_fn,
)
print(result)


print(f"\n[bold]Summary[/bold]")

counts = result.results["llm-as-judge::base"].aggregated_results["categorical_count"]["categorical_count"]
for label in ["CORRECT", "INCORRECT", "IRRELEVANT"]:
    pct = counts.get(label, 0) / len(dataset) * 100
    print(f"  {label}: {pct}%")