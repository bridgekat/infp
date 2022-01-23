{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TupleSections #-}

import Prelude hiding (pred)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import FOLPlus


-- Convert to de Brujin indices and check types.
convertAndCheck :: Context -> Expr -> Theorem
convertAndCheck ctx e = case e of
  (Var (Free x)) -> varMk ctx x
  (Var (Bound i)) -> error "Please use names for bound variables in the input expression"
  (Func (Free f) ts) -> funcMk ctx f (map (convertAndCheck ctx) ts)
  (Func (Bound i) ts) -> error "Please use names for bound variables in the input expression"
  (Pred (Free p) ts) -> predMk ctx p (map (convertAndCheck ctx) ts)
  (Pred (Bound i) ts) -> error "Please use names for bound variables in the input expression"
  (Eq t1 t2) -> eqMk (convertAndCheck ctx t1) (convertAndCheck ctx t2)
  Top -> weaken topMk ctx
  Bottom -> weaken bottomMk ctx
  (Not e) -> notMk (convertAndCheck ctx e)
  (And e1 e2) -> andMk (convertAndCheck ctx e1) (convertAndCheck ctx e2)
  (Or e1 e2) -> orMk (convertAndCheck ctx e1) (convertAndCheck ctx e2)
  (Implies e1 e2) -> impliesMk (convertAndCheck ctx e1) (convertAndCheck ctx e2)
  (Iff e1 e2) -> iffMk (convertAndCheck ctx e1) (convertAndCheck ctx e2)
  (Forall x e) -> forallMk (convertAndCheck (ctxVar x ctx) e)
  (Exists x e) -> existsMk (convertAndCheck (ctxVar x ctx) e)
  (Unique x e) -> uniqueMk (convertAndCheck (ctxVar x ctx) e)
  (ForallFunc f k e) -> forallFuncMk (convertAndCheck (ctxFunc f k ctx) e)
  (ForallPred p k e) -> forallPredMk (convertAndCheck (ctxPred p k ctx) e)
  (Lam x e) -> lamMk (convertAndCheck (ctxVar x ctx) e)

-- Derivation trees (aka. proof terms)
data Proof =
    As String
  | Decl Decl
  | AndI Proof Proof        | AndL Proof              | AndR Proof
  | OrL Proof Expr          | OrR Expr Proof          | OrE Proof Proof Proof
  | ImpliesE Proof Proof
  | NotI Proof              | NotE Proof Proof
  | IffI Proof Proof        | IffL Proof Proof        | IffR Proof Proof
  | TrueI                   | FalseE Proof Expr       | RAA Proof
  | EqI Expr                | EqE Expr Proof Proof
  | ForallE Proof Expr
  | ExistsI Expr Expr Proof | ExistsE Proof Proof Expr
  | UniqueI Proof Proof     | UniqueL Proof           | UniqueR Proof
  | ForallFuncE Proof Expr
  | ForallPredE Proof Expr

-- Declarations
data Decl =
    Block [Decl]
  | Assertion String (Maybe Expr) Proof
  | Any String Decl
  | AnyFunc String Int Decl
  | AnyPred String Int Decl
  | Assume String Expr Decl
{-
  | FuncDef String Expr
  | PredDef String Expr
  | FuncDDef String Expr Proof -- Definite description
  | FuncIDef String Expr Proof -- Indefinite description
-}

-- `StatefulVal s` is a "state monad" (i.e. an expression/procedure that reads & modifies a state when being evaluated).
newtype StatefulVal s a = StatefulVal { eval :: s -> (a, s) }

instance Functor (StatefulVal s) where
  -- Allows normal functions to act on a `StatefulVal`. Can be implemented using the Applicative instance.
  fmap :: (a -> b) -> StatefulVal s a -> StatefulVal s b
  fmap f x = pure f <*> x

instance Applicative (StatefulVal s) where
  -- Allows normal values to be converted into `StatefulVal`s.
  pure :: a -> StatefulVal s a
  pure f = StatefulVal (\s -> (f, s))
  -- Allows a `StatefulVal` (which evaluates to a function) to act on another `StatefulVal`. We evaluate the LHS first.
  (<*>) :: StatefulVal s (a -> b) -> StatefulVal s a -> StatefulVal s b
  (<*>) f x = StatefulVal (\s -> let (f', s') = eval f s in let (x', s'') = eval x s' in (f' x', s''))

instance Monad (StatefulVal s) where
  -- Allows chaining of dependent `StatefulVal`s.
  (>>=) :: StatefulVal s a -> (a -> StatefulVal s b) -> StatefulVal s b
  (>>=) f g = StatefulVal (\s -> let (x, s') = eval f s in eval (g x) s')

-- Theorem pool (stack of Maps)
type TheoremPool = [Map String Theorem]
type WithState = StatefulVal TheoremPool

-- Add theorem to the topmost pool and return it (for convenience).
addTheorem :: String -> Theorem -> WithState Theorem
addTheorem id thm = StatefulVal (\(top : ps) -> (thm, Map.insert id thm top : ps))

-- Delete identifier from all pools.
removeAll :: String -> WithState ()
removeAll id = StatefulVal (((), ) . map (Map.delete id))

push :: WithState ()
push = StatefulVal (\ls -> ((), Map.empty : ls))

pop :: WithState ()
pop = StatefulVal (\(top : ls) -> ((), ls))

lookupPool :: String -> WithState (Maybe Theorem)
lookupPool id = StatefulVal $ \ls ->
  (foldl
    (\acc curr ->
      case acc of
        (Just thm) -> Just thm
        Nothing -> case Map.lookup id curr of
          (Just thm) -> Just thm
          Nothing -> Nothing)
    Nothing ls,
  ls)

-- Generalize over a variable and then pop.
-- Pre: all theorems in the form of (Provable ctx, p) in the top layer must have the same context, with some variable assumed last
genPop :: WithState ()
genPop = StatefulVal $ \(top : second : ls) -> ((),
  let
    second' = Map.foldlWithKey'
      (\acc id thm ->
        case thmJudgment thm of
          IsFunc k f -> Map.insert id (lamMk thm) acc
          IsPred k f -> Map.insert id (lamMk thm) acc
          Provable p -> Map.insert id (forallIntro thm) acc)
      second top
  in
    second' : ls)

-- Generalize over a function and then pop.
-- Pre: all theorems in the form of (Provable ctx, p) in the top layer must have the same context, with some function (arity > 0) assumed last
genFuncPop :: WithState ()
genFuncPop = StatefulVal $ \(top : second : ls) -> ((),
  let
    second' = Map.foldlWithKey'
      (\acc id thm ->
        case thmJudgment thm of
          Provable p -> Map.insert id (forallFuncIntro thm) acc
          _          -> acc) -- TODO: "second-order" functions/predicates
      second top
  in
    second' : ls)

-- Generalize over a predicate and then pop.
-- Pre: all theorems in the form of (Provable ctx, p) in the top layer must have the same context, with some predicate assumed last
genPredPop :: WithState ()
genPredPop = StatefulVal $ \(top : second : ls) -> ((),
  let
    second' = Map.foldlWithKey'
      (\acc id thm ->
        case thmJudgment thm of
          Provable p -> Map.insert id (forallPredIntro thm) acc
          _          -> acc) -- TODO: "second-order" functions/predicates
      second top
  in
    second' : ls)

-- Apply impliesIntro and then pop.
-- Pre: all theorems in the form of (Provable ctx, p) in the top layer must have the same context, with some formula assumed last 
assumePop :: WithState ()
assumePop = StatefulVal $ \(top : second : ls) -> ((),
  let
    second' = Map.foldlWithKey'
      (\acc id thm ->
        case thmJudgment thm of
          Provable p -> Map.insert id (impliesIntro thm) acc
          _          -> acc) -- TODO: partial functions/predicates
      second top
  in
    second' : ls)

-- Check if a (non-context-changing) proof is well-formed; returns its judgment.
checkProof :: Context -> Proof -> WithState Theorem
checkProof ctx e = case e of
  (As id) -> do
    res <- lookupPool id;
    case res of
      (Just thm) -> return (weaken thm ctx);
      Nothing    -> return (assumption ctx id);
  (Decl decl) -> checkDecl ctx decl
  (AndI p q) -> andIntro <$> checkProof ctx p <*> checkProof ctx q
  (AndL p) -> andLeft <$> checkProof ctx p
  (AndR p) -> andRight <$> checkProof ctx p
  (OrL p q) -> orLeft <$> checkProof ctx p <*> pure (convertAndCheck ctx q)
  (OrR p q) -> orRight <$> pure (convertAndCheck ctx p) <*> checkProof ctx q
  (OrE pq ps qs) -> orElim <$> checkProof ctx pq <*> checkProof ctx ps <*> checkProof ctx qs
  (ImpliesE pq p) -> impliesElim <$> checkProof ctx pq <*> checkProof ctx p
  (NotI p) -> notIntro <$> checkProof ctx p
  (NotE np p) -> notElim <$> checkProof ctx np <*> checkProof ctx p
  (IffI pq qp) -> iffIntro <$> checkProof ctx pq <*> checkProof ctx qp
  (IffL pq p) -> iffLeft <$> checkProof ctx pq <*> checkProof ctx p
  (IffR pq q) -> iffRight <$> checkProof ctx pq <*> checkProof ctx q
  (TrueI) -> pure (weaken trueIntro ctx)
  (FalseE f p) -> falseElim <$> checkProof ctx f <*> pure (convertAndCheck ctx p)
  (RAA npf) -> raa <$> checkProof ctx npf
  (EqI t) -> eqIntro <$> pure (convertAndCheck ctx t)
  (EqE p ab pa) -> eqElim <$> pure (convertAndCheck ctx p) <*> checkProof ctx ab <*> checkProof ctx pa
  (ForallE px t) -> forallElim <$> checkProof ctx px <*> pure (convertAndCheck ctx t)
  (ExistsI p t pt) -> existsIntro <$> pure (convertAndCheck ctx p) <*> pure (convertAndCheck ctx t) <*> checkProof ctx pt
  (ExistsE epx pxq q) -> existsElim <$> checkProof ctx epx <*> checkProof ctx pxq <*> pure (convertAndCheck ctx q)
  (UniqueI ex one) -> uniqueIntro <$> checkProof ctx ex <*> checkProof ctx one
  (UniqueL uni) -> uniqueLeft <$> checkProof ctx uni
  (UniqueR uni) -> uniqueRight <$> checkProof ctx uni
  (ForallFuncE pf f) -> forallFuncElim <$> checkProof ctx pf <*> pure (convertAndCheck ctx f)
  (ForallPredE pp p) -> forallPredElim <$> checkProof ctx pp <*> pure (convertAndCheck ctx p)

-- Check if a declaration is well-formed; returns the judgment for the last declaration.
checkDecl :: Context -> Decl -> WithState Theorem
checkDecl ctx e = case e of
  (Block []) -> error "Uses sorry (empty block)"
  (Block [d]) -> checkDecl ctx d
  (Block (d : ds)) -> do checkDecl ctx d; checkDecl ctx (Block ds);
  (Assertion id e pf) -> do
    thm <- checkProof ctx pf;
    case thmJudgment thm of
      (Provable e')
        | e == Just e' || e == Nothing -> addTheorem id thm;
      _                                -> error "Statement and proof does not match"
  (Any x d) -> do
    push;
    thm <- checkDecl (ctxVar x ctx) d;
    genPop;
    case thmJudgment thm of
      IsFunc k f -> return (lamMk thm);
      IsPred k f -> return (lamMk thm);
      Provable p -> return (forallIntro thm);
  (AnyFunc x k d) -> do
    push;
    thm <- checkDecl (ctxFunc x k ctx) d;
    genFuncPop;
    case thmJudgment thm of
      Provable p -> return (forallFuncIntro thm);
      _          -> error "TODO: \"second-order\" functions/predicates"
  (AnyPred x k d) -> do
    push;
    thm <- checkDecl (ctxPred x k ctx) d;
    genPredPop;
    case thmJudgment thm of
      Provable p -> return (forallPredIntro thm);
      _          -> error "TODO: \"second-order\" functions/predicates"
  (Assume x e d) -> do
    push;
    thm <- checkDecl (ctxAssumption x (convertAndCheck ctx e)) d;
    assumePop;
    case thmJudgment thm of
      Provable p -> return (impliesIntro thm);
      _          -> error "TODO: partial functions/predicates"



-- TEMP CODE

var :: String -> Expr
var = Var . Free
func :: String -> [Expr] -> Expr
func = Func . Free
pred :: String -> [Expr] -> Expr
pred = Pred . Free

pool :: TheoremPool
pool = [Map.empty]

decls :: Decl
decls =
  AnyPred "L" 2 (AnyPred "B" 3 (Any "Q" (
    Assume "h1" (Forall "x" (Forall "y" (pred "L" [var "x", var "y"] `Implies` Forall "z" (Not (Eq (var "z") (var "y")) `Implies` Not (pred "L" [var "x", var "z"]))))) (
      Assume "h2" (Forall "x" (Forall "y" (Forall "z" (pred "B" [var "x", var "y", var "z"] `Implies` (pred "L" [var "x", var "z"] `Implies` pred "L" [var "x", var "y"]))))) (
        Assume "h3" (Exists "x" (Not (Eq (var "x") (var "Q")) `And` Forall "y" (pred "B" [var "y", var "x", var "Q"]))) (Block [
          Any "c" (Assume "hc" (Not (Eq (var "c") (var "Q")) `And` Forall "x" (pred "B" [var "x", var "c", var "Q"])) (Block [
            Assertion "hc1" Nothing (AndL (As "hc")),
            Assertion "hc2" Nothing (AndR (As "hc")),
            Assume "hex" (Exists "x" (pred "L" [var "x", var "Q"])) (Block [
              Any "x" (Assume "hx" (pred "L" [var "x", var "Q"]) (Block [
                Assertion "t1" Nothing (ImpliesE (ForallE (ForallE (As "h1") (var "x")) (var "Q")) (As "hx")),
                Assertion "t2" Nothing (ImpliesE (ForallE (As "t1") (var "c")) (As "hc1")),
                Assertion "t3" Nothing (ForallE (As "hc2") (var "x")),
                Assertion "t4" Nothing (ImpliesE (ImpliesE (ForallE (ForallE (ForallE (As "h2") (var "x")) (var "c")) (var "Q")) (As "t3")) (As "hx")),
                Assertion "t5" Nothing (NotE (As "t2") (As "t4"))
              ])),
              Assertion "t6" Nothing (ExistsE (As "hex") (As "t5") Bottom)
            ]),
            Assertion "t7" Nothing (NotI (As "t6"))
          ])),
          Assertion "t8" Nothing (ExistsE (As "h3") (As "t7") (Not (Exists "x" (pred "L" [var "x", var "Q"]))))
        ])
      )
    )
  )))

res :: TheoremPool
res = snd $ eval (checkDecl ctxEmpty decls) pool
