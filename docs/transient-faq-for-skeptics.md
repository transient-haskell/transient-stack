# Transient: An FAQ for the Skeptical Mainstream Programmer

This document addresses common questions and criticisms from developers accustomed to other popular programming paradigms. It aims to explain the "why" behind some of `transient`'s more unconventional design choices.

---

## 1. The Java Enterprise Developer: "Where is my Dependency Injection?"

**The Question:**

> "Look, all this monad and continuation stuff is fine for an academic paper, but let's be serious. I have to deliver a microservice for the next sprint. Where is my dependency injection? How am I supposed to mock services for my unit tests if everything is a magic black box? Do I have to spin up this whole `Cloud` thing just to test a simple business logic function? This seems to violate the Dependency Inversion Principle from SOLID top to bottom. Or do the software design principles of the last 20 years not apply in this functional world?"

**A Tentative Answer:**

Your question about SOLID and testing is spot on. In `transient`, these principles aren't violated; they are achieved through a different, more implicit mechanism: **the monadic context**.

**Dependency Injection via `getData`:**

Instead of injecting dependencies through a constructor or a framework annotation, `transient` "injects" them from the environment of the computation itself. The primitive `getData :: TransIO (Maybe MyService)` is your dependency injection container. It looks into the current context and retrieves the service (or data) of the requested type.

This is, in effect, type-safe, context-aware dependency injection. The dependency is on the *type*, not on a concrete implementation, which respects the Dependency Inversion Principle.

**Mocking and Unit Testing:**

You don't need to lift the entire `Cloud` to test your logic. A `transient` computation is just a value. To test it, you can run it in a controlled environment where you have previously injected mock services or data into the context using `setData`.

```haskell
-- Your business logic
myBusinessLogic :: TransIO String
myBusinessLogic = do
  db <- getData :: TransIO DatabaseService
  db.query "SELECT..."

-- Your test
testMyLogic :: Test
testMyLogic =
  -- 1. Create a mock service
  let mockDB = MockDatabaseService "mock-result"
  -- 2. Run the computation with the mock service in its context
  let result = runTransient $ setData mockDB >> myBusinessLogic
  -- 3. Assert the result
  assertEqual "mock-result" result
```

The "magic" is simply that the context is managed by the monad, not by an external container. This often leads to less boilerplate and a more direct connection between a component and its dependencies.

---

## 2. The Rust Developer: "Where is the Ownership? How is this Safe?"

**The Question:**

> "I've been looking at the code, and the memory and concurrency model is not clear at all. The Rust compiler guarantees at compile time that I don't have data races. It's 'fearless concurrency'. You talk about threads being created everywhere with `abduce` and `async`, and a state that is magically passed around. Who is the *owner* of the data? How do you guarantee that there are no concurrent mutable accesses to shared data? Do you use `Mutex`, `RwLock`? Or do you just cross your fingers and hope that Haskell's Garbage Collector works a miracle? It seems to me that you are trading compile-time safety for a runtime complexity that is impossible to reason about."

**A Tentative Answer:**

Your concern for memory safety and data races is entirely valid. `transient` achieves "fearless concurrency" not with a borrow checker like Rust, but through a combination of two core Haskell principles: **immutability and Software Transactional Memory (STM)**.

**Ownership and Immutability:**

In `transient`, you rarely mutate data. When you "change" a state, you are creating a *new version* of that state. This immutability-by-default eliminates a whole class of data races. There is no single "owner" in the Rust sense, because data is not passed around by mutable reference; it's passed by value. Threads receive their own copy of the data they need and cannot affect the data of other threads unless they explicitly communicate.

**Safe Concurrent State Modification with STM:**

For the cases where you *do* need to share and modify a common state (like a shared resource on disk), `transient` relies on `TCache`, which is built on STM. This is the answer to your `Mutex/RwLock` question.

Instead of locks, operations on shared data are performed inside an **atomic transaction**.

```haskell
-- Pseudocode
atomically $ do
  value <- readTVar sharedResource
  let newValue = value + 1
  writeTVar sharedResource newValue
```

The STM runtime guarantees that this entire block executes atomically. If two threads try to do this at the same time, the runtime detects the conflict, aborts one of the transactions, and transparently retries it. This provides the same safety against data races that locks do, but often without the associated problems like deadlocks. It's a high-level, composable approach to concurrency control.

So, `transient` is not "crossing its fingers". It's leveraging Haskell's powerful concurrency primitives to provide safety guarantees that are different from Rust's, but equally strong in practice.

---

## 3. The JavaScript/TypeScript Developer: "This is Hurting my DevEx!"

**The Question:**

> "Ok, `async/await` is the de facto standard. It's simple, it works, and I have an ecosystem of thousands of libraries on `npm` that use it. My editor gives me top-notch autocompletion and debugging. Are you really telling me that to make a simple async call I have to understand what an `Alternative` is and use a `(<|>)` operator instead of a `try/catch`? And what about debugging? If I have a chain of 10 `minput`s and something fails on the seventh, how do I set a breakpoint? Is my stack trace going to be an unintelligible list of continuations? It seems like you're reinventing the wheel just to be different, with a huge cost in tooling and developer experience."

**A Tentative Answer:**

You're right, the developer experience is different, and there's a learning curve. `transient` trades the familiarity of `async/await` for a more powerful and expressive composition model.

**`<|>` is More than `try/catch`:**

A `try/catch` block is designed to handle exceptional, unexpected errors. The `Alternative` operator `(<|>)` does that, but it also handles *logical failure* as a standard control flow mechanism. It's not for errors, it's for choice. `computationA <|> computationB` means "try A, if it doesn't produce a result, try B". This allows you to compose data sources, user choices, and fallback strategies in a single, declarative line, which would be much more verbose with `if/else` and `try/catch` blocks.

**Debugging and Introspection:**

Debugging is different, but not impossible. You are correct that a traditional stack trace is less useful. The "stack trace" of a `transient` computation is the computation graph itself. Debugging is done by introspecting this graph.

`transient` provides the `logged` primitive for this. You can wrap any computation in `logged` to get a detailed trace of all the events, state changes, and thread communications that happen within it. It's a form of structured, contextual logging that is often more powerful than a simple stack trace for understanding complex asynchronous flows.

Furthermore, because every computation is a value, you can inspect it, and primitives like `showURL` allow you to get a handle to a specific point in a long-running workflow and "jump" directly to it for testing, which is a form of debugging that is very difficult to achieve in traditional systems. It's a different mindset, focused on inspecting the flow of data rather than the call stack.

---

## 4. The Haskell Purist: "Isn't this a Monolithic God-Monad?"

**The Question:**

> "Interesting. You've built a `TransIO` monad that seems to be a kind of `ContT` mixed with `StateT`, `ExceptT`, and `ListT` for non-determinism, all on top of `IO`. It's a rather 'impure' and monolithic monad stack. Doesn't this break the principle of monad composition? If I want to add my own effect to the stack, say a `LoggingT`, how do I integrate it without having to modify the `transient` core? It seems you've created a god-monad that does everything, but at the cost of losing the modularity and the ability to build your own custom effect stack, which is one of the great advantages of Haskell. Wouldn't it be more 'Haskell-like' to have a set of monad transformers (`TransientT`, `CloudT`, etc.) that I could stack as I please?"

**A Tentative Answer:**

You've correctly identified the core design trade-off. `TransIO` (and `Cloud`) are indeed "monolithic" monads, and this is a very deliberate choice. `transient` sacrifices the granular composability of a custom monad transformer stack to gain something it considers more valuable for its specific domain: **the seamless, automatic propagation of context across asynchronous and distributed boundaries.**

The "magic" of `transient`—where exception handlers, state, and thread-local data are automatically inherited by child threads, remote computations (`runAt`), and even client-side code (`axiom`)—is only possible because `transient` has full control over the structure of its core monad.

If `transient` were a `MonadTransformer`, a user could insert a transformer into the stack that `transient` doesn't know about. How would `transient` propagate the context across that unknown layer when it creates a new thread? It couldn't, at least not without complex and fragile machinery.

`transient`'s thesis is that for building distributed, fault-tolerant, long-running applications, the ability to compose *application logic* (e.g., `(taskA <|> taskB) <> taskC`) freely across network and thread boundaries is more critical than the ability to compose the *monadic stack* itself.

**Adding Custom Effects:**

While you can't add a new transformer, you can add custom effects in a structured way:

1.  **State:** You can add any custom data to the `TranShip` state using `setData` and `getData`, effectively adding a `StateT`-like effect for your custom type.

2.  **Type-Level Effects:** As you've seen with `transient-typelevel`, you can add custom effects at the type level to enforce invariants at compile-time, which is arguably even more powerful than adding a transformer.

3.  **Direct Continuation Manipulation:** For the ultimate level of control, `transient` exposes primitives like `runCont` and `withCont`. These are escape hatches that give you direct access to the underlying continuation (`k`). By manipulating the continuation directly, an advanced user can effectively introduce *any* custom effect or control flow they can imagine, wrapping or transforming the rest of the computation. This is the raw power that other monad transformers are built upon, offered to you directly when you need it.

In essence, `transient` is an opinionated framework. It provides a powerful, integrated "application monad" out of the box, trading one form of modularity (the stack) for another (the application components).
