{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Main where

import Cardano.Ledger.Allegra (AllegraEra)
import Cardano.Ledger.Core
import Cardano.Ledger.Mary (MaryEra)
import Cardano.Ledger.Shelley.Rules (ShelleyLEDGER)
import qualified Cardano.Protocol.TPraos.Rules.Tickn as TPraos
import Data.Proxy (Proxy (..))
import System.Environment (lookupEnv)
import Test.Cardano.Ledger.Allegra.ScriptTranslation (testScriptPostTranslation)
import Test.Cardano.Ledger.Allegra.Translation (allegraTranslationTests)
import Test.Cardano.Ledger.AllegraEraGen ()
import Test.Cardano.Ledger.Mary.Examples.MultiAssets (multiAssetsExample)
import Test.Cardano.Ledger.Mary.Golden (goldenScaledMinDeposit)
import Test.Cardano.Ledger.Mary.Translation (maryTranslationTests)
import Test.Cardano.Ledger.Mary.Value (valTests)
import Test.Cardano.Ledger.MaryEraGen ()
import qualified Test.Cardano.Ledger.Shelley.PropertyTests as Shelley (commonTests)
import qualified Test.Cardano.Ledger.Shelley.Rules.AdaPreservation as AdaPreservation
import qualified Test.Cardano.Ledger.Shelley.Rules.ClassifyTraces as ClassifyTraces (
  onlyValidChainSignalsAreGenerated,
  relevantCasesAreCovered,
 )
import qualified Test.Cardano.Ledger.Shelley.Rules.IncrementalStake as IncrementalStake
import qualified Test.Cardano.Ledger.Shelley.WitVKeys as WitVKeys (tests)
import qualified Test.Cardano.Ledger.ShelleyMA.Serialisation as Serialisation
import Test.QuickCheck (Args (maxSuccess), stdArgs)
import Test.Tasty
import qualified Test.Tasty.QuickCheck as TQC

type instance EraRule "TICKN" MaryEra = TPraos.TICKN

type instance EraRule "TICKN" AllegraEra = TPraos.TICKN

main :: IO ()
main = do
  nightly <- lookupEnv "NIGHTLY"
  defaultMain $ case nightly of
    Nothing -> defaultTests
    Just _ -> nightlyTests

defaultTests :: TestTree
defaultTests =
  testGroup
    "ShelleyMA Ledger Tests"
    [ allegraTests
    , maryTests
    , testGroup
        "Mixed MA Ledger Tests"
        [ Serialisation.tests
        ]
    ]

allegraTests :: TestTree
allegraTests =
  testGroup
    "Allegra Ledger Tests"
    [ allegraTranslationTests
    , ( localOption
          (TQC.QuickCheckMaxRatio 50)
          (ClassifyTraces.relevantCasesAreCovered @AllegraEra (maxSuccess stdArgs))
      )
    , AdaPreservation.tests @AllegraEra @(ShelleyLEDGER AllegraEra) (maxSuccess stdArgs)
    , ClassifyTraces.onlyValidChainSignalsAreGenerated @AllegraEra
    , WitVKeys.tests
    , testScriptPostTranslation
    ]

maryTests :: TestTree
maryTests =
  testGroup
    "Mary Ledger Tests"
    [ maryTranslationTests
    , valTests
    , multiAssetsExample
    , goldenScaledMinDeposit
    ]

nightlyTests :: TestTree
nightlyTests =
  testGroup
    "ShelleyMA Ledger - nightly"
    [ testGroup
        "Allegra Ledger - nightly"
        ( Shelley.commonTests @AllegraEra @(ShelleyLEDGER AllegraEra)
            ++ [IncrementalStake.incrStakeComparisonTest (Proxy :: Proxy AllegraEra)]
        )
    , testGroup
        "Mary Ledger - nightly"
        ( Shelley.commonTests @MaryEra @(ShelleyLEDGER MaryEra)
            ++ [IncrementalStake.incrStakeComparisonTest (Proxy :: Proxy MaryEra)]
        )
    ]
