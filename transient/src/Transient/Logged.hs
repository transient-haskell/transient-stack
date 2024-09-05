 {-#Language OverloadedStrings, FlexibleContexts #-}
-----------------------------------------------------------------------------
--
-- Module      :  Transient.Logged
-- Copyright   :
-- License     :  MIT
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
-- 
--
-- Author: Alabado sea Dios que inspira todo lo bueno que hago. Porque Él es el que obra en mi
--
-- | The 'logged' primitive is used to save the results of the subcomputations
-- of a transient computation (including all its threads) in a  buffer.  The log
-- contains purely application level state, and is therefore independent of the
-- underlying machine architecture. The saved logs can be sent across the wire
-- to another machine and the computation can then be resumed on that machine.
-- We can also save the log to gather diagnostic information.
--

-----------------------------------------------------------------------------
{-# LANGUAGE  CPP, ExistentialQuantification, FlexibleInstances, ScopedTypeVariables, UndecidableInstances #-}
module Transient.Logged(
Loggable(..), logged, received, param, getLog, exec,wait, emptyLog,



Log(..), toPath,toPathLon,toPathFragment, getEnd, joinlog, dropFromIndex,recover, (<<), LogData(..),LogDataElem(..),  toLazyByteString, byteString, lazyByteString, Raw(..)
,hashExec) where

import Data.Typeable
import Data.Maybe
import Unsafe.Coerce
import Transient.Internals

import Transient.Indeterminism(choose)
import Transient.Parse
import Transient.Loggable

import Control.Applicative
import Control.Monad.State
import System.Directory
import Control.Exception
--import Control.Monad
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BSS
import qualified Data.Map as M
import Data.IORef
import System.IO.Unsafe
import GHC.Stack

import Data.ByteString.Builder



u= unsafePerformIO
exec=  LD [LX mempty] --byteString "e/"
wait=   byteString "w/"




instance Loggable LogData where
  serialize = toPath
  deserializePure s= Just (LD [LE  $ lazyByteString s],mempty)

-- instance Semigroup LogData where
--   (<>)= mappend
-- instance Monoid LogData where
--   mempty= LD mempty
--   LD [] `mappend` LD log= LD log
--   LD log `mappend` LD log' = 
--     case ((splitAt (length log -1) log),log') of
--       ((_,[LE _]),log') -> LD $ log ++ log' 

--       ((prev,[LX  (LD log'')]),LE log''':rest) -> LD $ prev ++ [LX $ LD(log''++[LE log'''])] <> rest
--       -- cuando los dos terminos tiene LX, se juntan
--       ((prev,[LX (log'')]),LX (log'''):rest) -> LD $ prev ++ [LX(log''<>log''')] <> rest

instance Semigroup LogData where
  (<>)= mappend
instance Monoid LogData where
  mempty= LD mempty
  LD [] `mappend` LD log= LD log
  LD log `mappend` LD log' =
    case (splitAt (length log -1) log) of
      (_,[LE _]) -> LD $ log ++ log'
      (prev,[LX  log'']) ->  LD $ prev ++ [LX (log'' <> LD log' )]


-- continue a chain at the innermost open branch of the first argument
LD [] `joinlog` LD log= LD log
LD log `joinlog` LD log' =
    case (splitAt (length log -1) log) of
      (_,[LE _]) -> LD $ log ++ log'

      (prev,[LX (LD [])]) ->LD $ prev ++ log'

      (prev,[LX  log'']) -> -- LD $ prev ++ [LX (log'' `joinlog` LD log' )]
         case log' of
                   [] -> LD log
                   (LE _ : _) -> LD $ prev ++ [LX (log'' `joinlog` LD log' )]

                   (LX log''':rest) -> LD $ prev ++ [LX (log'' `joinlog` log''')] <> rest



-- >>> getEnd $ LD [LX (LD [LX (LD [])])]


-- >>> getEnd $  LD  [LE $ e "hello/",LX [LE $ e "world/"] ]


--

-- >>> getEnd $   [LE $pack "hello/",LX [LE $ pack "world/",LE $ pack"rest/",LE $ pack"rest2/"] ]

--


-- >>>  toPath $ LD[LE $ pack "hi/"] <> exec <> exec << pack "world/" <<- pack "hello"
-- hi/e/hello
--

-- >>> toPath $ (LD[] <> exec << wait <<- pack "hello/" ) <> exec << wait <<- pack "world"
-- hello/world
--



-- >>> getEnd $  [LE $pack"hello/",LX [LE $ pack "world/"] ] <<- pack "world2/"
-- [3]
--


-- >>> getEnd                    $ LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "",e "N0/",LX (LD [LX (LD [LX (LD [e "N2/e/"])])])])]
-- [0,6,0,0,1]
--


-- >>> getLogFromIndex [0,6,0,0,1] $ LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "",e" N0/",LX (LD [LX (LD [LX (LD [e "N2/e/",e "()/",e "()/",e "()/",LX (LD [LX (LD [LX (LD [])])])])])])])]
-- ()/()/()/e/e/e/
--



e x= LE $ pack x
-- >>> getLogFromIndex  [0] $ LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "node",e "N0/",LX (LD [LX (LD [LX (LD [])])])])]
-- "e/f/w/w/h/nodeN0/e/e/e/"
--


-- >>> toPathFragment  $ dropFromIndex  [0] $ LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "node",e "N0/",LX (LD [LX (LD [LX (LD [])])])])]
-- "f/w/w/h/nodeN0/e/e/e/"
--

--

--- >>> dropLast $ LD[e "hello",LX $ LD[e "world2"]]
--- [LE "hello"]
---

--- >>> getLogFromIndex [1,1] $ LD[e "hello",LX $ LD[e "world2", e "1111/"],e "world3",e "WORLD4"]
--- "1111/WORLD4"
---

-- >>> toPathFragment  $ dropFromIndex [1,1] $ LD[e "hello",LX $ LD[e "world2", e "1111/"],e "world3",e "WORLD4"]
-- "1111/WORLD4"
--

-- >>> getLogFromIndex [1] $ LD [e "efw...",LX (LD [e "N4/",LX (LD [LX (LD [LX (LD [])])])])]
-- "e/N4/e/e/e/"

-- >>> toPath $ LD $ dropLast  $ LD [e "efw...",LX (LD [e "N4/",LX (LD [LX (LD [LX (LD [])])])])]
-- "efw..."
--

-- >>> toPath $ LD $ dropFromIndex [1] $ LD [e "efw...",LX (LD [e "N4/",LX (LD [LX (LD [LX (LD [])])])])]
-- "e/N4/e/e/e/"
--


-- >>> getLogFromIndex [0,6,0,0,1] $  LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "nodes/",e "N0/",LX (LD [LX (LD [LX (LD [e "e/N2/e/e/e/",e "()/",LX (LD [])])])])])]
-- "()/e/"
--


--



-- >>> toPathFragment  $ dropFromIndex [0,6,0,0,1] $  LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "nodes/",e "N0/",LX (LD [LX (LD [LX (LD [e "e/N2/e/e/e/",e "()/",LX (LD [])])])])])]
-- "()/e/"
--




-- >>> toPath $ LD [LX (LD [LX (LD [e "\"HELLO\"/"]),e "\"HELLO\"/",e "()/",LX (LD [])])]
-- "e/\"HELLO\"/()/e/"




--

getEnd ::  LogData -> [Int]
getEnd  (LD log)= let n= g [0] log in reverse n
  where
  g n []= n

  g  ns ((LX (LD []) ):[]) = 0:ns

  g  ns ((LX (LD rest) ):[]) = g (0:ns)  rest
  g  (n:ns) (_:rest) = g (n+1:ns) rest



dropFromIndex :: [Int] -> LogData -> [LogDataElem]
dropFromIndex [] (LD log)=  log



dropFromIndex (i:is) (LD log)=
  let dropi= drop i log
  in case dropi of
    []          -> mempty
    (LX log':t) -> if null is then LX log' : t

                        else LX (LD $ dropFromIndex is log')  :   t -- if null t then [] else tail t
    (LE x:_)    -> dropi --if toLazyByteString x== "w/"  then dropi else                   
                        --error $ "dropFormIndex: level too deep " ++ show (is) -- drop (length is) dropi  -- shoud be error


-- (!!>) a b = unsafePerformIO (print b) `seq` a

-- >>> dropFromIndex [1,0] $ LD [e "\"p\"/",e "()/",e "HELLO/",e "()/"]
-- [LE "HELLO/",LE "()/"]
--


-- >>> dropFromIndex [1,1] $ LD [e "\"p\"/",LX (LD [e "HI/",e "\"HO\"/"]),e "\"HO\"/",e "HELLO/",e "()/"]
-- [LE "\"HO\"/",LE "HELLO/",LE "()/"]
{- 
debe ser [[LE "\"HO\"/"],LE "HELLO/",LE "()/"]
necesario algo para preservar la estructura.

-}



-- shortest path
toPath (LD l)= toPathl l
toPathl :: [LogDataElem] -> Builder
toPathl  []  = mempty
toPathl (LE b:rest)= b <> toPathl rest
toPathl (LX (LD b):[])=  byteString "e/" <> toPathl  b
toPathl (LX _: b)= toPathl  b -- only get the result of the LX block which is b


-- remove the all "e/" before the first element
toPathFragment (LX (LD b):[])=   toPathFragment  b
toPathFragment (LX x:b)=toPathl b
toPathFragment x= toPathl $ tail x

-- longest path
toPathLon (LD x)= toPathlon' x
toPathlon' [] = mempty
toPathlon' (LE b:rest)= b <> toPathlon' rest

-- toPathlon' [(LX (LD [LE _]))]= byteString "e/" 

toPathlon' (LX x:[])= byteString "e/" <> toPathLon  x
toPathlon' (LX x: b)= byteString "e/" <> toPathLon  x  <> toPathlon' (tail b)



pack x=  byteString (BSS.pack x)

(<<) (LD[]) build =LD [LE build]
(<<) (LD log) build=  case splitAt (length log -1) log of

  (_,[LE _]) -> LD $ log ++ [LE build]
  (log',[LX log]) -> LD $ log'++[LX $ log << build]



(<<-) (LD[]) build = LD [LE build]
(<<-) (LD l) build=  case splitAt (length l -1) l of

  (_,[LE _]) -> LD $ l ++ [LE build]
  (log',[LX (LD [])]) ->  LD $ log'++[LE build]
  (log',[LX (LD log)]) -> case last log of
     LE _ -> LD $ l ++ [LE build]
     _       ->   LD $ log'++[LX $ (LD log) <<- build]


substwait (ld@(LD ldelm)) build = case  substwait1 ld build of -- fromJust $ substwait1 ld build
  Just r -> r
  Nothing ->  LD $ ldelm ++ [LE build]
  where
  substwait1 (LD[]) build =  Just $ LD [LE build]
  substwait1 (LD l) build=  case splitAt (length l -1) l of

    (prev,[LE x]) -> if  toLazyByteString x=="w/" then Just $ LD $ prev ++[LE build] else Nothing -- LD l <> LD [LE build]
    (prev,[LX (LD [])])  ->  Just $ LD $ prev++[LE build]
    (prev,[LX (LD log)]) -> let mr=  (LD log) `substwait1` build  --   LD $ log'++[LX $ (LD log) `substwait` build]
                            in case mr of
                              Nothing -> Just $ LD $ l ++ [LE build]
                              Just x  -> Just $ LD $ prev ++ [LX  x]



-- | Run the computation, write its result in a log in the state
-- and return the result. If the log already contains the result of this
-- computation ('restore'd from previous saved state) then that result is used
-- instead of running the computation again.
--
-- 'logged' can be used for computations inside a nother 'logged' computation. Once
-- the parent computation is finished its internal (subcomputation) logs are
-- discarded.
--

hashExec= 10000000
hashWait= 100000
hashDone= 1000




logged :: Loggable a => TransIO a -> TransIO a
logged mx = do

  -- indent
  debug <- getParseBuffer
  -- tr ("executing logged stmt of type",typeOf res,"with log",debug)

  -- mode <- gets execMode
  -- ttr ("execMode",mode)

  r <- res -- <** outdent

  -- tr ("finish logged stmt of type",typeOf res)
  

  return r
  where
  res = do
        log <- getLog

    -- if typeOf res == typeOf () then  (if recover log then return (unsafeCoerce ()) else unsafeCoerce mx)
    --   else do
        -- tr ("BUILD inicio", toPath $ partLog log)

        let full= partLog log
        rest <- getParseBuffer -- giveParseString
        -- ttr "after getparsebuffer"
        -- ttr ("parsebuffer", if BS.null rest then "NULL" else  BS.take 2 rest )
        let log'= if BS.null rest {-&& typeOf(type1 res) /= typeOf () -}then log{recover=False}  else log
        process rest full log'


    where
    -- fmx mx= tr ("executing logged stmt of type",typeOf mx) >> mx
    type1 :: TransIO a -> a
    type1 = undefined
    process rest full log= do

        -- tr ("process, recover",  recover log,partLog log)

        let fullexec=   full <> exec

        setData log{partLog= fullexec, hashClosure= hashClosure log + hashDone}
        r <-(if not $ BS.null rest
               then do  recoverIt
               else do   mx)  <** modifyData' (\log ->  log{partLog=partLog log <<- wait,hashClosure=hashClosure log + hashWait}) emptyLog

                            -- when   p1 <|> p2, to avoid the re-execution of p1 at the
                            -- recovery when p1 is asynchronous or  empty

        log' <- getLog

        let
            recoverAfter= recover log'
            add=   (serialize r <> byteString "/")   -- Var (toIDyn r):  full

        -- tr ("RECOVERAFTER",recover log,recover log')

        if BS.null rest && recoverAfter ==True  then do
            -- tr ("SUBLAST", "partLog log'",partLog log', "add", add,"sublast",substwait(partLog log')  add)
            setData $ Log{recover=False,partLog= substwait (partLog log')  add, hashClosure=hashClosure log + hashExec}

        else  do
            -- tr ("ADDLOG", "fulexec",fullexec,fullexec <<- add)  
            setData $ Log{recover=True, partLog= fullexec <<- add, hashClosure= hashClosure log +hashExec}


        return r


    recoverIt = do

        s <- giveParseString

        -- tr ("recoverIt recover", s)

        case BS.splitAt 2 s of
          ("e/",r) -> do
            -- tr "EXEC"
            setParseString r
            mx

          ("w/",r) -> do
            setParseString r
            modify $ \s -> s{execMode=if execMode s /= Remote then Parallel else Remote}  --setData Parallel 
            -- in recovery, execmode can not be parallel(NO; see below)
            empty                                --   !> "Wait"

          _ -> value

    value = r
      where
      typeOfr :: TransIO a -> a
      typeOfr _= undefined

      r= (do
        -- tr "VALUE"
        -- set serial for deserialization, restore execution mode
        x <- do mod <-gets execMode;modify $ \s -> s{execMode=Serial}; r <- deserialize; modify $ \s -> s{execMode= mod};return r  -- <|> errparse 
        tr ("value parsed",x)
        psr <- giveParseString
        when (not $ BS.null psr) $ (tChar '/' >> return ()) --  <|> errparse
        return x) <|> errparse
      errparse :: TransIO a
      errparse = do psr <- getParseBuffer;
                    stack <- liftIO currentCallStack
                    errorWithStackTrace  ("error parsing <" <> BS.unpack psr <> ">  to " <> show (typeOf $ typeOfr r) <> "\n" <> show stack)




-------- parsing the log for API's

received :: (Loggable a, Eq a) => a -> TransIO ()
received n= Transient.Internals.try $ do
   r <- param
   if r == n then  return () else empty

param :: (Loggable a, Typeable a) => TransIO a
param = r where
  r=  do
       let t = typeOf $ type1 r
       (Transient.Internals.try $ tChar '/'  >> return ())<|> return () --maybe there is a '/' to drop
       --(Transient.Internals.try $ tTakeWhile (/= '/') >>= liftIO . print >> empty) <|> return ()
       if      t == typeOf (undefined :: String)     then return . unsafeCoerce . BS.unpack =<< tTakeWhile' (/= '/')
       else if t == typeOf (undefined :: BS.ByteString) then return . unsafeCoerce =<< tTakeWhile' (/= '/')
       else if t == typeOf (undefined :: BSS.ByteString)  then return . unsafeCoerce . BS.toStrict =<< tTakeWhile' (/= '/')
       else deserialize  -- <* tChar '/'


       where
       type1  :: TransIO x ->  x
       type1 = undefined


{-
dejar como estaba. poner flag recovery cuando hay un setCont
Necesario un criterio para poner recover= False en un momento dado
no se puede usar recover=False. usar otro flag returnfromcont
problema de wait:
    hasta ahora al acabar mx se recuperaba solo el resultado:
           log <- getLog
           r <- mx <** wait
           log= log + serial r
    eso hace que todo alternativo tenga un wait añadido
    y toda secuencia se le quite el wait
    como quitar el wait en en la siguiente sentencia monadica
       tiene que funcionar dentro de logged y en transient monad
          distinguir logged en alternativo de monadico
          no se puede distinguir si <|> no lo dice

    trasladar logged a la monada cloud
    añadir un 

o poner un w y quitarlo en la siguiente orden de secuencia
o poner alternativo solo en <|> 
  meterno en alternative <|> de Cloud y meter logged en la cloud monad.
  meter fromCont= False en todo aplicativo y monadico

como deshabilitar el flag fromCont:
quitarlo para la siguiente sentencia monadica
 no se puede hacer al principio o baja el flag creado por setCont
 guardar el valor ejecutar sin formCont
     prev 0, after 0 -> 0
     0 1 -> 1   no tenia, pero hay un setCont en mx
     1 0 -> 1   viene de un setCont, pero no hay setcont en mx
     1 1 -> 1   
     0 0 -> 0

plan: hacer los ejemplos con local

flag pasó o no paso mx
si no paso poner w
si paso, nada

siguente logged puede ser ejecutado:
 en la siguente accion monadica: delData ha sido ejecutado
 alternativo al anterior: delData emptychek no ha sido ejecutado
 dentro del anterior:     delData emptychek no ha sido ejecutado

 como se distinguen los dos ultimos casos?
   flag exec

 flag alternativo 

if not fromCont poner <** wait
   pero a la vuelta puede ser necesario recojer lo producido porque ha habido un fromCont
   quitar el wait en esa posicion log ++ drop (length log +1) log'

al entrar mx  tiene un "e/" de ejecución, cuando acaba de procesar, se pone un "w/" preventivo por si entra en un <|> al final se le quita ambos y se pone el resultado.
Ahora: lo mismo al log generado por mx se le añade un w/ preventivo, y hay que quitar
 pero
    logged mx <|> logged my
    ...
    my tendría el w/ preventivo
    como se quita si retorna?
      hay que quitar el ultimo elemento nada mas.
-}
