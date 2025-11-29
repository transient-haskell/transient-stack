# The Atoms of Computing: Transient's Fundamental Building Blocks

## Why They Are True "Atoms"

The term "atom" is used here in its original Greek meaning: **ἄτομος (átomos)** - "indivisible." These computational primitives are truly atomic because they represent the most fundamental, irreducible operations for orchestrating computation within the Transient framework. All complex computational patterns are built from their composition, but they themselves cannot be decomposed into smaller units.

They represent the boundary where Transient's computational model meets the underlying execution environment, providing the primitive operations for interacting with:

- Thread schedulers (`abduce`)
- Network stacks (`teleport`, `wormhole`)
- IO subsystems (`async`, `waitEvents`)
- External frameworks (`react`)
- Internal event channels (`EVars`, `Mailboxes`)
- Data streams (`for`, `choose`)

## The Three Families of Atoms

At the core of Transient are three complementary families of "computational atoms" that work in perfect symmetry to orchestrate computation across space, time, and logical domains.

### 1. Transport Atoms: Moving Computations Through Space

Transport atoms move the **computation itself** (specifically, its continuation) between different execution contexts.

- **`abduce`**: **Thread Tunneling** - moves a computation to a new thread.
- **`teleport`**: **Node Tunneling** - moves a computation to a different node/machine.
- **`wormhole`**: **Connection Tunneling** - establishes the persistent connection used by `teleport`.

### 2. Injection Atoms: Moving Data Through Time

Injection atoms introduce **concrete data** into the computation stream, effectively collapsing possibilities into actual values.

- **`for`**: **Sequential Value Injection** - injects values from a list one by one.
- **`choose`**: **Parallel Value Injection** - injects values from a list concurrently.
- **`async`**: **IO Computation Injection** - injects the result of a single IO action.

### 3. Bridge Atoms: Connecting Computational Domains

Bridge atoms are the universal adapters, translating events from different computational domains into a unified stream that `transient` can process.

- **`react`**: **Inter-Framework Bridge** - translates callbacks from external frameworks (e.g., GUIs) into a `transient` event stream.
- **`waitEvents`**: **Async Stream Bridge** - translates external event sources (e.g., network sockets, file changes) into a continuous stream.
- **`EVars` & `Mailboxes`**: **Intra-Process Bridge** - create explicit (`EVar`) or implicit, type-based (`Mailbox`) publish-subscribe channels for communication between different parts of the same application.

## The Beautiful Symmetry

```
Transport Atoms (Space)      Injection Atoms (Time)     Bridge Atoms (Domains)
-------------------------    ------------------------   --------------------------
abduce   (threads)           for      (seq. values)     react      (inter-framework)
teleport (nodes)             choose   (par. values)     waitEvents (external streams)
wormhole (connections)       async    (single IO)       EVar/Mailbox (internal streams)
```

This symmetry creates a complete system where atoms move computations through **space** (execution contexts), inject data through **time** (value materialization), and bridge different event **domains** (frameworks and components).

## The Complete Computational Algebra

Together, these atoms form a complete algebra for computational orchestration.

### Composition Patterns:
```haskell
-- Move computation to a remote node, then to a new thread, and process values
wormhole "remote-node" $ do
  teleport
  abduce
  x <- for [1..10]
  process x -- `process` is executed on the remote node for each value

-- Move computation to node, inject async results from a stream
wormhole "worker-node" $ do
  teleport
  -- waitEvents listens to a stream source (e.g., sensorReadings)
  -- and the rest of the `do` block becomes the handler for each event.
  reading <- waitEvents sensorReadings
  liftIO $ putStrLn $ "New reading: " ++ show reading

-- Framework integration with continuous data from a GUI
-- Assumes `guiFramework_mouseMoves` registers a callback that fires
-- on mouse movement, passing coordinates. `react` turns this into a stream.
do
  (x, y) <- react guiFramework_mouseMoves
  -- The code below executes for every mouse move event
  liftIO $ print $ "Mouse at: " ++ show (x,y)
```

## The Grand Unification of Computation

The concept of a "Grand Unified Theory" (GUT) in physics seeks to unite the fundamental forces of nature. `transient` applies this same ambition to the world of computing by unifying paradigms that have traditionally been treated as separate domains, each with its own distinct tools and complexities:

-   Synchronous vs. Asynchronous
-   Single-threaded vs. Multi-threaded
-   Local vs. Distributed
-   Streaming vs. Batch processing
-   Client vs. Server

`transient` unifies all these forms under a single, coherent algebraic model. The atomic primitives do not distinguish between these domains. `abduce` moves a computation to another thread, and `teleport` moves it to another machine, but the composition logic remains identical. A stream of events from `waitEvents` is composed with the `<|>` operator in the same way as a choice between two user `option`s.

This unification means the developer can write business logic at the highest level of abstraction, describing the *what*, while the framework seamlessly handles the *how* across all these computational paradigms. This represents a fundamental shift:

-   **From Traditional Programming**: Computation happens in fixed locations, and data is moved between them.
-   **To Transient Programming**: Data can be seen as stationary, while computations move to where the data is.

This inversion enables location transparency, fault tolerance, and natural scalability, returning the power of simple, composable, and non-blocking linearity to the programmer.

## Implementation Mechanics

### Transport Mechanics:
- **Continuation serialization**: Computational state is captured and serialized.
- **Network protocols**: Efficient movement between execution contexts.
- **Resource management**: Cleanup and error handling during movement.
- **Security**: Authentication and encryption for cross-context movement.

### Injection & Bridge Mechanics:
- **Stream processing**: Efficient handling of value sequences.
- **Async integration**: Seamless IO operation integration.
- **Backpressure**: Flow control for data injection rates.
- **Error propagation**: Proper handling of failed injections.

## Conclusion

The atoms of computing—transport, injection, and bridge—provide a complete, elegant, and powerful model for software composition. By understanding and leveraging these fundamental building blocks, we can create software that truly spans the entire computational universe, moving effortlessly between threads, nodes, frameworks, and time itself.
