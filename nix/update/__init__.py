"""Confirmed Nix release updates; metadata discovery never runs release code."""


class UpdateError(RuntimeError):
    """An update cannot safely continue."""
