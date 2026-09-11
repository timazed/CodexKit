"""Closed choices shared by the offline app-verification commands."""
from enum import Enum


class VerificationMode(str, Enum):
    SMOKE = "smoke"
    FULL = "full"

    def __str__(self):
        return self.value


class VerificationPhase(str, Enum):
    INITIAL = "initial"
    REOPEN = "reopen"

    def __str__(self):
        return self.value
