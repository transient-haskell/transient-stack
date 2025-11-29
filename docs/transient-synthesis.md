# Transient: A Synthesized Technical Overview

This document provides a dense, detailed summary of the `transient` library and ecosystem, incorporating the core concepts and the refined understanding achieved through deep analysis. It is intended as a high-quality context for advanced understanding and future sessions.

## 1. Core Philosophy: Declarative & Compositional

`transient` is a declarative framework. Instead of specifying *how* to perform tasks (imperative), you declare *what* you want to achieve. The framework manages the complex "how" of concurrency, distribution, state, and error handling. The core principle is the composition of computations (`TransIO` and `Cloud` monads) using algebraic operators.

## 2. The Monadic Context: `TransIO` and `Cloud`

`transient` is built around a "monolithic" monad (`TransIO` for local, `Cloud` for distributed) that encapsulates the entire execution context. This includes:
- The continuation (what's left to do).
- State data.
- Event handlers.
- Thread management and distributed node information.

This monolithic design is a deliberate trade-off. It sacrifices granular monad transformer composition to gain seamless, automatic propagation of the entire context across asynchronous, concurrent, and distributed boundaries.

## 3. Fundamental Control Flow & Backtracking

- **`empty` (or `stop`):** Represents a computation that fails logically. It's not necessarily an error, but a branch that produces no result. This triggers backtracking.
- **`<|>` (Alternative):** The primary control flow operator. `A <|> B` means "try A. If it fails (`empty`), discard its effects and try B." This unifies:
    - **Error Handling:** Catching failures.
    - **Choice:** Composing multiple data sources or user options.
    - **Logic:** Exploring different strategies for a problem.

## 4. Concurrency Model

`transient`'s concurrency is structured and context-aware.

- **`abduce`:** The fundamental primitive. It forks the computation.
    1.  **The Future:** The rest of the computation (the continuation) is packaged and executed in a **new thread**.
    2.  **The Present:** For the **current thread**, `abduce` acts as `empty`, triggering a backtrack (e.g., to the other side of a `<|>`).
    - **Crucially, both threads share the same future continuation that follows the enclosing compositional block (`<|>`).** This enables parallel execution paths that converge later.

- **`async`:** A utility built on `abduce` (`async mx = abduce >> liftIO mx`). It runs an `IO` action in a background thread and feeds its result back into the `transient` flow.
  
  **Important Clarification:** In sequential execution (`do` notation), `async` computations execute one after another - the second `async` only launches when the first has completed. True parallelism only occurs in alternative (`<|>`) or applicative (`<*>`) contexts:
  - `async A <|> async B`: Executes A and B in parallel (alternative choice)
  - `(,) <$> async A <*> async B`: Executes A and B concurrently with synchronization (applicative)

- **Parallel Composition & Synchronization:**
    - **Launching:** Chaining actions with `<|>` (e.g., `async A <|> async B`) launches them in parallel (alternative exploration).
    - **Joining:**
        - **Applicative (`<*>`):** The most idiomatic way. `(,) <$> async A <*> async B` runs A and B concurrently with synchronization and waits for both to complete before returning the pair. Overloaded operators like `+` and `<>` use this internally.
        
  **Key Distinction:**
  - Alternative (`<|>`) provides parallel exploration of different computation paths
  - Applicative (`<*>`) provides concurrent execution with synchronization and combination of results
        - **`await` / `collect`:** Explicitly wait for a computation and all its child threads to finish, gathering all results into a list.

- **Iteration:**
    - **`for`:** **Fundamentally different from traditional loops** - takes only a list `[a] -> TransIO a` and acts as a **stream producer** that emits each value sequentially. Used with monadic binding (`<-`) to process values in the Transient pipeline:
      ```haskell
      do
        value <- for [1, 2, 3]  -- Produces 1, then 2, then 3
        async (process value)    -- Processes each value
      ```
    - **`choose`:** Schedules the execution for each element **in parallel**, using multiple threads. `for` is an optimized `threads 0 . choose`.
    
  **Critical distinction:** `for` is not an iterative loop but a **value producer** that feeds the monadic pipeline, while `choose` provides true parallel iteration.

## 5. Event Handling & Resilience

- **Handler Chain:** Primitives like `onException`, `onUndo`, and `onFinish` register handlers that are attached to the continuation. When multiple handlers are registered, they form a chain.
- **LIFO Execution:** When an event is triggered, handlers execute in **Last-In, First-Out (LIFO)** order (the last one defined is the first to run).
- **`forward`:** The primitive to continue propagating an event up the handler chain.
- **`continue`:** A shortcut for `forward (dataOfType :: SomeException)`. It stops the exception propagation and resumes normal execution *after* the block protected by the handler.
- **`onFinish`:** Guarantees execution of cleanup code. It is triggered only when the **last active thread** of a computation branch finishes. It is atomic and safe from race conditions, making it ideal for resource management (e.g., closing files/connections) in concurrent settings.

## 6. State Management & Persistence

- **Checkpoints & Continuations:** `transient` can persist the state of a computation to disk, allowing workflows to survive restarts.
    - **Chained, Not Independent:** Checkpoints are **not** full independent snapshots. For efficiency, a checkpoint saves the immediate state and a "log" or path to its parent checkpoints.
    - **Lazy Restoration:** When a computation is restored (e.g., via a web request), `transient` loads the immediate checkpoint. If the computation requires data from a parent scope, it recursively walks the chain of checkpoints on disk (or in cache) to reconstruct the full environment. This is a lazy, on-demand process.
- **`getData` / `setData`:** Provide type-safe access to the monadic state. This acts as a form of implicit, context-aware dependency injection.
- **`EVar`s & `Mailboxes`:** Provide pub/sub communication channels with distinct semantics:
  - **`EVar`s:** Explicitly passed event variables that implement reactive publish-subscribe within the Transient monad. Readers use `readEVar` which internally employs `react` to wait for events without blocking, while writers use `writeEVar` to publish values. Ideal for direct communication between known components.
  - **`Mailboxes`:** Global, type-indexed registry built on top of `EVar`s that enables highly decoupled communication. Components can communicate without explicit references using `putMailbox` and `getMailbox`. Mailboxes are application-wide and automatically indexed by type (and optionally by key), supporting multiple consumers per message and enabling mediator/event bus patterns.
  
  **Key distinction:** EVars require explicit passing but offer direct control, while Mailboxes provide global decoupling at the cost of implicit communication.

## 10. Precision on Parallelism Terminology

**Correction on "competitive parallelism":**
The previous mention of "competitive threads" was inaccurate. In Transient's alternative composition (`<|>`), threads don't compete for resources in the traditional sense. Instead:

- **Alternative (`<|>`)**: Explores different computation paths in parallel, where each branch receives different input values or follows different strategies
- **No resource competition**: Threads execute different computations rather than competing for the same result
- **Cooperative exploration**: Parallel branches work together to explore the solution space

The true "competition" occurs in backtracking scenarios where branches may fail (`empty`) and alternatives are tried, but this is logical competition rather than resource competition.

## 7. Distributed & Web Programming (`transient-universe`)

- **`runAt`:** Executes a computation on a remote node. It is a composition of:
    - **`wormhole`:** Establishes the network connection (tunnel).
    - **`atRemote`:** Manages the remote execution.
    - **`teleport`:** The low-level primitive that serializes the continuation, sends it across the network, and returns the result.
- **`minput`:** Creates a web endpoint and a console command simultaneously. It's the primary tool for user interaction in web flows.
- **Server-Guided URLs:** The server guides the client. A `minput` response provides the client with the exact, stateful URL for the next step. The client is "dumb" and simply follows the server's lead.
- **`showURL`:** A debugging/integration primitive that displays the unique, stateful URL for any point in a computation, allowing it to be triggered externally.
- **`initNodes` / `inputNodes`:** Primitives to interactively configure a cluster of nodes.
- **`-p` flag:** Allows scripting a sequence of console commands for automated deployment.

## 8. Client-Side & Full-Stack Composition (`axiom`)

- **Haskell on the Frontend:** `axiom` uses GHCJS to compile Haskell code to JavaScript, allowing it to run in the browser.
- **`atRemote`:** The bridge between client and server. It allows code running on the client to execute a block of code on the server and receive the result, as if it were a local function call.
- **Composition by Functionality:** This model transcends the traditional layered architecture (UI, backend, DB). It enables the creation of self-contained, vertical **features** as single library functions. A function can define its own UI, server logic, and distributed computations.
    - **Separation of Concerns is Maintained:** The components orchestrated by the feature function (e.g., UI widgets, DB queries) can and should live in their own specialized libraries, developed by different teams. `transient` composes these well-defined parts into a coherent whole.
    - **Composable Resilience:** Security and recovery policies (`retry`, `onException`, etc.) can be applied granularly to any part of this full-stack workflow.

## 9. Key Differences from Other Concurrency Libraries

**Critical Semantic Differences that often confuse LLMs and developers coming from other frameworks:**

1. **`async` in sequential context (`do` notation) executes sequentially** - the second `async` only launches after the first completes
2. **True parallelism only occurs in algebraic contexts** (`<|>`, `<*>`, numeric operators)
3. **Numeric operators (`+`, `*`) execute in parallel** when applied directly to `async` terms:
   ```haskell
   async comp1 + async comp2  -- Parallel execution (uses `<*>`)
   ```
4. **Monadic binding (`>>=`) implies sequential waiting** even with `async`
5. **The framework controls parallelism through compositional structure**, not imperative commands

**Common Misconceptions to Avoid:**
- ❌ "`async` always means immediate parallel execution" (false in Transient)
- ❌ "Monadic sequencing with `async` executes concurrently" (false - it waits)
- ❌ "Numeric operations are always sequential" (false - they use applicative context)

This design ensures that parallelism is explicit and controlled by the algebraic structure of the computation, preventing unintended concurrency and making the execution model more predictable.
