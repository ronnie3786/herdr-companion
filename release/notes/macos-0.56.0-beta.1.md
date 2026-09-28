# macOS 0.56.0-beta.1

## Talk to the real First Mate

**My First Mate** is now a real, continuing conversation with the lead First Mate: one session per machine that can see every First Mate feature on it. It replaces the summary and local answers of the earlier previews.

- **Ask across features.** "What needs me?", "What is Receipt export waiting on?", "What finished today?" First Mate checks the features and answers in a sentence or two. Long answers get a skim, like any First Mate reply.
- **Pass decisions on.** "Tell Receipt export to ship iPhone-only." First Mate posts your words to that feature as your message and marks its newest message read. The feature's own First Mate replies in its chat. It passes on only what you actually said, and asks when the feature or the decision is unclear.
- **In the HUD.** Click First Mate's face to open the conversation. Hold the face to talk; let go to send. Its answer shows beside the face when it lands, and a click opens the chat. **Open in window** shows the same conversation in the First Mate chat window.
- **In the chat window.** **My First Mate** at the top of the sidebar is the same conversation, with its newest message and a dot while a reply is unread.
- **More than one machine.** First Mate lives on the machine with the most active features and stays there; choose another in the chat window's header. Each message also tells it about your other machines' features, so "What's the status of my tasks?" covers all of them. For a feature on another machine, it names the machine, and you answer in that feature's chat.

## The same prompt input everywhere

The First Mate HUD's chat, **My First Mate**, and every feature chat in the First Mate chat window now use the same prompt composer as the main window's chats:
- attach files, paste images, and paste code;
- the mic for dictation;
- the model and thinking pill;
- the context line: how full the session is and when it hands off (150,000 tokens by default).

Suggested replies still sit above a feature's composer.

## HUD overflow

The HUD shows at most six orbs and six rows. With more features, the five most urgent show and the sixth is **+N**, even when more than five need you. The **+N** orb keeps their unread dot and lists them on hover, and the face's badge still counts every feature that needs you. In the list, a summary row ("4 more · 2 need you") shows or hides the rest.

## Compatibility and installation

The lead First Mate needs companion **0.56.0b1** or newer, which advertises `first-mate-lead-v1`. It uses that machine's First Mate model and skim model from the companion's configuration. Against an older companion, **My First Mate** keeps its summary and new-feature composer, and the HUD answers locally, now naming one of your own features as the example.

Install this preview through **Settings → Updates → Check for Updates…**, with **Include preview builds** enabled. The app is Apple Development-signed, distributed through the signed update feed, and is not notarized. The Mac updater installs only the app; update each companion separately.

## Check the changes

- Click First Mate's face in the HUD and ask "What needs me?". Expect a short answer about your features, then the context line and the model pill under it.
- Hold the face, ask a question, and let go. Expect "Asked First Mate" beside the face, then the answer there.
- In the First Mate chat window, open **My First Mate** and pass a decision to a feature. Expect your words in that feature's chat.
- With more than six features, expect five orbs and **+N** in the HUD.
