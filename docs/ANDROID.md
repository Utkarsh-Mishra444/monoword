# Android version (not built yet)

Plan for when the Mac version has proven itself. Nothing here is implemented.

## How it would be reached from any app

- **Text selection menu.** An activity with an `android.intent.action.PROCESS_TEXT` intent filter
  (`text/plain`) adds "Read with Monoword" to the copy / share / select-all bar in apps that use the
  standard text selection (Chrome, for example). Long-press, pick it, done. No permission
  needed. Which other apps (the X app in particular) expose selectable text is not checked yet.
- **Share sheet.** `ACTION_SEND` with `text/plain`, for apps that share text rather than a link.
- **Quick Settings tile** reading the clipboard, for anything else.

## The reader

A translucent, dialog-themed activity over the current app (no overlay permission), the same
layout as the Mac panel: the word centred between guides, tap to pause (context
sentence shown), swipe left/right for sentence back/next, vertical drag for speed, volume keys
optional. Kotlin + Jetpack Compose, Canvas text drawing.

## The engine

`Sources/MonowordCore` (TextCleaner, Tokenizer, Frequency, Timing, ReadingSession, DoubleTap) has no AppKit and
no platform calls except hyphenation (`CFStringGetHyphenationLocationBeforeIndex`, replaceable by
`android.icu.text.BreakIterator` plus a small hyphenation pattern table, or by plain even
splitting). Port it to Kotlin file for file and port `Tests/MonowordCoreTests/CoreTests.swift`
with it, so both builds behave the same on the same text.

## Toolchain on this Mac

Android Studio is installed, with SDK platforms 34 to 36 and build-tools 34.0.0, 35.0.0 and
36.1.0 under `~/Library/Android/sdk` (listed 2026-10-19). A first Gradle build downloads its
dependencies (on the order of a gigabyte); the disk had 26 GiB free on 2026-10-19.
