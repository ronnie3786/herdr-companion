"""Current operating instructions, independent of pinned personality snapshots."""
from .resources import pi_extension_path

POLICY_VERSION = "herdr-workflow-policy-v1"
MARKER = "<!-- herdr-workflow-policy:v1 -->"
_root = pi_extension_path({})
if _root is None:
    raise RuntimeError("The Companion workflow policy was not packaged")
POLICY_TEXT = (_root / "agent-docs" / "workflow-policy.md").read_text(encoding="utf-8").strip()


def append_workflow_policy(prompt: str) -> str:
    return prompt if MARKER in prompt else prompt + "\n\n" + POLICY_TEXT
