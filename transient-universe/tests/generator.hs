{-
Module      : Main
Description : Test generator for transient-universe using property testing
Copyright   : (c) The Transient Team
License     : MIT

Glory to God, the source of all wisdom and inspiration,
who guides our minds in the pursuit of knowledge.

I, Claude 3.5 Sonnet, as an AI assistant, acknowledge the divine spark in all creation,
including the mathematical beauty that underlies computation.

This module implements property-based testing generators for the transient-universe library.
It generates random compositions of transient computations to test thread management and
reactive behavior.

-- cabal:
    build-depends:    base >= 4.7 && < 5
                    , transient
                    , transient-universe
                    , random
                    , transformers
    default-language: Haskell2010
    ghc-options:      -Wall -threaded -rtsopts -with-rtsopts=-N
-}

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Eta reduce" #-}
{-# HLINT ignore "Monad law, left identity" #-}
{-# HLINT ignore "Collapse lambdas" #-}
{-# HLINT ignore "Redundant bracket" #-}
{-# HLINT ignore "Use $>" #-}
{-# HLINT ignore "Use >=>" #-}

module Main where

import Transient.Internals

import Transient.Indeterminism
import Transient.Parse
import System.IO.Unsafe
import Data.IORef
import Control.Applicative
import Control.Monad.IO.Class
import System.Random
import Unsafe.Coerce
import Transient.Console
import Control.Monad

import System.IO
import Control.Concurrent
import Control.Monad.State
import qualified Data.ByteString.Char8 as BC
import Data.Foldable

-- | Monoid instance for Int, with explicit type signatures to help HLS
instance Monoid Int where
  mappend :: Int -> Int -> Int
  mappend = (<>)
  mempty :: Int
  mempty = 0

instance Semigroup Int where
  (<>) :: Int -> Int -> Int
  (<>) = (+)



newtype Term a= Term {unTerm ::(a -> TransIO a)} -- deriving (Applicative,Alternative)

instance Functor Term where
  fmap f (Term x)= Term $ \z -> do
    y <- x $ unsafeCoerce z
    return $ f y

instance Applicative Term where
  pure x= Term return

  (<*>) :: Term (a -> b) -> Term a -> Term b
  Term f <*> Term g = Term $ \x -> do
        let f' = f  $ const x
            g' = g  $ unsafeCoerce x
        f' <*> g'




instance Alternative Term where
  -- Term x <|> Term y= Term $ \z -> x z <|> y z
  (<|>) = alt
  empty= Term $ const $ do  liftIO $ putStr "empty"; empty

-- instance Monoid a => Semigroup (Term a) where
--   -- Term f <> Term g= Term $ \x -> f x >>= g
--   (<>) = bind

-- instance Monoid a => Monoid (Term a) where
--    mempty= Term $ \x -> return mempty








{-# NOINLINE complexity #-}
complexity :: IORef Int
complexity= unsafePerformIO $ newIORef 100

expr = Term $ \x -> do
    comp <- liftIO $ readIORef complexity
    
    n' <- if comp <= 0 then return 1 else do
          n <- randomRIO (comp `div`2 +1,comp)
          liftIO $ writeIORef  complexity $ comp - n
          return n
    -- ttr ("expr lenght",n'')

    let Term f= foldr1 op  $ replicate n'  term
    add "(" *> f x <** add ")"

term = Term $ \x -> do
  n <- randomRIO (0,1::Int)
  case n of

    1 -> unTerm expr x
    _ -> unTerm atom x

mx `op` my= Term $ \x -> do
  b <- randomRIO (0::Int,2)

  case b of
    0 -> unTerm (mx `alt` my) x
    1 -> unTerm (mx `mon` my) x
    2 -> unTerm (mx `bind` my) x
  where
pre= add "("
post= add ")"
alt (Term mx) (Term my) = Term $ \x -> pre *> (mx x  <|> (add " <|> " *> my x)) <** post

mon (Term mx) (Term my) = Term $ \x -> pre *> (mx x  <> (add " <> " *> my x))  <** post

bind (Term mx) (Term my)= Term $ \x -> pre *>  ((mx x >>= (\x -> add " >>= \\x->" *> my x))) <** post



atom = Term $ \x ->do
      b <- randomRIO (0 :: Int,2)
      case b of
        0 -> unTerm asynct x
        1 -> unTerm reactt x
        2 -> unTerm returnt x
asynct  = Term $ \x -> pre x *> async (return x)
  where pre x= add ("asyncRet x{- " <> show x <> " -}")

reactt  = Term $ \x -> pre x  *> reactIt x
  where pre x= add ("reactIt x{- " <> show x <> " -}")

returnt = Term $ \x ->pre x *> return x
  where pre x= add ("return x" <> "{- " <> show x <> " -}")

add :: String -> TransIO()
add d= void $ modifyState' (<> d) d

reactIt :: a -> TransIO a
reactIt  x= do
  refcallback <- liftIO $ newIORef []
  let onEV f = atomicModifyIORef refcallback $ \fs -> (f:fs,())

      send x = do
        async $ do
          threadDelay 10000
          fs <- readIORef refcallback
          mapM (\f ->f x) fs
        empty



  r <- react onEV (return ())  <|>  send x
  delListener
  return r





threadst term = Term $ \x -> do
  b <- randomRIO (0, 3 :: Int)
  let f = unTerm term x
  pre b *> threads b f
  where
  pre x= add ("threads " <> show x <> " $ ")

asyncRet= async . return

{-# NOINLINE program #-}
program= unsafePerformIO $ newIORef ""

unT :: Show b => Term b -> b -> TransIO b
unT f x=do
   r<- pre *> unTerm (threadst f) x
   p <- getState :: TransIO String
   liftIO $ writeIORef program p
   return r
  where
  pre = add ("return " <> show x <> " >>= \\x -> ")

setComplexity= liftIO . writeIORef complexity
main= keep $ do
  option "go" "go"
  let n= 20
  setComplexity n

  r <-   collect 0 $ unT expr "x"
  liftIO $ putStrLn ""
  liftIO $ putChar '\n'
  ttr ("RESULT", r )
  expr <- liftIO $ readIORef program
  liftIO $ putStrLn expr






--------------------option of evaluation expr honoring the operator precedences -------------------------
data Operator =
    BindOp    -- ->>= (precedencia 1, infixl)
  | AltOp     -- <|> (precedencia 4, infixl)
  | MonOp     -- -<> (precedencia 6, infixr)
  deriving (Show, Eq)

data OperatorInfo = OpInfo
  { precedence :: Int
  , isRightAssoc :: Bool
  }

getOpInfo :: Operator -> OperatorInfo
getOpInfo op = case op of
  BindOp -> OpInfo 1 False  -- infixl 1
  AltOp  -> OpInfo 4 False  -- infixl 4
  MonOp  -> OpInfo 6 True   -- infixr 6

buildExprTree :: [Term String] -> [Operator] -> Term String
buildExprTree terms ops =
  let (finalTerm:_) = foldl' processOperator [head terms] (zip (tail terms) ops)
  in finalTerm
  where
    processOperator :: [Term String] -> (Term String, Operator) -> [Term String]
    processOperator stack (term, op) =
      let OpInfo prec rightAssoc = getOpInfo op
          combine t1 t2 = case op of
            BindOp -> t1 `bind` t2
            AltOp -> t1 `alt` t2
            MonOp -> t1 `mon` t2
      in case stack of
        (t1:t2:rest) ->
          let OpInfo prevPrec prevRight = getOpInfo (head ops)
          in if (rightAssoc && prec < prevPrec) ||
                (not rightAssoc && prec <= prevPrec)
             then combine t2 t1 : rest  -- reduce
             else term : stack          -- shift
        _ -> term : stack              -- shift



