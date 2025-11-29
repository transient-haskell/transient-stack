{-# LANGUAGE RankNTypes#-}
module Main where

newtype P a= P (IO a)

instance Functor P
instance Applicative P

instance Monad P where
   return  x=  P $ return x
   P p >>= q= P $ do
      putStr "(renderp "
      x <- p
      putStr ")"
      putStr "(renderq "
      let P y = q x
      r <- y
      putStr ")"
      return r

unP (P iox)= iox

main=do
      let P io=do
          P $ putStr "11111"
          P $ unP $ do   
               P (putStr "22222") 
               P (putStr "33333")
               P (putStr "44444")
               P (putStr "44422")

          P $ putStr "55555"
          P $ putStr "66666"

            
      io

putStrP x= P $ putStr x



newtype Cont a = Cont { unCont::  forall r. (a->r) ->r}

instance Applicative Cont

instance Monad Cont where 
   return a = Cont $ \c -> c a
   Cont m >>= f =  m f