# Performance Review

## Scope

This is a static performance review of the current project layout and runtime code paths. It focuses on CPU, wakeups, thread churn, and thermal risk. I did not run Instruments in this environment.

## Highest-Impact Findings

### 1. Background audio keepalive is likely the biggest thermal drain

- `TwoSocks/ContentView-VM.swift:292-315` creates an `AVAudioPlayer`, configures it to loop forever, and starts playback.
- `TwoSocks/Info.plist:5-8` enables the `audio` background mode.
- `TwoSocks/blank.wav` is effectively empty. `afinfo` reports an estimated duration of `0.000023 sec`.

That means the app is asking Core Audio to loop an almost zero-length silent asset continuously just to remain alive in the background. Even if CPU usage is not extreme in isolation, this is exactly the kind of persistent subsystem activity that can make a phone warm during normal use.

Suggested optimization:

- Remove the audio keepalive entirely if possible.
- If background execution must stay, redesign around a legitimate background model rather than a continuously looping silent player.
- At minimum, replace the microscopic audio asset with a long silent track so the engine is not retriggering a near-empty sample continuously.

### 2. The UI polls and republishes state every 250 ms forever

- `TwoSocks/ContentView-VM.swift:242-255` starts a detached polling task that wakes every 250 ms.
- `TwoSocks/ContentView-VM.swift:258-275` assigns `runtimeStats` on every pass, even when nothing changed.
- `TwoSocks/ContentView.swift:88-159` recomputes all displayed metrics from that published state.
- `TwoSocks/ContentView.swift:120-147` and `TwoSocks/ContentView.swift:276-317` make the connection list part of each refresh cycle.

This keeps SwiftUI active 4 times per second regardless of whether the proxy is idle. On a phone, unnecessary wakeups and redraw-triggering state changes add up quickly.

Suggested optimization:

- Poll less aggressively. `1s` is probably enough for this dashboard.
- Stop polling when the app is backgrounded or when nothing meaningful is happening.
- Only publish `runtimeStats` when the snapshot actually changed.
- Consider pushing state changes from native code instead of polling if the app evolves further.

### 3. Logging and stats collection are on hot data paths

- `TwoSocks/microsocks/sockssrv.c:263-269` locks a global mutex every time transfer bytes are recorded.
- `TwoSocks/microsocks/sockssrv.c:485-519` updates those counters for every 1 KB TCP copy chunk.
- `TwoSocks/microsocks/sockssrv.c:678` and `TwoSocks/microsocks/sockssrv.c:734` do the same in the UDP path.
- `TwoSocks/microsocks/sockssrv.c:223-245` formats and enqueues connection logs.
- `TwoSocks/ContentView-VM.swift:9-23` drains those logs from Swift on each poll cycle.

The bookkeeping is simple, but it is currently placed in the most performance-sensitive loops. Under sustained traffic, that means extra locking and extra bridge work just to drive the dashboard.

Suggested optimization:

- Batch transfer counters per connection and flush them less often.
- Replace the stats mutex with atomics if you want low-overhead shared counters.
- Keep connection logging to lifecycle events only, not traffic events.
- Avoid draining and publishing from Swift when no new logs are available.

## Native Runtime Findings

### 4. Thread-per-connection design is expensive on mobile

- `TwoSocks/microsocks/sockssrv.c:60-65` sets the Apple thread stack size to 64 KB.
- `TwoSocks/microsocks/sockssrv.c:1042-1054` creates a new pthread for every accepted client.
- `TwoSocks/microsocks/sockssrv.c:930-940` and `TwoSocks/microsocks/sockssrv.c:1021-1022` linearly scan and collect completed threads.

This is workable for low connection counts, but phones see lots of short-lived network activity. Thread creation, context switching, stack reservation, and repeated thread cleanup cost more on a mobile device than on a desktop/server.

Suggested optimization:

- If connection counts are low, leave this alone until the bigger issues are fixed.
- If you want a real scaling improvement, move to an event-driven loop or a small worker pool instead of one thread per client.

### 5. TCP copy loop uses small buffers and locks on every chunk

- `TwoSocks/microsocks/sockssrv.c:505-517` uses a 1024-byte buffer and records stats after each chunk.

For higher-throughput transfers, a 1 KB buffer causes more read/write syscalls and more stats lock contention than necessary.

Suggested optimization:

- Increase the relay buffer size materially, for example to `8 KB` or `16 KB`.
- Accumulate byte counts locally inside the loop and publish to shared stats less frequently.

### 6. UDP association path does repeated linear searches and address rebuilding

- `TwoSocks/microsocks/sockssrv.c:636-639` linearly searches for an existing UDP target socket by address.
- `TwoSocks/microsocks/sockssrv.c:686-691` linearly searches again by file descriptor on receive.
- `TwoSocks/microsocks/sockssrv.c:698-723` rebuilds SOCKS address headers from string form for every packet.
- `TwoSocks/microsocks/sblist.c:82-90` confirms the lookup is O(n).

This is fine for very small UDP fanout, but it does not scale well if a client talks to many UDP endpoints or sends traffic continuously.

Suggested optimization:

- Keep a direct fd-to-entry mapping instead of re-searching the list.
- Cache the serialized SOCKS address header alongside each UDP peer entry.
- Pre-size the UDP peer list more aggressively if this path matters in practice.

## UI-Specific Findings

### 7. The log list does extra string and collection work during refresh

- `TwoSocks/ContentView-VM.swift:282-289` inserts each new log entry at the front of the array, which shifts existing elements.
- `TwoSocks/ContentView.swift:135` rebuilds `Array(viewModel.connectionAttemptLogs.enumerated())` during rendering.
- `TwoSocks/ContentView-VM.swift:152-180` repeatedly derives category, endpoint, and detail from the raw message string.
- `TwoSocks/ContentView.swift:292` formats the timestamp in the row body.

The list is capped at 150 entries, so this is not catastrophic, but it is easy cleanup and helps reduce unnecessary UI work.

Suggested optimization:

- Precompute parsed log fields once when the log entry is created.
- Avoid rebuilding an enumerated array in the view body.
- If the list grows in the future, store newest entries appended in display order that minimizes front inserts.

### 8. Polling continues even though some published state is unused

- `TwoSocks/ContentView-VM.swift:189` publishes `serverStartedAt`.
- The current SwiftUI view does not read that property.

This is a small issue, but it is a sign that the VM is doing some work with no visible payoff.

Suggested optimization:

- Remove unused published state or stop updating it until it is needed by the UI.

## Measurement Caveat

### 9. Debug builds will exaggerate heat and CPU cost

- `TwoSocks.xcodeproj/project.pbxproj:184` sets `GCC_OPTIMIZATION_LEVEL = 0`.
- `TwoSocks.xcodeproj/project.pbxproj:202` and `TwoSocks.xcodeproj/project.pbxproj:289` set `SWIFT_OPTIMIZATION_LEVEL = -Onone`.
- Startup arguments in `TwoSocks/ContentView-VM.swift:223` do not pass `-q`, so native logging remains enabled.

If the project is being tested from Xcode in Debug on a physical device, some amount of extra heat is expected relative to a Release build.

Suggested optimization:

- Measure on a Release build installed to device.
- Disable native stderr logging during performance profiling.

## Recommended Order

1. Remove or redesign the background audio keepalive.
2. Reduce or eliminate unconditional 250 ms polling and avoid publishing unchanged state.
3. Batch native transfer stats and reduce lock frequency in relay loops.
4. Increase relay buffer sizes and trim UI log-processing overhead.
5. Revisit the thread-per-connection architecture only if heat remains after the earlier fixes.
