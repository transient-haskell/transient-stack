{-# LANGUAGE CPP                  #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}
module Internal.Type where

import           Perch.JS
#ifdef BROWSER
import           Internal.FFI  (js_isInCurrentDOM)
#endif
#if defined(ghcjs_HOST_OS)
import           GHCJS.Marshal (FromJSVal (..), ToJSVal (..))
#endif
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
newtype Elem = Elem JSVal

type PropId = JSString

type Attribute = (JSString, JSString)


class NamedEvent a where
  eventName :: a -> String

data JsEvent = Blur
             | Change
             | Click
             | DblClick
             | Focus
             | KeyPress
             | KeyUp
             | KeyDown
             | Load
             | MouseDown
             | MouseMove
             | MouseOut
             | MouseOver
             | MouseUp
             | Submit
             | Unload
             | Wheel


#if defined(wasm32_HOST_ARCH)
instance FromJSVal Elem where
  fromJSVal v =
    do isElem <- js_isInCurrentDOM v
       return $
         if isElem
         then Just (Elem v)
         else Nothing
#elif defined(ghcjs_HOST_OS)
instance FromJSVal Elem where
  fromJSVal v =
    do isElem <- js_isInCurrentDOM v
       return $
         if isElem
         then Just (Elem v)
         else Nothing

instance ToJSVal Elem where
  toJSVal (Elem val) = return val
#endif

#ifdef BROWSER
instance NamedEvent String where
  eventName = Prelude.id
#endif

instance {-# OVERLAPPABLE #-} Show a => NamedEvent a where
  eventName = eventName . show

instance NamedEvent JSString where
  eventName x = eventName (unpack x :: String)

instance Show JsEvent where
  show Blur      = "blur"
  show Change    = "change"
  show Click     = "click"
  show DblClick  = "dblclick"
  show Focus     = "focus"
  show KeyDown   = "keydown"
  show KeyPress  = "keypress"
  show KeyUp     = "keyup"
  show Load      = "load"
  show MouseDown = "mousedown"
  show MouseMove = "mousemove"
  show MouseOut  = "mouseout"
  show MouseOver = "mouseover"
  show MouseUp   = "mouseup"
  show Submit    = "submit"
  show Unload    = "unload"
  show Wheel     = "wheel"
--------------------------------------------------------------------------------
