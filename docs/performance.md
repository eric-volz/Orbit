# Performance

Orbit has to feel instant: it opens on a shortcut, searches while you type and streams long answers. This page
lists the performance targets, the measurements behind them, how to measure yourself, and what to keep in mind when
you change code on a hot path.

**On this page**

- [Targets](#targets)
- [Measurement setup](#measurement-setup)
- [Results](#results)
- [The one hotspot: finishing a long answer](#the-one-hotspot-finishing-a-long-answer)
- [Measuring by hand](#measuring-by-hand)
- [Tips for contributors](#tips-for-contributors)

## Targets

- Instant results within 150 ms of typing.
- The panel on screen within about 50 ms of the shortcut.
- No CPU use while the panel is hidden.
- Low memory, also after many chats (closing the panel only hides it, so Orbit keeps running).
- Smooth scrolling and streaming in long chats.
- A quick launch.

## Measurement setup

The numbers below were measured on an Apple silicon Mac running macOS 27, with:

- a debug build under its own bundle ID (`ORBIT_BUNDLE_ID`, see
  [development.md](development.md#building-the-app-with-build-appsh));
- invented data (`ORBIT_DEBUG_FAKE_PERSONAL_DATA` and `ORBIT_DEBUG_FILE_SCOPE`, see
  [development.md](development.md#debug-environment-overrides));
- [FakeLLMServer](development.md#fakellmserver) as the model and [orbitctl](development.md#orbitctl) to drive the app;
- the panel never shown.

Times are medians of several runs. Measurements that need the panel on screen are done
[by hand](#measuring-by-hand).

## Results

| What | Before the tuning pass | After |
|---|---|---|
| Launch: process start → "Orbit launched" (unified log) | ≈ 100 ms (≈ 125 ms until it answers `orbitctl`) | unchanged |
| Main thread in `applicationDidFinishLaunching` | ≈ 38 ms: panel and its SwiftUI view 16.5, main menu 10.5 (mostly macOS's own), menu bar item 5.5, services and environment 5.5 | unchanged |
| Idle with the panel hidden, 60 s | 0.0% CPU, no CPU time used, no wakeups, also after 35 chats | unchanged |
| Memory (`footprint`) | 25 MB after launch; ≈ 37 MB after 50 chats, no further growth; `leaks`: 20 KB once at launch (system frameworks), not growing | 25 MB; ≈ 39 MB after 35 chats |
| Instant search | First results 80 ms after the last keystroke (the debounce) + 1 to 4 ms ranking 500 apps | unchanged |
| Streaming into a long chat, per published delta | 0.2 / 1.2 / 2.7 ms with 20 / 200 / 600 rows | unchanged |
| An answer that finishes streaming | 18 / 65 / 165 / 350 ms for 1,700 / 6,600 / 16,600 / 33,000 characters (built again as a whole) | 2.1 / 6.4 / 14 / 26 ms; an answer of one paragraph or one code block (6,000 to 8,000 characters) under 1 ms |
| VoiceOver's plain text of a finished answer (also built without VoiceOver) | 0.9 / 3.2 / 7.5 / 15 ms for 1,700 / 6,600 / 16,600 / 33,000 characters, 44 ms for 100,000 (all of it converted) | 0.9 / 3.6 / 3.6 / 3.6 ms, also for 100,000: only the first 6,000 characters are converted (VoiceOver reads 2,000) |
| A richly formatted answer (headings, lists, a table, code; 1,600 characters) appearing in the chat | ≈ 14 ms to build and lay out (half of it for selectable text); Markdown parsing 0.2 ms, inline styles 1.2 ms | unchanged |

## The one hotspot: finishing a long answer

The only hotspot was the end of an answer. When streaming finished, the complete answer was built again as a whole,
which caused a visible hitch for long answers (350 ms for 33,000 characters).

Now the finished answer is shown in the same view that already showed its beginning
([`AnswerParts`](../Orbit/UI/MessageView.swift)):

- While streaming, the finished paragraphs render as one view that does not change with further deltas, and only
  the growing last part is parsed again.
- When the answer ends, only the blocks that changed are built.

Everything else met the targets without changes:

- The main thread does little at launch.
- Nothing runs while the panel is hidden: Spotlight queries stop when they are done, the resize animation runs only
  while the panel resizes, the typing dots only while a request runs, and the folder watcher waits for FSEvents.
- Memory levels off.
- Long chats are built lazily, row by row, and streamed text is published at most 30 times a second.

## Measuring by hand

Three things need the panel on screen and are measured by hand: how long the panel takes to appear, memory with the
panel shown, and scrolling a long chat. They are part of the [manual acceptance checks](manual-qa.md).

### Panel timing

Orbit logs how long the panel took to appear: "Panel appeared in N ms" (subsystem `io.github.eric-volz.Orbit`, category
`panel`, info level).

1. Open Console, select your Mac, start streaming, and filter for `Panel appeared` (enable Action → Include Info
   Messages). Or in a terminal:

    ```sh
    log stream --level info --predicate 'subsystem == "io.github.eric-volz.Orbit" AND category == "panel"'
    ```

2. Open Orbit with the shortcut a few times. "Panel appeared in N ms" should stay near 50 ms or below.

### Memory and CPU

1. Open Activity Monitor and select Orbit.
2. Have 20 chats. Memory should level off instead of growing with each chat.
3. Close the panel. CPU should stay at 0%, also a minute later.

For exact numbers, use the command line tools that produced the table:

```sh
footprint Orbit          # the memory footprint
leaks Orbit              # leaked memory (repeat later: it must not grow)
```

### Long chats

1. Build a long chat with 30 answers (with FakeLLMServer, `#markdown` and long messages are quick ways to fill it).
2. Scroll with the trackpad and with Page Up and Page Down. Scrolling should stay smooth.
3. When a long answer finishes, the chat should not stutter.

## Tips for contributors

- **Keep the main thread free.** Do Spotlight queries, AppleScript runs, file reading, text extraction and database
  work off the main actor, and publish only the results.
- **Publish streamed text at most 30 times a second.** The agent loop batches deltas
  ([`AgentLoop.streamPublishInterval`](../Orbit/Agent/AgentLoop.swift), 33 ms). Do not publish per token.
- **Build long lists lazily.** Chat rows are built row by row as they scroll into view; keep views for finished
  content equatable so later updates do not rebuild them.
- **Do not rebuild what has not changed.** Follow the `AnswerParts` approach: split content into a stable part and a
  changing part.
- **Stop Spotlight queries when they are done.** A running query keeps Orbit busy while the panel is hidden.
- **Nothing runs while the panel is hidden.** Animations, timers and polling must stop when the panel hides; watch
  the file system with FSEvents instead of polling.
- **Measure before and after.** Use the setup above and compare medians of several runs. The unified log ("Orbit
  launched", "Panel appeared in N ms") gives cheap, repeatable numbers.
