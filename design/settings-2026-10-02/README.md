# Settings, in the First Mate workspace

Carry First Mate's existing dusk, haze, and glass into the whole Settings window.
Use one continuous backdrop, a quiet navigation rail, and readable translucent
sections. This is a workspace for changing preferences, so controls and labels
stay familiar and the background supplies the visual character.

- Palette: dusk `#1D1634`, avatar violet `#2A2244`, lavender `#AAA6F4`,
  foreground `#E9E9EC`, and muted lavender `#B9A7DF`. Reuse the existing adaptive
  theme tokens and cached artwork rather than adding a competing palette.
- Type: the app's scalable system face, with 24-point page titles, 14-point
  section titles, and the existing 13-point control ramp. Skill names can retain
  their monospaced identifiers. Use sentence case.
- Layout: a 40-point native window bar, a compact navigation rail, and a flexible
  detail pane. Forms use bounded reading widths; Agent Roles keeps its role rail
  and gives the remaining width to its editor and skill tiles.
- Surfaces: one shared dusk image, the existing pane/sidebar glass levels, and
  restrained translucent section fills. Keep borders for grouping and selection.
- Accessibility: honor Glass, Haze, Desktop transparency, Reduce Transparency,
  and font scaling. Keep labels opaque and keyboard/VoiceOver navigation intact.

The brief explicitly asks for purple glass, so that is the defining gesture.
Avoid adding another gradient per card, decorative badges, animated backgrounds,
or a separate settings-only theme. Native render checks cover the full shell,
forms, Agent Roles, narrow widths, and opaque accessibility fallbacks.

Local skill discovery must describe this Mac's folders. Recognize common user
skill locations, explain one-time folder access, group permission problems, and
offer access to external linked targets. Execution-host discovery warnings do
not belong beside this Mac's picker. Saved role selections remain unchanged.
