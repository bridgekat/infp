-- ApiMu/FOL verifier v0.1 (Haskell version)
-- Licensed under Creative Commons CC0 (no copyright reserved, use at your will)

-- This variant of FOL & ND is largely based on Dirk van Dalen's *Logic and Structure*...
-- To keep in line with the proof language, some context-changing rules are now represented in terms of
-- `impliesIntro` and `forallIntro`; additional features are described in `notes/design.md`.

{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}
{-# LANGUAGE PatternSynonyms #-}

module FOLPlus where

import Data.List


data CInfo = CVar Type | CHyp Expr
  deriving (Eq, Show)

-- Contraction and permutation should be allowed, but currently they are not needed; weakening is stated below.
-- If there are naming clashes, later names will override
-- (TODO: hide this constructor when exporting)
newtype Context = Context { ctxList :: [(String, CInfo)] }
  deriving (Eq)

instance Show Context where
  show (Context ls) = foldl (\acc (id, t) -> id ++ " : " ++ show t ++ "\n" ++ acc) "" ls

ctxEmpty :: Context
ctxEmpty = Context []

ctxVar :: String -> Context -> Context
ctxVar id (Context ctx) =
  Context ((id, CVar TTerm) : ctx)

ctxFunc :: String -> Int -> Sort -> Context -> Context
ctxFunc id arity sort (Context ctx)
  | arity >= 0 = Context ((id, CVar $ TFunc arity sort) : ctx)

ctxAssumption :: String -> Theorem -> Context
ctxAssumption id (Theorem (Context ctx, HasType p TFormula)) =
  Context ((id, CHyp p) : ctx)

-- Bound variables are represented using de Brujin indices
-- (0 = binds to the deepest binder, 1 = escapes one binder, and so on)
data VarName = Free String | Bound Int
  deriving (Eq)

-- Possible "types" of expressions (proof terms do not count as expressions here):
--   Terms:      TFunc 0 SVar  (ι)
--   Functions:  TFunc k SVar  (ι → ... → ι → ι)
--   Formulas:   TFunc 0 SProp (*)
--   Predicates: TFunc k SProp (ι → ... → ι → *)
-- Schemas have exactly one "second-order lambda" in front of them:
--   TSchema k1 s1 k2 s2 means ((ι → ... → ι → s1) → ι → ... → ι → s2).
data Sort = SVar | SProp
  deriving (Eq, Show)
data Type = TFunc Int Sort | TSchema Int Sort Int Sort
  deriving (Eq, Show)

pattern TTerm :: Type
pattern TTerm = TFunc 0 SVar

pattern TFormula :: Type
pattern TFormula = TFunc 0 SProp

data Expr =
    Var VarName
  | Func VarName [Expr]
  | Schema VarName Expr
  | Eq Expr Expr
  | Top    -- To avoid naming clashes I did not use `True` here
  | Bottom -- Also here
  | Not Expr
  | And Expr Expr
  | Or Expr Expr
  | Implies Expr Expr
  | Iff Expr Expr
  | Forall String Expr
  | Exists String Expr
  | Unique String Expr
  -- This must be at the beginning (the outermost layer) of an expression, and can only occur once
  | ForallFunc String Int Sort Expr
  -- These must be at the beginning (the outermost layers) of an expression
  | Lam String Expr

-- Ignore the names of bound variables when comparing
instance Eq Expr where
  (==) (Var x1)                (Var y1)                = x1 == y1
  (==) (Func x1 x2)            (Func y1 y2)            = x1 == y1 && x2 == y2
  (==) (Schema x1 x2)          (Schema y1 y2)          = x1 == y1 && x2 == y2
  (==) (Eq x1 x2)              (Eq y1 y2)              = x1 == y1 && x2 == y2
  (==) Top                     Top                     = True
  (==) Bottom                  Bottom                  = True
  (==) (Not x1)                (Not y1)                = x1 == y1
  (==) (And x1 x2)             (And y1 y2)             = x1 == y1 && x2 == y2
  (==) (Or x1 x2)              (Or y1 y2)              = x1 == y1 && x2 == y2
  (==) (Implies x1 x2)         (Implies y1 y2)         = x1 == y1 && x2 == y2
  (==) (Iff x1 x2)             (Iff y1 y2)             = x1 == y1 && x2 == y2
  (==) (Forall _ x1)           (Forall _ y1)           = x1 == y1
  (==) (Exists _ x1)           (Exists _ y1)           = x1 == y1
  (==) (Unique _ x1)           (Unique _ y1)           = x1 == y1
  (==) (ForallFunc _ x1 x2 x3) (ForallFunc _ y1 y2 y3) = x1 == y1 && x2 == y2 && x3 == y3
  (==) (Lam _ x1)              (Lam _ y1)              = x1 == y1
  (==) _                       _                       = False

newName :: String -> [String] -> String
newName x used
  | x `notElem` used = x
  | otherwise        = newName (x ++ "'") used

showName :: [String] -> VarName -> String
showName stk (Free s)  = s
showName stk (Bound i) = stk !! i

showE :: [String] -> [String] -> Expr -> String
showE used stk e' = case e' of
  (Var x) -> showName stk x
  (Func x as) -> "(" ++ showName stk x ++ concatMap ((" " ++) . showE used stk) as ++ ")"
  (Schema x e) -> "(" ++ showName stk x ++ " " ++ showE used stk e ++ ")"
  (Eq t1 t2) -> "(" ++ showE used stk t1 ++ " = " ++ showE used stk t2 ++ ")"
  Top -> "true"
  Bottom -> "false"
  (Not e) -> "not " ++ showE used stk e
  (And e1 e2) -> "(" ++ showE used stk e1 ++ " and " ++ showE used stk e2 ++ ")"
  (Or e1 e2) -> "(" ++ showE used stk e1 ++ " or " ++ showE used stk e2 ++ ")"
  (Implies e1 e2) -> "(" ++ showE used stk e1 ++ " implies " ++ showE used stk e2 ++ ")"
  (Iff e1 e2) -> "(" ++ showE used stk e1 ++ " iff " ++ showE used stk e2 ++ ")"
  (Forall x e) -> "(forall " ++ x' ++ ", " ++ showE (x' : used) (x' : stk) e ++ ")" where x' = newName x used
  (Exists x e) -> "(exists " ++ x' ++ ", " ++ showE (x' : used) (x' : stk) e ++ ")" where x' = newName x used
  (Unique x e) -> "(unique " ++ x' ++ ", " ++ showE (x' : used) (x' : stk) e ++ ")" where x' = newName x used
  (ForallFunc x k SVar  e) -> "(forallfunc " ++ x' ++ "/" ++ show k ++ ", " ++ showE (x' : used) (x' : stk) e ++ ")" where x' = newName x used
  (ForallFunc x k SProp e) -> "(forallpred " ++ x' ++ "/" ++ show k ++ ", " ++ showE (x' : used) (x' : stk) e ++ ")" where x' = newName x used
  (Lam x e) -> "any " ++ x' ++ ", " ++ showE (x' : used) (x' : stk) e where x' = newName x used

inContextShowE :: Context -> Expr -> String
inContextShowE (Context ls) = showE (map fst ls) []

instance Show Expr where
  show = showE [] []

-- n = (number of binders on top of current node)
updateVars :: Int -> (Int -> VarName -> Expr) -> Expr -> Expr
updateVars n f e = case e of
  (Var x) -> f n x
  (Func x es) -> Func x (map (updateVars n f) es)
  (Schema x e) -> Schema x (updateVars n f e)
  (Eq e1 e2) -> Eq (updateVars n f e1) (updateVars n f e2)
  Top -> e
  Bottom -> e
  (Not e1) -> Not (updateVars n f e1)
  (And e1 e2) -> And (updateVars n f e1) (updateVars n f e2)
  (Or e1 e2) -> Or (updateVars n f e1) (updateVars n f e2)
  (Implies e1 e2) -> Implies (updateVars n f e1) (updateVars n f e2)
  (Iff e1 e2) -> Iff (updateVars n f e1) (updateVars n f e2)
  (Forall x e1) -> Forall x (updateVars (n + 1) f e1)
  (Exists x e1) -> Exists x (updateVars (n + 1) f e1)
  (Unique x e1) -> Unique x (updateVars (n + 1) f e1)
  (ForallFunc x k s e1) -> ForallFunc x k s (updateVars (n + 1) f e1)
  (Lam x e1) -> Lam x (updateVars (n + 1) f e1)

-- Replace occurrences of a free variable by a given term
-- Pre: t is a well-formed term
replaceVar :: String -> Expr -> Expr -> Expr
replaceVar id t = updateVars 0 (\_ x -> if x == Free id then t else Var x)

-- Prepare to bind a free variable
-- Note that the resulting expression is not well-formed until one additional layer of binder is added (there are "binding overflows by exactly one")
makeBound :: String -> Expr -> Expr
makeBound id = updateVars 0 (\n x -> if x == Free id then Var (Bound n) else Var x)

-- Inverse operation of makeBound
-- Input expression can be a subexpression which is not well-formed by itself (there can be "binding overflows by exactly one")
makeFree :: String -> Expr -> Expr
makeFree id = updateVars 0 (\n x -> if x == Bound n then Var (Free id) else Var x)

-- makeFree + replaceVar in one go
-- Input expression can be a subexpression which is not well-formed by itself (there can be "binding overflows by exactly one")
makeReplace :: Expr -> Expr -> Expr
makeReplace t = updateVars 0 (\n x -> if x == Bound n then t else Var x)

-- Prepare to insert k binders around a subexpression
-- Input expression can be a subexpression which is not well-formed by itself
makeGap :: Int -> Expr -> Expr
makeGap k = updateVars 0 (\n x -> case x of Bound m | m >= n -> Var (Bound (m + k)); _ -> Var x)

-- "Enhanced makeReplace" used on lambda function bodies, with t's possibly containing bound variables...
-- length ts == (the number of lambda binders)
makeReplace' :: [Expr] -> Expr -> Expr
makeReplace' ts = updateVars 0 (\n x -> case x of Bound m | m >= n -> makeGap n (ts' !! (m - n)); _ -> Var x)
  where ts' = reverse ts -- Leftmost arguments are used to substitute highest lambdas

-- Skip through lambda binders
getBody :: Expr -> Expr
getBody (Lam _ e) = getBody e
getBody e = e

-- n = (number of binders on top of current node)
updateFunc :: Int -> (Int -> VarName -> [Expr] -> Expr) -> Expr -> Expr
updateFunc n f e = case e of
  (Var x) -> e
  (Schema x e) -> Schema x (updateFunc n f e)
  (Func x es) -> f n x args where args = map (updateFunc n f) es
  (Eq e1 e2) -> Eq (updateFunc n f e1) (updateFunc n f e2)
  Top -> e
  Bottom -> e
  (Not e1) -> Not (updateFunc n f e1)
  (And e1 e2) -> And (updateFunc n f e1) (updateFunc n f e2)
  (Or e1 e2) -> Or (updateFunc n f e1) (updateFunc n f e2)
  (Implies e1 e2) -> Implies (updateFunc n f e1) (updateFunc n f e2)
  (Iff e1 e2) -> Iff (updateFunc n f e1) (updateFunc n f e2)
  (Forall x e1) -> Forall x (updateFunc (n + 1) f e1)
  (Exists x e1) -> Exists x (updateFunc (n + 1) f e1)
  (Unique x e1) -> Unique x (updateFunc (n + 1) f e1)
  (ForallFunc x k s e1) -> ForallFunc x k s (updateFunc (n + 1) f e1)
  (Lam x e1) -> Lam x (updateFunc (n + 1) f e1)

makeBoundFunc :: String -> Expr -> Expr
makeBoundFunc id = updateFunc 0 (\n f args -> if f == Free id then Func (Bound n) args else Func f args)

makeReplaceFunc :: Expr -> Expr -> Expr
makeReplaceFunc lamt = updateFunc 0 (\n f args -> if f == Bound n then makeReplace' args t else Func f args)
  where t = getBody lamt


data Judgment = HasType Expr Type | Provable Expr
  deriving (Eq, Show)

-- (TODO: hide this constructor when exporting)
newtype Theorem = Theorem (Context, Judgment)

thmContext :: Theorem -> Context
thmContext (Theorem (c, _)) = c

thmJudgment :: Theorem -> Judgment
thmJudgment (Theorem (_, j)) = j

instance Show Theorem where
  show (Theorem (c, j)) = "\n" ++ show c ++ "\n|- " ++ show j ++ "\n"


weaken :: Theorem -> Context -> Theorem
weaken (Theorem (ctx, j)) ctx' =
  case ctxList ctx `isSuffixOf` ctxList ctx' of
    True -> Theorem (ctx', j)

-- Formation rules (as in `notes/design.md`)

varMk :: Context -> String -> Theorem
varMk ctx id =
  case lookup id (ctxList ctx) of
    (Just (CVar TTerm)) ->
      Theorem (ctx, HasType (Var (Free id)) TTerm)

funcMk :: Context -> String -> [Theorem] -> Theorem
funcMk ctx id js =
  case lookup id (ctxList ctx) of
    (Just (CVar (TFunc l s)))
      | l == length as && all (== ctx) ctxs ->
        Theorem (ctx, HasType (Func (Free id) as) (TFunc 0 s))
      where
        (ctxs, as) = unzip . map (\x -> let Theorem (c, HasType t TTerm) = x in (c, t)) $ js

schemaMk :: String -> Theorem -> Theorem
schemaMk id (Theorem (ctx, HasType e (TFunc k1 s1))) =
  case lookup id (ctxList ctx) of
    (Just (CVar (TSchema k1' s1' k2 s2)))
      | k1 == k1' && s1 == s1' ->
        Theorem (ctx, HasType (Schema (Free id) e) (TFunc k2 s2))

eqMk :: Theorem -> Theorem -> Theorem
eqMk (Theorem (ctx, HasType t1 TTerm)) (Theorem (ctx', HasType t2 TTerm))
  | ctx == ctx' = Theorem (ctx, HasType (Eq t1 t2) TFormula)

topMk :: Context -> Theorem
topMk ctx = Theorem (ctx, HasType Top TFormula)

bottomMk :: Context -> Theorem
bottomMk ctx = Theorem (ctx, HasType Bottom TFormula)

notMk :: Theorem -> Theorem
notMk (Theorem (ctx, HasType e TFormula)) =
  Theorem (ctx, HasType (Not e) TFormula)

andMk :: Theorem -> Theorem -> Theorem
andMk (Theorem (ctx, HasType e1 TFormula)) (Theorem (ctx', HasType e2 TFormula))
  | ctx == ctx' = Theorem (ctx, HasType (And e1 e2) TFormula)

orMk :: Theorem -> Theorem -> Theorem
orMk (Theorem (ctx, HasType e1 TFormula)) (Theorem (ctx', HasType e2 TFormula))
  | ctx == ctx' = Theorem (ctx, HasType (Or e1 e2) TFormula)

impliesMk :: Theorem -> Theorem -> Theorem
impliesMk (Theorem (ctx, HasType e1 TFormula)) (Theorem (ctx', HasType e2 TFormula))
  | ctx == ctx' = Theorem (ctx, HasType (Implies e1 e2) TFormula)

iffMk :: Theorem -> Theorem -> Theorem
iffMk (Theorem (ctx, HasType e1 TFormula)) (Theorem (ctx', HasType e2 TFormula))
  | ctx == ctx' = Theorem (ctx, HasType (Iff e1 e2) TFormula)

-- (Context-changing rule)
forallMk :: Theorem -> Theorem
forallMk (Theorem (Context ((id, CVar TTerm) : ls), HasType e TFormula)) =
  Theorem (Context ls, HasType (Forall id (makeBound id e)) TFormula)

-- (Context-changing rule)
existsMk :: Theorem -> Theorem
existsMk (Theorem (Context ((id, CVar TTerm) : ls), HasType e TFormula)) =
  Theorem (Context ls, HasType (Exists id (makeBound id e)) TFormula)

-- (Context-changing rule)
uniqueMk :: Theorem -> Theorem
uniqueMk (Theorem (Context ((id, CVar TTerm) : ls), HasType e TFormula)) =
  Theorem (Context ls, HasType (Unique id (makeBound id e)) TFormula)

-- (Context-changing rule)
forallFuncMk :: Theorem -> Theorem
forallFuncMk (Theorem (Context ((id, CVar (TFunc k s)) : ls), HasType e TFormula)) =
  Theorem (Context ls, HasType (ForallFunc id k s (makeBoundFunc id e)) TFormula)

-- (Context-changing rule)
lamMk :: Theorem -> Theorem
lamMk (Theorem (Context ((id, CVar TTerm) : ls), HasType e (TFunc k s))) =
  Theorem (Context ls, HasType (Lam id (makeBound id e)) (TFunc (k + 1) s))


-- Introduction & elimination rules
-- Pre & post: `Provable ctx p` => `IsPred 0 ctx p`

assumption :: Context -> String -> Theorem
assumption ctx id =
  case lookup id (ctxList ctx) of
    Just (CHyp p) -> Theorem (ctx, Provable p)

andIntro :: Theorem -> Theorem -> Theorem
andIntro (Theorem (ctx,  Provable p))
         (Theorem (ctx', Provable q))
         | ctx == ctx' =
          Theorem (ctx,  Provable (p `And` q)) 

andLeft :: Theorem -> Theorem
andLeft (Theorem (ctx, Provable (p `And` q))) =
         Theorem (ctx, Provable p) 

andRight :: Theorem -> Theorem
andRight (Theorem (ctx, Provable (p `And` q))) =
          Theorem (ctx, Provable q)

orLeft :: Theorem -> Theorem -> Theorem
orLeft (Theorem (ctx,  Provable p))
       (Theorem (ctx', HasType q TFormula))
       | ctx == ctx' =
        Theorem (ctx,  Provable (p `Or` q))

orRight :: Theorem -> Theorem -> Theorem
orRight (Theorem (ctx,  HasType p TFormula))
        (Theorem (ctx', Provable q))
        | ctx == ctx' =
         Theorem (ctx,  Provable (p `Or` q))

orElim :: Theorem -> Theorem -> Theorem -> Theorem
orElim (Theorem (ctx,   Provable (p `Or` q)))
       (Theorem (ctx',  Provable (p' `Implies` r)))
       (Theorem (ctx'', Provable (q' `Implies` r')))
       | ctx == ctx' && ctx == ctx'' && p == p' && q == q' && r == r' =
        Theorem (ctx,   Provable r)

-- (Context-changing rule)
impliesIntro :: Theorem -> Theorem
impliesIntro (Theorem (Context ((_, CHyp p) : ls), Provable q)) =
              Theorem (Context ls, Provable (p `Implies` q))

impliesElim :: Theorem -> Theorem -> Theorem
impliesElim (Theorem (ctx,  Provable (p `Implies` q)))
            (Theorem (ctx', Provable p'))
            | ctx == ctx' && p == p' =
             Theorem (ctx,  Provable q)

notIntro :: Theorem -> Theorem
notIntro (Theorem (ctx, Provable (p `Implies` Bottom))) =
          Theorem (ctx, Provable (Not p))

notElim :: Theorem -> Theorem -> Theorem
notElim (Theorem (ctx,  Provable (Not p)))
        (Theorem (ctx', Provable p'))
        | ctx == ctx' && p == p' =
         Theorem (ctx,  Provable Bottom)

iffIntro :: Theorem -> Theorem -> Theorem
iffIntro (Theorem (ctx,  Provable (p `Implies` q)))
         (Theorem (ctx', Provable (q' `Implies` p')))
         | ctx == ctx' && p == p' && q == q' =
          Theorem (ctx,  Provable (p `Iff` q))

iffLeft :: Theorem -> Theorem -> Theorem
iffLeft (Theorem (ctx,  Provable (p `Iff` q)))
        (Theorem (ctx', Provable p'))
        | ctx == ctx' && p == p' =
         Theorem (ctx,  Provable q)

iffRight :: Theorem -> Theorem -> Theorem
iffRight (Theorem (ctx,  Provable (p `Iff` q)))
         (Theorem (ctx', Provable q'))
         | ctx == ctx' && q == q' =
          Theorem (ctx,  Provable p)

trueIntro :: Context -> Theorem
trueIntro ctx = Theorem (ctx, Provable Top)

falseElim :: Theorem -> Theorem -> Theorem
falseElim (Theorem (ctx,  Provable Bottom))
          (Theorem (ctx', HasType p TFormula))
          | ctx == ctx' =
           Theorem (ctx,  Provable p)

raa :: Theorem -> Theorem
raa (Theorem (ctx, Provable (Not p `Implies` Bottom))) =
     Theorem (ctx, Provable p)

eqIntro :: Theorem -> Theorem
eqIntro (Theorem (ctx, HasType t TTerm)) =
         Theorem (ctx, Provable (t `Eq` t))

eqElim :: Theorem -> Theorem -> Theorem -> Theorem
eqElim (Theorem (ctx,   HasType (Lam x px) (TFunc 1 SProp)))
       (Theorem (ctx',  Provable (a `Eq` b)))
       (Theorem (ctx'', Provable pa))
       | ctx == ctx' && pa == makeReplace a px =
        Theorem (ctx,   Provable (makeReplace b px))

-- (Context-changing rule)
forallIntro :: Theorem -> Theorem
forallIntro (Theorem (Context ((id, CVar TTerm) : ls), Provable p)) =
             Theorem (Context ls, Provable (Forall id (makeBound id p)))

forallElim :: Theorem -> Theorem -> Theorem
forallElim (Theorem (ctx,  Provable (Forall x q)))
           (Theorem (ctx', HasType t TTerm))
           | ctx == ctx' =
            Theorem (ctx,  Provable (makeReplace t q))

existsIntro :: Theorem -> Theorem -> Theorem -> Theorem
existsIntro (Theorem (ctx',  HasType (Exists x p) TFormula))
            (Theorem (ctx'', HasType t TTerm))
            (Theorem (ctx,   Provable pt))
            | ctx == ctx' && pt == makeReplace t p =
             Theorem (ctx,   Provable (Exists x p))

existsElim :: Theorem -> Theorem -> Theorem -> Theorem
existsElim (Theorem (ctx,   Provable (Exists x p)))
           (Theorem (ctx',  Provable (Forall y (p' `Implies` q))))
           (Theorem (ctx'', HasType q' TFormula))
           | ctx == ctx' && ctx == ctx'' && p == p' && q == q' =
            Theorem (ctx,   Provable q)

uniqueIntro :: Theorem -> Theorem -> Theorem
uniqueIntro (Theorem (ctx,  Provable (Exists x' px')))
            (Theorem (ctx', Provable (Forall x (px `Implies` Forall y (py `Implies` (Var (Bound 1) `Eq` Var (Bound 0)))))))
            | ctx == ctx' && px' == px && px' == py =
             Theorem (ctx,  Provable (Unique x' px'))

uniqueLeft :: Theorem -> Theorem
uniqueLeft (Theorem (ctx, Provable (Unique x px))) =
            Theorem (ctx, Provable (Exists x px))

uniqueRight :: Theorem -> Theorem
uniqueRight (Theorem (ctx, Provable (Unique x px))) =
             Theorem (ctx, Provable (Forall x (px `Implies` Forall x' (px `Implies` (Var (Bound 1) `Eq` Var (Bound 0))))))
  where x' = newName x (x : map fst (ctxList ctx))

-- (Context-changing rule)
forallFuncIntro :: Theorem -> Theorem
forallFuncIntro (Theorem (Context ((id, CVar (TFunc k s)) : ls), Provable p)) =
                 Theorem (Context ls, Provable (ForallFunc id k s (makeBoundFunc id p)))

forallFuncElim :: Theorem -> Theorem -> Theorem
forallFuncElim (Theorem (ctx,  Provable (ForallFunc f k s q)))
               (Theorem (ctx', HasType t (TFunc k' s')))
               | ctx == ctx' && k == k' && s == s' =
                Theorem (ctx,  Provable (makeReplaceFunc t q))

