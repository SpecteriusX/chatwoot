# Defines the Custom namespace unconditionally.
#
# This file is load-bearing: do not delete it, even when the overlay is otherwise empty.
#
# config/initializers/01_inject_enterprise_edition_module.rb resolves overlays with:
#
#   def const_get_maybe_false(mod, name)
#     mod&.const_defined?(name, false) && mod&.const_get(name, false)
#   end
#
# That returns *false* (not nil) for a missing constant, and `&.` only short-circuits on nil.
# So if `custom/` exists but the `Custom` constant does not, every *_mod_with call raises
# NoMethodError: undefined method 'const_defined?' for false, and the app will not boot.
#
# Chatwoot never hits this because enterprise/ always defines Enterprise. Defining Custom here
# keeps the overlay safe to leave empty.
module Custom
end
