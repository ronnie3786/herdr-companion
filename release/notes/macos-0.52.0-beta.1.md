# Herdr Companion 0.52.0-beta.1

## Skims: long replies in one breath

Long First Mate replies and HUD chat answers now arrive as a **skim**: one short,
casual sentence from the agent in which a few dotted phrases open the exact
original text. The full reply is always one click away.

- **The shape.** The sentence says what was found or done in about 25 words.
  A caveat with a rose rule appears only when something failed or is risky.
  **Rest of the original** collects every block the sentence doesn't link to,
  and the agent's suggested next step is always the last line, as a question
  after an amber dot.
- **Peek and open.** Hover a dotted phrase for a preview: its line range and a
  snippet, or for code the language, line count and the lines that matter.
  Click it (or Tab to it and press Return) for the original in a card with
  **Copy** and **Show in reply**, which opens the full reply at those lines,
  highlighted. Code in the card is highlighted, never wraps, and has **Copy code**.
- **Full reply** switches any message back to the reply as written, and **Skim**
  returns. Copy, quoting and thumbs up/down always act on the full reply.
- While a skim is being written, the full reply shows with a quiet
  "Skimming…". The skim swaps in a few seconds later without animation, and
  never while you're selecting text, reading with the pointer on that reply, or
  have a card open. If a skim can't be made, the full reply simply stays.
- Skims appear in First Mate chat, in Agent view columns, and on HUD chat
  answers of 80 words or more. Shorter replies are unchanged.

## Compatibility and installation

Install this preview through **Herdr Companion → Check for Updates…**, with
**Include preview builds** enabled. The app is Apple Development-signed,
distributed through the signed update feed, and is not notarized.

Skims come from the companion: a companion advertising `first-mate-skim-v1`
(0.52.0b1 or later) with a fast `skim_model` configured. The Mac updater does not
install companion packages; install and restart the companion separately. With an
older companion, or with skims turned off, every reply shows in full exactly as
before.

## Check the changes

- In a First Mate feature, ask something with a long answer. Expect "Skimming…",
  then the skim. Hover and click its phrases, then try **Full reply**.
- Ask a HUD chat a long question and check its answer the same way.
- See docs/first-mate/skim.md for configuration and what the model sees.
