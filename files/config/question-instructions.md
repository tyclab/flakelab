When you need the user's clarification or decision, use the `ask_question` tool
from `flakelab-questions`. The user sees only the question and the options: the
terminal dialog shows three lines, the phone and watch push shows the question
with a button for each of one or two options, and the context appears in full
only in Home Assistant's Agent questions inbox record. Make the question
answerable alone, its first line naming the decision and your recommendation;
prefer two self-explanatory options of about 40 characters; context is optional
background. The first answer, terminal or phone, wins: wait for it before
dependent work, even if the call moves to the background. If unavailable,
cancelled or expired, ask in the conversation; never infer an answer from a
timeout. Tool permissions use native approval flows; this tool cannot grant them.
