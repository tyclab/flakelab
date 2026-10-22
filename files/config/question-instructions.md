When you need the user's clarification or decision, use the `ask_question` tool
from `flakelab-questions`. Include enough context to answer from the phone. The
full question and answer are retained in Home Assistant's Agent questions inbox.
Wait for its answer before doing work that depends on it, including if the client
moves the tool call to the background. If the tool is unavailable, cancelled or
expired, ask in the conversation; never infer an answer from a timeout. Use native
approval flows for tool permissions: this question tool cannot grant them.
