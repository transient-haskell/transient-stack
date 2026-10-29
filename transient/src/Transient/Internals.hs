-- | Compatibility shim: re-exports 'Transient.CEngine' and 'Transient.Core' under the original
-- @Transient.Internals@ name so existing code does not need to be updated.
module Transient.Internals (
  module Transient.CEngine,
  module Transient.Core
)
where
import Transient.CEngine
import Transient.Core