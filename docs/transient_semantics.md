# The Semantics of Transient: A Technical Document

**A formal and semi-formal description of the execution model of the Transient framework for Haskell**

---

## 1. Introduction

Transient is a Haskell framework that unifies concurrency, non-deterministic computation, event handling, backtracking, and distributed computing under a single algebraic model. Unlike conventional frameworks that add these features as separate layers, Transient derives them from a small set of core primitives operating on continuations.

This document formalizes the semantics of Transient's execution model, providing both denotational (what the primitives mean) and operational (how they execute) descriptions.

> [!IMPORTANT]
> This document describes the semantics as implemented in the source code at
> [Core.hs](file:///c:/Users/gomezcalbe/cardano-cloud/transient-stack/transient/src/Transient/Core.hs) and
> [Engine.hs](file:///c:/Users/gomezcalbe/cardano-cloud/transient-stack/transient/src/Transient/Engine.hs).
> It is derived from code analysis, not from a prior formal specification.

---

## 2. Core Semantic Domain

### 2.1 The TransIO Type

```haskell
newtype TransIO a = Transient { runTrans :: StateIO (Maybe a) }
type StateIO = StateT TranShip IO
```

A `TransIO a` computation is a stateful IO action that may produce a value (`Just a`) or fail silently (`Nothing`). The `Nothing` case is not an error — it is the mechanism by which non-determinism, concurrency, and backtracking are implemented.

**Denotational interpretation:**

$$\llbracket \texttt{TransIO}\ a \rrbracket : \Sigma \rightarrow \text{IO}(\mathcal{P}(a) \times \Sigma)$$

Where $\Sigma$ is the state space (`TranShip`) and $\mathcal{P}(a)$ is a *stream* of results (zero, one, or many values of type `a`), potentially produced across multiple threads and over time.

> [!NOTE]
> The key departure from standard monads: `TransIO a` does not produce a single `a`.
> It produces a **potentially infinite stream** of `a` values, each potentially in a different thread.
> The continuation after a `TransIO a` statement is executed **once per result**.

### 2.2 The State: TranShip

```haskell
data TranShip = TranShip
  { fcomp      :: a -> TransIO b    -- current continuation
  , mfData     :: PolyMap           -- polymorphic state map
  , parent     :: IORef (Maybe TranShip)  -- parent thread state
  , children   :: MVar [TranShip]   -- child thread states
  , maxThread  :: Maybe (MVar Int)  -- thread semaphore
  , freeTh     :: Bool              -- tracking enabled?
  , labelth    :: IORef (LifeCycle, ByteString)  -- lifecycle
  , execMode   :: ExecMode          -- Serial | Parallel | Remote
  , ...
  }
```

The state `TranShip` is not just data — it contains the **continuation** (`fcomp`), which is "everything that remains to be executed." This is what enables Transient's unique capabilities: the continuation can be forked to another thread, serialized to another machine, or replayed for backtracking.

---

## 3. The Monad Instance: Sequential Composition

```haskell
instance Monad TransIO where
  x >>= f = Transient $ do
    k <- setEventCont f       -- save f composed with current continuation
    mk <- runTrans x          -- run x
    resetEventCont k           -- restore previous continuation
    case mk of
      Just r  -> runTrans (f r)  -- if x produced a value, apply f
      Nothing -> return Nothing  -- if x produced nothing, propagate nothing
```

**Semantic rule (bind):**

$$\llbracket m \bind f \rrbracket(\sigma) = \begin{cases} \llbracket f(r) \rrbracket(\sigma') & \text{if } \llbracket m \rrbracket(\sigma) = (\text{Just } r, \sigma') \\ (\text{Nothing}, \sigma') & \text{if } \llbracket m \rrbracket(\sigma) = (\text{Nothing}, \sigma') \end{cases}$$

The critical detail is `setEventCont`: before running `x`, the continuation `f >==> k` (where `k` is the existing continuation) is stored in the state. This means that at any point during the execution of `x`, the "rest of the program" is accessible as a first-class value in `fcomp`.

---

## 4. The Alternative Instance: Non-Determinism

```haskell
instance Alternative TransIO where
  empty = Transient $ return Nothing

  x <|> y = Transient $ do
    mx <- runTrans x
    was <- gets execMode
    if was == Remote then return Nothing
    else case mx of
      Nothing -> runTrans y
      _       -> return mx
```

**Semantic rule (alternative):**

$$\llbracket x \mathbin{<|>} y \rrbracket(\sigma) = \begin{cases} \llbracket x \rrbracket(\sigma) & \text{if } \llbracket x \rrbracket \text{ produces a result} \\ \llbracket y \rrbracket(\sigma) & \text{if } \llbracket x \rrbracket \text{ produces Nothing} \end{cases}$$

In pure sequential mode, this is standard `Alternative`: try `x`, if it fails try `y`. The radical insight of Transient is that **concurrency transforms the semantics of `<|>`**.

### 4.1 Alternative Under Concurrency

When `x` contains an `abduce` (see Section 5), `x` returns `Nothing` to the current thread immediately while its continuation runs in a new thread. This means `<|>` will execute `y` — not because `x` failed, but because `x` moved to another thread.

**The combined semantic:**

$$\llbracket (\texttt{abduce} \gg a) \mathbin{<|>} b \rrbracket = \{a_{\text{thread}_1}\} \cup \{b_{\text{thread}_0}\}$$

Both `a` and `b` execute, producing results independently. The `<|>` operator becomes **parallel composition** rather than sequential choice.

> [!TIP]
> This is the fundamental duality of Transient:
> **`>>=` is always sequential. `<|>` is sequential when pure, parallel when concurrent.**
> The programmer controls which regime applies by the presence or absence of `abduce`.

---

## 5. Concurrency: The `abduce` Primitive

### 5.1 Definition

```haskell
abduce :: TransIO ()
abduce = Transient $ do
  c <- get
  put c{execMode = if execMode c /= Remote then Parallel else Remote}
  (fork, sem) <- dofork c
  case (fork, freeTh c) of
    (True, False)  -> hangFrom c >>= \c' -> forkIO (runContCleanup c' ())
    (False, _)     -> runContLoop c ()
    (True, True)   -> forkIO (runContIO () c{parent = ...})
  return Nothing
```

### 5.2 Operational Semantics

$$\frac{\sigma.\texttt{maxThread} \text{ allows forking}}{\llbracket \texttt{abduce} \rrbracket(\sigma) = (\text{Nothing}, \sigma) \quad \parallel \quad \text{fork}(\sigma.\texttt{fcomp}, \sigma')}$$

In words:
1. **Check the thread semaphore** (`dofork`). If threads are available, proceed with forking.
2. **Create a child state** (`hangFrom`): a new `TranShip` that inherits the parent's state, including `fcomp` (the continuation), `mfData` (state variables), and the backtrack stack.
3. **Fork the continuation**: `forkIO` executes `runContCleanup c' ()` — this runs `fcomp` (everything after `abduce`) in a new thread.
4. **Return Nothing**: the current thread sees `abduce` as producing no result, which is equivalent to `empty`.

### 5.3 The Fallback: No Threads Available

When `maxThread` is exhausted (`fork = False`):

$$\frac{\sigma.\texttt{maxThread} = 0}{\llbracket \texttt{abduce} \rrbracket(\sigma) = \text{runContLoop}(\sigma.\texttt{fcomp}, \sigma)}$$

The continuation is executed **in the same thread**, synchronously. This means:
- `threads 0 $ abduce >> action` executes `action` sequentially
- The same code transparently adapts between concurrent and sequential execution

### 5.4 Thread Hierarchy

```
hangFrom st = do
    rchs   <- newMVar []
    th     <- myThreadId
    label  <- newIORef (LF Alive [], mempty)
    rparent <- newIORef (Just st)
    let st' = st { parent = rparent, children = rchs,
                   labelth = label, rThreadId = ... }
    hangState st st'   -- register st' as child of st
    return st'
```

Every forked thread is registered in a **tree structure**:
- `parent`: pointer to the parent state
- `children`: list of child states
- This tree enables `killBranch`, `killChildren`, `collect`, and `onFinish`

**State inheritance rule:**

$$\sigma_{\text{child}} = \sigma_{\text{parent}}[\texttt{parent} \mapsto \sigma_{\text{parent}}, \texttt{children} \mapsto \emptyset, \texttt{threadId} \mapsto \text{new}]$$

The child inherits:
- ✅ `fcomp` — the continuation (all `onBack`, `onException`, `onFinish` handlers)
- ✅ `mfData` — all state variables
- ✅ `maxThread` — the thread semaphore (shared via `MVar`)
- ✅ `execMode` — set to `Parallel`
- ❌ `children` — starts empty
- ❌ `parent` — points to the creator

> [!WARNING]
> `mfData` is copied by value (it's a `Map`), but values inside it may contain `IORef`s
> which are shared between threads. This creates potential race conditions that are outside
> the semantic model.

---

## 6. The Applicative Instance: Parallel Composition

```haskell
instance Applicative TransIO where
  mf <*> mx = do
    r1 <- newIORef Nothing
    r2 <- newIORef Nothing
    fparallel r1 r2 <|> xparallel r1 r2
```

The applicative instance implements a **non-buffering join**:

1. Both `mf` and `mx` may run in parallel (if `mf` contains `abduce`)
2. `r1` stores the last value of `mf`, `r2` stores the last value of `mx`
3. When either term produces a new value, it checks if the other has already produced one
4. If both have produced values, `f x` is computed and returned

**Semantic rule:**

$$\llbracket f \mathbin{<*>} x \rrbracket = \{f_i(x_j) \mid f_i \in \llbracket f \rrbracket, x_j \in \llbracket x \rrbracket, \text{both available}\}$$

> [!NOTE]
> This is NOT a cartesian product. If `f` produces values f₁, f₂ and `x` produces x₁, x₂,
> the results are NOT `{f₁ x₁, f₁ x₂, f₂ x₁, f₂ x₂}`.
> Instead, when f₂ arrives, only the current `x` (say x₁) is combined: `{f₁ x₁, f₂ x₁, ...}`.
> It is a **temporal join**, not a combinatorial one.

---

## 7. Derived Concurrency Primitives

### 7.1 `async`

```haskell
async :: IO b -> TransIO b
async mx = abduce >> liftIO mx
```

$$\llbracket \texttt{async}\ io \rrbracket = \text{fork}(\lambda(). io \gg \sigma.\texttt{fcomp})$$

Moves the IO action and its continuation to a new thread.

### 7.2 `waitEvents`

```haskell
waitEvents :: IO a -> TransIO a
waitEvents io = do
  abduce
  waitEvents1 io
  where
  waitEvents1 io = async1 io <|> waitEvents1 io
  async1 io = do { r <- liftIO io; abduce; return r }
```

**Operational semantics:**

1. `abduce` — detach from the main thread
2. `liftIO io` — block waiting for a result
3. `abduce` — fork the processing of the result to a new thread
4. `<|> waitEvents1 io` — since `async1` returned `Nothing` to the loop thread via the second `abduce`, the loop immediately iterates

This produces an **infinite stream** where each result is processed in its own thread:

$$\llbracket \texttt{waitEvents}\ io \rrbracket = \{io_1, io_2, io_3, \ldots\}_{\text{each in separate thread}}$$

### 7.3 `fork`

```haskell
fork :: TransIO () -> TransIO ()
fork proc = (abduce >> proc >> empty) <|> return ()
```

$$\llbracket \texttt{fork}\ p \rrbracket = \text{fork}(p) \cup \{()\}$$

The process `p` runs in a new thread; the current thread continues with `()`.

### 7.4 Thread Control

| Primitive | Effect on `TranShip` |
|-----------|---------------------|
| `threads n proc` | Sets `maxThread = Just (MVar n)` during `proc` |
| `threads 0 proc` | Forces sequential execution: `abduce` runs continuation in same thread |
| `anyThreads proc` | Sets `maxThread = Nothing` — unlimited threads |
| `freeThreads proc` | Sets `freeTh = True` — threads not tracked in tree |
| `hookedThreads proc` | Sets `freeTh = False` — threads tracked (default) |

---

## 8. The Backtracking System

### 8.1 Data Structure

```haskell
data Backtrack b = Backtrack
  { backtracking :: Maybe b                            -- Nothing = forward, Just = backtracking
  , backStack    :: [(b -> TransIO c, c -> TransIO a)] -- (handler, continuation) pairs
  }
```

The backtrack stack is **indexed by type** (stored in `mfData` via `Typeable`). This means multiple independent backtracking channels coexist:

- `Backtrack SomeException` — exception handlers
- `Backtrack ()` — undo handlers
- `Backtrack Finish` — finalization handlers
- `Backtrack MyCustomType` — user-defined channels

### 8.2 `onBack`: Registering a Handler

```haskell
onBack :: (Typeable b, Show b) => TransIO a -> (b -> TransIO a) -> TransIO a
onBack ac bac = Transient $ do
  registerBack (\reason -> bac reason)
  runTrans ac
```

`registerBack` pushes `(handler, current_continuation)` onto the typed backtrack stack:

$$\sigma.\texttt{backStack}_b \leftarrow (\texttt{handler}, \sigma.\texttt{fcomp}) : \sigma.\texttt{backStack}_b$$

### 8.3 `back`: Initiating Backtracking

```haskell
back :: (Typeable b, Show b) => b -> TransIO a
back reason = do
  bs@(Backtrack _ stack) <- getData
  goBackt bs

goBackt (Backtrack _ []) = empty        -- no more handlers
goBackt (Backtrack _ ((f, k) : bs)) = do
  setData $ Backtrack (Just reason) bs   -- record reason, pop handler
  x <- f reason                          -- execute handler
  Backtrack back' _ <- getData
  case back' of
    Nothing -> k x     -- forward set: resume with continuation k
    Just _  -> goBackt ...  -- still backtracking: continue to next handler
```

**Operational semantics of backtracking:**

```
back reason:
  for each (handler, continuation) in stack (LIFO order):
    execute handler(reason)
    if handler called forward:
      resume execution at continuation(handler_result)
      STOP backtracking
    else:
      continue to next handler
  if stack empty:
    empty (computation terminates)
```

### 8.4 `forward`: Stopping Backtracking

```haskell
forward reason = do
  Backtrack _ stack <- getData
  setData $ Backtrack (Nothing `asTypeOf` Just reason) stack
```

Sets `backtracking = Nothing`, which causes `goBackt` to execute the saved continuation `k` instead of continuing to pop the stack.

### 8.5 Exception Handling as Backtracking

Exceptions are implemented as a special case of backtracking on `SomeException`:

```haskell
onException :: Exception e => (e -> TransIO ()) -> TransIO ()
onException exc = return () `onException'` exc

onException' mx f = onAnyException mx $ \e ->
  case fromException e of
    Nothing -> back e          -- not my type: propagate
    Just e' -> f e'            -- my type: handle

continue :: TransIO ()
continue = forward (ofType :: SomeException)
```

**The relationship:**

| Exception concept | Backtracking equivalent |
|-------------------|------------------------|
| `onException handler` | `onBack1 (\(SomeException e) -> handler e)` |
| `throw e` | `back (SomeException e)` |
| `continue` | `forward (SomeException undefined)` |
| `catcht mx handler` | `localExceptions $ onException' mx (\e -> continue >> handler e)` |

> [!IMPORTANT]
> Unlike standard Haskell exceptions, Transient exceptions propagate through the
> **backtrack stack** (LIFO, through all registered handlers) rather than unwinding the
> call stack. This means multiple handlers execute for the same exception.
> `continue` stops propagation; without it, all handlers in the stack are executed.

### 8.6 Finalization as Backtracking

```haskell
onFinish :: (String -> TransIO ()) -> TransIO ()
onFinish mx = hookedThreads $ do
  anyThreads abduce
  cont <- get
  done <- liftIO $ newIORef False
  onBack1 $ \(Finish reason) -> tmask $ do
    has <- hasNoAliveThreads st cont "id"
    guard has
    f <- liftIO $ atomicModifyIORef done (\x -> (True, x))
    unless f $ mx reason
```

Finalization is backtracking on `Finish`. It fires when **all child threads of the scope have terminated**.

---

## 9. The Event System

### 9.1 `react`: De-inversion of Control

```haskell
react :: ((eventdata -> IO response) -> IO b)
      -> IO response
      -> TransIO eventdata
```

**Operational semantics:**

1. Capture the current continuation `fcomp` from `TranShip`
2. Create a callback `cb` that, when called with `eventdata`, executes `fcomp(eventdata)`
3. Pass `cb` to the external event system via `setHandler`
4. Return `Nothing` — the current thread stops here

$$\llbracket \texttt{react}\ \text{setHandler}\ \text{response} \rrbracket = \text{register}(\sigma.\texttt{fcomp}) \quad;\quad \forall \text{event}: \text{fork}(\sigma.\texttt{fcomp}(\text{event}))$$

Each time the external system calls the callback, a new invocation of the continuation occurs, producing a new result.

### 9.2 EVars: Reactive Variables

```haskell
newtype EVar a = EVar (IORef [(Int, a -> IO ())])
```

An EVar maintains a list of subscribers. Each subscriber is a callback (derived from `react`) that receives written values.

| Operation | Semantics |
|-----------|-----------|
| `newEVar` | Create empty subscriber list |
| `readEVar ev` | `react (register_callback_on ev)` — subscribe to future writes |
| `writeEVar ev x` | For each subscriber `f`: call `f(x)` — triggers all continuations |
| `cleanEVar ev` | Remove all subscribers |

**Key semantics of `writeEVar`:**

```haskell
writeEVar (EVar ref) x = do
  conts <- liftIO $ readIORef ref
  liftIO $ mapM_ (\(_, f) -> f x) conts
```

`writeEVar` is **synchronous**: it invokes each subscriber's continuation in the calling thread. To make it asynchronous, the subscriber's continuation should contain `abduce`.

---

## 10. Distributed Computing

### 10.1 The Cloud Monad

```haskell
newtype Cloud a = Cloud (TransIO a)
```

`Cloud` is a newtype over `TransIO` that constrains values to be `Loggable` (serializable). This enables continuations to be transmitted across nodes.

### 10.2 `logged`: Computation Logging

```haskell
local :: Loggable a => TransIO a -> Cloud a
local = Cloud . logged
```

`logged` wraps a computation so that its result is added to a serialized log. When the computation is replayed on another node, `logged` reads the result from the log instead of re-executing:

$$\llbracket \texttt{logged}\ m \rrbracket(\sigma) = \begin{cases} \llbracket m \rrbracket(\sigma) \quad;\quad \text{append result to log} & \text{if } \neg\sigma.\texttt{recover} \\ \text{read result from log} & \text{if } \sigma.\texttt{recover} \end{cases}$$

### 10.3 `wormhole`: Opening a Connection

```haskell
wormhole :: Loggable a => Node -> Cloud a -> Cloud a
```

Establishes a bidirectional communication channel with a remote node and executes a computation within that context:

1. Connect to the node via socket/websocket
2. Set the connection in the state (`setData conn`)
3. Execute the enclosed computation
4. The connection remains open for streaming

### 10.4 `teleport`: Migrating Execution

```haskell
teleport :: Cloud ()
```

**Operational semantics:**

**On the sending node (run mode):**
1. Serialize the current log (all `logged` results up to this point)
2. Send the serialized log to the remote node via the wormhole connection
3. `abduce <|> empty` — fork a thread to wait for responses, current thread sees `empty`

**On the receiving node (recover mode):**
1. Receive the serialized log fragment (the "delta" since the last interaction with this node).
2. Re-execute incrementally starting from the **last execution point (closure)** on that specific remote node, *not* from the very beginning of the program. The node reconstructs its execution stack incrementally.
3. For each `logged` step in the received log fragment, read the result from the log instead of executing it.
4. When the log fragment is exhausted, resume executing new computations normally.

$$\llbracket \texttt{teleport} \rrbracket = \text{send}(\sigma.\texttt{log} \setminus \sigma.\texttt{prevLog}_{\text{remote}}) \quad;\quad \sigma.\texttt{execMode} \leftarrow \text{Remote}$$

**The teleport ping-pong:**
```
wormhole nodeB $ do
    x <- local computation1    -- runs on nodeA, logged
    teleport                   -- sends log to nodeB
    y <- local computation2    -- runs on nodeB (computation1 replayed from log)
    teleport                   -- sends log back to nodeA
    local $ use x y            -- runs on nodeA (computation1 and 2 from log)
```

### 10.5 Derived Distributed Primitives

| Primitive | Definition | Semantics |
|-----------|------------|-----------|
| `beamTo node` | `wormhole node teleport` | Move execution to node |
| `forkTo node` | `beamTo node <\|> return ()` | Fork execution to node |
| `runAt node proc` | `wormhole node $ atRemote proc` | Execute proc remotely, return result |
| `atRemote proc` | `teleport >> loggedc proc >>= \r -> teleport >> return r` | Execute proc on the remote side, return result to caller |
| `clustered proc` | `foldr (<\|>) empty [runAt n proc \| n <- nodes]` | Execute on all nodes in parallel |

---

## 11. Thread Lifecycle and Cleanup

### 11.1 Lifecycle States

```haskell
data Status = Dead | Alive
data LifeCycle = LF Status [Listener]
```

### 11.2 Cleanup Algorithm (`freelogic`)

When a thread finishes:

```
freelogic(this_thread):
  parent = this_thread.parent
  others = parent.children - {this_thread}
  dead_parent = isDead(parent) && noListeners(parent)

  case (this_thread is active, parent is active):
    (True,  True)  -> do nothing (both alive)
    (False, True)  -> remove this_thread from parent.children
    (_,     False) -> recurse: freelogic(parent)
                      if this_thread is active, rehang to first active ancestor
```

This recursive cleanup ensures that dead branches of the thread tree are pruned, and orphaned active threads are re-attached to the nearest living ancestor.

### 11.3 Cleanup on Thread Termination

```haskell
runContCleanup cont dat = mask $ \unmask -> do
  writeIORef (rThreadId cont) currentThread
  (_, c) <- unmask (runContIO dat cont) `catch` backExceptIO cont
  cleanupThreads c
```

Every forked thread runs inside `runContCleanup`, which:
1. Executes the continuation
2. Catches any exception and converts it to backtracking (`backExceptIO`)
3. Runs `cleanupThreads` to prune the thread tree

---

## 12. Algebraic Laws

### 12.1 Monad Laws

| Law | Status | Notes |
|-----|--------|-------|
| Left identity: `return a >>= f ≡ f a` | ✅ Holds | Standard |
| Right identity: `m >>= return ≡ m` | ✅ Holds | Standard |
| Associativity: `(m >>= f) >>= g ≡ m >>= (\x -> f x >>= g)` | ✅ Holds | By continuation composition |

### 12.2 Alternative Laws

| Law | Status | Notes |
|-----|--------|-------|
| Identity: `empty <\|> x ≡ x` | ✅ Holds | `empty` returns Nothing, so `x` runs |
| Identity: `x <\|> empty ≡ x` | ⚠️ Holds only if `x` succeeds | If `x` returns Nothing, `empty` runs and returns Nothing |
| Associativity: `(x <\|> y) <\|> z ≡ x <\|> (y <\|> z)` | ⚠️ Holds sequentially | Under concurrency, timing differences may alter result order |

### 12.3 MonadPlus Laws

| Law | Status | Notes |
|-----|--------|-------|
| Left zero: `empty >>= f ≡ empty` | ✅ Holds | `empty` produces Nothing, `f` never runs |
| Right zero: `m >> empty ≡ empty` | ⚠️ Context-dependent | `m` may have side effects; `empty` stops the current thread but forked threads continue |

### 12.4 Concurrency-Specific Laws

| Law | Notes |
|-----|-------|
| `abduce >> x ≡ x` (semantically) | Same result, different thread |
| `(abduce >> a) <\|> b ≡ a ∥ b` | Parallel execution of a and b |
| `threads 0 $ abduce >> x ≡ x` | No fork when threads = 0 |
| `fork p >> q ≡ p ∥ q` | p and q execute in parallel |

### 12.5 Backtracking Laws

| Law | Notes |
|-----|-------|
| `(x \`onBack\` h1) \`onBack\` h2 ; back r` | Executes h2 first, then h1 (LIFO) |
| `onBack x (\r -> forward r >> v) ; back r` | Stops backtracking, returns v to continuation |
| `back r` where no handlers registered | `empty` — computation terminates |
| `onException h ; onException h' ; throwt e` | h' executes first, then h (LIFO) |

---

## 13. Comparison with Other Models

### 13.1 vs. Async/Await (JavaScript, Python, C#)

| Aspect | Async/Await | Transient |
|--------|-------------|-----------|
| Result cardinality | One future → one result | One computation → stream of results |
| Composition | Sequential (`await`) | Algebraic (`<\|>`, `<*>`, `>>=`) |
| Error handling | try/catch per future | Backtracking through handler stack |
| Parallelism | `Promise.all` / `Task.WhenAll` | `<\|>` (automatic) |

### 13.2 vs. Reactive Streams (RxJS, Reactor)

| Aspect | Reactive Streams | Transient |
|--------|-----------------|-----------|
| Abstraction | `Observable<T>` | `TransIO a` |
| Composition | `.map`, `.flatMap`, `.filter` | `>>=`, `<*>`, `guard` |
| Backpressure | Explicit | Via `threads n` |
| Side effects | Managed via schedulers | Natural via IO monad |
| Distribution | Not built-in | `teleport`/`wormhole` |

### 13.3 vs. Prolog (Logic Programming)

| Aspect | Prolog | Transient |
|--------|--------|-----------|
| Non-determinism | Unification + backtracking | `<\|>` + `back`/`onBack` |
| Concurrency | Not built-in | `abduce` |
| Cut (!) | Stops alternatives | `empty` / `fullStop` |
| Side effects | Impure predicates | Full IO monad |

### 13.4 vs. Actor Model (Erlang, Akka)

| Aspect | Actors | Transient |
|--------|--------|-----------|
| Communication | Message passing | Shared continuations |
| State | Per-actor state | Per-continuation state (inherited) |
| Distribution | Location-transparent actors | Continuation migration (`teleport`) |
| Supervision | Supervisor trees | Thread tree + `onFinish`/`onException` |

---

## 14. Summary: The Transient Execution Model

The Transient execution model can be summarized by five principles:

1. **Computations produce streams, not values.** A `TransIO a` may yield zero, one, or many `a` values, each triggering the continuation independently.

2. **The continuation is a first-class, mutable value.** Stored in `fcomp`, it can be forked (`abduce`), serialized (`teleport`), replayed (`logged`), or traversed backwards (`back`).

3. **Two orthogonal axes of composition.** Monadic bind (`>>=`) is sequential; algebraic operators (`<|>`, `<*>`) are potentially parallel. The programmer chooses the axis per expression.

4. **State flows downward.** Child threads inherit the full state of their parent, including handlers, variables, and the continuation. This eliminates the need for explicit handler registration in child threads.

5. **Events are streams.** External callbacks (`react`), reactive variables (`EVar`), IO polling (`waitEvents`), and user input (`minput`) all produce the same thing: a stream of values flowing through the continuation. There is no fundamental distinction between "an event" and "a computation result."

These five principles, implemented through a single mechanism (continuation manipulation in the `TranShip` state), produce a unified framework for concurrency, distribution, streaming, error handling, and interactive I/O.

---

*Document generated from source code analysis of the Transient framework (transient, transient-universe packages). April 2026.*
