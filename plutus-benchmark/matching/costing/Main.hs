{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}

-- | Criterion driver and exact dynamic-count validator for shallow Match calibration.
module Main (main) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Criterion.Main (Benchmark, bench, defaultMain, env, whnf)
import Data.List (find, intercalate)
import PlutusBenchmark.Matching.Costing
  ( CostingCase (..)
  , MatchStepCounts (..)
  , Unit (..)
  , calibrationCases
  )
import PlutusCore qualified as Core
import PlutusCore.Evaluation.Machine.ExBudget (ExBudget (..))
import PlutusCore.Evaluation.Machine.ExBudgetingDefaults (defaultCekParametersForTesting)
import PlutusCore.Evaluation.Machine.MachineParameters
  ( MachineParameters (..)
  , MachineVariantParameters (..)
  )
import System.Environment (lookupEnv)
import System.Mem (performGC)
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.Evaluation.Machine.Cek qualified as Cek
import UntypedPlutusCore.Evaluation.Machine.Cek.CekMachineCosts (unitCekMachineCosts)

data Mode = Cpu | Metadata

data MatchStepBudgets = MatchStepBudgets
  { matchBudget :: !ExBudget
  , matchWorkBudget :: !ExBudget
  , caseBudget :: !ExBudget
  , lamAbsBudget :: !ExBudget
  }
  deriving stock (Eq, Show)

instance Semigroup MatchStepBudgets where
  MatchStepBudgets m w c l <> MatchStepBudgets m' w' c' l' =
    MatchStepBudgets (m <> m') (w <> w') (c <> c') (l <> l')

instance Monoid MatchStepBudgets where
  mempty = MatchStepBudgets mempty mempty mempty mempty

type MatchParameters =
  MachineParameters
    Cek.CekMachineCosts
    Core.DefaultFun
    (Cek.CekValue Core.DefaultUni Core.DefaultFun ())

type Term =
  UPLC.Term UPLC.NamedDeBruijn Core.DefaultUni Core.DefaultFun ()

main :: IO ()
main = do
  mode <- parseMode =<< lookupEnv "MATCHING_COSTING_MODE"
  case mode of
    Metadata -> printMetadata calibrationCases
    Cpu -> do
      selected <- selectCases calibrationCases =<< lookupEnv "MATCHING_COSTING_CASE"
      validateCases selected
      -- Validation constructs and drops one term at a time.  Do not carry its last environment
      -- into Criterion's first sample.
      performGC
      defaultMain $ fmap benchmarkCase selected

parseMode :: Maybe String -> IO Mode
parseMode = \case
  Nothing -> pure Cpu
  Just "cpu" -> pure Cpu
  Just "metadata" -> pure Metadata
  Just other ->
    ioError . userError $
      "unknown MATCHING_COSTING_MODE " <> show other <> "; expected cpu or metadata"

selectCases :: [CostingCase] -> Maybe String -> IO [CostingCase]
selectCases cases = \case
  Nothing -> pure cases
  Just requested -> case find ((== requested) . costingCaseName) cases of
    Just selected -> pure [selected]
    Nothing ->
      ioError . userError $
        "unknown MATCHING_COSTING_CASE "
          <> show requested
          <> "; use MATCHING_COSTING_MODE=metadata to list names"

benchmarkCase :: CostingCase -> Benchmark
benchmarkCase costingCase =
  env (evaluate . force $ costingCaseTerm costingCase Unit) $ \ ~term ->
    bench (costingCaseName costingCase) $
      whnf evaluateTermWithMatch term

evaluateTermWithMatch :: Term -> ()
evaluateTermWithMatch =
  either (error . show) (const ())
    . Cek.cekResultToEither
    . Cek._cekReportResult
    . Cek.runCekDeBruijn matchParameters Cek.restrictingEnormous Cek.noEmitter

matchParameters :: MatchParameters
matchParameters = defaultCekParametersForTesting

unitMatchParameters :: MatchParameters
unitMatchParameters =
  case matchParameters of
    MachineParameters caser matcher (MachineVariantParameters _ runtime) ->
      MachineParameters
        caser
        matcher
        (MachineVariantParameters unitCekMachineCosts runtime)

matchStepBudgeting
  :: Cek.ExBudgetMode MatchStepBudgets Core.DefaultUni Core.DefaultFun
matchStepBudgeting =
  Cek.monoidalBudgeting $ \category budget -> case category of
    Cek.BStep Cek.BMatch -> mempty {matchBudget = budget}
    Cek.BStep Cek.BMatchWork -> mempty {matchWorkBudget = budget}
    Cek.BStep Cek.BCase -> mempty {caseBudget = budget}
    Cek.BStep Cek.BLamAbs -> mempty {lamAbsBudget = budget}
    _ -> mempty

validateCases :: [CostingCase] -> IO ()
validateCases cases =
  forM_ cases $ \costingCase -> do
    term <- evaluate . force $ costingCaseTerm costingCase Unit
    let report =
          Cek.runCekDeBruijn
            unitMatchParameters
            matchStepBudgeting
            Cek.noEmitter
            term
    case Cek.cekResultToEither $ Cek._cekReportResult report of
      Left err ->
        errorWithoutStackTrace $
          "costing case " <> costingCaseName costingCase <> " failed: " <> show err
      Right _ ->
        let expected = budgetsFromCounts $ costingCaseExpected costingCase
            actual = Cek._cekReportCost report
         in if actual == expected
              then pure ()
              else
                errorWithoutStackTrace $
                  "costing case "
                    <> costingCaseName costingCase
                    <> " has wrong CEK counts: expected "
                    <> show expected
                    <> ", got "
                    <> show actual

budgetsFromCounts :: MatchStepCounts -> MatchStepBudgets
budgetsFromCounts (MatchStepCounts m w c l) =
  MatchStepBudgets (unit m) (unit w) (unit c) (unit l)
  where
    unit count = ExBudget (fromIntegral count) 0

printMetadata :: [CostingCase] -> IO ()
printMetadata cases = do
  putStrLn "name,family,units,role,target,bmatch,bmatch_work,bcase,blamabs"
  mapM_ (putStrLn . metadataCsv) cases

metadataCsv :: CostingCase -> String
metadataCsv costingCase =
  let expected = costingCaseExpected costingCase
   in intercalate
        ","
        [ costingCaseName costingCase
        , costingCaseFamily costingCase
        , show $ costingCaseUnits costingCase
        , costingCaseRole costingCase
        , costingCaseTarget costingCase
        , show $ matchCount expected
        , show $ matchWorkCount expected
        , show $ caseCount expected
        , show $ lamAbsCount expected
        ]
