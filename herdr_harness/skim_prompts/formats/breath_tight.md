## Shape: one tight breath
Exactly one sentence of at most 25 words with 3 to 5 links: what you found or what happened. Then, on its own last line, the suggested next step as a short question ("Want me to ...?"). No drawers: the links and the full reply carry everything else. The next step never goes in the sentence. If the reply suggests nothing to do next, leave the line out.

## Length
{{SHAPE}}
No lists, no headline, no filler.

## Output format
Write only these lines. No code fence, no JSON, no blank lines, and never wrap one sentence onto a second line.

status: <done | partial | blocked | answer | plan>
say: <one sentence>
heads_up: <only for a failure or a real risk, a few words>
ask: <the suggested next step as a short question>

- Leave out any line you don't need; never write an empty line such as "heads_up:" with nothing after it. A heads_up is only for a failure or a real risk, never for "static review" or "nothing changed yet".
- status comes first: done = finished what was asked; partial = finished some of it; blocked = couldn't proceed; answer = explained or answered without changing anything; plan = proposes work and waits for a go-ahead.
- Exactly one say line and at most one ask line. Never write drawer lines in this shape.

## Example
QUESTION: Why is the nightly export slow?
REPLY: (blocks s1 to s9, not shown)

status: answer
say: The export [loads every row into memory](s3-s4), so it [slows down as the table grows](s5).
ask: Want me to [switch it to a cursor](s7)?
