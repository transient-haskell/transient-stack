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
runs one; `browser-all.sh` runs them all. All pass (2026-10-21), including the form `text box <** button`.

`widgets` is `axiom/tests/widgets.hs` itself, compiled to wasm (`widgets-test` in `axiom-test.cabal`): Chromium writes the name and the
age, clicks `send` and the page shows `Person {name = "Ana", age = 30}`. For wasm the file got three changes: `jstr` uses `Perch.JS (pack)`
when `wasm32_HOST_ARCH` (there is no `Data.JSString`), `JavaScriptFFI`, and `hs_start`, the entry point of the reactor
(`foreign export javascript`, it wraps `main`, which returns `IO (Either String ())`). The node that serves it is `Hello`: the server
branch of `GHCJS.HPlay.View` (the one that is not for the browser) does not compile any more (`pack` is not in scope), so
`widgets.hs` cannot be compiled for the server yet.

`widgetsmore` (same program as `widgets`): the link, the radio buttons and the select of `widgets.hs` in the same page. An event in one
of them does not touch the others. Three things were needed in `GHCJS.HPlay.View` for several widgets with events to live together:
`addEvent` puts the widget in an `<event>` element of its own and the handler in it (without it `build` returns the container and
every handler is triggered by the clicks of all the widgets); `render` builds in a `span` of its own (the alternatives of `<|>` are
independent, and `deleteSiblings` after an event does not delete the other alternatives); and `raiseEvent` sets again the identifier
of the element that `getSelect` and `getCheckBoxes` look for.

Checkboxes (`cb1`, `cb2`, `cb3`): `getCheckBoxes` over two or one `setCheckBox ... `fire` OnClick` joined with `<>`, outside `widgets.hs`:
the initial state is shown without any event (`returns: ["Green"]`) and a click gives the latest value of each box (`["Red","Green"]`).
It is the applicative of `transient` as it is: each term gives its initial value and a new value in each event, and the applicative
combines the latest value of each term (nothing reads the other terms again). Two things in `GHCJS.HPlay.View` were needed:
`setCheckBox` returns its initial state when its element is not in the page yet (before it returned nothing), and `Functor Widget` is
the `fmap` of `TransIO`: the previous one applied the function only to the result of the first evaluation and not to the one of an
event, so the next step of `<*>` applied a value that was not a function (`internal error: stg_ap_p_ret`).

The alternatives of `Widget` (`instance Alternative Widget` in `GHCJS.HPlay.View`): `a <|> b = Widget $ alternative (norender a) <|> alternative (norender b)`.
`alternative x` starts `x` from the `IdLine` (the place of the page) where the `<|>` began and leaves it as it was when it ends. `<|>` of
`TransIO` runs the next alternative with the state that the previous one left, and a `render` that gives a value leaves `IdLine` pointing to
its hole (`id2`): the next alternative would be rendered inside it and an event in the first one would clear it.

Not covered: the checkboxes inside the whole page of `widgets.hs`. There `buttons = ... inputPerson <|> radio <|> checkButton <|> select`
are alternatives of `TransIO` (each one is a sequence of `render`), not of `Widget`, so `Alternative Widget` does not reach them: since `checkButton`
gives a value in its first execution, `select` and the link are rendered inside its hole and a click in a checkbox deletes them. With
`alternative` in each alternative (`alternative inputPerson <|> alternative radio <|> ...`) that page passes (tried in a copy of
`widgets.hs`), but `widgets.hs` was not changed.
