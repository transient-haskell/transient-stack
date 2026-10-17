# Axiom in the GHC wasm backend

`Widget.hs` is a client-side form (`runBody`): a text box and a button. `run.sh` compiles it to wasm, runs it in node over
jsdom, writes "Ana" in the box, clicks the button and waits for `hello Ana`; it prints `PASS` or `FAIL`.

`Calc.hs` / `calc.sh`: computations in the `Widget` monad without rendering (bind, `liftIO`, applicative, alternative) through
`runBody`; they give the right result (`Just 20`) in wasm.

`Static.hs` / `static.sh`: widgets with rendering and without events (`rawHtml`, `<<<`, a bind in between): the HTML is drawn
in order, one `span` per bind (`<span id="n0"><p>one</p><span id="n1"><span id="n2"><div><p>two 2</p></div>...`).

`Click.hs` / `click.sh`: a button and a widget after it. The click draws the next widget (`<p>clicked</p>` in the span of
the bind) and the button stays once: the event and the continuation work. For that, `runCont'` discards the rendering of the
reevaluated widget (`delData noHtml`). Replacing `setEventContW` by `setEventCont (norender x) (norender . f)` in the bind
also runs the continuation, but the new HTML is appended at the end of the root span, not in the span of the bind
(`setEventContW` renders with `runWidgetId` in the element of the bind), and the button is drawn again.

Status (2026-10-15): `View.hs` and `Cell.hs` compile with wasm; the form of `Widget.hs` (a text box and a button joined with `<*`)
is drawn and its click handler runs, but the page is not updated, so `run.sh` prints `FAIL`.

* `raiseEvent` (`runCont'`) reevaluates only the widget that raises the event (the button), not the left side of the bind
  (the text box and the button), so the box is not read again from the page.
* `eventclosure-experiment.patch`: a try in which `>>=` of `Widget` stores `runView x` in the state for `runCont'`. The event
  thread then reevaluates more (it reaches the next `genNewId`) but the page is still not updated. Not applied.
* `render` (`render noEvent`) only stores the `Perch` in the state; `runWidget'` (used by `runBody`) is who builds it. With
  `local (render ...)` under `initNode` nothing is drawn.
