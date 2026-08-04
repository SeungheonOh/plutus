{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{-| Shallow-Match side of the nested-Data comparison.

Only the selected recipe is constructed.  List mode constructs no terms, CPU mode puts one fully
forced term in Criterion's environment, and each CPU case is intended to run in its own process. -}
module Main (main) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Criterion.Main (bench, defaultMain, env, whnf)
import Data.Functor.Identity (runIdentity)
import Data.List (find, intercalate)
import Data.SatInt (fromSatInt)
import Data.Vector qualified as Vector
import PlutusCore qualified as Core
import PlutusCore.Data qualified as PLCData
import PlutusCore.Default
  ( DefaultBuiltinPattern (..)
  , DefaultPatternField (..)
  , DefaultPatternFieldEnd (..)
  )
import PlutusCore.Evaluation.Machine.ExBudget (ExBudget (..))
import PlutusCore.Evaluation.Machine.ExBudgetingDefaults (defaultCekParametersForTesting)
import PlutusCore.Evaluation.Machine.ExMemory (ExCPU (..), ExMemory (..))
import PlutusCore.Evaluation.Machine.MachineParameters
  ( MachineParameters (..)
  , MachineVariantParameters (..)
  )
import PlutusCore.MkPlc (mkConstant)
import System.Environment (lookupEnv)
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.Evaluation.Machine.Cek qualified as Cek
import UntypedPlutusCore.Evaluation.Machine.Cek.CekMachineCosts
  ( CekMachineCostsBase (..)
  )

data Mode = ListCases | Cpu | Budget

data Family
  = ConstrChain
  | ListChain
  | AlternatingChain
  deriving stock (Eq, Show)

data Layer = ConstrLayer | ListLayer | MapLayer

data Unit = Unit

data ComparisonCase = ComparisonCase
  { comparisonCaseId :: !String
  , comparisonCaseFamily :: !Family
  , comparisonCaseDepth :: !Int
  , comparisonCaseWidth :: !Int
  , comparisonCaseTerm :: !(Unit -> Term)
  }

data BudgetTally = BudgetTally
  { totalBudget :: !ExBudget
  , matchBudget :: !ExBudget
  , matchWorkBudget :: !ExBudget
  }
  deriving stock (Eq, Show)

instance Semigroup BudgetTally where
  BudgetTally total match work <> BudgetTally total' match' work' =
    BudgetTally (total <> total') (match <> match') (work <> work')

instance Monoid BudgetTally where
  mempty = BudgetTally mempty mempty mempty

type MatchParameters =
  MachineParameters
    Cek.CekMachineCosts
    Core.DefaultFun
    (Cek.CekValue Core.DefaultUni Core.DefaultFun ())

type Term =
  UPLC.Term UPLC.NamedDeBruijn Core.DefaultUni Core.DefaultFun ()

main :: IO ()
main = do
  mode <- parseMode =<< lookupEnv "MATCHING_BENCH_MODE"
  case mode of
    ListCases -> printCases
    Cpu -> selectCase >>= runCpu
    Budget -> selectCase >>= runBudget

parseMode :: Maybe String -> IO Mode
parseMode = \case
  Nothing -> pure Cpu
  Just "cpu" -> pure Cpu
  Just "budget" -> pure Budget
  Just "list" -> pure ListCases
  Just other ->
    ioError . userError $
      "unknown MATCHING_BENCH_MODE " <> show other <> "; expected list, cpu, or budget"

selectCase :: IO ComparisonCase
selectCase = do
  requested <- lookupEnv "MATCHING_BENCH_CASE"
  case requested >>= \caseId -> find ((== caseId) . comparisonCaseId) comparisonCases of
    Just selected -> pure selected
    Nothing ->
      ioError . userError $
        case requested of
          Nothing -> "MATCHING_BENCH_CASE must name exactly one comparison case"
          Just bad ->
            "unknown MATCHING_BENCH_CASE "
              <> show bad
              <> "; use MATCHING_BENCH_MODE=list to list case IDs"

printCases :: IO ()
printCases = do
  putStrLn "case_id,family,depth,width"
  mapM_ (putStrLn . caseMetadataCsv) comparisonCases

runCpu :: ComparisonCase -> IO ()
runCpu selected = do
  let !parameters = defaultCekParametersForTesting
  defaultMain
    [ env (buildSelected selected) $ \ ~term ->
        bench ("shallow/" <> comparisonCaseId selected) $
          whnf (evaluateToInteger parameters) term
    ]

runBudget :: ComparisonCase -> IO ()
runBudget selected = do
  term <- buildSelected selected
  let !parameters = defaultCekParametersForTesting
      !report =
        Cek.runCekDeBruijn
          parameters
          comparisonBudgeting
          Cek.noEmitter
          term
  result <- evaluate $ verifyResult (Cek._cekReportResult report)
  if result /= 42
    then errorWithoutStackTrace $ "comparison case returned " <> show result <> ", expected 42"
    else do
      let tally = Cek._cekReportCost report
          (cpu, memory) = budgetParts $ totalBudget tally
          (matchCost, matchWorkCost) = patternCosts parameters
          matchSteps = budgetQuanta "BMatch" matchCost $ matchBudget tally
          matchWorkSteps = budgetQuanta "BMatchWork" matchWorkCost $ matchWorkBudget tally
      putStrLn
        "implementation,case_id,family,depth,width,cpu,memory,match_steps,match_work_steps,pattern_steps,structural_steps,next_steps"
      putStrLn . intercalate "," $
        [ "shallow"
        , comparisonCaseId selected
        , familyId $ comparisonCaseFamily selected
        , show $ comparisonCaseDepth selected
        , show $ comparisonCaseWidth selected
        , show cpu
        , show memory
        , show matchSteps
        , show matchWorkSteps
        , "0"
        , "0"
        , "0"
        ]

buildSelected :: ComparisonCase -> IO Term
buildSelected selected = evaluate . force $ comparisonCaseTerm selected Unit

evaluateToInteger :: MatchParameters -> Term -> Integer
evaluateToInteger parameters =
  verifyResult
    . Cek._cekReportResult
    . Cek.runCekDeBruijn parameters Cek.restrictingEnormous Cek.noEmitter

verifyResult
  :: Cek.CekResult Core.NamedDeBruijn Core.DefaultUni Core.DefaultFun
  -> Integer
verifyResult = \case
  Cek.CekSuccessConstant (Core.Some (Core.ValueOf Core.DefaultUniInteger result))
    | result == 42 -> result
    | otherwise ->
        errorWithoutStackTrace $ "comparison case returned " <> show result <> ", expected 42"
  failure@(Cek.CekFailure _) -> case Cek.cekResultToEither failure of
    Left err -> errorWithoutStackTrace $ "comparison case evaluation failed: " <> show err
    Right _ -> errorWithoutStackTrace "impossible successful conversion of a CEK failure"
  Cek.CekSuccessConstant _ ->
    errorWithoutStackTrace "comparison case returned a non-integer constant"
  Cek.CekSuccessNonConstant _ ->
    errorWithoutStackTrace "comparison case returned a non-constant term"

comparisonBudgeting
  :: Cek.ExBudgetMode BudgetTally Core.DefaultUni Core.DefaultFun
comparisonBudgeting =
  Cek.monoidalBudgeting $ \category budget ->
    case category of
      Cek.BStep Cek.BMatch -> (withTotal budget) {matchBudget = budget}
      Cek.BStep Cek.BMatchWork -> (withTotal budget) {matchWorkBudget = budget}
      _ -> withTotal budget
  where
    withTotal budget = mempty {totalBudget = budget}

patternCosts :: MatchParameters -> (ExBudget, ExBudget)
patternCosts (MachineParameters _ _ (MachineVariantParameters costs _)) =
  ( runIdentity $ cekMatchCost costs
  , runIdentity $ cekMatchWorkCost costs
  )

budgetQuanta :: String -> ExBudget -> ExBudget -> Integer
budgetQuanta category quantum total =
  let (quantumCpu, quantumMemory) = budgetParts quantum
      (totalCpu, totalMemory) = budgetParts total
      (count, cpuRemainder) = totalCpu `quotRem` quantumCpu
   in if quantumCpu <= 0
        then errorWithoutStackTrace $ category <> " has a non-positive production CPU quantum"
        else
          if cpuRemainder == 0 && totalMemory == count * quantumMemory
            then count
            else
              errorWithoutStackTrace $
                category
                  <> " production tally is not an integral number of quanta: quantum="
                  <> show quantum
                  <> ", total="
                  <> show total

budgetParts :: ExBudget -> (Integer, Integer)
budgetParts (ExBudget (ExCPU cpu) (ExMemory memory)) =
  (fromSatInt cpu, fromSatInt memory)

comparisonCases :: [ComparisonCase]
comparisonCases =
  [ comparisonCase family depth width
  | family <- [ConstrChain, ListChain, AlternatingChain]
  , depth <- [1, 4, 16]
  , width <- [1, 4, 16]
  ]

comparisonCase :: Family -> Int -> Int -> ComparisonCase
comparisonCase family depth width =
  ComparisonCase
    { comparisonCaseId = familyId family <> "-d" <> show depth <> "-w" <> show width
    , comparisonCaseFamily = family
    , comparisonCaseDepth = depth
    , comparisonCaseWidth = width
    , comparisonCaseTerm = defer buildShallowCase (family, depth, width)
    }

familyId :: Family -> String
familyId = \case
  ConstrChain -> "constr"
  ListChain -> "list"
  AlternatingChain -> "alternating"

caseMetadataCsv :: ComparisonCase -> String
caseMetadataCsv comparisonCase' =
  intercalate
    ","
    [ comparisonCaseId comparisonCase'
    , familyId $ comparisonCaseFamily comparisonCase'
    , show $ comparisonCaseDepth comparisonCase'
    , show $ comparisonCaseWidth comparisonCase'
    ]

-- Keep full-laziness from floating the selected term into the recipe table.
defer :: (a -> Term) -> a -> Unit -> Term
defer build input Unit = build input
{-# OPAQUE defer #-}

buildShallowCase :: (Family, Int, Int) -> Term
buildShallowCase (family, depth, width)
  | depth < 1 = errorWithoutStackTrace "comparison depth must be positive"
  | width < 1 = errorWithoutStackTrace "comparison width must be positive"
  | otherwise =
      deconstruct family 0 depth width $
        mkConstant @PLCData.Data () (nestedValue family 0 depth width)

nestedValue :: Family -> Int -> Int -> Int -> PLCData.Data
nestedValue family level remaining width
  | remaining == 0 = PLCData.I 42
  | otherwise =
      let child = nestedValue family (level + 1) (remaining - 1) width
       in case layerAt family level of
            ConstrLayer ->
              PLCData.Constr 0 $ replicate (width - 1) (PLCData.I 0) <> [child]
            ListLayer ->
              PLCData.List $ replicate (width - 1) (PLCData.I 0) <> [child]
            MapLayer ->
              PLCData.Map $
                replicate (width - 1) (PLCData.I 0, PLCData.I 0)
                  <> [(PLCData.I 0, child)]

deconstruct :: Family -> Int -> Int -> Int -> Term -> Term
deconstruct family level remaining width scrutinee
  | remaining == 0 =
      UPLC.Match
        ()
        scrutinee
        ( Vector.singleton
            ( DefaultPatternDataI DefaultPatternFieldBind
            , UPLC.LamAbs () valueBinder $ UPLC.Var () valueReference
            )
        )
  | otherwise =
      -- This project enables @Strict@.  Keep the recursive term branch-local: a strict @where@
      -- binding would also be forced by the terminal guard and recurse through negative depths.
      let fields =
            Vector.replicate (width - 1) DefaultPatternFieldWildcard
              `Vector.snoc` DefaultPatternFieldBind
          constrPattern = DefaultPatternDataConstr 0 DefaultPatternFieldsExact fields
          listPattern = DefaultPatternDataList DefaultPatternFieldsExact fields
          mapPattern = DefaultPatternDataMap DefaultPatternFieldsExact fields
          pairPattern = DefaultPatternPair DefaultPatternFieldWildcard DefaultPatternFieldBind
          nextValue =
            deconstruct
              family
              (level + 1)
              (remaining - 1)
              width
              (UPLC.Var () valueReference)
          structuralMatch pat =
            UPLC.Match
              ()
              scrutinee
              (Vector.singleton (pat, UPLC.LamAbs () valueBinder nextValue))
       in case layerAt family level of
            ConstrLayer -> structuralMatch constrPattern
            ListLayer -> structuralMatch listPattern
            MapLayer ->
              UPLC.Match
                ()
                scrutinee
                ( Vector.singleton
                    ( mapPattern
                    , UPLC.LamAbs () fieldBinder $
                        UPLC.Match
                          ()
                          (UPLC.Var () fieldReference)
                          ( Vector.singleton
                              ( pairPattern
                              , UPLC.LamAbs () valueBinder nextValue
                              )
                          )
                    )
                )

layerAt :: Family -> Int -> Layer
layerAt family level = case family of
  ConstrChain -> ConstrLayer
  ListChain -> ListLayer
  AlternatingChain -> case level `mod` 3 of
    0 -> ConstrLayer
    1 -> ListLayer
    _ -> MapLayer

fieldBinder :: UPLC.NamedDeBruijn
fieldBinder = UPLC.NamedDeBruijn "field" (UPLC.Index 0)

valueBinder :: UPLC.NamedDeBruijn
valueBinder = UPLC.NamedDeBruijn "value" (UPLC.Index 0)

fieldReference :: UPLC.NamedDeBruijn
fieldReference = UPLC.NamedDeBruijn "field" (UPLC.Index 1)

valueReference :: UPLC.NamedDeBruijn
valueReference = UPLC.NamedDeBruijn "value" (UPLC.Index 1)
