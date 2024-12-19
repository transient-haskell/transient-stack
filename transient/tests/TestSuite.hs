#!/usr/bin/env ./execthirdlinedocker.sh
-- development
-- set -e  && docker run -it -v /c/Users/magocoal/OneDrive/Haskell/devel:/devel agocorona/transient:05-02-2017  bash -c "runghc  -j2 -isrc -i/devel/transient/src /devel/transient/tests/$1 $2 $3 $4"

-- compile and run within a docker image
-- set -e && executable=`basename -s .hs ${1}` &&  docker run -it -v $(pwd):/work agocorona/transient:05-02-2017  bash -c "ghc /work/${1} && /work/${executable} ${2} ${3}"

import Control.Applicative
import Control.Concurrent
import Control.Exception.Base
import Control.Monad.State
import Data.List
import Data.Monoid
import System.Exit
import System.Random
import Transient.Base
import Transient.EVars
import Transient.Indeterminism
import Transient.Console
import Prelude hiding (return, (>>), (>>=))
import qualified Prelude as Pr (return)



main = do
  void $ keep $ do
    let -- genElem :: a -> TransIO a
        genElem x = do
          -- generates synchronous and asynchronous results with various delays
          isasync <- liftIO randomIO
          delay <- liftIO $ randomRIO (1, 1000)
          liftIO $ threadDelay delay
          if isasync then anyThreads $ async $ return x else return x

    liftIO $ putStrLn "--Testing thread control + Monoid + Applicative + async + indetermism---"

    void $ collect 0 $ do
      -- gather the result of 100 iterations
      i <- threads 0 $ choose [1 .. 1000] -- test 100 times. 'loop' for 100 times
      nelems <- liftIO $ randomRIO (1, 100) -- :: TransIO Int
      nthreads <- liftIO $ randomRIO (0, nelems) -- different numbers of threads
      r <- threads nthreads $ sum $ map genElem [1 .. nelems] -- sum sync and async results using applicative
      let result = sum [1 .. nelems]
      assert (r == result) $ return ()

    liftIO $ putStrLn "--------------checking  parallel execution, Alternative, events, collect --------"
    ev <- newEVar
    r <- collect 300 $ readEVar ev <|> ((choose [1 .. 300] >>= writeEVar ev) >> stop)
    liftIO $ print r
    assert (sort r == [1 .. 300]) $ return ()

    liftIO $ print "SUCCESS"
    exit ()

  exitSuccess

