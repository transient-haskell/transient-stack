# Project Debug Rules (Non-Obvious Only)

- **Debug compilation**: Must use `-f debug` flag with cabal for debug outputs
- **Log analysis**: Pipe output to ANSI color files (e.g., `8000.ansi`) and use ANSI color extension
- **Distributed debugging**: Monitor service runs on port 3000 by default
- **Thread analysis**: Use `traceAllThreads` and `showThreads` for concurrency debugging
- **State inspection**: `getLog` shows execution logs, `showLog` displays formatted logs
- **Exception tracing**: `onException` handlers execute in LIFO order (reverse of definition)
- **Exception debugging**: Use `continue` to test recovery paths, `forward` to test propagation
- **Handler inheritance**: Verify event handlers propagate correctly to child threads
- **Performance profiling**: Built-in with `-prof -fprof-auto -rtsopts -with-rtsopts=-p`
- **Cross-node debugging**: Nodes communicate via WebSockets (browser) and sockets (servers)
- **Recovery testing**: Use `restore1` to test state recovery from logs
- **Finalization debugging**: `onFinish` handlers execute exactly once per computation branch