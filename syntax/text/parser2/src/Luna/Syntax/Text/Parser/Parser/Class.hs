{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE PatternSynonyms      #-}
{-# LANGUAGE UndecidableInstances #-}

module Luna.Syntax.Text.Parser.Parser.Class where

import           Prologue hiding (fail, optional)
import qualified Prologue

import qualified Control.Monad.State.Layered               as State
import qualified Data.Graph.Component.Node.Destruction     as Component
import qualified Data.Map                                  as Map
import qualified Data.Set                                  as Set
import qualified Data.Text.Position                        as Position
import qualified Data.Text.Span                            as Span
import qualified Data.Vector                               as Vector
import qualified Language.Symbol.Operator.Assoc            as Assoc
import qualified Language.Symbol.Operator.Prec             as Prec
import qualified Luna.IR                                   as IR
import qualified Luna.IR.Aliases                           as Uni
import qualified Luna.IR.Term.Ast.Invalid                  as Invalid
import qualified Luna.Pass                                 as Pass
import qualified Luna.Syntax.Text.Parser.Data.Ast          as Ast
import qualified Luna.Syntax.Text.Parser.Data.CodeSpan     as CodeSpan
import qualified Luna.Syntax.Text.Parser.Data.Name.Special as Name
import qualified Luna.Syntax.Text.Scope                    as Scope
import qualified Text.Parser.State.Indent                  as Indent
import qualified Text.Parser.State.Indent                  as Indent

import Data.Map                              (Map)
import Data.Set                              (Set)
import Data.Text.Position                    (Delta (Delta), Position)
import Data.Vector                           (Vector)
import Luna.Syntax.Text.Parser.Data.Ast      (Spanned (Spanned))
import Luna.Syntax.Text.Parser.Data.CodeSpan (CodeSpan)
import Luna.Syntax.Text.Parser.Lexer         (Ast)
import Luna.Syntax.Text.Source               (Source)
import OCI.Data.Name                         (Name)
import Text.Parser.State.Indent              (Indent)
-- import Luna.Syntax.Text.Parser.Data.Result   (Result)


import Luna.Syntax.Text.Parser.Parser.ExprBuilder (ExprBuilderMonad, buildExpr,
                                      checkLeftSpacing)

import qualified Data.Attoparsec.Internal       as AParsec
import qualified Data.Attoparsec.Internal.Types as AParsec
import qualified Data.Attoparsec.List           as Parsec
import qualified GHC.Exts                       as GHC

import           Data.Parser hiding (anyToken, peekToken)
import qualified Data.Parser as Parser

import Data.Parser.Instances.Attoparsec ()



----------------------
-- === Reserved === --
----------------------

-- === Definition === --

newtype Reserved a = Reserved (Set a)
    deriving (Default, Show)
makeLenses ''Reserved

type family ReservedType m where
    ReservedType (State.StateT (Reserved a) _) = a
    ReservedType (t m)                         = ReservedType m

type ReservedM       m = Reserved (ReservedType m)
type MonadReserved'  m = MonadReserved (Token m) m
type MonadReserved a m =
    ( State.Monad (ReservedM m) m
    , MonadFail m
    , Ord (ReservedType m)
    , Convertible' a (ReservedType m)
    )


-- === API === --

withReserved :: ∀ a t m. MonadReserved a m => a -> m t -> m t
withReserved = \a -> State.withModified @(ReservedM m)
                   $ wrapped %~ Set.insert (convert' a)
{-# INLINE withReserved #-}

withManyReserved :: ∀ a t m. MonadReserved a m => [a] -> m t -> m t
withManyReserved = \a -> State.withModified @(ReservedM m)
                       $ wrapped %~ (Set.fromList (convert' <$> a) <>)
{-# INLINE withManyReserved #-}

checkReserved :: ∀ a m. MonadReserved a m => a -> m Bool
checkReserved = \a -> Set.member (convert' a) . unwrap
                  <$> State.get @(ReservedM m)
{-# INLINE checkReserved #-}

failIfReserved :: MonadReserved a m => a -> m ()
failIfReserved = \a -> checkReserved a >>= \case
    True  -> Prologue.fail "reserved"
    False -> pure ()
{-# INLINE failIfReserved #-}

notReserved :: MonadReserved a m => m a -> m a
notReserved = (>>= (\a -> a <$ failIfReserved a))
{-# INLINE notReserved #-}

anyTokenNotReserved :: (MonadReserved' m, TokenParser m) => m (Token m)
anyTokenNotReserved = notReserved Parser.anyToken
{-# INLINE anyTokenNotReserved #-}

peekTokenNotReserved :: (MonadReserved' m, TokenParser m) => m (Token m)
peekTokenNotReserved = notReserved Parser.peekToken
{-# INLINE peekTokenNotReserved #-}



-------------------
-- === Macro === --
-------------------

-- | Macro patterns are used to define non-standard mkMacro structures like
--   'if ... then ... else ...' or 'def foo a b: ...'. They work in a similar
--   fashion to Lisp macros.
--
--   Macro consist of one or more segments. Each mkSegment starts with a special
--   token match (like special keyword) and consist of many chunks. Chunk is
--   one of pre-defined symbol group defined by the 'Chunk'.


-- === Definition === --

data Chunk
    = Expr
    | ManyNonSpacedExpr
    | NonSpacedExpr
    | ExprBlock
    | ExprList

    -- To be removed in new syntax
    | ClassBlock
    deriving (Eq, Show)

data SegmentList
    = SegmentListCons SegmentType Segment SegmentList
    | SegmentListNull
    deriving (Eq, Show)

data SegmentType
    = Required
    | Optional
    deriving (Eq, Show)

data Segment = Segment
    { _segmentBase   :: Ast.Ast
    , _segmentChunks :: [Chunk]
    } deriving (Eq, Show)
makeLenses ''Segment

data Macro = Macro
    { _headSegment  :: Segment
    , _tailSegments :: SegmentList
    }
    deriving (Eq, Show)
makeLenses ''Macro



-- === Smart constructors === --

mkMacro :: Ast.Ast -> [Chunk] -> Macro
mkMacro = \ast pat -> Macro (Segment ast pat) SegmentListNull
{-# INLINE mkMacro #-}

mkSegment :: Ast.Ast -> [Chunk] -> Segment
mkSegment = Segment
{-# INLINE mkSegment #-}

singularOptionalSegmentList :: Segment -> SegmentList
singularOptionalSegmentList = \s -> SegmentListCons Optional s SegmentListNull
{-# INLINE singularOptionalSegmentList #-}

singularRequiredSegmentList :: Segment -> SegmentList
singularRequiredSegmentList = \s -> SegmentListCons Required s SegmentListNull
{-# INLINE singularRequiredSegmentList #-}

infixl 6 +?
infixl 6 +!
(+?), (+!) :: Macro -> Segment -> Macro
(+?) = \l r -> appendSegment l (singularOptionalSegmentList r)
(+!) = \l r -> appendSegment l (singularRequiredSegmentList r)
{-# INLINE (+?) #-}
{-# INLINE (+!) #-}


-- === Utils === --

concatSegmentList :: SegmentList -> SegmentList -> SegmentList
concatSegmentList = go where
    go l r = case l of
        SegmentListNull           -> r
        SegmentListCons tp sect t -> SegmentListCons tp sect (go t r)
{-# INLINE concatSegmentList #-}

appendSegment :: Macro -> SegmentList -> Macro
appendSegment = \sect r -> sect & tailSegments %~ flip concatSegmentList r
{-# INLINE appendSegment #-}



----------------------------
-- === Macro Registry === --
----------------------------

-- === Definition === --

newtype Registry = Registry (Map Ast.Ast Macro)
    deriving (Default, Show)
makeLenses ''Registry


-- === API === --

registerSection :: State.Monad Registry m => Macro -> m ()
registerSection = \section -> State.modify_ @Registry
    $ wrapped %~ Map.insert (section ^. headSegment . segmentBase) section
{-# INLINE registerSection #-}

lookupSection :: State.Getter Registry m => Ast.Ast -> m (Maybe Macro)
lookupSection = \ast -> Map.lookup ast . unwrap <$> State.get @Registry
{-# INLINE lookupSection #-}




--------------------
-- === Parser === --
--------------------

-- === Definition === --

-- | Parser is just a monad transformer over Attoparsec tagged with a label
--   "total" or "partial". Total parsers are those who never fail and always
--   consume the input, while partial parsers could fail. We use the information
--   while constructing the parsers to make sure we handle unexpected code in
--   the best possible way.

type Parser      = ParserT 'Total
type Parser'     = ParserT 'Partial
type ParserT t   = ParserBase t ParserStack
type ParserStack = State.StatesT
   '[ Scope.Scope
    , Reserved Ast.Ast
    , Position
    , Indent
    , Registry
    ] (Parsec.Parser Ast)

data ParserType
    = Total
    | Partial

newtype ParserBase (t :: ParserType) m a = ParserBase (IdentityT m a) deriving
    ( Alternative, Applicative, Assoc.Reader name, Assoc.Writer name, Functor
    , Monad, MonadFail, MonadTrans, Prec.RelReader name, Prec.RelWriter name)
makeLenses ''ParserBase

type instance Token  (ParserBase t m) = Token  m
type instance Tokens (ParserBase t m) = Tokens m


-- === Running === --

run :: [Ast] -> Parser a -> Either String a
run = \stream
   -> flip Parsec.parseOnly (Vector.fromList stream)
    . State.evalDefT @Registry
    . Indent.eval
    . State.evalDefT @Position
    . State.evalDefT @(Reserved Ast.Ast)
    . State.evalDefT @Scope.Scope
    . runParserBase
{-# INLINE run #-}

runParserBase :: ParserBase t m a -> m a
runParserBase = runIdentityT . unwrap
{-# INLINE runParserBase #-}



-- === Total / Partial management === --

total :: a -> ParserT t a -> Parser a
total = unsafeCoerceParser .: option
{-# INLINE total #-}

partial :: ParserT t a -> Parser' a
partial = unsafeCoerceParser
{-# INLINE partial #-}

(<||>) :: ParserT t a -> ParserT s a -> ParserT s a
(<||>) = \l r -> unsafeCoerceParser l <|> r
{-# INLINE (<||>) #-}

unsafeCoerceParser :: ParserBase t m a -> ParserBase t' m a
unsafeCoerceParser = coerce
{-# INLINE unsafeCoerceParser #-}




-------------------------
-- === Macro utils === --
-------------------------

segmentsToks :: SegmentList -> [Ast.Ast]
segmentsToks = \case
    SegmentListNull -> mempty
    SegmentListCons _ (Segment seg _) lst -> seg : segmentsToks lst
{-# INLINE segmentsToks #-}

withNextSegmentsReserved :: SegmentList -> Parser' a -> Parser' a
withNextSegmentsReserved = withManyReserved . segmentsToks
{-# INLINE withNextSegmentsReserved #-}



---------------------
-- === Parsers === --
---------------------

-- === Primitive === --

peekToken :: Parser Ast
peekToken = Parser.peekToken
{-# INLINE peekToken #-}

anyToken :: Parser Ast
anyToken = Parser.anyToken
{-# INLINE anyToken #-}

fail :: String -> Parser' a
fail = Prologue.fail
{-# INLINE fail #-}


-- === Assertions === --

nextTokenNotLeftSpaced :: Parser' ()
nextTokenNotLeftSpaced = do
    tok <- partial peekToken
    when_ (checkLeftSpacing tok) $ fail "spaced"
{-# INLINE nextTokenNotLeftSpaced #-}

nextTokenLeftSpaced :: Parser' ()
nextTokenLeftSpaced = do
    tok <- partial peekToken
    when_ (not $ checkLeftSpacing tok) $ fail "not spaced"
{-# INLINE nextTokenLeftSpaced #-}

leftSpaced :: ParserT t Ast -> Parser' Ast
leftSpaced = \mtok -> do
    tok <- partial mtok
    if checkLeftSpacing tok
        then pure tok
        else fail "not spaced"
{-# INLINE leftSpaced #-}

anySymbol :: Parser' Ast
anySymbol = peekSymbol <* dropToken
{-# INLINE anySymbol #-}

peekSymbol :: Parser' Ast
peekSymbol = do
    tok <- partial peekToken
    case Ast.unspan tok of
        Ast.AstLineBreak {} -> fail "not a symbol"
        _                   -> pure tok
{-# INLINE peekSymbol #-}

anySymbolNotReserved :: Parser' Ast
anySymbolNotReserved = notReserved anySymbol
{-# INLINE anySymbolNotReserved #-}

-- peekSymbolNotReserved :: Parser' Ast
-- peekSymbolNotReserved = notReserved peekSymbol
-- {-# INLINE peekSymbolNotReserved #-}

satisfyAst :: (Ast.Ast -> Bool) -> Parser' Ast
satisfyAst = \f -> peekSatisfyAst f <* dropToken
{-# INLINE satisfyAst #-}

peekSatisfyAst :: (Ast.Ast -> Bool) -> Parser' Ast
peekSatisfyAst = \f -> notReserved $ do
    tok <- partial peekToken
    if f (Ast.unspan tok)
        then pure tok
        else fail "satisfy"
{-# INLINE peekSatisfyAst #-}

ast :: Ast.Ast -> Parser' Ast
ast = satisfyAst . (==)
{-# INLINE ast #-}

unsafeLineBreak :: Parser' Ast
unsafeLineBreak = do
    tok <- partial anyToken
    case Ast.unspan tok of
        Ast.LineBreak off -> do
            Position.succLine
            Position.incColumn off
            pure tok
        _ -> fail "not a line break"
{-# INLINE unsafeLineBreak #-}

unsafeLineBreaks :: Parser' [Ast]
unsafeLineBreaks = many1 unsafeLineBreak
{-# INLINE unsafeLineBreaks #-}

-- | The current implementation works on token stream where some tokens are
--   line break indicators. After consuming such tokens we need to register them
--   as offset in the following token.
brokenLst1 :: Parser' (NonEmpty Ast) -> Parser' (NonEmpty Ast)
brokenLst1 = \f -> do
    spans     <- toksSpanAsSpace <$> unsafeLineBreaks
    (a :| as) <- f
    let a' = a & Ast.span %~ (spans <>)
    pure (a' :| as)
{-# INLINE brokenLst1 #-}

brokenLst1' :: Parser' (NonEmpty Ast) -> Parser' [Ast]
brokenLst1' = fmap convert . brokenLst1
{-# INLINE brokenLst1' #-}

unsafeBrokenLst :: Parser' [Ast] -> Parser' [Ast]
unsafeBrokenLst = \f -> do
    spans    <- toksSpanAsSpace <$> unsafeLineBreaks
    (a : as) <- f
    let a' = a & Ast.span %~ (spans <>)
    pure (a' : as)
{-# INLINE unsafeBrokenLst #-}

broken :: ParserT t Ast -> Parser' Ast
broken = \f -> do
    spans <- toksSpanAsSpace <$> unsafeLineBreaks
    tok   <- partial f
    pure $ tok & Ast.span %~ (spans <>)
{-# INLINE broken #-}

possiblyBroken :: ParserT t Ast -> ParserT t Ast
possiblyBroken = \p -> broken (Indent.indented *> p) <||> p
{-# INLINE possiblyBroken #-}

anyExprToken :: Parser Ast
anyExprToken = possiblyBroken anyToken
{-# INLINE anyExprToken #-}

toksSpanAsSpace :: [Ast] -> CodeSpan
toksSpanAsSpace = CodeSpan.asOffsetSpan . mconcat . fmap (view Ast.span)
{-# INLINE toksSpanAsSpace #-}





-- === Macro building block parsers === --

chunk :: Chunk -> Parser' Ast
chunk = \case
    Expr              -> partial $ possiblyBroken nonBlockExprBody
    NonSpacedExpr     -> nonSpacedExpr
    ManyNonSpacedExpr -> manyNonSpacedExpr
    ExprBlock         -> partial expr -- FIXME
    ExprList          -> exprList
    ClassBlock        -> classBlock
{-# INLINE chunk #-}

chunks :: [Chunk] -> Parser' [Ast]
chunks = mapM chunk
{-# NOINLINE chunks #-}


-- === Degment parsers === --

segment :: Segment -> Parser' [Ast]
segment = chunks . view segmentChunks
{-# INLINE segment #-}

segmentList :: Name -> SegmentList -> Parser' (Name, [Spanned [Ast]])
segmentList = go where
    go = \name -> \case
        SegmentListNull -> pure (name, mempty)
        SegmentListCons tp seg lst' -> do
            let name' = name <> "_" <> showSection (seg ^. segmentBase)
            acceptSegment name' seg lst' <|> discardSegment name name' lst' tp

    acceptSegment name seg lst = do
        tok <- partial anyExprToken
        when_ (Ast.unspan tok /= (seg ^. segmentBase)) $ fail "not a segment"
        outs <- withNextSegmentsReserved lst (segment seg)
        (Ast.Spanned (tok ^. Ast.span) outs:) <<$>> segmentList name lst

    discardSegment name name' lst = \case
        Optional -> pure (name, mempty)
        Required -> (Ast.Spanned mempty [Ast.invalid Invalid.MissingSection]:)
            <<$>> segmentList name' lst


-- === Section parsers === --

macro :: Ast -> Macro -> Parser' [Ast]
macro = \t@(Ast.Spanned span tok) (Macro seg lst) -> do
    psegs <- withNextSegmentsReserved lst $ segment seg

    let simpleOp = pure $ t : psegs
        standard = do
            (name, spanLst) <- segmentList (showSection tok) lst
            let (tailSpan, slst) = mergeSpannedLists spanLst
            let header = Ast.Spanned span $ Ast.Var name
                group  = Ast.apps header  $ psegs <> slst
                out    = group & Ast.span %~ (<> tailSpan)
            pure [out]

    case seg ^. segmentBase of
        Ast.Operator {} -> if lst == SegmentListNull then simpleOp else standard
        _ -> standard
{-# INLINE macro #-}

mergeSpannedLists :: [Spanned [Ast]] -> (CodeSpan, [Ast])
mergeSpannedLists = \lst -> let
    prependSpan span = Ast.span %~ (CodeSpan.prependAsOffset span)
    in case lst of
        [] -> (mempty, mempty)
        (Ast.Spanned span a : as) -> case a of
            (t:ts) -> ((prependSpan span t : ts) <>) <$> mergeSpannedLists as
            []     -> let
                (tailSpan, lst) = mergeSpannedLists as
                in case lst of
                    []     -> (span <> tailSpan, lst)
                    (t:ts) -> (tailSpan, (prependSpan span t : ts))
{-# INLINE mergeSpannedLists #-}

showSection :: Ast.Ast -> Name
showSection = \case
    Ast.Var      n -> n
    Ast.Cons     n -> n
    Ast.Operator n -> n
    x -> error $ ppShow x
{-# INLINE showSection #-}


-------------------------
-- === Expressions === --
-------------------------

-- === Utils === --

emptyExpression :: Ast
emptyExpression = Ast.invalid Invalid.EmptyExpression
{-# INLINE emptyExpression #-}



-- === API === --

expr :: Parser Ast
expr = total emptyExpression expr'
{-# INLINE expr #-}

expr' :: Parser' Ast
expr' = blockExpr' <|> nonBlockExpr'
{-# INLINE expr' #-}

blockExpr' :: Parser' Ast
blockExpr' = discoverBlock1 nonBlockExpr' <&> \case
    (a :| []) -> a
    as -> Ast.block as
{-# INLINE blockExpr' #-}





-- TODO: refactor marker handling in nonBlockExpr and nonBlockExpr'
nonBlockExpr :: Parser Ast
nonBlockExpr = do
    let marked = do
            marker <- satisfyAst isMarker
            nonBlockExpr <- partial nonBlockExprBody
            pure $ Ast.app marker nonBlockExpr

    Indent.withCurrent $ marked <||> nonBlockExprBody
{-# INLINE nonBlockExpr #-}

unit :: Parser Ast
unit = total emptyExpression $ Ast.unit <$> body where
    body     = nonEmpty <|> empty
    nonEmpty = Ast.block <$> block1 nonBlockExpr'
    empty    = pure Ast.missing
{-# INLINE unit #-}

nonBlockExpr' :: Parser' Ast
nonBlockExpr' = do
    let marked = do
            marker <- satisfyAst isMarker
            expr   <- nonBlockExprBody'
            pure $ Ast.app marker expr

    Indent.withCurrent $ marked <|> nonBlockExprBody'
{-# INLINE nonBlockExpr' #-}

nonBlockExprBody :: Parser Ast
nonBlockExprBody = total emptyExpression nonBlockExprBody'
{-# INLINE nonBlockExprBody #-}

isComment :: Ast.Ast -> Bool
isComment = \case
    Ast.Comment {} -> True
    _ -> False

assertNotComment :: Ast -> Parser' ()
assertNotComment = \tok -> when_ (isComment $ Ast.unspan tok)
    $ fail "Assertion failed: got a comment."
{-# INLINE assertNotComment #-}

nonBlockExprBody' :: Parser' Ast
nonBlockExprBody' = documented <|> unusedComment <|> body where
    documented    = Ast.documented <$> satisfyAst isComment <*> docBase
    unusedComment = satisfyAst isComment
    docBase       = broken (Indent.indentedEq *> body)

    body          = buildExpr . convert =<< lines
    line          = (\x -> buildExpr $ {- trace ("\n\n+++\n" <> ppShow x) -} x) =<< multiLineToks
    lines         = (:|) <$> line <*> nextLines
    nextLines     = option mempty (brokenLst1' $ Indent.indented *> lines)
    lineJoin      = satisfyAst Ast.isOperator <* leftSpaced peekSymbol
    multiLineToks = (lineToks <* dropComment) <**> lineTailToks
    dropComment   = option () (() <$ satisfyAst isComment)
    lineTailToks  = option id $ flip (<>) <$> brokenLst1' lineContToks
    lineContToks  = Indent.indented *> ((:|) <$> lineJoin <*> multiLineToks)
    lineToks      = fmap concat . many1 $ do
        tok <- anySymbolNotReserved
        assertNotComment tok
        let sym = Ast.unspan tok
        lookupSection sym >>= \case
            Just sect -> macro tok sect
            Nothing   -> case sym of
                Ast.Operator _ -> (tok:) <$> option [] (pure <$> blockExpr')
                _              -> pure [tok]
{-# INLINE nonBlockExprBody' #-}

manyNonSpacedExpr :: Parser' Ast
manyNonSpacedExpr = Ast.list <$> many nonSpacedExpr'
{-# INLINE manyNonSpacedExpr #-}

nonSpacedExpr :: Parser' Ast
nonSpacedExpr = option emptyExpression nonSpacedExpr'
{-# INLINE nonSpacedExpr #-}

nonSpacedExpr' :: Parser' Ast
nonSpacedExpr' = buildExpr =<< go where
    go = do
        tok  <- anySymbolNotReserved
        head <- lookupSection (Ast.unspan tok) >>= \case
            Nothing   -> pure  [tok]
            Just sect -> macro tok sect
        let loop = nextTokenNotLeftSpaced >> go
        (head <>) <$> option mempty loop
{-# INLINE nonSpacedExpr' #-}





exprList :: Parser' Ast
exprList = Ast.list <$> lst where
    lst      = option mempty $ nonEmpty <|> empty
    nonEmpty = (:) <$> seg segBody <*> many nextSeg
    empty    = (Ast.missing:) <$> many1 nextSeg
    nextSeg  = Ast.prependAsOffset <$> sep <*> seg (optional segBody)
    segs     = many nextSeg
    seg p    = possiblyBroken $ withReserved sepOp p
    sep      = possiblyBroken $ ast sepOp
    segBody  = nonBlockExprBody'
    sepOp    = Ast.Operator ","
{-# INLINE exprList #-}




--------------------
-- === Layout === --
--------------------

discoverBlock1 :: Parser' Ast -> Parser' (NonEmpty Ast)
discoverBlock1 = \p -> brokenLst1 $ Indent.indented *> block1 p
{-# INLINE discoverBlock1 #-}

block1 :: Parser' Ast -> Parser' (NonEmpty Ast)
block1 = Indent.withCurrent . blockBody1
{-# INLINE block1 #-}

blockBody1 :: Parser' Ast -> Parser' (NonEmpty Ast)
blockBody1 = \p -> (:|) <$> p <*> many (broken $ Indent.indentedEq *> p)
{-# INLINE blockBody1 #-}

block :: Parser' Ast -> Parser [Ast]
block = optionBlock . block1
{-# INLINE block #-}

blockBody :: Parser' Ast -> Parser [Ast]
blockBody = optionBlock . blockBody1
{-# INLINE blockBody #-}

optionBlock :: Parser' (NonEmpty Ast) -> Parser [Ast]
optionBlock = total mempty . fmap convert
{-# INLINE optionBlock #-}




optional :: Parser' Ast -> Parser' Ast
optional = option Ast.missing
{-# INLINE optional #-}


classBlock :: Parser' Ast
classBlock = broken $ do
    let conses = many classCons
    Ast.list <$> conses

classCons :: Parser' Ast
classCons = Ast.app <$> withReserved blockStartOp base <*> (blockDecl <|> inlineDecl) where
    base       = satisfyAst isCons
    inlineDecl = Ast.list <$> many unnamedField
    blockDecl   = ast blockStartOp *> blockDecl'
    blockStartOp = Ast.Operator ":"
    blockDecl'  = Ast.list <$> (unsafeBrokenLst $ Indent.indented *> Indent.withCurrent blockDeclLines)
    blockDeclLines :: Parser' [Ast]
    blockDeclLines  = (:) <$> namedFields <*> blockDeclLines'
    blockDeclLines' = option mempty $ unsafeBrokenLst (Indent.indentedEq *> blockDeclLines)


unnamedField :: Parser' Ast
unnamedField = do
    tp <- nonSpacedExpr'
    let f  = Ast.Spanned mempty $ Ast.Var "#fields#"
        ns = Ast.Spanned mempty $ Ast.List []
    pure $ Ast.apps f [ns, tp]

namedFields :: Parser' Ast
namedFields = do
    let tpOp = Ast.Operator "::"
    ns <- Ast.list <$> withReserved tpOp (many1 nonSpacedExpr')
    op <- ast tpOp
    tp <- nonSpacedExpr'
    let f  = Ast.Spanned mempty $ Ast.Var "#fields#"
    pure $ Ast.apps f [ns, tp]

isCons :: Ast.Ast -> Bool
isCons = \case
    Ast.Cons {} -> True
    _ -> False
{-# INLINE isCons #-}

isMarker :: Ast.Ast -> Bool
isMarker = \case
    Ast.Marker {} -> True
    _ -> False
{-# INLINE isMarker #-}

-- record :: Parser' (IRBS SomeTerm)
-- record = irbs $ (\nat n args (cs,ds) -> liftIRBS3 (irb5 IR.record' nat n) (sequence args) (sequence cs) (sequence ds))
--    <$> try (option False (True <$ symbol Lexer.KwNative) <* symbol Lexer.KwClass) <*> consName <*> many var <*> body
--     where body      = option mempty $ symbol Lexer.BlockStart *> bodyBlock
--           funcBlock = optionalBlockBody (possiblyDocumented func)
--           consBlock = breakableNonEmptyBlockBody' recordCons <|> breakableOptionalBlockBody recordNamedFields
--           bodyBlock = discoverIndent ((,) <$> consBlock <*> funcBlock)

-- recordCons :: Parser' (IRBS SomeTerm)
-- recordCons = ... <$> consName <*> (blockDecl <|> inlineDecl) where
--     blockDecl  = symbol Lexer.BlockStart *> possibleNonEmptyBlock' recordNamedFields
--     inlineDecl = many unnamedField

-- recordNamedFields :: Parser' (IRBS SomeTerm)
-- recordNamedFields = irbs $ do
--     varNames <- Mutable.fromList =<< many varName
--     liftIRBS1 (irb2 IR.recordFields' varNames) <$ symbol Lexer.Typed <*> valExpr

-- unnamedField :: Parser' (IRBS SomeTerm)
-- unnamedField = do
--     m <- Mutable.new
--     irbs $ liftIRBS1 (irb2 IR.recordFields' m)
--                       <$> nonSpacedValExpr




-------------------------------
-- === Predefined Macros === --
-------------------------------

-- | We might want to define these macros in stdlib in the future. However,
--   the real question is if we want to give the end user power to define
--   such customizable syntax.

syntax_if_then_else :: Macro
syntax_if_then_else = mkMacro
                 (Ast.Var "if")   [Expr]
    +! mkSegment (Ast.Var "then") [ExprBlock]
    +? mkSegment (Ast.Var "else") [ExprBlock]

syntax_case :: Macro
syntax_case = mkMacro
                 (Ast.Var "case") [Expr]
    +! mkSegment (Ast.Var "of")   [ExprBlock]

syntax_group :: Macro
syntax_group = mkMacro
                 (Ast.Operator "(") [ExprList]
    +! mkSegment (Ast.Operator ")") []

syntax_list :: Macro
syntax_list = mkMacro
                 (Ast.Operator "[") [ExprList]
    +! mkSegment (Ast.Operator "]") []

syntax_funcDef :: Macro
syntax_funcDef = mkMacro
                 (Ast.Var      "def") [NonSpacedExpr, ManyNonSpacedExpr]
    +! mkSegment (Ast.Operator ":")   [ExprBlock]

syntax_classDef :: Macro
syntax_classDef = mkMacro
                 (Ast.Var      "class") [NonSpacedExpr, ManyNonSpacedExpr]
    +! mkSegment (Ast.Operator ":")     [ClassBlock]

syntax_lambda :: Macro
syntax_lambda = mkMacro (Ast.Operator ":") [ExprBlock]

hardcodePredefinedMacros :: State.Monad Registry m => m ()
hardcodePredefinedMacros = mapM_ registerSection
    [ syntax_if_then_else
    , syntax_case
    , syntax_group
    , syntax_list
    , syntax_funcDef
    , syntax_lambda
    , syntax_classDef
    ]