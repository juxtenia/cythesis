(* A module that scans a CIL file and tags all TPtr with a unique attribute 
 * id. It also constructs a mapping from attributes id to places where they 
 * were introduced  *)
open Cil
open Pretty

module H = Hashtbl
module E = Errormsg

module N = Ptrnode

let lu = locUnknown

let currentFileName = ref ""
let currentFunctionName = ref ""
let currentResultType = ref voidType

let callId = ref (-1)  (* Each call site gets a new ID *)

(* Grab the node from the attributs of a type. Returns dummyNode if no such 
 * node *)
let nodeOfType t = 
  match unrollType t with 
    TPtr(_, a) -> begin
      match N.nodeOfAttrlist a with
        Some n -> n
      | None -> N.dummyNode
    end
  | _ -> N.dummyNode


(* Rewrite types so that pointer types get a new node and a new attribute. 
 * The attribute is added by the N.newNode.  *)

(* Keep track of composite types that we have done already, to avoid looping *)
let doneComposites : (int, bool) H.t = H.create 111 

(* Pass also the place and the next index within the place. Returns the 
 * modified type and the next ununsed index *)
let rec doType (t: typ) (p: N.place) 
               (nextidx: int) : typ * int = 
  match t with 
    (TVoid _ | TInt _ | TFloat _ | TBitfield _ | TEnum _ ) -> t, nextidx
  | TPtr (bt, a) -> begin
      match N.nodeOfAttrlist a with
        Some n -> TPtr (bt, a), nextidx (* Already done *)
      | None -> 
          let bt', i' = doType bt p (nextidx + 1) in
          let n = N.newNode p nextidx bt' a in
          TPtr (bt', n.N.attr), i'
  end
  | TArray(bt, len, a) -> begin
      (* wes: we want a node for the array, just like we have a node for
       * each pointer *)
      match N.nodeOfAttrlist a with
        Some n -> TArray (bt, len, a), nextidx (* Already done *)
      | None -> 
          let bt', i' = doType bt p (nextidx + 1) in
          let n = N.newNode p nextidx bt' a in
          TArray (bt', len, n.N.attr), i'
  end
          
  | TComp comp -> 
      if H.mem doneComposites comp.ckey then
        t, nextidx
      else begin
        H.add doneComposites comp.ckey true; (* before we do the fields *)
        List.iter 
          (fun f -> 
            let t', i' = doType f.ftype (N.PField f) 0 in
            f.ftype <- t') comp.cfields;
        t, nextidx
      end
        
  | TNamed (n, bt, a) -> 
      let t', _ = doType bt (N.PType n) 0 in
      t', nextidx
        
  | TForward (comp, a) -> 
      if H.mem doneComposites comp.ckey then
        t, nextidx
      else begin
        H.add doneComposites comp.ckey true; (* before we do the fields *)
        List.iter 
          (fun f -> 
            let t', i' = doType f.ftype (N.PField f) 0 in
            f.ftype <- t') comp.cfields;
        t, nextidx
      end
        
  | TFun (restyp, args, isva, a) -> 
      let restyp', i0 = doType restyp p nextidx in
          (* Rewrite the argument types in place *)
      let i' = 
        List.fold_left 
          (fun nidx arg -> 
            let t', i' = doType arg.vtype p nidx in
            arg.vtype <- t';
            i') i0 args in
      TFun(restyp', args, isva, a), i'

          

(* For each node corresponding to a struct or union or array type we will 
 * create successor node corresponding to various offsets. We cache these 
 * nodes indexed by the start node id and the name of the field. In the 
 * particular case of an array, we use the field name "@field" to refer to 
 * the first element *)
let offsetNodes : (int * string, N.node) H.t = H.create 111

(* Create a new offset node *)
let newOffsetNode (n: N.node)  (fname: string) 
                  (btype: typ) (battr: attribute list) = 
  let next = N.newNode (N.POffset(n.N.id, fname)) 0 btype battr in
  (* Add edges between n and next *)
  (match unrollType n.N.btype with
    TComp c when not c.cstruct -> (* A union *)
      N.addEdge n next N.ECast (-1);
      N.addEdge n next N.ESafe (-1)

  | TArray _ -> (* An index *)
      N.addEdge n next N.EIndex (-1)

  | TComp c when c.cstruct -> (* A struct *)
      N.addEdge n next N.ESafe (-1)

  | _ -> E.s (E.bug "Unexpected offset"));
  next

(* Create a field successor *)
let fieldOfNode (n: N.node) (fi: fieldinfo) = 
  try
    H.find offsetNodes (n.N.id, fi.fname)
  with Not_found -> 
    newOffsetNode n fi.fname fi.ftype []

let startOfNode (n: N.node) = 
  try
    H.find offsetNodes (n.N.id, "@first")
  with Not_found -> begin
    match unrollType n.N.btype with
      TArray (bt, _, _) ->
        let next = N.newNode (N.POffset(n.N.id, "@first")) 0 bt [] in
        N.addEdge n next N.EIndex (-1);
        next
    | _ -> n (* It is a function *)
  end
    

(* Compute the sign of an expression. Extend this to a real constant folding 
 * + the sign rule  *)
type sign = SPos | SNeg | SAny | SLiteral of int

let rec signOf = function
    Const(CInt(n, _, _), _) -> SLiteral n
  | Const(CChr c, _) -> SLiteral (Char.code c)
  | SizeOf _ -> SPos (* We do not compute it now *)
  | UnOp (Neg, e, _, _) -> begin
      match signOf e with
        SPos -> SNeg
      | SLiteral n -> SLiteral (- n)
      | SNeg -> SNeg
      | _ -> SAny
  end
  | UnOp (LNot, e, _, _) -> SPos
  | BinOp (PlusA, e1, e2, _, _) -> begin
      match signOf e1, signOf e2 with
        SPos, SPos -> SPos
      | SLiteral n, SPos when n >= 0 -> SPos
      | SPos, SLiteral n when n >= 0 -> SPos
      | SLiteral n1, SLiteral n2 -> SLiteral (n1 + n2)
      | SNeg, SNeg -> SNeg
      | SLiteral n, SNeg when n <= 0 -> SNeg
      | SNeg, SLiteral n when n <= 0 -> SNeg
      | _ -> SAny
  end
  | BinOp (MinusA, e1, e2, _, _) -> begin
      match signOf e1, signOf e2 with
        SPos, SNeg -> SPos
      | SLiteral n, SNeg when n >= 0 -> SPos
      | SPos, SLiteral n when n <= 0 -> SPos
      | SLiteral n1, SLiteral n2 -> SLiteral (n1 - n2)
      | SNeg, SPos -> SNeg
      | SLiteral n, SPos when n <= 0 -> SNeg
      | SNeg, SLiteral n when n >= 0 -> SNeg
      | _ -> SAny
  end
  | _ -> SAny

(* Do varinfo. We do the type and for all variables we also generate a node 
 * that will be used when we take the address of the variable (or if the 
 * variable contains an array) *)
let doVarinfo vi = 
  (* Compute a place for it *)
  let place = 
    if vi.vglob then
      if vi.vstorage = Static then 
        N.PStatic (!currentFileName, vi.vname)
      else
        N.PGlob vi.vname
    else
      N.PLocal (!currentFileName, !currentFunctionName, vi.vname)
  in
  (* Do the type of the variable. Start the index at 1 *)
  let t', _ = doType vi.vtype place 1 in
  vi.vtype <- t';
  (* Associate a node with the variable itself. Use index = 0 *)
  let n = N.getNode place 0 vi.vtype vi.vattr in
  (* Add this to the variable attributes *)
  vi.vattr <- n.N.attr
    
(* Do an expression. Return an expression, a type and a node. The node is 
 * only meaningful if the type is a TPtr _. In that case the node is also 
 * refered to from the attributes of TPtr  *)
let rec doExp (e: exp) = 
  match e with 
    Lval lv -> 
      let lv', lvn = doLvalue lv false in
      Lval lv', lvn.N.btype, nodeOfType lvn.N.btype

  | AddrOf (lv, l) -> 
      let lv', lvn = doLvalue lv false in
      AddrOf (lv', l), TPtr(lvn.N.btype, lvn.N.attr), lvn

  | StartOf lv -> 
      let lv', lvn = doLvalue lv false in
      let next = startOfNode lvn in
      StartOf lv', TPtr(next.N.btype, next.N.attr), next

  | UnOp (uo, e, tres, l) -> (* tres is an arithmetic type *)
      UnOp(uo, doExpAndCast e tres, tres, l), tres, N.dummyNode

  | SizeOf (t, l) ->
      let t', _ = doType t (N.anonPlace()) 0 in
      SizeOf (t', l), uintType, N.dummyNode

        (* arithemtic binop *)
  | BinOp (((PlusA|MinusA|Mult|Div|Mod|Shiftlt|Shiftrt|Lt|Gt|Le|Ge|Eq|Ne|BAnd|BXor|BOr|LtP|GtP|LeP|GeP|EqP|NeP|MinusPP) as bop), 
           e1, e2, tres, l) -> 
             BinOp(bop, doExpAndCast e1 tres,
                   doExpAndCast e2 tres, tres, l), tres, N.dummyNode
       (* pointer arithmetic *)
  | BinOp (((PlusPI|MinusPI) as bop), e1, e2, tres, l) -> 
      let e1', e1t, e1n = doExp e1 in
      (match signOf 
          (match bop with PlusPI -> e2 | _ -> UnOp(Neg, e2, intType, lu)) with
        SLiteral 0 -> ()
      | SPos -> e1n.N.posarith <- true
      | SLiteral n when n > 0 -> e1n.N.posarith <- true
      | _ -> 
          if l.line = -1000 then (* Was created from p[e] *)
            e1n.N.posarith <- true
          else
            e1n.N.arith <- true);
      BinOp (bop, e1', doExpAndCast e2 intType, e1t, l), e1t, e1n
      
      
  | CastE (newt, e, l) -> 
      let newt', _ = doType newt (N.anonPlace ()) 0 in
      CastE (newt', doExpAndCast e newt', l), newt', nodeOfType newt'

  | _ -> (e, typeOf e, N.dummyNode)


(* Do an lvalue. We assume conservatively that this is for the purpose of 
 * taking its address. Return a modifed lvalue and a node that stands for & 
 * lval. Just ignore the node and get its base type if you do not want to 
 * take the address of. *)
and doLvalue ((base, off) : lval) (iswrite: bool) : lval * N.node = 
  let base', startNode = 
    match base with 
      Var vi -> begin 
        doVarinfo vi;
        (* Now grab the node for it *)
        base, 
        (match N.nodeOfAttrlist vi.vattr with Some n -> n | _ -> N.dummyNode)
      end
    | Mem e -> 
        let e', et, ne = doExp e in
        if iswrite then
          ne.N.updated <- true;
        Mem e', ne
  in
  let newoff, newn = doOffset off startNode in
  (base', newoff), newn
        
(* Now do the offset. Base types are included in nodes. *)
and doOffset (off: offset) (n: N.node) : offset * N.node = 
  match off with 
    NoOffset -> off, n
  | Field(fi, resto) -> 
      let nextn = fieldOfNode n fi in
      let newo, newn = doOffset resto nextn in
      Field(fi, newo), newn
  | Index(e, resto) -> begin
      let nextn = startOfNode n in
      nextn.N.posarith <- true;
      let newo, newn = doOffset resto nextn in
      let e', et, _ = doExp e in
      Index(e', newo), newn
  end


  
(* Now model an assignment of a processed expression into a type *)
and expToType (e,et,en) t (callid: int) = 
  let rec isZero = function
      Const(CInt(0, _, _), _) -> true
    | CastE(_, e, _) -> isZero e
    | _ -> false
  in
  let isString = function
      Const(CStr(_),_) -> true
    | _ -> false
  in
  let etn = nodeOfType et in
  let tn  = nodeOfType t in
  match etn == N.dummyNode, tn == N.dummyNode with
    true, true -> e
  | false, true -> e (* Ignore casts of pointer to non-pointer *)
  | false, false -> 
      let edgetype = 
        if isZero e then begin tn.N.null <- true; N.ENull end else N.ECast in
      N.addEdge etn tn edgetype callid; 
      e
  | true, false -> 
      (* Cast of non-pointer to a pointer. Check for zero *)
      (if isZero e then
        tn.N.null <- true
      else if not (isString e) then 
        tn.N.intcast <- true
        );
      e
    
and doExpAndCast e t = 
  expToType (doExp e) t (-1)

and doExpAndCastCall e t callid = 
  expToType (doExp e) t callid

(* Do a statement *)
let rec doStmt (s: stmt) = 
  match s with 
    (Skip | Label _ | Case _ | Default | Break | Continue | Goto _) -> s
  | Sequence sl -> Sequence (List.map doStmt sl)
  | Loop s -> Loop (doStmt s)
  | IfThenElse (e, s1, s2) -> 
      IfThenElse (doExpAndCast e intType, doStmt s1, doStmt s2)
  | Switch (e, s) -> Switch (doExpAndCast e intType, doStmt s)
  | Return None -> s
  | Return (Some e) -> 
      Return (Some (doExpAndCast e !currentResultType))
  | Instr (Asm _) -> s
  | Instr (Set (lv, e, l)) -> 
      let lv', lvn = doLvalue lv true in
      let eres = doExp e in
      (* Now process the copy *)
      let e' = expToType eres lvn.N.btype (-1) in
      Instr (Set (lv', e', l))

  | Instr (Call (reso, orig_func, args, l)) -> 
      let is_polymorphic v =
        v.vname = "free" ||
        v.vname = "malloc" ||
        v.vname = "calloc" ||
        v.vname = "calloc_fseq" ||
        v.vname = "realloc" in
      let func = begin (* check and see if it is malloc *)
        match orig_func with
          (Lval(Var(v),x)) when is_polymorphic v -> 
            (* now we have to do a lot of work to make a copy of this
             * function with all of the _ptrnode attributes stripped so 
             * that it will get a new node in the graph correctly *) 
            let strip a = dropAttribute a (ACons("_ptrnode",[])) in
            let rec strip_va va = { va with vtype = new_type va.vtype ;
                                        vattr = strip va.vattr } 
            and new_type t = begin match t with
              TVoid(a) -> TVoid(strip a)
            | TInt(i,a) -> TInt(i, strip a)
            | TBitfield(i,j,a) -> TBitfield(i,j, strip a)
            | TFloat(f,a) -> TFloat(f, strip a)
            | TEnum(s,l,a) -> TEnum(s,l, strip a)
            | TPtr(t,a) -> TPtr(new_type t, strip a)
            | TArray(t,e,a) -> TArray(new_type t,e,strip a)
            | TComp(c) -> TComp({ c with cattr = strip c.cattr}) 
            | TForward(c,a) -> TForward({c with cattr = strip c.cattr}, strip a)
            | TFun(t,v,b,a) -> TFun(new_type t,List.map strip_va v,b,strip a)
            | TNamed(s,t,a) -> TNamed(s,new_type t,strip a)
            end in 
            let new_vtype = new_type v.vtype in
            (* this is the bit where we actually make this call unique *)
            let new_varinfo = makeGlobalVar 
              ("/*" ^ (string_of_int (!callId + 1)) ^ "*/" ^ v.vname) 
                new_vtype 
            in
            doVarinfo new_varinfo ;  
            (Lval(Var(new_varinfo),x)) 
        | _ -> orig_func
      end in
      let func', funct, funcn = doExp func in
      let (rt, formals, isva) = 
        match unrollType funct with
          TFun(rt, formals, isva, _) -> rt, formals, isva
        | _ -> E.s (E.bug "Call to a non-function")
      in
      incr callId; (* A new call id *)
      (* Now check the arguments *)
      let rec loopArgs formals args = 
        match formals, args with
          [], _ when (isva || args = []) -> args
        | fo :: formals, a :: args -> 
            let a' = doExpAndCastCall a fo.vtype !callId in
            a' :: loopArgs formals args
        | _, _ -> E.s (E.bug "Not enough arguments")
      in begin
          begin
          (* Now check the return value*)
            match reso, unrollType rt with
              None, TVoid _ -> ()
            | Some _, TVoid _ -> 
                ignore (E.warn "Call of subroutine is assigned")
            | None, _ -> () (* "Call of function is not assigned" *)
            | Some destvi, _ -> 
                N.addEdge 
                  (nodeOfType rt)
                  (nodeOfType destvi.vtype) 
                  N.ECast !callId  
          end;
          Instr (Call(reso, func', loopArgs formals args, l))
      end
            
     
  
      
(* Now do the globals *)
let doGlobal (g: global) : global = 
  match g with
    (GText _ | GPragma _ | GAsm _) -> g
  | GType (n, t) -> 
      let t', _ = doType t (N.PType n) 0 in
      GType (n, t')
  | GDecl vi -> doVarinfo vi; g
  | GVar (vi, init) -> 
      doVarinfo vi;
      let init' = 
        match init with
          None -> None
        | Some i -> Some (doExpAndCast i vi.vtype)
      in
      GVar (vi, init')
  | GFun fdec -> 
      doVarinfo fdec.svar;
      currentFunctionName := fdec.svar.vname;
      (match fdec.svar.vtype with
        TFun(rt, _, _, _) -> currentResultType := rt
      | _ -> E.s (E.bug "Not a function"));
      (* Do the formals (the local version). Reuse the types from the 
       * function type *)
      List.iter doVarinfo fdec.sformals;
      (* Do the other locals *)
      List.iter doVarinfo fdec.slocals;
      (* Do the body *)
      fdec.sbody <- doStmt fdec.sbody;
      g
      
      
(* Now do the file *)      
let markFile fl = 
  currentFileName := fl.fileName;
  {fl with globals = List.map doGlobal fl.globals}

        


(* A special file printer *)
let printFile (c: out_channel) fl = 
  Cil.setCustomPrint (N.ptrAttrCustom true)
    (fun fl ->
      Cil.printFile c fl;
      output_string c "#if 0\n/* Now the graph */\n";
      (* N.gc ();   *)
      (* N.simplify ();   *)
      N.printGraph c;
      output_string c "/* End of graph */\n";
      output_string c "/* Now the solved graph (simplesolve) */\n";
      Stats.time "simple solver" Simplesolve.solve N.idNode ; 
      N.printGraph c;
      output_string c "/* End of solved graph*/\n#endif\n";
      ) 
    fl ;
  Cil.setCustomPrint (N.ptrAttrCustom false)
    (fun fl -> Cil.printFile c fl) fl 

