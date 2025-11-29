# Project Coding Rules (Non-Obvious Only)

- **Distributed primitives**: Always use `wormhole` for node communication, not direct socket calls
- **State transport**: Use `teleport` to transport stack info between nodes, not manual serialization
- **Concurrency control**: `collect` with `threads` parameter must be used for parallelism, not raw forkIO
- **Exception handling**: `onException` handlers execute in LIFO order (last defined, first executed)
- **Exception recovery**: Use `continue` inside handlers to stop propagation and resume normal execution
- **Event control**: `forward` is the general primitive for event propagation control
- **Logging pattern**: Use `logged` and `loggedc` for checkpointing, not manual logging
- **State management**: Non-serializable mutable variables in stack persist across invocations
- **Web integration**: Browser nodes require GHCJS compilation to `static/out` directory
- **API patterns**: Use `minput` for web form inputs, not manual HTTP handling
- **Testing**: Tests must be in same directory as source files for proper module resolution
- **Handler inheritance**: Event handlers automatically propagate to child threads via state inheritance
- **Finalization**: Use `onFinish` for guaranteed resource cleanup, not `onException`