{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE RecordWildCards        #-}

module GHCJS.HPlay.View(
    Widget(..)
  -- * Running it
  , module Transient.Move.Utils
  , runBody, runWidget, runWidget'
  , addHeader
  , render,render1
  -- * Widget Combinators and Modifiers
  , (<<)
  , (<<<)
  , (<!)
  , (<++)
  , (++>)
  , validate
  , wcallback
  , redraw
  -- * Basic Widgets
  , option
  , wprint
  , getString
  , inputString
  , getInteger
  , inputInteger
  , getInt
  , inputInt
  , inputFloat
  , inputDouble
  , getPassword
  , inputPassword
  , setRadio
  , setRadioActive
  , getRadio
  , setCheckBox
  , getCheckBoxes
  , getTextBox
  , getMultilineText
  , textArea
  , getBool
  , getSelect
  , setOption
  , setSelectedOption
  , wlabel
  , resetButton
  , inputReset
  , submitButton
  , inputSubmit
  , wbutton
  , wlink
  , staticNav
  , noWidget
  , wraw
  , rawHtml
  , isEmpty
  -- * Events
  , BrowserEvent(..)
  -- * Out of Flow Updates
  , UpdateMethod(..)
  , setRenderTag
  , at, at'
  -- * Reactive and Events
  , IsEvent(..)
  , EventData(..)
  , EvData(..)
  , resetEventData
  , getEventData
  , setEventData
  , raiseEvent
  , fire
  , wake
  , pass
  -- * utility
  , clearScreen 
  -- * Low-level and Internals
  , ElemID
  , getNextId
  , genNewId
  , continuePerch
  , getParam
  , getCont
  , runCont
  , elemById
  , withElem
  , getProp
  , setProp
  , alert
  , fromJSString
  , toJSString
  , getValue
  --m* events
  , keyCode,buttonMouse, clientX,clientY,pageX,pageY
  -- * Re-exported
  , module Control.Applicative
  , module GHCJS.Perch  
  -- remove
  ,CheckBoxes(..)
  ,JSString,pack, unpack
  ,RadioId(..), Radio(..)


)  where


import           Transient.Internals     hiding (input, option, parent)
import           Transient.Move.Logged hiding ((<<))
import           Transient.Move.Utils
import qualified Prelude(id,span,div)
#ifndef ghcjs_HOST_OS
import           Transient.Parse hiding(parseString)
import           Data.Char(isSpace)
import           System.Directory
import           System.IO.Error
import           Data.List(elemIndices)
import           Control.Exception hiding (try)
import qualified Data.ByteString.Lazy.Char8 as BS
#endif

import           Control.Monad.State
-- import qualified Data.Map                as M

import           Control.Applicative
import           Control.Concurrent
import           Data.Dynamic

import           Data.Maybe
import           Data.Monoid
import           Data.Typeable
import           Prelude                 hiding (id,span,div)
import           System.IO.Unsafe
import           Unsafe.Coerce

import           Data.IORef


#ifdef ghcjs_HOST_OS

import           GHCJS.Foreign
import           GHCJS.Foreign.Callback
import           GHCJS.Foreign.Callback.Internal (Callback(..))
import           GHCJS.Marshal

import           GHCJS.Perch             hiding (JsEvent (..), eventName, option,head,map,tr)
import           GHCJS.Types
import           Transient.Move          hiding (pack)

import qualified Data.JSString           as JS hiding (empty, center,span, strip,foldr,head)
import           Data.JSString (pack,unpack,toLower)
#else
import           Data.List as JS         hiding (span)
import           GHCJS.Perch             hiding (JSVal, JsEvent (..), eventName, option,head, map,tr)
import           Transient.Move          
#endif

#ifndef ghcjs_HOST_OS
type JSString = String
#else
instance Loggable JSString
#endif

toJSString :: (Show a, Typeable a) => a -> JSString
toJSString x =
  if typeOf x == typeOf (ofType :: String )
  then pack $ unsafeCoerce x
  else pack$ show x

fromJSString :: (Typeable a,Read a) => JSString -> a
fromJSString s = x
   where
     x | typeOf x == typeOf (ofType :: JSString) =
         unsafeCoerce x            --  !> "unsafecoerce"
       | typeOf x == typeOf (ofType :: String) =
         unsafeCoerce $ pack$ unsafeCoerce x            -- !!> "packcoerce"
       | otherwise = read $ unpack s            -- !> "readunpack"

getValue :: MonadIO m => Elem -> m (Maybe String)

getName :: MonadIO m => Elem -> m (Maybe String)
#ifdef ghcjs_HOST_OS
getValue e = liftIO $ do
   s <- getValueDOM e
   fromJSVal s -- return $ JS.unpack s

getName e = liftIO $ do
   s <- getNameDOM e
   fromJSVal s
#else
getValue = undefined
getName = undefined
#endif

elemBySeq :: (MonadState TranShip m, MonadIO m) => JSString -> m (Maybe Elem)
#ifdef ghcjs_HOST_OS
elemBySeq id = do
  mid <- getData
  case mid of
    Nothing -> return Nothing
    Just (IdLine _ id1)  -> do
      -- alert ("elemBySeq",id1, id)
      liftIO $ do
          let id2= JS.takeWhile (/='p') id
          re <- elemBySeqDOM id1 id2
          fromJSVal re
#else
elemBySeq _ = return Nothing
#endif

#ifdef ghcjs_HOST_OS
attribute :: (MonadIO m)  => Elem -> JSString -> m (Maybe JSString)
attribute elem prop=  liftIO $ do
    rv <- attributeDOM elem "id"
    fromJSVal rv
#else
attribute _ = return Nothing
#endif

elemById :: MonadIO m  => JSString -> m (Maybe Elem)
#ifdef ghcjs_HOST_OS
elemById id= liftIO $ do
   re <- elemByIdDOM id
   fromJSVal re
#else
elemById _= return Nothing
#endif

withElem :: ElemID -> (Elem -> IO a) -> IO a
withElem id f= do
  me <- elemById id
  case me of
     Nothing -> error ("withElem: not found"++ fromJSString id)
     Just e -> f e

--data NeedForm= HasForm | HasElems  | NoElems deriving Show


type ElemID= JSString
newtype Widget a=  Widget{ norender :: TransIO a} deriving(MonadIO, Applicative, Alternative, MonadState TranShip,Num)


  

instance Monad Widget where
  return x=  Widget $ return x
  x >>= f = Widget $ Transient $ do
       id1 <- genNewId
       setEventContW x  f id1
       delData noHtml
       mk <- runView x
       form1 <- getData `onNothing` return noHtml
       resetEventCont mk
       case mk of
         Just k  -> do
            delData noHtml
            mk <- runView $ f k
            form2 <- getData `onNothing` return noHtml
            setData $ form1 <> (span ! id id1 $ form2)
            return mk
         Nothing -> do
            setData  $ form1 <> (span ! id id1 $ noHtml)
            return Nothing



setEventContW :: Widget a -> (a -> Widget b) -> JSString -> StateIO ()
setEventContW  x f id = modify $ \TranShip {mfSequence = seq, fcomp = fs, .. }
                           -> TranShip {mfSequence = seq
                                     , fcomp = unsafeCoerce (rend f id) :  fs
                                     , .. }   !> "setEventContW"
      where
      rend f id x= tr "rend" >> runWidgetId ( f x) id

      strip seq x=  Transient $ do
        alert "strip"
        -- seq' <- gets mfSequence
        -- modify $ \ s -> s{mfSequence = seq}
        
        r <- runView x
        -- modify $ \ s -> s{mfSequence = seq'}

        delData noHtml
        return r

-- instance Monad Widget where
--   return x=  Widget $ return x
--   x >>= f = Widget $ Transient $ do
--        id1 <- genNewId
--        setEventContW x  f id1
--        delData noHtml
--        mk <- runView x
--        form1 <- getData `onNothing` return noHtml
--        resetEventCont mk
--        let form1' = form1 <> (span ! id id1 $ noHtml)

--        case mk of
--          Just k  -> do
--             delData noHtml
--             setData $ IdLine 0 id1

--             mk <- runView $ f k
--             form2 <- getData `onNothing` return noHtml
--             setData $ form1' <> (span1  id1  form2)
--             return mk
--          Nothing -> do
--             setData form1'
--             return Nothing

render1 :: Widget a -> TransIO a
render1 w= do
  Transient $ do
    IdLine _ id1 <- getData `onNothing` error "render: no id"
    prevRend <- getData `onNothing` return noHtml
    delData noHtml
    
    mx <- runView w
    mexecEvent  <- getData
    if (mexecEvent== Just ExecEvent) 
      then do
         meid1 <- liftIO $ elemById id1
         liftIO $ clearChildren $ fromJust meid1
         delData ExecEvent
         delData noHtml
      else do
        rend <- getData `onNothing` return noHtml
        id2 <- genNewId
        setData $ IdLine 0 id2
        setData $ prevRend <> (span1 id1 $ rend)

    return mx
    
span1 id1 rend= Perch $ \e -> do
        parent <- liftIO $ elemById id1 `onNothing` error ("not found "++ show id1)
        build rend  parent
       
     


-- resetEventContW mx  =
--    modify $ \TranShip { fcomp = fs, .. }
--           -> TranShip { xcomp = case mx of
--                         Nothing -> empty
--                         Just x  -> unsafeCoerce (head fs) x
--                     , fcomp = tailsafe fs
--                     , .. }

-- ins  tance Monad Widget where
--   return x=  Widget $ return x
--   Widget w >>= w' = Widget  $ do
--     id1 <- genNewId
--     -- prevr <-  getState <|> return noHtml
--     delData noHtml
    
--     x <-  w  <*** do
--             meid <- liftIO $ elemById id1 
--             if isNothing meid
--               then do
--                 rend <- getState <|> return noHtml  
--                 setState $ rend <> (span ! id id1 $ noHtml)
--               else do
--                 liftIO $ clearChildren $ fromJust meid
--                 me :: Maybe ExecRender <- getData
--                 when (isJust me) $ do
--                    delData ExecEvent
--                    delData noHtml --setData prevr 
--     let Widget wy = w' x
 
--     rend <-  getState <|> return noHtml

--     delData noHtml
--     wy <*** do
         
--           rend' <-  getState <|> return noHtml

--           setState $ rend <> (span1 id1 $ rend')
--     where
    
--     span1 id1 rend= Perch $ \e -> do
--       parent <- liftIO $ elemById id1 `onNothing` error ("not found "++ show id1)
--       build rend  parent
{-
si build online, necesitamos meter id1 en setState
si esta lleno con algo id1,
-}


instance Functor Widget where
  fmap f mx=   Widget. Transient $ fmap (fmap f) . runTrans $ norender mx



-- instance Applicative Widget where
--   pure= return

--   Widget (Transient x) <*> Widget (Transient y) = Widget . Transient $ do
--         getData `onNothing` do 
--             cont <- get
--             let al= Alternative cont
--             setData $ Alternative cont
--             return al
--         mx <- x
--         my <- y
--         return $ mx <*> my



instance Monoid a => Monoid (Widget a) where
  mempty= return mempty

#if MIN_VERSION_base(4,11,0) 
  mappend= (<>)

instance (Monoid a) => Semigroup (Widget a) where
  (<>)=  mappendw
#else
  mappend= mappendw
#endif  
  
mappendw x y=  (<>) <$> x  <*> y

instance AdditionalOperators Widget where

    -- Widget (Transient x) <** Widget (Transient y)= Widget . Transient $ do
    --             getData `onNothing` do 
    --               cont <- get
    --               let al= Alternative cont
    --               setData $ Alternative cont
    --               return al
                 
    --             mx <- x
    --             y
    --             return mx
    (<**) x y= Widget $  norender x <** norender y

    (<***) x y= Widget $  norender x <*** norender y

    (**>)  x y= Widget $  norender x **>  norender y



runView :: Widget a -> StateIO (Maybe a)
runView  = runTrans . norender

-- | It is a callback in the view monad. The rendering of the second parameter substitutes the rendering
-- of the first paramenter when the latter validates without afecting the rendering of other widgets.
wcallback :: Widget a -> (a ->Widget b) -> Widget b

wcallback (Widget x) f= Widget $ do
  --nid <-  genNewId
  IdLine _ nid <-  getState <|>  do
                    id1 <- genNewId                                -- !> "ONNOTHING"
                    top <- liftIO getBody
                    liftIO $ build (span ! id id1 $ noHtml) top
                    return $ IdLine 0 id1
  let nidid=  "#" <> nid

  r <-  x
  delData noHtml
  delData ExecEvent
  liftIO $ withElem nid $ build clear 
  setState $ IdLine 0 nid
  render $ f r


-- | execute a widget but redraw itself too when some event happens.
-- The first parameter is the path of the DOM element that hold the widget, used by `at`

redraw :: JSString -> Widget a -> TransIO a
redraw idelem w=  do
   path <- getState <|> return ( Path [])
   r <- render $ at idelem Insert  w
   setState path
   redraw  idelem w   <|> return r



{-
instance Monoid view => MonadTrans (View view) where
  lift f = Transient $  (lift  f) >>= \x ->  returnFormElm mempty $ Just x
-}

type Name= JSString
type Type= JSString
type Value= JSString
type Checked= Bool
type OnClick1= Maybe JSString


-- | Minimal interface for defining the basic form and link elements. The core of MFlow is agnostic
-- about the rendering package used. Every formatting (either HTML or not) used with MFlow must have an
-- instance of this class.
-- See "MFlow.Forms.Blaze.Html for the instance for blaze-html" "MFlow.Forms.XHtml" for the instance
-- for @Text.XHtml@ and MFlow.Forms.HSP for the instance for Haskell Server Pages.
-- class (Monoid view,Typeable view)   => FormInput view where
--     fromStr :: JSString -> view
--     fromStrNoEncode :: String -> view
--     ftag :: JSString -> view  -> view
--     inred   :: view -> view
--     flink ::  JSString -> view -> view
--     flink1:: JSString -> view
--     flink1 verb = flink verb (fromStr verb)
--     finput :: Name -> Type -> Value -> Checked -> OnClick1 -> view
--     ftextarea :: JSString -> JSString -> view
--     fselect :: JSString -> view -> view
--     foption :: JSString -> view -> Bool -> view
--     foption1 :: JSString -> Bool -> view
--     foption1   val msel= foption val (fromStr val) msel
--     formAction  :: JSString -> JSString -> view -> view
--     attrs :: view -> Attribs -> view

type Attribs= [(JSString, JSString)]


data ParamResult v a= NoParam | NotValidated String v | Validated a deriving (Read, Show)

valToMaybe (Validated x)= Just x
valToMaybe _= Nothing

isValidated (Validated x)= True
isValidated _= False

fromValidated (Validated x)= x
fromValidated NoParam= error "fromValidated : NoParam"
fromValidated (NotValidated s err)= error $ "fromValidated: NotValidated "++ s

getParam1 :: ( Typeable a, Read a, Show a)
          => Bool -> JSString ->  StateIO (ParamResult Perch a)
getParam1 exact  par = do
  --  alert (exact,par)

       tr "GETPARAM"

       me <- if exact then elemById par else elemBySeq par
                                                !> ("looking for " ++ show par)
       case me of
         Nothing -> return  NoParam
         Just e ->  do
            v <- getValue e                       -- !!> ("exist" ++ show par)
            readParam v                           -- !!> ("getParam for "++ show v)


type Params= Attribs



readParam :: (Typeable a, Read a)=> Maybe String -> StateIO (ParamResult Perch a)
readParam Nothing = return NoParam
readParam (Just x1) = r
 where
 r= maybeRead x1

 getType ::  m (ParamResult v a) -> a
 getType= undefined
 x= getType r

 maybeRead str= do
   let typeofx = typeOf x
   if typeofx == typeOf  ( ofType :: String)     then
           return . Validated $ unsafeCoerce str            -- !!> ("maybread string " ++ str)
   else if typeofx == typeOf(ofType :: JSString) then
           return . Validated $ unsafeCoerce $ pack  str
   else case reads $ str  of          --            -- !!> ("read " ++ str) of
              [(x,"")] ->  return $ Validated x            -- !!> ("readsprec" ++ show x)
              _ -> do
                   let err= inred $ "can't read \"" ++ str ++ "\" as type " ++  show (typeOf x)
                   return $ NotValidated str err



-- | Validates a form or widget result against a validating procedure
--
-- @getOdd= getInt Nothing `validate` (\x -> return $ if mod x 2==0 then  Nothing else Just "only odd numbers, please")@
validate
  :: Widget a
     -> (a -> StateIO  (Maybe Perch))
     -> Widget a
validate  w val=  do
   idn <- Widget $ Transient $ Just <$> genNewId
   rawHtml $ span ! id idn $ noHtml
   x <-  w
   Widget $ Transient $ do
          me <- val x
          case me of
             Just str -> do
                  liftIO $ withElem idn $ build $ clear >> (inred  str)
                  return Nothing
             Nothing  -> do
                  liftIO $ withElem idn $ build clear
                  return $ Just x




-- | Generate a new string. Useful for creating tag identifiers and other attributes.
--
-- if the page is refreshed, the identifiers generated are the same.


{-#NOINLINE rprefix #-}
rprefix= unsafePerformIO $ newIORef 0
#ifdef ghcjs_HOST_OS
genNewId ::  (MonadState TranShip m, MonadIO m) => m  JSString
genNewId=  do
      -- r <- liftIO $ atomicModifyIORef rprefix (\n -> (n+1,n))
      n <- genId
      alert ("nid",n)
      let nid= toJSString $  ('n':show n) -- ++ ('p':show r)
      nid `seq` return  nid

-- getCurrentId= do
--       n <- gets mfSequence
--       let nid= toJSString $  ('n':show (n-1))
--       return nid
#else
genNewId ::  (MonadState TranShip m, MonadIO m) => m  JSString
genNewId= return $ pack ""

--getPrev ::  StateIO  JSString
--getPrev= return $ pack ""
#endif



-- | get the next ideitifier that will be created by genNewId
getNextId :: MonadState TranShip  m  =>  m JSString
getNextId=  do
      n <- gets mfSequence

      return $ toJSString $ 'p':show n


-- | Display a text box and return a non empty String
getString  ::  Maybe String -> Widget String
getString = getTextBox
--     `validate`
--     \s -> if Prelude.null s then return (Just $ fromStr "")
--                    else return Nothing

inputString  :: Maybe String -> Widget String
inputString= getString

-- | Display a text box and return an Integer (if the value entered is not an Integer, fails the validation)
getInteger :: Maybe Integer -> Widget  Integer
getInteger =  getTextBox

inputInteger ::  Maybe Integer -> Widget  Integer
inputInteger= getInteger

-- | Display a text box and return a Int (if the value entered is not an Int, fails the validation)
getInt :: Maybe Int -> Widget Int
getInt =  getTextBox

inputInt :: Maybe Int -> Widget Int
inputInt =  getInt

inputFloat :: Maybe Float -> Widget Float
inputFloat =  getTextBox

inputDouble :: Maybe Double -> Widget Double
inputDouble =  getTextBox

-- | Display a password box
getPassword :: Widget String
getPassword = getParam Nothing "password" Nothing

inputPassword ::   Widget String
inputPassword= getPassword

newtype Radio a= Radio a

data RadioId= RadioId JSString deriving Typeable

-- | Implement a radio button
setRadio :: (Typeable a, Eq a, Show a,Read a) =>
            Bool -> a ->  Widget  (Radio a)
setRadio ch v = Widget $ Transient $ do
  RadioId name <- getData `onNothing` error "setRadio out of getRadio"
  id <- genNewId
  me <- elemBySeq id  
  checked <-  case me  of
      Nothing -> return ""
      Just e  -> liftIO $ getProp e "checked"
  
  let str = if typeOf v == typeOf(ofType :: String)
                   then unsafeCoerce v else show v
  addSData
      ( finput id "radio" (toJSString str)  ch Nothing `attrs` [("name",name)] :: Perch)
  
  if  checked == "true"  then Just . Radio . read1 . unpack <$> liftIO (getProp (fromJust me) "value") else return Nothing
  where 
  read1 x=r 
    where
    r= if typeOf r== typeOf (ofType :: String) then unsafeCoerce x 
          else read x 

setRadioActive :: (Typeable a, Eq a, Show a,Read a) =>
                   Bool -> a -> Widget (Radio a)
setRadioActive ch rs = setRadio ch rs `raiseEvent` OnClick


-- | encloses a set of Radio boxes. Return the option selected
getRadio
   ::  [Widget (Radio a)] -> Widget a
getRadio ws =  do
  id <- genNewId
  setData $ RadioId id
  Radio x <- foldr (<|>) empty ws <*** delData (RadioId id)
  return x


newtype CheckBoxes a= CheckBoxes [a] 

instance Monoid a => Monoid (CheckBoxes a) where
  mempty= CheckBoxes []

#if MIN_VERSION_base(4,11,0) 
  mappend= (<>)

instance (Monoid a) => Semigroup (CheckBoxes a) where
  (<>)=  mappendch
#else
  mappend= mappendch
#endif  
  
mappendch (CheckBoxes x) (CheckBoxes y)=  CheckBoxes (x ++ y)


-- | present a checkbox
setCheckBox :: (Typeable a , Show a) =>
                Bool -> a -> Widget  (CheckBoxes a)
setCheckBox checked' v= Widget . Transient $ do
  n  <- genNewId
  me <- elemBySeq n
  let showv= toJSString (if typeOf v == typeOf (ofType :: String)
                             then unsafeCoerce v
                             else show v)

  addSData $  ( finput n "checkbox" showv  checked' Nothing :: Perch)

  case me of
       Nothing -> return Nothing
       Just e -> do
            checked <- liftIO $ getProp e "checked"
            return . Just . CheckBoxes $ if  checked=="true"  then [v] else []

-- Read the checkboxes
getCheckBoxes ::  Show a => Widget  (CheckBoxes a) ->  Widget  [a]
getCheckBoxes w =  do
  CheckBoxes rs <-  w
  return rs
 

whidden :: (Read a, Show a, Typeable a) => a -> Widget a
whidden x= res where
 res= Widget . Transient $ do
    n <- getData `onNothing` error "no event id" -- genNewId
    let showx= case cast x of
                Just x' -> x'
                Nothing -> show x
    r <- getParam1 True n  `asTypeOf` typef res
    addSData (finput n "hidden" (toJSString showx) False Nothing :: Perch)
    return (valToMaybe r)
    where
    typef :: Widget a -> StateIO (ParamResult Perch a)
    typef = undefined




getTextBox
  :: (Typeable a,
      Show a,
      Read a) =>
     Maybe a ->  Widget a
getTextBox ms  = getParam Nothing "text" ms


getParam
  :: (Typeable a,
      Show a,
      Read a) =>
      Maybe JSString -> JSString -> Maybe a -> Widget  a
getParam look type1 mvalue= Widget . Transient $ getParamS look type1 mvalue

getParamS look type1 mvalue= do
    tolook <- case look of
       Nothing  -> genNewId -- getData `onNothing` error "no event id" -- genNewId
       Just n -> return n
    alert tolook
    let nvalue x =  case x of
          Nothing -> mempty
          Just v  ->
              if (typeOf v== typeOf (ofType :: String)) then  pack(unsafeCoerce v)
              else if typeOf v== typeOf (ofType :: JSString) then unsafeCoerce v
              else toJSString $ show v             -- !!> "show"

    -- setData HasElems
    r <- getParam1 True tolook
    case r of
       Validated x        -> do addSData (finput tolook type1 (nvalue $ Just x) False Nothing :: Perch) ; return $ Just x            -- !!> "validated"
       NotValidated s err -> do addSData (finput tolook type1  (toJSString s) False Nothing <> err :: Perch); return Nothing
       NoParam            -> do modify $ \s -> s{execMode=Parallel};addSData (finput tolook type1 (nvalue mvalue) False Nothing :: Perch); return  Nothing




-- | Display a multiline text box and return its content
getMultilineText :: JSString
                 -> Widget String
getMultilineText nvalue =  res where
 res= Widget. Transient $ do
    tolook <- getData `onNothing` error "no event id" -- genNewId   !>  "GETMULTI"
    r <- getParam1 True tolook  `asTypeOf` typef res
    case r of
       Validated x        -> do addSData (ftextarea tolook  $ toJSString x :: Perch); return $ Just x     -- !> "VALIDATED"
       NotValidated s err -> do addSData (ftextarea tolook   (toJSString s) :: Perch); return  Nothing    -- !> "NOTVALIDATED"
       NoParam            -> do modify $ \s -> s{execMode=Parallel};addSData (ftextarea tolook  nvalue :: Perch); return  Nothing  -- !> "NOTHING"
    where
    typef :: Widget String -> StateIO (ParamResult Perch String)
    typef = undefined

-- | A synonim of getMultilineText
textArea ::  JSString ->Widget String
textArea= getMultilineText



getBool :: Bool -> String -> String -> Widget Bool
getBool mv truestr falsestr= do
   r <- getSelect $   setOption truestr (fromStr $ toJSString truestr)  <! (if mv then [("selected","true")] else [])
                  <|> setOption falsestr(fromStr $ toJSString falsestr) <! if not mv then [("selected","true")] else []
   if  r == truestr  then return True else return False



-- | Display a dropdown box with the options in the first parameter is optionally selected
-- . It returns the selected option.
getSelect :: (Typeable a, Read a,Show a) =>
      Widget (MFOption a) ->  Widget  a
getSelect opts = res where
  res= Widget . Transient $ do
    tolook <- getData `onNothing` error "no event id"  -- genNewId
    -- st <- get
--    setData HasElems
    r <- getParam1 True tolook `asTypeOf` typef res
--    setData $ fmap MFOption $ valToMaybe r
    runView $ fselect tolook <<< opts
--
    return $ valToMaybe r

    where
    typef :: Widget a -> StateIO (ParamResult Perch a)
    typef = undefined


newtype MFOption a = MFOption a deriving Typeable

instance Monoid a => Monoid (MFOption a) where
  mempty= MFOption mempty

#if MIN_VERSION_base(4,11,0) 
  mappend= (<>)

instance (Monoid a) => Semigroup (MFOption a) where
  (<>)=  mappendop
#else
  mappend= mappendop
#endif  
  
mappendop (MFOption x) (MFOption y)=  MFOption (x <> y)

-- | Set the option for getSelect. Options are concatenated with `<|>`
setOption
  :: (Show a, Eq a, Typeable a) =>
     a -> Perch -> Widget (MFOption a)
setOption n v = setOption1 n v False


-- | Set the selected option for getSelect. Options are concatenated with `<|>`
setSelectedOption
  :: (Show a, Eq a, Typeable a) =>
     a -> Perch -> Widget (MFOption a)
setSelectedOption n v= setOption1 n v True


setOption1 :: (Typeable a, Eq a, Show a) =>
      a -> Perch -> Bool ->  Widget  (MFOption a)
setOption1 nam  val check= Widget . Transient $ do
    let n = if typeOf nam == typeOf(ofType :: String)
                   then unsafeCoerce nam
                   else show nam

    addSData (foption (toJSString n) val check)

    return  Nothing -- (Just $ MFOption nam)


wlabel:: Perch -> Widget a -> Widget a
wlabel str w = Widget . Transient $ do
   id <- getNextId
   runView $ (ftag "label" str `attrs` [("for",id)] :: Perch) ++> w



-- passive reset button.
resetButton :: JSString -> Widget ()
resetButton label= Widget . Transient $ do
   addSData  (finput  "reset" "reset" label False Nothing :: Perch)
   return $ Just ()

inputReset :: JSString -> Widget ()
inputReset= resetButton

-- passive submit button. Submit a form, but it is not trigger any event.
-- Unless you attach it with `raiseEvent`
submitButton ::  (Read a, Show a, Typeable a) => a -> Widget a
submitButton label=  getParam Nothing "submit" $ Just label


inputSubmit ::  (Read a, Show a, Typeable a) => a -> Widget a
inputSubmit= submitButton

-- | active button. When clicked, return the first parameter
wbutton :: a -> JSString -> Widget a
wbutton x label= Widget $ Transient $ do
     idn <- genNewId
     runView $ do
        input  ! atr "type" "submit" ! id   idn ! atr "value" label `pass` OnClick
        return x
      `continuePerch`  idn


clearScreen=  local  $ do
   render . wraw $ forElems "body" $ this  >> clear `child` (div ! atr "id" "body1" $ noHtml)
   setRenderTag "body1"


-- | when creating a complex widget with many tags, this call indentifies which tag will receive the attributes of the (!) operator.
continuePerch :: Widget a -> ElemID -> Widget a
continuePerch w eid=   c <<< w
      where
      c f =Perch $ \e' ->  do
         build f e'
         elemid eid

      elemid id= elemById id >>=  return . fromJust

--      child  e = do
--             jsval <- firstChild e
--             fromJSValUnchecked jsval

rReadIndexPath= unsafePerformIO $ newIORef 0

-- | Present a link. It return the first parameter and execute the continuation when it is clicked.
--
-- It also update the path in the URL.
wlink :: (Show a, Typeable a) => a -> Perch -> Widget a
#ifdef ghcjs_HOST_OS
wlink x v=  do
    (a ! href "#"   $ v)  `pass` OnClick
    Path paths <- Widget $ getSData <|> return (Path  [])

    let paths'= paths ++  [ toLower $ JS.pack $ show1 x ]
    setData $ Path  paths'
--                                                         !> ("paths", paths')
    let fpath= ("/" <> (Prelude.foldl  (\p p' -> p <> "/" <> p') (head paths') $ tail paths')<> ".html")
    liftIO $ replaceState "" "" fpath
    return x
#else
wlink _ _= empty
#endif

show1 :: (Typeable a,Show a) => a -> String
show1 x | typeOf x== typeOf (ofType :: String) = unsafeCoerce x
        | otherwise= show x

data Path= Path [JSString]
--pathLength= unsafePerformIO $ newIORef 0

-- | avoid that a recursive widget with links may produce long paths. It is equivalent to tail call elimination
staticNav  x= do
  Path paths <-  getState <|> return (Path  [])
  x <*** setState (Path paths)
  
-- | show something enclosed in the <pre> tag, so ASCII formatting chars are honored
wprint :: ToElem a => a -> Widget ()
wprint = wraw . pre

-- | Enclose Widgets within some formating.
-- @view@ is intended to be instantiated to a particular format
--
-- NOTE: It has a infix priority : @infixr 5@ less than the one of @++>@ and @<++@ of the operators, so use parentheses when appropriate,
-- unless the we want to enclose all the widgets in the right side.
-- Most of the type errors in the DSL are due to the low priority of this operator.
--

(<<<) :: (Perch -> Perch)
         -> Widget a
         -> Widget a
(<<<) v  form = Widget  $ Transient $ do
  rest <- getData `onNothing` return noHtml
  delData rest
  r <- runView form
  do -- form <*** do
          torender <- getData `onNothing` return noHtml
          setData $ rest <> v torender
          return r


infixr 5 <<<





-- | A parameter application with lower priority than ($) and direct function application
(<<) :: (Perch -> Perch) -> Perch -> Perch
(<<) tag content= tag $ toElem content

infixr 7 <<


-- | Append formatting code to a widget
--
-- @ getString "hi" <++ H1 << "hi there"@
--
-- It has a infix prority: @infixr 6@ higuer that '<<<' and most other operators
(<++) :: Widget a
      -> Perch
      -> Widget a
(<++) form v= Widget . Transient $ do
              mx <-  runView  form
              addSData v
              return mx

infixr 6  ++>
infixr 6 <++
-- | Prepend formatting code to a widget
--
-- @bold << "enter name" ++> getString Nothing @
--
-- It has a infix prority: @infixr 6@ higher that '<<<' and most other operators
(++>) :: Perch -> Widget a -> Widget a
html ++> w = do 
  Widget . Transient $ do
      addSData html
      runView w




-- | Add attributes to the topmost tag of a widget

--  it has a fixity @infix 8@
infixl 8 <!
widget <! attribs=  Widget . Transient $ do
      rest <- getData `onNothing` return mempty
      delData rest
      mx <- runView widget
      fs <- getData `onNothing` return (mempty :: Perch)
      setData  $ rest <> (fs `attrs` attribs :: Perch)
      return mx


instance  Attributable (Widget a) where
 (!) widget atrib = Widget $ Transient $ do   -- widget <! [atrib]
              rest <- getData `onNothing` return (mempty:: Perch)
              delData rest
              mx <- runView widget
              fs <- getData `onNothing` return (mempty :: Perch)
              setData  $ do rest ; (child $ mspan  fs) ! atrib :: Perch
              return mx
     where
     child render = Perch $ \e -> do
             e'    <- build render e
             jsval <- firstChild e'
             fromJSValUnchecked jsval

instance Attributable   (Perch -> Widget a) where 
    w ! attr = \p -> w p ! attr

mspan  cont=  Perch $ \e -> build cont e -- do
--         n <- liftIO $ getName e
-- --        alert $ toJSString $ show n
--         if  n == Just "EVENT"
--            then build cont e
--            else build (nelem' "event" ! atr "id" id $  cont) e
  where
  -- nelem' x cont= nelem x `child` cont
-- | Empty widget that does not validate. May be used as \"empty boxes\" inside larger widgets.
--
-- It returns a non valid value.
noWidget  :: Widget a
noWidget= Control.Applicative.empty

-- | Render raw view formatting. It is useful for displaying information.
wraw ::  Perch -> Widget ()
wraw x= Widget $ addSData x >> return () -- x ++> return ()

-- |  wraw synonym
rawHtml= wraw

-- | True if the widget has no valid input
isEmpty :: Widget a -> Widget Bool
isEmpty w= Widget $ Transient $ do
  mv <- runView w
  return $ Just $ isNothing mv


-------------------------
fromStr = toElem
--     fromStrNoEncode  = toElem
ftag n v =  nelem n `child` v

attrs tag  [] = tag
attrs tag (nv:attribs) = attrs (attr tag nv) attribs

inred msg=  ftag "b" msg `attrs` [("style","color:red")]

finput n t v f c=
       let
        tag= input ! atr "type" t ! id   n ! atr "value"   v
        tag1= if f then tag ! atr "checked" "" else tag
       in case c of Just s -> tag1 ! atr "onclick" s; _ -> tag1


ftextarea nam text=
         textarea ! id  nam $ text


fselect nam list = select ! id nam $ list

foption  name v msel=
      let tag=  nelem "option" ! atr "value" name  `child`  v
      in if msel then tag ! atr "selected" "" else tag


--     formAction action method1 form = ftag "form" mempty `attrs` [("acceptCharset", "UTF-8")
--                                                          ,( "action", action)
--                                                          ,("method",  method1)]
--                                                          `child` form


--     flink  v str = ftag "a" mempty `attrs` [("href",  v)] `child` str


---------------------------
data EvData =  NoData | Click Int (Int, Int) | Mouse (Int, Int) | MouseOut | Key Int deriving (Show,Eq,Typeable)




resetEventData :: Widget ()
resetEventData= Widget . Transient $ do
    setData $ EventData "Onload" $ toDyn NoData
    return $ Just ()            -- !!> "RESETEVENTDATA"


getEventData ::  Widget EventData
getEventData =  Widget getSData <|> return  (EventData "Onload" $ toDyn NoData) -- (error "getEventData: event type not expected")

setEventData ::   EventData -> Widget ()
setEventData =  Widget . setData


class Typeable a => IsEvent a where
   eventName :: a -> JSString
   buildHandler :: Elem -> a  ->(EventData -> IO()) -> IO()



data BrowserEvent= OnLoad | OnUnload | OnChange | OnFocus | OnMouseMove | OnMouseOver |
 OnMouseOut | OnClick | OnDblClick | OnMouseDown | OnMouseUp | OnBlur |
 OnKeyPress | OnKeyUp | OnKeyDown deriving (Show, Typeable)

data EventData= EventData{ evName :: JSString, evData :: Dynamic} deriving (Show,Typeable)

--data OnLoad= OnLoad
instance  IsEvent  BrowserEvent  where
--  data EData _= EventData{ evName :: JSString, evData :: EvData} deriving (Show,Typeable)
  eventName e =
#ifdef ghcjs_HOST_OS
    JS.toLower $ JS.drop 2 (toJSString $ show e) -- const "load"
#else
    ""
#endif
  buildHandler elem e io =
    case e of
     OnLoad -> do
      cb <- syncCallback1 ContinueAsync (const $ setDat elem (io
                                           (EventData (eventName e) $ toDyn NoData)) )
      js_addEventListener elem (eventName e) cb

--data OnUnload = OnUnLoad
--instance  IsEvent  OnUnload   where
--  eventName= const "unload"
--  buildHandler elem e io = do
     OnUnload -> do
      cb <- syncCallback1 ContinueAsync (const $ setDat elem  $ io
                                           (EventData (eventName e) $ toDyn NoData) )
      js_addEventListener elem (eventName e) cb
--data OnChange= OnChange
--instance  IsEvent  OnChange   where
--  eventName= const "onchange"
--  buildHandler elem e io = do
     OnChange -> do
      cb <- syncCallback1 ContinueAsync (const $ setDat elem $ io
                                           (EventData (eventName e) $ toDyn NoData) )
      js_addEventListener elem (eventName e) cb

--data OnFocus= OnFocus
--instance  IsEvent  OnFocus   where
--  eventName= const "focus"
--  buildHandler elem e io = do
     OnFocus -> do
      cb <- syncCallback1 ContinueAsync (const $ setDat elem $ io
                                           (EventData (eventName e) $ toDyn NoData) )
      js_addEventListener elem (eventName e) cb

--data OnBlur= OnBlur
--instance  IsEvent  OnBlur   where
--  eventName= const "blur"
--  buildHandler elem e io = do
     OnBlur -> do
       cb <- syncCallback1 ContinueAsync (const $ setDat elem $ io
                                           (EventData (eventName e)$ toDyn NoData) )
       js_addEventListener elem (eventName e) cb

--data OnMouseMove= OnMouseMove Int Int
--instance  IsEvent  OnMouseMove  where
--  eventName= const "mousemove"
--  buildHandler elem e io= do
     OnMouseMove -> do
       cb <- syncCallback1 ContinueAsync
               (\r -> do
                 evdata<- Mouse <$> ((,) <$> clientX r <*> clientY r)
                 stopPropagation r
                 setDat elem $ io $  EventData (eventName e) $  toDyn evdata)
       js_addEventListener elem (eventName e) cb

--data OnMouseOver= OnMouseOver
--instance  IsEvent  OnMouseOver  where
--  eventName= const "mouseover"
--  buildHandler elem e io= do
     OnMouseOver -> do
       cb <- syncCallback1 ContinueAsync
                (\r -> do
                 evdata<- Mouse <$> ((,) <$> clientX r <*> clientY r)

                 stopPropagation r
                 setDat elem $ io $ EventData (nevent e) $ toDyn evdata)
       js_addEventListener elem (eventName e) cb

--data OnMouseOut= OnMouseOut
--instance  IsEvent  OnMouseOut   where
--  eventName= const "mouseout"
--  buildHandler elem e io = do
     OnMouseOut -> do
      cb <- syncCallback1 ContinueAsync (const $ setDat elem $ io
                                           (EventData (nevent e) $ toDyn $  NoData) )
      js_addEventListener elem (eventName e) cb

--data OnClick= OnClick
--
--instance  IsEvent  OnClick      where
--  eventName= const "click"
--  buildHandler elem e io= do
     OnClick -> do
      cb <- syncCallback1 ContinueAsync  $ \r -> do
          evdata<- Click <$> buttonMouse r <*> ((,) <$> clientX r <*> clientY r)
          stopPropagation r
          setDat elem $ io $   EventData (nevent e) $ toDyn evdata
      js_addEventListener elem (eventName e) cb

--data OnDblClick= OnDblClick
--instance  IsEvent  OnDblClick   where
--  eventName= const "dblclick"
--  buildHandler elem e io= do
     OnDblClick -> do
      cb <- syncCallback1 ContinueAsync  $ \r -> do
          evdata<- Click <$> buttonMouse r <*> ((,) <$> clientX r <*> clientY r)
          stopPropagation r
          setDat elem $ io $   EventData (nevent e) $ toDyn evdata
      js_addEventListener elem (eventName e) cb

--
--data OnMouseDown= OnMouseDown
--instance  IsEvent  OnMouseDown  where
--  eventName= const "mousedowm"
--  buildHandler elem e io= do
     OnMouseDown -> do
      cb <- syncCallback1 ContinueAsync $ \r -> do
          evdata<- Click <$> buttonMouse r <*> ((,) <$> clientX r <*> clientY r)
          stopPropagation r
          setDat elem  $ io $   EventData (nevent e) $ toDyn evdata
      js_addEventListener elem (eventName e) cb


--data OnMouseUp= OnMouseUp
--instance  IsEvent  OnMouseUp    where
--  eventName= const "mouseup"
--  buildHandler elem e io= do
     OnMouseUp -> do
      cb <- syncCallback1 ContinueAsync $ \r -> do
          evdata<- Click <$> buttonMouse r <*> ((,) <$> clientX r <*> clientY r)
          stopPropagation r
          setDat elem $ io $   EventData (nevent e) $ toDyn  evdata
      js_addEventListener elem (eventName e) cb


--data OnKeyPress= OnKeyPress
--instance  IsEvent  OnKeyPress  where
--  eventName= const "keypress"
--  buildHandler elem e io = do
     OnKeyPress -> do
      cb <- syncCallback1 ContinueAsync $ \r -> do
            i <-  keyCode r
            stopPropagation r
            setDat elem  $ io $  EventData (nevent e) $ toDyn $  Key i
      js_addEventListener elem (eventName e) cb

--data OnKeyUp= OnKeyUp
--instance  IsEvent OnKeyUp    where
--  eventName= const "keyup"
--  buildHandler elem e io = do
     OnKeyUp -> do
      cb <- syncCallback1 ContinueAsync $ \r -> do
            i <- keyCode r
            stopPropagation r
            setDat elem  $ io $ EventData (nevent e) $ toDyn $  Key i
      js_addEventListener elem (eventName e) cb

--data OnKeyDown= OnKeyDown
--instance  IsEvent  OnKeyDown   where
--  eventName= const "keydown"
--  buildHandler elem e io = do
     OnKeyDown -> do
      cb <- syncCallback1 ContinueAsync $ \r -> do
            i <-  keyCode r
            stopPropagation r
            setDat elem $ io $  EventData (nevent e) $ toDyn $ Key i
      js_addEventListener elem (eventName e) cb

   where


   nevent =  eventName

   setDat ::  Elem -> IO()  -> IO ()
   setDat elem action  = do
         action            -- !!> "begin action"
         return ()            -- !!> "end action"


addSData :: (MonadState TranShip m,Typeable a ,Monoid a) => a -> m ()
addSData y=  do
  x <- getData `onNothing` return  mempty
  setData (x <> y)

-- stores the identifier of the element to append new rendering
-- must be an identifier instead of an DOM element since links may reload the whole page

data IdLine= IdLine Int JSString  -- deriving(Read,Show)
data ExecRender= HasEventSet | ExecEvent   deriving (Eq, Read, Show)


-- first identifier for an applicative widget expression
-- needed for applictives in the widget monad that are executed differently than in the TransIO monad
-- newtype IDNUM = IDNUM Int deriving Show

-- data Event= forall ev.IsEvent ev => Event ev

-- data EventSet=  EventSet [(JSString, Int, Event, ( EventData -> IO ()))] deriving Typeable

-- {-# NOINLINE eventRef #-}
-- eventRef= unsafePerformIO $ newIORef $ EventSet []

-- | triggers the event that happens in a widget. The effects are the following:
--
-- 1)The event reexecutes the monadic sentence where the widget is, (with no re-rendering)
--
-- 2) with the result of this reevaluaution of 1), the rest of the monadic computation is executed
--
-- 3) update the DOM tree with the rendering generated by the reevaluation of 2).
--
-- As usual, If one step of the monadic computation return `empty` (`stop`), the reevaluation finish
-- So the effect of an event can be restricted as much as you may need.
--
-- The part of the monadic expression that is before the event is not evaluated and his rendering is untouched.
-- (but, at any moment, you can choose the element to be updated in the page using `at`)

-- to store the identifier number of the form elements to be set for that event



raiseEvent ::  IsEvent event  => Widget a -> event -> Widget a
#ifdef ghcjs_HOST_OS
raiseEvent w event = Widget  $ Transient $ do
  --  noTrans $ do
  --     id <- genNewId
  --     setData HasEventSet

  --     setState id
  --  Transient $ do
      --  Alternative cont <- getData  `onNothing` (Alternative <$> get)
       cont <- get
       let iohandler :: EventData -> IO ()
           iohandler eventdata =do
                runStateT (setData eventdata >> runCont' cont) cont  --  !> "runCont INIT"
                return ()                                            --  !> "runCont finished"

      --  id <- genNewId
      --  setState id
      --  let id'= JS.takeWhile (/='p') id
       runView $ addEvent  event iohandler <<< w  
       
   where
  --  -- to restore event handlers when a new template is loaded
  --  addEventList a b c= do
  --   mid <- getData
  --   case mid of
  --     Nothing -> return()
  --     Just (IdLine level _) -> do
  --       liftIO $ atomicModifyIORef eventRef $ \(EventSet mlist) ->
  --         let (cut,rest)= Prelude.span (\(x,l,_,_) -> x < a) mlist
  --             rest'= Prelude.takeWhile(\(_,l,_,_) -> l <= level) $ tail1 rest
  --         in (EventSet $ cut ++ (a,level, Event b, c):rest' ,())
  --  tail1 []= []
  --  tail1 xs= tail xs


   runCont' cont= do
     setData ExecEvent                              --  !> "REPEAT: SET EXECEVENT"

     mr <- runClosure cont !> "runclosure"
     case mr of
         Nothing -> return Nothing
         Just r -> runContinuation cont r     -- !> "continue"

       -- create an element and add any event handler to it.
   addEvent :: IsEvent a =>   a -> (EventData -> IO()) -> Perch -> Perch
   addEvent event iohandler be= Perch $ \e -> do
            e' <- build (mspan be) e
            buildHandler e' event iohandler
            return e


foreign import javascript unsafe
  "$1.keyCode"
  keyCode :: JSVal -> IO Int


foreign import javascript unsafe
  "$1.button"
  buttonMouse :: JSVal -> IO Int
  
foreign import javascript unsafe
  "$1.clientX"
  clientX  :: JSVal -> IO Int

foreign import javascript unsafe
  "$1.clientY"
  clientY  :: JSVal -> IO Int

foreign import javascript unsafe
  "$1.pageX"
  pageX  :: JSVal -> IO Int

foreign import javascript unsafe
  "$1.pageY"
  pageY  :: JSVal -> IO Int


#else
raiseEvent w _ = w
keyCode _=  undefint
undefint = error "not defined" :: IO Int
buttonMouse _=undefint
clientX _= undefint
clientY _= undefint
pageX _= undefint
pageY _= undefint
#endif

#ifdef ghcjs_HOST_OS
foreign import javascript unsafe
  "$1.stopPropagation()"
  stopPropagation :: JSVal -> IO ()
#else
stopPropagation= undefined
#endif



-- | A shorter synonym for `raiseEvent`
fire ::   IsEvent event => Widget a -> event -> Widget a
fire = raiseEvent

-- | A shorter and smoother synonym for `raiseEvent`
wake ::   IsEvent event => Widget a -> event -> Widget a
wake = raiseEvent


-- | pass trough only if the event is fired in this DOM element.
-- Otherwise, if the code is executing from a previous event, the computation will stop
pass :: IsEvent event => Perch -> event -> Widget EventData
pass v event= Widget $ do
        norender resetEventData 
        norender $ rawHtml v `fire` event 
        e@(EventData typ _) <- norender getEventData
        norender $ guard (eventName event== typ)
        return e


-- | run the widget as the content of a DOM element
-- the new rendering is added to the element
runWidget :: Widget b -> Elem  -> IO (Maybe b)
runWidget action e = do
     (mx, s) <- runTransient $ runWidget' action e
     return mx


runWidget' :: Widget b -> Elem   -> TransIO b
runWidget' action e  = do

      mx <- norender action <*** do                        -- !> "runVidget'"
              torender <- getData `onNothing` (return  noHtml)
              tr "build de runWidget"
              
              liftIO $ build torender e >> return()

              delData torender
      return mx

runWidgetId w id=  do
   tr "runWidgetId"
   me <- liftIO $ elemById id
   guard $ isJust me
   let e = fromJust me
   liftIO $ clearChildren  e
   runWidget' w  e

-- | add a header in the <header> tag
addHeader :: Perch -> IO ()
#ifdef ghcjs_HOST_OS
addHeader format= do
    head <- getHead
    build format head
    return ()
#else
addHeader _ = return ()
#endif


-- | run the widget as the body of the HTML. It adds the rendering to the body of the document.
--
-- Use only for pure client-side applications, like the ones of <http://http://tryplayg.herokuapp.com>
runBody :: Widget a -> IO (Maybe a)
runBody w= do
  (ma,_) <- runTransient $ do
          id1 <- genNewId
          top <- liftIO getBody
          liftIO $ build (span ! id id1 $ noHtml) top
          delData ExecEvent
          setState $ IdLine 0 id1
          runWidgetId w id1
  return ma


-- newtype AlternativeBranch= Alternative TranShip deriving Typeable

-- | executes the computation and  add the effect of "hanging" the generated rendering from the one generated by the
-- previous `render` sentence, or from the body of the document, if there isn't any. If an event happens within
-- the `render` parameter, it deletes the rendering of all subsequent ones.
-- so that the sucessive sequence of `render` in the code will reconstruct them again.
-- However the rendering of elements combined with `<|>` or `<>` or `<*>`  are independent.
-- This allows for full dynamic and composable client-side Web apps.
render :: Widget a -> TransIO a
#ifdef ghcjs_HOST_OS
render  mx = Transient $ do
       delData RenderExec ; tr "reset RenderExec"
       idline1@(IdLine level id1')
             <- getData `onNothing` do
                    id1 <- genNewId                                -- !> "ONNOTHING"
                    -- if is being edited or not
                    top <-  liftIO  $ (elemById "edited") `onNothing` getBody
                    liftIO $ build (span ! id id1 $ noHtml) top
                    return $ IdLine 0 id1

       tr("render",id1')
       let id1= id1'

       id2 <-  genNewId
       tr ("id2 generated",id2)


       needIndent<- liftIO $ newIORef False

--       r <- runWidgetId' (mx' id1 id2 <++ (span ! id id2 $ noHtml)) id1
       prevRender <- getData `onNothing` return noHtml
       delData noHtml
       r <-runTrans $ norender mx <*** noTrans (do
       
          mtorender    :: Maybe Perch       <- getData 
          mrenderExec  :: Maybe RenderExec  <- getData 

          tr ("mtorender, mrenderExec ",isNothing mtorender,isJust mrenderExec)
          if isJust mrenderExec then do 
                 tr ("second level render" , id2)
                 liftIO $ writeIORef needIndent True
                 --alert("creating", id2)
                 setData $ (fromMaybe noHtml mtorender  <> (span ! id id2 $ noHtml))
          else if isNothing mtorender then do  setData prevRender;  tr "no HTML" ; return () 
          else do
           liftIO $ writeIORef needIndent True
           let torender = fromMaybe mempty mtorender -- fromJust mtorender
           tr ("HAY HTML",id1')

           execmode <- getData

           case execmode of
            Just ExecEvent ->   do
                tr "ExecEvent"
                tr ("EVENT id1,id2",id1,id2)
                meid2 <- liftIO $ elemBySeqDOM id1 id2 >>= fromJSVal  -- elemById id2
                -- tr ("isJust id2", isJust meid2)
                delData ExecEvent
                delData noHtml
                setData $ IdLine (level +1) id2

                when (isJust meid2) $ do
                   liftIO $ clearChildren $ fromJust meid2


            Just HasEventSet  -> do 
            
                     delData HasEventSet
                     tr "render HasEventSet"
                     --liftIO $ build (torender <> (span ! id id2 $ noHtml)) eid1
                     
                     setData $ ((Perch $ \e -> do
                        build prevRender e
                        parent <- liftIO $ elemById id1 `onNothing`  error ("not found: " ++ show id1)
                        build (torender <> (span ! id id2 $ noHtml)) parent >> return e) :: Perch)
                     delData ExecEvent
            _ -> do
                     tr "render noEvent"
                     liftIO $ writeIORef needIndent False
                     setData $ ((Perch $ \e -> do
                        build prevRender e
                        parent <- liftIO $ elemById id1 `onNothing`  error ("not found: " ++ show id1)
                        build torender  parent >> return e) :: Perch)
                     
              
          return  ())
       tr ("ISJUST", isJust r)
       when (isJust r) $ do
            setData RenderExec; tr "set RennderExec"
            indent <- liftIO $ readIORef needIndent -- interesa rendering producido en esa llamada no el acumulado
            when indent $ do
               tr ("SET ID2",id2)
               setData (IdLine (level +1) id2 )  
                             --delData $ fromJust mtorender
            -- delData (Alternative undefined)-- >> setData (IdLine (level +1) id2 )    --solo cuando ha habido rendering!
          -- else do 
               --delData noHtml
              --  cont <- get
              --  setData (Alternative cont)  !> "SETDATA ALTERNATIVE"
       return r

-- render :: Widget a -> TransIO a
-- #ifdef ghcjs_HOST_OS
-- render  mx = Transient $ do
--        delData RenderExec ; tr "reset RenderExec"
--        idline1@(IdLine level id1')
--              <- getData `onNothing` do
--                     id1 <- genNewId                                -- !> "ONNOTHING"
--                     -- if is being edited or not
--                     top <-  liftIO  $ (elemById "edited") `onNothing` getBody
--                     liftIO $ build (span ! id id1 $ noHtml) top
--                     return $ IdLine 0 id1

--        tr("render",id1')
--        let id1= id1'

--        id2 <-  genNewId
--        tr ("id2 generated",id2)


--        needIndent<- liftIO $ newIORef False

-- --       r <- runWidgetId' (mx' id1 id2 <++ (span ! id id2 $ noHtml)) id1
--        prevRender <- getData `onNothing` return noHtml
--        delData noHtml
--        r <-runTrans $ norender mx <***
--         (noTrans $ do
--           mtorender    :: Maybe Perch       <- getData 
--           mrenderExec  :: Maybe RenderExec  <- getData 

--           tr ("mtorender, mrenderExec ",isNothing mtorender,isJust mrenderExec)
--           if isJust mrenderExec then do 
--                  tr ("second level render" , id2)
--                  liftIO $ writeIORef needIndent True
--                  --alert("creating", id2)
--                  setData $ (fromMaybe noHtml mtorender  <> (span ! id id2 $ noHtml))
--           else if isNothing mtorender then do  setData prevRender;  tr "no HTML" ; return () 
--           else do
--            liftIO $ writeIORef needIndent True
--            let torender = fromMaybe mempty mtorender -- fromJust mtorender
--            tr ("HAY HTML",id1')

--            execmode <- getData

--            case execmode of
--             Just ExecEvent ->   do
--                 tr "ExecEvent"
--                 tr ("EVENT id1,id2",id1,id2)
--                 meid2 <- liftIO $ elemBySeqDOM id1 id2 >>= fromJSVal  -- elemById id2
--                 -- tr ("isJust id2", isJust meid2)
--                 delData ExecEvent
--                 delData noHtml
--                 setData $ IdLine (level +1) id2

--                 when (isJust meid2) $ do
--                    liftIO $ clearChildren $ fromJust meid2



             

--             Just HasEventSet  -> do
            
--                      delData HasEventSet
--                      tr "render HasEventSet"
--                      --liftIO $ build (torender <> (span ! id id2 $ noHtml)) eid1
                     
--                      setData $ ((Perch $ \e -> do
--                         build prevRender e
--                         parent <- liftIO $ elemById id1 `onNothing`  error ("not found: " ++ show id1)
--                         build (torender <> (span ! id id2 $ noHtml)) parent >> return e) :: Perch)
--                      delData ExecEvent
--             _ -> do
--                      tr "render noEvent"
--                      liftIO $ writeIORef needIndent False
--                      setData $ ((Perch $ \e -> do
--                         build prevRender e
--                         parent <- liftIO $ elemById id1 `onNothing`  error ("not found: " ++ show id1)
--                         build torender  parent >> return e) :: Perch)
                     
              
--            return  ())
--        tr ("ISJUST", isJust r)
--        if isJust r
--           then do 
--             setData RenderExec; tr "set RennderExec"
--             indent <- liftIO $ readIORef needIndent -- interesa rendering producido en esa llamada no el acumulado
--             when indent $ do
--                tr ("SET ID2",id2)
--                setData (IdLine (level +1) id2 )  
--                              --delData $ fromJust mtorender
--             delData (Alternative undefined)-- >> setData (IdLine (level +1) id2 )    --solo cuando ha habido rendering!
--           else do 
--                --delData noHtml
--                cont <- get
--                setData (Alternative cont)  !> "SETDATA ALTERNATIVE"
--        return r

#else
render (Widget x)= empty
#endif

data RenderExec= RenderExec deriving Typeable  --render has just been executed



-- | use this instead of `Transient.Base.option` when runing in the browser
option :: (Typeable b, Show b) =>  b -> String -> Widget b
option x v=  wlink x (toElem v) <++ " "


--foreign import javascript unsafe "document.body" getBody :: IO Elem



data UpdateMethod= Append | Prepend | Insert deriving Show

-- | set the tag where subsequent `render` calls will place HTML-DOM element
setRenderTag :: MonadState TranShip m => JSString -> m ()
setRenderTag id=  modifyData' (\(IdLine level _) -> IdLine level   id) (IdLine 0 id) >> return () 


-- | Run the widget as the content of the element with the given path identifier. The content can
-- be appended, prepended to the previous content or it can erase the previous content depending on the
-- update method.
at ::  JSString -> UpdateMethod -> Widget a -> Widget  a
at id method w = Widget $ Transient $ runView $ setAt id method `insert` w 
  where
  insert v (Widget form)= Widget  $ Transient $ do
      rest <- getData `onNothing` return noHtml
      delData rest
      r <- runTrans form
      do
      -- form <*** do
              --mat :: Maybe RenderExec <- getData
              torender <- getData `onNothing` return noHtml
              let torender'= v torender -- if isJust mat then torender else v torender
              setData $ rest <> torender'
              return r
-- pspan= prependElem "span"
-- prependElem :: JSString -> Perch
-- prependElem s = Perch $ \(V.Elem x) ->
--   do Elem e <- newElem s
--      prepend e x
--      return e

-- foreign import javascript unsafe "$1.prepend($2)"
--   prepend :: JSVal -> JSVal -> IO ()


setAt :: JSString -> UpdateMethod -> Perch  -> Perch
setAt id method render  = liftIO $   case method of

     Insert -> do
             tr "INSERT"
             forElems_ id $ clear >> render
             return ()
     Append -> do
             forElems_ id render
             return ()
     Prepend -> do
            forElems_ id $ Perch $ \e -> do
             jsval <- getChildren e
             es <- fromJSValUncheckedListOf jsval
             case es of
                       [] -> build render e >> return e
                       e':es -> do
                             span <- newElem "span"
                             addChildBefore span e e'
                             build render span
                             return e


-- | a version of `at` for the Cloud monad.
at' ::  JSString -> UpdateMethod -> Cloud a -> Cloud  a
at' id method w= setAt id method `insert` w
    where
    insert v comp=   Cloud . Transient $ do
          rest <- getData `onNothing` return noHtml
          delData rest
          mx <-  runTrans  $ unCloud comp
          f <- getData `onNothing` return noHtml
          setData $ rest <> v f
          return mx



#ifdef ghcjs_HOST_OS

foreign import javascript unsafe  "$1[$2].toString()" getProp :: Elem -> JSString -> IO JSString



foreign import javascript unsafe  "$1[$2] = $3" setProp :: Elem -> JSString -> JSString -> IO ()

foreign import javascript unsafe  "alert($1)" js_alert ::  JSString -> IO ()

alert ::  (Show a,MonadIO m) => a -> m ()
alert= liftIO . js_alert . pack . show 

foreign import javascript unsafe  "document.getElementById($1)" elemByIdDOM
      :: JSString -> IO JSVal

foreign import javascript unsafe  "document.getElementById($1).querySelector(\"[id^='\"+$2+\"']\")"
        elemBySeqDOM
        :: JSString -> JSString -> IO JSVal

foreign import javascript unsafe  "$1.value"   getValueDOM :: Elem -> IO JSVal
foreign import javascript unsafe  "$1.tagName" getNameDOM :: Elem -> IO JSVal

foreign import javascript unsafe "$1.getAttribute($2)"
          attributeDOM
          :: Elem -> JSString -> IO JSVal
#else
unpack= undefined
getProp :: Elem -> JSString -> IO JSString
getProp = error "getProp: undefined in server"
setProp :: Elem -> JSString -> JSString -> IO ()
setProp = error "setProp: undefined in server"
alert ::  (Show a,MonadIO m) => a -> m ()
alert= liftIO . print
data Callback a= Callback a
data ContinueAsync=ContinueAsync
syncCallback1= undefined
fromJSValUnchecked= undefined
fromJSValUncheckedListOf= undefined
#endif

#ifdef ghcjs_HOST_OS
foreign import javascript unsafe
  "$1.addEventListener($2, $3,false);"
  js_addEventListener :: Elem -> JSString -> Callback (JSVal -> IO ()) -> IO ()
#else
js_addEventListener= undefined
#endif


#ifdef ghcjs_HOST_OS
foreign import javascript unsafe "document.head" getHead :: IO Elem
#else
getHead= undefined
#endif

#ifdef ghcjs_HOST_OS
foreign import javascript unsafe "$1.childNodes" getChildren :: Elem -> IO JSVal
foreign import javascript unsafe "$1.firstChild" firstChild :: Elem -> IO JSVal
foreign import javascript unsafe "$2.insertBefore($1, $3)" addChildBefore :: Elem -> Elem -> Elem -> IO()

foreign import javascript unsafe
   "while ($1.nextSibling != null) {$1.parentNode.removeChild($1.nextSibling)};"
  deleteSiblings :: Elem -> IO ()

foreign import javascript unsafe
   "$1.nextSibling"
   js_nextSibling :: Elem  -> IO JSVal

nextSibling e= js_nextSibling e >>= fromJSVal

#else

type JSVal = ()
getChildren :: Elem -> IO JSVal
getChildren= undefined
firstChild :: Elem -> IO JSVal
firstChild= undefined
addChildBefore :: Elem -> Elem -> Elem -> IO()
addChildBefore= undefined
#endif


---------------------------- TEMPLATES & NAVIGATION ---------------

editW ::   Cloud String
#ifdef ghcjs_HOST_OS
editW = onBrowser $ loggedc $ do

      local $ do
         liftIO $ forElems_ "body"  $ this `child` do
                       div ! id  "panel" $ noHtml
                       div ! id "edit" $ div ! id "edited" $
                        center $ font ! atr "size" "2" ! atr "color" "red" $ p $ do
                           "Edit this template" <> br
                           "Add content, styles, layout" <> br
                           "Navigate the links and save the edition for each link" <> br
                           "Except this header, don't delete anything unless you know what you do" <> br
                           "since the template has been generated by your code" <> br
         installnicedit
         liftIO $threadDelay 1000000


--         edit <- liftIO $ elemById "edit" >>= return . fromJust
--         setState $ IdLine 0 "edit"



         react edit1  (return ()) :: TransIO ()

      return "editw"
      where
      font ch= nelem "font" `child` ch

      edit1 :: (() -> IO ()) -> IO ()
      edit1  f= do
         Callback cb <- syncCallback1 ContinueAsync $  \ _ -> f()
         js_edit  cb


      installnicedit= do
         liftIO   $ addHeader $ script ! id "nic"
                                       ! atr "type" "text/javascript"
                                       ! src "http://js.nicedit.com/nicEdit-latest.js"
                                       $ noHtml

--manageNavigation= do
--    Callback cb <- syncCallback1 ContinueAsync nav
--    onpopstate cb
--    where
--    nav e= do
--      location <- fromJSValUnchecked  e
--      alert location
----- pushstate

foreign import javascript unsafe
  "window.onpopstate = function(event) { $1(document.location);}"
  onpopstate :: JSVal -> IO ()

foreign import javascript unsafe  "window.history.pushState($1,$2,$3)"
    pushState :: JSString -> JSString  -> JSString -> IO ()



foreign import javascript unsafe  "window.history.replaceState($1,$2,$3)"
    replaceState :: JSString -> JSString  -> JSString -> IO ()

foreign import javascript unsafe "document.getElementById('edit').innerHTML"
    js_getPage :: IO JSVal
foreign import javascript safe  "window.location.pathname"                js_path    :: IO JSVal

foreign import javascript unsafe
          "var myNicEditor = new nicEditor({fullPanel : true, onSave : $1});myNicEditor.addInstance('edit');myNicEditor.setPanel('panel');"

          js_edit    ::  JSVal -> IO ()

--          "var myNicEditor = new nicEditor({fullPanel : true, onSave : function(content, id, instance) {myNicEditor.removeInstance('edit');myNicEditor.removePanel('panel');}});myNicEditor.addInstance('edit');myNicEditor.setPanel('panel');"

#else
--manageNavigation :: IO ()
--manageNavigation = undefined
pushState _ _ _= empty
replaceState _ _ _= empty
editW = onBrowser $ local empty                             -- !> "editW"
js_getPage=  empty :: IO JSVal
js_path=  empty :: IO JSVal
#endif
