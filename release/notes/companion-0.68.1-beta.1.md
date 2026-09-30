# Companion 0.68.1 beta 1

First Mate conversation handoffs preserve message text without embedding each
message's full verification metadata. This prevents long-running conversations
from starting a fresh session with a prompt that already exceeds the model's
context limit. Existing saved handoffs are projected the same way when loaded.

Human instructions, question-and-answer context, and full stored history remain
intact. This companion-only update retains the 0.68.0 features and is compatible
with existing Mac, iOS, web, and Pi clients. Install the package and restart the
companion service. No database or configuration migration is required.
