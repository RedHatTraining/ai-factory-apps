import json
import logging
from typing import Callable

from llama_stack_client import LlamaStackClient
from llama_stack_client.types import ResponseObject
from llama_stack_client.types.response_object import (
    OutputOpenAIResponseOutputMessageFunctionToolCall,
)

log = logging.getLogger(__name__)


class BakerAgent:
    """
    This is the main class for the Baker agent.
    """

    def __init__(
        self,
        model,
        instructions,
        client: LlamaStackClient,
        tools,
        tool_executor: Callable[[str, dict], str],
    ):
        self.model = model
        self.input_list = []
        self.instructions = instructions
        self.client = client
        self.tools = tools
        self.previous_response_id = None
        self.tool_executor = tool_executor

    def send_message(self, user_input: str, previous_response_id: str | None = None):
        """
        Run the agent with the given input.
        Returns (response_text, response_id, tool_calls_made).
        """
        tool_calls_made = []

        response = self.client.responses.create(
            model=self.model,
            instructions=self.instructions,
            tools=self.tools,
            input=user_input,
            previous_response_id=previous_response_id,
        )

        # Tool calling loop: process one tool call at a time until none remain
        # Note: LLama Stack LLM can only handle one tool call at a time
        tool_call = self._extract_next_function_call(response)
        while tool_call:
            output = None

            # First, parse the arguments (the model sends them as a JSON string)
            try:
                arguments = self._parse_tool_call_arguments(tool_call)
            except json.JSONDecodeError as exception:
                log.exception(f"Error parsing arguments for tool {tool_call.name}")
                arguments = None
                output = {
                    "error": f"Error parsing arguments for tool {tool_call.name}: {tool_call.arguments}",
                    "exception": str(exception),
                }

            # Then, run the tool and get the output
            if arguments is not None:
                log.info(f"Tool call: {tool_call.name} with arguments: {arguments}")
                output = self.tool_executor(tool_call.name, arguments)
                tool_calls_made.append({"name": tool_call.name, "arguments": arguments})

            # Finally, send the tool results back to the model
            if output:
                results = [
                    {
                        "type": "function_call_output",
                        "call_id": tool_call.call_id,
                        "output": output,
                    }
                ]
                log.info(f"Submit tool results to the model: {results}")

                response = self.client.responses.create(
                    model=self.model,
                    instructions=self.instructions,
                    tools=self.tools,
                    input=results,
                    previous_response_id=response.id,
                )

            # Keep iterating if the model has responded with another tool call
            tool_call = self._extract_next_function_call(response)

        # When there are no more tool calls, return the final text response of the agent
        return response.output_text, response.id, tool_calls_made

    def _extract_next_function_call(self, response: ResponseObject):
        """
        Extract the next tool call from the response output.
        Returns None if no tool call is found.
        """
        for item in response.output:
            if item.type == "function_call":
                return item
        return None

    def _parse_tool_call_arguments(
        self, tool_call: OutputOpenAIResponseOutputMessageFunctionToolCall
    ):
        """
        Parse the arguments for a tool call.
        Returns the parsed arguments, or None on parse error.
        """
        try:
            return json.loads(tool_call.arguments) if tool_call.arguments else {}
        except json.JSONDecodeError:
            log.exception(f"Error parsing arguments for tool {tool_call.name}")
            return None
