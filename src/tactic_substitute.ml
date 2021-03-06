open Map_all_the_things
open Genarg
open Names

module ReaderMonad (R : sig type r end) = struct
  open R
  type 'a t = r -> 'a
  let return x = fun _ -> x
  let (>>=) x f = fun r -> f (x r) r
  let (>>) x y = fun r -> let () = x r in y r
  let map f x = fun r -> f (x r)

  let ask x = x
  let local f x = fun r -> x (f r)
end

module WriterMonad (R : sig type w val id : w val comb : w -> w -> w end) = struct
  open R
  type 'a t = w * 'a
  let return x = (id, x)
  let (>>=) (w, x) f = let (w', y) = f x in (comb w w', y)
  let (>>) (w, ()) (w', x) = (comb w w', x)
  let map f (w, x) = w, f x

  let tell l = ([l], ())
  let censor f (w, x) = (f w, x)
end

module FreeVarsDef = struct
  include MapDefTemplate (WriterMonad
                            (struct type w = Id.t list let id = [] let comb = List.append end))
  let map_sort = "freevars"
  let warnProblem wit =
    Feedback.msg_warning (Pp.(str "Tactician is having problems with " ++
                              str "the following tactic. Please report. " ++
                              pr_argument_type wit))
  let default wit = { raw = (fun _ -> warnProblem (ArgumentType wit); id)
                    ; glb = (fun _ -> warnProblem (ArgumentType wit); id)}

  let with_binders ids (w, x) = List.filter (fun id -> not @@ List.exists (Id.equal id) ids) w, x
end
module FreeVarsMapper = MakeMapper(FreeVarsDef)
open FreeVarsDef
open WriterMonad(struct type w = Id.t list let id = [] let comb = List.append end)

type 'a w = Id.t list * 'a

let mapper = { FreeVarsDef.default_mapper with
               variable = (fun id -> tell id >> return id)
             }

let tactic_free_variables t : Id.t list =
  let vars, _ = FreeVarsMapper.glob_tactic_expr_map mapper t in vars

module SubstituteDef = struct
  include MapDefTemplate (ReaderMonad(struct type r = Id.t list end))
  let map_sort = "substitute"
  let warnProblem wit =
    Feedback.msg_warning (Pp.(str "Tactician is having problems with " ++
                              str "the following tactic. Please report. " ++
                              pr_argument_type wit))
  let default wit = { raw = (fun _ -> warnProblem (ArgumentType wit); id)
                    ; glb = (fun _ -> warnProblem (ArgumentType wit); id)}

  let with_binders ids f = fun ids' -> f (ids@ids')
end
module SubstituteMapper = MakeMapper(SubstituteDef)
open SubstituteDef
open ReaderMonad(struct type r = Id.t list end)

type 'a k = (Id.t list -> 'a)

let mapper f = { SubstituteDef.default_mapper with
                 variable = (fun id -> ask >>= fun ids ->
                            if List.exists (Id.equal id) ids then return id else return (f id))
               }

let tactic_substitute f t = SubstituteMapper.glob_tactic_expr_map (mapper f) t []
