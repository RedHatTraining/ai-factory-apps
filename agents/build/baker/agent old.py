from typing import Dict, List


class BakerAgent:
    """
    This is the main class for the Baker agent.
    """

    def __init__(self, model, instructions, client, tools):
        self.model = model
        self.input_list = []
        self.instructions = instructions
        self.client = client
        self.tools = tools
        self.previous_response_id = None

    def create_turn(
        self, input: str, executed_calls: List[Dict] | None = None, stream: bool = True
    ):
        if input:
            self.input_list.append(
                {
                    "role": "user",
                    "content": input,
                }
            )

        # If pending tool approvals, input is the list of approval request entries
        # if approval_requests:
        #     input = []
        #     for request in approval_requests:
        #         input.append(
        #             {
        #                 "type": "mcp_approval_request",
        #                 "approval_request_id": request[2],
        #                 "approval": approval_requests[request],
        #             }
        #         )

        if executed_calls:
            for call in executed_calls:
                self.input_list.append(
                    {
                        "type": "function_call_output",
                        "call_id": call["call_id"],
                        "output": call["output"],
                    }
                )
        if not stream:
            response = self.client.responses.create(
                model=self.model,
                input=self.input_list,
                previous_response_id=self.previous_response_id,
                instructions=self.instructions,
                tools=self.tools,
            )
            self.previous_response_id = response.id
        else:
            response = None
            streamed_any_text = False
            stream_iter = self.client.responses.create(
                model=self.model,
                input=self.input_list,
                previous_response_id=self.previous_response_id,
                instructions=self.instructions,
                tools=self.tools,
                stream=True,
            )
            for event in stream_iter:
                if event.type == "response.output_text.delta":
                    print(event.delta, end="", flush=True)
                    streamed_any_text = True
                elif event.type == "response.completed":
                    response = event.response
            if streamed_any_text:
                print()
            if response is None:
                raise RuntimeError("Streaming response completed without a final response.")
            self.previous_response_id = response.id

        print("--------------------------------", response.output)

        # Parse the response for more approval requests
        received_function_calls = []
        for item in response.output:
            if item.type == "function_call":
                request = (item.name, item.arguments, item.id)
                received_function_calls.append(request)

        return response, received_function_calls


