-- | Compatibility shim: re-exports 'Transient.LEngine' and 'Transient.Core' under the original
-- @Transient.Internals@ name so existing code does not need to be updated.
module Transient.Internals (
  module Transient.LEngine,
  module Transient.Core
)
where
import Transient.LEngine
import Transient.Core