open Big_int
module E = Errormsg

let averageloopcount = ref 40;;

(** Unary Operations*)
type unop =
  | Cast                                (** Cast expression*)
  | Neg                                 (** Unary minus *)
  | BNot                                (** Bitwise complement (~) *)
  | LNot                                (** Logical Not (!) *)
(** Binary operations *)
and binop =
  | PlusA                               (** arithmetic + *)
  | MinusA                              (** arithmetic - *)
  | Mult                                (** * *)
  | Div                                 (** / *)
  | Mod                                 (** % *)
  | Shiftlt                             (** shift left *)
  | Shiftrt                             (** shift right *)
  | Lt                                  (** <  (arithmetic comparison) *)
  | Gt                                  (** >  (arithmetic comparison) *)  
  | Le                                  (** <= (arithmetic comparison) *)
  | Ge                                  (** >  (arithmetic comparison) *)
  | Eq                                  (** == (arithmetic comparison) *)
  | Ne                                  (** != (arithmetic comparison) *)            
  | BAnd                                (** bitwise and *)
  | BXor                                (** bitwise exclusive-or *)
  | BOr                                 (** bitwise inclusive-or *)
and funmodule = {
	mutable vdesc: vvarinfo;
		(** The name and output type of the function *) 
	mutable vinputs: vvarinfo list;
		(** The parameters to the function *)
	mutable vlocals: vvarinfo list;
		(** The local variables in the function *)
	mutable vmodules: vmodule list;
		(** The modules that provide internal functionality *)
}
and vvarinfo = {
	mutable varname: string;
		(** The name of the variable *)
	mutable vtype: vtype;
		(** the type of this constant *)
}
and vconstinfo = {
	mutable value: big_int;
		(** the value of this constant *)
	mutable ctype: vtype;
		(** the type of this constant *)
}
and vconnection = {
	mutable connectfrom: int option;
		(** The id of the exporting module, none means from the start *)
	mutable connectto: int option;
		(** The id of the importing module, none means computation ends *)
	mutable requires: (voperationlink * bool) option;
		(** Optional requirement for exporting, The value of the operation 
			with the given id must have the same c truth value as the bool 
			provided *)
	mutable probability: float;
		(** The likelihood of taking this connection*)
}
and vmodule = {
	mutable mid: int;
		(** The id of this module in the function *)
	mutable mvars: vvarinfo list;
		(** The variables inputed to this module *)
	mutable mvarexports: vvarinfo list;
		(** The variables outputed from this module *)
	mutable minputs: vconnection list;
		(** The incoming connections *)
	mutable moutputs: vconnection list;
		(** The posible modules to hand control flow to *)
	mutable mdataFlowGraph: voperation list;
}
and voperationlink = 
	| Simple of voperation
	| Compound of vcomplink list
and vcomplink = {
	mutable loperation: voperation;
		(** the operation linked from *)
	mutable lbase: int;
		(** base position to link from *)
	mutable lwidth: int;
		(** the size of the link *)
}
and voperation = {
	mutable oid: int;
		(** id used to remove duplicates inside a module *)
	mutable operation: voperationtype;
		(** the type of this operation*)
	mutable ousecount: int;
		(** the number of users of this operation *)
	mutable oschedule: vscheduleinfo;
		(** the scheduling data of this operation *)
}
and vscheduleinfo = {
	earliest: int;
		(** asap schedule *)
	latest: int;
		(** alap schedule*)
	set: int;
		(** actual schedule *)
}
and voperationtype = 
	| Variable of vvarinfo
		(** The value of a variable as it enters the module *)
	| Constant of vconstinfo
		(** The value of a constant *)
	| Result of vvarinfo * int * int * voperationlink
		(** marks the value of a variable that should be passed to the next 
			stage *)
	| ReturnValue of voperationlink
		(** marks the value to be returned *)
	| Unary of unop * voperationlink * vtype
		(** applies a unary operation to the previous item *)
	| Binary of binop * voperationlink * voperationlink * vtype
		(** applies a binary operation to the previous items *)  
and vtype = 
	| Basic of vtypeelement
	| Struct of vtypeelement * vcompelement list
	| Union of vtypeelement * vcompelement list
and vtypeelement = {
	(** The width of the type, in bits *)
	mutable width: int;
	(** Whether this is a signed variable *)
	mutable isSigned: bool;
}
and vcompelement = {
	(** The name of the element *)
	mutable ename: string;
	(** The type of the element*)
	mutable etype: vtype;
	(** The base position of this element in the composite type*)
	mutable ebase: int;
}

let emptyschedule = {earliest = 0; latest = 0; set = 0};;

(** The following functions produce a JSON like dump of all the 
 *  information inside any of the above data types. Since there are
 *  typically multiple references to certain items within modules,
 *  some items are represented only by an id.
 *)
let string_of_list lp rp sf fl = lp ^ (String.concat ", " (List.map sf fl)) ^ rp
let string_of_list_sq sf fl = string_of_list "[" "]" sf fl
let string_of_list_cl sf fl = string_of_list "{" "}" sf fl
let string_of_list_pr sf fl = string_of_list "(" ")" sf fl

let rec string_of_unop u = match u with
  | Neg -> "Neg"
  | BNot -> "BNot"
  | LNot -> "LNot"
  | Cast -> "Cast"
and string_of_binop b = match b with
  | PlusA  -> "PlusA "
  | MinusA -> "MinusA"
  | Mult -> "Mult"
  | Div -> "Div"
  | Mod -> "Mod"
  | Shiftlt -> "Shiftlt"
  | Shiftrt -> "Shiftrt"
  | Lt -> "Lt"
  | Gt -> "Gt"
  | Le -> "Le"
  | Ge -> "Ge"
  | Eq -> "Eq"
  | Ne -> "Ne"
  | BAnd -> "BAnd"
  | BXor -> "BXor"
  | BOr -> "BOr"
and string_of_funmodule f = 
	"{ vdesc:" ^ string_of_vvarinfo f.vdesc
	^ ", vinputs:" ^ string_of_vvarinfo_list f.vinputs
	^ ", vlocals:" ^ string_of_vvarinfo_list f.vlocals
	^ ", vmodules:" ^ string_of_vmodule_list f.vmodules
	^ "}"
and string_of_vvarinfo v = 
	"{ varname:\"" ^ v.varname
	^ "\", vtype:" ^ string_of_vtype v.vtype
	^ "}"
and string_of_vvarinfo_list l = string_of_list_sq string_of_vvarinfo l
and string_of_vconstinfo c = 
	"{ value:" ^ string_of_big_int c.value
	^ ", vtype:" ^ string_of_vtype c.ctype
	^ "}"
and string_of_vconnection c = 
	"{ connectfrom:" ^ (match c.connectfrom with 
		| Some i -> string_of_int i
		| None -> "None"
	)
	^ ", connectto:" ^ (match c.connectto with 
		| Some i -> string_of_int i
		| None -> "None"
	)
	^ ", requires:" ^ (match c.requires with 
		| Some (o,b) -> "Some:(" ^ string_of_voperationlink o ^ ", " 
			^ string_of_bool b ^ ")"
		| None -> "None"
	)
	^ ", probability:" ^ string_of_float c.probability
	^ "}"
and string_of_vconnection_list l = string_of_list_sq string_of_vconnection l
and string_of_vmodule m = 
	"{ mid:" ^ string_of_int m.mid
	^ ", minputs:" ^ string_of_vconnection_list m.minputs
	^ ", moutputs:" ^ string_of_vconnection_list m.moutputs
	^ ", mdataFlowGraph:" ^ string_of_voperation_list m.mdataFlowGraph
	^ "}"
and string_of_vmodule_list l = string_of_list_sq string_of_vmodule l
and string_of_voperationlink ol = match ol with
	| Simple o -> "Simple:" ^ string_of_voperation o
	| Compound ol -> "Compound:" ^ string_of_list_sq string_of_vcomplink ol
and string_of_vcomplink vl = 
	"{ loperation:" ^ string_of_int vl.loperation.oid
	^ ", lbase:" ^ string_of_int vl.lbase 
	^ ", lwidth:" ^ string_of_int vl.lwidth
	^ "}"	
and string_of_voperation o = 
	"{ oid:" ^ string_of_int o.oid
	^ ", ousecount:" ^ string_of_int o.ousecount 
	^ ", oschedule:" ^ string_of_vscheduleinfo o.oschedule
	^ ", operation:" ^ string_of_voperationtype o.operation
	^ "}"
and string_of_voperation_list l = string_of_list_sq string_of_voperation l
and string_of_vscheduleinfo si = 
	"{ earliest:" ^ string_of_int si.earliest
	^ ", latest:" ^ string_of_int si.latest 
	^ ", set:" ^ string_of_int si.set
	^ "}"
and string_of_voperationtype vt = "{" ^ (match vt with
	| Variable v -> "Variable:" ^ string_of_vvarinfo v
	| Constant c -> "Constant:" ^ string_of_vconstinfo c
	| Result (v,b,w,o) -> "Result:(" ^ string_of_vvarinfo v ^ ", " ^ string_of_int b ^ ", " ^ string_of_int w ^ ", " ^ string_of_voperationlink o ^ ")"
	| ReturnValue o -> "ReturnValue:(" ^ string_of_voperationlink o ^ ")"
	| Unary (u,o,t) -> "Unary:(" ^ string_of_unop u ^ ", " ^ string_of_voperationlink o ^ ", " 
		^ string_of_vtype t ^ ")" 
	| Binary (u,o1,o2,t) -> "Binary:(" ^ string_of_binop u ^ ", " ^ string_of_voperationlink o1
		^ ", " ^ string_of_voperationlink o2 ^ ", " ^ string_of_vtype t ^ ")" 
	) ^ "}"
and string_of_vtype t = "{" ^ (match t with
	| Basic te -> "Basic:" ^ string_of_vtypeelement te
	| Struct (te,cel) -> "Struct:(" ^ string_of_vtypeelement te ^ ", [" ^
		string_of_list_sq string_of_vcompelement cel ^ "])"
	| Union (te,cel) -> "Union:(" ^ string_of_vtypeelement te ^ ", [" ^ 
		string_of_list_sq string_of_vcompelement cel ^ "])"
	) ^ "}"
and string_of_vtypeelement te = 
	"{ width:" ^ string_of_int te.width
	^ ", isSigned:" ^ string_of_bool te.isSigned
	^ "}"
and string_of_vcompelement ce = 
	"{ ename:" ^ ce.ename
	^ ", etype:" ^ string_of_vtype ce.etype
	^ ", ebase:" ^ string_of_int ce.ebase
	^ "}"

(* gets the typeelement from a type *)
let gettypeelement (t:vtype) = match t with
	| Basic te 
	| Struct (te,_) 
	| Union (te,_) 
		-> te

(*  The following functions attempt to give a quick readable
 *  output from the various types, intented for console output
 *)
let rec print_unop u = match u with
  | Neg -> "-"
  | BNot -> "~"
  | LNot -> "!"
  | Cast -> "<cast>"
and print_binop b = match b with
  | PlusA  -> "+"
  | MinusA -> "-"
  | Mult -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Shiftlt -> "<<"
  | Shiftrt -> ">>"
  | Lt -> "<"
  | Gt -> ">"
  | Le -> "<="
  | Ge -> ">="
  | Eq -> "=="
  | Ne -> "!="
  | BAnd -> "&"
  | BXor -> "^"
  | BOr -> "|"
and print_funmodule f = 
	(print_vvarinfo f.vdesc)
	^ "\n\tinputs:" ^ string_of_list_sq print_vvarinfo f.vinputs
	^ "\n\tlocals:" ^ string_of_list_sq print_vvarinfo f.vlocals
	^ "\n\tmodules:\n\t" ^ (String.concat "\n\t" (List.map print_vmodule f.vmodules))
and print_vvarinfo v = 
	v.varname ^ ": " ^ (print_vtype v.vtype)
and print_vconstinfo c = 
	(string_of_big_int c.value) ^ ": " ^ (print_vtype c.ctype)
and print_vconnections (c:vconnection list) = match c with
	| [{connectfrom=f;connectto=t;requires=None}] -> "-> " ^ (match t with 
		| Some i -> (string_of_int i)
		| None -> "return"
	)
	| [{connectfrom=f1;connectto=tt;requires=Some(o1,true);probability=pt};
		{connectfrom=f2;connectto=tf;requires=Some(o2,false);probability=pf}] 
		when f1 = f2 || o1 = o2
	-> "-> " ^ print_voperationlink o1 ^ " ? " ^ (match tt with 
		| Some i -> (string_of_int i)
		| None -> "return"
	) ^ " : " ^ (match tf with 
		| Some i -> (string_of_int i)
		| None -> "return"
	) ^ "\t\t(" ^ string_of_float pt ^ ":" ^ string_of_float pf ^ ")"
	| _ -> string_of_list_sq string_of_vconnection c
and print_vmodule m = 
	(string_of_int m.mid) ^ " " ^ (print_vconnections m.moutputs) 
	^ "    ( " ^ (String.concat ", " (List.map (fun v -> v.varname) m.mvars))
	^ " ) -> ( " ^ (String.concat ", " (List.map (fun v -> v.varname) m.mvarexports))
	^ " )\n\t\t" ^ (String.concat "\n\t\t" (List.map print_voperation m.mdataFlowGraph))
and print_voperation o = 
	(string_of_int o.oid) ^ " ==== " ^ (print_voperationtype o.operation)
	^ "\t\t" ^ (print_vscheduleinfo o.oschedule)
and print_voperationlink ol = match ol with
	| Simple o -> "<" ^ string_of_int o.oid ^ ">"
	| Compound ol -> string_of_list_cl print_vcomplink ol
and print_vcomplink vl = "<" ^ string_of_int vl.loperation.oid ^ ">[" 
	^ string_of_int (vl.lbase+vl.lwidth-1)
	^ string_of_int vl.lbase ^ "]"
and print_voperationtype vt = match vt with
	| Variable v -> print_vvarinfo v
	| Constant c -> print_vconstinfo c
	| Result (v,b,w,o) -> v.varname ^ " = (" ^ print_voperationlink o ^ ")[" ^ string_of_int (b+w-1) ^ ":" ^ string_of_int b ^ "]"
	| ReturnValue o -> "return " ^ print_voperationlink o 
	| Unary (u,o,t) -> (print_unop u) ^ print_voperationlink o ^ ": " 
		^ (print_vtype t) 
	| Binary (u,o1,o2,t) -> print_voperationlink o1 ^ " " ^ print_binop u ^ " " ^ 
		print_voperationlink o2 ^ ": " ^ print_vtype t
and print_vscheduleinfo si = 
	"@" ^ string_of_int si.set 
	^ "(" ^ string_of_int si.earliest 
	^ "-" ^ string_of_int si.latest ^ ")"
and print_vtype t = match t with
	| Basic te -> print_vtypeelement te
	| Struct (te,cel) -> string_of_list_cl print_vcompelement cel
	| Union (te,cel) -> "{" ^ (String.concat "||" (List.map print_vcompelement cel)) ^ "}"
and print_vtypeelement te = 
	(string_of_int te.width) ^ "'" ^ if te.isSigned then "s" else "u"
and print_vcompelement ce = 
	ce.ename ^ ":" ^ print_vtype ce.etype

(* the following functions check for equality between various types
 * there are several pieces of information left out, if it's not deemed
 * necessary to the equality test *)
let eq_type (t1:vtype) (t2:vtype) = t1 = t2
let eq_typeelement (te1:vtypeelement) (te2:vtypeelement) = te1 = te2
let eq_compelement (ce1:vtypeelement) (ce2:vtypeelement) = ce1 = ce2
let eq_unop (u1:unop) (u2:unop) = u1 = u2
let eq_binop (b1:binop) (b2:binop) = b1 = b2
let eq_complink (l1:vcomplink) (l2:vcomplink) = 
	l1.loperation.oid = l2.loperation.oid &&
	l1.lbase = l2.lbase && l2.lwidth = l2.lwidth
let eq_operation_link (l1:voperationlink) (l2:voperationlink) = match (l1,l2) with
	| (Simple o1, Simple o2) -> o1 = o2
	| (Compound ol1, Compound ol2) -> List.for_all2 eq_complink ol1 ol2
	| _ -> false
let eq_operation_type (ot1:voperationtype) (ot2:voperationtype) = 
	match (ot1,ot2) with
	| (Variable v1, Variable v2) when v1.varname = v2.varname -> true
	| (Constant c1, Constant c2) when (eq_big_int c1.value c2.value && eq_type c1.ctype c2.ctype) -> true
	| (Result (v1,b1,w1,o1), Result (v2,b2,w2,o2)) when v1.varname = v2.varname && eq_operation_link o1 o2 && b1=b2 && w1=w2-> true
	| (Unary (u1,o1,t1), Unary (u2,o2,t2)) when eq_unop u1 u2 && eq_operation_link o1 o2 && eq_type t1 t2 -> true
	| (Binary (b1,o11,o21,t1), Binary(b2,o12,o22,t2)) 
		when eq_binop b1 b2 && eq_operation_link o11 o12 &&
		eq_operation_link o21 o22 && eq_type t1 t2 -> true
	| _ -> false
let eq_operation (o1:voperation) (o2:voperation) = 
	o1.oid = o2.oid && eq_operation_type o1.operation o2.operation



let getlinkchildren (l:voperationlink) = match l with
	| Simple o -> [o]
	| Compound ol -> List.map (fun l -> l.loperation) ol

(* gets the children of an operation *)
let getchildren (o:voperation) = 
	match o.operation with
	| Result (_,_,_,o1) -> getlinkchildren o1
	| ReturnValue o1 -> getlinkchildren o1
	| Unary (_,o1,_) -> getlinkchildren o1
	| Binary (_,o1,o2,_) -> (getlinkchildren o1) @ (getlinkchildren o2)
	| _ -> []

(* checks whether the children are in a given list, or returns default
 * if o has no children *)
let childreninlist (default:bool) (o:voperation) (l:voperation list) = 
	match getchildren o with 
		| [] -> default
		| x -> List.for_all (fun o1 -> List.memq o1 l) x

(* gets scheduling offset for o *)
let operationoffset (o:voperation) = match o.operation with
	| Unary (Cast,_,_) -> 0 (* cast is instant *)
	| Unary (_,_,_)  
	| Binary(_,_,_,_) -> 1 (* other operators take 1 step *)
	| _ -> 0 (* results, consts returnvalues and variables are instant *)

(* helper functions for manipulating vil objects *)

let getentrypoint (f:funmodule) = List.find (fun m -> match m.minputs with
		| [{connectfrom=None;connectto=Some _;requires=None}] -> true
		| _ -> false
	) f.vmodules

(* extracts module from an id *)
let modulefromintoption (f:funmodule) (io:int option) = match io with
	| Some i -> Some (List.find (fun m -> m.mid = i) f.vmodules)
	| None -> None

(* gives a sucessor list *)
let getmodulesucessors (f:funmodule) (m:vmodule) :vmodule list = 
	Listutil.mapfilter (fun c -> modulefromintoption f c.connectto) m.moutputs

(* gives a predecessor list *)
let getmodulepredecessors (f:funmodule) (m:vmodule) :vmodule list = 
	Listutil.mapfilter (fun c -> modulefromintoption f c.connectfrom) m.minputs

(* is variable v in list l ? (name equality)*)
let variableinlist (v:vvarinfo) (l:vvarinfo list) = 
	List.exists (fun v1 -> v1.varname = v.varname) l

(* does m have a result operation for v?*)
let hasvariableresult (v:vvarinfo) (o:voperation list) = 
	List.exists (fun op -> match op.operation with
			| Result (v1,_,_,_) when v1.varname = v.varname -> true
			| _ -> false
		) o

(* doesn m have a variable operation for v? *)
let hasvariableuse (v:vvarinfo) (m:vmodule) = 
	List.exists (fun op -> match op.operation with
			| Variable v1 when v1.varname = v.varname -> true
			| _ -> false
		) m.mdataFlowGraph

(* increment operation use count *)
let incoperationcount (op:voperation) = 
	op.ousecount <- op.ousecount + 1

(* decrement operation use count *)
let decoperationcount (op:voperation) = 
	op.ousecount <- op.ousecount - 1

(* applies f to the immediate children of op *)
let dotoimmediatechildren (f:voperation -> unit) (op:voperation) = 
	List.iter (fun o -> f o) (getchildren op)

(* simple uses of dotoimmediatechildren for tracking use counts *)
let incchildren = dotoimmediatechildren incoperationcount;;
let decchildren = dotoimmediatechildren decoperationcount;;

(* get switching points *)
let getswitches (m:vmodule) = 
	let foundids = ref []
	in (Listutil.mapfilter (fun c -> match c.requires with
		| Some(o,_) when not (List.mem o !foundids) -> 
			foundids := o :: ! foundids;
			Some(o)
		| _ -> None) m.moutputs)

(* get type of an operation *)
let rec gettype (f:vvarinfo) (o:voperation) = match o.operation with
	| Variable v 
	| Result (v,_,_,_) -> v.vtype
	| Constant c -> c.ctype
	| ReturnValue o1 -> f.vtype
	| Unary (_,_,t) 
	| Binary (_,_,_,t) -> t

(* get the name of a function *)
let functionname (f:funmodule) = f.vdesc.varname

(* gets the latest scheduled item in a vmodule *)
let maxtime (m:vmodule) = 
	List.fold_left (fun a o -> max o.oschedule.set a) 0 m.mdataFlowGraph

(* code for filling in the schedule *)

(* sets the asap schedule for o *)
let asap (o:voperation) = o.oschedule <- 
	{
		earliest = (List.fold_left max 0 (List.map (fun o1 -> o1.oschedule.earliest) (getchildren o))) + (operationoffset o);
		latest = o.oschedule.latest; 
		set = o.oschedule.set;
	}

(* sets the alap schedule for o*)
let alap (latest:int) (ops:voperation list) (o:voperation) = o.oschedule <- 
	{
		earliest = o.oschedule.earliest; 
		latest = (let users = List.filter (fun o1 -> List.memq o (getchildren o1)) ops 
			in match users with
				| [] -> latest
				| h::t -> (List.fold_left min (h.oschedule.latest - (operationoffset h)) (List.map (fun o1 -> o1.oschedule.latest - (operationoffset o1)) t)) 
		);
		set = o.oschedule.set;
	}

(* builds asap schedule for ops (start with acc=[]) *)
let rec generateasap (acc:voperation list) (ops:voperation list) = 
	match ops with
	| [] -> ()
	| _ -> let (ready,notready) = List.partition (fun o -> childreninlist true o acc) ops
		in List.iter asap ready;
			generateasap (List.rev_append ready acc) notready
(* builds alap schedule for ops (start with acc=[] and latest as the maximum asap value) *)
let rec generatealap (latest:int) (acc:voperation list) (ops:voperation list) = 
	match ops with
	| [] -> ()
	| _ -> let (notready,ready) = List.partition (fun o -> List.exists (fun o1 -> List.memq o (getchildren o1)) ops) ops
		in List.iter (alap latest acc) ready;
			generatealap latest (List.rev_append ready acc) notready

(* generates an overall schedule for the module *)
let rec generateschedule (m:vmodule) =
	List.iter (fun o -> o.oschedule <- (* TODO add non trivial scheduler *)
	{earliest=o.oschedule.earliest;latest=o.oschedule.latest;set=o.oschedule.earliest}) m.mdataFlowGraph

(* generates schedules for all modules *)
let generatescheduleinfo (f:funmodule) = 
	List.iter (fun m -> 
		generateasap [] m.mdataFlowGraph; 
		generatealap (List.fold_left (fun a b -> max a b.oschedule.earliest) (* find max time *)
			0 m.mdataFlowGraph) [] m.mdataFlowGraph;
		generateschedule m;
	) f.vmodules

(* subroutines to replace operations, useful later *)

(* gives the result of running all replacements in reps on the operation op *)
let replaceone (reps :(voperation*voperation) list) (op: voperation) = 
	try snd (List.find (fun (f,_) -> f.oid = op.oid) reps)
	with | Not_found -> op

(* gets the specified range of a complink list *)
let getrange (b:int) (w:int) (cll:vcomplink list) = 
	Listutil.mapfilter (fun cl ->
		if (b >= cl.lbase && b < cl.lbase + cl.lwidth) || (cl.lbase >= b && cl.lbase < b + w)
		then Some {
			loperation=cl.loperation;
			lbase=max cl.lbase b;
			lwidth=(min (b+w) (cl.lbase+cl.lwidth)) - b; }
		else None
	) cll

(* creates a new complink and replaces the target if necessary *)
let duplicatecomplinkwithreplacement (replacee:voperation) (replacer:voperation) (target:vcomplink) =
	{
		loperation=if target.loperation.oid = replacee.oid then replacer else target.loperation;
		lbase=target.lbase;
		lwidth=target.lwidth;
	}

(* replaces operation with the appropriate sections of a link in the target *)
let replaceinlink (target:voperationlink) ((replacee:voperation),(replacer:voperationlink)) :voperationlink =
	match (target,replacer) with
		| (Simple o,_) -> if o.oid = replacee.oid then replacer else target
		| (Compound cll,Simple o) -> Compound (List.map (duplicatecomplinkwithreplacement replacee o) cll)
		| (Compound cll1,Compound cll2) -> Compound (Listutil.mapflatten (fun cl -> 
				if cl.loperation.oid = replacee.oid 
				then getrange cl.lbase cl.lwidth cll2
				else [cl]
			) cll1)

let replacelink (reps :(voperation*voperationlink) list) (target:voperationlink) :voperationlink =
	List.fold_left replaceinlink target reps

(* replace the targeted operations in condition requirements *)
let replaceconditions (reps :(voperation*voperationlink) list) (cs:vconnection list) = List.iter
	(fun c -> let req = 
		match c.requires with
			| None -> None
			| Some (o,b) -> Some (replacelink reps o,b)
		in c.requires <- req
	) cs

(* replace operations in the sub trees of operations in the list *)
let replaceoperations (reps :(voperation*voperationlink) list) (ops :voperation list) = List.iter 
	(fun o -> let op = 
		match o.operation with
			| Result (v,b,w,o1) -> Result(v,b,w,replacelink reps o1)
			| Unary (u,o1,t) -> Unary(u,replacelink reps o1,t)
			| Binary (b,o1,o2,t) -> Binary(b,replacelink reps o1, replacelink reps o2,t)
			| _ -> o.operation
		in o.operation <- op
	) ops

let mergeoperations (o1:voperation list) (o2:voperation list) (c2:vconnection list) = 
	(* remove result tags if one exists in second module *)
	let first_half = List.filter 
		(fun o -> match o.operation with
			| Result(i,b,w,_) when hasvariableresult i o2 -> false
			| _ -> true
		) o1
	(* things to replace, variable references and what they 
	 * were set to in the first module *)
	in let replacements = ref []
	(* remove variable accesses that were set in first module and add replacements *)
	in let second_half = List.filter
		(fun o -> match o.operation with
			| Variable i when List.exists 
				(fun o1 -> match o1.operation with
					| Result(i1,_,_,o2) when i1.varname = i.varname -> 
						replacements := (o,o2) :: !replacements;
						true
					| _ -> false
				) o1 -> false
			| _ -> true
		) o2
	in  (* do replacements *)
		replaceoperations !replacements second_half;
		(* do the same replacements on the condiditons *)
		replaceconditions !replacements c2;
		(* join the two together (rev_append is tail recursive) *)
		List.rev_append first_half second_half