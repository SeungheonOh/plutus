{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module PlutusCore.Builtin.Case where

import PlutusCore.Builtin.KnownType (HeadSpine (..))
import PlutusCore.Core.Type (Type, UniOf)
import PlutusCore.Name.Unique (TyName)
import PlutusPrelude

import Control.DeepSeq (NFData (..), rwhnf)
import Control.Monad.ST (ST)
import Data.Text (Text)
import Data.Vector (Vector)
import NoThunks.Class
import Universe

class AnnotateCaseBuiltin uni where
  {-| Given a tag for a built-in type and a list of branches, annotate each of the branches with
  its expected argument types or fail if casing on values of the built-in type isn't supported.
  Note: you don't need to include the resulting type of the whole case matching in the
  returning list here. -}
  annotateCaseBuiltin
    :: UniOf term ~ uni
    => Type TyName uni ann
    -> [term]
    -> Either Text [(term, [Type TyName uni ann])]

class CaseBuiltin uni where
  {-| Given a constant with its type tag and a vector of branches, choose the appropriate branch
  or fail if the constant doesn't correspond to any of the branches (or casing on constants of
  this type isn't supported at all). -}
  caseBuiltin
    :: UniOf term ~ uni
    => Some (ValueOf uni)
    -> Vector term
    -> HeadSpine Text term (Some (ValueOf uni))

  {-# MINIMAL caseBuiltin #-}

{-| A number of conservative shallow-matching work units. The fixed 'Match' CEK step covers the
first bounded root probe. Universe matchers use this single additional quantum for work that can
grow with syntax or captured output. -}
newtype PatternWork = PatternWork {patternWorkUnits :: Word64}

{-| The fixed effect used by universe-specific pattern matchers. It is a Reader over 'ST': the CEK
supplies its budget action once when running the matcher, while matcher code calls
'spendPatternWork' directly from its monadic context. Keeping the monad fixed lets GHC erase the
Reader and 'ST' newtypes and optimize sequencing without a per-step unknown-'Monad' dictionary. -}
newtype PatternMatchM s a = PatternMatchM
  { runPatternMatchM :: (PatternWork -> ST s ()) -> ST s a
  }

instance Functor (PatternMatchM s) where
  fmap f (PatternMatchM action) = PatternMatchM $ \spend -> fmap f (action spend)
  {-# INLINE fmap #-}

instance Applicative (PatternMatchM s) where
  pure value = PatternMatchM $ \_ -> pure value
  {-# INLINE pure #-}
  PatternMatchM fun <*> PatternMatchM arg =
    PatternMatchM $ \spend -> fun spend <*> arg spend
  {-# INLINE (<*>) #-}

instance Monad (PatternMatchM s) where
  PatternMatchM action >>= next =
    PatternMatchM $ \spend -> action spend >>= \value -> runPatternMatchM (next value) spend
  {-# INLINE (>>=) #-}

spendPatternWork :: PatternWork -> PatternMatchM s ()
spendPatternWork (PatternWork 0) = pure ()
spendPatternWork work = PatternMatchM $ \spend -> spend work
{-# INLINE spendPatternWork #-}

class MatchBuiltin uni where
  type BuiltinPattern uni

  {-| Given a built-in constant and an ordered vector of pattern/handler alternatives, choose the
  first matching handler. The ordinary CEK Match step pays for the first bounded root probe;
  'spendPatternWork' prepays a single kind of conservative shallow-work quantum for variable work.
  A universe matcher may charge from syntax before inspecting the value, so a failing structural
  pattern can intentionally pay for requested fields that the scrutinee does not contain.

  Input-sized operations must be bounded by work units before they run. For the default shallow
  matcher, units cover later alternative probes, immediate fields, capture retention and
  materialization, and eight-byte chunks of ByteString comparison. Handler application after
  selection remains ordinary CEK work.

  Alternative ordering and selection belong to the universe matcher, not the CEK machine. A
  successful matcher returns the selected handler and captures directly in head-spine form and
  handler-application order. 'HeadError' represents an unsupported matcher or exhaustion of the
  alternatives. The 'PatternMatchM' context is a trusted costing boundary. -}
  matchBuiltin
    :: Some (ValueOf uni)
    -> Vector (BuiltinPattern uni, term)
    -> PatternMatchM s (HeadSpine Text term (Some (ValueOf uni)))
  matchBuiltin _ _ =
    pure $ HeadError "built-in patterns are not supported by this universe"

-- See Note [DO NOT newtype-wrap functions].
{-| A @data@ version of 'CaseBuiltin'. we parameterize the evaluator by a 'CaserBuiltin' so that
the caller can choose whether to use the 'caseBuiltin' method or the always failing caser (the
latter is required for earlier protocol versions when we didn't support casing on builtins). -}
data CaserBuiltin uni = CaserBuiltin
  { unCaserBuiltin
      :: !( forall term
             . UniOf term ~ uni => Some (ValueOf uni) -> Vector term -> HeadSpine Text term (Some (ValueOf uni))
          )
  }

{-| A data version of 'MatchBuiltin'. It is separate from 'CaserBuiltin' so that adding a pattern
language to UPLC does not parameterize the typed CK machine or change legacy built-in casing APIs. -}
data MatcherBuiltin uni = MatcherBuiltin
  { unMatchBuiltin
      :: !( forall s term
             . Some (ValueOf uni)
            -> Vector (BuiltinPattern uni, term)
            -> PatternMatchM s (HeadSpine Text term (Some (ValueOf uni)))
          )
  }

instance NFData (CaserBuiltin uni) where
  rnf = rwhnf

deriving via
  OnlyCheckWhnfNamed "PlutusCore.Builtin.Case.CaserBuiltin" (CaserBuiltin uni)
  instance
    NoThunks (CaserBuiltin uni)

instance NFData (MatcherBuiltin uni) where
  rnf = rwhnf

deriving via
  OnlyCheckWhnfNamed "PlutusCore.Builtin.Case.MatcherBuiltin" (MatcherBuiltin uni)
  instance
    NoThunks (MatcherBuiltin uni)

availableCaserBuiltin :: CaseBuiltin uni => CaserBuiltin uni
availableCaserBuiltin = CaserBuiltin caseBuiltin

availableMatcherBuiltin
  :: MatchBuiltin uni => MatcherBuiltin uni
availableMatcherBuiltin = MatcherBuiltin matchBuiltin

instance CaseBuiltin uni => Default (CaserBuiltin uni) where
  def = availableCaserBuiltin

instance MatchBuiltin uni => Default (MatcherBuiltin uni) where
  def = availableMatcherBuiltin

unavailableCaserBuiltin :: Int -> CaserBuiltin uni
unavailableCaserBuiltin ver =
  CaserBuiltin $ \_ _ ->
    HeadError $
      "'case' on values of built-in types is not supported in protocol version " <> display ver

unavailableMatcherBuiltin :: Int -> MatcherBuiltin uni
unavailableMatcherBuiltin ver =
  MatcherBuiltin
    ( \_ _ ->
        pure . HeadError $
          "patterns on values of built-in types are not supported in protocol version " <> display ver
    )
