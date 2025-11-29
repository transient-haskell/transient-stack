# `transient` Advanced Primitives Cheatsheet

This cheatsheet covers more advanced or specialized primitives in `transient` and `transient-universe`, focusing on persistence, distributed patterns, and reactive programming.

## 1. Persistence and Workflow Control

| Primitive | Explanation | Example |
| :-------- | :---------- | :------ |
| `logged` | Wraps a computation, saving its result to a log. This is the core mechanism for persistence and code mobility, as the log can be recovered on another node or after a restart to resume the computation. |<pre>
-- The result of this IO action is logged.
nodeName <- logged $ liftIO getHostName
liftIO $ putStrLn $ "Logged node name: " ++ nodeName
</pre> |
| `endpoint` | Creates a persistent and recoverable point in a workflow. It saves the state of the computation and waits for external data to be sent to it to resume execution. It's the foundation for `minput`. |<pre>
-- Creates a persistent task that waits for data.
local $ do
  endpoint $ Just "my-task"
  receivedData <- param :: TransIO String
  liftIO $ print $ "Task resumed with: " ++ receivedData
</pre> |
| `retry` | If a computation fails, `retry` will re-execute it from the beginning. It can be configured to retry a specific number of times, making it ideal for handling transient network failures. |<pre>
-- Tries to connect up to 3 times before failing.
retry 3 $ do
  liftIO $ putStrLn "Attempting to connect..."
  connectToService -- An action that might fail
</pre> |

## 2. Reactive and Event-Driven Primitives

| Primitive | Explanation | Example |
| :-------- | :---------- | :------ |
| `react` | Converts a traditional callback-based asynchronous API into a composable `TransIO` event stream. It's the bridge to integrate external event sources (like UIs or other libraries) into `transient`. |<pre>
-- Assuming `onEvent :: ((String -> IO ()) -> IO ())`
-- `react` turns the callback into a value in the monad.
main = keep $ do
  liftIO $ putStrLn "Waiting for event..."
  eventData <- react onEvent
  liftIO $ putStrLn $ "Event received: " ++ eventData
</pre> |
| `EVar` | Event Variables provide a local publish-subscribe mechanism. Threads can `writeEVar` to publish events and `readEVar` to subscribe to them, enabling decoupled communication within the same process. |<pre>
main = keep $ do
  ev <- newEVar
  -- Subscriber
  readEVar ev >>= liftIO . putStrLn
  -- Publisher
  freeThreads $ liftIO $ threadDelay 1000000 >> writeEVar ev "Hello"
</pre> |
| `Mailbox` | A global, type-indexed, publish-subscribe system built on `EVar`s. `putMailbox` and `getMailbox` allow components to communicate without any direct reference to each other, simply by using the type of the data. |<pre>
-- Component A
getMailbox >>= liftIO . print :: TransIO Int

-- Component B, somewhere else
putMailbox (42 :: Int)
</pre> |

## 3. Distributed Computing Patterns

| Primitive | Explanation | Example |
| :-------- | :---------- | :------ |
| `mclustered` | A variant of `clustered`. It executes a computation on all connected nodes but instead of collecting the results in a list, it combines them using the `mappend` (`<>`) operation of their `Monoid` instance. |<pre>
-- Gathers log messages from all nodes into a single string.
allLogs <- mclustered $ local $ return "Log from my node...\n"
liftIO $ putStrLn allLogs
</pre> |
| `foldNet` | A generic, distributed fold operation over the network. It takes a binary operator, an initial value, and an action, executing the action on nodes and folding the results. It is the basis for `exploreNet` and `exploreNetUntil`. |<pre>
-- Finds the maximum value across all nodes.
maxValue <- foldNet (
x ny -> max <$> nx <*> ny) (return 0) $
            local $ return (10 :: Int) -- some node-specific value
liftIO $ print maxValue
</pre> |
| `exploreNet` | A specialization of `foldNet` that uses a `Monoid` to aggregate results from all nodes in the network. It's useful for gathering information in a map-reduce style. |<pre>
-- Gets a list of all active nodes.
allNodes <- exploreNet $ local $ (:[]) <$> getMyNode
liftIO $ print allNodes
</pre> |
| `exploreNetUntil` | A specialization of `foldNet` that uses `<|>` to combine results. It explores the network and returns the result from the *first* node that successfully completes the computation, ignoring the rest. |<pre>
-- Finds the first available worker node.
firstWorker <- exploreNetUntil $ local $ do
  isBusy <- checkStatus
  if isBusy then empty else Just <$> getMyNode
</pre> |

## 4. Advanced Web and API Primitives

| Primitive | Explanation | Example |
| :-------- | :---------- | :------ |
| `moutput` | Sends a final response back to the client and terminates a specific web workflow. Unlike intermediate responses, this signals the end of the interaction. |<pre>
main = keep' $ do
  name <- minput "askName" "What's your name?"
  moutput $ "Hello, " ++ name ++ ". End of conversation."
</pre> |
| `public`/`published` | Provides a mechanism for endpoint discovery. `public` marks a `minput` with a key. `published` allows a client to request a list of all endpoints available under that key. |<pre>
-- Server: Publish an endpoint
public "actions" $ minput "task1" "Run task 1"

-- Client: Discover available actions
actions <- published "actions"
</pre> |
| `param`/`received` | Allows for fine-grained parsing of request data. `param` can extract a single parameter from a request path or body, and `received` can check if a specific value was sent. |<pre>
-- Handles requests like /user/some-user-id
endpoint "user" >> do
  received "user"
  userId <- param :: TransIO String
  moutput $ "Data for user: " ++ userId
</pre> |
| `setSessionState` | Sets a value in the user's session that will persist across multiple HTTP requests. It is indexed by the value's type, providing type-safe session management. |<pre>
-- In a login flow:
let currentUser = "JohnDoe"
setSessionState currentUser

-- In another part of the app:
mUser <- getSessionState :: TransIO (Maybe String)
</pre> |