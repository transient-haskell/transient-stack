# Axiom in the GHC wasm backend

Tests that compile Axiom to wasm and run it in node over jsdom (`all.sh` runs them sharing one build directory; first run ~4 min).
The widgets are used as `widgets.hs` does: in `TransIO`, with `render` before every line, run with `keep`.

| test | what it checks | status (2026-10-19) |
|---|---|---|
| `calc.sh` (`Calc.hs`) | computations in the `Widget` monad without rendering, with `runBody` | PASS (`Just 20`) |
| `static.sh` (`Static.hs`) | a `render` in every line, no events | PASS |
| `click.sh` (`Click.hs`) | `render (wbutton ..)` and a `render` after it; a click draws `clicked` in the gap of the button, the button stays once | PASS |
| `form.sh` (`Form.hs`) | the form of `widgets.hs`: `render` of a text box `<**` a submit button; writes "Ana", clicks: expects `hello Ana` | PASS |
| `run.sh` (`Widget.hs`) | `render (inputString .. `fire` OnChange)`; writes "Ana" and fires `change`: expects `hello Ana` | PASS |

`render` builds the DOM directly (as in the 2020 version): its HTML, followed by an empty element (`id2`) where the next render
hangs. It is split in `TransIO` steps, so its last step also runs in the continuation of an event: there it deletes the
rendering of the subsequent renders (`deleteSiblings`/`clearChildren` of `id2`) and leaves `IdLine` pointing to `id2`.

`raiseEvent` works as `react`: the handler of the page resumes the computation with the event (no `cont`/`runCont'`).

The widget that raises the event runs again in the continuation, in `ExecEvent` mode (its HTML is not built), reads the page and
returns its content.

`<**` (`Transient.LEngine`) executes its first term again when an event happens in the second one, and the computation continues
with the result of the first term (see its documentation and `transient/tests/aftertest.sh`). Axiom needs that definition for
forms (`fields <** button`, as in `form.sh`). The first term is executed again with the same sequence of identifiers it had the
first time (`mfSequence`): without that, the text box asked `genNewId` for a new identifier (`n4`) instead of `n2`, did not find
its element and the continuation stopped.

## In a real browser: `browser.sh`, `browser-all.sh`

The same tests (`static`, `click`, `widget`, `form`) in Chromium (playwright): a transient node serves the page and the wasm of the test
(`index.html` loads `file/loader.js`, which fetches `app.wasm`; see `transient-universe/tests/wasm/README.md`), Chromium opens
`http://localhost:<port>/` and `check.cjs` drives the page with real events (`fill`, `click`) and looks at the text. `browser.sh <port> <app>`
runs one; `browser-all.sh` runs the four. All pass (2026-10-21), including the form `text box <** button`.
