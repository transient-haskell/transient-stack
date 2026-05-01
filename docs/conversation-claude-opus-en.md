# Verbatim Conversation Transcript

This document contains the exact word-for-word transcript of our conversation regarding Transient and Cardano.

---

**User:**  read the docs and tell me what it is

**Antigravity:** Based on the documents and the project's structure, this repository contains **Transient** and all its associated libraries (`transient`, `transient-universe`, `transient-universe-tls`, and `axiom`).

In summary, **Transient is an advanced framework (and an extensible effects monad) for Haskell designed to achieve "unrestricted composability."**

Here I highlight the main points of what it does and what it's for:

1. **Complex ("Impure") Effects Unification:**
   Transient allows handling typical real-world problems that usually break the elegance of pure functional programming. This includes: concurrency, multi-parallelism, exception handling (including backtracking and asynchronous continuation), asynchronous I/O (async I/O), events, distributed computing (moving processes between nodes), and web programming both on the client (browser) and server sides.

2. **Standard Mathematical Composability:**
   Normally in Haskell, handling things with different effects would require complex nesting of monad transformers. Transient allows combining these applications and complex logics using simple monadic and applicative operators:
   - `<$>`, `<*>` and `<>` for concurrency.
   - `<|>` (Alternative) for parallelism or *backtracking* upon exceptions.
   - `>>=` for chained asynchronous operations or serialized steps.

3. **Architecture and Scalability:**
   The ecosystem is divided into modules that take on different layers:
   - **`transient`**: The core that manages thread control, asynchronous continuations, events, and exceptions in memory/state.
   - **`transient-universe` and `tls`**: Extensions to transport this logic over the network transparently (creating computation *clusters* where a thread/calculation can travel from one server node to another or to a web browser using teleportation).
   - **`axiom`**: A framework that exposes these capabilities to the browser, allowing user interfaces (web forms, widgets) intertwined in the same concurrent logic.

The general goal is to enable you to program highly difficult things (like microservices streaming applications with failure recovery or web apps with distributed calculations) as if you were programming regular pure mathematical functions, all in a single line of elegant logic in the same `TransIO` monad.

---

**User:** veo que tiene async. para que sirve? esa orde se usa como siempre? (I see it has async. what is it for? is that command used as usual?)

**Antigravity:** In **Transient**, the `async` command does not work exactly "as usual" in other languages (like JavaScript or C#) nor like in Haskell's traditional `async` library.

Here is a summary based on the documentation and internal code comments:

### What is it for?
It serves to take an input/output computation (type `IO a`) and execute it asynchronously within the `TransIO` monad. It sends that computation to a background thread, freeing the current thread, and when it finishes, it resumes the code flow execution, bringing the result with it in a new Transient cooperative thread.

### Is it used like in other languages (await / async)?
**Definitely NO**. In the source code, there is an explicit warning about this:
> *"NOTE: `async` and `await` DOES NOT WORK like in other languages. Every LLM tries to use the pattern of async-await and transient does not work that way."*

In other languages or libraries, it is common to do this:
```haskell
-- This does NOT do what you think in Transient
do
   x <- async task1
   y <- async task2
   resultX <- await x 
   resultY <- await y
```
If you write that in Transient, **it will execute sequentially**. `task2` won't start until `task1` has finished because, in the monadic flow (`do` / `>>=`), `async` stops the sequence's progress until it obtains the value.

### How is it used correctly then?
In Transient, `async` is blocking in the monadic sequence, but **non-blocking in algebraic operations**.

To achieve true parallelism with `async`, you must combine them using Transient's special operators:

**To execute them in parallel (each in its own thread will continue on its own):**
```haskell
async task1 <|> async task2
```

**To collect the results of both parallel processes at a single point:**
```haskell
await $ async task1 <|> async task2
-- or also:
collect 0 $ async task1 <|> async task2
```

In summary: Instead of creating promises and plainly waiting for them, in Transient, asynchronous operations are composed directly using algebraic operators (`<|>`, `<$>`, `<*>`) to establish concurrent or parallel flows.

---

**User:** react?

**Antigravity:** In Transient, **`react`** is the "magic piece" that serves as a bridge between the messiness of the outside world APIs (based on callbacks or events) and Transient's elegant sequential flow.

### What is it for?
While most asynchronous code in event-driven systems results in "Callback Hell" (functions inside functions inside functions), `react` takes an API that expects a callback (like a button "onClick" or a WebSocket "onMessage") and transforms it into a normal monadic value (`TransIO a`).

This way, your code looks sequential and flat, but underneath *Transient* is managing that when the external event occurs, that line wakes up and emits the value.

### Its signature and usage
Conceptually, the signature is something like:
`react :: ((a -> IO ()) -> IO ()) -> TransIO () -> TransIO a`
*(The second parameter is usually a cleanup action or simply `return ()`).*

### Practical Example
Imagine you have a library with an `onButtonClick` function to which you pass a function (callback) to execute when the user clicks.

**In traditional code (Callback Hell):**
```haskell
onButtonClick $ \coordX -> do
    -- Do something with X
    onMouseClick $ \coordY -> do
         -- Do something with Y
```

**With Transient using `react`:**
```haskell
do
    coordX <- react onButtonClick (return ())
    -- The code magically advances only when the button click occurs
    
    coordY <- react onMouseClick (return ())
    -- Now we advance only when a mouse click occurs
    
    liftIO $ print (coordX, coordY)
```

### Why is it cool?
By using `react`, this click event is now a building block that can be combined using algebraic operators just as we saw with `async`.

For example, you could start two `react` calls at the same time and wait for either event to occur to continue, without asynchronous tangles:
```haskell
    result <- react onEventX (return()) <|> react onEventY (return())
```

In summary: **`react` tames messy external asynchronous APIs (callback-based)**, tying them to Transient's parallel processing engine.

---

**User:** minput?

**Antigravity:** In the Transient ecosystem, **`minput`** (an abbreviation that usually refers to *monadic input* or something similar) is a function related to the user interface, specifically within the web/distributed module (`Transient.Move.Web`).

### What is it for?
It serves to **declaratively request data (input) from the user** and pause the flow's execution (within the `Cloud` monad) until that data is returned.

### How does it work in practice?
Normally in traditional web development, asking for data involves creating an HTML form in a file, programming the backend endpoint that receives the POST, parsing the data, and validating it.

With `minput`, all of that is reduced to a single line of Haskell code:

```haskell
userID <- minput "userID" "Please enter your user ID:"
```

That line does all the "magic" work behind the scenes:
1. It renders (or assumes) a web/console interface that shows the text "Please enter your user ID..." to the user.
2. It creates the input field named `"userID"`.
3. It pauses the execution of that monadic "thread."
4. When the user submits the form (either via GET or POST), Transient retrieves the sent value, checks that it matches the expected Haskell type, and resumes execution by assigning that value to the `userID` variable.

### Its typical signature
In code examples, the signature usually looks similar to:
```haskell
minput :: (Loggable a, ToHTTPReq a) => String -> String -> Cloud a
```
This means it takes two `Strings` (the identifier/name and the label or prompt to show the user) and returns a value of type `a` within the `Cloud` monad (which is Transient's distributed monad).

In summary: **It is the way to create data entry points (inputs or forms) fully integrated with the asynchronous logic flow, automating the "request and response" of the classic web cycle.**

---

**User:** puede enviar y recibir JSION a/del browser? (can it send and receive JSON to/from the browser?)

**Antigravity:** Yes, **absolutely**. Transient can send and receive JSON to and from the browser (or any other client/server) without problems.

The Transient framework has direct and deep integration with **Aeson** (the standard and fastest Haskell library for JSON).

From the design of Transient's code, we can deduce:

1. **Typeclass Usage:** Everything is based on implementing the `ToJSON` and `FromJSON` classes for your Haskell data types. The library even has built-in support for its own internal types (Nodes, MVar, ByteStrings, Session IDs, etc.).
2. **REST APIs and WebSockets:** Both socket communications between nodes and RESTful calls or WebSockets from an SPA (Single Page Application) in the browser send and receive the payload in JSON format if so declared.
3. **Dedicated Web Module:** There is a `Transient.Move.JSON` module within `transient-universe` specifically designed for serializing and deserializing structures to/from network constructors/responses.

**How it works in practice:**
You don't have to manually parse text strings over and over. If you define a structure like:

```haskell
data Person = Person { name :: String, age :: Int } 
  deriving (Generic, ToJSON, FromJSON)
```

When using endpoints like `minput` sending POST, or performing network operations in the `Cloud` monad, if the client (JavaScript or the browser using `JSON.parse` / `JSON.stringify`) sends a matching JSON object, Transient will automatically and type-safely convert it, and your Haskell code will receive a pure and valid `Person` variable.

---

**User:** Tiene alguna otra funcion que no se ve en otras librerias? (Does it have any other function not seen in other libraries?)

**Antigravity:** Yes, Transient is full of unique primitives. Because it bases its architecture on serializable continuations and full state control of the monad, there is a set of functions that you almost **never see in standard libraries** of other languages.

Here I highlight the most peculiar and interesting ones:

### 1. `teleport` (and `wormhole`)
Probably the most extravagant of all. Transient allows distributed computing such that the *code itself* decides where to execute mid-way.
*   **What is it for?** If you have a function executing on your server but need to show an alert to the user and collect their web response, or need to process heavy parallel calculations in a cluster of nodes, you use these primitives.
*   **What does it do?** It serializes your execution state and variables, sends them over the network, "jumps" to that other computer or the client's web browser, continues executing there, and can then return to the server bringing the result back. It literally teleports the execution thread over the network.

### 2. `abduce`
*   **What is it for?** It is the core of asynchronous efficiency ("thread abduction").
*   **What does it do?** It immediately releases the physical Haskell thread (your processor) on which that line was executing, allowing the system to do something else in parallel. In the next line of code, the monad will automatically reappear on another free thread ("returned by the aliens"). Unlike `fork`, this allows Transient's concurrency to handle millions of idle operations without saturating the host's processor threads.

### 3. `sandbox`
*   **What is it for?** A state variable time machine.
*   **What does it do?** Suppose you enter a long calculation that modifies local databases, the global user session state, or configurations, and in the end, something fails or you decide to cancel the process (backtracking). `sandbox` will wrap that, so if the computation within finishes unsuccessfully (with an explicit `stop` or another reason), the system undos *all modifications to the monadic state*, returning the program to the snapshot just a millisecond before executing `sandbox`.

### 4. `logged` and `loggedc`
*   **What is it for?** Unshakable state saving to never lose execution (Fault Tolerance).
*   **What does it do?** If you wrap important I/O operations or large blocks of your program with `logged`, the state and return value of that line will be automatically written to disk. If there is a total power outage, upon restarting the compiled process, Transient *won't* execute everything from scratch; it will jump like lightning reading the logs and "resurrect" the program exactly at the line after the one that had the outage, with all precise memory states reconstituted automagically.

### 5. Inverted `try - catch`? (`onException`, `onUndo`, `continue`, `forward`)
In almost every language, there is a `try {...} catch (e) {...}`. Transient doesn't work that way. It uses a "monadic backtracking" system.
*   When you configure `onException`, these handlers are attached to the thread (even if you create new "child" threads, they inherit them for free).
*   If an exception occurs, instead of being caught "upwards," the process steps back step-by-step, executing all shutdown/cleanup options in succession from the innermost to the outermost handling.
*   You have pure exception-level commands like **`continue`** that can tell the monad in the middle of that disaster: "Stop the error propagation and resume the code as if everything had been fine," which provides a very high level of crash tolerance not comparable to anything standard.

---

**User:** he oido que tiene streaming y reactividad (I've heard it has streaming and reactivity)

**Antigravity:** Indeed, Transient has a radically different (and powerful) approach to **streaming** and **reactivity**. Unlike other libraries where you have to learn a completely different set of primitives or data types to handle "Flows" (like `Stream`, `Observable`, `Conduit`, `Pipes`, etc.), in Transient, **streaming is a default effect always available**.

### Reactivity (`Push` vs `Pull`)
Most languages use a *Pull* approach (you pull from the flow by iterating it to ask for the next datum in a `while` or `for` loop).
Transient uses pure **Push-based** reactivity. You don't ask for the next datum; you simply declare your asynchronous code and **react** to the data as the system "pushes" them toward your thread, using the exact same algebra of operators (`<|>`, `<*>`, etc.) you use for any other concurrent task.

### How does Streaming work then?
In Transient, a computation—regardless of whether it's local or remote over the network—is not limited to returning *a single* result. It can return **zero, one, or multiple results over time**.

If you combine this with distributed computing, streaming magically emerges:

```haskell
-- This executes in the browser (local)
onBrowser $ do
   result <- atRemote $ repeatAndSuspend "Hello from Server"
   -- This print (in the browser console) will be called 
   -- automatically every time the server spits out a datum over the network.
   liftIO $ print result 
```

**Key points of streaming in Transient:**
1. **Implicit over the network**: Zero WebSocket configuration. A simple `atRemote` block of code can generate results indefinitely; Transient keeps the connection open and transports each result as if it were a real-time WebSocket stream.
2. **Multi-threaded by default**: If the generator emits data very fast, the system manages processing them in parallel by assigning threads as they arrive.
3. **Control from the receiver (Feedback)**: Since it's a *Push* system, what happens if the server floods the client? Simple; the client remote process can use a mechanism where it sends a signal or exception "upstream" (`killChilds`) to turn off the server's stream tap, or silently pause its production.

Basically, "reactive streaming" in Transient means: Functions *can return multiple results over time*, and you simply write your code assuming "when a new datum arrives, execute me here," unifying serial asynchronous code and infinite lists into a single abstraction.

---

