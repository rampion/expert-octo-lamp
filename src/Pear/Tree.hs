module Pear.Tree 
  ( module Pear.Tree
  , module Pear.Positive
  , module Pear.Pair.LinkToModuleDocumentation
  , module Pear.Those
  , module Pear.Zipper
  ) where

import Prelude hiding (lookup, fst, snd, reverse, span)
import Control.Applicative (liftA3)
import Control.Applicative.Backwards (pattern Backwards, forwards)
import Control.Monad.State (evalState, state, runState)
import Data.Foldable1 (Foldable1(..))
import Data.Function ((&))
import Data.Functor ((<&>))
import Data.Functor.Const (pattern Const, getConst)
import Data.Functor.Identity (pattern Identity, runIdentity)
import Data.Kind (Type)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Monoid (pattern Alt, getAlt)
import Data.Tuple (swap)
import Numeric.Natural (Natural)
import Pear.Pair hiding (at)
import Pear.Pair qualified as Pear.Pair.LinkToModuleDocumentation -- avoid transcluding definitions from Pear.Pair when generating the documentation
import Pear.Positive
import Pear.Those
import Pear.Zipper

-- | A container type that stores elements in balanced binary trees.
--
-- For a @Tree a@ of size @n@, no element @a@ is more than @1 + 2 log₂ n@
-- constructors deep.
type Tree :: Type -> Type
data Tree a = Top a | Tree (Pair a) :>- Maybe a
infixl 4 :>-

deriving instance Eq a => Eq (Tree a)
deriving instance Functor Tree
deriving instance Foldable Tree
deriving instance Traversable Tree

instance Show a => Show (Tree a) where
  showsPrec p = showParen (p >= 4) . showsTree where
    -- *almost* equivalent to the derived instance, but the derived instance inserts
    -- unnecessary parentheses e.g.
    --
    --  (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing) :>- Just 'e'
    showsTree :: forall a. Show a => Tree a -> ShowS
    showsTree = \case
      Top a -> showString "Top " . showsPrec 10 a
      t :>- ma -> showsTree t . showString " :>- " . showsPrec 4 ma

instance Foldable1 Tree where
  foldMap1 f = \case
    Top a -> f a
    ta² :>- ma -> 
      let m = foldMap1 (foldMap1 f) ta²
      in maybe m (\a -> m <> f a) ma

instance Zipperable Tree where
  -- | one-hole contexts of 'Tree's
  data Context Tree a where
    -- Per Conor McBride, the one-hole context for a type is isomorphic to the
    -- derivative of the algebraic representation of a type.
    --
    -- @
    --  Maybe a                         ↔   1 + a
    --  Hole                            ↔   1
    --
    --  Top a                           ↔   a
    --  Tree (Pair a) :>- Maybe a       ↔   Tree (Pair a) · (1 + a)
    --  Tree a                          ↔   a + Tree (Pair a) · (1 + a)
    --
    --  Context Tree a                  ↔   d(Tree a)/da
    --                                  ↔   da/da + d(Tree (Pair a))/da · (1 + a) + Tree (Pair a) . d(1 + a)/da
    --
    --  da/da                           ↔   1
    --                                  ↔   AtTop
    --
    --  d(Tree (Pair a))/da · (1 + a)   ↔   Context Tree a² · Context Pair a · (1 + a)
    --                                  ↔   Context Tree a² :\ (Context Pair a, Maybe a)
    --
    --  Tree (Pair a) . d(1 + a)/da     ↔   Tree (Pair a) · 1
    --                                  ↔   Tree a² :\- Hole
    -- @
    --
    -- The chain rule is your friend
    AtTop :: Context Tree a
    (:\) :: Context Tree (Pair a) -> (Context Pair a, Maybe a)-> Context Tree a
    (:\-) :: Tree (Pair a) -> Hole -> Context Tree a
    deriving (Show, Eq, Functor)

  fillContext = \case
    AtTop             -> Top
    ta² :\- Hole      -> \a -> ta² :>- Just a
    cta² :\ (ca², ma) -> \a -> fillContext cta² (fillContext ca² a) :>- ma

  mapWithContext f = \case
    Top a -> Top (f AtTop a)
    ta² :>- ma -> 
      mapWithContext (\cta² -> mapWithContext \ca² -> f (cta² :\ (ca², ma))) ta² 
        :>- fmap (f (ta² :\- Hole)) ma
    
  stepForward withTree withZipper = \case
    AtTop -> withTree . Top
    ta²  :\- Hole -> withTree . \a -> ta² :>- Just a
    cta² :\ (ca², ma) -> 
      ca² & stepForward
        do cta² & stepForward
            do \ta² -> maybe (withTree (ta² :>- Nothing)) (withZipper (ta² :\- Hole)) ma
            do \cta² (a₂ :× a₃) -> withZipper (cta² :\ (Hole :< a₃, ma)) a₂
        do \ca² -> withZipper (cta² :\ (ca², ma))

  stepBackward = \withTree withZipper -> \case
    AtTop -> withTree . Top
    ta²  :\- Hole -> \a -> zipToLast (withZipper `onSnd` Just a) ta²
    cta² :\ (ca², ma) -> 
      ca² & stepBackward
        do cta² & stepBackward
            do \ta² -> withTree (ta² :>- ma)
            do withZipper `onSnd` ma
        do \ca² -> withZipper (cta² :\ (ca², ma))
    where
      onSnd :: (Context Tree a -> a -> r) -> Maybe a -> Context Tree (Pair a) -> Pair a -> r
      onSnd k ma cta² (a₀ :× a₁) = k (cta² :\ (a₀ :> Hole, ma)) a₁
      
      zipToLast :: (Context Tree a -> a -> r) -> Tree a -> r
      zipToLast k = \case
        Top a -> k AtTop a
        ta² :>- Just a -> k (ta² :\- Hole) a
        ta² :>- Nothing -> zipToLast (k `onSnd` Nothing) ta²

infixl 4 :\, :\-

instance Traversable (Zipper Tree) where
  traverse = setup where 

    setup :: Applicative f => (a -> f b) -> Zipper Tree a -> f (Zipper Tree b)
    setup g Zipper{context,value} = loop g 
      do g value <&> \b ctb² () -> Zipper ctb² b
      do context 
      do pure ()

    -- aggregate the effects so that the elements are traversed in the proper order
    loop 
      :: Applicative f 
      => (a -> f b) 
      -> f (Context Tree b -> x -> r) 
      -> Context Tree a -> f x -> f r 
    loop g fh = \case
      -- fh - Seeded with the focused element; used to grow the effects *out* around
      --      that point as we ascend through the balanced binary tree until we hit
      --      Top or a (:>-). 
      --
      --      For example consider the following partial context:
      --      
      --      … :\ (((A :× B) :× (C :× D)) :> Hole, _) 
      --        :\ (Hole :< (G :× H), _) 
      --        :\ (E :> Hole, _)
      --
      --      This can also be drawn as a tree diagram:
      --
      --                           :<
      --                 :>                     :×
      --          A :× B    C :> D    E :× Hole    G :× H
      --
      --      In this case, fh would be seeded with the focused element,
      --      then the effects of `E` would be placed before it,
      --      then the effects of `G :× H` placed after,
      --      then the effects of `(A :× B) :× (C :× D)` placed before
      --
      --      We use the function value to rearrange the values obtained
      --      from the effects in the order needed to recreate a Zipper.
      --
      -- fx - Offshoots from (:>-) below the focused balanced binary tree,
      --      effects are aggregated leftward
      --
      --      For example consider the following partial context:
      --
      --      … :\ (_, Just ((I :× J) :× (K :× L))) 
      --        :\ (_, Nothing)
      --        :\ (_, Just M)
      --
      --      This can also be drawn as a set of tree diagrams.
      --      
      --               Just         Nothing         Just
      --               :×
      --        I :× J    K :× L                    M
      --
      --      In this case, fx would start out empty,
      --      then the effects of `M` would be prepended to it,
      --      then the effects of `(I :× J) :× (K :× L)` would be prepended to
      --      it.
      --
      AtTop -> liftA2 
        do \h -> h AtTop
        do fh
      ta² :\- Hole -> liftA3 
        do \tb² h -> h (tb² :\- Hole)
        do traverse (both g) ta²
        do fh
      cta² :\ (Hole :< a₁, Nothing) -> loop (both g) 
        do (fh ? g a₁) \h b₁ ctb² -> h (ctb² :\ (Hole :< b₁, Nothing))
        do cta²
      cta² :\ (Hole :< a₁, Just a) -> \fx -> loop (both g)
        do (fh ? g a₁) \h b₁ ctb² k -> k h b₁ ctb²
        do cta²
        do (g a ? fx) \b x h b₁ ctb² -> h (ctb² :\ (Hole :< b₁, Just b)) x
      cta² :\ (a₀ :> Hole, Nothing) -> loop (both g)
        do (g a₀ ? fh) \b₀ h ctb² -> h (ctb² :\ (b₀ :> Hole, Nothing))
        do cta²
      cta² :\ (a₀ :> Hole, Just a) -> \fx -> loop (both g)
        do (g a₀ ? fh) \b₀ h ctb² k -> k b₀ h ctb²
        do cta²
        do (g a ? fx) \b x b₀ h ctb² -> h (ctb² :\ (b₀ :> Hole, Just b)) x

    -- infix version of liftA2
    (?) :: Applicative f => f a -> f b -> (a -> b -> c) -> f c
    (?) fa fb g = liftA2 g fa fb

    -- raises a kleisli arrow to operate on pairs
    both :: Applicative f => (a -> f b) -> Pair a -> f (Pair b)
    both g (a₀ :× a₁) = liftA2 (:×) (g a₀) (g a₁)

-- | complexity(t₀ <> t₁) = O(|t₁|)
instance Semigroup (Tree a) where
  (<>) = v where
    v :: Tree b -> Tree b -> Tree b
    v = \case
      Top a₀            -> unshift a₀
      ta²₀ :>- Just a₀  -> uncurry (y ta²₀) .  rotateRight a₀
      ta²₀ :>- Nothing  -> x ta²₀

    w :: Tree b -> Tree b -> b -> Tree b
    w = \case
      Top a₀ -> push . unshift a₀
      ta²₀ :>- Just a₀ -> uncurry (z ta²₀) . rotateRight a₀
      ta²₀ :>- Nothing -> y ta²₀

    x :: Tree (Pair b) -> Tree b -> Tree b
    x ta²₀ = \case
      Top a₁        -> ta²₀ :>- Just a₁
      ta²₁ :>- ma₁  -> v ta²₀ ta²₁ :>- ma₁

    y :: Tree (Pair b) -> Tree b -> b -> Tree b
    y ta²₀ = \case
      Top a₁            -> \a₂ -> push ta²₀ (a₁ :× a₂) :>- Nothing
      ta²₁ :>- Just a₁  -> \a₂ -> w ta²₀ ta²₁ (a₁ :× a₂) :>- Nothing
      ta²₁ :>- Nothing  -> \a₂ -> v ta²₀ ta²₁ :>- Just a₂

    z :: Tree (Pair b) -> Tree b -> b -> b -> Tree b
    z ta²₀ = \case
      Top a₁            -> \a₂ a₃ -> push ta²₀ (a₁ :× a₂) :>- Just a₃
      ta²₁ :>- Just a₁  -> \a₂ a₃ -> w ta²₀ ta²₁ (a₁ :× a₂) :>- Just a₃
      ta²₁ :>- Nothing  -> \a₂ a₃ -> w ta²₀ ta²₁ (a₂ :× a₃) :>- Nothing

-- | A possibly-empty 'Tree'
type Tree0 :: Type -> Type
type Tree0 a = Maybe (Tree a)

-- | @reverse t@ returns the elements of @t@ in reverse order
--
-- complexity(reverse t) = O(|t|)
--
-- >>> reverse (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing :>- Just 'e')
-- Top (('e' :× 'd') :× ('c' :× 'b')) :>- Nothing :>- Just 'a'
reverse :: Tree a -> Tree a
reverse = loop id id where
  loop  :: ((a -> r) -> a -> r) -> (Tree a -> r) -> Tree a -> r
  loop f k = \case
    Top a -> f (k . Top) a
    ta² :>- Nothing -> loop
      do \g (a₀ :× a₁) -> f (\a₁ -> f (g . (a₁ :×)) a₀) a₁
      do \ta² -> k (ta² :>- Nothing)
      do ta²
    ta² :>- Just a -> loop
      do \g (a₀ :× a₁) -> f \a₂ -> f (\a₁ -> g (a₂ :× a₁) a₀) a₁
      do \ta² -> f \a -> k (ta² :>- Just a)
      do ta²
      do a

-- | @reverse0 t@ returns the elements of @t@ in reverse order
--
-- complexity: O(|t|)
--
-- >>> reverse0 Nothing
-- Nothing
-- >>> reverse0 (Just (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing :>- Just 'e'))
-- Just (Top (('e' :× 'd') :× ('c' :× 'b')) :>- Nothing :>- Just 'a')
reverse0 :: Tree0 a -> Tree0 a
reverse0 = fmap reverse

-- | @filter p t@ selects the elements @a@ of @t@ for which @p a@ is true.
--
-- complexity: O(|t| log |t|)
--
-- >>> filter @Int odd (Top ((0 :× 1) :× (2 :× 3)) :>- Just (4 :× 5) :>- Just 6)
-- Just (Top (1 :× 3) :>- Just 5)
filter :: (a -> Bool) -> Tree a -> Tree0 a
filter p = mapMaybe \a -> if p a then Just a else Nothing

-- | @mapMaybe f t@ returns a tree containing the values of type @b@
-- generated by passing the elements of @t@ to @f@.
--
-- complexity: O(|t| log |t|)
--
-- >>> mapMaybe (\x -> if even x then Just x else Nothing) (Top ((0 :× 1) :× (2 :× 3)) :>- Just (4 :× 5) :>- Just 6)
-- Just (Top ((0 :× 2) :× (4 :× 6)) :>- Nothing :> Nothing)
mapMaybe :: (a -> Maybe b) -> Tree a -> Tree0 b
mapMaybe f ta = case partition (maybe (Left ()) Right . f) ta of
  This _ -> Nothing
  That tb -> Just tb
  These _ tb -> Just tb

-- | @partition f t@ uses @f@ to divide the elements of @t@ into up to at most two trees.
--
-- complexity: O(|t| log |t|)
--
-- >>> partition @Int (\x -> if even x then Left x else Right x) (Top ((0 :× 1) :× (2 :× 3)) :>- Just (4 :× 5) :>- Just 6)
-- Just (These (Top ((0 :× 2) :× (4 :× 6)) :>- Nothing :> Nothing) (Top (1 :× 3) :>- Just 5))
partition :: (a -> Either b c) -> Tree a -> These (Tree b) (Tree c)
partition f = foldMap1 (either (This . Top) (That . Top) . f)

-- | @partition0 f t@ uses @f@ to divide the elements of @t@ into up to at most two trees.
--
-- complexity: O(|t| log |t|)
--
-- >>> partition0 @Int (\x -> if even x then Left x else Right x) (Just (Top ((0 :× 1) :× (2 :× 3)) :>- Just (4 :× 5) :>- Just 6))
-- (Just (Top ((0 :× 2) :× (4 :× 6)) :>- Nothing :> Nothing), Just (Top (1 :× 3) :>- Just 5))
-- >>> partition0 @Int Left (Just (Top ((0 :× 1) :× (2 :× 3)) :>- Just (4 :× 5) :>- Just 6))
-- ((Just (Top ((0 :× 1) :× (2 :× 3)) :>- Just (4 :× 5) :>- Just 6)), Nothing)
-- >>> partition0 @Int Right (Just (Top ((0 :× 1) :× (2 :× 3)) :>- Just (4 :× 5) :>- Just 6))
-- (Nothing, (Just (Top ((0 :× 1) :× (2 :× 3)) :>- Just (4 :× 5) :>- Just 6)))
partition0 :: (a -> Either b c) -> Tree0 a -> (Tree0 b, Tree0 c)
partition0 f = fromThose . fmap (partition f)

-- | @size t@ is the number of elements in @t@
--
-- complexity: O(log |t|)
--
-- >>> size (Top 'a')
-- ObI
-- >>> size (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing :>- Nothing)
-- ObI :. O :. O
-- >>> size (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Just ('e' :× 'f') :>- Just 'g')
-- ObI :. I :. I
size :: Tree a -> Positive
size =  \case
  Top _ -> ObI
  ta² :>- ma -> size ta² :. maybe O (const I) ma

-- | @size0 t@ is the number of elements in @t@
--
-- complexity: O(log |t|)
--
-- >>> size0 Nothing
-- 0
-- >>> size0 (Just (Top 'a'))
-- 1
-- >>> size0 (Just (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing :>- Nothing))
-- 4
-- >>> size0 (Just (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Just ('e' :× 'f') :>- Just 'g'))
-- 7
size0 :: Tree0 a -> Natural
size0 = maybe 0 (toNatural . size)

-- | @head t@ is the first element of @t@
--
-- complexity: O(log |t|)
--
-- >>> head (Top 'a')
-- 'a'
-- >>> head (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Just ('e' :× 'f') :>- Just 'g')
-- 'a'
head :: Tree a -> a
head = loop id where
  loop :: (b -> a) -> Tree b -> a
  loop k = \case
    Top b -> k b
    ta² :>- _ -> loop (k . fst) ta²

-- | @last t@ is the last element of @t@
--
-- complexity: O(log |t|)
--
-- >>> last (Top 'a')
-- 'a'
-- >>> last (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Just ('e' :× 'f') :>- Just 'g')
-- 'g'
last :: Tree a -> a
last = loop id where
  loop :: (b -> a) -> Tree b -> a
  loop k = \case
    Top b -> k b
    ta² :>- Nothing -> loop (k . snd) ta²
    _ :>- Just a -> k a

-- | @t ?? i@ is the i'th element of @t@, if i < size t.
--
-- complexity: O(log |t|)
--
-- >>> (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Just ('e' :× 'f') :>- Just 'g') ?? 0
-- Just 'a'
-- >>> (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Just ('e' :× 'f') :>- Just 'g') ?? 3
-- Just 'd'
-- >>> (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Just ('e' :× 'f') :>- Just 'g') ?? 7
-- Just 'g'
-- >>> (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Just ('e' :× 'f') :>- Just 'g') ?? 10
-- Nothing
(??) :: Tree a -> Natural -> Maybe a
(??) = flip \i -> fmap getConst . at i Const
infix 9 ??

-- | replace the i'th value of 't', if i < size t
--
-- complexity: O(log |t|)
--
-- >>> put 2 'C' (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing :>- Nothing)
-- Just (Top (('a' :× 'b') :× ('C' :× 'd')) :>- Nothing :>- Nothing)
-- >>> put 4 'X' (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing :>- Nothing)
-- Nothing
put :: Natural -> a -> Tree a -> Maybe (Tree a)
put i = modify i . const

-- | modify the i'th value of 't', if i < size t
--
-- complexity: O(log |t|)
--
-- >>> modify 2 toUpper  (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing :>- Nothing)
-- Just (Top (('a' :× 'b') :× ('C' :× 'd')) :>- Nothing :>- Nothing)
-- >>> modify 2 toUpper (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing :>- Nothing)
-- Nothing
modify :: Natural -> (a -> a) -> Tree a -> Maybe (Tree a)
modify i f = fmap runIdentity . at i (Identity . f)

-- | Get a hypo-lens for a given position in the tree.
--
-- complexity: O(log |t|)
at :: Natural -> (forall f. Functor f => (a -> f a) -> Tree a -> Maybe (f (Tree a)))
at i f t = fmap zipUp . focus f <$> zipDown t ?? i

-- | Label each position in the tree with its index
indexes :: Tree a -> Tree (Natural, a)
indexes = (`evalState` 0). traverse \a -> state \(!i) -> ((i, a), i + 1)

-- | Create a tree with a single value
singleton :: a -> Tree a
singleton = Top

-- | Append a value to a tree
--
-- complexity: O(log |t|)
--
-- >>> push (Top 'a') 'b'
-- Top ('a' :× 'b') :>- Nothing
-- >>> push (Top ('a' :× 'b') :>- Nothing) 'c'
-- Top ('a' :× 'b') :>- Just 'c'
-- >>> push (Top ('a' :× 'b') :>- Just 'c') 'd'
-- Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing :>- Nothing
push :: Tree a -> a -> Tree a
push = \case
  Top a₀ -> \a₁ -> Top (a₀ :× a₁) :>- Nothing
  ta² :>- Nothing -> \a₀ -> ta² :>- Just a₀
  ta² :>- Just a₀ -> \a₁ -> push ta² (a₀ :× a₁) :>- Nothing

-- | Append a value to a tree
--
-- complexity: O(log |t|)
--
-- >>> push0 Nothing 'a'
-- Top 'a'
-- >>> push0 (Just (Top 'a')) 'b'
-- Top ('a' :× 'b') :>- Nothing
push0 :: Tree0 a -> a -> Tree a
push0 = maybe Top push

-- | remove the last value from a tree
-- 
-- complexity: O(log |t|)
--
-- >>> pop (Top 'a')
-- (Nothing, 'a')
-- >>> pop (Top ('a' :× 'b') :>- Nothing)
-- (Just (Top 'a'), 'b')
pop :: Tree a -> (Tree0 a, a)
pop = \case 
  Top a -> (Nothing, a)
  ta² :>- Just a -> (Just (ta² :>- Nothing), a)
  ta² :>- Nothing ->
    let ~(ta, a) = pop2 ta² in (Just ta, a)

-- | remove the last value from a tree containing pairs of values
--
-- complexity: O(log |t|)
--
-- >>> pop2 (Top ('a' :× 'b'))
-- (Just (Top 'a'), 'b')
-- >>> pop2 (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing)
-- (Just (Top ('a' :× 'b') :>- Just 'c', 'd')
pop2 :: Tree (Pair a) -> (Tree a, a)
pop2 = \case
  Top (a₀ :× a₁) -> (Top a₀, a₁)
  ta⁴ :>- Just (a₀ :× a₁) -> (ta⁴ :>- Nothing :>- Just a₀, a₁)
  ta⁴ :>- Nothing -> 
    let ~(ta², a₀ :× a₁) = pop2 ta⁴ in (ta² :>- Just a₀, a₁)

rotateRight :: a -> Tree a -> (Tree a, a)
rotateRight a t = traverse (state . curry swap) t `runState` a

rotateLeft :: Tree a -> a -> (a, Tree a)
rotateLeft t a = swap do
  forwards (traverse (Backwards . state . curry swap) t) `runState` a

-- | Prepend a value to a tree
--
-- complexity: O(|t|)
--
-- >>> unshift 'c' (Top 'd')
-- Top ('c' :× 'd') :>- Nothing
-- >>> unshift 'b' (Top ('c' :× 'd') :>- Nothing)
-- Top ('b' :× 'c') :>- Just 'd'
-- >>> unshift 'a' (Top ('b' :× 'c') :>- Just 'd')
-- Top (('a' :× 'b') :× ('c' :× 'd')) :>- Nothing :>- Nothing
unshift :: a -> Tree a -> Tree a
unshift a = uncurry push  . rotateRight a

-- | Prepend a value to a possibly-empty tree
--
-- complexity: O(|t|)
unshift0 :: a -> Tree0 a -> Tree a
unshift0 = liftA2 maybe Top unshift

-- | Remove the first element from a tree
shift :: Tree a -> (a, Tree0 a)
shift = \case
  Top a -> (a, Nothing)
  ta² :>- Just a -> Just <$> rotateLeft (ta² :>- Nothing) a
  ta² :>- Nothing -> Just <$> shift2 ta²

-- | Remove the first element from an evenly-sized tree
shift2 :: Tree (Pair a) -> (a, Tree a)
shift2 = uncurry rotateLeft . pop2

-- | Split the zipper into two trees:
--  - one containing everything before the focused value
--  - one containing the focused value and everything after
--
-- complexity(fst (zipSplit z)) = O(log |z|)
-- complexity(snd (zipSplit z)) = O(|z|)
zipSplit :: Zipper Tree a -> (Tree0 a, Tree a)
zipSplit = \Zipper{value,context} -> buildAfter id id value context where
  buildAfter :: (Tree a -> x) -> (Tree a -> y) -> a -> Context Tree a -> (Maybe x, y)
  buildAfter f g a₀ = \case
    AtTop                     -> (Nothing, g (Top a₀))
    ta² :\- Hole              -> (Just (f (ta² :>- Nothing)), g (Top a₀))
    cta² :\ (Hole :< a₁, ma)  -> buildAfter 
                                  do f . (:>- Nothing) 
                                  do g . (:>- ma)
                                  do a₀ :× a₁
                                  do cta²
    cta² :\ (a_₁ :> Hole, ma) -> buildBoth 
                                  do Just (f (Top a_₁)) 
                                  do Just . f . (:>- Just a_₁) 
                                  do bitop g a₀ ma
                                  do surround g a₀ ma
                                  do cta²

  buildBoth  :: x -> (Tree a -> x) -> y -> (Tree a -> y) -> Context Tree a -> (x, y)
  buildBoth x f y g = \case
    AtTop                     -> (x, y)
    ta² :\- Hole              -> (f (ta² :>- Nothing), y)

    cta² :\ (a₀ :> Hole, ma)  -> buildBoth 
                                  do f (Top a₀)
                                  do f . (:>- Just a₀) 
                                  do maybe y (g . Top) ma
                                  do g . (:>- ma)
                                  do cta²
    cta² :\ (Hole :< a₁, ma)  -> buildBoth 
                                  do x
                                  do f . (:>- Nothing)
                                  do bitop g a₁ ma
                                  do surround g a₁ ma
                                  do cta²

  bitop :: (Tree a -> y) -> a -> Maybe a -> y
  bitop g a = g . (maybe <*> push) (Top a)

  surround :: (Tree a -> y) -> a -> Maybe a -> Tree (Pair a) -> y
  surround g a ma = g . unshift a . (:>- ma)

find :: (a -> Maybe b) -> Tree a -> Maybe b
find p = getAlt . foldMap (Alt . p)

-- | Given a tree and a predicate, find the longest prefix of 
-- that tree's elements that satisfy that predicate
--
-- complexity: O(|t|)
--
-- >>> span (< 'g') (Top (('a' :× 'b') :× ('c' :× 'g')) :>- Just ('f' :× 'e') :>- Just 'd')
-- These (Top ('a' :× 'b') :>- Just 'c') (Top (('g' :× 'f') :× ('e' :× 'd')) :>- Nothing :>- Nothing)
span :: (a -> Bool) -> Tree a -> These (Tree a) (Tree a)
span p ta = maybe
  do This ta
  do uncurry (maybe That These) . zipSplit
  do find (\za -> if p (value za) then Nothing else Just za) (zipDown ta)

-- | Given a tree and a predicate, find the longest prefix of 
-- that tree's elements that do not satisfy that predicate
--
-- complexity: O(|t|)
--
-- >>> break (== 'd') (Top (('a' :× 'b') :× ('c' :× 'd')) :>- Just ('e' :× 'f') :>- Just 'g')
-- These (Top ('a' :× 'b') :>- Just 'c') (Top (('d' :× 'e') :× ('f' :× 'g')) :>- Nothing :>- Nothing)
break :: (a -> Bool) -> Tree a -> These (Tree a) (Tree a)
break p = span (not . p)

splitAt :: Positive -> Tree a -> Maybe (Tree a, Tree a)
splitAt _ _ = Nothing

splitAt0 :: Natural -> Tree0 a -> (Tree0 a, Tree0 a)
splitAt0 _ _ = (Nothing, Nothing)

fuse :: Tree a -> Tree a -> Tree a
fuse = undefined

fuse0 :: Tree0 a -> Tree0 a -> Tree0 a
fuse0 = liftA2 fuse

fiss :: Positive -> Tree a -> Maybe (Tree a, Tree a)
fiss = undefined

fiss0 :: Natural -> Tree a -> (Tree0 a, Tree0 a)
fiss0 = undefined

fromNonEmpty :: NonEmpty a -> Tree a
fromNonEmpty = undefined

fromList :: [a] -> Tree0 a
fromList = fmap fromNonEmpty . NonEmpty.nonEmpty

toList :: Tree0 a -> [a]
toList = maybe [] (NonEmpty.toList . toNonEmpty)

generate :: Positive -> (Natural -> a) -> Tree a
generate = undefined

generate0 :: Natural -> (Natural -> a) -> Tree0 a
generate0 = maybe (const Nothing) (fmap Just . generate) . fromNatural

replicate :: Positive -> a -> Tree a
replicate n = generate n . const

replicate0 :: Natural -> a -> Tree0 a
replicate0 n = generate0 n . const
