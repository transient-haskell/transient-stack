#!/usr/bin/env execthirdlinedocker.sh
--  info: use sed -i 's/\r//g' file if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- LIB="/projects/transient-stack" && runghc  -DDEBUG   -i${LIB}/transient/src -i${LIB}/transient-universe/src -i${LIB}/axiom/src   $1 ${2} ${3}

{-# LANGUAGE  ExistentialQuantification, CPP, OverloadedStrings,ScopedTypeVariables, DeriveDataTypeable, FlexibleInstances, UndecidableInstances #-}
{-# LANGUAGE MagicHash, UnboxedTuples #-}


import Transient.Internals 
import Transient.Console
import Transient.EVars
-- import Transient.Move.Logged
import Transient.Parse
import Transient.Indeterminism
import Data.Typeable
import Control.Applicative
import Data.Monoid hiding (Any)
import Data.List
import System.Directory
import System.IO
import System.IO.Error
import System.Random
import Control.Exception hiding (onException)
import qualified Control.Exception(onException)
import Control.Concurrent.MVar 
import Control.Monad.State
import Control.Concurrent 
import           System.IO.Error
import Debug.Trace

import qualified Data.ByteString.Char8 as BSS
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.ByteString.Builder
import Control.Monad.IO.Class
import System.Time
import Control.Monad
import Data.IORef
import Data.Maybe
import Data.String
import Data.Default
import Data.Char
import System.IO.Unsafe
import Unsafe.Coerce


import GHC.Exts
import GHC.IO


{-# language MagicHash #-}

import Data.IORef
import System.IO.Unsafe
import Control.Exception
import Control.Monad
import GHC.Exts

unique :: IORef Int
unique = unsafePerformIO $ newIORef 0
{-# noinline unique #-}

newTag :: IO Int
newTag = do
  t <- readIORef unique
  modifyIORef' unique (+1)
  pure t

data Tagged = Tagged !Int Any
instance Show Tagged where show = undefined
instance Exception Tagged

callCC :: ((a -> IO b) -> IO a) -> IO a
callCC f = do
  t <- newTag
  catch (f $ \a -> throwIO (Tagged t (unsafeCoerce# a)))
        (\e@(Tagged t' a) -> if t == t' then pure (unsafeCoerce# a) else throwIO e)

main :: IO ()
main = do
  x <- callCC $ \exit -> do
    b <- read <$> getLine
    when b $ do
      putStrLn "exit branch"
      exit 10
    putStrLn "pure branch"
    return 20
  print x

-- callCC :: ((a -> IO b) -> IO a) -> IO a
-- callCC f = IO $ \s0 ->
--  case newPromptTag# s0 of
--     (# s1, p #) ->
--       let
--         body s =
--           unIO (f k) s
--           where
--             k x = IO $ \s' ->
--               control0# p (\_ -> unIO (return x)) s'
--       in
--         prompt# p body s1
        

-- main :: IO String
-- main = do
--   r <- callCC $ \f -> do
--     putStrLn "Antes"
--     f "Salto inmediato"
--     putStrLn "Después"   -- nunca se ejecuta
--   print r

-- {-#NOINLINE reff#-}
-- reff= unsafePerformIO $ newIORef undefined
-- main1=  do
--   writeIORef reff (2*)
--   f2 <- readIORef reff
--   print $ ((coerce f2) 2 :: Int)



-- data Callback1= forall a.Call a -- Int -> IO (Maybe (),TranShip)

-- {-# NOINLINE rcallbacks1#-}
-- rcallbacks1 :: IORef (Callback1)
-- rcallbacks1 = unsafePerformIO $  newIORef undefined

-- addInternalCallbackData1 ::   Callback1 -> IO ()
-- addInternalCallbackData1    cb = do 
--   writeIORef rcallbacks1   cb 

-- main= keep empty :: IO (Either String ())

-- main1= keep' $ it <|>  callb 2
--   where 
--   it= do
--     r <- react1  
--     ttr (r :: Int)
  


--   callb (x)=  do
--     liftIO $ do
--        Call cb <-  readIORef rcallbacks1
--        (unsafeCoerce cb) x
--        ttr "after1"
--     empty
--     -- where
--     -- cast f= unsafeCoerce f `asTypeOf` typ x
--     -- typ:: a -> a -> IO (Maybe(),TranShip)
--     -- typ= error "typ: type level"

  

-- react1  = Transient $ do

--         cont <- get

--         let callback dat = do
--               ttr "callbackreact1"
            
--               runContIO dat  cont  
--         liftIO $ addInternalCallbackData1  $  Call   callback


--         return Nothing