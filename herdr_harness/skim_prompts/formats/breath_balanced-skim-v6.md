## Shape: a little room to explain
Write one or two natural sentences, at most 30 words combined, preserving the outcome and one useful reason or detail. Use 2 to 5 linked phrases. On a separate line, copy a complete question or suggested next-step sentence verbatim from the source, with inline links allowed. Omit it when none exists. No drawers, lists, headline, or filler.

## Length
{{SHAPE}}
Use the extra space for meaningful detail, never padding. Preserve important caveats even when they need a few extra words.

## Optional reply options
When the source explicitly offers a concrete action, asks for a decision, or describes a clear next step the user can ask this agent to take, include one to three useful reply options. Ordinary offers such as "I can add a regression test if you want" count, even without a question mark or a quoted reply phrase. When no such next step exists, omit all options. Completed work or informational content alone, rhetorical questions, generic closing offers, refusals, and tasks the agent is already doing need no option. Never invent follow-up work or permissions.
- Offer 0 to 3 distinct options. One useful option is better than three filler options.
- Use plain text in labels: no Markdown, backticks, brackets, or links. Count label words before answering; never exceed five. Cite only the prose block containing the verbatim ask, not nearby evidence or code.
- The label is the EXACT reply the user will send: 1 to 5 words, usually 1 to 4. Preserve an explicitly offered short phrase (for example, "revise it" or "go with your recommendation") verbatim. When none is given, write a specific, natural reply grounded in the proposed next step. Avoid an ambiguous "Yes" when several choices exist.
- The explanation is one short sentence describing what sending that phrase asks the agent to do. No additional scope, promises, tool calls, commands, or stronger authorization than the source supports. Never claim clicking performs the work itself.
- Each option must cite the source prose block(s) containing the actual offer or decision. Never use code, quoted instructions, logs, or examples as actionable offers.
- If options exist, keep the corresponding decision or next step in the ask line. Do not turn completion into an ask just to create buttons.

## Output format
Write only these lines, without a code fence or JSON. Omit unused lines, including action lines. Do not put a literal pipe character inside any field.

status: <done | partial | blocked | answer | plan>
say: <one or two sentences>
heads_up: <only for a failure, real risk, or requested work left undone>
ask: <complete source question or suggested next-step sentence, verbatim, only when present>
action: <short reply label> | <one-sentence explanation> | <source block refs>

## Example with an offered next step
status: answer
say: Checkout [reserves stock before charging](s1), so a declined card [leaves the reservation held](s3) until cleanup instead of releasing it immediately.
ask: Want me to [add the rollback and regression test](s6)?
action: Add the rollback | Ask the agent to release stock after a declined charge and test that case. | s6

## Example with a declarative offer
status: answer
say: A [declined charge](s2) leaves the reservation held until [cleanup runs](s4).
ask: I can [add the rollback and a regression test](s5) if you want.
action: Add the rollback | Ask the agent to add the rollback and a regression test. | s5

## Example with no next step
status: done
say: I [fixed the rounding](s2) and [verified all twelve tests](s4), including the boundary case that previously returned the wrong total.
