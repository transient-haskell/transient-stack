# `transient` Primitives Cheatsheet

This cheatsheet summarizes the key primitives of the `transient` and `transient-universe` libraries in Haskell, with concise explanations and examples.

## 1. Execution and Main Control Primitives

| Primitive | Explanation | Example |
| :-------- | :---------- | :------ |
| `keep` | Initializes and keeps an interactive `TransIO` application running. It executes the main computation and a command-line interpreter (REPL). It terminates when the computation produces an exit event (e.g., `exit`). |<pre><br>main = keep \$ do<br>  liftIO \$ putStrLn "¡Hola desde Transient!"<br>  (option "greet" "Says hello" >> liftIO (putStrLn "¡Hola!"))<br>|
| `keep'` | Initializes and executes a `TransIO` computation for parallel processing. It does not include the console REPL. It waits for all generated threads to finish and returns a list with their results. |<pre><br>main = do<br>  results <- keep' \$ do<br>    r1 <- async \$ return "Task 1 completed"<br>    r2 <- async \$ return "Task 2 completed"<br>    return r1 <|> return r2<br>  liftIO \$ print results<br>|
| `option` | Declares a persistent command in the console REPL. The associated computation is activated each time the user invokes the command. It acts as a persistent event producer. |<pre><br>menu = (option "add" "Add a new task" >> liftIO (putStrLn "Adding...")) <|><br>       (option "list" "List tasks" >> liftIO (putStrLn "Listing..."))<br>main = keep menu<br>|
| `option1` | Declares a command in the console REPL that can only be invoked once. After its first use, the command is no longer available. |<pre><br>main = keep \$ do<br>  option1 "init" "Initialize system" >> liftIO (putStrLn "System initialized.")<br>  liftIO \$ putStrLn "The 'init' option is no longer available."<br>|
| `input` | Prompts the user for input in the console, reads it, and validates it. It is typically used after an `option`. |<pre><br>main = keep \$ do<br>  option "num" "Enter a number < 10" >> do<br>    n <- input (<10) "Number? > "<br>    liftIO \$ print \$ "You entered: " ++ show n<br>|
| `<|>` | Alternative operator. If the left computation fails (produces `empty` or `stop`), the right computation is executed. It allows defining alternative execution paths or combining event streams. |<pre><br>main = keep \$ do<br>  (option "a" "Option A" >> liftIO (putStrLn "You chose A")) <|><br>  (option "b" "Option B" >> liftIO (putStrLn "You chose B"))<br>|

## 2. Concurrency and Parallelism Primitives

| Primitive | Explanation | Example |
| :-------- | :---------- | :------ |
| `abduce` | Forks the computation. The rest of the `do` block is executed in a new thread, while for the current thread, `abduce` acts as `stop` (fails). It is the basis for building other concurrency primitives. |<pre><br>main = keep \$ do<br>  (do<br>    liftIO \$ putStrLn "Main Thread: Before abduce"<br>    abduce<br>    liftIO \$ putStrLn "Child Thread: After abduce"<br>  ) <|><br>  (do<br>    liftIO \$ putStrLn "Main Thread: Alternative path"<br>  )<br>  liftIO \$ putStrLn "Both threads: End of block"<br>|
| `async` | Executes an `IO` action in a new background thread and returns its result to the `TransIO` flow when it finishes. Built on `abduce`. |<pre><br>main = keep \$ do<br>  liftIO \$ putStrLn "Starting asynchronous task..."<br>  result <- async \$ do<br>    liftIO \$ threadDelay 2000000 -- Simulate work<br>    return "Task completed"<br>  liftIO \$ putStrLn \$ "Result received: " ++ result<br>|
| `for` | Processes a list of elements sequentially in a single thread. Although the loop body can launch asynchronous tasks, `for` schedules each iteration in order. Equivalent to `threads 0 . choose`. |<pre><br>main = keep \$ do<br>  n <- for [1..3 :: Int]<br>  liftIO \$ print n<br>|
| `choose` | Processes a list of elements in parallel, attempting to execute each element in a separate thread. The order of execution is not guaranteed. | <pre><br>main = keep \$ threads 2 \$ do<br>  -- Only 2 threads will be used for printing<br>  n <- choose [1..5 :: Int]<br>  liftIO \$ print n<br></pre>|
| `threads` | Limits the maximum number of threads that can be created for a computation. `threads 0` forces sequential execution in a single thread. |<pre><br>main = keep \$ threads 1 \$ do<br>  -- Only one `print` will execute at a time<br>  n <- choose [1..5 :: Int]<br>  liftIO \$ print n<br>|
| `await` | Waits for a `TransIO` computation (and all child threads it has generated) to complete fully, collecting all results into a list. |<pre><br>main = keep \$ do<br>  results <- await \$<br>    (async \$ return "A") <\|><br>    (async \$ return "B")<br>  liftIO \$ print results -- Prints ["A", "B"] or ["B", "A"]<br>|
| `<*>` | Applicative operator. Executes the left and right computations in parallel and combines their results. |<pre><br>main = keep \$ do<br>  res <- (,) <$> (async \$ return "Hello") <*> (async \$ return "World")<br>  liftIO \$ print res -- Prints ("Hello", "World")<br>|
| `<>` | `Semigroup` operator. Executes the left and right computations in parallel and concatenates their results (if the type allows it). |<pre><br>main = keep \$ do<br>  res <- (async \$ return "Part1") <> (async \$ return "Part2")<br>  liftIO \$ putStrLn res -- Prints "Part1Part2"|
| `+` (Num) | Overloaded arithmetic operator for `TransIO`. Executes the computations in parallel and sums their results. |<pre><br>main = keep \$ do<br>  res <- (async \$ return 5) + (async \$ return 3)<br>  liftIO \$ print res -- Prints 8
|

## 3. Control Flow and Error Handling Primitives

| Primitive | Explanation | Example |
| :-------- | :---------- | :------ |
| `onException` | Registers a handler for Haskell exceptions (`SomeException`). The handler executes when an exception occurs within the computation's scope. Handlers are chained and execute in reverse order of their definition. |<pre><br>main = keep \$ do<br>  onException \$ \e -> liftIO \$ print \$ "Error caught: " ++ show e<br>  liftIO \$ fail "Something went wrong!"
|
| `forward` | Stops the propagation of a specific type of backtracking event (e.g., an exception, an undo event) and resumes normal execution. Used within handlers (`onBack`, `onException`, etc.) to signal that the event has been handled and no further handlers for that type should be executed. |<pre><br>main = keep \$ do<br>  onException \$ \e -> do<br>    liftIO \$ putStrLn "Handler: Error handled, stopping propagation."<br>forward e -- Stops further exception propagation<br>  liftIO \$ fail "Failure"<br>  liftIO \$ putStrLn "Program continues here."
|
| `continue` | A specialized version of `forward` used within exception handlers (`onException`). It stops the propagation of the exception backtracking and resumes normal program execution from that point. |<pre><br>main = keep \$ do<br>  (do<br>    onException \$ \(e :: IOException) -> do<br>      liftIO \$ putStrLn "File not found, creating default."
      -- Logic to create file<br>      continue -- Stops exception propagation and resumes normal execution<br>    liftIO \$ readFile "non_existent.txt"
  )<br>  liftIO \$ putStrLn "The program continues here."
|
| `onUndo` | Registers a handler for "undo" or "cancel" events. It executes when an `undo` event is triggered. |<pre><br>main = keep \$ do<br>  onUndo \$ liftIO \$ putStrLn "Operation undone. Cleaning..."
  option "cancel" "Cancel operation" >> undo<br>  liftIO \$ putStrLn "Performing long operation..."
|
| `undo` | Triggers an "undo" event, activating registered `onUndo` handlers. | (See `onUndo` example) |
| `onFinish` | Registers a handler that executes when a computation and all its child threads have completed fully (either by success, failure, or cancellation). It guarantees resource cleanup. |<pre><br>main = keep \$ do<br>  onFinish \$ const \$ liftIO \$ putStrLn "Resources released."
  liftIO \$ putStrLn "Starting task..."
  -- ... task that may fail or complete ...<br>  liftIO \$ putStrLn "Task finished."
|
| `finish` | Triggers a completion event. It is usually done by the `transient` runtime automatically when a computation branch finishes. | (Normally not called directly, it's internal) |

## 4. Distributed Computing Primitives (`transient-universe`)

| Primitive | Explanation | Example |
| :-------- | :---------- | :------ |
| `local` | Executes a `TransIO` computation on the current node. Its result is "logged" so it can be "teleported" to other nodes. |<pre><br>main = keep \$ initNode \$ do<br>  local \$ liftIO \$ putStrLn "This message only on my node."
|
| `runAt` | Executes a computation on a specific remote node. The computation is "teleported" to the remote node, executed there, and the result is returned to the original node. |<pre><br>-- Assuming 'remoteNode' is a Node<br>main = keep \$ initNode \$ do<br>  res <- runAt remoteNode \$ local \$ return "Hola desde el remoto"<br>  liftIO \$ putStrLn res<br>|
| `atRemote` | Within a `wormhole` or `onBrowser` context, it indicates that the nested computation should be executed on the remote node (server) instead of the local node (client). |<pre><br>-- Conceptual example in a web context<br>webFib = onBrowser \$ do<br>  -- This executes in the browser<br>  local . render \$ h1 "Click for Fibonacci"<br>  -- This executes on the server<br>  fibNum <- atRemote \$ do<br>    n <- local . choose \$ take 1 fibs<br>    return \$ show n<br>  -- This executes back in the browser<br>  local . render \$ h2 fibNum<br>|
| `clustered` | Executes a computation on all nodes in the cluster in parallel. Results are collected on the node that initiated the call. |<pre><br>main = keep \$ initNode \$ do<br>  -- Assuming other nodes are connected<br>  messages <- clustered \$ local \$ do<br>    myNode <- getMyNode<br>    return \$ "Hello from " ++ show myNode<br>  liftIO \$ print messages<br>|
| `teleport` | The low-level primitive for moving execution. It sends the remaining computation log to the remote node and stops local execution. | (Normally not called directly, it's internal to `runAt`, `atRemote`, etc.) |

---