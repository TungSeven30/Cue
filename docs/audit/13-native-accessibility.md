# Native controls, focus, and reduced motion

Preview sizing now has an AppKit NSStepper with native drawing and focus ring, accessible increment/decrement, and Up/Down keyboard adjustment. The existing drag and double-click reset remain available. Saved invalid heights are clamped before layout. Sidebar filters use system toggle-button styling and expose separate labeled selected states. Invisible tab-shortcut buttons are hidden from accessibility. Automatic transcript following and the repeating loading shimmer honor Reduce Motion.

| Relevant baseline | Before | After |
| --- | --- | --- |
| Resize affordance height | 13 pt | 28 pt |
| Exposed resize adjustment actions | 0 | 2: increment/decrement |
| Live keyboard resize after click | Unavailable | 280 → 300 on click → 320 on Up; Down returns to 280 |
| Individually exposed quick filters in observed AX tree | 0 (combined row description) | 5 labeled toggle controls |
| Follow animation when Reduce Motion is enabled | 200 ms | Disabled, including inherited animations |
| Repeating loading shimmer with Reduce Motion | Enabled | Disabled |

The live GUI pass caught missing mouse-to-keyboard focus despite the initial control unit tests; the accepted implementation fixes it and the captured native focus ring confirms the result. The final suite passes **492 Swift tests and 8 Python tests, zero compiler warnings**. New tests exercise the real AppKit control actions, key events, size bounds, invalid stored heights, and animation transactions.

Screenshots use the actual Cue ContentView and AppModel with synthetic media, paused at zero, 45 Japanese/Vietnamese cues, and the same window size. A separate audit entry point avoids production secrets, history, and updater behavior. AppKit Aqua, Dark Aqua, and both accessibility high-contrast appearance variants were visually checked. System-wide accent-color combinations and Reduce Transparency were not exhaustively tested. No dropped-frame or frame-rate improvement is claimed.

- [Before, dark](screenshots/13-workspace-before-dark.png)
- [After, dark](screenshots/13-workspace-after-dark.png)
- [After, light](screenshots/13-workspace-after-light.png)
- [Native keyboard focus ring](screenshots/13-native-focus.png)
- [High contrast light](screenshots/13-workspace-after-high-contrast-light.png)
- [High contrast dark](screenshots/13-workspace-after-high-contrast-dark.png)

Guidance: [Apple Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Apple accessible controls](https://developer.apple.com/documentation/swiftui/accessible-controls). No dependency or file-format changes.
