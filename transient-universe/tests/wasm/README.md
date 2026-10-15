# Browser side compiled with the GHC wasm backend

`Hello.hs` is one program for both sides: the browser (`onBrowser`) asks the server (`atRemote`) and prints the answer.
`run.sh` builds it for the server and for wasm, runs the wasm in node (stub of `window.location`; the `WebSocket` is the
one of node) against the server, and prints `PASS` or `FAIL`. It does not test a real browser.

Requirements: the nix shell of `CLAUDE.md`, and the wasm toolchain (`FLAVOUR=9.10 ./setup.sh` of
https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta, installed in `~/.ghc-wasm`). Notes: the entry point is
`foreign export javascript` (asynchronous: with `ccall` the scheduler blocks the JS thread), and node runs with stdin closed
because `keep` reads it.
