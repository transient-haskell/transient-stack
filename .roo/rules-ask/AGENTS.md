# Project Documentation Rules (Non-Obvious Only)

- **Package structure**: `transient/` contains core monad, `transient-universe/` adds distributed computing
- **Cross-compilation**: Supports GHCJS for browser alongside native Haskell compilation
- **Architecture**: Distributed computing via closure serialization and stack transport
- **Exception system**: Sophisticated event handling with LIFO handler execution and thread inheritance
- **Event types**: `onException` (errors), `onUndo` (cancellation), `onFinish` (cleanup) use same propagation
- **Control primitives**: `forward` for event propagation, `continue` for exception recovery
- **Web integration**: Browser nodes connect via WebSockets, compiled with GHCJS to `static/out`
- **State persistence**: Execution logs enable computation recovery across sessions
- **Concurrency model**: Based on continuations with implicit threading and event handling
- **Testing approach**: Tests run in same directory as source, not separate test folders
- **Development workflow**: Uses Docker containers with specific transient images
- **API design**: REST endpoints via `api` combinator, web forms via `minput`