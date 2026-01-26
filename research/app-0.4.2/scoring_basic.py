import json
from pprint import pprint
from llama_stack_client import LlamaStackClient
from llama_stack_client.types.scoring_score_params import ScoringFunctionsBasicScoringFnParams

client = LlamaStackClient(base_url="http://localhost:8321")



result = client.scoring.score(
    input_rows=[
        {"expected_answer": "Paris", "generated_answer": "Paris"},
        {"expected_answer": "London", "generated_answer": "Paris"}
    ],
    # Check the list of scoring functions that the server provides at http://localhost:8321/v1/scoring-functions
    scoring_functions={
        "basic::equality": ScoringFunctionsBasicScoringFnParams(
            aggregation_functions=["accuracy"],
            type="basic",
        ),
    }
)


print(f"Accuracy: {result.results}")