{-# LANGUAGE TypeInType           #-}
{-# LANGUAGE UndecidableInstances #-}

module Data.Graph.Component.Container where

import Data.Graph.Component.Class
import Prologue

import qualified Data.Construction             as Data
import qualified Data.Graph.Component.Provider as Component
import qualified Data.Set.Mutable.Class        as Set
import qualified Foreign.Storable1.Deriving    as Storable1

import Data.PtrSet.Mutable (UnmanagedPtrSet)
import Foreign.Storable    (Storable)



-----------------
-- === Set === --
-----------------

-- === Definition === --

newtype Set tag layout = Set (UnmanagedPtrSet (Component tag layout))
    deriving (Show, Storable)
makeLenses       ''Set
Storable1.derive ''Set


-- === Instances === --

type instance Set.Item (Set tag layout) = Component tag layout
instance MonadIO m => Set.Set m (Set tag layout) where
    new    = wrap <$> Set.new    ; {-# INLINE new    #-}
    insert = Set.insert . unwrap ; {-# INLINE insert #-}
    delete = Set.delete . unwrap ; {-# INLINE delete #-}
    member = Set.member . unwrap ; {-# INLINE member #-}
    size   = Set.size   . unwrap ; {-# INLINE size   #-}
    null   = Set.null   . unwrap ; {-# INLINE null   #-}
    toList = Set.toList . unwrap ; {-# INLINE toList #-}

instance MonadIO m => Data.Constructor2 m () Set where
    construct2 _ = wrap <$> Data.new1 ; {-# INLINE construct2 #-}

instance MonadIO m => Data.ShallowDestructor2 m Set where
    destructShallow2 = Data.destruct1 . unwrap ; {-# INLINE destructShallow2 #-}

instance Typeable tag => Component.DynamicProvider1 (Set tag) where
    dynamicComponentsIO1 = Component.dynamicComponentsIO . unwrap ; {-# INLINE dynamicComponentsIO1 #-}