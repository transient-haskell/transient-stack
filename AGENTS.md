# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Build/Test Commands (Non-Obvious)

- **Debug compilation**: `cabal install -f debug test-transient1 --overwrite-policy=always`
- **Run monitor in debug mode**: `runghc -w -threaded -rtsopts -i../src -i../../transient/src ../app/server/Transient/Move/Services/MonitorService.hs -p start/localhost/3000`
- **Run test suite in debug mode**: `runghc -DDEBUG -w -threaded -rtsopts -i../src -i../../transient/src TestSuite.hs`
- **Run examples**: `runghc -DDEBUG -w -threaded -rtsopts -i../src -i../../transient/src flow.hs -p g 2>&1 | tee 8000.ansi`
- **Compile examples**: `ghc -DDEBUG -w -threaded -rtsopts -i../src -i../../transient/src flow.hs 2>&1 | tee 8000.ansi`

## Code Style & Architecture (Non-Obvious)

- **Distributed computing patterns**: Use `wormhole` for node communication, `teleport` for stack transport
- **State management**: Non-serializable mutable variables in stack are kept across successive invocations
- **Exception handling**: `onException` handlers execute in LIFO order (last defined, first executed)
- **Exception recovery**: Use `continue` to stop propagation and resume normal execution after handler
- **Event propagation**: `forward` is the general primitive for event control, `continue` is `forward` for exceptions
- **Concurrency patterns**: `collect` with `threads` parameter controls parallelism level
- **Logging system**: Uses custom logging with `logged` and `loggedc` for checkpointing and recovery
- **Handler inheritance**: Event handlers (`onException`, `onUndo`, `onFinish`) are inherited by child threads
- **Finalization**: `onFinish` handlers execute exactly once when entire computation branch finishes

## Project Structure (Non-Obvious)

- **Main packages**: `transient` (core), `transient-universe` (distributed), `transient-universe-tls` (secure comms), `axiom` (web UI)
- **Test organization**: Tests are in same directory as source files, not separate test folders
- **Cross-compilation**: Supports GHCJS for browser execution alongside native compilation
- **Dependency resolution**: Use `cabal install --lib --package-env . <library>` when libraries not found

## Testing Patterns (Non-Obvious)

- **Single test execution**: Use `runghc` with specific include paths rather than cabal test
- **Distributed testing**: Tests require multiple nodes running on different ports
- **Debug output**: Use `-DDEBUG` flag and pipe to ANSI color files for log analysis
- **Performance profiling**: Built-in profiling with `-prof -fprof-auto -rtsopts`

## Critical Gotchas

- **File encoding**: Use `sed -i 's/\r//g' file` if encountering "No such file or directory" errors
- **Docker development**: Many scripts assume Docker environment with specific image
- **WebSocket connections**: Browser nodes use WebSockets, server nodes use sockets
- **State recovery**: Execution logs are serialized and can restore computation state
- **Handler ordering**: `onException` handlers execute in reverse order of definition (LIFO stack)
- **Thread safety**: Event handlers propagate to child threads automatically via state inheritance
- **Resource cleanup**: Use `onFinish` for guaranteed cleanup, not `onException` for resource management
- **Exception control**: `continue` resumes execution AFTER the handler scope, not at the failure point