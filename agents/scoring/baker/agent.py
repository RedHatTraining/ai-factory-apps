import json
import logging
from typing import Callable, Literal

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
        model: str,
        instructions: str,
        client: LlamaStackClient,
        tools: list[dict],
        tool_executor: Callable[[str, dict], str],
    ):
        self.model = model
        self.input_list = []
        self.instructions = instructions
        self.client = client
        self.tools = tools
        self.previous_response_id = None
        self.tool_executor = tool_executor

        self._register_regex_shield()

    def send_message(self, user_input: str, previous_response_id: str | None = None):
        """
        Run the agent with the given input.
        Returns (response_text, response_id, tool_calls_made).
        """
        tool_calls_made = []

        # Input safety check: the input should pass the regex shield
        if not self._passes_regex_shield(user_input, role="user"):
            message = "I am sorry, but I cannot process your message due to sensitive information."
            return message, None, []

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

        # Output safety check: the response should pass the regex shield
        if not self._passes_regex_shield(response.output_text, role="assistant"):
            message = "I am sorry, but I cannot respond to that request due to sensitive information."
            return message, None, []

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

    def _register_regex_shield(self):
        """
        Register the regex shield.
        This shield uses the regex detector exposed by the Guardrails Orchestrator.
        """

        shield_id = "regex_detector"

        # A shield cannot be registered twice, so we need to delete it if it already exists.
        registered_shield_ids = [shield.identifier for shield in self.client.shields.list()]
        if shield_id in registered_shield_ids:
            logging.warning(
                "Regex detector already registered. Deleting it before re-registering..."
            )
            self.client.shields.delete(identifier=shield_id)
            logging.info("Regex detector deleted.")

        self.client.shields.register(
            shield_id=shield_id,
            provider_id="trustyai_fms",
            provider_shield_id=shield_id,
            params={
                "type": "content",
                "confidence_threshold": 0.5,
                "message_types": ["completion", "system", "user"],
                "detectors": {
                    "regex": {"detector_params": {"regex": ["email", "ssn", "credit-card"]}}
                },
            },
        )

        logging.info("Regex detector registered.")


    def _passes_regex_shield(self, message: str, role: Literal["user", "assistant"]):
        """
        Verify if the message passes the regex detector shield.
        Returns True if the message passes the regex shield, False otherwise.
        """

        if role == "user":
            message = {"role": role, "content": message}
        elif role == "assistant":
            message = {"role": role, "content": message, "stop_reason": "end_of_turn"}
        else:
            raise ValueError(f"Invalid role: {role}")

        response = self.client.safety.run_shield(
            shield_id="regex_detector",
            messages=[message],
            params={},
        )

        if response.violation and response.violation.violation_level in ["error", "warn"]:
            logging.warning(
                f"Regex shield violation detected: {response.violation.user_message}. "
                f"Violation data: {response.violation.metadata}"
            )

            return False

        return True # If no violation, the message passes the regex shield