# Suggestions

## Improvement Areas

1. Startup is brittle enough to stall or crash before the proxy starts.
   - `TwoSocks/ContentView.swift:14` force-dereferences `ifa_addr` during interface enumeration.
   - `TwoSocks/ContentView.swift:50` and `TwoSocks/ContentView.swift:56` only launch the server if a hard-coded `bridge100` or `en0` address exists.
   - On devices where that interface is absent, the app stays at `Starting...` even though the server itself could still bind.

2. Proxy lifecycle is not idempotent.
   - `TwoSocks/ContentView.swift:49` can trigger startup every time the view appears.
   - `TwoSocks/ContentView-VM.swift:25` launches an untracked `Task.detached`.
   - `TwoSocks/microsocks/sockssrv.c:828` runs forever with global process state declared at `TwoSocks/microsocks/sockssrv.c:67`.
   - Re-entering the view can create orphaned servers, leaked state, and bind failures with no clean stop or restart path.

3. The default runtime config is an open proxy.
   - `TwoSocks/ContentView-VM.swift:26` passes only `-p`.
   - `TwoSocks/microsocks/sockssrv.c:780` defaults to `0.0.0.0`.
   - `TwoSocks/microsocks/sockssrv.c:811` only enables auth when credentials are supplied.
   - That is a risky default for any real network.

4. The UDP relay path needs hardening.
   - `TwoSocks/microsocks/sockssrv.c:386` uses a fixed 1024-entry poll array.
   - `TwoSocks/microsocks/sockssrv.c:486` appends sockets without a bounds check.
   - The same loop tears down the whole UDP association on many recoverable packet or socket errors starting at `TwoSocks/microsocks/sockssrv.c:456`.
   - One bad datagram can kill an otherwise healthy session.

5. The Xcode target is too loosely scoped.
   - `TwoSocks.xcodeproj/project.pbxproj:14` and `TwoSocks.xcodeproj/project.pbxproj:76` synchronize the whole `TwoSocks` folder into the target.
   - The derived app bundle includes `.gitignore`, `README.md`, `COPYING`, `create-dist.sh`, and `install.sh`.
   - The build also emits a warning for `TwoSocks/microsocks/Makefile`.
   - Tightening file membership would remove bundle noise and keep the target intentional.

6. The vendored C is not independently build-clean on the iOS SDK.
   - A direct syntax check fails at `TwoSocks/microsocks/sockssrv.c:613` because `IN6_ARE_ADDR_EQUAL` is used without directly including the header that defines it.
   - Even if the project currently builds around that, it is a portability and maintenance trap.

## Notes

- `xcodebuild -project TwoSocks.xcodeproj -scheme TwoSocks -configuration Debug -derivedDataPath .derived CODE_SIGNING_ALLOWED=NO build` got far enough to confirm the Makefile warning and the extra bundled files, but did not finish in the sandbox because Swift preview macro execution failed.
- `clang -fsyntax-only` on the vendored C sources exposed the `IN6_ARE_ADDR_EQUAL` issue.
- No test target was present, so these paths do not appear to be covered by automated checks.
