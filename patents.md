I want to summarize the things that I consider unique in transient
With full composability I mean the availiability of two binary operator such that  

```haskell
<|> ::  m x -> m x -> m x   
<*> :: m (y -> x) -> m y -> m x
 ```

The composition of two elements produce a third element with the same signature where `m` is the monad and x is the type of the result.
- full composability of threaded routines. where the operands run in different threads
      - The two operators introduce two ways: the <|> introduce  parallel execution. <*> introduce concurrency
     -  The <*> concurrent operator allows the use of concurrency in any other conventional operator.
             - For example addition:   `(+) x y  =  (+) <$> x <*> y`  so that  in the formula  a + b + c the three terms will be computed in parallel and the result will be computed concurrently.
Both operators <*> <|> can be combined to create arbitrary parallel and concurrent combinations.

The expression can become conventionally serial when the number of threads or a special flag is set. Also the parallelism can be controlled among the two limits of fully parallel and fully serial. Sometimes, for example, parsing need strict serial execution. In other cases excessive parallelization of trivial tasks could increase memory footprint and reduce performance instead of increasing it.


- How to serialize and deserialize the execution state necessary to respond to an event or network request
- How to move computations back and forth between different computers
- distributing computations between different computers, in a fully composable way
         r <- (a+b)* c       -- where a b and c run in different computers

- streaming as a default effect ever available, not as a distinct set of primitives
         r <- (a+b) *c      -- where a, b and c generate streams of values

- De-inversion of callbcks to make them composable
         r <-  (react onCallback + b) * c

- Fully composing multi-threaded code
         r <- (a+b)* c       -- where a b and c run in different threads

- homoiconic code in browser and server

- web widgets fully composable
       r <- (a+ b)* c                 -- where a, b and c are widgets activated by browser events

      