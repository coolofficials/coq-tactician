open Ltac_plugin
open Tacexpr
open Tactypes
open Constrexpr
open Glob_term
open Locus
open Tactics
open Context

let context_to_vars lc = List.map (function
    | Named.Declaration.LocalAssum (id, _) -> id.binder_name
    | Named.Declaration.LocalDef (id,_, _) -> id.binder_name) lc

let hd_default ls x = match ls with
  | [] -> x
  | x::_ -> x

let find_in_lc x lc_vars =
  Option.default (hd_default lc_vars (Names.Id.of_string "_"))
    (List.find_opt (fun y -> Names.Id.equal x y) lc_vars)

let replace_free_variables (lc : EConstr.named_context) t =
  let free = Names.Id.Set.elements (Glob_ops.free_glob_vars t) in
  (*print_endline "free";
    List.iter (fun id -> print_endline (Names.Id.to_string id)) free;*)
  let lc_vars = context_to_vars lc in
  let map = List.map (fun x -> (x, find_in_lc x lc_vars)) free in
  Glob_ops.rename_glob_vars map t

let id_map f id =
  let lc_vars = context_to_vars f in
  find_in_lc id lc_vars

let id_map2 f id = CAst.map (id_map f) id

let constr_and_expr_map f ((glb_constr : glob_constr), (constr_expr : constr_expr option)) : glob_constr * Constrexpr.constr_expr option =
  (replace_free_variables f glb_constr, None)

let binding_map f =
  CAst.map (fun (b,c) ->
      b, constr_and_expr_map f c)

let bindings_map f = function
  | NoBindings -> NoBindings
  | ImplicitBindings l -> ImplicitBindings (List.map (constr_and_expr_map f) l)
  | ExplicitBindings l -> ExplicitBindings (List.map (binding_map f) l)

let with_bindings_map f (c, bl) = (constr_and_expr_map f c, bindings_map f bl)
let with_bindings_arg_map f ((clear, c) : g_trm with_bindings_arg) : g_trm with_bindings_arg =
  (clear, with_bindings_map f c)

let intro_pattern_naming_map f p = p (* TODO: anonymize this if possible *)
let new_name_map f id = id (* TODO: anonymize this if possible *)

let rec intro_pattern_action_map f = function
  | IntroWildcard -> IntroWildcard
  | IntroOrAndPattern p -> IntroOrAndPattern (intro_pattern_orand_map f p)
  | IntroInjection p -> IntroInjection (List.map (CAst.map (intro_pattern_map f)) p)
  | IntroApplyOn (c, p) ->
    IntroApplyOn (CAst.map (constr_and_expr_map f) c, CAst.map (intro_pattern_map f) p)
  | IntroRewrite b -> IntroRewrite b
and intro_pattern_orand_map f = function
    IntroOrPattern ls -> IntroOrPattern (List.map (List.map (CAst.map (intro_pattern_map f))) ls)
  | IntroAndPattern ls -> IntroAndPattern (List.map (CAst.map (intro_pattern_map f)) ls)
and intro_pattern_map f = function
  | IntroForthcoming b -> IntroForthcoming b
  | IntroNaming p -> IntroNaming (intro_pattern_naming_map f p)
  | IntroAction p -> IntroAction (intro_pattern_action_map f p)

let apply_in_map f (id, pattern) = (id_map2 f id, Option.map (CAst.map (intro_pattern_map f)) pattern)

let with_occurrences_map f (o, c) = (o, constr_and_expr_map f c)

let or_var_map f = function
  | ArgArg x -> ArgArg (f x)
  | ArgVar x -> ArgVar x

let quantified_hypothesis_map f = function
  | AnonHyp n -> AnonHyp n
  | NamedHyp x -> NamedHyp (id_map f x)

let core_destruction_arg_map f = function
  | Tactics.ElimOnConstr (gc, ce) -> ElimOnConstr (constr_and_expr_map f gc, ce)
  | Tactics.ElimOnIdent id -> ElimOnIdent (CAst.map (id_map f) id)
  | Tactics.ElimOnAnonHyp n -> ElimOnAnonHyp n

let induction_clause_map f (((cflg, da), (eqn, p), ce) : ('k, 'i) induction_clause) =
  ((cflg, core_destruction_arg_map f da),
   (Option.map (CAst.map (intro_pattern_naming_map f)) eqn,
    Option.map (or_var_map (CAst.map (intro_pattern_orand_map f))) p), ce)

let g_pat_map f (id, c, p) = (Names.Id.Set.map (id_map f) id, constr_and_expr_map f c, p) (* What to do with 'p' (Pattern.constr_pattern)*)

let clause_expr_map f { onhyps = oh; concl_occs = oe } =
  {onhyps = Option.map (List.map (fun ((o, id), l) -> ((o, id_map2 f id), l))) oh; concl_occs = oe}

let inversion_strength_map f = function
    NonDepInversion (k, ids, p) -> NonDepInversion (k, List.map (id_map2 f) ids, Option.map (or_var_map (CAst.map (intro_pattern_orand_map f))) p)
  | DepInversion (k, c, p) -> DepInversion (k, Option.map (constr_and_expr_map f) c, Option.map (or_var_map (CAst.map (intro_pattern_orand_map f))) p)
  | InversionUsing (c, ids) -> InversionUsing (constr_and_expr_map f c, List.map (id_map2 f) ids)

let match_rule_map f = function (* TODO: Finish *)
  | Pat (x, y, z) -> Pat (x, y, z)
  | All x -> All (f x)

let rec atomic_map (f : EConstr.named_context) (t : glob_atomic_tactic_expr) : glob_atomic_tactic_expr =
  match t with
  | TacIntroPattern (ev, l) -> TacIntroPattern (ev, List.map (CAst.map (intro_pattern_map f)) l)
  | TacApply (a, ev, cb, cl) ->
    TacApply (a, ev, List.map (with_bindings_arg_map f) cb, Option.map (apply_in_map f) cl)
  | TacElim (ev, cb, cbo) -> TacElim (ev, with_bindings_arg_map f cb, Option.map (with_bindings_map f) cbo)
  | TacCase (ev, cb) -> TacCase (ev, with_bindings_arg_map f cb)
  | TacMutualFix (id, n, l) -> TacMutualFix (id, n, List.map (fun (id, n, t) -> (id, n, constr_and_expr_map f t)) l)
  | TacMutualCofix (id, l) -> TacMutualCofix (id, List.map (fun (id, t) -> (id, constr_and_expr_map f t)) l)
  | TacAssert (ev, b, otac, na, c) -> TacAssert (ev, b, Option.map (Option.map (tactic_constr_map f)) otac,
                                                 Option.map (CAst.map (intro_pattern_map f)) na,
                                                 constr_and_expr_map f c)
  | TacGeneralize cl -> TacGeneralize (List.map (fun (wo, id) -> (with_occurrences_map f wo, new_name_map f id)) cl)
  | TacLetTac (ev, id, c, clp, b, eqpat) -> TacLetTac (ev, id, constr_and_expr_map f c, clause_expr_map f clp, b,
                                                       Option.map (CAst.map (intro_pattern_naming_map f )) eqpat)
  | TacInductionDestruct (isrec, ev, (l, el)) ->
    TacInductionDestruct (isrec, ev, (List.map (induction_clause_map f) l, Option.map (with_bindings_map f) el))
  | TacReduce (r, cl) -> TacReduce (r, clause_expr_map f cl) (* TODO: Do something with r here *)
  | TacChange (check, op, c, cl) -> TacChange (check, Option.map (g_pat_map f) op, constr_and_expr_map f c,
                                               clause_expr_map f cl)
  | TacRewrite (ev, l, cl, by) ->
    TacRewrite (ev, List.map (fun (b, eq, x) -> (b, eq, with_bindings_arg_map f x)) l,
                clause_expr_map f cl, Option.map (tactic_constr_map f) by)
  | TacInversion (a, b) -> TacInversion (inversion_strength_map f a, quantified_hypothesis_map f b)

and tactic_constr_map (f : EConstr.named_context) (tac : glob_tactic_expr) : glob_tactic_expr =
  match tac with
  | TacAtom { CAst.v= t } -> TacAtom (CAst.make @@ atomic_map f t)
  | TacFun (ids, t) -> TacFun (ids, tactic_constr_map f t)
  | TacLetIn (r, l, u) -> TacLetIn (r, List.map (fun (id, t) -> (id, t)) l, tactic_constr_map f u)
  | TacMatchGoal (lz, lr, lmr) -> TacMatchGoal (lz, lr, List.map (match_rule_map (fun x -> x)) lmr) (* TODO: finish from here *)
  | TacMatch (lz, c, lmr) -> TacMatch (lz, c, lmr)
  | TacId ls -> TacId ls
  | TacFail (flg, n, ls) -> TacFail (flg, n, ls)
  | TacProgress tac -> TacProgress (tactic_constr_map f tac)
  | TacShowHyps tac -> TacShowHyps (tactic_constr_map f tac)
  | TacAbstract (tac, s) -> TacAbstract (tactic_constr_map f tac, s)
  | TacThen (t1, t2) -> TacThen (tactic_constr_map f t1, tactic_constr_map f t2)
  | TacDispatch tl -> TacDispatch (List.map (tactic_constr_map f) tl)
  | TacExtendTac (tf, t, tl) -> TacExtendTac (Array.map (tactic_constr_map f) tf, tactic_constr_map f t,
                                              Array.map (tactic_constr_map f) tl)
  | TacThens (t, tl) -> TacThens (tactic_constr_map f t, List.map (tactic_constr_map f) tl)
  | TacThens3parts (t1, tf, t2, tl) -> TacThens3parts (tactic_constr_map f t1, Array.map (tactic_constr_map f) tf,
                                                       tactic_constr_map f t2, Array.map (tactic_constr_map f) tl)
  | TacDo (n, tac) -> TacDo (n, tactic_constr_map f tac)
  | TacTimeout (n, tac) -> TacTimeout (n, tactic_constr_map f tac)
  | TacTime (s, tac) -> TacTime (s, tactic_constr_map f tac)
  | TacTry tac -> TacTry (tactic_constr_map f tac)
  | TacInfo tac -> TacInfo (tactic_constr_map f tac)
  | TacRepeat tac -> TacRepeat (tactic_constr_map f tac)
  | TacOr (t1, t2) -> TacOr (tactic_constr_map f t1, tactic_constr_map f t2)
  | TacOnce tac -> TacOnce (tactic_constr_map f tac)
  | TacExactlyOnce tac -> TacExactlyOnce (tactic_constr_map f tac)
  | TacIfThenCatch (tac, tact, tace) -> TacIfThenCatch (tactic_constr_map f tac, tactic_constr_map f tact,
                                                        tactic_constr_map f tace)
  | TacOrelse (t1, t2) -> TacOrelse (tactic_constr_map f t1, tactic_constr_map f t2)
  | TacFirst l -> TacFirst (List.map (tactic_constr_map f) l)
  | TacSolve l -> TacSolve (List.map (tactic_constr_map f) l)
  | TacComplete tac -> TacComplete (tactic_constr_map f tac)
  | TacArg { CAst.v=a } -> TacArg (CAst.make @@ a)
  | TacSelect (s, tac) -> TacSelect (s, tactic_constr_map f tac)
  | TacAlias { CAst.v=(s,l) } -> TacAlias (CAst.make (s, l))
  | TacML { CAst.loc; v=(opn, l)} -> TacML (CAst.(make ?loc (opn, l)))
