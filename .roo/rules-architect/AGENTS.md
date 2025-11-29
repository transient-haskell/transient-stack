# Project Architecture Rules (Non-Obvious Only)

- **Distributed computing**: Based on closure serialization and stack transport between nodes
- **State persistence**: Execution logs enable computation recovery and continuation
- **Concurrency model**: Continuation-based with implicit threading and event handling
- **Event system**: Unified event handling with LIFO execution and automatic thread inheritance
- **Exception architecture**: `forward`/`continue` primitives provide fine-grained control over event propagation
- **Resource management**: `onFinish` guarantees cleanup execution exactly once per computation branch
- **Cross-platform**: Supports GHCJS for browser nodes alongside native Haskell servers
- **Communication**: Browser nodes use WebSockets, server nodes use raw sockets
- **Monad design**: TransIO monad handles threading, events, and distributed execution
- **Package dependencies**: `transient` (core) → `transient-universe` (distributed) → `axiom` (web UI)
- **Testing strategy**: Tests require multiple running nodes on different ports
- **Development workflow**: Docker-based with specific transient development images
- **Performance**: Built-in profiling and RTS options for concurrency analysis