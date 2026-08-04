{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{-| Small, paired workloads for calibrating shallow @Match@.

The suite has only two cost targets: the fixed 'BMatch' entry and the conservative
'BMatchWork' quantum.  Every case retains a recipe rather than a term.  This is important for
Criterion: a selected environment owns the only fully-forced calibration term, so running a large
case does not retain all of the other large constants and pattern vectors in the suite. -}
module PlutusBenchmark.Matching.Costing
  ( CostingCase (..)
  , MatchStepCounts (..)
  , Unit (..)
  , calibrationCases
  , calibrationSizes
  )
where

import Data.ByteString qualified as BS
import Data.Vector qualified as Vector
import PlutusCore qualified as Core
import PlutusCore.Data qualified as PLC
import PlutusCore.Default
  ( DefaultBuiltinPattern (..)
  , DefaultPatternField (..)
  , DefaultPatternFieldEnd (..)
  )
import PlutusCore.MkPlc (mkConstant)
import UntypedPlutusCore qualified as UPLC

type Term =
  UPLC.Term UPLC.NamedDeBruijn Core.DefaultUni Core.DefaultFun ()

-- | The four dynamic CEK counts checked before any calibration benchmark is timed.
data MatchStepCounts = MatchStepCounts
  { matchCount :: !Integer
  , matchWorkCount :: !Integer
  , caseCount :: !Integer
  , lamAbsCount :: !Integer
  }
  deriving stock (Eq, Show)

data CostingCase = CostingCase
  { costingCaseName :: !String
  , costingCaseFamily :: !String
  , costingCaseUnits :: !Integer
  , costingCaseRole :: !String
  , costingCaseTarget :: !String
  -- ^ @match@, @match_work@, or @audit@.  Audit rows are reported but never calibrated.
  , costingCaseExpected :: !MatchStepCounts
  , costingCaseTerm :: !(Unit -> Term)
  }

data Unit = Unit

-- Four separated points are enough to expose both non-linearity and fixed noise without making
-- the full suite retain or evaluate a large corpus.
calibrationSizes :: [Integer]
calibrationSizes = [16, 64, 256, 1024]

calibrationCases :: [CostingCase]
calibrationCases = calibrationSizes >>= casesAtSize

casesAtSize :: Integer -> [CostingCase]
casesAtSize scale =
  concat
    [ paired
        "entry-integer"
        "match"
        scale
        (counts 0 0 scale 0)
        (defer buildIntegerCaseChain scale)
        (counts scale 0 0 0)
        (defer buildIntegerMatchChain scale)
    , paired
        "rejected-alternatives"
        "match_work"
        scale
        (counts 1 0 0 0)
        (defer buildAlternativesControl scale)
        (counts 1 scale 0 0)
        (defer buildRejectedAlternatives scale)
    , fieldScanPair "list-fields" scale buildListFields
    , fieldScanPair "data-list-fields" scale buildDataListFields
    , fieldScanPair "data-constr-fields" scale buildDataConstrFields
    , fieldScanPair "data-map-fields" scale buildDataMapFields
    , paired
        "root-capture-success"
        "match_work"
        scale
        (counts scale 0 0 0)
        (defer buildRootCaptureControl scale)
        (counts scale scale 0 scale)
        (defer buildRootCaptureWork scale)
    , paired
        "field-capture-success"
        "match_work"
        scale
        (counts 1 scale 0 0)
        (defer buildFieldCaptureControl scale)
        (counts 1 (2 * scale) 0 scale)
        (defer buildFieldCaptureWork scale)
    , paired
        "field-capture-abandoned"
        "match_work"
        scale
        (counts 1 (scale + 1) 0 0)
        (defer buildAbandonedCaptureControl scale)
        (counts 1 (2 * scale + 1) 0 0)
        (defer buildAbandonedCaptureWork scale)
    , paired
        "rest-suffix"
        "audit"
        scale
        (counts 1 1 0 0)
        (defer buildRestControl scale)
        (counts 1 1 0 0)
        (defer buildRestSuffix scale)
    , paired
        "pair-bounded"
        "match_work"
        (2 * scale)
        (counts scale 0 0 0)
        (defer buildPairControl scale)
        (counts scale (2 * scale) 0 0)
        (defer buildPairWork scale)
    , paired
        "data-i-bounded"
        "match_work"
        scale
        (counts scale 0 0 0)
        (defer buildDataIControl scale)
        (counts scale scale 0 0)
        (defer buildDataIWork scale)
    , paired
        "data-b-bounded"
        "match_work"
        scale
        (counts scale 0 0 0)
        (defer buildDataBControl scale)
        (counts scale scale 0 0)
        (defer buildDataBWork scale)
    , paired
        "bytestring-8-byte-chunks"
        "match_work"
        scale
        (counts 1 0 0 0)
        (defer buildByteStringControl scale)
        (counts 1 scale 0 0)
        (defer buildByteStringWork scale)
    ]

fieldScanPair :: String -> Integer -> (Bool -> Integer -> Term) -> [CostingCase]
fieldScanPair family scale build =
  paired
    family
    "match_work"
    scale
    (counts 1 0 0 0)
    (defer (build False) scale)
    (counts 1 scale 0 0)
    (defer (build True) scale)

counts :: Integer -> Integer -> Integer -> Integer -> MatchStepCounts
counts = MatchStepCounts

paired
  :: String
  -> String
  -> Integer
  -> MatchStepCounts
  -> (Unit -> Term)
  -> MatchStepCounts
  -> (Unit -> Term)
  -> [CostingCase]
paired family target units controlCounts controlRecipe workCounts workRecipe =
  [ make "control" controlCounts controlRecipe
  , make "work" workCounts workRecipe
  ]
  where
    make role expected recipe =
      CostingCase
        { costingCaseName = family <> "/" <> show units <> "/" <> role
        , costingCaseFamily = family
        , costingCaseUnits = units
        , costingCaseRole = role
        , costingCaseTarget = target
        , costingCaseExpected = expected
        , costingCaseTerm = recipe
        }

-- Do not let full-laziness float a constructed term into 'calibrationCases'.  Inputs to 'defer'
-- are deliberately only small scalars; no term, vector, list, or ByteString is retained here.
defer :: (a -> Term) -> a -> Unit -> Term
defer build input Unit = build input
{-# OPAQUE defer #-}

result :: Term
result = mkConstant @Integer () 0

captureBinder :: UPLC.NamedDeBruijn
captureBinder = UPLC.NamedDeBruijn "capture" (UPLC.Index 0)

matchChain
  :: Integer
  -> Term
  -> DefaultBuiltinPattern
  -> (Term -> Term)
  -> Term
matchChain depth scrutinee pat makeHandler =
  foldr
    ( \_ continuation ->
        UPLC.Match () scrutinee $ Vector.singleton (pat, makeHandler continuation)
    )
    result
    [1 .. depth]

buildIntegerCaseChain :: Integer -> Term
buildIntegerCaseChain depth =
  let scrutinee = mkConstant @Integer () 0
   in foldr
        (\_ continuation -> UPLC.Case () scrutinee $ Vector.singleton continuation)
        result
        [1 .. depth]

buildIntegerMatchChain :: Integer -> Term
buildIntegerMatchChain depth =
  matchChain depth (mkConstant @Integer () 0) (DefaultPatternInteger 0) id

buildAlternativesControl :: Integer -> Term
buildAlternativesControl _ =
  UPLC.Match
    ()
    (mkConstant @Integer () 0)
    (Vector.singleton (DefaultPatternWildcard, result))

buildRejectedAlternatives :: Integer -> Term
buildRejectedAlternatives rejected =
  UPLC.Match () (mkConstant @Integer () 0) $
    Vector.replicate
      (fromIntegral rejected)
      (DefaultPatternInteger 1, result)
      <> Vector.singleton (DefaultPatternWildcard, result)

buildListFields :: Bool -> Integer -> Term
buildListFields work width =
  let values = replicate (fromIntegral width) (0 :: Integer)
      fields =
        if work
          then Vector.replicate (fromIntegral width) DefaultPatternFieldWildcard
          else Vector.empty
      pat = if work then DefaultPatternList DefaultPatternFieldsExact fields else DefaultPatternWildcard
   in oneMatch (mkConstant @[Integer] () values) pat result

buildDataListFields :: Bool -> Integer -> Term
buildDataListFields work width =
  let values = PLC.List $ replicate (fromIntegral width) (PLC.I 0)
      fields =
        if work
          then Vector.replicate (fromIntegral width) DefaultPatternFieldWildcard
          else Vector.empty
      pat =
        if work
          then DefaultPatternDataList DefaultPatternFieldsExact fields
          else DefaultPatternWildcard
   in oneMatch (mkConstant @PLC.Data () values) pat result

buildDataConstrFields :: Bool -> Integer -> Term
buildDataConstrFields work width =
  let values = PLC.Constr 0 $ replicate (fromIntegral width) (PLC.I 0)
      fields =
        if work
          then Vector.replicate (fromIntegral width) DefaultPatternFieldWildcard
          else Vector.empty
      pat =
        if work
          then DefaultPatternDataConstr 0 DefaultPatternFieldsExact fields
          else DefaultPatternWildcard
   in oneMatch (mkConstant @PLC.Data () values) pat result

buildDataMapFields :: Bool -> Integer -> Term
buildDataMapFields work width =
  let values = PLC.Map $ replicate (fromIntegral width) (PLC.I 0, PLC.I 0)
      fields =
        if work
          then Vector.replicate (fromIntegral width) DefaultPatternFieldWildcard
          else Vector.empty
      pat =
        if work
          then DefaultPatternDataMap DefaultPatternFieldsExact fields
          else DefaultPatternWildcard
   in oneMatch (mkConstant @PLC.Data () values) pat result

buildRootCaptureControl :: Integer -> Term
buildRootCaptureControl depth =
  matchChain depth (mkConstant @Integer () 0) DefaultPatternWildcard id

buildRootCaptureWork :: Integer -> Term
buildRootCaptureWork depth =
  matchChain
    depth
    (mkConstant @Integer () 0)
    DefaultPatternCapture
    (UPLC.LamAbs () captureBinder)

buildFieldCaptureControl :: Integer -> Term
buildFieldCaptureControl width = buildFieldCapture False width False

buildFieldCaptureWork :: Integer -> Term
buildFieldCaptureWork width = buildFieldCapture True width False

buildAbandonedCaptureControl :: Integer -> Term
buildAbandonedCaptureControl width = buildFieldCapture False width True

buildAbandonedCaptureWork :: Integer -> Term
buildAbandonedCaptureWork width = buildFieldCapture True width True

buildFieldCapture :: Bool -> Integer -> Bool -> Term
buildFieldCapture bind width abandon =
  let field = if bind then DefaultPatternFieldBind else DefaultPatternFieldWildcard
      fields = Vector.replicate (fromIntegral width) field
      extra = if abandon then 1 else 0
      values = replicate (fromIntegral $ width + extra) (0 :: Integer)
      handler =
        if bind
          then foldr (const $ UPLC.LamAbs () captureBinder) result [1 .. width]
          else result
      alternatives =
        if abandon
          then
            Vector.fromList
              [ (DefaultPatternList DefaultPatternFieldsExact fields, handler)
              , (DefaultPatternWildcard, result)
              ]
          else Vector.singleton (DefaultPatternList DefaultPatternFieldsExact fields, handler)
   in UPLC.Match () (mkConstant @[Integer] () values) alternatives

buildRestControl :: Integer -> Term
buildRestControl _ = buildRestMatch 0

buildRestSuffix :: Integer -> Term
buildRestSuffix = buildRestMatch

buildRestMatch :: Integer -> Term
buildRestMatch suffixWidth =
  oneMatch
    (mkConstant @[Integer] () $ replicate (fromIntegral suffixWidth + 1) 0)
    ( DefaultPatternList
        DefaultPatternFieldsRest
        (Vector.singleton DefaultPatternFieldWildcard)
    )
    result

buildPairControl :: Integer -> Term
buildPairControl depth =
  matchChain
    depth
    (mkConstant @(Integer, Integer) () (0, 0))
    DefaultPatternWildcard
    id

buildPairWork :: Integer -> Term
buildPairWork depth =
  matchChain
    depth
    (mkConstant @(Integer, Integer) () (0, 0))
    (DefaultPatternPair DefaultPatternFieldWildcard DefaultPatternFieldWildcard)
    id

buildDataIControl :: Integer -> Term
buildDataIControl depth =
  matchChain depth (mkConstant @PLC.Data () $ PLC.I 0) DefaultPatternWildcard id

buildDataIWork :: Integer -> Term
buildDataIWork depth =
  matchChain
    depth
    (mkConstant @PLC.Data () $ PLC.I 0)
    (DefaultPatternDataI DefaultPatternFieldWildcard)
    id

buildDataBControl :: Integer -> Term
buildDataBControl depth =
  matchChain depth (mkConstant @PLC.Data () $ PLC.B BS.empty) DefaultPatternWildcard id

buildDataBWork :: Integer -> Term
buildDataBWork depth =
  matchChain
    depth
    (mkConstant @PLC.Data () $ PLC.B BS.empty)
    (DefaultPatternDataB DefaultPatternFieldWildcard)
    id

buildByteStringControl :: Integer -> Term
buildByteStringControl chunks =
  let expected = bytesForChunks chunks
   in oneMatch
        (mkConstant @BS.ByteString () $ copyByteString expected)
        DefaultPatternWildcard
        result

buildByteStringWork :: Integer -> Term
buildByteStringWork chunks =
  let expected = bytesForChunks chunks
   in oneMatch
        (mkConstant @BS.ByteString () $ copyByteString expected)
        (DefaultPatternByteString expected)
        result

bytesForChunks :: Integer -> BS.ByteString
bytesForChunks chunks = BS.replicate (8 * fromIntegral chunks) 0x5a

-- Ensure the pattern and scrutinee do not share the same ByteString payload.  Pointer identity
-- would make an equality benchmark fail to exercise its charged chunks.
copyByteString :: BS.ByteString -> BS.ByteString
copyByteString = BS.copy
{-# OPAQUE copyByteString #-}

oneMatch :: Term -> DefaultBuiltinPattern -> Term -> Term
oneMatch scrutinee pat handler =
  UPLC.Match () scrutinee $ Vector.singleton (pat, handler)
