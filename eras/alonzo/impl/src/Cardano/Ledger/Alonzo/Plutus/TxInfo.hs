{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Alonzo.Plutus.TxInfo (
  AlonzoContextError (..),
  TxOutSource (..),
  transLookupTxOut,
  transTxOut,
  transValidityInterval,
  transSlotToPOSIXTime,
  transPolicyID,
  transAssetName,
  transMultiAsset,
  transMintValue,
  transValue,
  transWithdrawals,
  transDataPair,
  transTxCert,
  transTxCertCommon,
  transPlutusPurpose,
  transTxBodyId,
  transTxBodyCerts,
  transTxBodyWithdrawals,
  transTxBodyReqSignerHashes,
  transTxWitsDatums,

  -- * LgacyPlutusArgs helpers
  toPlutusV1Args,
  toLegacyPlutusArgs,
) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Alonzo.Core
import Cardano.Ledger.Alonzo.Era (AlonzoEra)
import Cardano.Ledger.Alonzo.Plutus.Context
import Cardano.Ledger.Alonzo.Scripts (AlonzoPlutusPurpose (..), PlutusScript (..), toAsItem)
import Cardano.Ledger.Alonzo.TxWits (unTxDatsL)
import Cardano.Ledger.BaseTypes (ProtVer, StrictMaybe (..), strictMaybeToMaybe)
import Cardano.Ledger.Binary (DecCBOR (..), EncCBOR (..))
import Cardano.Ledger.Binary.Coders (
  Decode (..),
  Encode (..),
  decode,
  encode,
  (!>),
  (<!),
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (
  AssetName (..),
  MaryValue (..),
  MultiAsset (..),
  PolicyID (..),
 )
import Cardano.Ledger.Plutus.Data (Data, getPlutusData)
import Cardano.Ledger.Plutus.Language (
  Language (..),
  LegacyPlutusArgs (..),
  PlutusArgs (..),
  SLanguage (..),
 )
import Cardano.Ledger.Plutus.TxInfo
import Cardano.Ledger.PoolParams (PoolParams (..))
import Cardano.Ledger.Rules.ValidationMode (Inject (..))
import Cardano.Ledger.State (UTxO (..))
import Cardano.Ledger.TxIn (TxIn (..), txInToText)
import Cardano.Ledger.Val (zero)
import Cardano.Slotting.EpochInfo (EpochInfo)
import Cardano.Slotting.Time (SystemStart)
import Control.Arrow (left)
import Control.DeepSeq (NFData)
import Control.Monad (forM, guard)
import Data.Aeson (ToJSON (..), pattern String)
import Data.ByteString.Short as SBS (fromShort)
import Data.Foldable as F (Foldable (..))
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, isNothing, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import GHC.Generics (Generic)
import Lens.Micro ((^.))
import NoThunks.Class (NoThunks)
import qualified PlutusLedgerApi.V1 as PV1

instance EraPlutusTxInfo 'PlutusV1 AlonzoEra where
  toPlutusTxCert _ _ = pure . transTxCert

  toPlutusScriptPurpose proxy pv = transPlutusPurpose proxy pv . hoistPlutusPurpose toAsItem

  toPlutusTxInfo proxy LedgerTxInfo {ltiProtVer, ltiEpochInfo, ltiSystemStart, ltiUTxO, ltiTx} = do
    timeRange <-
      transValidityInterval ltiTx ltiProtVer ltiEpochInfo ltiSystemStart (txBody ^. vldtTxBodyL)
    txInsMaybes <- forM (Set.toList (txBody ^. inputsTxBodyL)) $ \txIn -> do
      txOut <- transLookupTxOut ltiUTxO txIn
      pure $ PV1.TxInInfo (transTxIn txIn) <$> transTxOut txOut
    txCerts <- transTxBodyCerts proxy ltiProtVer txBody
    Right $
      PV1.TxInfo
        { -- A mistake was made in Alonzo of filtering out Byron addresses, so we need to
          -- preserve this behavior by only retaining the Just case:
          PV1.txInfoInputs = catMaybes txInsMaybes
        , PV1.txInfoOutputs = mapMaybe transTxOut $ F.toList (txBody ^. outputsTxBodyL)
        , PV1.txInfoFee = transCoinToValue (txBody ^. feeTxBodyL)
        , PV1.txInfoMint = transMintValue (txBody ^. mintTxBodyL)
        , PV1.txInfoDCert = txCerts
        , PV1.txInfoWdrl = transTxBodyWithdrawals txBody
        , PV1.txInfoValidRange = timeRange
        , PV1.txInfoSignatories = transTxBodyReqSignerHashes txBody
        , PV1.txInfoData = transTxWitsDatums (ltiTx ^. witsTxL)
        , PV1.txInfoId = transTxBodyId txBody
        }
    where
      txBody = ltiTx ^. bodyTxL

  toPlutusArgs = toPlutusV1Args

toPlutusV1Args ::
  EraPlutusTxInfo 'PlutusV1 era =>
  proxy 'PlutusV1 ->
  ProtVer ->
  PV1.TxInfo ->
  PlutusPurpose AsIxItem era ->
  Maybe (Data era) ->
  Data era ->
  Either (ContextError era) (PlutusArgs 'PlutusV1)
toPlutusV1Args proxy pv txInfo scriptPurpose maybeSpendingData redeemerData =
  PlutusV1Args
    <$> toLegacyPlutusArgs proxy pv (PV1.ScriptContext txInfo) scriptPurpose maybeSpendingData redeemerData

toLegacyPlutusArgs ::
  EraPlutusTxInfo l era =>
  proxy l ->
  ProtVer ->
  (PlutusScriptPurpose l -> PlutusScriptContext l) ->
  PlutusPurpose AsIxItem era ->
  Maybe (Data era) ->
  Data era ->
  Either (ContextError era) (LegacyPlutusArgs l)
toLegacyPlutusArgs proxy pv mkScriptContext scriptPurpose maybeSpendingData redeemerData = do
  scriptContext <- mkScriptContext <$> toPlutusScriptPurpose proxy pv scriptPurpose
  let redeemer = getPlutusData redeemerData
  pure $ case maybeSpendingData of
    Nothing -> LegacyPlutusArgs2 redeemer scriptContext
    Just spendingData -> LegacyPlutusArgs3 (getPlutusData spendingData) redeemer scriptContext

instance EraPlutusContext AlonzoEra where
  type ContextError AlonzoEra = AlonzoContextError AlonzoEra
  newtype TxInfoResult AlonzoEra
    = AlonzoTxInfoResult (Either (ContextError AlonzoEra) (PlutusTxInfo 'PlutusV1))

  mkSupportedLanguage = \case
    PlutusV1 -> Just $ SupportedLanguage SPlutusV1
    _lang -> Nothing

  mkTxInfoResult = AlonzoTxInfoResult . toPlutusTxInfo SPlutusV1

  lookupTxInfoResult SPlutusV1 (AlonzoTxInfoResult tirPlutusV1) = tirPlutusV1
  lookupTxInfoResult slang _ = lookupTxInfoResultImpossible slang

  mkPlutusWithContext (AlonzoPlutusV1 p) = toPlutusWithContext (Left p)

data AlonzoContextError era
  = TranslationLogicMissingInput !TxIn
  | TimeTranslationPastHorizon !Text
  deriving (Eq, Show, Generic)

instance NoThunks (AlonzoContextError era)

instance Era era => NFData (AlonzoContextError era)

instance Era era => EncCBOR (AlonzoContextError era) where
  encCBOR = \case
    TranslationLogicMissingInput txIn ->
      encode $ Sum (TranslationLogicMissingInput @era) 1 !> To txIn
    TimeTranslationPastHorizon err ->
      encode $ Sum (TimeTranslationPastHorizon @era) 7 !> To err

instance Era era => DecCBOR (AlonzoContextError era) where
  decCBOR = decode $ Summands "ContextError" $ \case
    1 -> SumD (TranslationLogicMissingInput @era) <! From
    7 -> SumD (TimeTranslationPastHorizon @era) <! From
    n -> Invalid n

instance ToJSON (AlonzoContextError era) where
  toJSON = \case
    TranslationLogicMissingInput txin ->
      String $ "Transaction input does not exist in the UTxO: " <> txInToText txin
    TimeTranslationPastHorizon msg ->
      String $ "Time translation requested past the horizon: " <> msg

transLookupTxOut ::
  forall era a.
  Inject (AlonzoContextError era) a =>
  UTxO era ->
  TxIn ->
  Either a (TxOut era)
transLookupTxOut (UTxO utxo) txIn =
  case Map.lookup txIn utxo of
    Nothing -> Left $ inject $ TranslationLogicMissingInput @era txIn
    Just txOut -> Right txOut

-- | This is a variant of `slotToPOSIXTime` that works with `Either` and `Inject`
transSlotToPOSIXTime ::
  forall era a.
  Inject (AlonzoContextError era) a =>
  EpochInfo (Either Text) ->
  SystemStart ->
  SlotNo ->
  Either a PV1.POSIXTime
transSlotToPOSIXTime epochInfo systemStart =
  left (inject . TimeTranslationPastHorizon @era) . slotToPOSIXTime epochInfo systemStart

-- | Translate a validity interval to POSIX time
transValidityInterval ::
  forall proxy era a.
  Inject (AlonzoContextError era) a =>
  proxy era ->
  ProtVer ->
  EpochInfo (Either Text) ->
  SystemStart ->
  ValidityInterval ->
  Either a PV1.POSIXTimeRange
transValidityInterval _ pv epochInfo systemStart = \case
  ValidityInterval SNothing SNothing -> pure PV1.always
  ValidityInterval (SJust i) SNothing -> PV1.from <$> slotToTime i
  ValidityInterval SNothing (SJust i)
    | pvMajor pv >= natVersion @9 -> do
        t <- slotToTime i
        pure $ PV1.Interval (PV1.lowerBound PV1.NegInf) (PV1.strictUpperBound t)
    | otherwise -> PV1.to <$> slotToTime i
  ValidityInterval (SJust i) (SJust j)
    | pvMajor pv >= natVersion @9 -> do
        t1 <- slotToTime i
        t2 <- slotToTime j
        pure $ PV1.Interval (PV1.lowerBound t1) (PV1.strictUpperBound t2)
    | otherwise -> PV1.interval <$> slotToTime i <*> slotToTime j
  where
    slotToTime :: SlotNo -> Either a PV1.POSIXTime
    slotToTime = transSlotToPOSIXTime epochInfo systemStart

-- | Translate a TxOut. Returns `Nothing` if a Byron address is present in the TxOut.
transTxOut ::
  (Value era ~ MaryValue, AlonzoEraTxOut era) => TxOut era -> Maybe PV1.TxOut
transTxOut txOut = do
  -- Minor optimization:
  -- We can check for Byron address without decompacting the address in the TxOut
  guard $ isNothing (txOut ^. bootAddrTxOutF)
  let val = txOut ^. valueTxOutL
      dataHash = txOut ^. dataHashTxOutL
  address <- transAddr (txOut ^. addrTxOutL)
  pure $ PV1.TxOut address (transValue val) (transDataHash <$> strictMaybeToMaybe dataHash)

transTxBodyId :: EraTxBody era => TxBody era -> PV1.TxId
transTxBodyId txBody = PV1.TxId (transSafeHash (hashAnnotated txBody))

-- | Translate all `TxCert`s from within a `TxBody`
transTxBodyCerts ::
  (EraPlutusTxInfo l era, EraTxBody era) =>
  proxy l ->
  ProtVer ->
  TxBody era ->
  Either (ContextError era) [PlutusTxCert l]
transTxBodyCerts proxy pv txBody =
  mapM (toPlutusTxCert proxy pv) $ F.toList (txBody ^. certsTxBodyL)

transWithdrawals :: Withdrawals -> Map.Map PV1.StakingCredential Integer
transWithdrawals (Withdrawals mp) = Map.foldlWithKey' accum Map.empty mp
  where
    accum ans rewardAccount (Coin n) =
      Map.insert (PV1.StakingHash (transRewardAccount rewardAccount)) n ans

-- | Translate all `Withdrawal`s from within a `TxBody`
transTxBodyWithdrawals :: EraTxBody era => TxBody era -> [(PV1.StakingCredential, Integer)]
transTxBodyWithdrawals txBody = Map.toList (transWithdrawals (txBody ^. withdrawalsTxBodyL))

-- | Translate all required signers produced by `reqSignerHashesTxBodyL`s from within a
-- `TxBody`
transTxBodyReqSignerHashes :: AlonzoEraTxBody era => TxBody era -> [PV1.PubKeyHash]
transTxBodyReqSignerHashes txBody = transKeyHash <$> Set.toList (txBody ^. reqSignerHashesTxBodyL)

-- | Translate all `TxDats`s from within `TxWits`
transTxWitsDatums :: AlonzoEraTxWits era => TxWits era -> [(PV1.DatumHash, PV1.Datum)]
transTxWitsDatums txWits = transDataPair <$> Map.toList (txWits ^. datsTxWitsL . unTxDatsL)

-- ==================================
-- translate Values

transPolicyID :: PolicyID -> PV1.CurrencySymbol
transPolicyID (PolicyID (ScriptHash x)) = PV1.CurrencySymbol (PV1.toBuiltin (hashToBytes x))

transAssetName :: AssetName -> PV1.TokenName
transAssetName (AssetName bs) = PV1.TokenName (PV1.toBuiltin (SBS.fromShort bs))

transMultiAsset :: MultiAsset -> PV1.Value
transMultiAsset ma = transMultiAssetInternal ma mempty

transMultiAssetInternal :: MultiAsset -> PV1.Value -> PV1.Value
transMultiAssetInternal (MultiAsset m) initAcc = Map.foldlWithKey' accum1 initAcc m
  where
    accum1 ans sym mp2 = Map.foldlWithKey' accum2 ans mp2
      where
        accum2 ans2 tok quantity =
          PV1.unionWith
            (+)
            ans2
            (PV1.singleton (transPolicyID sym) (transAssetName tok) quantity)

-- | Hysterical raisins:
--
-- Previously transaction body contained a mint field with MaryValue instead of a
-- MultiAsset, which has changed since then to just MultiAsset (because minting ADA
-- makes no sense). However, if we don't preserve previous translation, scripts that
-- previously succeeded will fail.
transMintValue :: MultiAsset -> PV1.Value
transMintValue m = transMultiAssetInternal m (transCoinToValue zero)

transValue :: MaryValue -> PV1.Value
transValue (MaryValue c m) = transCoinToValue c <> transMultiAsset m

-- =============================================
-- translate fields like TxCert, Withdrawals, and similar

transTxCert :: (ShelleyEraTxCert era, ProtVerAtMost era 8) => TxCert era -> PV1.DCert
transTxCert txCert =
  case transTxCertCommon txCert of
    Just cert -> cert
    Nothing ->
      case txCert of
        GenesisDelegTxCert {} -> PV1.DCertGenesis
        MirTxCert {} -> PV1.DCertMir
        _ -> error "Impossible: All certificates should have been accounted for"

-- | Just like `transTxCert`, but do not translate certificates that were deprecated in Conway
transTxCertCommon :: ShelleyEraTxCert era => TxCert era -> Maybe PV1.DCert
transTxCertCommon = \case
  RegTxCert stakeCred ->
    Just $ PV1.DCertDelegRegKey (PV1.StakingHash (transCred stakeCred))
  UnRegTxCert stakeCred ->
    Just $ PV1.DCertDelegDeRegKey (PV1.StakingHash (transCred stakeCred))
  DelegStakeTxCert stakeCred keyHash ->
    Just $ PV1.DCertDelegDelegate (PV1.StakingHash (transCred stakeCred)) (transKeyHash keyHash)
  RegPoolTxCert (PoolParams {ppId, ppVrf}) ->
    Just $
      PV1.DCertPoolRegister
        (transKeyHash ppId)
        (PV1.PubKeyHash (PV1.toBuiltin (hashToBytes (unVRFVerKeyHash ppVrf))))
  RetirePoolTxCert poolId retireEpochNo ->
    Just $ PV1.DCertPoolRetire (transKeyHash poolId) (transEpochNo retireEpochNo)
  _ -> Nothing

transPlutusPurpose ::
  (EraPlutusTxInfo l era, PlutusTxCert l ~ PV1.DCert) =>
  proxy l ->
  ProtVer ->
  AlonzoPlutusPurpose AsItem era ->
  Either (ContextError era) PV1.ScriptPurpose
transPlutusPurpose proxy pv = \case
  AlonzoSpending (AsItem txIn) -> pure $ PV1.Spending (transTxIn txIn)
  AlonzoMinting (AsItem policyId) -> pure $ PV1.Minting (transPolicyID policyId)
  AlonzoCertifying (AsItem txCert) -> PV1.Certifying <$> toPlutusTxCert proxy pv txCert
  AlonzoRewarding (AsItem rewardAccount) ->
    pure $ PV1.Rewarding (PV1.StakingHash (transRewardAccount rewardAccount))
