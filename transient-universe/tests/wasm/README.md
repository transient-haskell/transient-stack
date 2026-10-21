# Browser side compiled with the GHC wasm backend

`Hello.hs` is one program for both sides: the browser (`onBrowser`) asks the server (`atRemote`) and prints the answer.
`run.sh` builds it for the server and for wasm, runs the wasm in node (stub of `window.location`; the `WebSocket` is the
one of node) against the server, and prints `PASS` or `FAIL`. It does not test a real browser.

Requirements: the nix shell of `CLAUDE.md`, and the wasm toolchain (`FLAVOUR=9.10 ./setup.sh` of
https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta, installed in `~/.ghc-wasm`). Notes: the entry point is
`foreign export javascript` (asynchronous: with `ccall` the scheduler blocks the JS thread), and node runs with stdin closed
because `keep` reads it.

## In a real browser: `browser.sh`

The node (the server) serves the page and the program: `static/index.html` loads `file/loader.js`, which fetches `app.wasm` and starts
it with the WASI shim for browsers (`@bjorn3/browser_wasi_shim`). The node serves the files of `./static` only under `/file/`
(`servePage` in `Transient.Move.Internals`); the page is `/`. Chromium (playwright) opens `http://localhost:<port>/`; the wasm program
connects back to the node through the websocket, asks for the string and gets it (`check-hello.cjs` looks at the frames of the websocket).

Chromium for playwright is not installed by the toolchain: `playwright install chromium` (it goes to `/root/pw-browsers`) and the system
libraries `libnss3 libnspr4 libgbm1 libasound2`.
