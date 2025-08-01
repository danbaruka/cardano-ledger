{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Alonzo.TxOut (
  AlonzoEraTxOut (..),
  AlonzoTxOut (.., AlonzoTxOut, TxOutCompact, TxOutCompactDH),
  -- Constructors are not exported for safety:
  Addr28Extra,
  DataHash32,
  getAdaOnly,
  decodeDataHash32,
  encodeDataHash32,
  encodeAddress28,
  decodeAddress28,
  viewCompactTxOut,
  viewTxOut,
  getAlonzoTxOutEitherAddr,
  utxoEntrySize,
  internAlonzoTxOut,
) where

import Cardano.Crypto.Hash
import Cardano.Ledger.Address (
  Addr (..),
  CompactAddr,
  compactAddr,
  decompactAddr,
  fromCborBothAddr,
 )
import Cardano.Ledger.Alonzo.Era
import Cardano.Ledger.Alonzo.PParams (AlonzoEraPParams, CoinPerWord (..), ppCoinsPerUTxOWordL)
import Cardano.Ledger.Alonzo.Scripts ()
import Cardano.Ledger.BaseTypes (
  Network (..),
  StrictMaybe (..),
  inject,
  strictMaybeToMaybe,
 )
import Cardano.Ledger.Binary (
  DecCBOR (decCBOR),
  DecShareCBOR (Share, decShareCBOR),
  DecoderError (DecoderErrorCustom),
  EncCBOR (encCBOR),
  FromCBOR (..),
  Interns,
  ToCBOR (..),
  TokenType (..),
  cborError,
  decodeBreakOr,
  decodeListLenOrIndef,
  decodeMemPack,
  encodeListLen,
  interns,
  peekTokenType,
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Compactible
import Cardano.Ledger.Credential (Credential (..), PaymentCredential, StakeReference (..))
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Plutus.Data (Datum (..), dataHashSize)
import Cardano.Ledger.Shelley.Core
import qualified Cardano.Ledger.Shelley.TxOut as Shelley
import Cardano.Ledger.Val (Val (..))
import Control.DeepSeq (NFData (..), rwhnf)
import Control.Monad (guard)
import Data.Aeson (ToJSON (..), object, (.=))
import qualified Data.Aeson as Aeson (Value (Null, String))
import Data.Bits
import Data.Maybe (fromMaybe)
import Data.MemPack
import Data.Typeable (Proxy (..))
import Data.Word
import GHC.Generics (Generic)
import GHC.Stack (HasCallStack)
import Lens.Micro
import NoThunks.Class (InspectHeapNamed (..), NoThunks)

class (AlonzoEraPParams era, EraTxOut era) => AlonzoEraTxOut era where
  dataHashTxOutL :: Lens' (TxOut era) (StrictMaybe DataHash)

  datumTxOutF :: SimpleGetter (TxOut era) (Datum era)

data Addr28Extra
  = Addr28Extra
      {-# UNPACK #-} !Word64 -- Payment Addr
      {-# UNPACK #-} !Word64 -- Payment Addr
      {-# UNPACK #-} !Word64 -- Payment Addr
      {-# UNPACK #-} !Word64 -- Payment Addr (32bits) + ... +  0/1 for Testnet/Mainnet + 0/1 Script/Pubkey
  deriving (Eq, Show, Generic, NoThunks)

instance MemPack Addr28Extra where
  packedByteCount _ = 32
  packM (Addr28Extra w0 w1 w2 w3) = packM w0 >> packM w1 >> packM w2 >> packM w3
  {-# INLINE packM #-}
  unpackM = Addr28Extra <$> unpackM <*> unpackM <*> unpackM <*> unpackM
  {-# INLINE unpackM #-}

data DataHash32
  = DataHash32
      {-# UNPACK #-} !Word64 -- DataHash
      {-# UNPACK #-} !Word64 -- DataHash
      {-# UNPACK #-} !Word64 -- DataHash
      {-# UNPACK #-} !Word64 -- DataHash
  deriving (Eq, Show, Generic, NoThunks)

instance MemPack DataHash32 where
  packedByteCount _ = 32
  packM (DataHash32 w0 w1 w2 w3) = packM w0 >> packM w1 >> packM w2 >> packM w3
  {-# INLINE packM #-}
  unpackM = DataHash32 <$> unpackM <*> unpackM <*> unpackM <*> unpackM
  {-# INLINE unpackM #-}

decodeAddress28 ::
  Credential 'Staking ->
  Addr28Extra ->
  Addr
decodeAddress28 stakeRef (Addr28Extra a b c d) =
  let network = if d `testBit` 1 then Mainnet else Testnet
      paymentCred =
        if d `testBit` 0
          then KeyHashObj (KeyHash addrHash)
          else ScriptHashObj (ScriptHash addrHash)
      addrHash :: Hash ADDRHASH a
      addrHash =
        hashFromPackedBytes $
          PackedBytes28 a b c (fromIntegral (d `shiftR` 32))
   in Addr network paymentCred (StakeRefBase stakeRef)
{-# INLINE decodeAddress28 #-}

data AlonzoTxOut era
  = TxOutCompact'
      {-# UNPACK #-} !CompactAddr
      !(CompactForm (Value era))
  | TxOutCompactDH'
      {-# UNPACK #-} !CompactAddr
      !(CompactForm (Value era))
      !DataHash
  | TxOut_AddrHash28_AdaOnly
      !(Credential 'Staking)
      {-# UNPACK #-} !Addr28Extra
      {-# UNPACK #-} !(CompactForm Coin) -- Ada value
  | TxOut_AddrHash28_AdaOnly_DataHash32
      !(Credential 'Staking)
      {-# UNPACK #-} !Addr28Extra
      {-# UNPACK #-} !(CompactForm Coin) -- Ada value
      {-# UNPACK #-} !DataHash32

-- | This instance is backwards compatible in binary representation with TxOut instances for all
-- previous era
instance (Era era, MemPack (CompactForm (Value era))) => MemPack (AlonzoTxOut era) where
  packedByteCount = \case
    TxOutCompact' cAddr cValue ->
      packedTagByteCount + packedByteCount cAddr + packedByteCount cValue
    TxOutCompactDH' cAddr cValue dataHash ->
      packedTagByteCount + packedByteCount cAddr + packedByteCount cValue + packedByteCount dataHash
    TxOut_AddrHash28_AdaOnly cred addr28 cCoin ->
      packedTagByteCount + packedByteCount cred + packedByteCount addr28 + packedByteCount cCoin
    TxOut_AddrHash28_AdaOnly_DataHash32 cred addr28 cCoin dataHash32 ->
      packedTagByteCount
        + packedByteCount cred
        + packedByteCount addr28
        + packedByteCount cCoin
        + packedByteCount dataHash32
  {-# INLINE packedByteCount #-}
  packM = \case
    TxOutCompact' cAddr cValue ->
      packTagM 0 >> packM cAddr >> packM cValue
    TxOutCompactDH' cAddr cValue dataHash ->
      packTagM 1 >> packM cAddr >> packM cValue >> packM dataHash
    TxOut_AddrHash28_AdaOnly cred addr28 cCoin ->
      packTagM 2 >> packM cred >> packM addr28 >> packM cCoin
    TxOut_AddrHash28_AdaOnly_DataHash32 cred addr28 cCoin dataHash32 ->
      packTagM 3 >> packM cred >> packM addr28 >> packM cCoin >> packM dataHash32
  {-# INLINE packM #-}
  unpackM =
    unpackTagM >>= \case
      0 -> TxOutCompact' <$> unpackM <*> unpackM
      1 -> TxOutCompactDH' <$> unpackM <*> unpackM <*> unpackM
      2 -> TxOut_AddrHash28_AdaOnly <$> unpackM <*> unpackM <*> unpackM
      3 -> TxOut_AddrHash28_AdaOnly_DataHash32 <$> unpackM <*> unpackM <*> unpackM <*> unpackM
      n -> unknownTagM @(AlonzoTxOut era) n
  {-# INLINE unpackM #-}

deriving stock instance (Eq (Value era), Compactible (Value era)) => Eq (AlonzoTxOut era)

deriving instance Generic (AlonzoTxOut era)

-- | Already in NF
instance NFData (AlonzoTxOut era) where
  rnf = rwhnf

decodeDataHash32 ::
  DataHash32 ->
  DataHash
decodeDataHash32 (DataHash32 a b c d) = do
  unsafeMakeSafeHash $ hashFromPackedBytes $ PackedBytes32 a b c d

viewCompactTxOut ::
  Val (Value era) =>
  AlonzoTxOut era ->
  (CompactAddr, CompactForm (Value era), StrictMaybe DataHash)
viewCompactTxOut txOut = case txOut of
  TxOutCompact' addr val -> (addr, val, SNothing)
  TxOutCompactDH' addr val dh -> (addr, val, SJust dh)
  TxOut_AddrHash28_AdaOnly stakeRef addr28Extra adaVal ->
    let
      addr = decodeAddress28 stakeRef addr28Extra
     in
      (compactAddr addr, injectCompact adaVal, SNothing)
  TxOut_AddrHash28_AdaOnly_DataHash32 stakeRef addr28Extra adaVal dataHash32 ->
    let
      addr = decodeAddress28 stakeRef addr28Extra
      dh = decodeDataHash32 dataHash32
     in
      (compactAddr addr, injectCompact adaVal, SJust dh)

viewTxOut ::
  Val (Value era) =>
  AlonzoTxOut era ->
  (Addr, Value era, StrictMaybe DataHash)
viewTxOut (TxOutCompact' bs c) = (addr, val, SNothing)
  where
    addr = decompactAddr bs
    val = fromCompact c
viewTxOut (TxOutCompactDH' bs c dh) = (addr, val, SJust dh)
  where
    addr = decompactAddr bs
    val = fromCompact c
viewTxOut (TxOut_AddrHash28_AdaOnly stakeRef addr28Extra adaVal) =
  let addr = decodeAddress28 stakeRef addr28Extra
   in (addr, inject (fromCompact adaVal), SNothing)
viewTxOut (TxOut_AddrHash28_AdaOnly_DataHash32 stakeRef addr28Extra adaVal dataHash32) =
  let
    addr = decodeAddress28 stakeRef addr28Extra
    dh = decodeDataHash32 dataHash32
   in
    (addr, inject (fromCompact adaVal), SJust dh)

instance (Era era, Val (Value era)) => Show (AlonzoTxOut era) where
  show = show . viewTxOut -- FIXME: showing tuple is ugly

deriving via InspectHeapNamed "AlonzoTxOut" (AlonzoTxOut era) instance NoThunks (AlonzoTxOut era)

encodeAddress28 ::
  Network ->
  PaymentCredential ->
  Addr28Extra
encodeAddress28 network paymentCred = do
  let networkBit, payCredTypeBit :: Word64
      networkBit =
        case network of
          Mainnet -> 0 `setBit` 1
          Testnet -> 0
      payCredTypeBit =
        case paymentCred of
          KeyHashObj {} -> 0 `setBit` 0
          ScriptHashObj {} -> 0
      encodeAddr ::
        Hash ADDRHASH a ->
        Addr28Extra
      encodeAddr h = do
        case hashToPackedBytes h of
          PackedBytes28 a b c d ->
            let d' = (fromIntegral d `shiftL` 32) .|. networkBit .|. payCredTypeBit
             in Addr28Extra a b c d'
          _ -> error "Incorrectly constructed PackedBytes"
  case paymentCred of
    KeyHashObj (KeyHash addrHash) -> encodeAddr addrHash
    ScriptHashObj (ScriptHash addrHash) -> encodeAddr addrHash

encodeDataHash32 ::
  DataHash ->
  DataHash32
encodeDataHash32 dataHash = do
  case hashToPackedBytes (extractHash dataHash) of
    PackedBytes32 a b c d -> DataHash32 a b c d
    _ -> error "Incorrectly constructed PackedBytes"

getAdaOnly ::
  forall era.
  Val (Value era) =>
  Proxy era ->
  Value era ->
  Maybe (CompactForm Coin)
getAdaOnly _ v = do
  guard $ isAdaOnly v
  toCompact $ coin v

pattern AlonzoTxOut ::
  forall era.
  (Era era, Val (Value era), HasCallStack) =>
  Addr ->
  Value era ->
  StrictMaybe DataHash ->
  AlonzoTxOut era
pattern AlonzoTxOut addr vl dh <-
  (viewTxOut -> (addr, vl, dh))
  where
    AlonzoTxOut (Addr network paymentCred stakeRef) vl SNothing
      | StakeRefBase stakeCred <- stakeRef
      , Just adaCompact <- getAdaOnly (Proxy @era) vl =
          let addr28Extra = encodeAddress28 network paymentCred
           in TxOut_AddrHash28_AdaOnly stakeCred addr28Extra adaCompact
    AlonzoTxOut (Addr network paymentCred stakeRef) vl (SJust dh)
      | StakeRefBase stakeCred <- stakeRef
      , Just adaCompact <- getAdaOnly (Proxy @era) vl =
          let
            addr28Extra = encodeAddress28 network paymentCred
            dataHash32 = encodeDataHash32 dh
           in
            TxOut_AddrHash28_AdaOnly_DataHash32 stakeCred addr28Extra adaCompact dataHash32
    AlonzoTxOut addr vl mdh =
      let v = fromMaybe (error $ "Illegal value in TxOut: " ++ show vl) $ toCompact vl
          a = compactAddr addr
       in case mdh of
            SNothing -> TxOutCompact' a v
            SJust dh -> TxOutCompactDH' a v dh

{-# COMPLETE AlonzoTxOut #-}

instance EraTxOut AlonzoEra where
  type TxOut AlonzoEra = AlonzoTxOut AlonzoEra

  mkBasicTxOut addr vl = AlonzoTxOut addr vl SNothing

  upgradeTxOut (Shelley.TxOutCompact addr value) = TxOutCompact' addr value

  addrEitherTxOutL =
    lens
      getAlonzoTxOutEitherAddr
      ( \txOut eAddr ->
          let cVal = getTxOutCompactValue txOut
              (_, _, dh) = viewTxOut txOut
           in case eAddr of
                Left addr -> mkTxOutCompact addr (compactAddr addr) cVal dh
                Right cAddr -> mkTxOutCompact (decompactAddr cAddr) cAddr cVal dh
      )
  {-# INLINE addrEitherTxOutL #-}

  valueEitherTxOutL =
    lens
      (Right . getTxOutCompactValue)
      ( \txOut eVal ->
          case eVal of
            Left val ->
              let (addr, _, dh) = viewTxOut txOut
               in AlonzoTxOut addr val dh
            Right cVal ->
              let dh = getAlonzoTxOutDataHash txOut
               in case getAlonzoTxOutEitherAddr txOut of
                    Left addr -> mkTxOutCompact addr (compactAddr addr) cVal dh
                    Right cAddr -> mkTxOutCompact (decompactAddr cAddr) cAddr cVal dh
      )
  {-# INLINE valueEitherTxOutL #-}

  getMinCoinTxOut pp txOut =
    case pp ^. ppCoinsPerUTxOWordL of
      CoinPerWord (Coin cpw) -> Coin $ utxoEntrySize txOut * cpw

instance
  (Era era, Val (Value era)) =>
  EncCBOR (AlonzoTxOut era)
  where
  encCBOR (TxOutCompact addr cv) =
    encodeListLen 2
      <> encCBOR addr
      <> encCBOR cv
  encCBOR (TxOutCompactDH addr cv dh) =
    encodeListLen 3
      <> encCBOR addr
      <> encCBOR cv
      <> encCBOR dh

instance (Era era, Val (Value era)) => DecCBOR (AlonzoTxOut era) where
  decCBOR = do
    lenOrIndef <- decodeListLenOrIndef
    case lenOrIndef of
      Nothing -> do
        (a, ca) <- fromCborBothAddr
        cv <- decCBOR
        decodeBreakOr >>= \case
          True -> pure $ mkTxOutCompact a ca cv SNothing
          False -> do
            dh <- decCBOR
            decodeBreakOr >>= \case
              True -> pure $ mkTxOutCompact a ca cv (SJust dh)
              False -> cborError $ DecoderErrorCustom "txout" "Excess terms in txout"
      Just 2 -> do
        (a, ca) <- fromCborBothAddr
        cv <- decCBOR
        pure $ mkTxOutCompact a ca cv SNothing
      Just 3 -> do
        (a, ca) <- fromCborBothAddr
        cv <- decCBOR
        mkTxOutCompact a ca cv . SJust <$> decCBOR
      Just _ -> cborError $ DecoderErrorCustom "txout" "wrong number of terms in txout"
  {-# INLINEABLE decCBOR #-}

instance (Era era, Val (Value era), MemPack (CompactForm (Value era))) => DecShareCBOR (AlonzoTxOut era) where
  type Share (AlonzoTxOut era) = Interns (Credential 'Staking)
  decShareCBOR credsInterns = do
    txOut <-
      peekTokenType >>= \case
        TypeBytes -> decodeMemPack
        TypeBytesIndef -> decodeMemPack
        _ -> decCBOR
    pure $! internAlonzoTxOut (interns credsInterns) txOut
  {-# INLINEABLE decShareCBOR #-}

internAlonzoTxOut ::
  (Credential 'Staking -> Credential 'Staking) ->
  AlonzoTxOut era ->
  AlonzoTxOut era
internAlonzoTxOut internCred = \case
  TxOut_AddrHash28_AdaOnly cred addr28Extra ada ->
    TxOut_AddrHash28_AdaOnly (internCred cred) addr28Extra ada
  TxOut_AddrHash28_AdaOnly_DataHash32 cred addr28Extra ada dataHash32 ->
    TxOut_AddrHash28_AdaOnly_DataHash32 (internCred cred) addr28Extra ada dataHash32
  txOut -> txOut
{-# INLINE internAlonzoTxOut #-}

instance (Era era, Val (Value era)) => ToCBOR (AlonzoTxOut era) where
  toCBOR = toEraCBOR @era
  {-# INLINE toCBOR #-}

instance (Era era, Val (Value era)) => FromCBOR (AlonzoTxOut era) where
  fromCBOR = fromEraCBOR @era
  {-# INLINE fromCBOR #-}

instance (Era era, Val (Value era)) => ToJSON (AlonzoTxOut era) where
  toJSON (AlonzoTxOut addr v dataHash) =
    object
      [ "address" .= toJSON addr
      , "value" .= toJSON v
      , "datahash" .= case strictMaybeToMaybe dataHash of
          Nothing -> Aeson.Null
          Just dHash ->
            Aeson.String . hashToTextAsHex $
              extractHash dHash
      ]

pattern TxOutCompact ::
  (Era era, Val (Value era), HasCallStack) =>
  CompactAddr ->
  CompactForm (Value era) ->
  AlonzoTxOut era
pattern TxOutCompact addr vl <-
  (viewCompactTxOut -> (addr, vl, SNothing))
  where
    TxOutCompact cAddr cVal = mkTxOutCompact (decompactAddr cAddr) cAddr cVal SNothing

pattern TxOutCompactDH ::
  (Era era, Val (Value era), HasCallStack) =>
  CompactAddr ->
  CompactForm (Value era) ->
  DataHash ->
  AlonzoTxOut era
pattern TxOutCompactDH addr vl dh <-
  (viewCompactTxOut -> (addr, vl, SJust dh))
  where
    TxOutCompactDH cAddr cVal dh = mkTxOutCompact (decompactAddr cAddr) cAddr cVal (SJust dh)

{-# COMPLETE TxOutCompact, TxOutCompactDH #-}

mkTxOutCompact ::
  (Era era, HasCallStack, Val (Value era)) =>
  Addr ->
  CompactAddr ->
  CompactForm (Value era) ->
  StrictMaybe DataHash ->
  AlonzoTxOut era
mkTxOutCompact addr cAddr cVal mdh
  | isAdaOnlyCompact cVal = AlonzoTxOut addr (fromCompact cVal) mdh
  | SJust dh <- mdh = TxOutCompactDH' cAddr cVal dh
  | otherwise = TxOutCompact' cAddr cVal

getAlonzoTxOutDataHash ::
  forall era.
  AlonzoTxOut era ->
  StrictMaybe DataHash
getAlonzoTxOutDataHash = \case
  TxOutCompactDH' _ _ dh -> SJust dh
  TxOut_AddrHash28_AdaOnly_DataHash32 _ _ _ dh ->
    SJust $ decodeDataHash32 dh
  _ -> SNothing

getAlonzoTxOutEitherAddr ::
  AlonzoTxOut era ->
  Either Addr CompactAddr
getAlonzoTxOutEitherAddr = \case
  TxOutCompact' cAddr _ -> Right cAddr
  TxOutCompactDH' cAddr _ _ -> Right cAddr
  TxOut_AddrHash28_AdaOnly stakeRef addr28Extra _ ->
    Left $ decodeAddress28 stakeRef addr28Extra
  TxOut_AddrHash28_AdaOnly_DataHash32 stakeRef addr28Extra _ _ ->
    Left $ decodeAddress28 stakeRef addr28Extra

-- | Compute an estimate of the size of storing one UTxO entry.
-- This function implements the UTxO entry size estimate done by scaledMinDeposit in the ShelleyMA era
utxoEntrySize :: AlonzoEraTxOut era => TxOut era -> Integer
utxoEntrySize txOut = utxoEntrySizeWithoutVal + size v + dataHashSize dh
  where
    v = txOut ^. valueTxOutL
    dh = txOut ^. dataHashTxOutL
    -- lengths obtained from tracing on HeapWords of inputs and outputs
    -- obtained experimentally, and number used here
    -- units are Word64s

    -- size of UTxO entry excluding the Value part
    utxoEntrySizeWithoutVal :: Integer
    utxoEntrySizeWithoutVal = 27 -- 6 + txoutLenNoVal [14] + txinLen [7]

instance AlonzoEraTxOut AlonzoEra where
  dataHashTxOutL =
    lens getAlonzoTxOutDataHash (\(AlonzoTxOut addr cv _) dh -> AlonzoTxOut addr cv dh)
  {-# INLINEABLE dataHashTxOutL #-}

  datumTxOutF = to $ \txOut ->
    case getAlonzoTxOutDataHash txOut of
      SNothing -> NoDatum
      SJust dh -> DatumHash dh
  {-# INLINEABLE datumTxOutF #-}

getTxOutCompactValue :: EraTxOut era => AlonzoTxOut era -> CompactForm (Value era)
getTxOutCompactValue =
  \case
    TxOutCompact' _ cv -> cv
    TxOutCompactDH' _ cv _ -> cv
    TxOut_AddrHash28_AdaOnly _ _ cc -> injectCompact cc
    TxOut_AddrHash28_AdaOnly_DataHash32 _ _ cc _ -> injectCompact cc
