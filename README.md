This new repo contains all the transient libraries

A new release of transient with a lot of improvements to strenghten the execution model is coming.

## What is Transient?

One of the dreams of software engineering is unrestricted composability.

This may be put in these terms:

let `ap1` and `ap2` two applications with arbitrary complexity, with all effects including multiple threads, asynchronous IO, indeterminism, events and perhaps, distributed computing.

Then the combinations:

     - ap1 <|> ap2          -- Alternative expression
     - ap1 >>= \x -> ap2    -- monadic sequence
     - ap1 <> ap2           -- monoidal expression
     - (,) <$> ap1 <*> ap2  -- Applicative expression

are possible if the types match, and generate new applications that are composable as well.

Transient does exactly that.

The operators `<$>` `<*>` and `<>` express concurrency, the operator `<|>` express parallelism and `>>=` for sequencing of threads, distributed processes or web widgets. So even in the presence of these effects and others, everything is composable.

For this purpose transient is an extensible effects monad with all major effects and primitives for parallelism, events, asynchronous IO, early termination, non-determinism logging and distributed computing. Since it is possible to extend it with more effects without adding monad transformers, the composability is assured.

Motivating example
==================
This program, will stream "hello world"  from all the nodes connected if you enter "fire" in the console

```Haskell
main= keep $ initNode $ inputNodes <|> distribStream

distribStream= do
      local $ option "fire" "fire"
      r <- clustered . local . choose $ repeat "hello world"
      localIO $ print r
```
Read the tutorial to know how to compile and invoke it.

This program will present a link in the browser and stream fibonnacci numbers to the browser when
yo click it.  (if you have Docker, you can run it straigh from the console; See [this](https://github.com/transient-haskell/axiom#how-to-install--run-fast)

```Haskell
main= keep . initNode $ webFib

webFib= onBrowser $ do
    local . render $  wlink () (h1 "hello fibonacci numbers")

    r <-  atRemote $ do
                r <- local . threads 1 . choose $ take 10 fibs
                localIO $ print r
                localIO $ threadDelay 1000000
                return r

    local . render . rawHtml $ (h2 r)
    where
    fibs = 0 : 1 : zipWith (+) fibs (tail fibs) :: [Int]
```

This program combines both functionalities:

```haskell
main= keep . initNode $ inputNodes <|> webFib <|> distribStream
```

Documentation
=============

The [Wiki](https://github.com/agocorona/transient/wiki) is more user oriented

My video sessions in [livecoding.tv](https://www.livecoding.tv/agocorona/videos/) not intended as tutorials or presentations, but show some of the latest features running.

The articles are more technical:

- [Philosophy, async, parallelism, thread control, events, Session state](https://www.fpcomplete.com/user/agocorona/EDSL-for-hard-working-IT-programmers?show=tutorials)
- [Backtracking and undoing IO transactions](https://www.fpcomplete.com/user/agocorona/the-hardworking-programmer-ii-practical-backtracking-to-undo-actions?show=tutorials)
- [Non-deterministic list like processing, multithreading](https://www.fpcomplete.com/user/agocorona/beautiful-parallel-non-determinism-transient-effects-iii?show=tutorials)
- [Distributed computing](https://www.fpcomplete.com/user/agocorona/moving-haskell-processes-between-nodes-transient-effects-iv?show=tutorials)
- [Publish-Subscribe variables](https://www.schoolofhaskell.com/user/agocorona/publish-subscribe-variables-transient-effects-v)
- [Distributed streaming, map-reduce](https://www.schoolofhaskell.com/user/agocorona/estimation-of-using-distributed-computing-streaming-transient-effects-vi-1)

These articles contain executable examples (not now, since the site no longer support the execution of haskell snippets).


Plans
=====
Once composability in the large is possible, there are a infinite quantity of ideas that may be realized. There are short term and long term goals. An status of development is regularly published in [![Gitter](https://badges.gitter.im/theam/haskell-do.svg)](https://gitter.im/Transient-Transient-Universe-HPlay/Lobby?utm_source=share-link&utm_medium=link&utm_campaign=share-link).  

Among the most crazy ones is the possibility of extending this framework to other languages and make them interoperable. treating whole packaged applications as components, and docking them as lego pieces in a new layer of the Operating system where the shell allows such kind of type safe docking. this composable docker allows all kinds of composability, while the current docker platform is just a form of degraded monoid that do not compute.


Once you learn something interesting, you can [contribute to the wiki](https://github.com/transient-haskell/transient/wiki)

[You can also donate](https://agocorona.github.io/donation.html) 

