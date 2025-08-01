{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Test.Cardano.Ledger.Conway.Spec (spec) where

import Cardano.Ledger.Alonzo.Plutus.Context (EraPlutusContext (..), EraPlutusTxInfo)
import Cardano.Ledger.Alonzo.Rules (
  AlonzoUtxoPredFailure,
  AlonzoUtxosPredFailure,
  AlonzoUtxowPredFailure,
 )
import Cardano.Ledger.Babbage.Rules (BabbageUtxoPredFailure, BabbageUtxowPredFailure)
import Cardano.Ledger.Babbage.TxInfo (BabbageContextError)
import Cardano.Ledger.BaseTypes (Inject)
import Cardano.Ledger.Binary (DecCBOR)
import Cardano.Ledger.Conway.Core (
  AlonzoEraScript (..),
  AsIx,
  EraRule,
  EraTx (..),
  EraTxBody (..),
  EraTxCert (..),
  EraTxWits (..),
  InjectRuleEvent,
  InjectRuleFailure,
  SafeToHash,
 )
import Cardano.Ledger.Conway.Rules (
  ConwayBbodyPredFailure,
  ConwayCertsPredFailure,
  ConwayDelegPredFailure,
  ConwayEpochEvent,
  ConwayGovCertPredFailure,
  ConwayGovPredFailure,
  ConwayHardForkEvent,
  ConwayLedgerPredFailure,
  ConwayNewEpochEvent,
  ConwayUtxoPredFailure,
 )
import Cardano.Ledger.Conway.TxCert (ConwayTxCert)
import Cardano.Ledger.Conway.TxInfo (ConwayContextError)
import Cardano.Ledger.Plutus (Language (..))
import Cardano.Ledger.Shelley.API (ApplyTx)
import Cardano.Ledger.Shelley.LedgerState (StashedAVVMAddresses)
import Cardano.Ledger.Shelley.Rules (
  ShelleyDelegPredFailure,
  ShelleyUtxoPredFailure,
  ShelleyUtxowPredFailure,
 )
import Control.State.Transition (STS (..))
import Data.Typeable (Typeable)
import qualified Test.Cardano.Ledger.Alonzo.Binary.CostModelsSpec as CostModelsSpec
import qualified Test.Cardano.Ledger.Alonzo.Binary.TxWitsSpec as TxWitsSpec
import Test.Cardano.Ledger.Common
import qualified Test.Cardano.Ledger.Conway.Binary.Regression as Regression
import qualified Test.Cardano.Ledger.Conway.BinarySpec as Binary
import qualified Test.Cardano.Ledger.Conway.CommitteeRatifySpec as CommitteeRatify
import qualified Test.Cardano.Ledger.Conway.DRepRatifySpec as DRepRatify
import qualified Test.Cardano.Ledger.Conway.GoldenSpec as Golden
import qualified Test.Cardano.Ledger.Conway.Imp as Imp
import Test.Cardano.Ledger.Conway.ImpTest (ConwayEraImp)
import qualified Test.Cardano.Ledger.Conway.Proposals as Proposals
import qualified Test.Cardano.Ledger.Conway.SPORatifySpec as SPORatifySpec
import qualified Test.Cardano.Ledger.Conway.TxInfoSpec as TxInfo
import Test.Cardano.Ledger.Core.Binary.RoundTrip (RuleListEra)
import Test.Cardano.Ledger.Core.JSON (roundTripJsonEraSpec)

spec ::
  forall era.
  ( EraPlutusTxInfo PlutusV2 era
  , EraPlutusTxInfo PlutusV3 era
  , RuleListEra era
  , ConwayEraImp era
  , ApplyTx era
  , DecCBOR (TxWits era)
  , DecCBOR (TxBody era)
  , DecCBOR (Tx era)
  , Arbitrary (PlutusPurpose AsIx era)
  , SafeToHash (TxWits era)
  , StashedAVVMAddresses era ~ ()
  , Inject (BabbageContextError era) (ContextError era)
  , Inject (ConwayContextError era) (ContextError era)
  , Event (EraRule "EPOCH" era) ~ ConwayEpochEvent era
  , Event (EraRule "NEWEPOCH" era) ~ ConwayNewEpochEvent era
  , Event (EraRule "HARDFORK" era) ~ ConwayHardForkEvent era
  , InjectRuleFailure "BBODY" ConwayBbodyPredFailure era
  , InjectRuleFailure "LEDGER" ConwayGovPredFailure era
  , InjectRuleFailure "LEDGER" ConwayCertsPredFailure era
  , InjectRuleFailure "LEDGER" BabbageUtxoPredFailure era
  , InjectRuleFailure "LEDGER" BabbageUtxowPredFailure era
  , InjectRuleFailure "LEDGER" AlonzoUtxoPredFailure era
  , InjectRuleFailure "LEDGER" AlonzoUtxosPredFailure era
  , InjectRuleFailure "LEDGER" AlonzoUtxowPredFailure era
  , InjectRuleFailure "LEDGER" ShelleyDelegPredFailure era
  , InjectRuleFailure "LEDGER" ShelleyUtxoPredFailure era
  , InjectRuleFailure "LEDGER" ShelleyUtxowPredFailure era
  , InjectRuleFailure "LEDGER" ConwayDelegPredFailure era
  , InjectRuleFailure "LEDGER" ConwayGovCertPredFailure era
  , InjectRuleFailure "LEDGER" ConwayLedgerPredFailure era
  , InjectRuleFailure "LEDGER" ConwayUtxoPredFailure era
  , InjectRuleEvent "TICK" ConwayEpochEvent era
  , NFData (Event (EraRule "ENACT" era))
  , ToExpr (Event (EraRule "ENACT" era))
  , Eq (Event (EraRule "ENACT" era))
  , Typeable (Event (EraRule "ENACT" era))
  , TxCert era ~ ConwayTxCert era
  ) =>
  Spec
spec =
  describe "Conway features" $ do
    Golden.spec @era
    Proposals.spec @era
    Binary.spec @era
    DRepRatify.spec @era
    CommitteeRatify.spec @era
    SPORatifySpec.spec @era
    roundTripJsonEraSpec @era
    describe "Imp" $
      Imp.spec @era
    describe "CostModels" $ do
      CostModelsSpec.spec @era
    describe "TxWits" $ do
      TxWitsSpec.spec @era
    Regression.spec @era
    TxInfo.spec @era
