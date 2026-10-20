# Axiom in the GHC wasm backend

Tests that compile Axiom to wasm and run it in node over jsdom (`all.sh` runs them sharing one build directory; first run ~4 min).
The widgets are used as `widgets.hs` does: in `TransIO`, with `render` before every line, run with `keep`.

| test | what it checks | status (2026-10-19) |
|---|---|---|
| `calc.sh` (`Calc.hs`) | computations in the `Widget` monad without rendering, with `runBody` | PASS (`Just 20`) |
| `static.sh` (`Static.hs`) | a `render` in every line, no events | PASS |
| `click.sh` (`Click.hs`) | `render (wbutton ..)` and a `render` after it; a click draws `clicked` in the gap of the button, the button stays once | PASS |
| `form.sh` (`Form.hs`) | the form of `widgets.hs`: `render` of a text box `<**` a submit button; writes "Ana", clicks: expects `hello Ana` | FAIL: after the click nothing is drawn |
| `run.sh` (`Widget.hs`) | `render (inputString .. `fire` OnChange)`; writes "Ana" and fires `change`: expects `hello Ana` | PASS |

`render` builds the DOM directly (as in the 2020 version): its HTML, followed by an empty element (`id2`) where the next render
hangs. It is split in `TransIO` steps, so its last step also runs in the continuation of an event: there it deletes the
rendering of the subsequent renders (`deleteSiblings`/`clearChildren` of `id2`) and leaves `IdLine` pointing to `id2`.

`raiseEvent` works as `react`: the handler of the page resumes the computation with the event (no `cont`/`runCont'`).

The widget that raises the event runs again in the continuation, in `ExecEvent` mode (its HTML is not built), reads the page and
returns its content.

`<**` (`Transient.LEngine`) executes its first term again when an event happens in the second one, and the computation continues
with the result of the first term (see its documentation and `transient/tests/aftertest.sh`, which passes). Axiom needs that
definition for forms (`fields <** button`). In `form.sh` it is not enough yet: with `alert`s in the test, "ma runs" (the box)
appears only in the first execution, so after the click the continuation does not get to execute the box again.
