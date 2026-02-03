--  Transient.Internals was divided into Transient.Engine and Transient.Core. This simulates the original Transient.Internals
module Transient.Internals (
  module Transient.Engine,
  module Transient.Core
)
where
import Transient.Engine
import Transient.Core