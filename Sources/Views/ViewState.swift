import SwiftUI

/// SwiftUI's `State` property wrapper, under a name that is not also a macro.
///
/// The macOS 27 SDK redeclares `@State` as a macro whose implementation
/// (`SwiftUIMacros`) ships only with Xcode, so a Command Line Tools build fails
/// at every `@State`; a module-level `State` alias does not help, because macro
/// lookup wins over it. This alias names the property wrapper type directly, so
/// view state compiles — with identical semantics — on every SDK Cue supports
/// (macOS 14 through 27) and with or without Xcode.
/// `script/test_macos27_toolchain.py` rejects bare `@State` in the app sources.
typealias ViewState = SwiftUI.State
