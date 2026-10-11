# Crux development safety

- Work on `develop/v1` unless the user requests another branch.
- All self-generated docset GUI tests before public release must use **Crux Beta**, bundle identifier `com.zacharyhuo.Crux.Beta`, never production `com.zacharyhuo.Crux`.
- Use the shared `Crux Beta` scheme or `scripts/build_and_run.sh`. Do not run the production app, quit it, install over `/Applications/Crux.app`, import test docsets into its library, or migrate its preferences for a beta test.
- Production Crux and Beta share source code. Keep differences limited to build branding and isolation. Do not create a forked source tree.
- Keep Beta app data in its separate sandbox/Application Support namespace. Never initialize it by copying production data or security-scoped bookmarks.
- Core tests may use newly allocated disposable directories. App-hosted tests must remain behind the existing isolated XCTest/UI-test runtime.
- Revert only changes proven to belong to the current task. Never reset or delete unrelated user changes/data.
