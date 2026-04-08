# Suggestions

Scope notes:
Audio workaround stays. I did not include "remove the silent playback hack" as a suggestion.
I am also not recommending a deep rewrite to `Network.framework`, `kqueue`, or an async reactor. For the stated target of 1-2 users and about 400 Mbps, the current thread-per-connection shape is acceptable.

1. [x] Increase the TCP relay buffer size and stop paying the accounting cost every 1 KB.
`copyloop()` currently moves data through a 1024-byte buffer and records totals on every chunk (`TwoSocks/microsocks/sockssrv.c:444-477`). At roughly 400 Mbps that turns into tens of thousands of `read`/`write` iterations and global counter updates per second per direction. A moderate bump to something like 16-64 KB is a direct CPU win without changing the design, and it makes per-transfer accounting much cheaper.

2. [ ] Replace the global transfer-total mutexes with atomics or with coarser-grained flushing.
`record_downloaded_bytes()` and `record_uploaded_bytes()` take a process-wide mutex for every chunk in both the TCP and UDP loops (`TwoSocks/microsocks/sockssrv.c:117-142`, `TwoSocks/microsocks/sockssrv.c:473-476`, `TwoSocks/microsocks/sockssrv.c:726`, `TwoSocks/microsocks/sockssrv.c:788`). That is fine at low traffic, but it becomes unnecessary hot-path contention once the proxy is moving real volume. This is a good place for `stdatomic` counters or for per-connection byte accumulation that flushes less often.

3. [x] Fix `copyloop()` so `poll()` hangups and errors cannot make it read from the wrong socket.
After `poll()`, the code only checks `POLLIN` and then picks `fd1` or `fd2` with a single ternary (`TwoSocks/microsocks/sockssrv.c:454-470`). If `poll()` wakes because one side has `POLLHUP` or `POLLERR` without `POLLIN`, this logic can choose the other socket and block on a fresh `read()` even though the event came from the first one. This is a correctness issue first, but it also creates avoidable stalls in the TCP hot path.

4. [x] Stop truncating UDP payloads at 1024 bytes.
`copy_loop_udp()` allocates `MAX_SOCKS5_HEADER_LEN + 1024` and explicitly comments that it only supports up to 1024 bytes of payload (`TwoSocks/microsocks/sockssrv.c:554-555`). That is below common QUIC packet sizes and well below what SOCKS5 UDP clients may legitimately send, so larger datagrams can be clipped or broken silently. A larger scratch buffer or explicit oversize handling would improve real-world UDP behavior more than most other changes here.

5. [x] Do not tear down the whole UDP association when one remote destination fails.
Several UDP error paths set `association_failed = 1` and jump to `UDP_LOOP_END`, which closes every tracked UDP socket for that client association (`TwoSocks/microsocks/sockssrv.c:615-627`, `TwoSocks/microsocks/sockssrv.c:631-677`, `TwoSocks/microsocks/sockssrv.c:719-724`, `TwoSocks/microsocks/sockssrv.c:773-787`, `TwoSocks/microsocks/sockssrv.c:792-810`). That means one bad resolve, one unreachable target, or one send failure can kill unrelated UDP flows that were otherwise fine. The better tradeoff is to fail that destination, emit its error event, and keep the association alive.

6. [x] Close the leaked UDP sockets on `udp_svc_setup()` failure paths.
`udp_svc_setup()` returns early on `connect()`, `getaddrinfo()`, and `bind()` failures without consistently closing the socket it already opened (`TwoSocks/microsocks/sockssrv.c:833-885`). Repeated bad UDP_ASSOCIATE attempts can slowly consume descriptors. This is not a rewrite, just error-path hygiene that matters once clients misbehave.

7. [ ] Batch or defer `UserDefaults` writes for lifetime byte totals.
The Swift layer polls native totals every 0.5 seconds and immediately persists lifetime counters whenever the values changed (`TwoSocks/ContentView-VM.swift:391-425`). Under sustained traffic, that creates steady write churn for data that is not latency-sensitive. Keeping the UI refresh cadence is fine; the expensive part is the persistence frequency, which should be coarser.

8. [ ] Fix the proxy start lifecycle so it can recover from late network availability and early bind failures.
`startProxyIfPossible()` only runs on `onAppear()`, and `hasStartedProxy` is latched before `socks_main()` has actually proven that the listener came up (`TwoSocks/ContentView.swift:186-197`, `TwoSocks/ContentView-VM.swift:261-285`). If `bridge100` or `en0` appears later, or if the listener fails once, the app gets stuck until restart. This is one of the bigger practical quality issues outside the packet loops.

9. [ ] Buffer the small SOCKS handshake stages instead of assuming each stage arrives in one `recv()`.
`clientthread()` drives method selection, optional username/password auth, and the request header directly from whatever a single `recv()` returned (`TwoSocks/microsocks/sockssrv.c:888-925`). On a local network this usually works, but TCP does not preserve message boundaries, so partial handshakes can be rejected unnecessarily. This is not a throughput optimization, but it is a real protocol robustness gap.

10. [ ] Leave the O(n) UDP destination lookup alone for now, but mark it as the next thing to revisit if one client starts multiplexing many UDP peers.
Each UDP packet does a linear search by destination address or by fd through `sblist_search()` (`TwoSocks/microsocks/sockssrv.c:608-612`, `TwoSocks/microsocks/sockssrv.c:734-739`, `TwoSocks/microsocks/sblist.c:82-90`). For the current target load, this is probably not worth complicating. It only becomes interesting if a single SOCKS association starts tracking lots of remote UDP endpoints at once.

11. [ ] Clean up the small but real source-of-truth drift around UDP support and logging.
The embedded `microsocks` docs and usage text still mention `-b bindaddr` and even say "no UDP at this time" despite the fork adding UDP support (`TwoSocks/microsocks/README.md:7-9`, `TwoSocks/microsocks/README.md:50`, `TwoSocks/microsocks/README.md:70`, `TwoSocks/microsocks/sockssrv.c:1045`). There are also UDP-path `dprintf(1, ...)` calls that bypass `quiet` and write to stdout directly (`TwoSocks/microsocks/sockssrv.c:531`, `TwoSocks/microsocks/sockssrv.c:570`, `TwoSocks/microsocks/sockssrv.c:596`). These are not major performance issues, but they make the fork harder to reason about and noisier to debug.
