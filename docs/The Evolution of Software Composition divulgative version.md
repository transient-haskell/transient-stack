# Evolution of Composition

## Grand Unification Timeline

CPU Machine Code Era:
- Technology: CPUs, Interrupts, High level languages (FORTRAN)
- Result: Batch processing, direct execution of formulas (pure numeric algebra)

Memory Access Era:
- Technology: DMA, OS with synchronous IO blocking (Linux)
- Result: Interactive console apps, algebraic composition with I/O blocking, single threading

### The OOP Composition Ice Age

- Technology: Disk I/O, Mouse, Communication Systems 
- Approach: Object-Oriented Programming (message-based), epoll, event loops
- Result: Complex spaghetti code without algebraic composition

### The Small Global Warming

- Technology: Threading, Parallelism, Concurrency
- Approach: Semaphores, critical sections, async/await patterns
- Result: Imperative programming with blocking operations; algebraic composition absent; synchronous and asynchronous modes remain separate

### Back to the Ice Age

- Technology: Web Development
- Approach: Web servers, routing systems, contexts, event loops
- Result: Manual state management with no compositional benefits

### The Paradise Lost

Continuations could have solved the composition problems but were abandoned due to:
- Large execution states
- OOP dominance
- Disconnection of academia from real world programming needs
- Lack of global vision (get things done)
- Search for substitutes:
  - Modularity
  - Encapsulation
  - Separation of concerns
- Partial solutions: async/await
- False dichotomies: block programming versus microservices

### Modern Distributed Era

- Technology: Distributed Computing
- Approach: Actor model, agent programming (OOP with other names)
- Result: No advancement in composition, artisanal programming

- Technology: Client-side Programming
- Approach: Message passing, web services, JSON, callbacks
- Result: No imperative composition, explicit state management

- Technology: Multiuser Workflows (Blockchain contracts)
- Approach: Same solutions
- Result: Similar limitations

## The New Grand Unification: Transient

**Core Principle:** Everything should compose with anything

Key Concepts:
- New threads can execute continuations
- "async x" is a thread that executes the same continuation with a different result x
- Parallelism represents alternatives with different threads
- Streaming is composition of parallel applicatives
- Implicit concurrency is programmed within applicatives
- Concurrency consists of applicatives of different threads
- Formulas/binary operators can be constructed with applicatives
- Execution states can be transported as logs and restored
- Callbacks are continuations
- Streaming is a composition of alternatives

### Implementation Details:
- Requests/responses send/receive stack states to build execution stacks of communicating machines upon previous states
- Web routes are stacks
- Execution logs are serializations of stack
- Intermediate results can be removed from logs when not in scope
- GET Web requests are logs
- Messages/web/distributed requests can transport stacks as logs
- Messages can address previous restored stacks to construct distributed computing state among different machines
- Stacks serialize as logs
- Deserialize to restore any execution state upon previous states


- synchronous AND asynchronous: Horizontally asyncronous, vertically syncronouys

```haskell
do
  this <- async(is) + asynchronous
  async(is)
  sinchronous
```