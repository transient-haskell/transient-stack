# Axiom in the GHC wasm backend

Tests that compile Axiom to wasm and run it in node over jsdom (`all.sh` runs them sharing one build directory; first run ~4 min).

| test | what it checks | status (2026-10-19) |
|---|---|---|
| `calc.sh` (`Calc.hs`) | computations in the `Widget` monad without rendering | PASS (`Just 20`) |
| `static.sh` (`Static.hs`) | `TransIO` with a `render` in every line, no events, inside `runBody (Widget page)` | PASS (`one`, `two 2`, `three` in order) |
| `click.sh` (`Click.hs`) | `render (wbutton ..)` and a `render` after it; a click draws `clicked` | FAIL: the click draws nothing |
| `run.sh` (`Widget.hs`) | `render` of a text box `<**` a button; a click gives `hello Ana` | FAIL: the form is drawn, the click draws nothing |

The widgets are used as `widgets.hs` does: in `TransIO`, with `render` before every line. The `Perch` that `render` leaves in
the state is built by `runWidget'` (its `<***` hook), so the program runs inside `runBody (Widget page)`.

Earlier results with plain `Widget` and `runBody` (not the way Axiom is used, but they separate the problems): the bind of
`Widget` draws in order; a click on a button draws the next widget once if `runCont'` discards the rendering of the reevaluated
widget (`delData noHtml`) and the bind keeps `setEventContW`, which places the result in the span of the bind
(`setEventCont` alone appends it at the end of the root span). The form `(campo) <* (botón)` with `runBody` did not update.
`eventclosure-experiment.patch`: a try in which `>>=` stores `runView x` in the state; not applied.

`render-split-experiment.patch` (2026-10-19): two changes in `render`, not applied. (1) the rest of `render` (the part after
`norender mx <*** hook`) is a `TransIO` step instead of the tail of one `Transient` block, so it runs again in the event
continuation: with `alert`s, after a click the order is `runCont'` -> tail of the render of the button -> next line -> next
`render` in `ExecEvent` mode. (2) the `ExecEvent` branch builds `torender` in the element `id1` (like `runWidgetId`), which
draws `<p>clicked</p>`, but in `n0` (it clears the button): the `IdLine` of the next render is still `n0`, not the span left
after the button, although the tail of the first render runs before it.
