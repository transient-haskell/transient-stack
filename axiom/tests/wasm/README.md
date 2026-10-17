# Axiom in the GHC wasm backend

Tests that compile Axiom to wasm and run it in node over jsdom (`all.sh` runs them sharing one build directory; first run ~4 min).

| test | what it checks | status (2026-10-17) |
|---|---|---|
| `calc.sh` (`Calc.hs`) | computations in the `Widget` monad without rendering, with `runBody` | PASS (`Just 20`) |
| `static.sh` (`Static.hs`) | `TransIO` with a `render` in every line, no events: `one`, `two 2`, `three` are drawn | FAIL: nothing is drawn |
| `click.sh` (`Click.hs`) | `render (wbutton ..)` and a `render` after it; a click draws `clicked`, the button stays once | FAIL: nothing is drawn |
| `run.sh` (`Widget.hs`) | `render` of a text box `<**` a button; a click gives `hello Ana` | FAIL: nothing is drawn |

The widgets must be used as `widgets.hs` does: in `TransIO`, with `render` before every line.

Why nothing is drawn: `render` (`render noEvent`) only stores a `Perch` in the state with `setData`; nothing builds it
(`runWidget'`, used by `runBody`, does, but these tests do not use `runBody`). The original `render` built the DOM itself.

Earlier results with plain `Widget` and `runBody` (not the way Axiom is used, but they separate the problems): the bind of
`Widget` draws in order; a click on a button draws the next widget once if `runCont'` discards the rendering of the reevaluated
widget (`delData noHtml`) and the bind keeps `setEventContW`, which places the result in the span of the bind
(`setEventCont` alone appends it at the end of the root span). The form `(campo) <* (botón)` with `runBody` did not update.
`eventclosure-experiment.patch`: a try in which `>>=` stores `runView x` in the state; not applied.
