# Start Pi from another Mac app

Open a `herdr://pi/new` URL to bring Herdr forward, create a fresh interactive Pi session, and send its first prompt automatically. No confirmation or extra Send click is required. The result opens in Chat and remains a normal session you can revisit from Herdr or its HUD.

```text
herdr://pi/new?prompt=Summarize%20this%20Slack%20thread&source=Slack&request_id=slack-example-1
```

Herdr must already be connected to a harness. Cold launches wait briefly for that connection. New sessions use Pi's configured default model. The link does not change global model settings, open its source URL, or execute a shell command directly.

## Parameters

| Parameter | Purpose |
| --- | --- |
| `prompt` | Required. The question or instruction to send. Maximum 16 KB of UTF-8 text. |
| `context` | Optional post, thread, selected text, or other reference content. Maximum 32 KB. |
| `source_url` | Optional HTTP/HTTPS permalink, such as the Slack message URL. Appears as **Open source** in the first prompt. |
| `source` | Optional calling app name, such as `Slack`. |
| `title` | Optional initial session title. Otherwise Herdr uses the source name or “External request.” Long display titles are shortened to fit. |
| `machine_id` | Optional configured Herdr machine ID. Defaults to the first configured Mac, regardless of the currently selected chat. |
| `workspace_id` | Optional existing workspace ID, such as `w7` or `work-mac\|w7`. Creates a new tab/session there. A scoped ID also selects its Mac. |
| `cwd` | Optional absolute working-folder path on the target Mac. Omit it to inherit the workspace folder, or the target Mac's home folder for a new workspace. |
| `request_id` | Recommended unique identifier per button click. Use the same ID to retry that click. Letters, numbers, `.`, `_`, and `-`, up to 100 characters. |

Without `workspace_id`, Herdr creates a new workspace for the request, using the title plus a short unique suffix. An invalid workspace or Mac never silently falls back to another destination. A source link alone does not fetch Slack content: the calling app supplies the context it wants Pi to see. The prompt is followed by a clearly quoted reference block containing that context and link.

Encode values exactly once. The complete encoded URL must fit within 64 KB, and the launching app or operating system may impose a smaller limit. Unknown or duplicate parameters and conflicting Mac/workspace targets show an error. Put credentials in neither the URL nor context. Launch receipts contain only a content hash, request ID, state, and resulting pane ID; prompt content is retained in normal chat history.

## Swift example for a Slack HUD button

```swift
import AppKit

func askPiAboutSlack(prompt: String, context: String, permalink: URL) {
    var link = URLComponents()
    link.scheme = "herdr"
    link.host = "pi"
    link.path = "/new"
    link.queryItems = [
        URLQueryItem(name: "prompt", value: prompt),
        URLQueryItem(name: "context", value: context),
        URLQueryItem(name: "source_url", value: permalink.absoluteString),
        URLQueryItem(name: "source", value: "Slack"),
        URLQueryItem(name: "title", value: "Question about #engineering"),
        URLQueryItem(name: "request_id", value: UUID().uuidString),
        // Optional: target an existing workspace on a specific configured Mac.
        // URLQueryItem(name: "machine_id", value: "your-configured-machine-id"),
        // URLQueryItem(name: "workspace_id", value: "w7"),
    ]
    guard let url = link.url else { return }
    NSWorkspace.shared.open(url)
}
```

Keep that constructed URL if your app retries delivery. Generate a new `request_id` for a deliberate new question, even about the same Slack message.

For JavaScript, build query values with `encodeURIComponent` (spaces become `%20`, literal plus signs become `%2B`):

```javascript
const fields = {
  prompt: "Explain the problem and suggest a reply",
  context: slackThreadText,
  source_url: slackMessagePermalink,
  source: "Slack",
  request_id: crypto.randomUUID(),
};
const query = Object.entries(fields)
  .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
  .join("&");
const url = `herdr://pi/new?${query}`;
// Pass url to your desktop app's normal external-URL opener.
```

## Retries and failures

The most recent 512 completed request IDs survive app restarts. Reopening one opens its original pane without sending again. Reusing an ID with changed content is rejected. Without a supplied request ID, each opening is a new request.

If creation or prompt delivery fails after it starts, Herdr keeps a receipt and does not automatically repeat the action. Reopening that ID opens the known pane, when available, and explains that delivery was not confirmed. Inspect it before sending manually or using a new ID. An error offers **Copy Prompt**, including the supplied context, so the request can be recovered. Unconfirmed receipts are retained rather than automatically expired.

## Manual checks

- Open the sample link with Herdr running, then with its main window closed, then after quitting the app. Each new request ID should open a new Chat and submit once.
- Supply a Slack permalink and multiline context with `+`, `&`, emoji, backticks, and nested URL query parameters. Check that the first prompt preserves the content and provides **Open source**.
- Target a workspace on another configured Mac. Check the session's machine, workspace, and working folder.
- Open the exact same URL twice, including after restarting Herdr. It should reopen the same chat without another prompt.
- Reuse the ID with different content. Expect an error, with no additional session or prompt.
- Try a missing workspace, missing prompt, offline Mac, and invalid source URL. Expect a useful error without launching in a fallback destination.
