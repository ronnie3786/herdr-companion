# Companion 0.28.0 Preview 1

First Mate uses a dedicated coordinator role with brief replies and delegates substantial planning, investigation, implementation, and review to tracked workers. Detailed work remains in agent sessions and retained documents. Existing saved coordinator conversations receive the updated role on their next dispatch.

The browser First Mate view renders assistant markdown, retained markdown documents, and saved assistant messages with styled prose and code. User text stays literal, and embedded HTML is escaped.

## Compatibility and setup

Package version: **0.28.0b1**. The `first-mate-v1` API remains compatible with existing Mac and iOS clients. Use macOS **0.28.0-beta.1** for the matching Mac markdown improvement. The iOS First Mate chat already supports markdown.

Install this package on the companion that runs First Mate. Follow the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.28.0-beta.1/herdr_harness/README.md#update-the-server): preserve private configuration and state, install the wheel into a fresh runtime, validate that runtime, and switch the service separately. A Mac app update does not deploy this package. Existing work and saved sessions remain intact; already running dispatches finish with the instructions they started with.

After updating, open First Mate and give a feature a substantive task. The main reply should be brief; follow execution in **Agents** and detailed results in **Documents**. In the browser, verify headings, lists, links, and fenced code render in replies.
