# Research: iOS app architecture (origin/main 30627dc, 2026-09-28)

Read-only sweep made for the iPhone port. Paths are relative to the repository root unless an absolute scratchpad path is shown (that export is gone; use the same path under the checkout).

iOS app documentation for the First Mate messaging UI

The app has no messaging-style list yet. Most of the data layer for one is already compiled into iOS but has no caller:
- the shared fleet summary types, including unread state;
- the chat-window demo data;
- `fetchFirstMateFleet` and `markFirstMateRead` on the client;
- `attentionCount` on the fleet store.

The UI is still split: charcoal dark chrome everywhere, plus First Mate's own light/dark palette. There is no dusk or glass styling on iOS.

**Path legend.** Every path below starts from one of these roots:
- ROOT = `<repository-root>`
- APP = ROOT/herdr-harness-ios/herdr-harness-ios
- SH = ROOT/HerdrFirstMateShared
- T = ROOT/herdr-harness-ios/herdr-harness-iosTests
- UIT = ROOT/herdr-harness-ios/herdr-harness-iosUITests

## 0. Project and build facts

**Project file** (ROOT/herdr-harness-ios/herdr-harness-ios.xcodeproj/project.pbxproj)
- **Format and Xcode:** objectVersion 77 (l.6). LastUpgradeCheck and LastSwiftUpdateCheck are 2640, i.e. Xcode 26.4 (l.275-276). The README says Xcode 26.2 or newer (ROOT/herdr-harness-ios/README.md:123).
- **Deployment target:** `IPHONEOS_DEPLOYMENT_TARGET = 26.0` on every target: app l.603/642, widget l.409/439, project l.513/572, unit tests l.669/693. UI tests inherit it.
- **Devices and versions:** `TARGETED_DEVICE_FAMILY "1,2"` (iPhone and iPad). Build 43, version 0.1.
- **Swift settings, all targets:**
  - `SWIFT_VERSION = 6.0`
  - `SWIFT_STRICT_CONCURRENCY = complete`
  - `SWIFT_APPROACHABLE_CONCURRENCY = YES`
  - `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`
  - No `SWIFT_DEFAULT_ACTOR_ISOLATION`, so the default is nonisolated. Code marks `@MainActor` explicitly.
  - `@concurrent` is used, e.g. APP/Infrastructure/HerdPulseCoordinator.swift:478.
- **How files are added:** folder references only. Every target uses `PBXFileSystemSynchronizedRootGroup` (l.69-110), and every Sources phase is empty (l.349-378).
  - A new `.swift` file anywhere under APP/ compiles automatically; no pbxproj edit is needed.
  - The only exception set removes `Info.plist` from the widget target (l.59-67).
- **HerdrFirstMateShared is compiled into the iOS app as source**, not as a package:
  - Group `F17A7E000000000000000001`, path `../HerdrFirstMateShared` (l.70-75), is in the app's `fileSystemSynchronizedGroups` (l.186-190).
  - So `FirstMateClient.swift` and `FirstMateStore.swift` live in module `herdr_harness_ios`.
  - `HerdrFirstMateSharedTests` compiles into the iOS unit-test target (l.234-237).
  - The Mac project compiles the same two folders (ROOT/herdr-harness-mac/herdr-harness-mac.xcodeproj/project.pbxproj:38-47, 97-99). Anything added to SH must build on both platforms; existing files use `#if os(macOS)`, e.g. SH/FirstMatePalette.swift:6-56.
- **Widget extension:**
  - Target `HerdPulseWidgets` (E40000042FABC00000000001), an app extension (l.198-220). It compiles the HerdrPulseShared and HerdPulseWidgets folders.
  - Embedded through "Embed App Extensions" (dstSubfolderSpec 13, l.10, 38-48); the app depends on it (l.181-185).
  - `APPLICATION_EXTENSION_API_ONLY = YES`. Info.plist is ROOT/herdr-harness-ios/HerdPulseWidgets/Info.plist with `com.apple.widgetkit-extension`.
  - The bundle has one widget, `HerdPulseLiveActivity` (HerdPulseWidgetBundle.swift).
  - `HerdrPulseShared/HerdPulseAttributes.swift` compiles into both app and widget. There is no App Group.

**ROOT/herdr-harness-ios/Defaults.xcconfig**
- `HERDR_IOS_BUNDLE_ID = org.herdr.companion.ios`; `HERDR_WIDGET_BUNDLE_ID = org.herdr.companion.ios.widgets`.
- Tests use `.tests` and `.uitests` suffixes (pbxproj l.671, 717). `HERDR_MAC_BUNDLE_ID = org.herdr.companion.macos`.
- `HERDR_DEVELOPMENT_TEAM`, `HERDR_KEYCHAIN_SERVICE` and `HERDR_LEGACY_KEYCHAIN_SERVICE` are empty.
- `HERDR_APNS_ENVIRONMENT = development` feeds `APS_ENVIRONMENT`.
- `#include? "Local.xcconfig"` supplies private overrides.
- `HERDR_DEMO_SERVER_URL` is `http://localhost:9092` in Debug and empty in Release (pbxproj l.589/628).

**ROOT/herdr-harness-ios/AppInfo.plist**
- URL scheme `herdr` (l.21-31).
- ATS: `NSAllowsLocalNetworking` plus an insecure-HTTP exception for localhost (l.38-50).
- `NSBonjourServices` `_herdr-harness._tcp` and `NSLocalNetworkUsageDescription` (l.51-56).
- Car-mode shortcut item (l.57-67).
- `NSMicrophoneUsageDescription` (l.68-69) and `NSSpeechRecognitionUsageDescription` (l.70-71).
- `NSSupportsLiveActivities` true (l.72-73).
- Five Inter fonts under `UIAppFonts` (l.74-81).
- Single scene only (l.82-86).
- Custom keys `HerdrDemoServerURL`, `HerdrKeychainService`, `HerdrLegacyKeychainService`, `HerdrTerminalBundleIdentifier`, `HerdrAPNsEnvironment`.
- **There is no `UIBackgroundModes` key.**

**Entitlements** (APP/herdr_harness_ios.entitlements): `aps-environment` set from `$(APS_ENVIRONMENT)`, and an empty `associated-domains` array.

## 1. App structure

**Entry point:** APP/App/HerdrHarnessApp.swift
- `@main` (l.4) with `@UIApplicationDelegateAdaptor(HerdrAppDelegate.self)` (l.6).
- `@AppStorage("herdr.firstMate.appearance") firstMateAppearance = .system` (l.7).
- `@State model = HerdrAppModel()` (l.8) and `herdPulse = HerdPulseCoordinator()`, passed down with `.environment` (l.9, 24).
- In DEBUG, `-HerdrPiOptionsFixture` replaces the root with `PiOptionsUITestFixtureView` (l.14-22).
- `.preferredColorScheme(model.selectedTab == .firstMate ? firstMateAppearance.colorScheme : .dark)` (l.25).
- `.tint(HerdrTheme.accent)` (l.26).

**Delegate:** APP/App/HerdrAppDelegate.swift
- APNs token is posted as `.herdrPushToken` (l.39-45).
- Foreground presentation is `[.banner, .badge]`, no sound (l.47-55).
- A notification tap reads `pane_id`/`paneId` and `machine_id` (l.20-28) and posts `.herdrOpenPane` (l.57-65).
- Quick action `herdr.car-mode` (l.67-77).

**Root view:** APP/Views/Root/AppRootView.swift
- Shows `ZStack { appTabs; SidebarDrawer }` when `hasCompletedSetup`, otherwise `OnboardingView` (l.10-19).
- Tasks:
  - connection, keyed by `connectionGeneration` (l.20-23)
  - pending pane or car mode (l.24-40)
  - push token (l.41-46)
  - smart alerts (l.47-49)
  - First Mate observation (l.50-53; context l.92-99)
  - Herd Pulse (l.54-56, 101-112)
- `onOpenURL` and universal links (l.57-62).
- Toast overlay (l.63-70), headless-agent sheet (l.74-76), Car mode full-screen cover (l.77-81), "Connection issue" alert (l.82-89).

**Tabs** (l.114-138): iOS 18 `Tab(_:systemImage:value:)` inside `TabView(selection: $model.selectedTab)`, in this order:

| # | Title | Icon | Value | Root view | Badge |
|---|---|---|---|---|---|
| 1 | First Mate | `sailboat` | `.firstMate` | `FirstMateWorkspaceView(model:fleet:)` | none |
| 2 | Agents | `bubble.left.and.bubble.right` | `.workspaces` | `WorkspaceNavigationView` | none |
| 3 | Attention | `bell.badge` | `.attention` | `AttentionNavigationView` | `.badge(model.unreadAlertCount)` — the only badge in the app |
| 4 | Notes | `note.text` | `.notes` | `RemoteNotesView` | none |
| 5 | Settings | `gearshape` | `.settings` | `SettingsView` | none |

**How AppTab is stored**
- APP/Models/AppTab.swift:3-9 is a plain enum with no raw values.
- Held in memory as `HerdrAppModel.selectedTab = .workspaces` (APP/State/HerdrAppModel.swift:29). **It is not persisted.**
- `-HerdrFirstMateDemo` or `-HerdrOpenFirstMate` selects `.firstMate` (l.236-238).
- `route(to:)` forces `.workspaces` whenever a pane or notification opens (l.2157-2164).

**Navigation pattern:** each tab switches on size class.
- **First Mate:** regular width uses `NavigationSplitView` (column 280/320/380, `.balanced`); compact uses `NavigationStack(path: [FirstMateFeatureTarget])` (APP/Views/FirstMate/FirstMateWorkspaceView.swift:13-36).
- **Agents:** compact uses `NavigationStack(path: $model.workspacePath)` over `WorkspaceRoute {.pane(String), .hudChats}`; regular uses `NavigationSplitView` (APP/Views/Workspace/WorkspaceNavigationView.swift:9-84).
- **Attention and Notes:** `NavigationStack(path:)`.
- **Settings:** `NavigationStack`.
- Pushed panes hide the tab bar with `.toolbarVisibility(.hidden, for: .tabBar)` (APP/Views/Pane/PaneSessionView.swift:44). **The First Mate chat does not.**
- The navigator is a custom left drawer over the whole TabView (APP/Views/Sidebar/SidebarDrawer.swift).
- On iPad the tab bar is the iPadOS 26 floating bar (UIT/HerdrFirstMateNavigationUITests.swift:70-94).

**App model:** APP/State/HerdrAppModel.swift
- Declared `@MainActor @Observable final class HerdrAppModel: HudChatTransport` (l.5-7).
- Owns `firstMateFleet` (l.30, built at l.176), `hudChats` (l.31) and `toastMessage` (l.52).
- Changing `connectionGeneration` calls `firstMateFleet.retireAll()` (l.73-83, 2280-2285).
- Testable init: `init(credentials:arguments:userDefaults:bootstrapMachines:)` (l.144-149), plus a `clientFactory` seam (l.119-121).

**Where demo mode is wired**
- In `HerdrAppModel`:
  - `forcedDemo = -HerdrDemoMode || -HerdrFirstMateDemo` (l.153).
  - `isDemoMode` (l.196) and `hasCompletedSetup` (l.197).
  - `loadDemo()` (l.233-235; body l.2044-2073) creates machines `demo1` "desktop" and `demo2` "laptop" and loads `DemoData.*`.
  - `useDemo()` and `leaveDemo()` (l.354-375). The UI entry points are OnboardingView.swift:98 and SettingsView.swift:78-82.
  - DEBUG-only arguments `-HerdrUITestServerURL`, `-HerdrUITestAPIToken` (machine id "ui-test"), `-HerdrResetSidebarState` and `-HerdrResetFirstMateScope` (l.154-171).
- First Mate demo:
  - `firstMateSources()` passes `isDemo: true, client: nil` (l.2302-2325).
  - The shared store then seeds `FirstMateDemo.features(step: 0)` (SH/FirstMateStore.swift:246-252).
  - An iOS-only extra adds `demo2-release-checklist` to demo2 (APP/FirstMate/FirstMateMobileDemo.swift:14-48, applied in FirstMateMobileFleetStore.swift:418-420).

## 2. The First Mate tab end to end

**Observe and poll**
- The root view's task calls `HerdrAppModel.observeFirstMate()` (l.2290-2296), which calls `fleet.observe(sources:connectionGeneration:)` (FirstMateMobileFleetStore.swift:566-584).
- That activates the roster, refreshes immediately, then loops `Task.sleep(pollingInterval = .seconds(10))` (l.117).
- It does not poll when every host is a demo (l.574).
- Observation only runs when `selectedTab == .firstMate && scenePhase == .active` (AppRootView.swift:97), so there is **no polling on other tabs or in the background**, and no First Mate SSE.
- Each host refreshes in its own `withTaskGroup` child (l.540-556) through the shared `FirstMateStore.refresh()` (SH/FirstMateStore.swift:475-547). That call fetches, in order:
  1. capabilities
  2. `GET /features?view=active|all`
  3. the selected feature's snapshot
- A 404 or 501 marks the host unsupported (SH/FirstMateStore.swift:1595-1600).

**Stores and identity** (APP/FirstMate/)
- `FirstMateFeatureTarget {machineID, featureID}` (FirstMateFeatureTarget.swift:10-15) and `FirstMateMobileFleetFeature {target, machineName, feature}` (l.22-30).
- `FirstMateMachineScope {.all, .machine(id)}`: a removed machine resolves to `.all` (FirstMateMachineScope.swift:10-32).
- `FirstMateScopePreference`, key `herdr.firstMate.scope.v1`, values `v1:all` or `v1:machine:<id>`. The legacy `herdr.firstMate.machine` key is ignored (l.45-89).
- `FirstMateObservationContext {machineIDs, generation, isDemo, isActive}` (FirstMateObservationContext.swift:10-17).

**`FirstMateMobileFleetStore`** (@MainActor @Observable, l.76-77)
- `FirstMateMobileFleetSource` (l.5-25).
- `FirstMateMobileFleetHost` mirrors each host's list and capability flags (l.34-64), including archive, attachments, context, safe model settings, links and feedback.
- Private `stores[machineID]: FirstMateStore` and `identities[machineID]` (l.121-125).
- Public API:
  - `selectScope` (149), `beginCreating` (170)
  - `featureIdentifier` → `first-mate-feature-<m>-<f>` (184)
  - `setShowArchived` (196), `canShowArchived` (204)
  - `setArchived(_:archived:reason:expectedContext:)` (211)
  - `create(on:title:goal:cwd:requestID:expectedContext:)` (232)
  - `visibleHosts` (256)
  - `visibleRows` (266-281) — **roster order, then each host's own order; there is no cross-host recency sort**
  - `waitingRows` (`awaiting_direction` or `blocked`, l.97/284), `otherActiveRows` (289), `archivedRows` (294)
  - `attentionCount` (304-313)
  - `store(for:)` (318), `feature(for:)` (332), `selectTarget` (354), `open` (366)
  - `activate` (386-474; keeps a host's store while its connection identity is unchanged), `deactivate` (479), `retireAll` (490)
- `samePublishedFeatures` ignores usage and telemetry churn (667-677).
- "All Machines" means one `FirstMateStore` per machine, with rows flattened across the hosts in scope.
  - Cards show the owning host only when more than one host is visible (FirstMateFeatureListView.swift:13, 231-234).
  - Each host gets its own notice when unsupported, failing or empty (l.89-132).
  - Every write goes to that exact machine's store.

**List:** APP/Views/FirstMate/FirstMateFeatureListView.swift
- Layout: ScrollView + LazyVStack (spacing 20, padding 20), pull to refresh, `navigationTitle("First Mate")`, search prompt "Find a feature or goal" (l.26-63).
- Toolbar (l.134-191):
  - Host menu (`first-mate-machine-picker`).
  - `Menu("First Mate options", "ellipsis.circle")` with the Appearance picker, Refresh, Show/Hide archived, and Next demo scenario.
  - "New feature" (`plus`).
- Sections: "Needs your direction", "Your features" or "Everything else", and "Archived".
- Context menu offers "Archive…" or "Unarchive" (l.250-262).
- The archive sheet, `FirstMateMobileArchiveSheet`, is in the same file (l.297-362). It offers an optional `FirstMateArchiveReason` and calls `POST /features/{id}/actions` with `{action, reason?, request_id}` (APP/Infrastructure/HerdrAPIClient.swift:63-68).

**Feature card:** `FirstMateFeatureCard` shows status, ticket or "Idea", cost, title, a two-line goal, the host label, and the current step with a chevron. Padding 18, radius 20, `palette.surface`, 0.5 pt `palette.line` stroke.

**Opening a feature**
- iPhone **pushes** it (`path = [target]`, FirstMateWorkspaceView.swift:75-78). iPad shows it as the split detail, with `.id("\(machineID)-\(featureID)")` (l.65-73).
- `FirstMateFeatureDetailView` has a toolbar menu: overview, refresh, demo, Pause/Resume, and Cancel (with confirmation). These call `store.perform(...)`.
- `.task(id: featureID)` selects the feature and refreshes (l.18-86).
- The README's phrase "iPhone uses focused detail sheets" applies only to the inspector and resources. The chat itself is pushed.

**Chat:** FirstMateChatView.swift
- A row of shortcut capsules: Workflow, Agents · n, Docs · n, Overview (l.100-125).
- Messages come from shared `snapshot.conversationEntries` (SH/FirstMateConversationEntry.swift):
  - Only user/human/assistant messages that are not `visibility == "background"` are shown.
  - Checkpoint closing replies go into an "Additional response from this turn" disclosure.
- A "Decision needed" label marks the pending decision message.
- Scrolling: `.defaultScrollAnchor(.bottom, for: .initialOffset)`, follows the newest message when within 70 pt of the bottom, keyboard dismisses interactively.
- The composer and a checkpoint status line sit in `.safeAreaInset(.bottom)` over `.background(.bar)` (l.16-79, 127-159). The composer is hidden once a feature is completed or cancelled.

**Messages:** FirstMateMessageView.swift
- **Your messages:** a bubble with padding 16, radius 18, accent at 0.13 opacity (dark) or 0.08 (light), pushed right by `Spacer(minLength: 28)` except at accessibility text sizes.
- **First Mate's messages:** no bubble; a "sailboat.fill" and "First Mate" header, then `SkimmableReply(style: .firstMate(scheme))` around `FirstMateDocumentContentView`. "Queued" and "Skimming…" labels appear when relevant.

**Composer:** FirstMateComposerView.swift is **text only**.
- Vertical `TextField` with 1…6 lines.
- 44 pt circular accent send button (`arrow.up`), ⌘↩ shortcut, radius-28 capsule.
- Sends with `store.send(expectedContext:expectedText:)`.

**Inspector:** FirstMateInspectorPresentation.swift
- iPad: `.inspector`, column width 320/380/460.
- iPhone: `.sheet` with `.presentationDetents([.large])`.
- Tabs are Overview, Agents, Documents and Workflow (SH/FirstMateInspector.swift).
- Documents and sessions open a `.sheet(item: $store.resourcePresentation)` resource sheet with pagination.

**Create sheet:** FirstMateCreateSheet.swift
- Destination picker, which starts as "Choose a machine" when All Machines is in scope.
- Title, goal and folder fields; recent folders come only from the destination's workspaces and existing features.
- The request ID rotates on any edit; dismissal is blocked while sending.
- Calls `POST /api/v1/first-mate/features`, then opens the new feature.

**Appearance**
- APP/FirstMate/FirstMateAppearance.swift: `system`, `light`, `dark`.
- Applied app-wide only while the First Mate tab is selected (HerdrHarnessApp.swift:25).
- Views read `@Environment(\.colorScheme)`, build `FirstMatePalette(scheme:)`, and set `.toolbarColorScheme(scheme, for: .navigationBar)`.
- The shared store's `isDark` (`-HerdrFirstMateDark`, SH/FirstMateStore.swift:62-66) is **unused on iOS**.

**Control gating** (HerdrAppModel):
- `firstMateCanControl(machineID:)` (l.2262-2267)
- `firstMateCanControlVisibleHosts` (l.2272)
- `firstMateScopeLabel` (l.2252)
- `selectFirstMateScope` (l.2276)

**Shared types iOS uses:**
- **Store and client:** `FirstMateStore`, `FirstMateClient`, `FirstMateCapabilities`, `FirstMateFeatureList`, `FirstMateFeatureScope`, `FirstMateConnectionIdentity`.
- **Models:** `FirstMateSnapshot`, `FirstMateFeature`, `FirstMateMessage` (+`Metadata`), `FirstMateConversationEntry`, `FirstMateVisit`, `FirstMateAssignment`, `FirstMateSession`, `FirstMateDocument`, `FirstMateEvent`, `FirstMateResource` (+`Presentation`), `FirstMateInspector`, `FirstMateArchiveReason`, `FirstMateFeedbackCapability`.
- **Presentation:** `FirstMatePalette`, `FirstMateSkim`, `FirstMateSkimReader`, `SkimToken`, `SkimCodeHighlighter`, `FirstMateUsageFormatting`, `FirstMateUsageSummaryView`, `FirstMateVerificationSummaryView`, `FirstMateModelSelectionSummaryView`.
- **Demo:** `FirstMateDemo`.

## 3. iOS theme

**HerdrTheme** (APP/Design/HerdrTheme.swift:3-48): every color is opaque sRGB and **fixed dark (not adaptive)**.

| Token | Hex | Token | Hex |
|---|---|---|---|
| ink | #191A23 | accent | #AAA6F4 |
| graphite | #20212C | primaryAction | #A6BAFF |
| elevated | #292B39 | mauve | #B9A7DF |
| input | #2B2D3B | signal | #9CCDB9 |
| surface | #353747 | success | #A3CBA7 |
| separator | #343643 | working | #E4C386 |
| subtleSeparator | #2C2E3A | alert | #E2A7B6 |
| selection | #353649 | attention | #FF9F0A |
| mist | #B3B5C6 | diffAdd | #83BC91 |
| muted | #A0A3B4 | diffRemove | #D997A2 |
| text | #E4E5ED | diffHunk | #A6BAFF |
| crust | #15161E | warning | #DFB38E |
| | | code | #CFB8E8 |

- Radii: `cardRadius` 16, `compactRadius` 10.
- Spacing: `pagePadding` 18, `cardPadding` 16, `rowSpacing` 12.
- HerdrTheme defines no fonts.

**HerdrProse** (APP/Design/HerdrProse.swift) uses system fonts scaled from Dynamic Type text styles (l.93-99).

| Role | Base size | Text style |
|---|---|---|
| body / quote / listItem | 15 | body |
| h1 | 20 | title2 |
| h2 | 17 | title3 |
| h3 | 15 | headline |
| h4 | 13 | subheadline |
| h5 | 12 | footnote |
| h6 | 11 | caption |
| tableHeader / tableCell | 14 | callout |

- Headings and table headers are semibold; quotes are italic.
- `blockSpacing` 12, `turnSpacing` 28, `subOutputOpacity` 0.78.
- Inline code: base × 0.9, monospaced medium, color `HerdrTheme.code`.
- `lineSpacing` = base × 0.35 (5 for body). `headingTopSpacing` is 12 for levels up to 2, 6 for level 3, otherwise 2.
- Inter TTFs are bundled but only checked for availability (l.137-139).
- First Mate views use plain system text styles, not HerdrProse.

**FirstMatePalette, iOS branch** (SH/FirstMatePalette.swift:48-56). Only seven tokens, versus about 18 on the Mac. Hex values are approximate conversions.

| Token | Dark | Light |
|---|---|---|
| background | #1A1C26 | #FCFCFF |
| sidebar | #13161F | #F2F4F9 |
| surface | #242633 | #F4F5F9 |
| accent | #B3ABFF | #6152B3 |
| text | #E8EBF7 | #1F2433 |
| secondaryText | #ADB5CC | #596178 |
| line | text at 12% | text at 12% |

**Status label** (FirstMateStatusLabel.swift:43-53)
- Waiting states: system orange in dark, about #8C590D in light.
- Complete: system green in dark, about #1F6E57 in light.
- Failed: red. Running states: accent. Otherwise: secondaryText.
- Pill: footnote medium, padding 10×7, color at 10% as the capsule fill.

**SkimStyle** (APP/Views/Shared/SkimStyle.swift:42-97)
- `.firstMate(scheme)`: source surface #121319 (dark) / #F0F1F5 (light); code surface #0E0F14 / #FFFFFF. Attention is #FF9F0A in dark and (0.55, 0.35, 0.05) in light; the light alert is about #A62142.
- `.hud`: source surface is crust, code surface #101118, fonts come from HerdrProse.

**ChatTabColor** (APP/Design/ChatTabColor.swift): lavender #B9A7DF, iris #969ED4, rose #CD9FAB, clay #C6AD96, sage #9DB9AE, slate #95B2C8. Row fills blend over #191A23 at 16%, or 20% when selected.

**Other palettes**
- The AccentColor asset is about #89B4FA, but the root `.tint` overrides it.
- The widget's HerdPulseTheme (ROOT/herdr-harness-ios/HerdPulseWidgets/HerdPulseTheme.swift) is an older Catppuccin-like palette that does not match HerdrTheme: ink #181825, graphite #1E1E2E, elevated #313244, mist #A6ADC8, text #CDD6F4, accent #89B4FA, signal #94E2D5, working #F9E2AF, alert #F38BA8.

**Shared visual components**
- `HerdrBackground` is just `HerdrTheme.ink.ignoresSafeArea()`.
- `GlassCard` is **opaque**: a graphite background, radius 16 by default, and a 1 pt surface stroke at 0.85 opacity. There is no blur. It is used in the Attention, Activity, Onboarding and Fleet screens, not in First Mate.
- `HerdrStatusDot` draws `status.terminalGlyph` ("●" for blocked/done/working, "○" for idle, "·" for unknown) in bold monospaced body text, colored:
  - blocked → alert
  - done → signal
  - working → working
  - idle → success
  - unknown → muted
- `StatusRail` is a 4 pt capsule; the working state glows at 0.35→0.95 over 1.15 s.
- `AgentStatusBadge` is a capsule filled at 0.11 opacity with a 0.28 opacity stroke.
- `ConnectionState.color`: live → signal, connecting → accent, demo → mist, failed → alert, disconnected → muted.

**No purple, dusk or glass surfaces on iOS; it is still "charcoal chrome"**
- The source says so directly: README.md:70, HerdrTheme.swift:4, ChatTabColor.swift:3.
- Lavender is used only as an accent.
- Materials that do appear: `.bar` (FirstMateChatView.swift:75), `.ultraThinMaterial` (PiChatView.swift:65, PiChatTimelineView.swift:183), `.regularMaterial` (ToastView.swift:14).
- There are no `glassEffect` calls. System bars get iOS 26 glass automatically, and `.sharedBackgroundVisibility(.hidden)` opts toolbar items out (FirstMateInspectorPresentation.swift:48, FirstMateResourceSheet.swift:73).
- The dusk styling exists only on the Mac (ROOT/herdr-harness-mac/herdr-harness-mac/Design/HerdrGlass.swift and the Mac's HerdrTheme.swift).

**Dark mode**
- The app is **forced dark**, except that the First Mate tab follows its own appearance setting (HerdrHarnessApp.swift:25).
- Car mode forces dark (CarModeView.swift:59), and many sheets force a dark toolbar.

## 4. Reusable building blocks

**PromptComposerView** (APP/Views/Pane/PromptComposerView.swift) is **tied to a pane**.
- The initializer requires `model`, a `HerdrPane`, a `HerdrWorkspace`, a draft binding, attachments bound as `[TerminalAttachment]`, focus requests, an optional `PiPromptComposerConfiguration`, and a response audio player (l.37-60).
- Attachments and voice:
  - Attach offers Photos (`PhotosPicker`, capped by `AttachmentPolicy.maximumCount`) or Files. Uploads go to `model.uploadAttachment(... to: workspace)`, i.e. `POST /api/v1/workspaces/{id}/attachments` (l.666-701).
  - Hold-to-dictate uses `HerdrQuickVoiceCapture` and locks after 2.65 s. A locked dictation mode is also available.
  - A full voice-note sheet (`HerdrVoiceNoteRecorderSheet`) can record, then save as an attachment or transcribe into the draft.
  - The More menu has file search, Jira, Paste code, and terminal keys.
- Sending:
  - Uploaded files become "Attachment: \`path\`" lines, and dictated text gets a transcription caveat (`submissionMessage`, l.886-903).
  - It then calls `piConfiguration.submit` or `model.sendPrompt(to: pane)`.
  - Drafts clear only if unchanged, keyed by pane ID in `model.paneDrafts` (l.844-884).
- The model and thinking pickers are `PiComposerOptionsBar` → `PiModelPickerChip` / `PiThinkingLevelChip`, driven by `PiPromptComposerConfiguration` (PiPromptComposerConfiguration.swift). That type carries Pi capabilities and `PiAvailableModel`s, which are not First Mate types.
- Pieces that can be lifted out: `ComposerAuxiliaryBar` (ComposerAuxiliaryBar.swift:4-19), `ComposerAttachmentTray(attachments:retry:remove:)`, `ComposerPhotoPreparationState`, `ComposerCodeBlockPaste`, `AttachmentPolicy`, `TerminalAttachment` / `UploadedAttachment` (Models/WorkspaceToolModels.swift:239, 261).

**Voice**
- `HerdrVoiceRecorder` (Views/Pane/HerdrVoiceRecorder.swift): AVAudioRecorder, 16 kHz mono 16-bit WAV, 10-minute cap, 40-sample meter, complete file protection. The microphone permission prompt is handled at l.110-132.
- `HerdrQuickVoiceCapture` (HerdrQuickVoiceCapture.swift): phases idle, recording, locked, transcribing; minimum 0.5 s; `endHold(transcribe:)` returns `.transcript`, `.tooShort`, `.failure` or `.cancelled`.
- `HerdrVoiceNoteRecorderSheet(save:transcribe:insertTranscript:cancel:)`, `HerdrVoiceWaveform`, and `CarVoiceCaptureView`.
- Transcription runs through `HerdrAppModel.transcribeVoiceNote(at:)` (l.744-780):
  - Parakeet via `POST /api/v1/voice/transcriptions` (120 s timeout) on the **primary, i.e. first, machine** (l.755, 2327-2329).
  - Falls back to `AppleVoiceTranscriber` (SpeechAnalyzer).
  - Demo mode returns canned text.
- Stale recordings are cleaned at launch (HerdrAppDelegate.swift:34).

**Skims** (APP/Views/Shared/)
- `SkimmableReply(messageID:reader:style:state:fullReply:)`:
  - Shows one sentence, caveats, a "Rest of the original" chip, the next step, and a Skim / Full reply toggle.
  - Excerpts open as a sheet on compact width and a popover on regular width (l.43-308).
- `SkimReadingState` (@Observable, owned per chat; "Show in reply" scrolls via `ScrollViewProxy.revealSkimTarget`), `SkimExcerptView`, `SkimSegmentedReply`, `SkimCodeBlockView` with `SkimCodeHighlighter`, `SkimText`, `SkimDisplay.hasContent`.
- Readers come from `FirstMateSkimReader.cached(skim:reply:owner:)` in the shared folder.

**Markdown**
- `PiMarkdownParser.parse` returns `[PiMarkdownBlock]`: paragraph, heading, code, list, quote, table, thematicBreak (Models/PiMarkdownParser.swift, PiMarkdownBlock.swift).
- `PiMarkdownText.render` is the inline renderer: `AttributedString` with inline-only markdown, cached.
- First Mate path: `FirstMateDocumentContentView(source:)` → `FirstMateMarkdownBlockView` / `ListItemView` / `TableView`. It is **scheme-aware**, with plain monospaced code blocks.
- Pi path: `PiMarkdownMessageView` / `PiMarkdownBlockView` use HerdrProse and are **dark only**; `PiMarkdownText` hard-sets `HerdrTheme.text` (PiMarkdownText.swift:33-37).
- `CarMarkdownView` also exists.

**HUD Chats** (Views/Agent/HudChat*.swift, State/HudChatStore.swift, Models/HudChat.swift)
- Saved headless-agent threads on one machine at a time.
- Endpoints: `GET /api/v1/hud-chats`, `/api/v1/hud-chats/{id}`, and `POST /api/v1/agent-runs` with profile `hud-chat-v1`.
- Reached from `HudChatsDestinationButton` in the Agents list, then `WorkspaceRoute.hudChats`.
- The catalog and the conversation swap inside one view (`store.isShowingConversation`); there is no push.
- Conversations are prompt/response turns (`HeadlessAgentRun`), using the agent model catalog and a thinking menu. They also have folder choice, stop-latest-run, and a read-only state once promoted to a pane.
- Always dark HerdrTheme. Uses `SkimmableReply(style: .hud)` and `PiMarkdownMessageView`.
- **How it differs from First Mate:** no multi-host aggregation, no feature workflow, no scheme support, and turn cards instead of messages.

**Toast and haptics**
- `ToastView`: `model.toastMessage`, overlay at AppRootView.swift:63-70, auto-dismiss after 2.2 s, regularMaterial capsule.
- `HerdrHaptic`, 16 cases (Design/HerdrHaptic.swift), fired through `HerdrHapticPulse.fire` and `.herdrHaptic(trigger:)` (HerdrHapticModifier.swift).
- **First Mate uses neither toast nor haptics.**

## 5. Networking and auth

**HerdrAPIClient** (APP/Infrastructure/HerdrAPIClient.swift)
- `actor HerdrAPIClient: FirstMateClient` (l.6), initialized with `(configuration:session: .shared)`.
- `makeRequest` sends `Accept: application/json` and `Bearer <token>` (l.825-840).
- Errors decode `{"error":{"code","message"}}` into `APIError.server(status:message:)` (l.889-895; APIError.swift).
- First Mate endpoints implemented (l.21-143):

| Call | Endpoint |
|---|---|
| models | `/api/v1/first-mate/models` |
| capabilities | `/first-mate/capabilities` |
| model settings | `/features/{id}/model-settings` |
| list | `/features?view=` |
| snapshot | `/features/{id}` |
| create | `POST /features` |
| send message | `POST /features/{id}/messages` `{text, request_id}` |
| actions / archive | `POST /features/{id}/actions` |
| document | `/documents/{id}` |
| session | `/sessions/{id}?limit=100&before=` |
| feedback | feedback routes |
| **fleet summary** | `/first-mate/fleet` |
| **read marker** | `POST /features/{id}/read` `{through_message_id}` |
| **HUD label** | `POST /features/{id}/hud` |

  - IDs are validated: alphanumerics plus `-_.:`, at most 256 characters (l.134-143).
- **Not implemented on iOS**, so the protocol defaults throw `invalidResponse` (SH/FirstMateClient.swift:238-296): `uploadFirstMateAttachment`, `transcribeFirstMateVoice`, `saveFirstMateLink`, `setFirstMateLinkVisibility`, `fetchFirstMateLead`, `ensureFirstMateLead`. `sendFirstMateMessage(... context:)` falls back to a plain send.

**Timeouts** (`timeoutInterval`, l.842-887)

| Requests | Timeout |
|---|---|
| health / network | 8 s |
| response-audio capabilities | 8 s |
| other response-audio | 150 s |
| end-pi-and-close, reserved-shell, quick Pi | 75 s |
| `POST agent-runs` | 90 s |
| other agent-runs / hud-chats | 30 s |
| `GET *events` / `*stream` | 24 h |
| `*/attachments` | 90 s |
| voice transcription | 120 s |
| jira / git / skills / files | 30 s |
| **everything else, including all First Mate calls** | **15 s** |

**Event stream**
- `events()` reads SSE from `/api/v1/events` (l.578-609).
- Handled events: `snapshot.updated`, `alert.*`, `alerts.read_state_changed`, `stars.changed`, `pi.*`, `push.delivery` (HerdrAppModel.swift:2370-2384). None are First Mate events.

**Machines and credentials**
- `HerdrMachine {id, name, urlString, role?}` (Models/HerdrMachine.swift), saved as JSON under `herdr.machines` (HerdrAppModel.swift:2576-2584). It can be seeded from a bundle `HerdrBootstrap.plist` restricted to https or loopback http (l.13-25).
- `ServerConfiguration(urlString:token:)` accepts https, or http only for localhost (Models/ServerConfiguration.swift).
- Each machine gets a `MachineRuntime` with its client and connection (HerdrAppModel.swift:8-21), plus `machineStates` and an aggregate `connectionState`.
- `add`, `update`, `remove` and `reorder` of machines (l.378-438, 2214-2247) each bump `connectionGeneration`.
- UI: Settings (SettingsView.swift:44-88) → `MachinesView` (reorder with `onMove`) → `MachineEditorView`. The editor's Test runs `/api/v1/health` then `/api/v1/network` and auto-names the machine (MachineEditorView.swift:107-135).
- Tokens live in the Keychain:
  - `KeychainCredentialStore` / `KeychainStore` use a generic password. The service is `HerdrKeychainService` or the bundle ID; the account is `api-token.<machineID>`.
  - Accessibility is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, with legacy migration paths (Infrastructure/KeychainStore.swift:5-79).
  - The `@MainActor protocol HerdrCredentialStore` can be injected (HerdrCredentialStore.swift).
  - `MachineEditorView.swift:20` reads `KeychainStore` directly instead of going through that protocol.

**Capability detection**
- First Mate calls `GET /first-mate/capabilities` on every refresh (SH/FirstMateStore.swift:397-409, 488-504).
- Flags: `first-mate-archive-v1`, `-attachments-v1`, `-context-v1`, `-safe-model-settings-v1`, `-journal-events-v1`, `-feedback-v1`, `-links-v1`, `-fleet-v1`, `-lead-v1`, `-lead-peers-v1` (SH/FirstMateClient.swift:135-148).
- The iOS host mirror omits the fleet and lead flags.
- Other capability checks:
  - `GET /api/v1` for `pane-retirement-v1`
  - `/agent-runs/capabilities` for `hud-chat-v1`
  - `/response-audio/capabilities`
  - `/push/status` for `apns.configured`
  - Pi semantic capabilities per pane

## 6. Push and background

**Remote notifications**
- Registration: `prepareSmartAlerts` (l.1576-1584) calls `NotificationManager.requestAuthorization` then `registerForRemoteNotifications`.
- Device sync: the delegate's token goes to `registerPushDevice` (l.1586-1592), then `syncPushDevice` (l.1947-1977). That posts `/api/v1/push/devices` with `{deviceToken, bundleId, environment (sandbox|production), machineId}`, then reads `/push/status`.
- Push types that exist today:
  1. **Server APNs alerts for panes.** Payload keys `pane_id` and `machine_id`; a tap opens the pane in Agents.
  2. **Local fallback alerts.** `NotificationManager.post` fires when a `push.delivery` event reports zero sent (l.2166-2190). Blocked alerts are time-sensitive; there is a 60 s grace period (Infrastructure/NotificationManager.swift:42-68).
  3. **Live Activity token pushes.**
  4. **A local test notification.**
- Badge: `NotificationManager.setBadge(unreadAlertCount)` counts pane alerts only (HerdrAppModel.swift:1940-1945).
- Not present: notification categories or actions, thread identifiers, a notification service extension, `UIBackgroundModes`, or background tasks.

**Herd Pulse Live Activity**
- `HerdPulseCoordinator` (Infrastructure/HerdPulseCoordinator.swift) is fed by `HerdPulseAggregate(workspaces, alerts, pendingReadPaneIDs, revealTitles, connectionState)` (AppRootView.swift:101-112).
- The user turns it on with `HerdPulseButton`, which lives in AgentsHeader.swift:55; the setting is `herdr.herdPulse.enabled`.
- It calls `Activity.request(pushType: .token)`. The stale date is 15 minutes, or immediately when offline. Relevance: attention 100, ready 80, working 50, resting 20, offline 10.
- Token updates go to `POST /api/v1/live-activities` with retries at 1/2/4/8/15/30 s (HerdPulseRegistrationClient.swift, HerdPulseRegistrationRetryPolicy.swift).
- `HerdPulseAttributes.ContentState` holds pane counts and sessions (HerdrPulseShared/HerdPulseAttributes.swift).

**There is no First Mate push, badge, notification route or Live Activity content today.**

## 7. Tests

**IOSNativeRenderHarness** (T/IOSNativeRenderHarness.swift)
- `render(_:width:dynamicType:)` hosts the SwiftUI view in a `UIHostingController` inside a `UIWindow` on the test host app's scene.
- It **forces `.dark`** traits (l.91, 101) and fills with the **ink** background (l.65, 125).
- It sizes with `sizeThatFits` (maximum height 10,000), draws with `drawHierarchy`, and collects frames from DEBUG-only `.composerLayoutMeasurement(id:label:)` anchors (APP/Views/Pane/ComposerLayoutMeasurement.swift).
- Dynamic Type fixtures: `.defaultSize` and `.accessibility3`.

**Where render tests write PNGs** (also saved as XCTAttachments with `.keepAlways`)
- IOSMobileV2RenderTests: `$HERDR_IOS_RENDER_DIR`, else temp dir `herdr-ios-mobile-v2-renders`, plus `-geometry.txt` files (l.506-549). It also prints `HERDR_IOS_MOBILE_V2_RENDER_DIR=`. Widths tested: 320/375/402/430.
- PromptComposerAttachmentRenderTests: the same environment variable, else `herdr-ios-prompt-composer-renders`.
- IOSSkimRenderTests: `/tmp/herdr-ios-skim-render` (renders FirstMateMessageView skims).
- IOSChatSpaceRenderTests: `/tmp/herdr-ios-chat-space-render/synthetic-conversation.png`.
- Car mode, compaction and agent-card tests write under the temp directory.
- UI screenshots: `/tmp/herdr-first-mate-ios-screens/<name>.png`, with an "iphone" → "ipad" rename when the window is wider than 700 (HerdrFirstMateUITests.swift:143-156).

**Unit tests**
- First Mate mobile tests use **Swift Testing** (`import Testing`, `@MainActor struct`, `@Test`, `#expect`):
  - FirstMateMobileFleetTests: scope, aggregation, stale hosts, rotation, `attentionCount`.
  - FirstMateMobileLifecycleTests.
  - FirstMateMobileRoutingTests: fake `FirstMateClient` actors.
- They use isolated `UserDefaults(suiteName:)` and `TestCredentialStore`.
- Render tests use XCTest. The 15 files in HerdrFirstMateSharedTests also run in the iOS unit target.

**UI test conventions**
- Launch arguments:
  - `-HerdrFirstMateDemo`, `-HerdrResetFirstMateScope`
  - `-herdr.firstMate.appearance light|dark`, `-herdr.smartAlerts NO`
  - `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge`
  - `-HerdrDemoMode` (opens on Agents)
  - Server fixture: `-HerdrUITestServerURL`, `-HerdrUITestAPIToken`, `-HerdrOpenFirstMate`, used with `scripts/first-mate-ios-fixture.py --port 9196`
  - `-HerdrResetSidebarState`, `-HerdrPiOptionsFixture`
- Demo data: machines `demo1` "desktop" and `demo2` "laptop"; features `demo-session-continuity` (on both), `demo-search`, `demo2-release-checklist`.
- Accessibility IDs: `first-mate-feature-<m>-<f>`, `first-mate-machine-picker`, `first-mate-new-feature`, `first-mate-composer`, `first-mate-send`, `first-mate-message-<id>`, `first-mate-open-workflow`, and `first-mate-create-*`.
- The `tapTab` helper copes with the iPad floating tab bar.
- UI test files: HerdrFirstMateUITests, HerdrFirstMateMachinesUITests, HerdrFirstMateNavigationUITests (needs ad hoc signing for the Keychain), HerdrFirstMateServerUITests (skips when the fixture is absent).

**CI** (ROOT/.github/workflows/verify.yml)
- Job `ios` (l.94-108) runs on `macos-26`, timeout 30 min, with no pinned Xcode.
- The simulator is the first available iPhone on an "iOS-26" runtime (found via `simctl`).
- Command: `scripts/ci-xcode-test.py` with `-scheme herdr-harness-ios`, `CODE_SIGNING_ALLOWED=NO`, `-only-testing:herdr-harness-iosTests`, `-parallel-testing-enabled NO`. It retries only failed tests. **UI tests are not run in CI.**
- The job is gated by `scripts/ci-plan.py:26`, which matches changes under `herdr-harness-ios/`, `HerdrFirstMateShared/`, `HerdrFirstMateSharedTests/`, or `verify.yml`.

## 8. What already exists toward a messaging list, and gaps

- **No TODO, FIXME or HACK markers** anywhere in the iOS sources. No iMessage-style or pinned-conversation concepts.
- **No First Mate unread state or badge.**
  - `FirstMateMobileFleetStore.attentionCount` (l.304-313) is computed and tested, but AppRootView badges only Attention (l.128).
  - "Unread" on iOS today means pane alerts only: `unreadPaneIDs`, the sidebar Unread section, and agent-card dots.
- **The data layer for a message list is compiled in but unused** (all in SH):
  - `FirstMateFleetEntry` / `FirstMateFleetResponse` (SH/FirstMateFleet.swift:78-204) carry `label`, `emoji`, `hudStatus`, `stepIndex`, `now`, `latestMessage` (with `skimSay`), `readThroughMessageID`, `unread`, `workingOnReply`, `activityAt`.
  - Also `FirstMateHudStatus.needsYou`, `FirstMateDefaultEmoji`, `FirstMateChatSteps`.
  - `FirstMateDemo.chatWindowFeatures`, `chatWindowLead` and `chatWindowFleet` (SH/FirstMateChatDemo.swift:12-87).
  - `FirstMateLeadSummary` and `FirstMateMention`.
  - HerdrAPIClient already implements `fetchFirstMateFleet`, `markFirstMateRead` and `updateFirstMateHud` (l.74-96) with no callers.
  - `FirstMateFeature.dashboardSummary` (`latestMessage`, `latestMessageAt`, `needsUser`, `activityAt`, `awaitingTurn`) arrives in every list response but iOS never displays it.
- The Mac chat window is the reference implementation (ROOT/herdr-harness-mac/herdr-harness-mac/FirstMate/ChatWindow/: FirstMateReadState, FirstMateChatSidebar, FirstMateChatBubble, FirstMateBadge, FirstMateConversation, and others). ROOT/docs/first-mate/chat-window/BUILD-SPEC.md:171 says "iOS and the web can adopt read markers later."
- **Deep links:** mention links of the form `herdr://first-mate?feature_id=…` (BUILD-SPEC.md:136) are not routed on iOS. `HerdrAppModel.open(url:)` handles only car mode and panes (l.1655-1692).
- **Lead First Mate:** unavailable on iOS because the client lacks the lead endpoints.
- **Composer:** the First Mate composer has no attachments, voice or model controls, even though the store and host already mirror those capabilities.
- **Background freshness:** polling happens only in the foreground on the First Mate tab. There is no push or SSE.
- **Voice routing:** transcription always uses the first machine.
- **Drafts:** kept in memory per feature only.
- **Rendering:** the render harness only renders dark, so light First Mate renders would need a light variant.
- **Sign-off status:** the acceptance checklist in ROOT/docs/ios-mobile-v2-implementation.md:456-485 is still unchecked. ROOT/docs/ios-chat-space.md:83-86 records that the build 42/43 tests were written but held back until the final gate.
