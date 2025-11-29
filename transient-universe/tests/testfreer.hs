{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
module Console where

import Control.Monad.Freer
import Control.Monad.Freer.Error
import Control.Monad.Freer.State
import Control.Monad.Freer.Writer
import System.Exit hiding (ExitCode(ExitSuccess))

--------------------------------------------------------------------------------
                               -- Effect Model --
--------------------------------------------------------------------------------
data Console r where
  PutStrLn    :: String -> Console ()
  GetLine     :: Console String
  ExitSuccess :: Console ()

putStrLn' :: Member Console effs => String -> Eff effs ()
putStrLn' = send . PutStrLn

getLine' :: Member Console effs => Eff effs String
getLine' = send GetLine

exitSuccess' :: Member Console effs => Eff effs ()
exitSuccess' = send ExitSuccess

--------------------------------------------------------------------------------
                          -- Effectful Interpreter --
--------------------------------------------------------------------------------
runConsole :: Eff '[Console, IO] a -> IO a
runConsole = runM . interpretM (\case
  PutStrLn msg -> putStrLn msg
  GetLine -> getLine
  ExitSuccess -> exitSuccess)

--------------------------------------------------------------------------------
                             -- Pure Interpreter --
--------------------------------------------------------------------------------
runConsolePure :: [String] -> Eff '[Console] w -> [String]
runConsolePure inputs req = snd . fst $
    run (runWriter (runState inputs (runError (reinterpret3 go req))))
  where
    go :: Console v -> Eff '[Error (), State [String], Writer [String]] v
    go (PutStrLn msg) = tell [msg]
    go GetLine = get >>= \case
      [] -> error "not enough lines"
      (x:xs) -> put xs >> pure x
    go ExitSuccess = throwError ()


main=  print $ runConsolePure  ["hello"] $do
  r <-getLine'
  putStrLn' r